// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice ERC-20 that deliberately returns **nothing** from transfer /
///         transferFrom / approve.  SafeERC20 must handle this correctly.
contract MockUSDC {
    mapping(address => uint256)                          private _bal;
    mapping(address => mapping(address => uint256))      private _allow;

    constructor(uint256 supply) {
        _bal[msg.sender] = supply;
    }

    function balanceOf(address a) external view returns (uint256) {
        return _bal[a];
    }

    // ── No return values ─────────────────────────────────────────────────

    function transfer(address to, uint256 amount) external {
        _bal[msg.sender] -= amount;
        _bal[to]         += amount;
    }

    function approve(address spender, uint256 amount) external {
        _allow[msg.sender][spender] = amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        _allow[from][msg.sender] -= amount;
        _bal[from]               -= amount;
        _bal[to]                 += amount;
    }
    function symbol() public pure returns (string memory) {
        return "USDC";
    }

    function decimals() public pure returns (uint8) {
        return 6;
    }

    function name() public pure returns (string memory) {
        return "Mock USD Coin";
    }
}
