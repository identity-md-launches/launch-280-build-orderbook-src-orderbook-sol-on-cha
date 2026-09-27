// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OrderBook} from "../../src/OrderBook.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {TestBase} from "../helpers/TestBase.sol";

/// @dev Only observation helpers are shared. No production storage access or matching model is used.
abstract contract BookObservation is TestBase {
    uint256 internal constant TICK = 3e16;
    uint256 internal constant MIN = 34; // ceil(1e18 / TICK), deliberately not an exact division.
    uint256 internal constant PRICES = 9;
    uint256 internal constant INITIAL = 1e24;

    struct ObservedOrder {
        address maker;
        bool buy;
        uint256 price;
        uint256 remaining;
        uint256 escrow;
        OrderBook.Status status;
    }

    function _read(OrderBook book, uint256 id) internal view returns (ObservedOrder memory o) {
        (o.maker, o.buy, o.price, o.remaining, o.escrow, o.status) = book.order(id);
    }
}

/// @dev Ghost state records submitted orders and external cash flows, never predicted matching state.
/// Only the four explicit action selectors below are targeted; tokens cannot be minted or donated mid-run.
contract SolvencyHandler is BookObservation {
    struct Submission {
        address maker;
        bool buy;
        uint256 price;
        uint256 amount;
        bool ioc;
    }

    OrderBook public immutable book;
    MockERC20 public immutable base;
    MockERC20 public immutable quote;
    address[5] public actors =
        [address(0x201), address(0x202), address(0x203), address(0x204), address(0x205)];
    Submission[] private submissions;
    mapping(address => mapping(address => uint256)) public deposited;
    mapping(address => mapping(address => uint256)) public withdrawn;
    uint256 public paidWithdrawals;

    constructor(OrderBook book_, MockERC20 base_, MockERC20 quote_) {
        book = book_;
        base = base_;
        quote = quote_;
        submissions.push();
        for (uint256 i; i < actors.length; ++i) {
            base.mint(actors[i], INITIAL);
            quote.mint(actors[i], INITIAL);
            vm.startPrank(actors[i]);
            base.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            vm.stopPrank();
        }
    }

    function count() external view returns (uint256) {
        return submissions.length - 1;
    }

    function submission(uint256 id) external view returns (Submission memory) {
        return submissions[id];
    }

    function place(uint256 who, bool buy, uint256 priceSeed, uint256 sizeSeed, bool ioc) external {
        address actor = actors[who % actors.length];
        uint256 price = (1 + priceSeed % PRICES) * TICK;
        // Small odd sizes exercise partial fills, maker/taker dust and quote rounding frequently.
        uint256 amount = MIN + sizeSeed % (8 * MIN + 1);
        MockERC20 token = buy ? quote : base;
        uint256 deposit = buy ? (amount * price + 1e18 - 1) / 1e18 : amount;
        uint256 assetsBefore = token.balanceOf(address(book));
        uint256 transfersBefore = base.transferCalls() + quote.transferCalls();
        vm.prank(actor);
        uint256 id = book.place(buy, price, amount, ioc);
        assertEq(id, submissions.length);
        submissions.push(Submission(actor, buy, price, amount, ioc));
        deposited[actor][address(token)] += deposit;
        assertEq(token.balanceOf(address(book)), assetsBefore + deposit);
        assertEq(base.transferCalls() + quote.transferCalls(), transfersBefore);
    }

    function cancel(uint256 idSeed, uint256 callerSeed) external {
        uint256 id = idSeed % (submissions.length + 2);
        bool exists = id != 0 && id < submissions.length;
        ObservedOrder memory o = _read(book, id);
        address actor = actors[callerSeed % actors.length];
        // Half the calls use the recorded maker, the other half try an unrelated actor.
        if (exists && callerSeed % 2 == 0) {
            actor = submissions[id].maker;
        } else if (exists && actor == submissions[id].maker) {
            actor = actors[(callerSeed % actors.length + 1) % actors.length];
        }
        address token = o.buy ? address(quote) : address(base);
        uint256 creditBefore = book.claimable(actor, token);
        if (!exists || actor != submissions[id].maker) {
            vm.expectRevert(OrderBook.NotMaker.selector);
        } else if (o.status != OrderBook.Status.Open) {
            vm.expectRevert(OrderBook.NotOpen.selector);
        }
        vm.prank(actor);
        book.cancel(id);
        if (exists && actor == submissions[id].maker && o.status == OrderBook.Status.Open) {
            assertEq(book.claimable(actor, token), creditBefore + (o.buy ? o.escrow : o.remaining));
            assertEq(uint256(_read(book, id).status), uint256(OrderBook.Status.Cancelled));
        }
    }

    function withdraw(uint256 who, bool quoteToken) external {
        _withdraw(actors[who % actors.length], quoteToken ? quote : base);
    }

    function _withdraw(address actor, MockERC20 token) private {
        uint256 claim = book.claimable(actor, address(token));
        uint256 walletBefore = token.balanceOf(actor);
        uint256 bookBefore = token.balanceOf(address(book));
        uint256 transfersBefore = token.transferCalls();
        vm.prank(actor);
        assertEq(book.withdraw(address(token)), claim);
        assertEq(token.balanceOf(actor), walletBefore + claim);
        assertEq(token.balanceOf(address(book)), bookBefore - claim);
        assertEq(book.claimable(actor, address(token)), 0);
        withdrawn[actor][address(token)] += claim;
        if (claim != 0) ++paidWithdrawals;
        // Repeating immediately must pay nothing and must not call the token.
        vm.prank(actor);
        assertEq(book.withdraw(address(token)), 0);
        assertEq(token.balanceOf(actor), walletBefore + claim);
        assertEq(token.transferCalls(), transfersBefore + (claim == 0 ? 0 : 1));
    }

    /// @dev Exact errors are required; unexpected reverts are never swallowed by try/catch.
    function reject(uint256 who, bool buy, uint256 kindSeed) external {
        address actor = actors[who % actors.length];
        uint256 kind = kindSeed % 9;
        MockERC20 token = buy ? quote : base;
        bytes32 beforeState = fingerprint();
        uint256 price = TICK;
        uint256 amount = MIN;
        bytes4 errorSelector;
        if (kind < 2) {
            price = kind == 0 ? 0 : TICK + 1;
            errorSelector = OrderBook.InvalidPrice.selector;
        } else if (kind == 2) {
            amount = MIN - 1;
            errorSelector = OrderBook.AmountTooSmall.selector;
        } else if (kind == 3 || kind == 4) {
            token.setMode(kind == 3 ? MockERC20.Mode.Fee : MockERC20.Mode.Bonus);
            errorSelector = OrderBook.InexactDeposit.selector;
        } else if (kind == 5 || kind == 6) {
            token.setMode(kind == 5 ? MockERC20.Mode.FalseReturn : MockERC20.Mode.RevertTransfer);
            errorSelector = OrderBook.TokenTransferFailed.selector;
        } else if (kind == 7) {
            vm.prank(actor);
            token.approve(address(book), 0);
            errorSelector = OrderBook.TokenTransferFailed.selector;
        } else {
            errorSelector = OrderBook.InvalidToken.selector;
        }
        vm.expectRevert(errorSelector);
        vm.prank(actor);
        if (kind == 8) book.withdraw(address(0xBAD));
        else book.place(buy, price, amount, false);
        token.setMode(MockERC20.Mode.Normal);
        if (kind == 7) {
            vm.prank(actor);
            token.approve(address(book), type(uint256).max);
        }
        require(fingerprint() == beforeState, "rejected call changed book, claims or tokens");
    }

    function fingerprint() public view returns (bytes32 digest) {
        digest = keccak256(abi.encode(book.nextOrderId(), book.bestBid(), book.bestAsk()));
        for (uint256 id = 1; id < submissions.length; ++id) {
            (uint256 prev, uint256 next) = book.orderLinks(id);
            digest = keccak256(abi.encode(digest, _read(book, id), prev, next));
        }
        for (uint256 p = 1; p <= PRICES; ++p) {
            for (uint256 side; side < 2; ++side) {
                (uint256 prev, uint256 next, uint256 head, uint256 tail) = book.level(side == 1, p * TICK);
                digest = keccak256(abi.encode(digest, prev, next, head, tail));
            }
        }
        for (uint256 side; side < 2; ++side) {
            MockERC20 token = side == 0 ? base : quote;
            digest = keccak256(
                abi.encode(
                    digest,
                    token.balanceOf(address(book)),
                    token.totalSupply(),
                    token.transferCalls(),
                    token.transferFromCalls()
                )
            );
            for (uint256 i; i < actors.length; ++i) {
                digest = keccak256(
                    abi.encode(
                        digest,
                        token.balanceOf(actors[i]),
                        token.allowance(actors[i], address(book)),
                        book.claimable(actors[i], address(token))
                    )
                );
            }
        }
    }

    function drain() external {
        for (uint256 id = 1; id < submissions.length; ++id) {
            if (_read(book, id).status != OrderBook.Status.Open) continue;
            vm.prank(submissions[id].maker);
            book.cancel(id);
        }
        for (uint256 i; i < actors.length; ++i) {
            _withdraw(actors[i], base);
            _withdraw(actors[i], quote);
        }
    }
}

