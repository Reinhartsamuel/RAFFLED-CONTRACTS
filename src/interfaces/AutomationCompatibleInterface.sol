// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Chainlink Automation compatible interface (local shim).
interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData)
        external
        view
        returns (bool upkeepNeeded, bytes memory performData);

    function performUpkeep(bytes calldata performData) external;
}
