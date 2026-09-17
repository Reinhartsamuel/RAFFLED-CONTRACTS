// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {WinrUSDG} from "../test/mocks/MockUsdg.sol";
import {console} from "forge-std/console.sol";

contract DeployMockWinrUSDG is Script {
    function run() external returns (WinrUSDG usdg) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        usdg = new WinrUSDG(1e6 * 1e6);
        vm.stopBroadcast();
        console.log("Deployed WinrUSDG at:", address(usdg));
        return usdg;
    }
}