contract OrderBookSolvencyInvariantTest is BookObservation {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    OrderBook private book;
    MockERC20 private base;
    MockERC20 private quote;
    SolvencyHandler private handler;

    function setUp() public {
        base = new MockERC20("Solvency Base", "SBASE");
        quote = new MockERC20("Solvency Quote", "SQUOTE");
        book = new OrderBook(address(base), address(quote), TICK, MIN);
        handler = new SolvencyHandler(book, base, quote);
    }

    function targetContracts() external view returns (address[] memory result) {
        result = new address[](1);
        result[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory result) {
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SolvencyHandler.place.selector;
        selectors[1] = SolvencyHandler.cancel.selector;
        selectors[2] = SolvencyHandler.withdraw.selector;
        selectors[3] = SolvencyHandler.reject.selector;
        result = new FuzzSelector[](1);
        result[0] = FuzzSelector(address(handler), selectors);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_exactSolvencyAndReachableFIFO() public view {
        _assertBook();
    }

    function _assertBook() private view {
        uint256 count = handler.count();
        assertEq(book.nextOrderId(), count + 1);
        bool[] memory reachable = new bool[](count + 1);
        _walk(true, reachable);
        _walk(false, reachable);
        uint256 baseLiability;
        uint256 quoteLiability;
        uint256 bid;
        uint256 ask;
        for (uint256 id = 1; id <= count; ++id) {
            ObservedOrder memory o = _read(book, id);
            SolvencyHandler.Submission memory submitted = handler.submission(id);
            assertEq(o.maker, submitted.maker);
            assertTrue(o.buy == submitted.buy);
            assertEq(o.price, submitted.price);
            if (o.status == OrderBook.Status.Open) {
                require(reachable[id], "open order absent from queues");
                require(!submitted.ioc, "IOC rested");
                require(o.remaining >= MIN && o.remaining <= submitted.amount, "invalid resting size");
                if (o.buy) {
                    quoteLiability += o.escrow;
                    require(o.escrow >= (o.remaining * o.price + 1e18 - 1) / 1e18, "underfunded buy");
                    if (o.price > bid) bid = o.price;
                } else {
                    baseLiability += o.remaining;
                    assertEq(o.escrow, 0);
                    if (ask == 0 || o.price < ask) ask = o.price;
                }
            } else {
                require(!reachable[id], "closed order still linked");
                assertEq(o.remaining, 0);
                assertEq(o.escrow, 0);
                (uint256 prev, uint256 next) = book.orderLinks(id);
                assertEq(prev, 0);
                assertEq(next, 0);
            }
        }
        assertEq(book.bestBid(), bid);
        assertEq(book.bestAsk(), ask);
        require(bid == 0 || ask == 0 || bid < ask, "crossed book");
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            baseLiability += book.claimable(actor, address(base));
            quoteLiability += book.claimable(actor, address(quote));
        }
        // These are exact specification equations, with no donation or unexplained-surplus allowance.
        assertEq(base.balanceOf(address(book)), baseLiability);
        assertEq(quote.balanceOf(address(book)), quoteLiability);
        _assertCashFlows(base);
        _assertCashFlows(quote);
        assertEq(base.transferCalls() + quote.transferCalls(), handler.paidWithdrawals());
    }

    function _assertCashFlows(MockERC20 token) private view {
        uint256 netDeposited;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            uint256 incoming = handler.deposited(actor, address(token));
            uint256 outgoing = handler.withdrawn(actor, address(token));
            assertEq(token.balanceOf(actor), INITIAL + outgoing - incoming);
            netDeposited += incoming;
        }
        for (uint256 i; i < 5; ++i) {
            netDeposited -= handler.withdrawn(handler.actors(i), address(token));
        }
        assertEq(token.balanceOf(address(book)), netDeposited);
        assertEq(token.totalSupply(), 5 * INITIAL);
    }

    function _walk(bool buy, bool[] memory reachable) private view {
        bool[] memory seenPrices = new bool[](PRICES + 1);
        uint256 price = buy ? book.bestBid() : book.bestAsk();
        uint256 previous;
        while (price != 0) {
            require(price % TICK == 0 && price / TICK <= PRICES, "unexpected level price");
            uint256 index = price / TICK;
            require(!seenPrices[index], "level cycle");
            seenPrices[index] = true;
            (uint256 prev, uint256 next, uint256 head, uint256 tail) = book.level(buy, price);
            assertEq(prev, previous);
            assertEq(next, book.nextLevel(buy, price));
            require(head != 0 && tail != 0, "empty linked level");
            if (previous != 0) require(buy ? previous > price : previous < price, "level sorting");
            uint256 previousId;
            while (head != 0) {
                require(head < reachable.length && !reachable[head], "duplicate or unknown order");
                reachable[head] = true;
                ObservedOrder memory o = _read(book, head);
                require(o.status == OrderBook.Status.Open && o.buy == buy && o.price == price, "wrong queue");
                (uint256 orderPrev, uint256 orderNext) = book.orderLinks(head);
                assertEq(orderPrev, previousId);
                require(head > previousId, "queue out of placement order");
                previousId = head;
                head = orderNext;
            }
            assertEq(previousId, tail);
            previous = price;
            price = next;
        }
        for (uint256 p = 1; p <= PRICES; ++p) {
            if (seenPrices[p]) continue;
            (uint256 prev, uint256 next, uint256 head, uint256 tail) = book.level(buy, p * TICK);
            require(prev == 0 && next == 0 && head == 0 && tail == 0, "orphaned level metadata");
        }
    }

    function afterInvariant() public {
        handler.drain();
        _assertBook();
        assertEq(base.balanceOf(address(book)), 0);
        assertEq(quote.balanceOf(address(book)), 0);
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
    }

    /// @dev Deterministically exercise each rejection in populated state, regardless of fuzz distribution.
    function testRejectedActionsPreserveLiveBookAndCredits() public {
        handler.place(0, false, 1, 3 * MIN, false);
        handler.place(1, true, 1, 0, false); // Partial fill leaves an ask and withdrawable credits.
        handler.place(2, true, 0, MIN, false); // Non-crossing bid.
        for (uint256 kind; kind < 9; ++kind) {
            handler.reject(0, false, kind);
            handler.reject(2, true, kind);
            _assertBook();
        }
        handler.withdraw(0, true);
        handler.withdraw(1, false);
        handler.cancel(1, 1); // Wrong maker.
        handler.cancel(1, 0); // Correct maker.
        handler.cancel(1, 0); // Closed order.
        handler.cancel(2, 0); // Filled order, by its maker.
        handler.cancel(0, 0); // Unknown ID.
        _assertBook();
        afterInvariant();
    }
}
