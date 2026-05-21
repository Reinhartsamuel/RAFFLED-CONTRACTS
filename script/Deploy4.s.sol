// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager4} from "../src/RaffleManager4.sol";

/// @notice Deployment script for RaffleManager4.
///
/// PREREQUISITES (must be set in .env):
///   DEPLOYER_PRIVATE_KEY  – deployer wallet private key
///   VRF_COORDINATOR       – Chainlink VRF v2.5 Coordinator address
///   KEY_HASH              – Chainlink key hash for gas lane
///   SUB_ID                – Chainlink VRF subscription ID
///   PAYMENT_TOKEN         – ERC-20 token address for ticket payments (e.g. USDC)
///   TREASURY              – Treasury address that receives platform fees
///   TRUSTED_SIGNER        – Backend signer address for free entry EIP-712 signatures
///   INITIAL_FEE_BPS       – (optional) Initial platform fee in basis points, default 0
///
/// DRY-RUN (no broadcast, simulation only):
///   forge script script/Deploy4.s.sol:Deploy4 --rpc-url $RPC_URL -vvv
///
/// BROADCAST (real deployment):
///   forge script script/Deploy4.s.sol:Deploy4 --rpc-url $RPC_URL --broadcast --verify -vvv
///
/// LOCAL TESTING (Anvil, no env vars needed):
///   forge script script/Deploy4.s.sol:Deploy4
///

contract Deploy4 is Script {
    function run() external returns (RaffleManager4 raffle) {
        // ── Load configuration ──────────────────────────────────────────────
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));

        address vrfCoordinator = vm.envAddress(
            "VRF_COORDINATOR"
            // address(0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE) // Base Sepolia default
        );
        bytes32 keyHash = vm.envBytes32(
            "KEY_HASH"
            // bytes32(0x9e1344a1247c8a1785d0a4681a27152bffdb43666ae5bf7d14d24a5efd44bf71) // Base Sepolia default
        );
        uint256 subId = vm.envUint(
            "SUB_ID"
            // uint256(1)
        );

        address paymentToken = vm.envAddress(
            "MOCK_USDC"
            // address(0x417dae58f22f6C105DfC0f18B2cF3495CD07Bd72) // Mock USDC default
        );
        address treasury = vm.envAddress(
            "MOCK_TREASURY"
            // address(0x753dFC03b4d37B3a316D0Fe5aB9F677C0D3C20f8) // Default treasury
        );
        address trustedSigner = vm.envOr(
            "TRUSTED_SIGNER",
            deployerKey != 0 ? vm.addr(deployerKey) : address(0)
        );

        uint256 initialFeeBps = vm.envOr("INITIAL_FEE_BPS", uint256(500));

        // ── Validate critical params ────────────────────────────────────────
        require(vrfCoordinator != address(0), "VRF_COORDINATOR required");
        require(paymentToken != address(0), "PAYMENT_TOKEN required");
        require(treasury != address(0), "TREASURY required");
        require(trustedSigner != address(0), "TRUSTED_SIGNER required");

        // ── Deploy ──────────────────────────────────────────────────────────
        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        }

        raffle = new RaffleManager4(
            vrfCoordinator,
            keyHash,
            subId,
            paymentToken,
            treasury,
            trustedSigner
        );

        if (initialFeeBps > 0) {
            raffle.proposeFeeChange(initialFeeBps);
            // Warp forward past timelock only in local/fork simulations
            // On live chains this requires a second tx after 2 days
        }

        if (deployerKey != 0) {
            vm.stopBroadcast();
        }

        // ── Output ──────────────────────────────────────────────────────────
        console.log("===========================================");
        console.log("RaffleManager4 deployed to:");
        console.logAddress(address(raffle));
        console.log("");
        console.log("Configuration:");
        console.log("  Payment Token :");
        console.logAddress(paymentToken);
        console.log("  Treasury      :");
        console.logAddress(treasury);
        console.log("  Trusted Signer:");
        console.logAddress(trustedSigner);
        console.log("  VRF Coordinator:");
        console.logAddress(vrfCoordinator);
        console.log("  Min Duration  : 2 hours");
        console.log("");
        console.log("Next steps:");
        console.log("1. Add RaffleManager4 as VRF consumer on vrf.chain.link");
        console.log("2. Fund VRF subscription with LINK");
        console.log("3. If INITIAL_FEE_BPS > 0, call applyFeeChange() after 2 days");
        console.log("4. Verify: forge verify-contract <address> src/RaffleManager4.sol:RaffleManager4");
        console.log("===========================================");

        return raffle;
    }
}
