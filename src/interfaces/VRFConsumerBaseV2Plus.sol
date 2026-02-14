// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFV2PlusClient} from "./VRFV2PlusClient.sol";

/// @notice Coordinator interface used by the consumer base (local shim).
interface IVRFCoordinatorV2Plus {
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external payable returns (uint256 requestId);
}

/// @notice Abstract base that wires the coordinator callback.
///         `rawFulfillRandomWords` is the only external entry-point;
///         it enforces msg.sender == coordinator before delegating to the
///         internal `fulfillRandomWords` hook.
abstract contract VRFConsumerBaseV2Plus {
    IVRFCoordinatorV2Plus public s_vrfCoordinator;

    error OnlyCoordinatorCanFulfill(address have, address want);

    constructor(address vrfCoordinator) {
        s_vrfCoordinator = IVRFCoordinatorV2Plus(vrfCoordinator);
    }

    /// @dev Called by the VRF coordinator after randomness is generated.
    ///      Reverts if called by anyone else – the sole security gate for
    ///      fulfillRandomWords.
    function rawFulfillRandomWords(
        uint256   requestId,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != address(s_vrfCoordinator)) {
            revert OnlyCoordinatorCanFulfill(msg.sender, address(s_vrfCoordinator));
        }
        fulfillRandomWords(requestId, randomWords);
    }

    /// @dev Override in the consumer contract.
    function fulfillRandomWords(
        uint256   requestId,
        uint256[] memory randomWords
    ) internal virtual;
}
