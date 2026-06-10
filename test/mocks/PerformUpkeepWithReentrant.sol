// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FreeEntryVerifier} from "../../src/FreeEntryVerifier.sol";

contract PerformUpkeepWithReentrant is
    VRFConsumerBaseV2Plus,
    AutomationCompatibleInterface,
    ReentrancyGuard,
    FreeEntryVerifier
{
    // VRF configuration ────────────────────────────────────────────────────
    bytes32 private immutable s_keyHash;
    uint256 private immutable s_subId;

    /// @notice Maps a VRF requestId back to the raffle that requested it.
    mapping(uint256 => uint256) private requestIdToRaffleId;

    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant CALLBACK_GAS_LIMIT = 300_000;
    uint32 private constant NUM_WORDS = 1;

    event VRFRequested(uint256 indexed raffleId, uint256 requestId);
    event PerformUpkeepCalled(uint256 indexed raffleId);
    event WinnerPickedByRandomWords(
        uint256 indexed raffleId,
        uint256[] randomWords
    );

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subId,
        address _trustedSigner
    )
        VRFConsumerBaseV2Plus(_vrfCoordinator)
        FreeEntryVerifier(_trustedSigner, msg.sender)
    {
        s_keyHash = _keyHash;
        s_subId = _subId;
    }

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(
        bytes calldata
    ) external view override returns (bool, bytes memory) {
        return (true, abi.encode(uint256(1)));
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @notice PerformUpkeep is called by Chainlink Automation to close expired raffles.
    function performUpkeep(
        bytes calldata performData
    ) external override nonReentrant {
        uint256 raffleId = abi.decode(performData, (uint256));
        // Request VRF for both full-fill and underfill paths
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: s_keyHash,
                subId: s_subId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        requestIdToRaffleId[requestId] = raffleId;
        emit VRFRequested(raffleId, requestId);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Chainlink VRF v2.5 – fulfillment callback
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc VRFConsumerBaseV2Plus
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] calldata _randomWords
    ) internal override nonReentrant {
        uint256 raffleId = requestIdToRaffleId[_requestId];
        delete requestIdToRaffleId[_requestId];
        emit WinnerPickedByRandomWords(raffleId, _randomWords);
    }
}
