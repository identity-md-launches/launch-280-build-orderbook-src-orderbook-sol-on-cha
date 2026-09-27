// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OrderBook} from "../src/OrderBook.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {TestBase, Vm} from "./helpers/TestBase.sol";

contract OrderBookTest is TestBase {
    MockERC20 internal base;
    MockERC20 internal quote;
    OrderBook internal book;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA401);
    uint256 internal constant START = 1e36;
    uint256 internal constant TICK = 1e16;
    uint256 internal constant MIN = 100;
    bytes32 internal constant FILL = keccak256("Filled(uint256,uint256,uint256,uint256,uint256)");

    function setUp() public {
        base = new MockERC20("Base", "BASE");
        quote = new MockERC20("Quote", "QUOTE");
        book = new OrderBook(address(base), address(quote), TICK, MIN);
        _fund(ALICE);
        _fund(BOB);
        _fund(CAROL);
    }

    function _fund(address actor) internal {
        base.mint(actor, START);
        quote.mint(actor, START);
        vm.startPrank(actor);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function _place(address actor, bool buy, uint256 price, uint256 amount, bool ioc)
        internal
        returns (uint256)
    {
        vm.prank(actor);
        return book.place(buy, price, amount, ioc);
    }

    function _cancel(address actor, uint256 id) internal {
        vm.prank(actor);
        book.cancel(id);
    }

    function _check(uint256 id, uint256 remaining, uint256 escrow, OrderBook.Status expected) internal view {
        (,,, uint256 actualRemaining, uint256 actualEscrow, OrderBook.Status actualStatus) = book.order(id);
        assertEq(actualRemaining, remaining);
        assertEq(actualEscrow, escrow);
        assertEq(uint256(actualStatus), uint256(expected));
    }

    function testConstructorAndEmptyViews() public view {
        assertEq(book.base(), address(base));
        assertEq(book.quote(), address(quote));
        assertEq(book.tickSize(), TICK);
        assertEq(book.minBaseAmount(), MIN);
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
        assertEq(book.nextOrderId(), 1);
        assertEq(book.nextLevel(true, 1), 0);
        (address maker,,,,,) = book.order(99);
        assertEq(maker, address(0));
    }

    function testInvalidConstructors() public {
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(0), address(quote), TICK, MIN);
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(base), address(0), TICK, MIN);
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(base), address(base), TICK, MIN);
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(base), address(quote), 0, MIN);
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(base), address(quote), TICK, 0);
        vm.expectRevert(OrderBook.InvalidConfiguration.selector);
        new OrderBook(address(base), address(quote), TICK, MIN - 1);
        // The constructor comparison supports mathematically valid products wider than 256 bits.
        OrderBook huge = new OrderBook(address(base), address(quote), type(uint256).max, type(uint256).max);
        assertEq(huge.tickSize(), type(uint256).max);
    }

    function testInvalidOrdersAndMissingAllowance() public {
        vm.startPrank(ALICE);
        vm.expectRevert(OrderBook.InvalidPrice.selector);
        book.place(true, 0, MIN, false);
        vm.expectRevert(OrderBook.InvalidPrice.selector);
        book.place(false, TICK + 1, MIN, false);
        vm.expectRevert(OrderBook.AmountTooSmall.selector);
        book.place(true, TICK, MIN - 1, false);
        quote.approve(address(book), 0);
        vm.expectRevert(OrderBook.TokenTransferFailed.selector);
        book.place(true, TICK, MIN, false);
        vm.stopPrank();
        assertEq(book.nextOrderId(), 1);
    }

    function testFilledOnEntryNeverRestsAndUsesMakerPrice() public {
        _place(BOB, false, 2e18, 1e18, false);
        uint256 id = _place(ALICE, true, 3e18, 1e18, false);
        assertEq(id, 2);
        _check(1, 0, 0, OrderBook.Status.Filled);
        _check(2, 0, 0, OrderBook.Status.Filled);
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
        assertEq(book.claimable(ALICE, address(base)), 1e18);
        assertEq(book.claimable(ALICE, address(quote)), 1e18);
        assertEq(book.claimable(BOB, address(quote)), 2e18);
        assertEq(base.balanceOf(ALICE), START);
        assertEq(quote.balanceOf(BOB), START);
        assertEq(base.transferCalls(), 0);
        assertEq(quote.transferCalls(), 0);
    }

    function testCrossesSeveralLevelsInPriceTimeOrder() public {
        _place(BOB, false, 3e18, 1e18, false);
        _place(CAROL, false, 2e18, 1e18, false);
        _place(BOB, false, 2e18, 1e18, false);
        vm.recordLogs();
        _place(ALICE, true, 3e18, 25e17, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256[] memory expected = new uint256[](3);
        expected[0] = 2;
        expected[1] = 3;
        expected[2] = 1;
        _checkFills(logs, expected, 4);
        _check(1, 5e17, 0, OrderBook.Status.Open);
        _check(4, 0, 0, OrderBook.Status.Filled);
        assertEq(book.bestAsk(), 3e18);
        assertEq(book.claimable(ALICE, address(quote)), 2e18);
        assertEq(book.claimable(ALICE, address(base)), 25e17);
    }

    function testSellTakerBestBidFirstAndPartialBuyRefund() public {
        _place(BOB, true, 2e18, 1e18, false);
        _place(CAROL, true, 3e18, 1e18, false);
        _place(BOB, true, 3e18, 1e18, false);
        vm.recordLogs();
        _place(ALICE, false, 2e18, 25e17, false);
        uint256[] memory expected = new uint256[](3);
        expected[0] = 2;
        expected[1] = 3;
        expected[2] = 1;
        _checkFills(vm.getRecordedLogs(), expected, 4);
        _check(1, 5e17, 1e18, OrderBook.Status.Open);
        assertEq(book.claimable(ALICE, address(quote)), 7e18);
        _cancel(BOB, 1);
        assertEq(book.claimable(BOB, address(quote)), 1e18);
        assertEq(book.bestBid(), 0);
    }

    function _checkFills(Vm.Log[] memory logs, uint256[] memory makers, uint256 taker) internal view {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(book) || logs[i].topics[0] != FILL) continue;
            assertEq(uint256(logs[i].topics[1]), makers[count++]);
            assertEq(uint256(logs[i].topics[2]), taker);
            (uint256 price, uint256 amount, uint256 paid) =
                abi.decode(logs[i].data, (uint256, uint256, uint256));
            assertTrue(amount >= MIN);
            assertEq(paid, amount * price / 1e18);
            assertTrue(paid > 0);
        }
        assertEq(count, makers.length);
    }

    function testFuzzFillCapReleasesCrossingRemainder(bool buy) public {
        for (uint256 i; i < 33; ++i) {
            _place(BOB, !buy, 1e18, MIN, false);
        }
        vm.recordLogs();
        uint256 id = _place(ALICE, buy, 1e18, 34 * MIN, false);
        uint256[] memory expected = new uint256[](32);
        for (uint256 i; i < 32; ++i) {
            expected[i] = i + 1;
        }
        _checkFills(vm.getRecordedLogs(), expected, id);
        _check(33, MIN, buy ? 0 : MIN, OrderBook.Status.Open);
        _check(id, 0, 0, OrderBook.Status.Cancelled);
        assertEq(buy ? book.bestBid() : book.bestAsk(), 0);
        assertEq(buy ? book.bestAsk() : book.bestBid(), 1e18);
        assertEq(book.claimable(ALICE, buy ? address(quote) : address(base)), 2 * MIN);
    }

    function testFuzzFillCapMayRestUncrossedRemainder(bool buy) public {
        for (uint256 i; i < 32; ++i) {
            _place(BOB, !buy, 2e18, MIN, false);
        }
        _place(BOB, !buy, buy ? 3e18 : 1e18, MIN, false);
        uint256 id = _place(ALICE, buy, 2e18, 33 * MIN, false);
        _check(id, MIN, buy ? 2 * MIN : 0, OrderBook.Status.Open);
        assertEq(buy ? book.bestBid() : book.bestAsk(), 2e18);
        assertTrue(book.bestBid() < book.bestAsk());
    }

    function testFuzzIOCEmptyAndPartial(bool buy) public {
        uint256 id = _place(ALICE, buy, 1e18, MIN, true);
        _check(id, 0, 0, OrderBook.Status.Cancelled);
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
        _place(BOB, !buy, 1e18, MIN, false);
        id = _place(ALICE, buy, 1e18, 2 * MIN, true);
        _check(id, 0, 0, OrderBook.Status.Cancelled);
        assertEq(book.claimable(ALICE, buy ? address(quote) : address(base)), 2 * MIN);
    }

    function testFuzzMakerDustReleased(bool buyMaker) public {
        _place(BOB, buyMaker, TICK, MIN + 1, false);
        _place(ALICE, !buyMaker, TICK, MIN, false);
        _check(1, 0, 0, OrderBook.Status.Cancelled);
        assertEq(book.claimable(BOB, buyMaker ? address(quote) : address(base)), 1);
        assertEq(book.bestBid(), 0);
        assertEq(book.bestAsk(), 0);
    }

    function testFuzzTakerDustCannotMakeZeroQuoteFill(bool buyTaker) public {
        _place(BOB, !buyTaker, TICK, MIN, false);
        _place(BOB, !buyTaker, TICK, MIN, false);
        vm.recordLogs();
        uint256 id = _place(ALICE, buyTaker, TICK, MIN + 1, false);
        uint256[] memory expected = new uint256[](1);
        expected[0] = 1;
        _checkFills(vm.getRecordedLogs(), expected, id);
        _check(2, MIN, buyTaker ? 0 : 1, OrderBook.Status.Open);
        _check(id, 0, 0, OrderBook.Status.Cancelled);
    }

    function testRoundingRefundForBuyMakerOnCompletion() public {
        _place(ALICE, true, 101e16, 202, false); // ceil(204.02) = 205
        _place(BOB, false, 1e18, 101, false); // floor(102.01) = 102
        _check(1, 101, 103, OrderBook.Status.Open);
        _place(CAROL, false, 1e18, 101, false);
        _check(1, 0, 0, OrderBook.Status.Filled);
        assertEq(book.claimable(ALICE, address(quote)), 1);
        assertEq(book.claimable(ALICE, address(base)), 202);
        assertEq(book.claimable(BOB, address(quote)), 102);
    }

    function testPartiallyFilledHeadRetainsPriority() public {
        _place(BOB, false, 1e18, 3 * MIN, false);
        _place(CAROL, false, 1e18, MIN, false);
        _place(ALICE, true, 1e18, MIN, false);
        _check(1, 2 * MIN, 0, OrderBook.Status.Open);
        vm.recordLogs();
        _place(ALICE, true, 1e18, 3 * MIN, false);
        uint256[] memory makers = new uint256[](2);
        makers[0] = 1;
        makers[1] = 2;
        _checkFills(vm.getRecordedLogs(), makers, 4);
    }

    function testSelfTradeConservesBothTokens() public {
        _place(ALICE, true, 101e16, 101, false);
        _place(ALICE, false, 1e18, 101, false);
        assertEq(book.claimable(ALICE, address(base)), 101);
        assertEq(book.claimable(ALICE, address(quote)), 103);
        vm.startPrank(ALICE);
        book.withdraw(address(base));
        book.withdraw(address(quote));
        vm.stopPrank();
        assertEq(base.balanceOf(ALICE), START);
        assertEq(quote.balanceOf(ALICE), START);
    }

    function testCancelAuthorizationAndClosedOrders() public {
        uint256 id = _place(ALICE, true, 1e18, MIN, false);
        vm.prank(BOB);
        vm.expectRevert(OrderBook.NotMaker.selector);
        book.cancel(id);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.NotMaker.selector);
        book.cancel(999);
        _cancel(ALICE, id);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.NotOpen.selector);
        book.cancel(id);
        _place(BOB, false, 1e18, MIN, false);
        id = _place(ALICE, true, 1e18, MIN, false);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.NotOpen.selector);
        book.cancel(id);
    }

    function testFuzzQueueMiddleHeadTailAndLevelReinsertion(bool buy) public {
        uint256 first = _place(ALICE, buy, 2e18, MIN, false);
        uint256 middle = _place(BOB, buy, 2e18, MIN, false);
        uint256 last = _place(CAROL, buy, 2e18, MIN, false);
        _cancel(BOB, middle);
        (uint256 prev, uint256 next) = book.orderLinks(first);
        assertEq(prev, 0);
        assertEq(next, last);
        _cancel(ALICE, first);
        (prev, next) = book.orderLinks(last);
        assertEq(prev, 0);
        assertEq(next, 0);
        _cancel(CAROL, last);
        uint256 head;
        uint256 tail;
        (prev, next, head, tail) = book.level(buy, 2e18);
        assertEq(prev + next + head + tail, 0);
        _place(ALICE, buy, 1e18, MIN, false);
        _place(ALICE, buy, 3e18, MIN, false);
        uint256 center = _place(ALICE, buy, 2e18, MIN, false);
        assertEq(book.nextLevel(buy, buy ? 3e18 : 1e18), 2e18);
        assertEq(book.nextLevel(buy, 2e18), buy ? 1e18 : 3e18);
        _cancel(ALICE, center);
        assertEq(book.nextLevel(buy, buy ? 3e18 : 1e18), buy ? 1e18 : 3e18);
    }

    function testFuzzLevelWalk64Succeeds65RevertsAtomically(bool buy) public {
        // Inserting progressively better levels allows arbitrarily many levels overall.
        for (uint256 i; i < 65; ++i) {
            _place(ALICE, buy, (buy ? i + 2 : 66 - i) * TICK, MIN, false);
        }
        uint256 balanceBefore = (buy ? quote : base).balanceOf(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.TooDeep.selector);
        book.place(buy, buy ? TICK : 67 * TICK, MIN, false);
        assertEq(book.nextOrderId(), 66);
        assertEq((buy ? quote : base).balanceOf(ALICE), balanceBefore);
        _cancel(ALICE, 65); // Exactly 64 better levels may now be walked.
        uint256 id = _place(ALICE, buy, buy ? TICK : 67 * TICK, MIN, false);
        assertEq(id, 66);
        // Appending to an existing deep level does not perform a new-level walk.
        _place(BOB, buy, buy ? TICK : 67 * TICK, MIN, false);
    }

    function testWithdrawAllOnlyCallerAndRetryFailure() public {
        uint256 id = _place(ALICE, false, 1e18, MIN, false);
        _cancel(ALICE, id);
        vm.prank(BOB);
        assertEq(book.withdraw(address(base)), 0);
        base.setMode(MockERC20.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.TokenTransferFailed.selector);
        book.withdraw(address(base));
        assertEq(book.claimable(ALICE, address(base)), MIN);
        assertEq(base.balanceOf(address(book)), MIN);
        base.setMode(MockERC20.Mode.Normal);
        vm.prank(ALICE);
        assertEq(book.withdraw(address(base)), MIN);
        vm.prank(ALICE);
        assertEq(book.withdraw(address(base)), 0);
        assertEq(base.balanceOf(ALICE), START);
        vm.expectRevert(OrderBook.InvalidToken.selector);
        book.withdraw(address(123));
    }

    function testFuzzInexactDepositsRejected(bool buy, bool bonus) public {
        MockERC20 token = buy ? quote : base;
        token.setMode(bonus ? MockERC20.Mode.Bonus : MockERC20.Mode.Fee);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.InexactDeposit.selector);
        book.place(buy, 1e18, MIN, false);
        assertEq(token.balanceOf(ALICE), START);
        assertEq(token.balanceOf(address(book)), 0);
        assertEq(book.nextOrderId(), 1);
    }

    function testFuzzFalseAndRevertingDepositsRollback(bool buy, bool reverts) public {
        MockERC20 token = buy ? quote : base;
        token.setMode(reverts ? MockERC20.Mode.RevertTransfer : MockERC20.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(OrderBook.TokenTransferFailed.selector);
        book.place(buy, 1e18, MIN, false);
        assertEq(token.balanceOf(ALICE), START);
        assertEq(book.nextOrderId(), 1);
    }

    function testFuzzNoReturnTokensSupported(bool buy) public {
        MockERC20 token = buy ? quote : base;
        token.setMode(MockERC20.Mode.NoReturn);
        uint256 id = _place(ALICE, buy, 1e18, MIN, false);
        _cancel(ALICE, id);
        vm.prank(ALICE);
        book.withdraw(address(token));
        assertEq(token.balanceOf(ALICE), START);
    }

    function testFuzzReentrancyBlockedOnDepositAndWithdrawal(uint8 operation) public {
        bytes memory data;
        if (operation % 3 == 0) data = abi.encodeCall(book.place, (false, 1e18, MIN, false));
        else if (operation % 3 == 1) data = abi.encodeCall(book.cancel, (1));
        else data = abi.encodeCall(book.withdraw, (address(base)));
        base.setCallback(address(book), data);
        uint256 id = _place(ALICE, false, 1e18, MIN, false);
        assertTrue(!base.callbackSucceeded());
        assertEq(uint256(uint32(base.callbackError())), uint256(uint32(OrderBook.ReentrantCall.selector)));
        _cancel(ALICE, id);
        vm.prank(ALICE);
        book.withdraw(address(base));
        assertTrue(!base.callbackSucceeded());
        assertEq(uint256(uint32(base.callbackError())), uint256(uint32(OrderBook.ReentrantCall.selector)));
        assertEq(base.balanceOf(ALICE), START);
        assertEq(book.nextOrderId(), 2);
    }

    function testFullPrecisionEscrowAndFill() public {
        uint256 amount = uint256(1) << 200;
        uint256 price = 1e20;
        base.mint(BOB, amount);
        quote.mint(ALICE, amount * 100);
        _place(BOB, false, price, amount, false);
        _place(ALICE, true, price, amount, false);
        assertEq(book.claimable(ALICE, address(base)), amount);
        assertEq(book.claimable(BOB, address(quote)), amount * 100);
        _check(2, 0, 0, OrderBook.Status.Filled);
    }

    function testFullPrecisionRoundingRefund() public {
        uint256 amount = (uint256(1) << 200) + 1;
        uint256 floorQuote = amount + amount / 100;
        uint256 ceilQuote = amount + (amount + 99) / 100;
        base.mint(BOB, amount);
        quote.mint(ALICE, ceilQuote);
        _place(BOB, false, 101e16, amount, false);
        _place(ALICE, true, 101e16, amount, false);
        assertEq(book.claimable(BOB, address(quote)), floorQuote);
        assertEq(book.claimable(ALICE, address(quote)), ceilQuote - floorQuote);
        assertEq(book.claimable(ALICE, address(base)), amount);
    }

    function testUnrepresentableEscrowRevertsBeforeDeposit() public {
        uint256 price = type(uint256).max / TICK * TICK;
        vm.prank(ALICE);
        vm.expectRevert();
        book.place(true, price, 2e18, false);
        assertEq(quote.balanceOf(ALICE), START);
        assertEq(book.nextOrderId(), 1);
    }

    function testPlacedCancelledWithdrawnEvents() public {
        vm.recordLogs();
        uint256 id = _place(ALICE, true, 1e18, MIN, false);
        _cancel(ALICE, id);
        vm.prank(ALICE);
        book.withdraw(address(quote));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 3);
        assertTrue(logs[0].topics[0] == keccak256("OrderPlaced(uint256,address,bool,uint256,uint256,bool)"));
        assertEq(uint256(logs[0].topics[1]), id);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), ALICE);
        (bool buy, uint256 price, uint256 amount, bool ioc) =
            abi.decode(logs[0].data, (bool, uint256, uint256, bool));
        assertTrue(buy && !ioc);
        assertEq(price, 1e18);
        assertEq(amount, MIN);
        assertTrue(logs[1].topics[0] == keccak256("OrderCancelled(uint256)"));
        assertEq(uint256(logs[1].topics[1]), id);
        assertTrue(logs[2].topics[0] == keccak256("Withdrawn(address,address,uint256)"));
        assertEq(abi.decode(logs[2].data, (uint256)), MIN);
    }
}
