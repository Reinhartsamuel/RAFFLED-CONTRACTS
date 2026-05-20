// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager3}  from "../src/RaffleManager3.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Phase A – create all test raffles and purchase tickets.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// WHAT THIS SCRIPT DOES
/// ─────────────────────────────────────────────────────────────────────────────
/// Creates 8 raffles covering every meaningful backend-indexing path in RaffleManager3:
///
///   Raffle 1  – ERC-20 prize, full-fill  + fee
///   Raffle 2  – ERC-20 prize, full-fill  + zero fee
///   Raffle 3  – ERC-20 prize, underfill  + fee
///   Raffle 4  – ERC-20 prize, zero participants  (RaffleExpired)
///   Raffle 5  – ERC-20 prize = payment token (USDC as prize + ticket payment)
///   Raffle 6  – ERC-20 prize, multi-ticket single buyer
///   Raffle 7  – ERC-721 prize, full-fill  (NFT prize, no prize fee)
///   Raffle 8  – ERC-721 prize, underfill  (NFT returned to host)
///
/// Events emitted by this script:
///   FeeChangeProposed   x1
///   RaffleCreated       x8
///   TicketPurchased     xN
///
/// ─────────────────────────────────────────────────────────────────────────────
/// PREREQUISITES
/// ─────────────────────────────────────────────────────────────────────────────
/// In your .env set:
///   DEPLOYER_PRIVATE_KEY   – host wallet (owns MockUSDC + MockNFT)
///   PARTICIPANT_1_KEY      – burner wallet #1 (needs MockUSDC + ETH for gas)
///   PARTICIPANT_2_KEY      – burner wallet #2 (needs MockUSDC + ETH for gas)
///   RAFFLE_MANAGER         – deployed RaffleManager3 address
///   MOCK_USDC              – deployed MockUSDC address
///   MOCK_NFT               – deployed MockNFT address (ERC-721)
///
/// ─────────────────────────────────────────────────────────────────────────────
/// HOW TO RUN
/// ─────────────────────────────────────────────────────────────────────────────
///   forge script script/TestScenarios_Create.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     -vvv
///
/// After running: copy the printed raffle IDs into .env, wait 3 minutes, run Phase B.
/// ─────────────────────────────────────────────────────────────────────────────

interface IMockNFT {
    function mint(address to) external returns (uint256 tokenId);
    function approve(address to, uint256 tokenId) external;
}

