// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {RaffleManager} from "../src/RaffleManager.sol";

/// @notice Deployment script for RaffleManager with automatic verification.
///
/// PREREQUISITES (must be set in .env or exported):
///   - RPC_URL              Blockchain RPC endpoint
///   - DEPLOYER_PRIVATE_KEY Deployer account private key
///   - ETHERSCAN_API_KEY    For contract verification
///   - VRF_COORDINATOR      Chainlink VRF v2.5 Coordinator address
///   - KEY_HASH             Chainlink key hash for gas lane
///   - SUB_ID               Chainlink VRF subscription ID
///
/// DEPLOY TO TESTNET (with verification):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvv
///
/// DEPLOY TO TESTNET (skip verification):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast -vvv
///
/// DRY-RUN (no broadcast):
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL -vvv
///
/// LOCAL TESTING (no env vars needed):
///   forge script script/Deploy.s.sol
///
contract Deploy is Script {
    function run() external returns (RaffleManager raffle) {
        // Load configuration from environment variables
        address vrfCoordinator;
        bytes32 keyHash;
        uint256 subId;
        uint256 deployerKey;

        // Check if running in production mode (VRF_COORDINATOR env var set)
        if (isProduction()) {
            vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
            keyHash        = vm.envBytes32("KEY_HASH");
            subId          = vm.envUint("SUB_ID");
        } else {
            // Local dry-run with placeholder values
            vrfCoordinator = address(0xDEAD);
            keyHash        = keccak256("dry_run");
            subId          = 1;
        }

        // Load deployer private key (required for broadcast)
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Deploy RaffleManager
        vm.startBroadcast(deployerKey);
        raffle = new RaffleManager(vrfCoordinator, keyHash, subId);
        vm.stopBroadcast();

        return raffle;
    }

    /// @notice Check if running in production mode.
    /// @return True if VRF_COORDINATOR environment variable is set.
    function isProduction() internal view returns (bool) {
        try vm.envAddress("VRF_COORDINATOR") returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}
