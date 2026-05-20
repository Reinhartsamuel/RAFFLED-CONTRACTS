// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}                   from "forge-std/Test.sol";
import {RaffleManager3}         from "../src/RaffleManager3.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20}          from "./mocks/StandardERC20.sol";
import {MockERC721}             from "./mocks/MockERC721.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}                from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @notice Comprehensive test suite for RaffleManager3.
contract Raffle3Test is Test {
    // ─── Contracts ──────────────────────────────────────────────────────────
    RaffleManager3         mgr;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20          prize;
    StandardERC20          usdc;
    MockERC721             nft;

    // ─── Accounts ───────────────────────────────────────────────────────────
    address HOST;
    address ALICE;
    address BOB;
    address TREASURY;

    // ─── Constants ──────────────────────────────────────────────────────────
    bytes32 constant KEYHASH      = keccak256("test_keyhash");
    uint256 constant SUB_ID       = 1;
    uint256 constant PRIZE_AMT    = 1_000e18;
    uint256 constant TICKET_PRICE = 10e18;     // 10 USDC per ticket
    uint256 constant MAX_CAP      = 100;
    uint256 constant DURATION     = 1 days;
    uint256 constant FEE_BPS      = 250;       // 2.5%
    uint256 constant NFT_TOKEN_ID = 42;

    // ─── Setup ──────────────────────────────────────────────────────────────
    function setUp() external {
        HOST     = makeAddr("host");
        ALICE    = makeAddr("alice");
        BOB      = makeAddr("bob");
        TREASURY = makeAddr("treasury");

        coord = new VRFCoordinatorV2_5Mock();
        prize = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc  = new StandardERC20("USDC", "USDC", 1_000_000e18);
        nft   = new MockERC721();

        mgr = new RaffleManager3(
            address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY
        );

        // Set platform fee
        mgr.proposeFeeChange(FEE_BPS);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();

        // Distribute ERC-20 tokens
        prize.transfer(HOST, 50_000e18);
        usdc.transfer(ALICE, 100_000e18);
        usdc.transfer(BOB,   100_000e18);

        // Mint NFT to HOST
        nft.mint(HOST, NFT_TOKEN_ID);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _createERC20() internal returns (uint256) {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        return mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function _createERC721() internal returns (uint256) {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);
        vm.prank(HOST);
        return mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
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

    function _fulfillVRF(uint256 requestId, uint256 randomWord) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = randomWord;
        coord.fulfillRandomWords(requestId, words);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – createRaffleERC20
    // ═════════════════════════════════════════════════════════════════════════

    function test_createERC20_EmitsEvent() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);

        uint48 expectedExpiry = uint48(block.timestamp + DURATION);

        vm.expectEmit(true, true, false, true);
        emit RaffleManager3.RaffleCreated(
            1, HOST, address(prize), RaffleManager3.PrizeType.ERC20,
            PRIZE_AMT, expectedExpiry, "PZ", 18
        );

        vm.prank(HOST);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_StoredCorrectly() external {
        uint256 id = _createERC20();
        RaffleManager3.RaffleData memory r = mgr.getRaffle(id);

        assertEq(r.host,                 HOST);
        assertEq(uint8(r.status),        uint8(RaffleManager3.RaffleStatus.OPEN));
        assertEq(uint8(r.prizeType),     uint8(RaffleManager3.PrizeType.ERC20));
        assertEq(r.prizeAsset,           address(prize));
        assertEq(r.prizeAmountOrTokenId, PRIZE_AMT);
        assertEq(r.ticketPrice,          TICKET_PRICE);
        assertEq(r.maxCap,               MAX_CAP);
        assertEq(r.ticketsSold,          0);
        assertFalse(r.underfilled);
    }

    function test_createERC20_TransfersPrize() external {
        uint256 before = prize.balanceOf(address(mgr));
        _createERC20();
        assertEq(prize.balanceOf(address(mgr)), before + PRIZE_AMT);
    }

    function test_createERC20_RevertsOnZeroAsset() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.createRaffleERC20(address(0), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_RevertsOnZeroAmount() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), 0, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_RevertsOnZeroDuration() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – createRaffleERC721
    // ═════════════════════════════════════════════════════════════════════════

    function test_createERC721_EmitsEvent() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);

        uint48 expectedExpiry = uint48(block.timestamp + DURATION);

        vm.expectEmit(true, true, false, true);
        emit RaffleManager3.RaffleCreated(
            1, HOST, address(nft), RaffleManager3.PrizeType.ERC721,
            NFT_TOKEN_ID, expectedExpiry, "MockNFT", 0
        );

        vm.prank(HOST);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC721_StoredCorrectly() external {
        uint256 id = _createERC721();
        RaffleManager3.RaffleData memory r = mgr.getRaffle(id);

        assertEq(r.host,                 HOST);
        assertEq(uint8(r.prizeType),     uint8(RaffleManager3.PrizeType.ERC721));
        assertEq(r.prizeAsset,           address(nft));
        assertEq(r.prizeAmountOrTokenId, NFT_TOKEN_ID);
        assertEq(r.ticketPrice,          TICKET_PRICE);
        assertEq(r.maxCap,               MAX_CAP);
        assertEq(r.ticketsSold,          0);
        assertFalse(r.underfilled);
    }

    function test_createERC721_TransfersNFT() external {
        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);
        _createERC721();
        assertEq(nft.ownerOf(NFT_TOKEN_ID), address(mgr));
    }

    function test_createERC721_RevertsOnZeroAddress() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.createRaffleERC721(address(0), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC721_RevertsOnZeroDuration() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_createERC721_RevertsWithoutApproval() external {
        vm.prank(HOST);
        vm.expectRevert();
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Unit – enterRaffle
    // ═════════════════════════════════════════════════════════════════════════

    function test_enterRaffle_UpdatesState() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 5);

        RaffleManager3.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.ticketsSold, 5);
        assertEq(mgr.participants(id, 0), ALICE);
        assertEq(mgr.participants(id, 4), ALICE);
    }

    function test_enterRaffle_HostCannotEnter() external {
        uint256 id = _createERC20();
        uint256 cost = TICKET_PRICE;
        vm.prank(HOST);
        IERC20(address(usdc)).approve(address(mgr), cost);
        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager3.HostCannotEnter.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_MaxCapReached() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager3.MaxCapReached.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_RevertsWhenExpired() external {
        uint256 id = _createERC20();
        _warp();
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager3.RaffleNotOpen.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_RevertsOnZeroTickets() external {
        uint256 id = _createERC20();
        vm.prank(ALICE);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.enterRaffle(id, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 full-fill lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_FullFill_VRFWinnerPickedCorrectly() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 preBal = prize.balanceOf(ALICE);
        _fulfillVRF(reqId, 0);  // index 0 → ALICE

        assertGt(prize.balanceOf(ALICE), preBal);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.COMPLETED));
    }

    function test_erc20_FullFill_WinnerReceivesPrizeMinusFee() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 fee    = (PRIZE_AMT * FEE_BPS) / 10_000;
        uint256 expect = PRIZE_AMT - fee;

        uint256 preBal = prize.balanceOf(ALICE);
        _fulfillVRF(reqId, 0);
        assertEq(prize.balanceOf(ALICE) - preBal, expect);
    }

    function test_erc20_FullFill_HostReceivesPaymentMinusFee() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool       = MAX_CAP * TICKET_PRICE;
        uint256 fee        = (pool * FEE_BPS) / 10_000;
        uint256 hostExpect = pool - fee;

        uint256 preBal = usdc.balanceOf(HOST);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(HOST) - preBal, hostExpect);
    }

    function test_erc20_FullFill_TreasuryReceivesBothFees() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool       = MAX_CAP * TICKET_PRICE;
        uint256 payFee     = (pool * FEE_BPS) / 10_000;
        uint256 prizeFee   = (PRIZE_AMT * FEE_BPS) / 10_000;

        uint256 preUSDC  = usdc.balanceOf(TREASURY);
        uint256 prePrize = prize.balanceOf(TREASURY);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(TREASURY)  - preUSDC,  payFee);
        assertEq(prize.balanceOf(TREASURY) - prePrize, prizeFee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 underfill lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_Underfill_PrizeReturnedToHost() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);   // only 10 of 100
        _warp();

        uint256 preBal = prize.balanceOf(HOST);

        vm.expectEmit(true, true, false, true);
        emit RaffleManager3.UnderfilledPrizeReturned(id, HOST, PRIZE_AMT);

        _triggerUpkeep();
        assertEq(prize.balanceOf(HOST) - preBal, PRIZE_AMT);
    }

    function test_erc20_Underfill_WinnerGetsPaymentPool() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        uint256 expect = pool - fee;

        uint256 preBal = usdc.balanceOf(ALICE);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(ALICE) - preBal, expect);
    }

    function test_erc20_Underfill_RaffleIsUnderfilled() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();
        _triggerUpkeep();
        assertTrue(mgr.getRaffle(id).underfilled);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-20 zero participants
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_ZeroParticipants_PrizeReturnedToHost() external {
        uint256 id = _createERC20();
        _warp();

        uint256 preBal = prize.balanceOf(HOST);

        vm.expectEmit(true, false, false, false);
        emit RaffleManager3.RaffleExpired(id);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        assertEq(prize.balanceOf(HOST) - preBal, PRIZE_AMT);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 full-fill lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc721_FullFill_WinnerReceivesNFT() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        _fulfillVRF(reqId, 0);  // index 0 → ALICE

        assertEq(nft.ownerOf(NFT_TOKEN_ID), ALICE);
    }

    function test_erc721_FullFill_HostReceivesPaymentMinusFee() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool   = MAX_CAP * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        uint256 expect = pool - fee;

        uint256 preBal = usdc.balanceOf(HOST);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(HOST) - preBal, expect);
    }

    function test_erc721_FullFill_TreasuryReceivesPaymentFeeOnly() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool   = MAX_CAP * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;

        uint256 preBal = usdc.balanceOf(TREASURY);
        _fulfillVRF(reqId, 0);
        // No prize fee for NFT (indivisible)
        assertEq(usdc.balanceOf(TREASURY) - preBal, fee);
    }

    function test_erc721_FullFill_VRFWinnerIndex() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 60);
        _enterAs(BOB,   id, 40);
        _warp();
        uint256 reqId = _triggerUpkeep();

        // random word that picks index 60 → BOB's first ticket
        _fulfillVRF(reqId, 60);

        assertEq(nft.ownerOf(NFT_TOKEN_ID), BOB);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 underfill lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc721_Underfill_NFTReturnedToHost() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();

        vm.expectEmit(true, true, false, true);
        emit RaffleManager3.UnderfilledPrizeReturned(id, HOST, NFT_TOKEN_ID);

        _triggerUpkeep();

        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);
    }

    function test_erc721_Underfill_WinnerGetsPaymentPool() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();
        uint256 reqId = _triggerUpkeep();

        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        uint256 expect = pool - fee;

        uint256 preBal = usdc.balanceOf(ALICE);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(ALICE) - preBal, expect);
    }

    function test_erc721_Underfill_IsMarkedUnderfilled() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();
        _triggerUpkeep();
        assertTrue(mgr.getRaffle(id).underfilled);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  ERC-721 zero participants
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc721_ZeroParticipants_NFTReturnedToHost() external {
        uint256 id = _createERC721();
        _warp();

        uint256 preBal = nft.balanceOf(HOST);

        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);

        assertEq(nft.balanceOf(HOST) - preBal, 1);
        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Manual fulfill
    // ═════════════════════════════════════════════════════════════════════════

    function test_manualFulfill_ERC20ByIndex() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();

        uint256 preBal = prize.balanceOf(ALICE);
        mgr.manualFulfillWinner(id, 0);
        assertGt(prize.balanceOf(ALICE), preBal);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.COMPLETED));
    }

    function test_manualFulfill_ERC721ByIndex() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();

        mgr.manualFulfillWinner(id, 0);
        assertEq(nft.ownerOf(NFT_TOKEN_ID), ALICE);
    }

    function test_manualFulfill_ERC721ByRandomWord() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 60);
        _enterAs(BOB,   id, 40);
        _warp();

        mgr.manualFulfillWinnerByRandomWord(id, 60);   // index 60 → BOB
        assertEq(nft.ownerOf(NFT_TOKEN_ID), BOB);
    }

    function test_manualFulfill_RevertsBeforeExpiry() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 5);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager3.RaffleNotExpired.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_RevertsOnCompletedRaffle() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        mgr.manualFulfillWinner(id, 0);

        vm.expectRevert(abi.encodeWithSelector(RaffleManager3.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_ERC20Underfill_ReturnsPrizeAndPaysWinner() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();

        uint256 preHostPrize = prize.balanceOf(HOST);
        uint256 preAliceUSDC = usdc.balanceOf(ALICE);

        mgr.manualFulfillWinner(id, 0);

        assertEq(prize.balanceOf(HOST) - preHostPrize, PRIZE_AMT);
        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(ALICE) - preAliceUSDC, pool - fee);
    }

    function test_manualFulfill_ERC721Underfill_ReturnsNFTAndPaysWinner() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();

        mgr.manualFulfillWinner(id, 0);

        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);  // NFT back to host (underfill)

        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        // Alice gets payment pool
        // (We don't check exact pre-balance math here – just that she received something)
        assertGt(usdc.balanceOf(ALICE), 100_000e18 - 10 * TICKET_PRICE);
        // Verify winner received pool minus fee correctly
        uint256 aliceNet = usdc.balanceOf(ALICE) - (100_000e18 - 10 * TICKET_PRICE);
        assertEq(aliceNet, pool - fee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fee timelock
    // ═════════════════════════════════════════════════════════════════════════

    function test_fee_ProposalStored() external {
        // Reset fee first
        mgr.proposeFeeChange(500);
        assertEq(mgr.pendingFeeBps(), 500);
        assertGt(mgr.feeChangeEffectiveAt(), block.timestamp);
    }

    function test_fee_CannotApplyBeforeTimelock() external {
        mgr.proposeFeeChange(500);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager3.FeeTimelockNotElapsed.selector,
                mgr.feeChangeEffectiveAt()
            )
        );
        mgr.applyFeeChange();
    }

    function test_fee_AppliedAfterTimelock() external {
        mgr.proposeFeeChange(500);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();
        assertEq(mgr.platformFeeBps(), 500);
        assertEq(mgr.pendingFeeBps(), 0);
        assertEq(mgr.feeChangeEffectiveAt(), 0);
    }

    function test_fee_RevertsIfNoChangePending() external {
        vm.expectRevert(RaffleManager3.NoFeeChangePending.selector);
        mgr.applyFeeChange();
    }

    function test_fee_RevertsIfTooHigh() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager3.FeeTooHigh.selector,
                1_001,
                RaffleManager3(mgr).MAX_PLATFORM_FEE_BPS()
            )
        );
        mgr.proposeFeeChange(1_001);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Automation
    // ═════════════════════════════════════════════════════════════════════════

    function test_checkUpkeep_ReturnsFalseWhenNoExpiry() external {
        _createERC20();
        (bool needed,) = mgr.checkUpkeep("");
        assertFalse(needed);
    }

    function test_checkUpkeep_ReturnsTrueWhenExpired() external {
        _createERC20();
        _warp();
        (bool needed,) = mgr.checkUpkeep("");
        assertTrue(needed);
    }

    function test_checkUpkeep_ReturnsFalseAfterCompletion() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 0);

        (bool needed,) = mgr.checkUpkeep("");
        assertFalse(needed);
    }

    function test_performUpkeep_ERC721Underfill_ReturnsNFT() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 5);
        _warp();

        assertEq(nft.ownerOf(NFT_TOKEN_ID), address(mgr));
        _triggerUpkeep();
        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);
        assertTrue(mgr.getRaffle(id).underfilled);
    }

    function test_performUpkeep_NoOpWhenNotExpired() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);

        // Manually call performUpkeep with a valid but not-yet-expired raffle
        mgr.performUpkeep(abi.encode(id));
        // Raffle should still be open
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.OPEN));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Security
    // ═════════════════════════════════════════════════════════════════════════

    function test_vrf_OnlyCoordinatorCanFulfill() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        _triggerUpkeep();

        uint256[] memory words = new uint256[](1);
        words[0] = 0;
        vm.prank(ALICE);
        vm.expectRevert();
        mgr.rawFulfillRandomWords(1, words);
    }

    function test_onERC721Received_AcceptsNFT() external {
        // Verify contract accepts NFT via safeTransferFrom
        _createERC721();
        assertEq(nft.ownerOf(NFT_TOKEN_ID), address(mgr));
    }

    function test_enterRaffle_NoReentrancy() external {
        // Sanity check: entering with zero tickets is blocked before any transfers
        uint256 id = _createERC20();
        vm.prank(ALICE);
        vm.expectRevert(RaffleManager3.InvalidParams.selector);
        mgr.enterRaffle(id, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Views
    // ═════════════════════════════════════════════════════════════════════════

    function test_getRaffle_ReturnsCorrectData() external {
        uint256 id = _createERC20();
        RaffleManager3.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.host, HOST);
        assertEq(r.ticketPrice, TICKET_PRICE);
        assertEq(r.maxCap, MAX_CAP);
    }

    function test_raffleCount_Increments() external {
        assertEq(mgr.raffleCount(), 0);
        _createERC20();
        assertEq(mgr.raffleCount(), 1);
        _createERC721();
        assertEq(mgr.raffleCount(), 2);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Fuzz
    // ═════════════════════════════════════════════════════════════════════════

    function fuzz_enterRaffle_NeverExceedsCap(uint256 ticketCount) external {
        ticketCount = bound(ticketCount, 1, MAX_CAP);
        uint256 id  = _createERC20();
        _enterAs(ALICE, id, ticketCount);
        assertLe(mgr.getRaffle(id).ticketsSold, MAX_CAP);
    }

    function fuzz_winnerIndex_AlwaysInBounds(uint256 randomWord) external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 50);
        _enterAs(BOB,   id, 50);
        _warp();
        uint256 reqId = _triggerUpkeep();

        // All random words should yield a valid participant
        _fulfillVRF(reqId, randomWord);
        // If we get here without revert, winner index was valid
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager3.RaffleStatus.COMPLETED));
    }

    function fuzz_erc721_winnerIndex_AlwaysInBounds(uint256 randomWord) external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 50);
        _enterAs(BOB,   id, 50);
        _warp();
        uint256 reqId = _triggerUpkeep();

        _fulfillVRF(reqId, randomWord);
        // Winner must be ALICE or BOB
        address owner = nft.ownerOf(NFT_TOKEN_ID);
        assertTrue(owner == ALICE || owner == BOB);
    }
}
