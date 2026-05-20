// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager3}  from "../src/RaffleManager3.sol";

/// @notice Phase B – resolve all test raffles created by TestScenarios_Create.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// WHAT THIS SCRIPT DOES
/// ─────────────────────────────────────────────────────────────────────────────
/// Resolves the 8 raffles from Phase A, one per path:
///
///   Raffle 1  – manualFulfillWinnerByRandomWord  (ERC-20 full-fill)
///   Raffle 2  – manualFulfillWinner by index     (ERC-20 full-fill, zero fee)
///   Raffle 3  – manualFulfillWinner by index     (ERC-20 underfill)
///   Raffle 4  – performUpkeep                    (ERC-20 zero participants)
///   Raffle 5  – manualFulfillWinnerByRandomWord  (ERC-20, prize = payment token)
///   Raffle 6  – manualFulfillWinner by index     (ERC-20 multi-ticket buyer)
///   Raffle 7  – manualFulfillWinner by index     (ERC-721 full-fill)
///   Raffle 8  – manualFulfillWinner by index     (ERC-721 underfill)
///
/// Events emitted by this script:
///   UnderfilledPrizeReturned  × 3  (raffles 3, 4, 8)
///   WinnerPicked              × 7  (raffles 1–3, 5–8)
///   PlatformFeeCollected      × 2  (raffles 1, 7 — only if fee > 0 at resolve time)
///   RaffleExpired             × 1  (raffle 4)
///
/// ─────────────────────────────────────────────────────────────────────────────
/// PREREQUISITES
/// ─────────────────────────────────────────────────────────────────────────────
/// In your .env (add IDs printed by Phase A):
///   DEPLOYER_PRIVATE_KEY
///   RAFFLE_MANAGER
///   RAFFLE_ID_1=...
///   RAFFLE_ID_2=...
///   RAFFLE_ID_3=...
///   RAFFLE_ID_4=...
///   RAFFLE_ID_5=...
///   RAFFLE_ID_6=...
///   RAFFLE_ID_7=...
///   RAFFLE_ID_8=...
///
/// ─────────────────────────────────────────────────────────────────────────────
/// HOW TO RUN (wait at least 3 minutes after Phase A)
/// ─────────────────────────────────────────────────────────────────────────────
///   forge script script/TestScenarios_Resolve.s.sol \
///     --rpc-url $RPC_URL \
///     --broadcast \
///     -vvv
/// ─────────────────────────────────────────────────────────────────────────────

