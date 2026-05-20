// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";
import {console} from "forge-std/console.sol";

/// @notice Deployment script for MockERC721 NFT
///
/// USAGE:
///   # Deploy to Base Sepolia testnet
///   forge script script/DeployMockERC721.s.sol --rpc-url https://base-sepolia.g.alchemy.com/v2/51MRDeFHeLtd5FrWrTMv0bsusLfs5n8r --broadcast -vvv
///
///   # Deploy locally (dry run)
///   forge script script/DeployMockERC721.s.sol -vvv
///
contract DeployMockERC721 is Script {
    function run() external returns (MockERC721 nft) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        nft = new MockERC721();
        vm.stopBroadcast();

        console.log("Deployed MockERC721 NFT at:", address(nft));

        return nft;
    }
}
