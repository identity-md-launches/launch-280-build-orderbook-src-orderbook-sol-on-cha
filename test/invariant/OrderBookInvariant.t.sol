// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OrderBook} from "../../src/OrderBook.sol";
import {MockERC20} from "../helpers/MockERC20.sol";
import {TestBase, Vm} from "../helpers/TestBase.sol";

/// @dev Independent specification model: scans an append-only array for best price, breaking ties by ID.
/// It does not import production arithmetic, traverse production levels, or read production state to predict.
contract BookHandler is TestBase {
    struct ModelOrder {
        address maker;
        bool buy;
        uint256 price;
        uint256 amount;
        uint256 escrow;
        uint8 state; // 0 open, 1 filled, 2 cancelled
    }

    struct Trade {
        uint256 maker;
        uint256 price;
        uint256 amount;
        uint256 quote;
    }

    OrderBook public immutable book;
    MockERC20 public immutable base;
    MockERC20 public immutable quote;
    address[4] public actors = [address(0x101), address(0x102), address(0x103), address(0x104)];
    ModelOrder[] private model;
    mapping(address => uint256) private baseCredit;
    mapping(address => uint256) private quoteCredit;
    mapping(address => uint256) private baseWallet;
    mapping(address => uint256) private quoteWallet;
    uint256 private donatedBase;
    uint256 private donatedQuote;
    uint256 private constant INITIAL = 1e30;
    bytes32 private constant FILL = keccak256("Filled(uint256,uint256,uint256,uint256,uint256)");

    constructor(OrderBook book_, MockERC20 base_, MockERC20 quote_) {
        book = book_;
        base = base_;
        quote = quote_;
        model.push(); // Order IDs start at one.
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            base.mint(actor, INITIAL);
            quote.mint(actor, INITIAL);
            baseWallet[actor] = INITIAL;
            quoteWallet[actor] = INITIAL;
            vm.startPrank(actor);
            base.approve(address(book), type(uint256).max);
            quote.approve(address(book), type(uint256).max);
            vm.stopPrank();
        }
    }

    function place(uint256 who, bool buy, uint256 priceSeed, uint256 amountSeed, bool ioc) external {
        address actor = actors[who % actors.length];
        // Forty prices keep stateful insertions within the walk budget; dedicated tests cover its boundary.
        uint256 price = (1 + priceSeed % 40) * 1e16;
        uint256 amount = 100 + amountSeed % 1901;
        uint256 id = model.length;
        (Trade[32] memory trades, uint256 count) = _predictPlace(actor, buy, price, amount, ioc);
        vm.recordLogs();
        vm.prank(actor);
        assertEq(book.place(buy, price, amount, ioc), id);
        _compareTrades(vm.getRecordedLogs(), trades, count, id);
    }

    function cancel(uint256 who, uint256 idSeed) external {
        uint256 id = idSeed % (model.length + 2);
        bool exists = id > 0 && id < model.length;
        address actor = exists && who % 2 == 0 ? model[id].maker : actors[who % actors.length];
        vm.prank(actor);
        if (!exists || model[id].maker != actor) vm.expectRevert(OrderBook.NotMaker.selector);
        else if (model[id].state != 0) vm.expectRevert(OrderBook.NotOpen.selector);
        book.cancel(id);
        if (exists && model[id].maker == actor && model[id].state == 0) _close(id);
    }

    function withdraw(uint256 who, bool quoteToken) external {
        _withdraw(actors[who % actors.length], quoteToken);
    }

    function donate(uint256 who, bool quoteToken, uint256 seed) external {
        address actor = actors[who % actors.length];
        uint256 amount = seed % 1001;
        if (quoteToken) {
            quoteWallet[actor] -= amount;
            donatedQuote += amount;
        } else {
            baseWallet[actor] -= amount;
            donatedBase += amount;
        }
        vm.prank(actor);
        assertTrue((quoteToken ? quote : base).transfer(address(book), amount));
    }

    function _predictPlace(address actor, bool buy, uint256 price, uint256 amount, bool ioc)
        private
        returns (Trade[32] memory trades, uint256 count)
    {
        // Inputs are bounded so a plain multiply/divide is independent of production full-precision math.
        uint256 escrow = buy ? (amount * price + 1e18 - 1) / 1e18 : 0;
        if (buy) quoteWallet[actor] -= escrow;
        else baseWallet[actor] -= amount;
        uint256 id = model.length;
        model.push(ModelOrder(actor, buy, price, amount, escrow, 0));
        ModelOrder storage incoming = model[id];
        while (incoming.amount >= 100 && count < 32) {
            uint256 chosen = _bestMatch(id);
            if (chosen == 0) break;
            trades[count++] = _predictTrade(id, chosen);
        }
        if (incoming.amount < 100 || ioc || _bestMatch(id) != 0) _close(id);
    }

    function _predictTrade(uint256 id, uint256 chosen) private returns (Trade memory trade) {
        ModelOrder storage incoming = model[id];
        ModelOrder storage resting = model[chosen];
        uint256 size = incoming.amount < resting.amount ? incoming.amount : resting.amount;
        uint256 paid = size * resting.price / 1e18;
        trade = Trade(chosen, resting.price, size, paid);
        incoming.amount -= size;
        resting.amount -= size;
        if (incoming.buy) {
            incoming.escrow -= paid;
            baseCredit[incoming.maker] += size;
            quoteCredit[resting.maker] += paid;
        } else {
            resting.escrow -= paid;
            baseCredit[resting.maker] += size;
            quoteCredit[incoming.maker] += paid;
        }
        if (resting.amount < 100) _close(chosen);
    }

    function _bestMatch(uint256 incomingId) private view returns (uint256 selected) {
        ModelOrder storage incoming = model[incomingId];
        for (uint256 i = 1; i < incomingId; ++i) {
            ModelOrder storage candidate = model[i];
            if (candidate.state != 0 || candidate.buy == incoming.buy) continue;
            if (incoming.buy ? candidate.price > incoming.price : candidate.price < incoming.price) continue;
            // Strict comparison leaves equal-priced older orders selected.
            if (
                selected == 0
                    || (incoming.buy
                            ? candidate.price < model[selected].price
                            : candidate.price > model[selected].price)
            ) selected = i;
        }
    }

    function _close(uint256 id) private {
        ModelOrder storage item = model[id];
        item.state = item.amount == 0 ? 1 : 2;
        if (item.buy) quoteCredit[item.maker] += item.escrow;
        else baseCredit[item.maker] += item.amount;
        item.amount = 0;
        item.escrow = 0;
    }

    function _withdraw(address actor, bool quoteToken) private {
        uint256 expected;
        if (quoteToken) {
            expected = quoteCredit[actor];
            quoteCredit[actor] = 0;
            quoteWallet[actor] += expected;
        } else {
            expected = baseCredit[actor];
            baseCredit[actor] = 0;
            baseWallet[actor] += expected;
        }
        vm.prank(actor);
        assertEq(book.withdraw(quoteToken ? address(quote) : address(base)), expected);
    }

    function _compareTrades(Vm.Log[] memory logs, Trade[32] memory trades, uint256 count, uint256 incoming)
        private
        view
    {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(book) || logs[i].topics[0] != FILL) continue;
            require(seen < count, "unexpected fill");
            Trade memory expected = trades[seen++];
            assertEq(uint256(logs[i].topics[1]), expected.maker);
            assertEq(uint256(logs[i].topics[2]), incoming);
            (uint256 price, uint256 amount, uint256 paid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertEq(price, expected.price);
            assertEq(amount, expected.amount);
            assertEq(paid, expected.quote);
            require(amount >= 100 && paid > 0, "dust fill");
        }
        assertEq(seen, count);
        require(seen <= 32, "fill budget");
    }

    function assertAll() public view {
        assertEq(book.nextOrderId(), model.length);
        uint256 baseLiability;
        uint256 quoteLiability;
        uint256 openCount;
        uint256 bid;
        uint256 ask;
        for (uint256 id = 1; id < model.length; ++id) {
            ModelOrder storage expected = model[id];
            (
                address maker,
                bool buy,
                uint256 price,
                uint256 amount,
                uint256 escrow,
                OrderBook.Status status
            ) = book.order(id);
            assertEq(maker, expected.maker);
            assertTrue(buy == expected.buy);
            assertEq(price, expected.price);
            assertEq(amount, expected.amount);
            assertEq(escrow, expected.escrow);
            assertEq(uint256(status), expected.state);
            if (status == OrderBook.Status.Open) {
                ++openCount;
                require(amount >= 100 && price % 1e16 == 0, "invalid resting order");
                if (buy) {
                    quoteLiability += escrow;
                    require(escrow >= (amount * price + 1e18 - 1) / 1e18, "underfunded bid");
                    if (price > bid) bid = price;
                } else {
                    baseLiability += amount;
                    assertEq(escrow, 0);
                    if (ask == 0 || price < ask) ask = price;
                }
            } else {
                (uint256 prev, uint256 next) = book.orderLinks(id);
                assertEq(amount + escrow + prev + next, 0);
            }
        }
        assertEq(book.bestBid(), bid);
        assertEq(book.bestAsk(), ask);
        require(bid == 0 || ask == 0 || bid < ask, "crossed book");
        assertEq(_checkLevels(true, bid) + _checkLevels(false, ask), openCount);
        uint256 walletBaseSum;
        uint256 walletQuoteSum;
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            assertEq(book.claimable(actor, address(base)), baseCredit[actor]);
            assertEq(book.claimable(actor, address(quote)), quoteCredit[actor]);
            assertEq(base.balanceOf(actor), baseWallet[actor]);
            assertEq(quote.balanceOf(actor), quoteWallet[actor]);
            baseLiability += baseCredit[actor];
            quoteLiability += quoteCredit[actor];
            walletBaseSum += baseWallet[actor];
            walletQuoteSum += quoteWallet[actor];
        }
        assertEq(base.balanceOf(address(book)), baseLiability + donatedBase);
        assertEq(quote.balanceOf(address(book)), quoteLiability + donatedQuote);
        assertEq(walletBaseSum + base.balanceOf(address(book)), INITIAL * actors.length);
        assertEq(walletQuoteSum + quote.balanceOf(address(book)), INITIAL * actors.length);
    }

    function _checkLevels(bool buy, uint256 cursor) private view returns (uint256 ordersSeen) {
        uint256 previous;
        uint256 levelsSeen;
        while (cursor != 0) {
            require(++levelsSeen < model.length, "level cycle");
            (uint256 prev, uint256 next, uint256 head, uint256 tail) = book.level(buy, cursor);
            assertEq(prev, previous);
            assertEq(book.nextLevel(buy, cursor), next);
            require(head != 0 && tail != 0, "empty linked level");
            if (previous != 0) require(buy ? previous > cursor : previous < cursor, "price ordering");
            uint256 priorOrder;
            while (head != 0) {
                require(head < model.length && ++ordersSeen < model.length, "order cycle");
                ModelOrder storage expected = model[head];
                require(
                    expected.state == 0 && expected.buy == buy && expected.price == cursor, "queue member"
                );
                (uint256 orderPrev, uint256 orderNext) = book.orderLinks(head);
                assertEq(orderPrev, priorOrder);
                require(head > priorOrder, "FIFO ordering");
                priorOrder = head;
                head = orderNext;
            }
            assertEq(priorOrder, tail);
            previous = cursor;
            cursor = next;
        }
        // Every absent price must also have completely deleted links and queue endpoints.
        for (uint256 price = 1e16; price <= 40e16; price += 1e16) {
            bool exists;
            for (uint256 id = 1; id < model.length; ++id) {
                if (model[id].state == 0 && model[id].buy == buy && model[id].price == price) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                (uint256 prev, uint256 next, uint256 head, uint256 tail) = book.level(buy, price);
                assertEq(prev + next + head + tail, 0);
            }
        }
    }

    /// @dev End-of-sequence liveness: all liabilities can be cancelled and withdrawn, leaving only gifts.
    function closeAndWithdrawAll() external {
        for (uint256 id = 1; id < model.length; ++id) {
            if (model[id].state != 0) continue;
            vm.prank(model[id].maker);
            book.cancel(id);
            _close(id);
        }
        for (uint256 i; i < actors.length; ++i) {
            _withdraw(actors[i], false);
            _withdraw(actors[i], true);
        }
        assertAll();
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
        assertEq(base.balanceOf(address(book)), donatedBase);
        assertEq(quote.balanceOf(address(book)), donatedQuote);
    }
}

contract OrderBookInvariantTest {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    BookHandler private handler;

    function setUp() public {
        MockERC20 base = new MockERC20("Invariant Base", "IBASE");
        MockERC20 quote = new MockERC20("Invariant Quote", "IQUOTE");
        OrderBook book = new OrderBook(address(base), address(quote), 1e16, 100);
        handler = new BookHandler(book, base, quote);
    }

    function targetContracts() external view returns (address[] memory result) {
        result = new address[](1);
        result[0] = address(handler);
    }

    function targetSelectors() external view returns (FuzzSelector[] memory result) {
        result = new FuzzSelector[](1);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = BookHandler.place.selector;
        selectors[1] = BookHandler.cancel.selector;
        selectors[2] = BookHandler.withdraw.selector;
        selectors[3] = BookHandler.donate.selector;
        result[0] = FuzzSelector(address(handler), selectors);
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 100
    function invariant_matchesModelStructuresAndConservation() public view {
        handler.assertAll();
    }

    function afterInvariant() public {
        handler.closeAndWithdrawAll();
    }
}
