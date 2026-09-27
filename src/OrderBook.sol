// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "../lib/openzeppelin-contracts/contracts/utils/math/Math.sol";

interface IERC20Book {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @notice A single-pair, fully escrowed price-time priority limit-order book.
/// @dev Token amounts are raw units. Supported tokens must have stable, honest balances and exact transfers.
contract OrderBook {
    uint256 public constant SCALE = 1e18;
    uint256 public constant MAX_FILLS = 32;
    uint256 public constant MAX_LEVEL_WALK = 64;

    address public immutable base;
    address public immutable quote;
    uint256 public immutable tickSize;
    uint256 public immutable minBaseAmount;

    enum Status {
        Open,
        Filled,
        Cancelled
    }

    struct Order {
        address maker;
        bool isBuy;
        uint256 price;
        uint256 remainingBase;
        uint256 remainingQuote;
        Status status;
        uint256 prev;
        uint256 next;
    }

    struct Level {
        uint256 prev;
        uint256 next;
        uint256 head;
        uint256 tail;
    }

    mapping(uint256 => Order) private _orders;
    mapping(bool => mapping(uint256 => Level)) private _levels;
    mapping(address => mapping(address => uint256)) public claimable;
    uint256 public nextOrderId = 1;
    uint256 private _bestBid;
    uint256 private _bestAsk;
    uint256 private _lock = 1;

    error InvalidConfiguration();
    error InvalidPrice();
    error AmountTooSmall();
    error NotMaker();
    error NotOpen();
    error TooDeep();
    error InvalidToken();
    error TokenTransferFailed();
    error InexactDeposit();
    error ReentrantCall();

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed maker,
        bool isBuy,
        uint256 price,
        uint256 baseAmount,
        bool immediateOrCancel
    );
    event Filled(
        uint256 indexed makerOrderId,
        uint256 indexed takerOrderId,
        uint256 price,
        uint256 baseAmount,
        uint256 quoteAmount
    );
    /// @dev Also emitted for automatic releases (IOC, dust, or a still-crossing fill-cap remainder).
    event OrderCancelled(uint256 indexed orderId);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);

    constructor(address base_, address quote_, uint256 tickSize_, uint256 minBaseAmount_) {
        if (base_ == address(0) || quote_ == address(0) || base_ == quote_ || tickSize_ == 0) {
            revert InvalidConfiguration();
        }
        // Equivalent to minBaseAmount_ * tickSize_ >= SCALE, without multiplication overflow.
        if (minBaseAmount_ < (SCALE - 1) / tickSize_ + 1) revert InvalidConfiguration();
        base = base_;
        quote = quote_;
        tickSize = tickSize_;
        minBaseAmount = minBaseAmount_;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @notice Escrow, match at maker prices, and rest or release any remainder.
    /// @dev A released remainder is Cancelled; an exactly filled order is Filled. Closed balances are zero.
    function place(bool isBuy, uint256 price, uint256 baseAmount, bool immediateOrCancel)
        external
        nonReentrant
        returns (uint256 orderId)
    {
        if (price == 0 || price % tickSize != 0) revert InvalidPrice();
        if (baseAmount < minBaseAmount) revert AmountTooSmall();
        uint256 quoteEscrow = isBuy ? Math.mulDiv(baseAmount, price, SCALE, Math.Rounding.Ceil) : 0;
        _deposit(isBuy ? quote : base, isBuy ? quoteEscrow : baseAmount);

        orderId = nextOrderId++;
        Order storage taker = _orders[orderId];
        taker.maker = msg.sender;
        taker.isBuy = isBuy;
        taker.price = price;
        taker.remainingBase = baseAmount;
        taker.remainingQuote = quoteEscrow;
        emit OrderPlaced(orderId, msg.sender, isBuy, price, baseAmount, immediateOrCancel);

        uint256 fills = 0;
        // Stop on taker dust as well as maker dust: every actual fill is at least minBaseAmount.
        while (taker.remainingBase >= minBaseAmount && fills < MAX_FILLS && _crosses(isBuy, price)) {
            uint256 makerPrice = isBuy ? _bestAsk : _bestBid;
            uint256 makerId = _levels[!isBuy][makerPrice].head;
            Order storage maker = _orders[makerId];
            uint256 fillBase = Math.min(taker.remainingBase, maker.remainingBase);
            uint256 fillQuote = Math.mulDiv(fillBase, makerPrice, SCALE);
            taker.remainingBase -= fillBase;
            maker.remainingBase -= fillBase;

            if (isBuy) {
                taker.remainingQuote -= fillQuote;
                claimable[taker.maker][base] += fillBase;
                claimable[maker.maker][quote] += fillQuote;
            } else {
                maker.remainingQuote -= fillQuote;
                claimable[maker.maker][base] += fillBase;
                claimable[taker.maker][quote] += fillQuote;
            }
            emit Filled(makerId, orderId, makerPrice, fillBase, fillQuote);
            ++fills;

            if (maker.remainingBase < minBaseAmount) {
                _unlink(makerId);
                _close(makerId);
            }
        }

        if (taker.remainingBase >= minBaseAmount && !immediateOrCancel && !_crosses(isBuy, price)) {
            _rest(orderId);
        } else {
            _close(orderId);
        }
    }

    function cancel(uint256 orderId) external nonReentrant {
        Order storage item = _orders[orderId];
        if (item.maker != msg.sender) revert NotMaker();
        if (item.status != Status.Open) revert NotOpen();
        _unlink(orderId);
        _close(orderId);
    }

    /// @notice Withdraw all of the caller's credit for one of the pair's tokens. Zero credit is a no-op.
    function withdraw(address token) external nonReentrant returns (uint256 amount) {
        if (token != base && token != quote) revert InvalidToken();
        amount = claimable[msg.sender][token];
        if (amount == 0) return 0;
        claimable[msg.sender][token] = 0;
        _callToken(token, abi.encodeCall(IERC20Book.transfer, (msg.sender, amount)));
        emit Withdrawn(msg.sender, token, amount);
    }

    function bestBid() external view returns (uint256) {
        return _bestBid;
    }

    function bestAsk() external view returns (uint256) {
        return _bestAsk;
    }

    /// @dev Unknown IDs return zero fields; status has meaning only when maker is nonzero.
    function order(uint256 id)
        external
        view
        returns (
            address maker,
            bool isBuy,
            uint256 price,
            uint256 remainingBase,
            uint256 remainingQuote,
            Status status
        )
    {
        Order storage item = _orders[id];
        return (item.maker, item.isBuy, item.price, item.remainingBase, item.remainingQuote, item.status);
    }

    /// @notice Next worse price; zero for the end of the list or an absent level.
    function nextLevel(bool isBuy, uint256 price) external view returns (uint256) {
        return _levels[isBuy][price].next;
    }

    /// @notice Read-only traversal metadata for indexers and structural checks.
    function level(bool isBuy, uint256 price)
        external
        view
        returns (uint256 prev, uint256 next, uint256 head, uint256 tail)
    {
        Level storage item = _levels[isBuy][price];
        return (item.prev, item.next, item.head, item.tail);
    }

    function orderLinks(uint256 id) external view returns (uint256 prev, uint256 next) {
        return (_orders[id].prev, _orders[id].next);
    }

    function _crosses(bool isBuy, uint256 price) private view returns (bool) {
        return isBuy ? (_bestAsk != 0 && price >= _bestAsk) : (_bestBid != 0 && price <= _bestBid);
    }

    function _rest(uint256 id) private {
        Order storage item = _orders[id];
        Level storage queue = _levels[item.isBuy][item.price];
        if (queue.head == 0) _insertLevel(item.isBuy, item.price);
        item.prev = queue.tail;
        if (queue.tail == 0) queue.head = id;
        else _orders[queue.tail].next = id;
        queue.tail = id;
    }

    function _insertLevel(bool isBuy, uint256 price) private {
        uint256 cursor = isBuy ? _bestBid : _bestAsk;
        uint256 previous = 0;
        uint256 walked = 0;
        while (cursor != 0 && (isBuy ? cursor > price : cursor < price)) {
            if (walked == MAX_LEVEL_WALK) revert TooDeep();
            ++walked;
            previous = cursor;
            cursor = _levels[isBuy][cursor].next;
        }
        Level storage inserted = _levels[isBuy][price];
        inserted.prev = previous;
        inserted.next = cursor;
        if (previous == 0) {
            if (isBuy) _bestBid = price;
            else _bestAsk = price;
        } else {
            _levels[isBuy][previous].next = price;
        }
        if (cursor != 0) _levels[isBuy][cursor].prev = price;
    }

    function _unlink(uint256 id) private {
        Order storage item = _orders[id];
        Level storage queue = _levels[item.isBuy][item.price];
        if (item.prev == 0) queue.head = item.next;
        else _orders[item.prev].next = item.next;
        if (item.next == 0) queue.tail = item.prev;
        else _orders[item.next].prev = item.prev;
        item.prev = 0;
        item.next = 0;
        if (queue.head == 0) {
            if (queue.prev == 0) {
                if (item.isBuy) _bestBid = queue.next;
                else _bestAsk = queue.next;
            } else {
                _levels[item.isBuy][queue.prev].next = queue.next;
            }
            if (queue.next != 0) _levels[item.isBuy][queue.next].prev = queue.prev;
            delete _levels[item.isBuy][item.price];
        }
    }

    /// @dev Caller must unlink resting orders first. Escrow becomes a pull-payment liability.
    function _close(uint256 id) private {
        Order storage item = _orders[id];
        bool fullyFilled = item.remainingBase == 0;
        if (item.isBuy) {
            claimable[item.maker][quote] += item.remainingQuote;
            item.remainingQuote = 0;
        } else {
            claimable[item.maker][base] += item.remainingBase;
        }
        item.remainingBase = 0;
        item.status = fullyFilled ? Status.Filled : Status.Cancelled;
        if (!fullyFilled) emit OrderCancelled(id);
    }

    function _deposit(address token, uint256 amount) private {
        uint256 beforeBalance = IERC20Book(token).balanceOf(address(this));
        _callToken(token, abi.encodeCall(IERC20Book.transferFrom, (msg.sender, address(this), amount)));
        uint256 afterBalance = IERC20Book(token).balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactDeposit();
    }

    function _callToken(address token, bytes memory data) private {
        (bool success, bytes memory result) = token.call(data);
        if (!success || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) {
            revert TokenTransferFailed();
        }
    }
}
