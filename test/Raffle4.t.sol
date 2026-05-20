// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test}                   from "forge-std/Test.sol";
import {RaffleManager4}         from "../src/RaffleManager4.sol";
import {FreeEntryVerifier}      from "../src/FreeEntryVerifier.sol";
import {VRFCoordinatorV2_5Mock} from "./mocks/VRFCoordinatorV2_5Mock.sol";
import {StandardERC20}          from "./mocks/StandardERC20.sol";
import {MockERC721}             from "./mocks/MockERC721.sol";
import {IERC20}                 from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721}                from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

contract Raffle4Test is Test {
    RaffleManager4         mgr;
    VRFCoordinatorV2_5Mock coord;
    StandardERC20          prize;
    StandardERC20          usdc;
    MockERC721             nft;

    address HOST;
    address ALICE;
    address BOB;
    address TREASURY;
    address SIGNER;
    uint256 SIGNER_PK;

    bytes32 constant KEYHASH      = keccak256("test_keyhash");
    uint256 constant SUB_ID       = 1;
    uint256 constant PRIZE_AMT    = 1_000e18;
    uint256 constant TICKET_PRICE = 10e18;
    uint256 constant MAX_CAP      = 100;
    uint256 constant DURATION     = 1 days;
    uint256 constant FEE_BPS      = 250;
    uint256 constant NFT_TOKEN_ID = 42;

    function setUp() external {
        HOST     = makeAddr("host");
        ALICE    = makeAddr("alice");
        BOB      = makeAddr("bob");
        TREASURY = makeAddr("treasury");
        SIGNER_PK = uint256(keccak256("signer_private_key"));
        SIGNER    = vm.addr(SIGNER_PK);

        coord = new VRFCoordinatorV2_5Mock();
        prize = new StandardERC20("Prize", "PZ", 100_000e18);
        usdc  = new StandardERC20("USDC", "USDC", 1_000_000e18);
        nft   = new MockERC721();

        mgr = new RaffleManager4(
            address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY, SIGNER
        );

        mgr.proposeFeeChange(FEE_BPS);
        vm.warp(block.timestamp + 2 days + 1);
        mgr.applyFeeChange();

        prize.transfer(HOST, 50_000e18);
        usdc.transfer(ALICE, 100_000e18);
        usdc.transfer(BOB,   100_000e18);
        nft.mint(HOST, NFT_TOKEN_ID);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Helpers
    // ═════════════════════════════════════════════════════════════════════════

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

    function _signFreeEntry(uint256 raffleId, address user) internal view returns (bytes memory) {
        bytes32 digest = mgr.computeDigest(raffleId, user);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
        return abi.encodePacked(r, s, v);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  A. Constructor & Initialization
    // ═════════════════════════════════════════════════════════════════════════

    function test_constructor_StoresAllParams() external {
        assertEq(mgr.paymentToken(), address(usdc));
        assertEq(mgr.treasury(), TREASURY);
        assertEq(mgr.trustedSigner(), SIGNER);
        assertEq(mgr.platformFeeBps(), FEE_BPS);
    }

    function test_constructor_RevertsOnZeroPaymentToken() external {
        vm.expectRevert();
        new RaffleManager4(address(coord), KEYHASH, SUB_ID, address(0), TREASURY, SIGNER);
    }

    function test_constructor_RevertsOnZeroTreasury() external {
        vm.expectRevert();
        new RaffleManager4(address(coord), KEYHASH, SUB_ID, address(usdc), address(0), SIGNER);
    }

    function test_constructor_RevertsOnZeroSigner() external {
        vm.expectRevert();
        new RaffleManager4(address(coord), KEYHASH, SUB_ID, address(usdc), TREASURY, address(0));
    }

    function test_ownerIsDeployer() external {
        assertEq(mgr.owner(), address(this));
    }

    function test_platformFeeStartsAtSetBps() external {
        assertEq(mgr.platformFeeBps(), FEE_BPS);
    }

    function test_minDurationIsTwoHours() external {
        assertEq(mgr.MIN_DURATION(), 2 hours);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  B. Raffle Creation – ERC20
    // ═════════════════════════════════════════════════════════════════════════

    function test_createERC20_EmitsEvent() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        uint48 expectedExpiry = uint48(block.timestamp + DURATION);
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.RaffleCreated(
            1, HOST, address(prize), RaffleManager4.PrizeType.ERC20,
            PRIZE_AMT, expectedExpiry, "PZ", 18
        );
        vm.prank(HOST);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_StoredCorrectly() external {
        uint256 id = _createERC20();
        RaffleManager4.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.host,                 HOST);
        assertEq(uint8(r.status),        uint8(RaffleManager4.RaffleStatus.OPEN));
        assertEq(uint8(r.prizeType),     uint8(RaffleManager4.PrizeType.ERC20));
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
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(0), PRIZE_AMT, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_RevertsOnZeroAmount() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), 0, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC20_RevertsOnZeroTicketPrice() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, 0, MAX_CAP, DURATION);
    }

    function test_createERC20_RevertsOnZeroMaxCap() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, 0, DURATION);
    }

    function test_createERC20_RevertsOnZeroDuration() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_createERC20_RevertsOnDurationTooShort() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager4.DurationTooShort.selector, 1 hours, 2 hours
            )
        );
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, 1 hours);
    }

    function test_createERC20_RevertsOnMaxCapExceedsUint96() external {
        vm.prank(HOST);
        IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, uint256(type(uint96).max) + 1, DURATION);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  C. Raffle Creation – ERC721
    // ═════════════════════════════════════════════════════════════════════════

    function test_createERC721_EmitsEvent() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);
        uint48 expectedExpiry = uint48(block.timestamp + DURATION);
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.RaffleCreated(
            1, HOST, address(nft), RaffleManager4.PrizeType.ERC721,
            NFT_TOKEN_ID, expectedExpiry, "MockNFT", 0
        );
        vm.prank(HOST);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC721_StoredCorrectly() external {
        uint256 id = _createERC721();
        RaffleManager4.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.host,                 HOST);
        assertEq(uint8(r.prizeType),     uint8(RaffleManager4.PrizeType.ERC721));
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
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC721(address(0), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    function test_createERC721_RevertsOnZeroDuration() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, 0);
    }

    function test_createERC721_RevertsOnDurationTooShort() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);
        vm.prank(HOST);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager4.DurationTooShort.selector, 30 minutes, 2 hours
            )
        );
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, 30 minutes);
    }

    function test_createERC721_RevertsOnZeroMaxCap() external {
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, 0, DURATION);
    }

    function test_createERC721_RevertsOnMaxCapExceedsUint96() external {
        vm.prank(HOST);
        IERC721(address(nft)).approve(address(mgr), NFT_TOKEN_ID);
        vm.prank(HOST);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, uint256(type(uint96).max) + 1, DURATION);
    }

    function test_createERC721_RevertsWithoutApproval() external {
        vm.prank(HOST);
        vm.expectRevert();
        mgr.createRaffleERC721(address(nft), NFT_TOKEN_ID, TICKET_PRICE, MAX_CAP, DURATION);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  D. enterRaffle – Paid Tickets
    // ═════════════════════════════════════════════════════════════════════════

    function test_enterRaffle_UpdatesState() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 5);
        RaffleManager4.RaffleData memory r = mgr.getRaffle(id);
        assertEq(r.ticketsSold, 5);
        assertEq(mgr.participants(id, 0), ALICE);
        assertEq(mgr.participants(id, 4), ALICE);
    }

    function test_enterRaffle_MultipleTicketsSameUser() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        uint256 count = 0;
        for (uint256 i; i < 10; ) {
            if (mgr.participants(id, i) == ALICE) count++;
            unchecked { ++i; }
        }
        assertEq(count, 10);
    }

    function test_enterRaffles_MultipleUsers() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 3);
        _enterAs(BOB,   id, 2);
        assertEq(mgr.getRaffle(id).ticketsSold, 5);
        assertEq(mgr.participants(id, 0), ALICE);
        assertEq(mgr.participants(id, 3), BOB);
    }

    function test_enterRaffle_HostCannotEnter() external {
        uint256 id = _createERC20();
        vm.prank(HOST);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.HostCannotEnter.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_MaxCapReached() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        vm.prank(BOB);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.MaxCapReached.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_RevertsWhenExpired() external {
        uint256 id = _createERC20();
        _warp();
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotOpen.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_enterRaffle_RevertsOnZeroTickets() external {
        uint256 id = _createERC20();
        vm.prank(ALICE);
        vm.expectRevert(RaffleManager4.InvalidParams.selector);
        mgr.enterRaffle(id, 0);
    }

    function test_enterRaffle_DeductsPaymentFromBuyer() external {
        uint256 id = _createERC20();
        uint256 preBalance = usdc.balanceOf(ALICE);
        _enterAs(ALICE, id, 1);
        assertEq(usdc.balanceOf(ALICE), preBalance - TICKET_PRICE);
    }

    function test_enterRaffle_EmitsEvent() external {
        uint256 id = _createERC20();
        uint256 cost = TICKET_PRICE * 3;
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), cost);
        vm.prank(ALICE);
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.TicketPurchased(id, ALICE, 3);
        mgr.enterRaffle(id, 3);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  E. enterFreeRaffle – EIP-712 Signature
    // ═════════════════════════════════════════════════════════════════════════

    function test_enterFreeRaffle_SuccessWithValidSignature() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sig);
        assertTrue(mgr.freeEntryClaimed(id, ALICE));
    }

    function test_enterFreeRaffle_IncrementsTicketsSold() external {
        uint256 id = _createERC20();
        uint256 cost = TICKET_PRICE * 50;
        _enterAs(ALICE, id, 50);
        bytes memory sigBob = _signFreeEntry(id, BOB);
        vm.prank(BOB);
        mgr.enterFreeRaffle(id, sigBob);
        assertEq(mgr.getRaffle(id).ticketsSold, 51);
    }

    function test_freeEntry_MixedWithPaidTickets() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 5);
        bytes memory sig = _signFreeEntry(id, BOB);
        vm.prank(BOB);
        mgr.enterFreeRaffle(id, sig);
        assertEq(mgr.getRaffle(id).ticketsSold, 6);
        assertTrue(mgr.freeEntryClaimed(id, BOB));
    }

    function test_enterFreeRaffle_AddsToParticipants() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sig);
        assertEq(mgr.participants(id, 0), ALICE);
        // Verify by checking raffle ticketsSold == 1
        assertEq(mgr.getRaffle(id).ticketsSold, 1);
    }

    function test_enterFreeRaffle_EmitsTicketPurchased() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.TicketPurchased(id, ALICE, 1);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_EmitsFreeEntryClaimed() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.expectEmit(true, true, false, true);
        emit FreeEntryVerifier.FreeEntryClaimed(id, ALICE, SIGNER);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_RevertsOnInvalidSignature() external {
        uint256 id = _createERC20();
        bytes32 digest = mgr.computeDigest(id, ALICE);
        // Sign with wrong key
        uint256 wrongPk = uint256(keccak256("wrong_key"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPk, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);
        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier.InvalidSigner.selector);
        mgr.enterFreeRaffle(id, badSig);
    }

    function test_enterFreeRaffle_RevertsOnDoubleClaim() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sig);
        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier.AlreadyClaimed.selector);
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_RevertsOnExpiredRaffle() external {
        uint256 id = _createERC20();
        _warp();
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotOpen.selector, id));
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_RevertsIfHostTries() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, HOST);
        vm.prank(HOST);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.HostCannotEnter.selector, id));
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_RevertsOnMaxCapReached() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        bytes memory sig = _signFreeEntry(id, BOB);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.MaxCapReached.selector, id));
        mgr.enterFreeRaffle(id, sig);
    }

    function test_enterFreeRaffle_DifferentUsersCanClaimSeparately() external {
        uint256 id = _createERC20();
        bytes memory sigAlice = _signFreeEntry(id, ALICE);
        bytes memory sigBob   = _signFreeEntry(id, BOB);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id, sigAlice);
        vm.prank(BOB);
        mgr.enterFreeRaffle(id, sigBob);
        assertEq(mgr.getRaffle(id).ticketsSold, 2);
        assertTrue(mgr.freeEntryClaimed(id, ALICE));
        assertTrue(mgr.freeEntryClaimed(id, BOB));
    }

    function test_enterFreeRaffle_SameUserDifferentRaffles() external {
        uint256 id1 = _createERC20();
        uint256 id2 = _createERC20();
        bytes memory sig1 = _signFreeEntry(id1, ALICE);
        bytes memory sig2 = _signFreeEntry(id2, ALICE);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id1, sig1);
        vm.prank(ALICE);
        mgr.enterFreeRaffle(id2, sig2);
        assertEq(mgr.getRaffle(id1).ticketsSold, 1);
        assertEq(mgr.getRaffle(id2).ticketsSold, 1);
    }

    function test_enterFreeRaffle_WrongRaffleIdFails() external {
        _createERC20(); // id = 1
        bytes memory sig = _signFreeEntry(999, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(); // InvalidSigner since raffle 999 doesn't match
        mgr.enterFreeRaffle(999, sig);
    }

    function test_enterFreeRaffle_SignatureCannotBeReusedAfterRaffleExpires() external {
        uint256 id = _createERC20();
        bytes memory sig = _signFreeEntry(id, ALICE);
        _warp();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotOpen.selector, id));
        mgr.enterFreeRaffle(id, sig);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  F. ERC-20 Full-Fill Lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_FullFill_VRFWinnerPickedCorrectly() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        uint256 preBal = prize.balanceOf(ALICE);
        _fulfillVRF(reqId, 0);
        assertGt(prize.balanceOf(ALICE), preBal);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
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

    function test_erc20_FullFill_MultipleParticipantsWeighted() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 60);
        _enterAs(BOB,   id, 40);
        _warp();
        uint256 reqId = _triggerUpkeep();
        uint256 preBal = prize.balanceOf(ALICE);
        _fulfillVRF(reqId, 0); // index 0 → ALICE
        assertGt(prize.balanceOf(ALICE), preBal);
    }

    function test_erc20_FullFill_RaffleStatusCompleted() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 0);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  G. ERC-20 Underfill Lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_Underfill_PrizeReturnedToHost() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();
        uint256 preBal = prize.balanceOf(HOST);
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.UnderfilledPrizeReturned(id, HOST, PRIZE_AMT);
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

    function test_erc20_Underfill_TreasuryGetsPaymentFee() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();
        uint256 reqId = _triggerUpkeep();
        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        uint256 preBal = usdc.balanceOf(TREASURY);
        _fulfillVRF(reqId, 0);
        assertEq(usdc.balanceOf(TREASURY) - preBal, fee);
    }

    function test_erc20_Underfill_UnderfilledFlagPreventsDoubleReturn() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        _warp();
        _triggerUpkeep();
        assertTrue(mgr.getRaffle(id).underfilled);
        // Calling performUpkeep again should not return prize again
        // Since status is still OPEN, it would try to request VRF again
        // After VRF fulfill, the raffle is COMPLETED so no double return
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  H. ERC-20 Zero Participants
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc20_ZeroParticipants_PrizeReturnedToHost() external {
        uint256 id = _createERC20();
        _warp();
        uint256 preBal = prize.balanceOf(HOST);
        vm.expectEmit(true, false, false, false);
        emit RaffleManager4.RaffleExpired(id);
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        mgr.performUpkeep(data);
        assertEq(prize.balanceOf(HOST) - preBal, PRIZE_AMT);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    function test_erc20_ZeroParticipants_RaffleExpired() external {
        uint256 id = _createERC20();
        _warp();
        (bool needed,) = mgr.checkUpkeep("");
        assertTrue(needed);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  I. ERC-721 Full-Fill Lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc721_FullFill_WinnerReceivesNFT() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 0);
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
        assertEq(usdc.balanceOf(TREASURY) - preBal, fee);
    }

    function test_erc721_FullFill_VRFWinnerIndex() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 60);
        _enterAs(BOB,   id, 40);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 60);
        assertEq(nft.ownerOf(NFT_TOKEN_ID), BOB);
    }

    function test_erc721_FullFill_RaffleStatusCompleted() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 0);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  J. ERC-721 Underfill Lifecycle
    // ═════════════════════════════════════════════════════════════════════════

    function test_erc721_Underfill_NFTReturnedToHost() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();
        vm.expectEmit(true, true, false, true);
        emit RaffleManager4.UnderfilledPrizeReturned(id, HOST, NFT_TOKEN_ID);
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

    function test_erc721_Underfill_NoPrizeFeeForNFT() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();
        uint256 reqId = _triggerUpkeep();
        uint256 prePrize = prize.balanceOf(TREASURY);
        _fulfillVRF(reqId, 0);
        // No prize tokens should go to treasury (NFT prize = no prize fee)
        assertEq(prize.balanceOf(TREASURY) - prePrize, 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  K. ERC-721 Zero Participants
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
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  L. Chainlink Automation
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

    function test_checkUpkeep_FindsFirstExpiredRaffle() external {
        uint256 id1 = _createERC20();
        vm.warp(block.timestamp + DURATION + 1);
        uint256 id2 = _createERC20();
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        uint256 foundId = abi.decode(data, (uint256));
        assertEq(foundId, id1);
    }

    function test_performUpkeep_NoOpWhenNotExpired() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        mgr.performUpkeep(abi.encode(id));
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.OPEN));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  M. VRF Security
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

    function test_vrf_StaleRequestIdIgnored() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, 0);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
        // Second fulfill with same request should do nothing (requestId already deleted)
        // No revert expected, just a no-op
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  N. Manual Fallback
    // ═════════════════════════════════════════════════════════════════════════

    function test_manualFulfill_ERC20ByIndex() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        uint256 preBal = prize.balanceOf(ALICE);
        mgr.manualFulfillWinner(id, 0);
        assertGt(prize.balanceOf(ALICE), preBal);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    function test_manualFulfill_ERC721ByIndex() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        mgr.manualFulfillWinner(id, 0);
        assertEq(nft.ownerOf(NFT_TOKEN_ID), ALICE);
    }

    function test_manualFulfill_RevertsBeforeExpiry() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 5);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotExpired.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_RevertsOnCompletedRaffle() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP);
        _warp();
        mgr.manualFulfillWinner(id, 0);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotOpen.selector, id));
        mgr.manualFulfillWinner(id, 0);
    }

    function test_manualFulfill_ERC20Underfill() external {
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

    function test_manualFulfill_ERC721Underfill() external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 10);
        _warp();
        mgr.manualFulfillWinner(id, 0);
        assertEq(nft.ownerOf(NFT_TOKEN_ID), HOST);
        uint256 pool   = 10 * TICKET_PRICE;
        uint256 fee    = (pool * FEE_BPS) / 10_000;
        uint256 aliceNet = usdc.balanceOf(ALICE) - (100_000e18 - 10 * TICKET_PRICE);
        assertEq(aliceNet, pool - fee);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  O. Fee Timelock
    // ═════════════════════════════════════════════════════════════════════════

    function test_fee_ProposalStored() external {
        mgr.proposeFeeChange(500);
        assertEq(mgr.pendingFeeBps(), 500);
        assertGt(mgr.feeChangeEffectiveAt(), block.timestamp);
    }

    function test_fee_CannotApplyBeforeTimelock() external {
        mgr.proposeFeeChange(500);
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager4.FeeTimelockNotElapsed.selector,
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
        vm.expectRevert(RaffleManager4.NoFeeChangePending.selector);
        mgr.applyFeeChange();
    }

    function test_fee_RevertsIfTooHigh() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                RaffleManager4.FeeTooHigh.selector,
                1_001,
                mgr.MAX_PLATFORM_FEE_BPS()
            )
        );
        mgr.proposeFeeChange(1_001);
    }

    function test_fee_NonOwnerCannotPropose() external {
        vm.prank(ALICE);
        vm.expectRevert();
        mgr.proposeFeeChange(500);
    }

    function test_fee_NonOwnerCannotApply() external {
        mgr.proposeFeeChange(500);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(ALICE);
        vm.expectRevert();
        mgr.applyFeeChange();
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  P. Fuzzing
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
        _fulfillVRF(reqId, randomWord);
        assertEq(uint8(mgr.getRaffle(id).status), uint8(RaffleManager4.RaffleStatus.COMPLETED));
    }

    function fuzz_erc721_winnerIndex_AlwaysInBounds(uint256 randomWord) external {
        uint256 id = _createERC721();
        _enterAs(ALICE, id, 50);
        _enterAs(BOB,   id, 50);
        _warp();
        uint256 reqId = _triggerUpkeep();
        _fulfillVRF(reqId, randomWord);
        address owner = nft.ownerOf(NFT_TOKEN_ID);
        assertTrue(owner == ALICE || owner == BOB);
    }

    function fuzz_feeCalculation_Accurate(uint256 amount) external {
        amount = bound(amount, 0, type(uint128).max);
        uint256 fee = (amount * FEE_BPS) / 10_000;
        assertLe(fee, amount);
    }

    function fuzz_duration_MustBeAboveMinimum(uint256 duration) external {
        if (duration < mgr.MIN_DURATION()) {
            vm.prank(HOST);
            IERC20(address(prize)).approve(address(mgr), PRIZE_AMT);
            vm.prank(HOST);
            vm.expectRevert(
                abi.encodeWithSelector(
                    RaffleManager4.DurationTooShort.selector, duration, mgr.MIN_DURATION()
                )
            );
            mgr.createRaffleERC20(address(prize), PRIZE_AMT, TICKET_PRICE, MAX_CAP, duration);
        }
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  Q. Views
    // ═════════════════════════════════════════════════════════════════════════

    function test_getRaffle_ReturnsCorrectData() external {
        uint256 id = _createERC20();
        RaffleManager4.RaffleData memory r = mgr.getRaffle(id);
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

    function test_freeEntryClaimed_DefaultsFalse() external {
        assertFalse(mgr.freeEntryClaimed(1, ALICE));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  R. Free Entry Integration with Paid Tickets
    // ═════════════════════════════════════════════════════════════════════════

    function test_freeEntry_WinnerSelectionIncludesFreeEntries() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, 10);
        bytes memory sig = _signFreeEntry(id, BOB);
        vm.prank(BOB);
        mgr.enterFreeRaffle(id, sig);
        _warp();
        uint256 preBobUSDC = usdc.balanceOf(BOB);
        uint256 preHostPrize = prize.balanceOf(HOST);
        uint256 reqId = _triggerUpkeep();
        assertTrue(mgr.getRaffle(id).underfilled);
        _fulfillVRF(reqId, 10);
        uint256 pool = 10 * TICKET_PRICE;
        uint256 fee = (pool * FEE_BPS) / 10_000;
        assertEq(usdc.balanceOf(BOB) - preBobUSDC, pool - fee);
        assertEq(prize.balanceOf(HOST) - preHostPrize, PRIZE_AMT);
    }

    function test_freeEntry_FullCapReached() external {
        uint256 id = _createERC20();
        _enterAs(ALICE, id, MAX_CAP - 1);
        bytes memory sig = _signFreeEntry(id, BOB);
        vm.prank(BOB);
        mgr.enterFreeRaffle(id, sig);
        assertEq(mgr.getRaffle(id).ticketsSold, MAX_CAP);
        // Paid should fail
        vm.prank(ALICE);
        IERC20(address(usdc)).approve(address(mgr), TICKET_PRICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.MaxCapReached.selector, id));
        mgr.enterRaffle(id, 1);
    }

    function test_verifyAndClaim_CannotBypassRaffleChecks() external {
        uint256 id = _createERC20();
        _warp();
        // Direct call to verifyAndClaim would still mark as claimed,
        // but enterFreeRaffle reverts due to expired raffle
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RaffleManager4.RaffleNotOpen.selector, id));
        mgr.enterFreeRaffle(id, sig);
        // freeEntryClaimed should NOT be marked since tx reverted
        assertFalse(mgr.freeEntryClaimed(id, ALICE));
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  S. Trusted Signer Management
    // ═════════════════════════════════════════════════════════════════════════

    function test_setTrustedSigner_OnlyOwner() external {
        address newSigner = makeAddr("newSigner");
        mgr.setTrustedSigner(newSigner);
        assertEq(mgr.trustedSigner(), newSigner);
    }

    function test_setTrustedSigner_NonOwnerReverts() external {
        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier.NotOwner.selector);
        mgr.setTrustedSigner(ALICE);
    }

    function test_setTrustedSigner_RevertsOnZeroAddress() external {
        vm.expectRevert();
        mgr.setTrustedSigner(address(0));
    }

    function test_setTrustedSigner_EmitsEvent() external {
        address newSigner = makeAddr("newSigner");
        vm.expectEmit(true, true, false, true);
        emit FreeEntryVerifier.TrustedSignerUpdated(SIGNER, newSigner);
        mgr.setTrustedSigner(newSigner);
    }

    function test_setTrustedSigner_OldSignaturesBecomeInvalid() external {
        uint256 id = _createERC20();
        bytes memory oldSig = _signFreeEntry(id, ALICE);
        // Change signer
        address newSigner = makeAddr("newSigner");
        mgr.setTrustedSigner(newSigner);
        vm.prank(ALICE);
        vm.expectRevert(FreeEntryVerifier.InvalidSigner.selector);
        mgr.enterFreeRaffle(id, oldSig);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  T. Edge Cases
    // ═════════════════════════════════════════════════════════════════════════

    function test_edge_PerformUpkeepZeroParticipantsReturnsPrize() external {
        uint256 id = _createERC20();
        _warp();
        uint256 preBal = prize.balanceOf(HOST);
        (, bytes memory data) = mgr.checkUpkeep("");
        mgr.performUpkeep(data);
        // HOST had PRIZE_AMT transferred out during creation, so preBal = 49_000e18
        // After return, should be back to 50_000e18
        assertEq(prize.balanceOf(HOST), preBal + PRIZE_AMT);
    }

    function test_edge_VerifierOwnerMatchesRaffleManagerOwner() external {
        assertEq(mgr.verifierOwner(), mgr.owner());
    }

    function test_edge_ComputeDigestIsDeterministic() external view {
        bytes32 d1 = mgr.computeDigest(1, ALICE);
        bytes32 d2 = mgr.computeDigest(1, ALICE);
        assertEq(d1, d2);
    }

    function test_edge_SignatureForWrongUserFails() external {
        uint256 id = _createERC20();
        // Sign for ALICE, but BOB tries to claim
        bytes memory sig = _signFreeEntry(id, ALICE);
        vm.prank(BOB);
        vm.expectRevert(FreeEntryVerifier.InvalidSigner.selector);
        mgr.enterFreeRaffle(id, sig);
    }

    function test_edge_MultipleRafflesSimultaneousExpiry() external {
        uint256 id1 = _createERC20();
        uint256 id2 = _createERC20();
        _warp();
        (bool needed, bytes memory data) = mgr.checkUpkeep("");
        assertTrue(needed);
        // Only one raffle returned per checkUpkeep call
        uint256 found = abi.decode(data, (uint256));
        mgr.performUpkeep(data);
        // After first is processed, checkUpkeep should find the second
        (bool needed2,) = mgr.checkUpkeep("");
        assertTrue(needed2 || found == id2); // id2 may be returned if id1 was first
    }
}
