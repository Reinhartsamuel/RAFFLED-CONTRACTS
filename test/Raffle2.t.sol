// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}                   from "forge-std/Test.sol";
import {RaffleManager2}         from "../src/RaffleManager2.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20}          from "./mocks/StandardERC20.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Comprehensive test suite for RaffleManager2.
contract Raffle2Test is Test {
    // ─── Contracts ──────────────────────────────────────────────────────────
    RaffleManager2         mgr;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20          prize;
    StandardERC20          usdc;

    // ─── Accounts ───────────────────────────────────────────────────────────
    address HOST;
    address ALICE;
    address BOB;
    address TREASURY;

    // ─── Constants ──────────────────────────────────────────────────────────
    bytes32 constant KEYHASH      = keccak256("test_keyhash");
    uint256 constant SUB_ID       = 1;
    uint256 constant PRIZE_AMT    = 1_000e18;
    uint256 constant TICKET_PRICE = 10e18;    // 10 USDC per ticket
    uint256 constant MAX_CAP      = 100;
    uint256 constant DURATION     = 1 days;
    uint256 constant FEE_BPS      = 250;      // 2.5%

    // ─── Setup ──────────────────────────────────────────────────────────────
    function setUp() external {
        HOST     = makeAddr("host");
        ALICE    = makeAddr("alice");
        BOB      = makeAddr("bob");
        TREASURY = makeAddr("treasury");

        coord = new VRFCoordinatorV2_5Mock();
        prize = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc  = new StandardERC20("USDC", "USDC", 1_000_000e18);

        mgr = new RaffleManager2(
            address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY
        );

        // Distribute tokens
        prize.transfer(HOST, 50_000e18);
        usdc.transfer(ALICE, 100_000e18);
        usdc.transfer(BOB,   100_000e18);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _createStd() internal returns (uint256) {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        return mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function _warp() internal { vm.warp(block.timestamp + DURATION + 1); }

    function _triggerUpkeep() internal returns (uint256) {
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed, "checkUpkeep returned false");
        mgr.performUpkeep(data);
        return coord.lastRequestId();
    }

    function _enterAs(address user, uint256 raffleId, uint256 tickets) internal {
        uint256 cost = TICKET_PRICE * tickets;
        vm.prank(user);
        IERC20(address(usdc)).approve(address(mgr), cost);
        vm.prank(user);
        mgr.enterRaffle(raffleId, tickets);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – createRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_createRaffle_EmitsEvent() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);

        uint48 expectedExpiry = uint48(block.timestamp + DURATION);

        vm.expectEmit(true, true, false, true);
        emit RaffleManager2.RaffleCreated(
            1, HOST, address(prize), PRIZE_AMT, expectedExpiry, "PZ", 18
        );

        vm.prank(HOST);
        mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createRaffle_StoredCorrectly() external {
        uint256 id = _createStd();
        assertEq(id, 1);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.host,        HOST);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.OPEN));
        assertEq(r.prizeAsset,  address(prize));
        assertEq(r.ticketsSold, 0);
        assertEq(r.underfilled, false);
        assertEq(r.prizeAmount, PRIZE_AMT);
        assertEq(r.ticketPrice, TICKET_PRICE);
        assertEq(r.maxCap,      MAX_CAP);
        assertGt(r.expiry,      uint48(block.timestamp));
    }

    function test_createRaffle_LocksPrize() external {
        uint256 before_ = IERC20(address(prize)).balanceOf(address(mgr));
        _createStd();
        assertEq(IERC20(address(prize)).balanceOf(address(mgr)), before_ + PRIZE_AMT);
    }

    function test_createRaffle_Reverts_ZeroAmount() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.createRaffle(address(prize), 0, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createRaffle_Reverts_ZeroAsset() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.createRaffle(address(0), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createRaffle_Reverts_ZeroDuration() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_createRaffle_Reverts_ZeroTicketPrice() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.createRaffle(address(prize), PRIZE_AMT, 0, MAX_CAP, DURATION);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – enterRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_enterRaffle_SingleTicket() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);
        assertEq(mgr.participants(id, 0), ALICE);
    }

    function test_enterRaffle_MultiTicket() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 5);
        for (uint256 i; i < 5; ++i)
            assertEq(mgr.participants(id, i), ALICE);
    }

    function test_enterRaffle_TwoBuyers() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 2);
        _enterAs(BOB, id, 3);

        assertEq(mgr.participants(id, 0), ALICE);
        assertEq(mgr.participants(id, 1), ALICE);
        assertEq(mgr.participants(id, 2), BOB);
        assertEq(mgr.participants(id, 3), BOB);
        assertEq(mgr.participants(id, 4), BOB);
    }

    function test_enterRaffle_TransfersUSDC() external {
        uint256 id = _createStd();
        uint256 balBefore = usdc.balanceOf(ALICE);
        _enterAs(ALICE, id, 3);
        assertEq(usdc.balanceOf(ALICE), balBefore - TICKET_PRICE * 3);
    }

    function test_enterRaffle_Reverts_HostCannotEnter() external {
        uint256 id = _createStd();
        vm.prank(HOST);
        usdc.approve(address(mgr), TICKET_PRICE);
        // Give HOST some USDC
        deal(address(usdc), HOST, TICKET_PRICE);
        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager2.HostCannotEnter.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_Reverts_Expired() external {
        uint256 id = _createStd();
        _warp();
        vm.prank(ALICE);
        usdc.approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager2.RaffleNotOpen.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_Reverts_MaxCap() external {
        // Create a raffle with maxCap = 2
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 2);

        vm.prank(BOB);
        usdc.approve(address(mgr), TICKET_PRICE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager2.MaxCapReached.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_Reverts_ZeroTickets() external {
        uint256 id = _createStd();
        vm.prank(ALICE);
        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.enterRaffle(id, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – setPlatformFeeBps
    // ═════════════════════════════════════════════════════════════════════════

    function test_setPlatformFee_Owner() external {
        mgr.setPlatformFeeBps(500);
        assertEq(mgr.platformFeeBps(), 500);
    }

    function test_setPlatformFee_EmitsEvent() external {
        vm.expectEmit(false, false, false, true);
        emit RaffleManager2.PlatformFeeUpdated(0, 500);
        mgr.setPlatformFeeBps(500);
    }

    function test_setPlatformFee_Reverts_NotOwner() external {
        vm.prank(ALICE);
        vm.expectRevert();
        mgr.setPlatformFeeBps(500);
    }

    function test_setPlatformFee_Reverts_ExceedsMax() external {
        vm.expectRevert(abi.encodeWithSelector(
            RaffleManager2.FeeTooHigh.selector, 1001, 1000
        ));
        mgr.setPlatformFeeBps(1001);
    }

    function test_setPlatformFee_MaxAllowed() external {
        mgr.setPlatformFeeBps(1000);
        assertEq(mgr.platformFeeBps(), 1000);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – performUpkeep (three paths)
    // ═════════════════════════════════════════════════════════════════════════

    function test_performUpkeep_FullFill_RequestsVRF() external {
        // Create raffle with maxCap = 2, fill it completely
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        _triggerUpkeep();

        // Prize should still be in the contract (not returned to host)
        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.underfilled, false);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.OPEN));
    }

    function test_performUpkeep_Underfill_ReturnsPrizeToHost() external {
        // Create raffle with maxCap = 100, only 2 tickets sold
        uint256 id = _createStd();
        _enterAs(ALICE, id, 2);
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);
        _triggerUpkeep();

        // Prize returned to host
        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.underfilled, true);
    }

    function test_performUpkeep_ZeroParticipants_ReturnsPrize() external {
        uint256 id = _createStd();
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
    }

    function test_performUpkeep_ZeroParticipants_EmitsExpired() external {
        uint256 id = _createStd();
        _warp();

        vm.expectEmit(true, false, false, false);
        emit RaffleManager2.RaffleExpired(id);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);
    }

    function test_performUpkeep_IgnoresNotExpired() external {
        uint256 id = _createStd();
        // Don't warp — not expired yet
        mgr.performUpkeep(abi.encode(id));
        // Should be no-op, status still OPEN
        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.OPEN));
    }

    function test_performUpkeep_IgnoresNotOpen() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);
        _warp();

        // Resolve via manual fulfill first
        mgr.manualFulfillWinner(id, 0);

        // performUpkeep should be a no-op
        mgr.performUpkeep(abi.encode(id));
        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – fulfillRandomWords (two paths)
    // ═════════════════════════════════════════════════════════════════════════

    function test_fulfill_FullFill_WinnerGetsPrizeMinusFee() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 alicePrizeBefore = prize.balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 0; // ALICE wins (index 0)
        coord.fulfillRandomWords(reqId, words);

        uint256 expectedFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(prize.balanceOf(ALICE), alicePrizeBefore + PRIZE_AMT - expectedFee);
    }

    function test_fulfill_FullFill_HostGetsPaymentsMinusFee() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 hostUsdcBefore = usdc.balanceOf(HOST);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        uint256 paymentPool = TICKET_PRICE * 2;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(HOST), hostUsdcBefore + paymentPool - expectedFee);
    }

    function test_fulfill_FullFill_TreasuryGetsFees() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 treasuryPrizeBefore = prize.balanceOf(TREASURY);
        uint256 treasuryUsdcBefore = usdc.balanceOf(TREASURY);

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        uint256 prizeFee   = (PRIZE_AMT * FEE_BPS) / 10_000;
        uint256 paymentFee = (TICKET_PRICE * 2 * FEE_BPS) / 10_000;

        assertEq(prize.balanceOf(TREASURY), treasuryPrizeBefore + prizeFee);
        assertEq(usdc.balanceOf(TREASURY), treasuryUsdcBefore + paymentFee);
    }

    function test_fulfill_FullFill_ZeroFee() external {
        // platformFeeBps defaults to 0
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 alicePrizeBefore = prize.balanceOf(ALICE);
        uint256 hostUsdcBefore   = usdc.balanceOf(HOST);

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        // No fee deducted
        assertEq(prize.balanceOf(ALICE), alicePrizeBefore + PRIZE_AMT);
        assertEq(usdc.balanceOf(HOST), hostUsdcBefore + TICKET_PRICE * 2);
        assertEq(prize.balanceOf(TREASURY), 0);
        assertEq(usdc.balanceOf(TREASURY), 0);
    }

    function test_fulfill_Underfill_WinnerGetsPaymentsMinusFee() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd(); // maxCap = 100
        _enterAs(ALICE, id, 3);    // only 3 tickets sold
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 0; // ALICE wins
        coord.fulfillRandomWords(reqId, words);

        uint256 paymentPool = TICKET_PRICE * 3;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore + paymentPool - expectedFee);
    }

    function test_fulfill_Underfill_TreasuryGetsFee() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd();
        _enterAs(ALICE, id, 3);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 treasuryUsdcBefore = usdc.balanceOf(TREASURY);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        uint256 paymentPool = TICKET_PRICE * 3;
        uint256 expectedFee = (paymentPool * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(TREASURY), treasuryUsdcBefore + expectedFee);
        // No prize fee for underfill
        assertEq(prize.balanceOf(TREASURY), 0);
    }

    function test_fulfill_Underfill_PrizeAlreadyReturned() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 2);
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);
        uint256 reqId = _triggerUpkeep();

        // Prize already returned in performUpkeep
        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);

        // fulfillRandomWords should NOT transfer prize again
        uint256 hostPrizeAfterUpkeep = prize.balanceOf(HOST);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        assertEq(prize.balanceOf(HOST), hostPrizeAfterUpkeep);
    }

    function test_fulfill_Underfill_ZeroFee() external {
        // platformFeeBps = 0
        uint256 id = _createStd();
        _enterAs(ALICE, id, 3);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        uint256 paymentPool = TICKET_PRICE * 3;
        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore + paymentPool);
        assertEq(usdc.balanceOf(TREASURY), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – manualFulfillWinner
    // ═════════════════════════════════════════════════════════════════════════

    function test_manualFulfill_FullFill_DistributesCorrectly() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 alicePrizeBefore = prize.balanceOf(ALICE);
        uint256 hostUsdcBefore   = usdc.balanceOf(HOST);

        mgr.manualFulfillWinner(id, 0); // ALICE wins

        uint256 prizeFee   = (PRIZE_AMT * FEE_BPS) / 10_000;
        uint256 paymentFee = (TICKET_PRICE * 2 * FEE_BPS) / 10_000;

        assertEq(prize.balanceOf(ALICE), alicePrizeBefore + PRIZE_AMT - prizeFee);
        assertEq(usdc.balanceOf(HOST), hostUsdcBefore + TICKET_PRICE * 2 - paymentFee);
    }

    function test_manualFulfill_Underfill_ReturnsPrizeThenDistributes() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd();
        _enterAs(ALICE, id, 3);
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);
        uint256 aliceUsdcBefore = usdc.balanceOf(ALICE);

        // Call manualFulfill WITHOUT performUpkeep first
        mgr.manualFulfillWinner(id, 0); // ALICE wins

        uint256 paymentPool = TICKET_PRICE * 3;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        // Prize returned to host
        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);
        // ALICE gets payment pool minus fee
        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore + paymentPool - paymentFee);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.underfilled, true);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
    }

    function test_manualFulfill_Underfill_AfterPerformUpkeep() external {
        // performUpkeep already returned prize and set underfilled
        uint256 id = _createStd();
        _enterAs(ALICE, id, 2);
        _warp();

        // performUpkeep returns prize
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        uint256 hostPrizeAfterUpkeep = prize.balanceOf(HOST);

        // Now use manualFulfill (simulating VRF not responding, manual fallback)
        // We need the raffle to still be OPEN for manual fulfill...
        // Actually after performUpkeep, status is still OPEN (waiting for VRF)
        // But we already requested VRF. Let's just verify the underfilled flag
        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.underfilled, true);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.OPEN));

        mgr.manualFulfillWinner(id, 0);

        // Prize should NOT be transferred again
        assertEq(prize.balanceOf(HOST), hostPrizeAfterUpkeep);
    }

    function test_manualFulfill_Reverts_NotOpen() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);
        _warp();

        mgr.manualFulfillWinner(id, 0);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager2.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_Reverts_NotExpired() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager2.RaffleNotExpired.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_Reverts_InvalidIndex() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);
        _warp();

        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.manualFulfillWinner(id, 1); // only index 0 exists
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – manualFulfillWinnerByRandomWord
    // ═════════════════════════════════════════════════════════════════════════

    function test_manualFulfillByWord_FullFill() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 bobPrizeBefore = prize.balanceOf(BOB);
        mgr.manualFulfillWinnerByRandomWord(id, 1); // 1 % 2 = 1 → BOB

        uint256 prizeFee = (PRIZE_AMT * FEE_BPS) / 10_000;
        assertEq(prize.balanceOf(BOB), bobPrizeBefore + PRIZE_AMT - prizeFee);
    }

    function test_manualFulfillByWord_Underfill() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd();
        _enterAs(ALICE, id, 2);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);
        uint256 bobUsdcBefore   = usdc.balanceOf(BOB);

        mgr.manualFulfillWinnerByRandomWord(id, 2); // 2 % 3 = 2 → BOB (index 2)

        uint256 paymentPool = TICKET_PRICE * 3;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);
        assertEq(usdc.balanceOf(BOB), bobUsdcBefore + paymentPool - paymentFee);
    }

    function test_manualFulfillByWord_Reverts_ZeroParticipants() external {
        uint256 id = _createStd();
        _warp();

        vm.expectRevert(RaffleManager2.InvalidParams.selector);
        mgr.manualFulfillWinnerByRandomWord(id, 42);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Security – VRF coordinator gate
    // ═════════════════════════════════════════════════════════════════════════

    function test_rawFulfill_Reverts_NotCoordinator() external {
        uint256 id = _createStd();
        _enterAs(ALICE, id, 1);
        _warp();
        _triggerUpkeep();

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        vm.prank(ALICE);
        vm.expectRevert();
        mgr.rawFulfillRandomWords(1, words);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Integration – full end-to-end lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_e2e_FullFillLifecycle() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        // Create raffle with maxCap = 3
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, 3, DURATION);

        // Fill completely
        _enterAs(ALICE, id, 2);
        _enterAs(BOB, id, 1);
        _warp();

        // Snapshot balances
        uint256 alicePrizeBefore = prize.balanceOf(ALICE);
        uint256 hostUsdcBefore   = usdc.balanceOf(HOST);
        uint256 treasuryPrizeBefore = prize.balanceOf(TREASURY);
        uint256 treasuryUsdcBefore  = usdc.balanceOf(TREASURY);

        // Upkeep + VRF
        uint256 reqId = _triggerUpkeep();
        uint256[] memory words = new uint256[](1);
        words[0] = 0; // ALICE wins (index 0)
        coord.fulfillRandomWords(reqId, words);

        // Verify final state
        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
        assertEq(r.underfilled, false);

        uint256 paymentPool = TICKET_PRICE * 3;
        uint256 prizeFee    = (PRIZE_AMT * FEE_BPS) / 10_000;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        assertEq(prize.balanceOf(ALICE), alicePrizeBefore + PRIZE_AMT - prizeFee);
        assertEq(usdc.balanceOf(HOST), hostUsdcBefore + paymentPool - paymentFee);
        assertEq(prize.balanceOf(TREASURY), treasuryPrizeBefore + prizeFee);
        assertEq(usdc.balanceOf(TREASURY), treasuryUsdcBefore + paymentFee);
    }

    function test_e2e_UnderfillLifecycle() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd(); // maxCap = 100
        _enterAs(ALICE, id, 5);
        _enterAs(BOB, id, 3);
        _warp();

        uint256 hostPrizeBefore    = prize.balanceOf(HOST);
        uint256 aliceUsdcBefore    = usdc.balanceOf(ALICE);
        uint256 treasuryUsdcBefore = usdc.balanceOf(TREASURY);

        uint256 reqId = _triggerUpkeep();

        // Prize already returned to host
        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);

        // VRF picks ALICE (index 0)
        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
        assertEq(r.underfilled, true);

        uint256 paymentPool = TICKET_PRICE * 8;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore + paymentPool - paymentFee);
        assertEq(usdc.balanceOf(TREASURY), treasuryUsdcBefore + paymentFee);
        // No prize fee in underfill
        assertEq(prize.balanceOf(TREASURY), 0);
    }

    function test_e2e_ZeroParticipantLifecycle() external {
        uint256 id = _createStd();
        _warp();

        uint256 hostPrizeBefore = prize.balanceOf(HOST);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);

        RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
        assertEq(uint256(r.status), uint256(RaffleManager2.RaffleStatus.COMPLETED));
    }

    function test_e2e_ManualFulfillWithoutUpkeep() external {
        mgr.setPlatformFeeBps(FEE_BPS);

        uint256 id = _createStd();
        _enterAs(ALICE, id, 5);
        _enterAs(BOB, id, 5);
        _warp();

        // Skip performUpkeep entirely, go straight to manual fulfill
        uint256 hostPrizeBefore    = prize.balanceOf(HOST);
        uint256 aliceUsdcBefore    = usdc.balanceOf(ALICE);
        uint256 treasuryUsdcBefore = usdc.balanceOf(TREASURY);

        mgr.manualFulfillWinner(id, 0); // ALICE wins, underfilled (10 < 100)

        uint256 paymentPool = TICKET_PRICE * 10;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        // Prize returned to host (underfill path)
        assertEq(prize.balanceOf(HOST), hostPrizeBefore + PRIZE_AMT);
        // ALICE gets payment pool minus fee
        assertEq(usdc.balanceOf(ALICE), aliceUsdcBefore + paymentPool - paymentFee);
        assertEq(usdc.balanceOf(TREASURY), treasuryUsdcBefore + paymentFee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fuzz tests
    // ═════════════════════════════════════════════════════════════════════════

    function testFuzz_enterRaffle_CapEnforcement(uint256 ticketCount) external {
        ticketCount = bound(ticketCount, 1, 200);
        uint256 cap = 50;

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, cap, DURATION);

        uint256 cost = TICKET_PRICE * ticketCount;
        deal(address(usdc), ALICE, cost);
        vm.prank(ALICE);
        usdc.approve(address(mgr), cost);

        if (ticketCount > cap) {
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(RaffleManager2.MaxCapReached.selector, id));
            mgr.enterRaffle(id, ticketCount);
        } else {
            vm.prank(ALICE);
            mgr.enterRaffle(id, ticketCount);
            RaffleManager2.RaffleData memory r = mgr.getRaffle(id);
            assertEq(r.ticketsSold, ticketCount);
        }
    }

    function testFuzz_fulfill_FeeCalculation(uint256 feeBps, uint256 tickets) external {
        feeBps  = bound(feeBps, 0, 1000);
        tickets = bound(tickets, 1, 50);

        mgr.setPlatformFeeBps(feeBps);

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(
            address(prize), PRIZE_AMT, TICKET_PRICE, tickets, DURATION
        );

        // Fill exactly to maxCap
        uint256 cost = TICKET_PRICE * tickets;
        deal(address(usdc), ALICE, cost);
        vm.prank(ALICE);
        usdc.approve(address(mgr), cost);
        vm.prank(ALICE);
        mgr.enterRaffle(id, tickets);

        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        coord.fulfillRandomWords(reqId, words);

        // Verify accounting: all funds accounted for
        uint256 paymentPool = TICKET_PRICE * tickets;
        uint256 paymentFee  = (paymentPool * feeBps) / 10_000;
        uint256 prizeFee    = (PRIZE_AMT * feeBps) / 10_000;

        // Winner got prize minus fee
        assertEq(prize.balanceOf(ALICE), PRIZE_AMT - prizeFee);
        // Host got payments minus fee
        assertEq(usdc.balanceOf(HOST), paymentPool - paymentFee);
        // Treasury got both fees
        assertEq(prize.balanceOf(TREASURY), prizeFee);
        assertEq(usdc.balanceOf(TREASURY), paymentFee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Edge cases
    // ═════════════════════════════════════════════════════════════════════════

    function test_prizeAssetSameAsPayment() external {
        // Host puts up USDC as prize, payments also in USDC
        mgr.setPlatformFeeBps(FEE_BPS);

        deal(address(usdc), HOST, PRIZE_AMT);
        vm.prank(HOST);
        usdc.approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id = mgr.createRaffle(address(usdc), PRIZE_AMT, TICKET_PRICE, 2, DURATION);

        _enterAs(ALICE, id, 1);
        _enterAs(BOB, id, 1);
        _warp();

        uint256 reqId = _triggerUpkeep();

        uint256 aliceBefore   = usdc.balanceOf(ALICE);
        uint256 hostBefore    = usdc.balanceOf(HOST);
        uint256 treasuryBefore = usdc.balanceOf(TREASURY);

        uint256[] memory words = new uint256[](1);
        words[0] = 0; // ALICE wins
        coord.fulfillRandomWords(reqId, words);

        uint256 paymentPool = TICKET_PRICE * 2;
        uint256 prizeFee    = (PRIZE_AMT * FEE_BPS) / 10_000;
        uint256 paymentFee  = (paymentPool * FEE_BPS) / 10_000;

        assertEq(usdc.balanceOf(ALICE), aliceBefore + PRIZE_AMT - prizeFee);
        assertEq(usdc.balanceOf(HOST), hostBefore + paymentPool - paymentFee);
        assertEq(usdc.balanceOf(TREASURY), treasuryBefore + prizeFee + paymentFee);
    }

    function test_multipleRafflesExpiring() external {
        // Create two raffles, both expire
        uint256 id1 = _createStd();

        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        uint256 id2 = mgr.createRaffle(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);

        _enterAs(ALICE, id1, 1);
        _enterAs(BOB, id2, 1);
        _warp();

        // checkUpkeep returns the first expired raffle
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        uint256 firstId = abi.decode(data, (uint256));
        assertEq(firstId, id1);
    }
}
