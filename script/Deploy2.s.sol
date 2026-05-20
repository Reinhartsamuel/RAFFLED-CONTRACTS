// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {RaffleManager2} from "../src/RaffleManager2.sol";

/// @notice Deployment script for RaffleManager2.
///
/// PREREQUISITES (must be set in .env or exported):
///   - DEPLOYER_PRIVATE_KEY Deployer account private key
///   - VRF_COORDINATOR      Chainlink VRF v2.5 Coordinator address
///   - KEY_HASH             Chainlink key hash for gas lane
///   - SUB_ID               Chainlink VRF subscription ID
///   - PAYMENT_TOKEN        ERC-20 payment token address (e.g. USDC)
///   - TREASURY             Treasury address for platform fees
///
/// DEPLOY:
///   forge script script/Deploy2.s.sol --rpc-url $RPC_URL --broadcast --verify -vvv
///
/// DRY-RUN:
///   forge script script/Deploy2.s.sol --rpc-url $RPC_URL -vvv
///
contract Deploy2 is Script {
    function run() external returns (RaffleManager2 raffle) {
        address vrfCoordinator;
        bytes32 keyHash;
        uint256 subId;
        address paymentToken;
        address treasury;

        if (isProduction()) {
            vrfCoordinator = vm.envAddress("VRF_COORDINATOR");
            keyHash        = vm.envBytes32("KEY_HASH");
            subId          = vm.envUint("SUB_ID");
            paymentToken   = vm.envAddress("PAYMENT_TOKEN");
            treasury       = vm.envAddress("TREASURY");
        } else {
            vrfCoordinator = address(0xDEAD);
            keyHash        = keccak256("dry_run");
            subId          = 1;
            paymentToken   = vm.envAddress("MOCK_USDC");
            treasury       =  vm.envAddress("MOCK_TREASURY");
        }

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        raffle = new RaffleManager2(vrfCoordinator, keyHash, subId, paymentToken, treasury);
        vm.stopBroadcast();

        return raffle;
    }

    function isProduction() internal view returns (bool) {
        try vm.envAddress("VRF_COORDINATOR") returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}
