// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {PerformUpkeepWithReentrant} from "../test/mocks/PerformUpkeepWithReentrant.sol";

contract DeployPerformUpkeepWithReentrant is Script {
    function run()
        external
        returns (PerformUpkeepWithReentrant performUpkeepWithReentrant)
    {
        // Load configuration from environment variables
        uint256 deployerKey;
        address deployer;

        // Load deployer private key (required for broadcast)
        deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerKey);
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
        address trustedSigner = vm.envOr(
            "TRUSTED_SIGNER",
            deployerKey != 0 ? vm.addr(deployerKey) : address(0)
        );

        // ── Validate critical params ────────────────────────────────────────
        require(vrfCoordinator != address(0), "VRF_COORDINATOR required");
        require(trustedSigner != address(0), "TRUSTED_SIGNER required");
        require(subId != 0, "SUB_ID required");

        // Deploy PerformUpkeepWithReentrant
        vm.startBroadcast(deployerKey);
        performUpkeepWithReentrant = new PerformUpkeepWithReentrant(
            vrfCoordinator,
            keyHash,
            subId,
            trustedSigner
        );
        console.log(
            "Deployed PerformUpkeepWithReentrant at: %s",
            address(performUpkeepWithReentrant)
        );
        vm.stopBroadcast();

        return performUpkeepWithReentrant;
    }
}
