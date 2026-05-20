// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus}          from "./interfaces/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient}                from "./interfaces/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface}  from "./interfaces/AutomationCompatibleInterface.sol";
import {ReentrancyGuard}                from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable}                        from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20}                         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata}                 from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}                      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  RaffleManager2
/// @notice Gas-optimised raffle system backed by Chainlink VRF v2.5 and Automation.
///         USDC-only payments. Underfilled raffles return prize to host and raffle
///         the collected payments to a winner. Platform fee for treasury.
/// @dev    Storage packing: 5 EVM slots per raffle. Slot map on RaffleData.
contract RaffleManager2 is
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
    enum RaffleStatus { OPEN, COMPLETED }

    /// @notice Per-raffle state – tightly packed into 5 EVM slots.
    ///
    ///   Slot 0 │ host        (20 B)
    ///          │ expiry      ( 6 B)  ← uint48 timestamp
    ///          │ status      ( 1 B)  ← enum ≡ uint8
    ///          │ underfilled ( 1 B)  ← bool
    ///          │ padding     ( 4 B)
    ///          └──────────────────  = 32 B  ✓
    ///
    ///   Slot 1 │ prizeAsset  (20 B)
    ///          │ ticketsSold (12 B)  ← uint96
    ///          └──────────────────  = 32 B  ✓
    ///
    ///   Slot 2 │ prizeAmount  32 B
    ///   Slot 3 │ ticketPrice  32 B
    ///   Slot 4 │ maxCap       32 B
    struct RaffleData {
        address      host;           // 20 B  ┐
        uint48       expiry;         //  6 B  │ Slot 0  (28 B used)
        RaffleStatus status;         //  1 B  │
        bool         underfilled;    //  1 B  ┘
        address      prizeAsset;     // 20 B  ┐
        uint96       ticketsSold;    // 12 B  ┘ Slot 1  (32 B used)
        uint256      prizeAmount;    // 32 B     Slot 2
        uint256      ticketPrice;    // 32 B     Slot 3
        uint256      maxCap;         // 32 B     Slot 4
    }

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Raffle data, keyed by 1-based raffleId.
    mapping(uint256 => RaffleData)   public raffles;

    /// @notice Participant array – address appears once per ticket.
    mapping(uint256 => address[])    public participants;

    /// @notice Maps a VRF requestId back to the raffle that requested it.
    mapping(uint256 => uint256)      private requestIdToRaffleId;

    /// @notice Monotonically increasing raffle counter (1-based).
    uint256 public raffleCount;

    // Payment & fee configuration ─────────────────────────────────────────
    /// @notice The ERC-20 token used for all ticket payments (e.g. USDC).
    address public immutable paymentToken;

    /// @notice Treasury address that receives platform fees.
    address public immutable treasury;

    /// @notice Platform fee in basis points (1 bp = 0.01%).
    uint256 public platformFeeBps;

    /// @notice Hard cap for platform fee: 10%.
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1000;

    // VRF configuration ────────────────────────────────────────────────────
    bytes32 private immutable s_keyHash;
    uint256 private immutable s_subId;

    uint16  private constant REQUEST_CONFIRMATIONS = 3;
    uint32  private constant CALLBACK_GAS_LIMIT    = 300_000;
    uint32  private constant NUM_WORDS             = 1;

    // ──────────────────────────────────────────────────────────────────────
    // Events
    // ──────────────────────────────────────────────────────────────────────

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed host,
        address prizeAsset,
        uint256 prizeAmount,
        uint48  expiry,
        string  prizeSymbol,
        uint256 decimals
    );
    event TicketPurchased(uint256 indexed raffleId, address indexed buyer, uint256 ticketCount);
    event WinnerPicked(uint256 indexed raffleId, address indexed winner);
    event VRFRequested(uint256 indexed raffleId, uint256 requestId);
    event RaffleExpired(uint256 indexed raffleId);
    event PlatformFeeCollected(uint256 indexed raffleId, uint256 amount);
    event PlatformFeeUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidParams();
    error RaffleNotOpen(uint256 raffleId);
    error RaffleNotExpired(uint256 raffleId);
    error MaxCapReached(uint256 raffleId);
    error HostCannotEnter(uint256 raffleId);
    error FeeTooHigh(uint256 requested, uint256 max);

    // ──────────────────────────────────────────────────────────────────────
    // Constructor
    // ──────────────────────────────────────────────────────────────────────

    constructor(
        address _vrfCoordinator,
        bytes32 _keyHash,
        uint256 _subId,
        address _paymentToken,
        address _treasury
    )
        VRFConsumerBaseV2Plus(_vrfCoordinator)
        Ownable(msg.sender)
    {
        if (_paymentToken == address(0) || _treasury == address(0))
            revert InvalidParams();
        s_keyHash    = _keyHash;
        s_subId      = _subId;
        paymentToken = _paymentToken;
        treasury     = _treasury;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Admin
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Update the platform fee. Capped at MAX_PLATFORM_FEE_BPS.
    function setPlatformFeeBps(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_PLATFORM_FEE_BPS)
            revert FeeTooHigh(_newFeeBps, MAX_PLATFORM_FEE_BPS);
        uint256 oldFeeBps = platformFeeBps;
        platformFeeBps = _newFeeBps;
        emit PlatformFeeUpdated(oldFeeBps, _newFeeBps);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – raffle lifecycle
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Create a raffle and lock the ERC-20 prize into this contract.
    /// @param  _asset       Prize token address.
    /// @param  _amount      Total prize amount (caller must have approved).
    /// @param  _ticketPrice Price per ticket in paymentToken units.
    /// @param  _maxCap      Maximum tickets that may be sold.
    /// @param  _duration    Seconds from now until the raffle expires.
    /// @return raffleId     1-based identifier.
    function createRaffle(
        address _asset,
        uint256 _amount,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) external returns (uint256 raffleId) {
        if (_asset == address(0) || _amount == 0 || _ticketPrice == 0
            || _maxCap == 0 || _duration == 0)
            revert InvalidParams();

        if (_maxCap > type(uint96).max) revert InvalidParams();

        raffleId = ++raffleCount;

        raffles[raffleId] = RaffleData({
            host:        msg.sender,
            expiry:      uint48(block.timestamp + _duration),
            status:      RaffleStatus.OPEN,
            underfilled: false,
            prizeAsset:  _asset,
            ticketsSold: 0,
            prizeAmount: _amount,
            ticketPrice: _ticketPrice,
            maxCap:      _maxCap
        });

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 prizeDecimals = IERC20Metadata(_asset).decimals();
        string memory prizeSymbol = IERC20Metadata(_asset).symbol();

        emit RaffleCreated(
            raffleId,
            msg.sender, // raffle host address
            _asset, // prize asset address
            _amount, // prize amount
            uint48(block.timestamp + _duration), // expiry timestamp
            prizeSymbol,
            prizeDecimals
        );

        return raffleId;
    }

    /// @notice Buy one or more tickets. Payment is in the contract's paymentToken.
    /// @param  _raffleId    Target raffle.
    /// @param  _ticketCount Number of tickets to purchase.
    function enterRaffle(uint256 _raffleId, uint256 _ticketCount)
        external nonReentrant
    {
        RaffleData storage raffle = raffles[_raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp >= raffle.expiry)
            revert RaffleNotOpen(_raffleId);
        if (msg.sender == raffle.host)
            revert HostCannotEnter(_raffleId);
        if (_ticketCount == 0)
            revert InvalidParams();
        if (raffle.ticketsSold + _ticketCount > raffle.maxCap)
            revert MaxCapReached(_raffleId);

        uint256 totalCost = raffle.ticketPrice * _ticketCount;

        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalCost);

        raffle.ticketsSold += uint96(_ticketCount);

        address[] storage arr = participants[_raffleId];
        for (uint256 i; i < _ticketCount; ) {
            arr.push(msg.sender);
            unchecked { ++i; }
        }

        emit TicketPurchased(_raffleId, msg.sender, _ticketCount);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Chainlink Automation
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc AutomationCompatibleInterface
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
    function performUpkeep(bytes calldata performData) external override {
        uint256 raffleId = abi.decode(performData, (uint256));
        RaffleData storage raffle = raffles[raffleId];

        if (raffle.status != RaffleStatus.OPEN || block.timestamp < raffle.expiry)
            return;

        // Zero participants → return prize, mark completed
        if (participants[raffleId].length == 0) {
            raffle.status = RaffleStatus.COMPLETED;
            IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);
            emit RaffleExpired(raffleId);
            return;
        }

        // Underfilled → return prize to host now, VRF will award payment pool
        if (raffle.ticketsSold < raffle.maxCap) {
            raffle.underfilled = true;
            IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);
        }

        // Request VRF for both full-fill and underfill paths
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
    function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords)
        internal override
    {
        uint256 raffleId = requestIdToRaffleId[_requestId];
        delete requestIdToRaffleId[_requestId];

        RaffleData storage raffle = raffles[raffleId];
        if (raffle.status != RaffleStatus.OPEN) return;

        uint256 winnerIndex = _randomWords[0] % participants[raffleId].length;
        address winner      = participants[raffleId][winnerIndex];

        raffle.status = RaffleStatus.COMPLETED;

        _distribute(raffleId, raffle, winner);

        emit WinnerPicked(raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns the full state of a raffle.
    function getRaffle(uint256 _raffleId) external view returns (RaffleData memory) {
        return raffles[_raffleId];
    }

    // ──────────────────────────────────────────────────────────────────────
    // Manual Winner Selection (testing & frontend integration)
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Manually select a winner by participant index. Callable after expiry.
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
        raffle.status = RaffleStatus.COMPLETED;

        // Handle underfill prize return if performUpkeep was not called
        if (raffle.ticketsSold < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
            IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);
        }

        _distribute(_raffleId, raffle, winner);

        emit WinnerPicked(_raffleId, winner);
    }

    /// @notice Manually select a winner using a random word. Callable after expiry.
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

        uint256 winnerIndex = _randomWord % participantList.length;
        address winner      = participantList[winnerIndex];

        raffle.status = RaffleStatus.COMPLETED;

        // Handle underfill prize return if performUpkeep was not called
        if (raffle.ticketsSold < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
            IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmount);
        }

        _distribute(_raffleId, raffle, winner);

        emit WinnerPicked(_raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Compute platform fee for a given amount.
    function _computeFee(uint256 _amount) internal view returns (uint256) {
        return (_amount * platformFeeBps) / 10_000;
    }

    /// @dev Distribute prizes, payments, and fees after winner selection.
    ///      - Underfilled: winner gets payment pool minus fee.
    ///      - Full-fill:   winner gets prize minus fee, host gets payments minus fee.
    function _distribute(uint256 _raffleId, RaffleData storage _raffle, address _winner) internal {
        uint256 paymentPool = uint256(_raffle.ticketsSold) * _raffle.ticketPrice;
        uint256 paymentFee  = _computeFee(paymentPool);

        if (_raffle.underfilled) {
            // Winner receives payment pool minus fee
            IERC20(paymentToken).safeTransfer(_winner, paymentPool - paymentFee);

            // Fee to treasury
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
                emit PlatformFeeCollected(_raffleId, paymentFee);
            }
        } else {
            // Full-fill: winner gets prize minus fee
            uint256 prizeFee = _computeFee(_raffle.prizeAmount);
            IERC20(_raffle.prizeAsset).safeTransfer(_winner, _raffle.prizeAmount - prizeFee);

            // Host gets payment pool minus fee
            IERC20(paymentToken).safeTransfer(_raffle.host, paymentPool - paymentFee);

            // Fees to treasury
            uint256 totalFees = prizeFee + paymentFee;
            if (prizeFee > 0) {
                IERC20(_raffle.prizeAsset).safeTransfer(treasury, prizeFee);
            }
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
            }
            if (totalFees > 0) {
                emit PlatformFeeCollected(_raffleId, totalFees);
            }
        }
    }
}
