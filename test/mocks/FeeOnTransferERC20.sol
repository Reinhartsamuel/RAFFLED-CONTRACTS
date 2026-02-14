// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Every transfer silently deducts a 1 % fee (burned) from the
///         transferred amount.  Used to verify that fee-on-transfer tokens
///         cause the expected failure at prize-payout time.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public constant FEE_BPS = 100; // 1 %

    constructor(string memory name, string memory symbol, uint256 supply)
        ERC20(name, symbol)
    {
        _mint(msg.sender, supply);
    }

    /// @dev  OZ v5 ERC20._transfer is non-virtual, so we intercept at the
    ///       public transfer / transferFrom layer instead.
    ///       sender loses `amount`; recipient receives `amount - fee`; fee is burned.
    function transfer(address to, uint256 amount)
        public override returns (bool)
    {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        super.transfer(to, amount - fee);
        _burn(_msgSender(), fee);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        public override returns (bool)
    {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        super.transferFrom(from, to, amount - fee);
        _burn(from, fee);
        return true;
    }
}