contract TestScenarios_Resolve is Script {

    function run() external {
        address raffleManager = vm.envAddress("RAFFLE_MANAGER");
        uint256 deployerKey   = vm.envUint("DEPLOYER_PRIVATE_KEY");

        uint256 id1 = vm.envUint("RAFFLE_ID_1");
        uint256 id2 = vm.envUint("RAFFLE_ID_2");
        uint256 id3 = vm.envUint("RAFFLE_ID_3");
        uint256 id4 = vm.envUint("RAFFLE_ID_4");
        uint256 id5 = vm.envUint("RAFFLE_ID_5");
        uint256 id6 = vm.envUint("RAFFLE_ID_6");
        uint256 id7 = vm.envUint("RAFFLE_ID_7");
        uint256 id8 = vm.envUint("RAFFLE_ID_8");

        RaffleManager3 mgr = RaffleManager3(raffleManager);

        console.log("=== Phase B: Resolving test raffles (RaffleManager3) ===");

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 1 – ERC-20 full-fill
        //   randomWord=12345, winner index = 12345 % 2 = 1 → participant2 wins
        //   Events: WinnerPicked, PlatformFeeCollected (if fee applied)
        //   Distribution: winner gets prize - fee, host gets payments - fee
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinnerByRandomWord(id1, 12345);
        vm.stopBroadcast();
        console.log("Raffle 1 resolved (ERC-20 full-fill, randomWord=12345) | id:", id1);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 2 – ERC-20 full-fill, zero fee
        //   index=0 → participant1 wins
        //   Events: WinnerPicked only (no PlatformFeeCollected, fee=0)
        //   Distribution: winner gets full prize, host gets full payments
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinner(id2, 0);
        vm.stopBroadcast();
        console.log("Raffle 2 resolved (ERC-20 full-fill, zero fee, index=0) | id:", id2);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 3 – ERC-20 underfill
        //   index=0 → participant1 wins (bought slots 0 and 1)
        //   Events: UnderfilledPrizeReturned, WinnerPicked, PlatformFeeCollected
        //   Distribution: host gets prize back, winner gets payment pool - fee
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinner(id3, 0);
        vm.stopBroadcast();
        console.log("Raffle 3 resolved (ERC-20 underfill, index=0) | id:", id3);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 4 – ERC-20 zero participants
        //   performUpkeep hits the zero-participant branch, skips VRF entirely
        //   Events: UnderfilledPrizeReturned, RaffleExpired
        //   Distribution: host gets prize back, no winner
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.performUpkeep(abi.encode(id4));
        vm.stopBroadcast();
        console.log("Raffle 4 resolved (ERC-20 zero participants, RaffleExpired) | id:", id4);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 5 – ERC-20, prize asset = payment token
        //   randomWord=99, winner index = 99 % 2 = 1 → participant2 wins
        //   Tests same-token accounting: both prize and payment are USDC
        //   Events: WinnerPicked, PlatformFeeCollected
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinnerByRandomWord(id5, 99);
        vm.stopBroadcast();
        console.log("Raffle 5 resolved (ERC-20 prize=payment token, randomWord=99) | id:", id5);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 6 – ERC-20 multi-ticket buyer, underfill
        //   index=0 → participant1 wins (holds slots 0–4 from buying 5 tickets)
        //   Events: UnderfilledPrizeReturned, WinnerPicked
        //   Distribution: host gets prize back, winner (P1) gets payment pool
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinner(id6, 0);
        vm.stopBroadcast();
        console.log("Raffle 6 resolved (ERC-20 multi-ticket, index=0) | id:", id6);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 7 – ERC-721 full-fill
        //   index=1 → participant2 wins the NFT
        //   Events: WinnerPicked, PlatformFeeCollected (payment fee only — NFT indivisible)
        //   Distribution: winner gets NFT, host gets payment pool - fee, treasury gets payment fee
        //   Note: no prize fee is taken on the NFT (unlike ERC-20 full-fill)
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinner(id7, 1);
        vm.stopBroadcast();
        console.log("Raffle 7 resolved (ERC-721 full-fill, index=1) | id:", id7);

        // ─────────────────────────────────────────────────────────────────────
        // RAFFLE 8 – ERC-721 underfill
        //   index=0 → participant1 wins payment pool
        //   Events: UnderfilledPrizeReturned (NFT back to host), WinnerPicked
        //   Distribution: host gets NFT back, winner gets payment pool - fee
        // ─────────────────────────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        mgr.manualFulfillWinner(id8, 0);
        vm.stopBroadcast();
        console.log("Raffle 8 resolved (ERC-721 underfill, index=0) | id:", id8);

        // ── Summary ───────────────────────────────────────────────────────────
        console.log("");
        console.log("=== Phase B complete ===");
        console.log("");
        console.log("All events indexed by your backend:");
        console.log("  [Phase A]");
        console.log("  FeeChangeProposed         x1  (raffle 1 setup)");
        console.log("  RaffleCreated             x8");
        console.log("  TicketPurchased           xN");
        console.log("  [Phase B]");
        console.log("  UnderfilledPrizeReturned  x3  (raffles 3, 4, 8)");
        console.log("  WinnerPicked              x7  (raffles 1-3, 5-8)");
        console.log("  PlatformFeeCollected      x2  (raffles 1, 7 - if fee > 0)");
        console.log("  RaffleExpired             x1  (raffle 4)");
    }
}
