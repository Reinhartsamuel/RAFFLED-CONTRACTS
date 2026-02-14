// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain ERC-20 – entire supply minted to the deployer.
contract StandardERC20 is ERC20 {
    constructor(string memory name, string memory symbol, uint256 supply)
        ERC20(name, symbol)
    {
        _mint(msg.sender, supply);
    }
}
