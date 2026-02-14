// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus}          from "./interfaces/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient}                from "./interfaces/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface}  from "./interfaces/AutomationCompatibleInterface.sol";
import {ReentrancyGuard}                from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable}                        from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20}                         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20}                      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  RaffleManager
/// @notice Gas-optimised, single-manager raffle system backed by
///         Chainlink VRF v2.5 (randomness) and Automation (expiry trigger).
/// @dev    Storage packing reduces per-raffle state from 7 slots → 5 slots.
///         Slot map is documented on RaffleData.
contract RaffleManager is
    VRFConsumerBaseV2Plus,
    AutomationCompatibleInterface,
    ReentrancyGuard,
    Ownable
{
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Lifecycle states for a raffle.
    enum RaffleStatus { OPEN, CANCELLED, COMPLETED }

    /// @notice Per-raffle state – tightly packed into 6 EVM slots.
    ///
    ///   Slot 0 │ host       (20 B)
    ///          │ expiry     ( 6 B)  ← uint48 timestamp
    ///          │ status     ( 1 B)  ← enum ≡ uint8
    ///          │ padding    ( 5 B)
    ///          └──────────────────  = 32 B  ✓
    ///
    ///   Slot 1 │ prizeAsset (20 B)
    ///          │ ticketsSold(12 B)  ← uint96  (max ≈ 7.9 × 10²⁸)
    ///          └──────────────────  = 32 B  ✓
    ///
    ///   Slot 2 │ paymentAsset        20 B
    ///          │ padding             12 B
    ///          └──────────────────  = 32 B  ✓
    ///
    ///   Slot 3 │ prizeAmount         32 B
    ///   Slot 4 │ ticketPrice         32 B
    ///   Slot 5 │ maxCap              32 B
    struct RaffleData {
        address      host;           // 20 B  ┐
        uint48       expiry;         //  6 B  │ Slot 0  (27 B used)
        RaffleStatus status;         //  1 B  ┘
        address      prizeAsset;     // 20 B  ┐
        uint96       ticketsSold;    // 12 B  ┘ Slot 1  (32 B used)
        address      paymentAsset;   // 20 B     Slot 2
        uint256      prizeAmount;    // 32 B     Slot 3
        uint256      ticketPrice;    // 32 B     Slot 4
        uint256      maxCap;         // 32 B     Slot 5
    }

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Raffle data, keyed by 1-based raffleId.
    mapping(uint256 => RaffleData)                          public  raffles;

    /// @notice Participant array – address appears once per ticket.
    ///         Enables O(1) winner selection via modulo.
    mapping(uint256 => address[])                           public  participants;

    /// @notice Ticket count per user per raffle – used for pull-style refunds.
    mapping(uint256 => mapping(address => uint256))         private userTickets;

    /// @notice Maps a VRF requestId back to the raffle that requested it.
    mapping(uint256 => uint256)                             private requestIdToRaffleId;

    /// @notice Monotonically increasing raffle counter (1-based).
    uint256 public raffleCount;

    // VRF configuration ────────────────────────────────────────────────────
    bytes32 private immutable s_keyHash;
    uint256 private immutable s_subId;

    uint16  private constant  REQUEST_CONFIRMATIONS = 3;
    uint32  private constant  CALLBACK_GAS_LIMIT    = 100_000;
    uint32  private constant  NUM_WORDS             = 1;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event RaffleCreated   (uint256 indexed raffleId, address indexed host, address prizeAsset, uint256 prizeAmount, address paymentAsset, uint48 expiry);
    event TicketPurchased (uint256 indexed raffleId, address indexed buyer,  uint256 ticketCount);
    event RaffleCancelled (uint256 indexed raffleId);
    event WinnerPicked    (uint256 indexed raffleId, address indexed winner);
    event RefundClaimed   (uint256 indexed raffleId, address indexed claimer, uint256 amount);
    event VRFRequested    (uint256 indexed raffleId, uint256 requestId);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidParams();
    error RaffleNotOpen(uint256 raffleId);
    error RaffleNotExpired(uint256 raffleId);
    error MaxCapReached(uint256 raffleId);
    error InsufficientPayment(uint256 expected, uint256 received);
    error CannotCancelFilledRaffle(uint256 raffleId);
    error NoRefundAvailable();
    error ETHTransferFailed();
    error UnexpectedETHPayment();

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor(address _vrfCoordinator, bytes32 _keyHash, uint256 _subId)
        VRFConsumerBaseV2Plus(_vrfCoordinator)
        Ownable(msg.sender)
    {
        s_keyHash = _keyHash;
        s_subId   = _subId;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – raffle lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Create a raffle and lock the ERC-20 prize into this contract.
    /// @param  _asset          Prize token address.
    /// @param  _amount         Total prize amount (caller must have approved).
    /// @param  _paymentAsset   Payment token address (address(0) = ETH, otherwise ERC20).
    /// @param  _ticketPrice    Wei per ticket in payment asset units.
    /// @param  _maxCap         Maximum tickets that may be sold.
    /// @param  _duration       Seconds from now until the raffle expires.
    /// @return raffleId        1-based identifier.
    function createRaffle(
        address _asset,
        uint256 _amount,
        address _paymentAsset,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) external returns (uint256 raffleId) {
        // Basic validation
        if (_asset == address(0) || _amount == 0 || _ticketPrice == 0
            || _maxCap == 0 || _duration == 0)
            revert InvalidParams();

        // maxCap must fit in uint96 so ticketsSold can track it
        if (_maxCap > type(uint96).max) revert InvalidParams();

        raffleId = ++raffleCount;

        raffles[raffleId] = RaffleData({
            host:          msg.sender,
            expiry:        uint48(block.timestamp + _duration),
            status:        RaffleStatus.OPEN,
            prizeAsset:    _asset,
            ticketsSold:   0,
            paymentAsset:  _paymentAsset,
            prizeAmount:   _amount,
            ticketPrice:   _ticketPrice,
            maxCap:        _maxCap
        });

        // Lock prize – SafeERC20 handles non-standard return values
        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        emit RaffleCreated(raffleId, msg.sender, _asset, _amount, _paymentAsset, uint48(block.timestamp + _duration));
    }

    /// @notice Buy one or more tickets.  Each ticket pushes msg.sender into
    ///         the participants array once, preserving O(1) winner selection.
    ///         Supports both ETH and ERC20 token payments based on raffle config.
    /// @param  _raffleId    Target raffle.
    /// @param  _ticketCount Number of tickets to purchase.
    function enterRaffle(uint256 _raffleId, uint256 _ticketCount)
        external payable nonReentrant
    {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp >= raffle.expiry)
            revert RaffleNotOpen(_raffleId);
        if (_ticketCount == 0)
            revert InvalidParams();
        if (raffle.ticketsSold + _ticketCount > raffle.maxCap)
            revert MaxCapReached(_raffleId);

        uint256 totalCost = raffle.ticketPrice * _ticketCount;

        // ── payment handling ─────────────────────────────────────────
        if (raffle.paymentAsset == address(0)) {
            // ETH payment mode
            if (msg.value != totalCost)
                revert InsufficientPayment(totalCost, msg.value);
        } else {
            // ERC20 payment mode
            if (msg.value != 0)
                revert UnexpectedETHPayment();
            IERC20(raffle.paymentAsset).safeTransferFrom(
                msg.sender,
                address(this),
                totalCost
            );
        }

        // ── effects ──────────────────────────────────────────────────
        raffle.ticketsSold += uint96(_ticketCount);
        userTickets[_raffleId][msg.sender] += _ticketCount;

        address[] storage arr = participants[_raffleId];
        for (uint256 i; i < _ticketCount; ) {
            arr.push(msg.sender);
            unchecked { ++i; }
        }

        emit TicketPurchased(_raffleId, msg.sender, _ticketCount);
    }

    /// @notice Cancel an expired raffle whose cap was never reached.
    ///         Returns the locked prize to the host.
    /// @param  _raffleId  Target raffle.
    function cancelRaffle(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN)
            revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry)
            revert RaffleNotExpired(_raffleId);
        if (raffle.ticketsSold >= raffle.maxCap)
            revert CannotCancelFilledRaffle(_raffleId);

        // ── effects ──────────────────────────────────────────────────────
        raffle.status = RaffleStatus.CANCELLED;

        // ── interaction – return prize to host ───────────────────────────
        IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);

        emit RaffleCancelled(_raffleId);
    }

    /// @notice Pull-based refund for participants of a cancelled raffle.
    ///         Supports both ETH and ERC20 token refunds based on raffle config.
    /// @param  _raffleId  Target (must be CANCELLED).
    function claimRefund(uint256 _raffleId) external nonReentrant {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.CANCELLED)
            revert RaffleNotOpen(_raffleId);

        uint256 tickets = userTickets[_raffleId][msg.sender];
        if (tickets == 0) revert NoRefundAvailable();

        uint256 refund = tickets * raffle.ticketPrice;

        // ── effects before interaction (CEI pattern) ────────────────────
        userTickets[_raffleId][msg.sender] = 0;

        // ── interaction ──────────────────────────────────────────────────
        if (raffle.paymentAsset == address(0)) {
            // ETH refund
            (bool ok, ) = msg.sender.call{ value: refund }("");
            if (!ok) revert ETHTransferFailed();
        } else {
            // ERC20 refund
            IERC20(raffle.paymentAsset).safeTransfer(msg.sender, refund);
        }

        emit RefundClaimed(_raffleId, msg.sender, refund);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Chainlink Automation
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev    Linear scan is acceptable – checkUpkeep runs off-chain and the
    ///         Automation network does not charge gas for it.
    function checkUpkeep(bytes calldata)
        external view override
        returns (bool, bytes memory)
    {
        for (uint256 i = 1; i <= raffleCount; ) {
            if (raffles[i].status == RaffleStatus.OPEN
                && block.timestamp >= raffles[i].expiry)
            {
                return (true, abi.encode(i));
            }
            unchecked { ++i; }
        }
        return (false, "");
    }

    /// @inheritdoc AutomationCompatibleInterface
    /// @dev    Can also be called manually by any user ("Manual Resolve").
    function performUpkeep(bytes calldata performData) external override {
        uint256 raffleId = abi.decode(performData, (uint256));
        RaffleData storage raffle = raffles[raffleId];

        // On-chain re-validation – guards against stale payloads
        if (raffle.status != RaffleStatus.OPEN || block.timestamp < raffle.expiry)
            return;

        // Edge: zero participants → auto-cancel, return prize
        if (participants[raffleId].length == 0) {
            raffle.status = RaffleStatus.CANCELLED;
            IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);
            emit RaffleCancelled(raffleId);
            return;
        }

        // Request on-chain randomness
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash:              s_keyHash,
                subId:                s_subId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit:     CALLBACK_GAS_LIMIT,
                numWords:             NUM_WORDS,
                extraArgs:            VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV2Plus({ nativePayment: false })
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
    /// @dev    Only reachable via rawFulfillRandomWords (coordinator-only gate).
    ///         Winner derivation is O(1): index = randomWord % arrayLength.
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords)
        internal override
    {
        uint256 raffleId = requestIdToRaffleId[_requestId];
        delete requestIdToRaffleId[_requestId];

        // Idempotency guard – ignore duplicate / stale callbacks
        if (raffles[raffleId].status != RaffleStatus.OPEN) return;

        // O(1) winner selection
        uint256 winnerIndex = _randomWords[0] % participants[raffleId].length;
        address winner      = participants[raffleId][winnerIndex];

        // ── effects ──────────────────────────────────────────────────────
        raffles[raffleId].status = RaffleStatus.COMPLETED;

        // ── interaction – deliver prize ──────────────────────────────────
        IERC20(raffles[raffleId].prizeAsset).safeTransfer(winner, raffles[raffleId].prizeAmount);

        emit WinnerPicked(raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Manual Winner Selection (for testing & frontend integration)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Manually select a winner by specifying the participant index.
    ///         Can be called by anyone after raffle expiry.
    ///         Useful for testing and frontend winner selection before
    ///         Chainlink Automation / VRF integration.
    /// @dev    Must validate that raffle is OPEN and expired, and index is valid.
    /// @param  _raffleId     Target raffle.
    /// @param  _winnerIndex  Index into participants array [0, length).
    function manualFulfillWinner(uint256 _raffleId, uint256 _winnerIndex)
        external nonReentrant
    {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN)
            revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry)
            revert RaffleNotExpired(_raffleId);

        address[] storage participantList = participants[_raffleId];
        if (_winnerIndex >= participantList.length)
            revert InvalidParams();

        address winner = participantList[_winnerIndex];

        // ── effects ──────────────────────────────────────────────────────
        raffle.status = RaffleStatus.COMPLETED;

        // ── interaction – deliver prize ──────────────────────────────────
        IERC20(raffle.prizeAsset).safeTransfer(winner, raffle.prizeAmount);

        emit WinnerPicked(_raffleId, winner);
    }

    /// @notice Manually select a winner using a random word, simulating Chainlink VRF.
    ///         The winner is derived as: index = randomWord % participantCount.
    ///         Can be called by anyone after raffle expiry.
    ///         Useful for testing randomness logic and frontend winner simulation.
    /// @dev    Applies modulo to randomWord to ensure valid participant selection.
    /// @param  _raffleId     Target raffle.
    /// @param  _randomWord   Simulated random number (e.g., from a deterministic seed).
    function manualFulfillWinnerByRandomWord(uint256 _raffleId, uint256 _randomWord)
        external nonReentrant
    {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN)
            revert RaffleNotOpen(_raffleId);
        if (block.timestamp < raffle.expiry)
            revert RaffleNotExpired(_raffleId);

        address[] storage participantList = participants[_raffleId];
        if (participantList.length == 0)
            revert InvalidParams();

        // O(1) winner selection – same logic as VRF fulfillment
        uint256 winnerIndex = _randomWord % participantList.length;
        address winner      = participantList[winnerIndex];

        // ── effects ──────────────────────────────────────────────────────
        raffle.status = RaffleStatus.COMPLETED;

        // ── interaction – deliver prize ──────────────────────────────────
        IERC20(raffle.prizeAsset).safeTransfer(winner, raffle.prizeAmount);

        emit WinnerPicked(_raffleId, winner);
    }
}
