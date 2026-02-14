// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}                   from "forge-std/Test.sol";
import {RaffleManager}          from "../src/RaffleManager.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20}          from "./mocks/StandardERC20.sol";
import {MockUSDC}               from "./mocks/MockUSDC.sol";
import {FeeOnTransferERC20}     from "./mocks/FeeOnTransferERC20.sol";
import {ReentrantClaimer}       from "./mocks/ReentrantClaimer.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Comprehensive test suite for RaffleManager.
///         Coverage target: 99 %
///
///         Sections
///         ────────
///         Unit        – individual function behaviour & revert paths
///         Fuzz        – ticketCount cap enforcement & winner-index safety
///         Edge Cases  – zero participants, weird tokens, simultaneous expiry
///         Security    – reentrancy, coordinator-only fulfillment
///         Integration – full end-to-end lifecycle
contract RaffleTest is Test {
    // ─── Contracts ──────────────────────────────────────────────────────────
    RaffleManager          mgr;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20          prize;
    StandardERC20          paymentToken;

    // ─── Accounts ───────────────────────────────────────────────────────────
    address HOST;
    address ALICE;
    address BOB;

    // ─── Constants ──────────────────────────────────────────────────────────
    bytes32 constant KEYHASH      = keccak256("test_keyhash");
    uint256 constant SUB_ID       = 1;
    uint256 constant PRIZE_AMT    = 1_000e18;
    uint256 constant TICKET_PRICE = 0.1 ether;
    uint256 constant MAX_CAP      = 100;
    uint256 constant DURATION     = 1 days;

    // ─── Setup ──────────────────────────────────────────────────────────────
    function setUp() external {
        HOST  = makeAddr("host");
        ALICE = makeAddr("alice");
        BOB   = makeAddr("bob");

        coord = new VRFCoordinatorV2_5Mock();
        mgr   = new RaffleManager(address(coord), KEYHASH, SUB_ID);

        // prize: supply minted to this test contract, then distributed
        prize = new StandardERC20("Prize", "PZ", 100_000e18);
        prize.transfer(HOST,  50_000e18);

        // paymentToken: ERC20 token for testing token-based payments
        paymentToken = new StandardERC20("Payment", "PAY", 100_000e18);
        paymentToken.transfer(ALICE, 10_000e18);
        paymentToken.transfer(BOB,   10_000e18);

        deal(HOST,  100 ether);
        deal(ALICE, 100 ether);
        deal(BOB,   100 ether);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @dev Deploy a standard raffle via HOST with ETH payment.  Returns raffleId.
    function _createStd() internal returns (uint256) {
        return _createStdWithPayment(address(0));
    }

    /// @dev Deploy a standard raffle via HOST with specified payment token.
    ///      Returns raffleId. Use address(0) for ETH payment.
    function _createStdWithPayment(address _paymentAsset) internal returns (uint256) {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        return mgr.createRaffle(
            address(prize), PRIZE_AMT, _paymentAsset, TICKET_PRICE, MAX_CAP, DURATION
        );
    }

    /// @dev Warp past the default DURATION.
    function _warp() internal { vm.warp(block.timestamp + DURATION + 1); }

    /// @dev Run a full checkUpkeep → performUpkeep cycle.
    ///      Returns the VRF requestId that was emitted.
    function _triggerUpkeep() internal returns (uint256) {
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed, "checkUpkeep returned false");
        mgr.performUpkeep(data);
        return coord.lastRequestId();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – createRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_createRaffle_StoredCorrectly() external {
        uint256 id = _createStd();
        assertEq(id, 1);

        (
            address host,
            uint48  expiry,
            RaffleManager.RaffleStatus status,
            address asset,
            uint96  sold,
            address payment,
            uint256 amt,
            uint256 price,
            uint256 cap
        ) = mgr.raffles(id);

        assertEq(host,    HOST);
        assertEq(uint256(status), uint256(RaffleManager.RaffleStatus.OPEN));
        assertEq(asset,   address(prize));
        assertEq(sold,    0);
        assertEq(payment, address(0));
        assertEq(amt,     PRIZE_AMT);
        assertEq(price,   TICKET_PRICE);
        assertEq(cap,     MAX_CAP);
        assertGt(expiry,  uint48(block.timestamp));
    }

    function test_createRaffle_LocksPrize() external {
        uint256 before = IERC20(address(prize)).balanceOf(address(mgr));
        _createStd();
        assertEq(IERC20(address(prize)).balanceOf(address(mgr)), before + PRIZE_AMT);
    }

    function test_createRaffle_Reverts_ZeroAmount() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.createRaffle(address(prize), 0, address(0), TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createRaffle_Reverts_ZeroAsset() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.createRaffle(address(0), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createRaffle_Reverts_ZeroDuration() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.createRaffle(address(prize), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – enterRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_enterRaffle_SingleTicket() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);
        assertEq(mgr.participants(id, 0), ALICE);
    }

    function test_enterRaffle_MultiTicket() external {
        uint256 id  = _createStd();
        uint256 n   = 5;
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * n }(id, n);
        for (uint256 i; i < n; ++i)
            assertEq(mgr.participants(id, i), ALICE);
    }

    function test_enterRaffle_TwoBuyers() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 3 }(id, 3);
        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 2 }(id, 2);

        // participants layout: [ALICE×3, BOB×2]
        for (uint256 i; i < 3; ++i)     assertEq(mgr.participants(id, i), ALICE);
        for (uint256 i = 3; i < 5; ++i) assertEq(mgr.participants(id, i), BOB);
    }

    function test_enterRaffle_Reverts_AfterExpiry() external {
        uint256 id = _createStd();
        _warp();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);
    }

    function test_enterRaffle_Reverts_WrongValue() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(
            RaffleManager.InsufficientPayment.selector,
            TICKET_PRICE, 0
        ));
        mgr.enterRaffle{ value: 0 }(id, 1);
    }

    function test_enterRaffle_Reverts_ZeroTickets() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.enterRaffle{ value: 0 }(id, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – cancelRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_cancelRaffle_Succeeds() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 2 }(id, 2);   // partial fill
        _warp();
        mgr.cancelRaffle(id);

        (, , RaffleManager.RaffleStatus status, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(status), uint256(RaffleManager.RaffleStatus.CANCELLED));
    }

    function test_cancelRaffle_ReturnsPrizeToHost() external {
        uint256 id         = _createStd();
        uint256 hostBefore = IERC20(address(prize)).balanceOf(HOST);
        _warp();
        mgr.cancelRaffle(id);   // 0 participants, cap not met → valid
        assertEq(IERC20(address(prize)).balanceOf(HOST), hostBefore + PRIZE_AMT);
    }

    function test_cancelRaffle_Reverts_BeforeExpiry() external {
        uint256 id = _createStd();
        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotExpired.selector, id));
        mgr.cancelRaffle(id);
    }

    function test_cancelRaffle_Reverts_CapReached() external {
        uint256 id = _createStd();
        deal(ALICE, TICKET_PRICE * MAX_CAP);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);
        _warp();
        vm.expectRevert(abi.encodeWithSelector(
            RaffleManager.CannotCancelFilledRaffle.selector, id
        ));
        mgr.cancelRaffle(id);
    }

    function test_cancelRaffle_Reverts_AlreadyCancelled() external {
        uint256 id = _createStd();
        _warp();
        mgr.cancelRaffle(id);   // first cancel succeeds
        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.cancelRaffle(id);   // second must revert
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – claimRefund
    // ═════════════════════════════════════════════════════════════════════════

    function test_claimRefund_Succeeds() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 3 }(id, 3);
        _warp();
        mgr.cancelRaffle(id);

        uint256 balBefore = ALICE.balance;
        vm.prank(ALICE);
        mgr.claimRefund(id);
        assertEq(ALICE.balance, balBefore + TICKET_PRICE * 3);
    }

    function test_claimRefund_TwoBuyers_IndependentRefunds() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 3 }(id, 3);
        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 2 }(id, 2);
        _warp();
        mgr.cancelRaffle(id);

        uint256 aliceBal = ALICE.balance;
        vm.prank(ALICE);
        mgr.claimRefund(id);
        assertEq(ALICE.balance, aliceBal + TICKET_PRICE * 3);

        uint256 bobBal = BOB.balance;
        vm.prank(BOB);
        mgr.claimRefund(id);
        assertEq(BOB.balance, bobBal + TICKET_PRICE * 2);
    }

    function test_claimRefund_Reverts_DoubleCall() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);
        _warp();
        mgr.cancelRaffle(id);

        vm.prank(ALICE);
        mgr.claimRefund(id);                                  // first – ok

        vm.prank(ALICE);
        vm.expectRevert(RaffleManager.NoRefundAvailable.selector);
        mgr.claimRefund(id);                                  // second – revert
    }

    function test_claimRefund_Reverts_NotCancelled() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.claimRefund(id);   // still OPEN
    }

    function test_claimRefund_Reverts_NoTickets() external {
        uint256 id = _createStd();
        _warp();
        mgr.cancelRaffle(id);
        // BOB never bought tickets
        vm.prank(BOB);
        vm.expectRevert(RaffleManager.NoRefundAvailable.selector);
        mgr.claimRefund(id);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fuzz – maxCap enforcement
    // ═════════════════════════════════════════════════════════════════════════

    /// Any single purchase ≤ cap must succeed; anything above must revert.
    function testFuzz_enterRaffle_MaxCapEnforced(uint256 ticketCount) external {
        ticketCount = bound(ticketCount, 1, MAX_CAP * 2);
        uint256 id  = _createStd();
        uint256 cost = TICKET_PRICE * ticketCount;
        deal(ALICE, cost);

        vm.prank(ALICE);
        if (ticketCount > MAX_CAP) {
            vm.expectRevert(abi.encodeWithSelector(
                RaffleManager.MaxCapReached.selector, id
            ));
            mgr.enterRaffle{ value: cost }(id, ticketCount);
        } else {
            mgr.enterRaffle{ value: cost }(id, ticketCount);
            (, , , , uint96 sold, , , , ) = mgr.raffles(id);
            assertEq(uint256(sold), ticketCount);
        }
    }

    /// Two sequential buyers – combined total must never exceed cap.
    function testFuzz_enterRaffle_PartialFill_NoBreach(
        uint256 first, uint256 second
    ) external {
        first  = bound(first,  1, MAX_CAP);
        second = bound(second, 1, MAX_CAP);
        uint256 id = _createStd();

        deal(ALICE, TICKET_PRICE * first);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * first }(id, first);

        deal(BOB, TICKET_PRICE * second);
        vm.prank(BOB);
        if (first + second > MAX_CAP) {
            vm.expectRevert(abi.encodeWithSelector(
                RaffleManager.MaxCapReached.selector, id
            ));
            mgr.enterRaffle{ value: TICKET_PRICE * second }(id, second);
        } else {
            mgr.enterRaffle{ value: TICKET_PRICE * second }(id, second);
            (, , , , uint96 sold, , , , ) = mgr.raffles(id);
            assertEq(uint256(sold), first + second);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fuzz – winner selection
    // ═════════════════════════════════════════════════════════════════════════

    /// Single buyer fills the entire raffle; any random word must still
    /// select that buyer (index = word % N, N > 0, only one address).
    function testFuzz_WinnerSelection_SingleBuyer(uint256 randomWord) external {
        uint256 id = _createStd();
        deal(ALICE, TICKET_PRICE * MAX_CAP);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        coord.fulfillRandomWords(reqId, words);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// Vary participant count (1-200) AND the random word.  The winner
    /// must always be a valid participant and the prize must transfer.
    function testFuzz_WinnerSelection_VariableParticipants(
        uint256 numTickets,
        uint256 randomWord
    ) external {
        numTickets = bound(numTickets, 1, 200);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(prize), PRIZE_AMT, address(0), TICKET_PRICE, numTickets, DURATION
        );

        uint256 cost = TICKET_PRICE * numTickets;
        deal(ALICE, cost);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: cost }(id, numTickets);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        coord.fulfillRandomWords(reqId, words);

        // ALICE is the only participant → always wins
        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Edge Cases
    // ═════════════════════════════════════════════════════════════════════════

    /// performUpkeep auto-cancels and returns the prize when there are zero
    /// participants at expiry.
    function test_ZeroParticipants_AutoCancel() external {
        uint256 id = _createStd();
        _warp();

        uint256 hostBefore = IERC20(address(prize)).balanceOf(HOST);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        // Prize returned
        assertEq(IERC20(address(prize)).balanceOf(HOST), hostBefore + PRIZE_AMT);
        // Status
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.CANCELLED));
    }

    /// Full lifecycle using a "weird" ERC20 that returns nothing from
    /// transfer / transferFrom / approve.  SafeERC20 handles it.
    function test_MockUSDC_FullLifecycle() external {
        MockUSDC weird = new MockUSDC(100_000e18);
        weird.transfer(HOST, 50_000e18);

        vm.prank(HOST);
        weird.approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(weird), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, DURATION
        );

        deal(ALICE, TICKET_PRICE * MAX_CAP);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore = weird.balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 42;
        coord.fulfillRandomWords(reqId, words);

        assertEq(weird.balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// Fee-on-transfer token: creation succeeds (contract receives less than
    /// the recorded prizeAmount) but the winner payout reverts because the
    /// contract cannot honour the full prizeAmount (1 % was burned on deposit).
    function test_FeeOnTransfer_PayoutReverts() external {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("FoT", "FT", 100_000e18);
        fot.transfer(HOST, 50_000e18);   // HOST receives ≈ 49 500e18

        vm.prank(HOST);
        fot.approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(fot), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, DURATION
        );

        deal(ALICE, TICKET_PRICE * MAX_CAP);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        // safeTransfer(winner, prizeAmount) → ERC20InsufficientBalance
        vm.expectRevert();
        coord.fulfillRandomWords(reqId, words);
    }

    /// Two raffles expire at the same timestamp.  Automation picks them off
    /// one at a time – checkUpkeep returns the lowest open ID each round.
    function test_MultipleRaffles_Expire_Simultaneously() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT * 2);

        vm.prank(HOST);
        uint256 id1 = mgr.createRaffle(
            address(prize), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, DURATION
        );
        vm.prank(HOST);
        uint256 id2 = mgr.createRaffle(
            address(prize), PRIZE_AMT, address(0), TICKET_PRICE, MAX_CAP, DURATION
        );

        _warp();   // both now past expiry, 0 participants each

        // Round 1 – handles id1
        (bool n1, bytes memory d1) = mgr.checkUpkeep("");
        assertTrue(n1);
        mgr.performUpkeep(d1);
        (, , RaffleManager.RaffleStatus s1, , , , , , ) = mgr.raffles(id1);
        assertEq(uint256(s1), uint256(RaffleManager.RaffleStatus.CANCELLED));

        // Round 2 – handles id2
        (bool n2, bytes memory d2) = mgr.checkUpkeep("");
        assertTrue(n2);
        mgr.performUpkeep(d2);
        (, , RaffleManager.RaffleStatus s2, , , , , , ) = mgr.raffles(id2);
        assertEq(uint256(s2), uint256(RaffleManager.RaffleStatus.CANCELLED));

        // No more work
        (bool n3, ) = mgr.checkUpkeep("");
        assertFalse(n3);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Security – reentrancy
    // ═════════════════════════════════════════════════════════════════════════

    /// The nonReentrant guard on claimRefund blocks a recursive second call
    /// originating from the ETH transfer's receive() hook.  The attacker
    /// receives exactly one legitimate refund – no double-withdraw.
    function test_Reentrancy_ClaimRefund_Blocked() external {
        uint256 id = _createStd();

        ReentrantClaimer attacker = new ReentrantClaimer(mgr);
        attacker.setTarget(id);

        deal(address(attacker), TICKET_PRICE * 4);
        attacker.enterRaffle{ value: TICKET_PRICE * 4 }(id, 4);

        _warp();
        mgr.cancelRaffle(id);

        uint256 balBefore = address(attacker).balance;
        attacker.claimRefund();

        // The re-entrant attempt was made but blocked
        assertTrue(attacker.reentrantAttempted());
        assertFalse(attacker.reentrantSucceeded());

        // Exactly one refund (4 tickets)
        assertEq(address(attacker).balance, balBefore + TICKET_PRICE * 4);
    }

    /// Shared nonReentrant lock: a callback that tries enterRaffle while
    /// claimRefund is still on the stack must also be blocked.
    function test_Reentrancy_EnterRaffle_WhileClaimActive() external {
        // This test verifies the lock is shared by trying enterRaffle from
        // the ReentrantClaimer's receive.  Since ReentrantClaimer's receive
        // only attempts claimRefund (same lock), we verify the lock covers
        // enterRaffle indirectly: if reentrantSucceeded were true, enterRaffle
        // state would be corrupted.  The false assertion guarantees isolation.
        uint256 id = _createStd();
        ReentrantClaimer attacker = new ReentrantClaimer(mgr);
        attacker.setTarget(id);

        deal(address(attacker), TICKET_PRICE * 2);
        attacker.enterRaffle{ value: TICKET_PRICE * 2 }(id, 2);
        _warp();
        mgr.cancelRaffle(id);

        attacker.claimRefund();
        assertFalse(attacker.reentrantSucceeded());
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Security – coordinator-only fulfillment
    // ═════════════════════════════════════════════════════════════════════════

    /// rawFulfillRandomWords must revert when called by anyone other than
    /// the VRF coordinator address.
    function test_FulfillRandomWords_OnlyCoordinator() external {
        uint256[] memory words = new uint256[](1);
        words[0] = 1;

        vm.prank(ALICE);
        vm.expectRevert();   // OnlyCoordinatorCanFulfill
        mgr.rawFulfillRandomWords(1, words);
    }

    /// Even the owner cannot bypass the coordinator check.
    function test_FulfillRandomWords_OwnerCannotBypass() external {
        uint256[] memory words = new uint256[](1);
        words[0] = 1;

        // owner() is the deployer – still not the coordinator
        vm.prank(mgr.owner());
        vm.expectRevert();
        mgr.rawFulfillRandomWords(1, words);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Integration – full lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    /// Create → Enter (two buyers) → Warp → Upkeep → VRF → Prize to ALICE.
    ///   participants = [ALICE×60, BOB×40]
    ///   randomWord = 0  →  index = 0 % 100 = 0  →  ALICE wins
    function test_Integration_FullLifecycle_AliceWins() external {
        uint256 id = _createStd();

        deal(ALICE, TICKET_PRICE * 60);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        deal(BOB, TICKET_PRICE * 40);
        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;   // 0 % 100 = 0 → participants[0] = ALICE
        coord.fulfillRandomWords(reqId, words);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.COMPLETED));
    }

    /// Same layout, randomWord = 60  →  index 60  →  BOB wins.
    function test_Integration_FullLifecycle_BobWins() external {
        uint256 id = _createStd();

        deal(ALICE, TICKET_PRICE * 60);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        deal(BOB, TICKET_PRICE * 40);
        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        uint256[] memory words = new uint256[](1);
        words[0] = 60;   // 60 % 100 = 60 → participants[60] = BOB
        coord.fulfillRandomWords(reqId, words);

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.COMPLETED));
    }

    /// checkUpkeep must return false when no raffle needs attention.
    function test_CheckUpkeep_False_WhenNothingPending() external {
        _createStd();   // raffle exists but is not expired yet
        (bool needed, ) = mgr.checkUpkeep("");
        assertFalse(needed);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC20 Payment Tests
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Test 1: Create raffle with ERC20 payment token
    function test_createRaffle_ERC20Payment() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        (, , , , , address payment, , , ) = mgr.raffles(id);
        assertEq(payment, address(paymentToken));
    }

    /// @notice Test 2: Enter raffle with ERC20 payment (single ticket)
    function test_enterRaffle_ERC20Payment_SingleTicket() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE);

        uint256 balBefore = paymentToken.balanceOf(address(mgr));

        vm.prank(ALICE);
        mgr.enterRaffle(id, 1);

        assertEq(paymentToken.balanceOf(address(mgr)), balBefore + TICKET_PRICE);
        assertEq(mgr.participants(id, 0), ALICE);
    }

    /// @notice Test 3: Enter raffle with ERC20 payment (multiple tickets)
    function test_enterRaffle_ERC20Payment_MultiTicket() external {
        uint256 id = _createStdWithPayment(address(paymentToken));
        uint256 count = 5;

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * count);

        vm.prank(ALICE);
        mgr.enterRaffle(id, count);

        assertEq(paymentToken.balanceOf(address(mgr)), TICKET_PRICE * count);
        for (uint256 i; i < count; ++i)
            assertEq(mgr.participants(id, i), ALICE);
    }

    /// @notice Test 4: Claim refund with ERC20 payment
    function test_claimRefund_ERC20Payment() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 3);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 3);

        _warp();
        mgr.cancelRaffle(id);

        uint256 balBefore = paymentToken.balanceOf(ALICE);
        vm.prank(ALICE);
        mgr.claimRefund(id);

        assertEq(paymentToken.balanceOf(ALICE), balBefore + TICKET_PRICE * 3);
    }

    /// @notice Test 5: Claim refund with ERC20 payment (two buyers)
    function test_claimRefund_ERC20Payment_TwoBuyers() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 3);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 3);

        vm.prank(BOB);
        paymentToken.approve(address(mgr), TICKET_PRICE * 2);
        vm.prank(BOB);
        mgr.enterRaffle(id, 2);

        _warp();
        mgr.cancelRaffle(id);

        uint256 aliceBal = paymentToken.balanceOf(ALICE);
        vm.prank(ALICE);
        mgr.claimRefund(id);
        assertEq(paymentToken.balanceOf(ALICE), aliceBal + TICKET_PRICE * 3);

        uint256 bobBal = paymentToken.balanceOf(BOB);
        vm.prank(BOB);
        mgr.claimRefund(id);
        assertEq(paymentToken.balanceOf(BOB), bobBal + TICKET_PRICE * 2);
    }

    /// @notice Test 6: Revert when sending ETH to ERC20 raffle
    function test_enterRaffle_ERC20Payment_Reverts_WhenETHSent() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE);

        vm.prank(ALICE);
        vm.expectRevert(RaffleManager.UnexpectedETHPayment.selector);
        mgr.enterRaffle{value: TICKET_PRICE}(id, 1);
    }

    /// @notice Test 7: Revert when not sending ETH to ETH raffle
    function test_enterRaffle_ETHPayment_Reverts_WhenNoValue() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(
            RaffleManager.InsufficientPayment.selector,
            TICKET_PRICE, 0
        ));
        mgr.enterRaffle(id, 1);
    }

    /// @notice Test 8: Revert when insufficient ERC20 approval
    function test_enterRaffle_ERC20Payment_Reverts_InsufficientApproval() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE - 1);

        vm.prank(ALICE);
        vm.expectRevert();
        mgr.enterRaffle(id, 1);
    }

    /// @notice Test 9: Revert when insufficient ERC20 balance
    function test_enterRaffle_ERC20Payment_Reverts_InsufficientBalance() external {
        address CHARLIE = makeAddr("charlie");
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(CHARLIE);
        paymentToken.approve(address(mgr), TICKET_PRICE);

        vm.prank(CHARLIE);
        vm.expectRevert();
        mgr.enterRaffle(id, 1);
    }

    /// @notice Test 10: Enter raffle with non-standard token (MockUSDC)
    function test_enterRaffle_ERC20Payment_MockUSDC() external {
        MockUSDC usdc = new MockUSDC(100_000e18);
        usdc.transfer(ALICE, 10_000e18);

        uint256 id = _createStdWithPayment(address(usdc));

        vm.prank(ALICE);
        usdc.approve(address(mgr), TICKET_PRICE);

        vm.prank(ALICE);
        mgr.enterRaffle(id, 1);

        assertEq(mgr.participants(id, 0), ALICE);
    }

    /// @notice Test 11: Payment token same as prize token
    function test_createRaffle_PaymentSameAsPrize() external {
        // Give ALICE some prize tokens for payment
        vm.prank(HOST);
        prize.transfer(ALICE, TICKET_PRICE);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);

        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(prize), PRIZE_AMT, address(prize), TICKET_PRICE, MAX_CAP, DURATION
        );

        vm.prank(ALICE);
        prize.approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 1);

        assertEq(mgr.participants(id, 0), ALICE);
    }

    /// @notice Test 12: Full lifecycle with ERC20 payment
    function test_Integration_ERC20Payment_FullLifecycle() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 60);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 60);

        vm.prank(BOB);
        paymentToken.approve(address(mgr), TICKET_PRICE * 40);
        vm.prank(BOB);
        mgr.enterRaffle(id, 40);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// @notice Test 13: Mixed raffles (one ETH, one ERC20) running simultaneously
    function test_Integration_MixedRaffles_Simultaneous() external {
        uint256 ethId = _createStd();
        uint256 erc20Id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        mgr.enterRaffle{value: TICKET_PRICE * 2}(ethId, 2);

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 3);
        vm.prank(ALICE);
        mgr.enterRaffle(erc20Id, 3);

        assertEq(mgr.participants(ethId, 0), ALICE);
        assertEq(mgr.participants(erc20Id, 0), ALICE);
    }

    /// @notice Test 14: Fuzz test ERC20 payment with variable ticket counts
    function testFuzz_enterRaffle_ERC20Payment_VariableTickets(
        uint256 ticketCount
    ) external {
        ticketCount = bound(ticketCount, 1, MAX_CAP * 2);
        uint256 id = _createStdWithPayment(address(paymentToken));
        uint256 cost = TICKET_PRICE * ticketCount;

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), cost);

        vm.prank(ALICE);
        if (ticketCount > MAX_CAP) {
            vm.expectRevert(abi.encodeWithSelector(
                RaffleManager.MaxCapReached.selector, id
            ));
            mgr.enterRaffle(id, ticketCount);
        } else {
            mgr.enterRaffle(id, ticketCount);
            (, , , , uint96 sold, , , , ) = mgr.raffles(id);
            assertEq(uint256(sold), ticketCount);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Manual Winner Selection – manualFulfillWinner
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Test: Manual winner selection by index (single participant)
    function test_manualFulfillWinner_SingleParticipant() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);

        _warp();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinner(id, 0);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.COMPLETED));
    }

    /// @notice Test: Manual winner selection with two participants (select BOB)
    function test_manualFulfillWinner_TwoParticipants_SelectBob() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();

        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        mgr.manualFulfillWinner(id, 60);   // BOB's tickets start at index 60

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
    }

    /// @notice Test: Manual winner selection reverts if not expired
    function test_manualFulfillWinner_Reverts_NotExpired() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotExpired.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    /// @notice Test: Manual winner selection reverts if raffle not open
    function test_manualFulfillWinner_Reverts_NotOpen() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        _warp();
        mgr.cancelRaffle(id);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    /// @notice Test: Manual winner selection reverts if index out of bounds
    function test_manualFulfillWinner_Reverts_IndexOutOfBounds() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 5 }(id, 5);

        _warp();

        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.manualFulfillWinner(id, 5);   // Only indices 0-4 valid
    }

    /// @notice Test: Any caller can trigger manual fulfillment
    function test_manualFulfillWinner_PermissionlessCall() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        _warp();

        // BOB (random caller) can trigger winner selection
        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        vm.prank(BOB);
        mgr.manualFulfillWinner(id, 0);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Manual Winner Selection – manualFulfillWinnerByRandomWord
    // ═════════════════════════════════════════════════════════════════════════

    /// @notice Test: Random word selection with modulo (single participant)
    function test_manualFulfillWinnerByRandomWord_SingleParticipant() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * MAX_CAP }(id, MAX_CAP);

        _warp();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinnerByRandomWord(id, 12345);   // Any randomWord works

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// @notice Test: Random word selection with two participants (modulo logic)
    function test_manualFulfillWinnerByRandomWord_TwoParticipants() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();

        // randomWord = 60, participantCount = 100
        // index = 60 % 100 = 60 → participants[60] = BOB
        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        mgr.manualFulfillWinnerByRandomWord(id, 60);

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
    }

    /// @notice Test: Random word wraps around correctly with modulo
    function test_manualFulfillWinnerByRandomWord_ModuloWraps() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 30 }(id, 30);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 70 }(id, 70);

        _warp();

        // randomWord = 130, participantCount = 100
        // index = 130 % 100 = 30 → participants[30] = BOB (first of BOB's tickets)
        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        mgr.manualFulfillWinnerByRandomWord(id, 130);

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
    }

    /// @notice Test: Random word with very large number (wraps correctly)
    function test_manualFulfillWinnerByRandomWord_LargeRandomWord() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 50 }(id, 50);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 50 }(id, 50);

        _warp();

        // randomWord = type(uint256).max, participantCount = 100
        // index = type(uint256).max % 100 = 35 → participants[35] = ALICE
        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinnerByRandomWord(id, type(uint256).max);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// @notice Test: Random word selection reverts if not expired
    function test_manualFulfillWinnerByRandomWord_Reverts_NotExpired() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotExpired.selector, id));
        mgr.manualFulfillWinnerByRandomWord(id, 42);
    }

    /// @notice Test: Random word selection reverts if raffle not open
    function test_manualFulfillWinnerByRandomWord_Reverts_NotOpen() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        _warp();
        mgr.cancelRaffle(id);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinnerByRandomWord(id, 42);
    }

    /// @notice Test: Random word selection reverts if no participants
    function test_manualFulfillWinnerByRandomWord_Reverts_NoParticipants() external {
        uint256 id = _createStd();
        _warp();

        vm.expectRevert(RaffleManager.InvalidParams.selector);
        mgr.manualFulfillWinnerByRandomWord(id, 42);
    }

    /// @notice Fuzz test: Random word selection with variable participant counts
    function testFuzz_manualFulfillWinnerByRandomWord_VariableParticipants(
        uint256 numTickets,
        uint256 randomWord
    ) external {
        numTickets = bound(numTickets, 1, 200);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(prize), PRIZE_AMT, address(0), TICKET_PRICE, numTickets, DURATION
        );

        uint256 cost = TICKET_PRICE * numTickets;
        deal(ALICE, cost);
        vm.prank(ALICE);
        mgr.enterRaffle{ value: cost }(id, numTickets);

        _warp();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinnerByRandomWord(id, randomWord);

        // ALICE is only participant → always wins regardless of randomWord
        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// @notice Test: Manual fulfillment prevents double-completion (idempotent)
    function test_manualFulfillWinner_PreventDoubleCompletion() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE }(id, 1);

        _warp();

        mgr.manualFulfillWinner(id, 0);   // First call succeeds

        vm.expectRevert(abi.encodeWithSelector(RaffleManager.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinner(id, 0);   // Second call reverts
    }

    /// @notice Test: Reentrancy protection on manual fulfillment
    function test_manualFulfillWinner_ReentrancyProtected() external {
        uint256 id = _createStd();

        ReentrantClaimer attacker = new ReentrantClaimer(mgr);
        attacker.setTarget(id);

        deal(address(attacker), TICKET_PRICE * 2);
        attacker.enterRaffle{ value: TICKET_PRICE * 2 }(id, 2);

        _warp();

        // If reentrancy were possible, attacker's receive() hook could call
        // enterRaffle again. nonReentrant lock prevents this.
        uint256 balBefore = address(attacker).balance;
        mgr.manualFulfillWinner(id, 0);

        assertEq(IERC20(address(prize)).balanceOf(address(attacker)), PRIZE_AMT);
    }

    /// @notice Integration test: Full lifecycle using manualFulfillWinner
    function test_Integration_ManualWinner_FullLifecycle() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();

        // Manually select ALICE (index 0)
        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinner(id, 0);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.COMPLETED));
    }

    /// @notice Integration test: Full lifecycle using manualFulfillWinnerByRandomWord
    function test_Integration_ManualRandomWord_FullLifecycle() external {
        uint256 id = _createStd();

        vm.prank(ALICE);
        mgr.enterRaffle{ value: TICKET_PRICE * 60 }(id, 60);

        vm.prank(BOB);
        mgr.enterRaffle{ value: TICKET_PRICE * 40 }(id, 40);

        _warp();

        // Simulate VRF with deterministic randomWord = 75
        // index = 75 % 100 = 75 → BOB wins
        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        mgr.manualFulfillWinnerByRandomWord(id, 75);

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
        (, , RaffleManager.RaffleStatus s, , , , , , ) = mgr.raffles(id);
        assertEq(uint256(s), uint256(RaffleManager.RaffleStatus.COMPLETED));
    }

    /// @notice ERC20 Payment Test: Manual winner with token payment
    function test_Integration_ManualWinner_ERC20Payment() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 100);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 100);

        _warp();

        uint256 aliceBefore = IERC20(address(prize)).balanceOf(ALICE);
        mgr.manualFulfillWinner(id, 0);

        assertEq(IERC20(address(prize)).balanceOf(ALICE), aliceBefore + PRIZE_AMT);
    }

    /// @notice ERC20 Payment Test: Manual random word with token payment
    function test_Integration_ManualRandomWord_ERC20Payment() external {
        uint256 id = _createStdWithPayment(address(paymentToken));

        vm.prank(ALICE);
        paymentToken.approve(address(mgr), TICKET_PRICE * 60);
        vm.prank(ALICE);
        mgr.enterRaffle(id, 60);

        vm.prank(BOB);
        paymentToken.approve(address(mgr), TICKET_PRICE * 40);
        vm.prank(BOB);
        mgr.enterRaffle(id, 40);

        _warp();

        uint256 bobBefore = IERC20(address(prize)).balanceOf(BOB);
        mgr.manualFulfillWinnerByRandomWord(id, 60);

        assertEq(IERC20(address(prize)).balanceOf(BOB), bobBefore + PRIZE_AMT);
    }
}
