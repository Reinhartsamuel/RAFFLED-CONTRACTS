// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Raffled} from "../test/mocks/RaffledNft.sol";
import {console} from "forge-std/console.sol";

contract DeployRaffledNft is Script {
    function run() external returns (Raffled nft) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory baseUri = "https://pub-fedd92d489cc481596abe63636ea383f.r2.dev/metadata/";

        vm.startBroadcast(deployerKey);
        nft = new Raffled(baseUri);
        vm.stopBroadcast();

        console.log("Deployed Raffled NFT at:", address(nft));

        return nft;
    }
}
