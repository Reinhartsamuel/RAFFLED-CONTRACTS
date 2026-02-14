// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFV2PlusClient} from "../../src/interfaces/VRFV2PlusClient.sol";

/// @notice Minimal VRF Coordinator v2.5 mock for local Foundry testing.
///         Exposes `lastRequestId` so tests can grab the ID after
///         performUpkeep triggers a request.
contract VRFCoordinatorV2_5Mock {
    /// @notice Incremented on every request – read by the test harness.
    uint256 public lastRequestId;

    mapping(uint256 => address) private requestConsumer;

    event RandomWordsRequested(uint256 indexed requestId, uint32 numWords);
    event RandomWordsFulfilled(uint256 indexed requestId);

    /// @notice Selector must match what VRFConsumerBaseV2Plus calls on the
    ///         coordinator.  Stores the caller so fulfillRandomWords can
    ///         route the callback.
    function requestRandomWords(
        VRFV2PlusClient.RandomWordsRequest calldata req
    ) external returns (uint256) {
        lastRequestId           = lastRequestId + 1;
        requestConsumer[lastRequestId] = msg.sender;
        emit RandomWordsRequested(lastRequestId, req.numWords);
        return lastRequestId;
    }

    /// @notice Called by the test to simulate on-chain VRF delivery.
    ///         Invokes rawFulfillRandomWords on the consumer – the only
    ///         path accepted by VRFConsumerBaseV2Plus.
    function fulfillRandomWords(
        uint256   _requestId,
        uint256[] memory _randomWords
    ) external {
        address consumer = requestConsumer[_requestId];
        IVRFConsumer(consumer).rawFulfillRandomWords(_requestId, _randomWords);
        emit RandomWordsFulfilled(_requestId);
    }

    // Subscription helpers – no-ops ----------------------------------------
    function createSubscription()            external pure returns (uint256) { return 1; }
    function addConsumer(uint256, address)   external {}
    function fundSubscription(uint256, uint256) external {}
}

/// @dev Thin interface so the mock can call back into the consumer without
///      importing the full RaffleManager.
interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}
