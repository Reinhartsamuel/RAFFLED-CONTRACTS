// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {RaffleManager} from "../src/RaffleManager.sol";
import {FreeEntryVerifier} from "../src/FreeEntryVerifier.sol";

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
    function run() external returns (FreeEntryVerifier freeEntryVerifier) {
        // Load configuration from environment variables
        uint256 deployerKey;
        address deployer;


        // Load deployer private key (required for broadcast)
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);

        // Deploy FreeEntryVerifier
        vm.startBroadcast(deployerKey);
        freeEntryVerifier = new FreeEntryVerifier(deployer, deployer);
        console.log("Deployed FreeEntryVerifier at: %s", address(freeEntryVerifier));
        vm.stopBroadcast();

        return freeEntryVerifier;
    }
}