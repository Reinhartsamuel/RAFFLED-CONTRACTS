// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice VRF v2.5 request types (local shim – layout matches Chainlink upstream).
library VRFV2PlusClient {
    struct RandomWordsRequest {
        bytes32 keyHash;
        uint256 subId;
        uint16  requestConfirmations;
        uint32  callbackGasLimit;
        uint32  numWords;
        bytes   extraArgs;
    }

    struct ExtraArgsV2Plus {
        bool nativePayment;
    }

    function _argsToBytes(ExtraArgsV2Plus memory extraArgs)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(extraArgs);
    }
}