contract TestScenarios_Create is Script {

    // ── Raffle parameters ─────────────────────────────────────────────────────
    uint256 constant DURATION     = 3 minutes;
    uint256 constant TICKET_PRICE = 1e6;       // 1 USDC (6 decimals)
    uint256 constant PRIZE_AMOUNT = 10e6;      // 10 USDC
    uint256 constant FEE_BPS      = 250;       // 2.5%

    // ── Shared state set in run(), used by helpers ────────────────────────────
    address raffleManager;
    address mockUsdc;
    address mockNft;
    uint256 deployerKey;
    uint256 participant1Key;
    uint256 participant2Key;

    function run() external {
        raffleManager   = vm.envAddress("RAFFLE_MANAGER");
        mockUsdc        = vm.envAddress("MOCK_USDC");
        mockNft         = vm.envAddress("MOCK_NFT");
        deployerKey     = vm.envUint("DEPLOYER_PRIVATE_KEY");
        participant1Key = vm.envUint("PARTICIPANT_1_KEY");
        participant2Key = vm.envUint("PARTICIPANT_2_KEY");

        address host         = vm.addr(deployerKey);
        address participant1 = vm.addr(participant1Key);
        address participant2 = vm.addr(participant2Key);

        console.log("=== Phase A: Creating test raffles (RaffleManager3) ===");
        console.log("Host        :", host);
        console.log("Participant1:", participant1);
        console.log("Participant2:", participant2);

        // Mint MockUSDC to participants
        vm.startBroadcast(deployerKey);
        (bool ok1,) = mockUsdc.call(abi.encodeWithSignature("mint(address,uint256)", participant1, 1_000e6));
        (bool ok2,) = mockUsdc.call(abi.encodeWithSignature("mint(address,uint256)", participant2, 1_000e6));
        require(ok1 && ok2, "mint failed");
        vm.stopBroadcast();

        // Propose fee change — emits FeeChangeProposed for backend indexing
        vm.startBroadcast(deployerKey);
        RaffleManager3(raffleManager).proposeFeeChange(FEE_BPS);
        console.log("Fee change proposed: 250 bps (2.5%), effective in 2 days");
        vm.stopBroadcast();

        uint256 id1 = _createERC20Raffles();
        uint256 id5 = _createSpecialERC20Raffles();
        uint256 id7 = _createERC721Raffles();

        console.log("");
        console.log("=== All raffles created. Add these to your .env ===");
        console.log("RAFFLE_ID_1=", id1);
        console.log("RAFFLE_ID_2=", id1 + 1);
        console.log("RAFFLE_ID_3=", id1 + 2);
        console.log("RAFFLE_ID_4=", id1 + 3);
        console.log("RAFFLE_ID_5=", id5);
        console.log("RAFFLE_ID_6=", id5 + 1);
        console.log("RAFFLE_ID_7=", id7);
        console.log("RAFFLE_ID_8=", id7 + 1);
        console.log("");
        console.log("Wait 3 minutes, then run Phase B:");
        console.log("forge script script/TestScenarios_Resolve.s.sol --rpc-url $RPC_URL --broadcast -vvv");
    }

    /// @dev Raffles 1–4: standard ERC-20 prize scenarios.
    /// Returns the first raffle ID created (IDs are sequential from there).
    function _createERC20Raffles() internal returns (uint256 firstId) {
        RaffleManager3 mgr  = RaffleManager3(raffleManager);
        IERC20         usdc = IERC20(mockUsdc);

        // Raffle 1 – ERC-20 full-fill + fee
        // maxCap=2, P1 buys 1, P2 buys 1
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        firstId = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 2, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();
        console.log("Raffle 1 created (ERC-20 full-fill) | id:", firstId);

        // Raffle 2 – ERC-20 full-fill + zero fee (fee is 0 until applyFeeChange)
        uint256 id2;
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        id2 = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 2, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(id2, 1);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(id2, 1);
        vm.stopBroadcast();
        console.log("Raffle 2 created (ERC-20 full-fill + zero fee) | id:", id2);

        // Raffle 3 – ERC-20 underfill + fee
        // maxCap=10, P1 buys 2, P2 buys 1
        uint256 id3;
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        id3 = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 10, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE * 2);
        mgr.enterRaffle(id3, 2);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(id3, 1);
        vm.stopBroadcast();
        console.log("Raffle 3 created (ERC-20 underfill) | id:", id3);

        // Raffle 4 – ERC-20 zero participants (no enterRaffle calls)
        uint256 id4;
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        id4 = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 5, DURATION);
        vm.stopBroadcast();
        console.log("Raffle 4 created (ERC-20 zero participants) | id:", id4);
    }

    /// @dev Raffles 5–6: special ERC-20 scenarios.
    /// Returns the first raffle ID created.
    function _createSpecialERC20Raffles() internal returns (uint256 firstId) {
        RaffleManager3 mgr  = RaffleManager3(raffleManager);
        IERC20         usdc = IERC20(mockUsdc);

        // Raffle 5 – prize asset = payment token (USDC prize + USDC tickets)
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        firstId = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 2, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();
        console.log("Raffle 5 created (ERC-20 prize=payment token) | id:", firstId);

        // Raffle 6 – multi-ticket single buyer
        // P1 buys 5 in one call, P2 buys 1 → 6 of 10 cap → underfill
        uint256 id6;
        vm.startBroadcast(deployerKey);
        usdc.approve(raffleManager, PRIZE_AMOUNT);
        id6 = mgr.createRaffleERC20(mockUsdc, PRIZE_AMOUNT, TICKET_PRICE, 10, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE * 5);
        mgr.enterRaffle(id6, 5);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(id6, 1);
        vm.stopBroadcast();
        console.log("Raffle 6 created (ERC-20 multi-ticket buyer) | id:", id6);
    }

    /// @dev Raffles 7–8: ERC-721 prize scenarios.
    /// Returns the first raffle ID created.
    function _createERC721Raffles() internal returns (uint256 firstId) {
        RaffleManager3 mgr  = RaffleManager3(raffleManager);
        IERC20         usdc = IERC20(mockUsdc);
        address        host = vm.addr(deployerKey);

        // Raffle 7 – ERC-721 full-fill
        uint256 tokenId1;
        vm.startBroadcast(deployerKey);
        tokenId1 = IMockNFT(mockNft).mint(host);
        IMockNFT(mockNft).approve(raffleManager, tokenId1);
        firstId = mgr.createRaffleERC721(mockNft, tokenId1, TICKET_PRICE, 2, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();

        vm.startBroadcast(participant2Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(firstId, 1);
        vm.stopBroadcast();
        console.log("Raffle 7 created (ERC-721 full-fill) | id:", firstId, "| tokenId:", tokenId1);

        // Raffle 8 – ERC-721 underfill (NFT returned to host)
        // maxCap=5, only P1 buys 1 ticket
        uint256 tokenId2;
        uint256 id8;
        vm.startBroadcast(deployerKey);
        tokenId2 = IMockNFT(mockNft).mint(host);
        IMockNFT(mockNft).approve(raffleManager, tokenId2);
        id8 = mgr.createRaffleERC721(mockNft, tokenId2, TICKET_PRICE, 5, DURATION);
        vm.stopBroadcast();

        vm.startBroadcast(participant1Key);
        usdc.approve(raffleManager, TICKET_PRICE);
        mgr.enterRaffle(id8, 1);
        vm.stopBroadcast();
        console.log("Raffle 8 created (ERC-721 underfill) | id:", id8, "| tokenId:", tokenId2);
    }
}
