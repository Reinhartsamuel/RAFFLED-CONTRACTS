// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VRFConsumerBaseV2Plus}          from "./interfaces/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient}                from "chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface}  from "chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {ReentrancyGuard}                from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable}                        from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20}                         from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata}                 from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20}                      from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721}                        from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver}                from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata}                from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/// @title  RaffleManager3
/// @notice Gas-optimised raffle system backed by Chainlink VRF v2.5 and Automation.
///         Supports ERC-20 tokens *or* ERC-721 NFTs as the raffle prize.
///         USDC-only ticket payments. Underfilled raffles return the prize to the
///         host and raffle the collected payments to a random winner.
///         Platform fee taken from payment pool (and prize for ERC-20 full-fills).
///         Fee changes require a 2-day timelock to reduce centralisation risk.
///
/// @dev    Storage packing: 5 EVM slots per raffle (unchanged from RaffleManager2).
///
///   Slot 0 │ host        (20 B)
///          │ expiry      ( 6 B)  ← uint48 timestamp
///          │ status      ( 1 B)  ← RaffleStatus enum
///          │ underfilled ( 1 B)  ← bool
///          │ prizeType   ( 1 B)  ← PrizeType enum
///          │ padding     ( 3 B)
///          └──────────────────  = 32 B  ✓
///
///   Slot 1 │ prizeAsset  (20 B)
///          │ ticketsSold (12 B)  ← uint96
///          └──────────────────  = 32 B  ✓
///
///   Slot 2 │ prizeAmountOrTokenId  32 B  (amount for ERC-20; tokenId for ERC-721)
///   Slot 3 │ ticketPrice           32 B
///   Slot 4 │ maxCap                32 B
contract RaffleManager3 is
    VRFConsumerBaseV2Plus,
    AutomationCompatibleInterface,
    IERC721Receiver,
    ReentrancyGuard,
    Ownable
{
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────────────────────────────
    // Types
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Lifecycle states for a raffle.
    enum RaffleStatus { OPEN, COMPLETED }

    /// @notice Distinguishes prize type to branch distribution logic.
    enum PrizeType { ERC20, ERC721 }

    /// @notice Per-raffle state – tightly packed into 5 EVM slots.
    struct RaffleData {
        address      host;                  // 20 B  ┐
        uint48       expiry;                //  6 B  │ Slot 0  (29 B used)
        RaffleStatus status;                //  1 B  │
        bool         underfilled;           //  1 B  │
        PrizeType    prizeType;             //  1 B  ┘
        address      prizeAsset;            // 20 B  ┐
        uint96       ticketsSold;           // 12 B  ┘ Slot 1  (32 B used)
        uint256      prizeAmountOrTokenId;  // 32 B     Slot 2
        uint256      ticketPrice;           // 32 B     Slot 3
        uint256      maxCap;               // 32 B     Slot 4
    }

    // ──────────────────────────────────────────────────────────────────────
    // State
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Raffle data, keyed by 1-based raffleId.
    mapping(uint256 => RaffleData)  public raffles;

    /// @notice Participant array – address appears once per ticket.
    mapping(uint256 => address[])   public participants;

    /// @notice Maps a VRF requestId back to the raffle that requested it.
    mapping(uint256 => uint256)     private requestIdToRaffleId;

    /// @notice Monotonically increasing raffle counter (1-based).
    uint256 public raffleCount;

    // Payment & fee configuration ─────────────────────────────────────────
    /// @notice The ERC-20 token used for all ticket payments (e.g. USDC).
    address public immutable paymentToken;

    /// @notice Treasury address that receives platform fees.
    address public immutable treasury;

    /// @notice Active platform fee in basis points (1 bp = 0.01%).
    uint256 public platformFeeBps;

    /// @notice Hard cap for platform fee: 10%.
    uint256 public constant MAX_PLATFORM_FEE_BPS = 1_000;

    // Fee timelock ─────────────────────────────────────────────────────────
    /// @notice Pending fee that will become active after the timelock.
    uint256 public pendingFeeBps;

    /// @notice Timestamp after which pendingFeeBps may be applied.
    uint256 public feeChangeEffectiveAt;

    /// @notice Minimum delay before a proposed fee change can be applied.
    uint256 public constant FEE_TIMELOCK = 2 days;

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
        PrizeType prizeType,
        uint256 prizeAmountOrTokenId,
        uint48  expiry,
        string  prizeSymbol,
        uint256 decimals
    );
    event TicketPurchased(uint256 indexed raffleId, address indexed buyer, uint256 ticketCount);
    event WinnerPicked(uint256 indexed raffleId, address indexed winner);
    event VRFRequested(uint256 indexed raffleId, uint256 requestId);
    event RaffleExpired(uint256 indexed raffleId);
    event UnderfilledPrizeReturned(uint256 indexed raffleId, address indexed host, uint256 prizeAmountOrTokenId);
    event PlatformFeeCollected(uint256 indexed raffleId, uint256 amount);
    event FeeChangeProposed(uint256 newFeeBps, uint256 effectiveAt);
    event FeeChangeApplied(uint256 oldFeeBps, uint256 newFeeBps);

    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error InvalidParams();
    error RaffleNotOpen(uint256 raffleId);
    error RaffleNotExpired(uint256 raffleId);
    error MaxCapReached(uint256 raffleId);
    error HostCannotEnter(uint256 raffleId);
    error FeeTooHigh(uint256 requested, uint256 max);
    error FeeTimelockNotElapsed(uint256 effectiveAt);
    error NoFeeChangePending();

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
    // Admin – fee timelock
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Propose a new platform fee. Becomes active after FEE_TIMELOCK.
    /// @param  _newFeeBps New fee in basis points (max MAX_PLATFORM_FEE_BPS).
    function proposeFeeChange(uint256 _newFeeBps) external onlyOwner {
        if (_newFeeBps > MAX_PLATFORM_FEE_BPS)
            revert FeeTooHigh(_newFeeBps, MAX_PLATFORM_FEE_BPS);
        pendingFeeBps        = _newFeeBps;
        feeChangeEffectiveAt = block.timestamp + FEE_TIMELOCK;
        emit FeeChangeProposed(_newFeeBps, feeChangeEffectiveAt);
    }

    /// @notice Apply the pending fee change after the timelock has elapsed.
    function applyFeeChange() external onlyOwner {
        if (feeChangeEffectiveAt == 0) revert NoFeeChangePending();
        if (block.timestamp < feeChangeEffectiveAt)
            revert FeeTimelockNotElapsed(feeChangeEffectiveAt);
        uint256 oldFee   = platformFeeBps;
        platformFeeBps   = pendingFeeBps;
        pendingFeeBps    = 0;
        feeChangeEffectiveAt = 0;
        emit FeeChangeApplied(oldFee, platformFeeBps);
    }

    // ──────────────────────────────────────────────────────────────────────
    // ERC-721 receiver
    // ──────────────────────────────────────────────────────────────────────

    /// @inheritdoc IERC721Receiver
    function onERC721Received(address, address, uint256, bytes calldata)
        external pure override returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – raffle creation
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Create a raffle with an ERC-20 token prize.
    /// @param  _asset       Prize token address.
    /// @param  _amount      Total prize amount (caller must have approved).
    /// @param  _ticketPrice Price per ticket in paymentToken units.
    /// @param  _maxCap      Maximum tickets that may be sold.
    /// @param  _duration    Seconds from now until the raffle expires.
    /// @return raffleId     1-based identifier.
    function createRaffleERC20(
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

        raffleId = _initRaffle(
            msg.sender, _asset, PrizeType.ERC20, _amount, _ticketPrice, _maxCap, _duration
        );

        IERC20(_asset).safeTransferFrom(msg.sender, address(this), _amount);

        string memory sym = IERC20Metadata(_asset).symbol();
        uint256 dec       = IERC20Metadata(_asset).decimals();

        emit RaffleCreated(raffleId, msg.sender, _asset, PrizeType.ERC20, _amount,
            uint48(block.timestamp + _duration), sym, dec);
    }

    /// @notice Create a raffle with an ERC-721 NFT prize.
    /// @param  _nft         NFT contract address.
    /// @param  _tokenId     Token ID to raffle (caller must have approved or set approval-for-all).
    /// @param  _ticketPrice Price per ticket in paymentToken units.
    /// @param  _maxCap      Maximum tickets that may be sold.
    /// @param  _duration    Seconds from now until the raffle expires.
    /// @return raffleId     1-based identifier.
    function createRaffleERC721(
        address _nft,
        uint256 _tokenId,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) external returns (uint256 raffleId) {
        if (_nft == address(0) || _ticketPrice == 0 || _maxCap == 0 || _duration == 0)
            revert InvalidParams();
        if (_maxCap > type(uint96).max) revert InvalidParams();

        raffleId = _initRaffle(
            msg.sender, _nft, PrizeType.ERC721, _tokenId, _ticketPrice, _maxCap, _duration
        );

        // safeTransferFrom triggers onERC721Received on this contract
        IERC721(_nft).safeTransferFrom(msg.sender, address(this), _tokenId);

        string memory sym = "";
        // Attempt symbol fetch; not mandatory for ERC-721
        try IERC721Metadata(_nft).name() returns (string memory n) { sym = n; } catch {}

        emit RaffleCreated(raffleId, msg.sender, _nft, PrizeType.ERC721, _tokenId,
            uint48(block.timestamp + _duration), sym, 0);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Core – ticket purchase
    // ──────────────────────────────────────────────────────────────────────

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

        uint96 sold = raffle.ticketsSold;
        if (sold + _ticketCount > raffle.maxCap)
            revert MaxCapReached(_raffleId);

        uint256 totalCost = raffle.ticketPrice * _ticketCount;
        IERC20(paymentToken).safeTransferFrom(msg.sender, address(this), totalCost);

        raffle.ticketsSold = sold + uint96(_ticketCount);

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
            _returnPrizeToHost(raffleId, raffle);
            emit RaffleExpired(raffleId);
            return;
        }

        // Underfilled → return prize to host now, VRF will award the payment pool
        if (raffle.ticketsSold < raffle.maxCap) {
            raffle.underfilled = true;
            _returnPrizeToHost(raffleId, raffle);
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
                    VRFV2PlusClient.ExtraArgsV1({ nativePayment: false })
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
        internal override nonReentrant
    {
        uint256 raffleId = requestIdToRaffleId[_requestId];
        delete requestIdToRaffleId[_requestId];

        RaffleData storage raffle = raffles[raffleId];
        if (raffle.status != RaffleStatus.OPEN) return;

        address[] storage parts = participants[raffleId];
        uint256 len = parts.length;
        uint256 winnerIndex = _randomWords[0] % len;
        address winner      = parts[winnerIndex];

        raffle.status = RaffleStatus.COMPLETED;
        _distribute(raffleId, raffle, winner);

        emit WinnerPicked(raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Manual Winner Selection (testing & frontend fallback)
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

        address[] storage parts = participants[_raffleId];
        if (_winnerIndex >= parts.length)
            revert InvalidParams();

        address winner = parts[_winnerIndex];
        raffle.status  = RaffleStatus.COMPLETED;

        // Handle underfill prize return if performUpkeep was not called
        if (raffle.ticketsSold < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
            _returnPrizeToHost(_raffleId, raffle);
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

        address[] storage parts = participants[_raffleId];
        if (parts.length == 0)
            revert InvalidParams();

        uint256 winnerIndex = _randomWord % parts.length;
        address winner      = parts[winnerIndex];
        raffle.status       = RaffleStatus.COMPLETED;

        // Handle underfill prize return if performUpkeep was not called
        if (raffle.ticketsSold < raffle.maxCap && !raffle.underfilled) {
            raffle.underfilled = true;
            _returnPrizeToHost(_raffleId, raffle);
        }

        _distribute(_raffleId, raffle, winner);
        emit WinnerPicked(_raffleId, winner);
    }

    // ──────────────────────────────────────────────────────────────────────
    // Views
    // ──────────────────────────────────────────────────────────────────────

    /// @notice Returns the full state of a raffle.
    function getRaffle(uint256 _raffleId) external view returns (RaffleData memory) {
        return raffles[_raffleId];
    }

    // ──────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ──────────────────────────────────────────────────────────────────────

    /// @dev Write initial raffle record and increment counter. Does NOT transfer assets.
    function _initRaffle(
        address _host,
        address _asset,
        PrizeType _prizeType,
        uint256 _prizeAmountOrTokenId,
        uint256 _ticketPrice,
        uint256 _maxCap,
        uint256 _duration
    ) internal returns (uint256 raffleId) {
        raffleId = ++raffleCount;
        raffles[raffleId] = RaffleData({
            host:                 _host,
            expiry:               uint48(block.timestamp + _duration),
            status:               RaffleStatus.OPEN,
            underfilled:          false,
            prizeType:            _prizeType,
            prizeAsset:           _asset,
            ticketsSold:          0,
            prizeAmountOrTokenId: _prizeAmountOrTokenId,
            ticketPrice:          _ticketPrice,
            maxCap:               _maxCap
        });
    }

    /// @dev Return the prize to the host (called for zero-participant or underfilled raffles).
    function _returnPrizeToHost(uint256 _raffleId, RaffleData storage _raffle) internal {
        if (_raffle.prizeType == PrizeType.ERC721) {
            IERC721(_raffle.prizeAsset).safeTransferFrom(
                address(this), _raffle.host, _raffle.prizeAmountOrTokenId
            );
        } else {
            IERC20(_raffle.prizeAsset).safeTransfer(_raffle.host, _raffle.prizeAmountOrTokenId);
        }
        emit UnderfilledPrizeReturned(_raffleId, _raffle.host, _raffle.prizeAmountOrTokenId);
    }

    /// @dev Compute platform fee for a given amount.
    function _computeFee(uint256 _amount) internal view returns (uint256) {
        return (_amount * platformFeeBps) / 10_000;
    }

    /// @dev Distribute prizes, payments, and fees after winner selection.
    ///
    ///  Underfilled (prize already returned):
    ///    - winner gets paymentPool − paymentFee
    ///    - treasury gets paymentFee
    ///
    ///  Full-fill, ERC-20 prize:
    ///    - winner gets prizeAmount − prizeFee
    ///    - host   gets paymentPool − paymentFee
    ///    - treasury gets prizeFee + paymentFee
    ///
    ///  Full-fill, ERC-721 prize (NFT is indivisible – no prize fee):
    ///    - winner gets the NFT
    ///    - host   gets paymentPool − paymentFee
    ///    - treasury gets paymentFee
    function _distribute(
        uint256 _raffleId,
        RaffleData storage _raffle,
        address _winner
    ) internal {
        uint256 paymentPool = uint256(_raffle.ticketsSold) * _raffle.ticketPrice;
        uint256 paymentFee  = _computeFee(paymentPool);

        if (_raffle.underfilled) {
            // Prize already returned; distribute payment pool to winner
            IERC20(paymentToken).safeTransfer(_winner, paymentPool - paymentFee);
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
                emit PlatformFeeCollected(_raffleId, paymentFee);
            }
        } else if (_raffle.prizeType == PrizeType.ERC721) {
            // Full-fill with NFT prize – NFT is indivisible, no prize fee
            IERC721(_raffle.prizeAsset).safeTransferFrom(
                address(this), _winner, _raffle.prizeAmountOrTokenId
            );
            IERC20(paymentToken).safeTransfer(_raffle.host, paymentPool - paymentFee);
            if (paymentFee > 0) {
                IERC20(paymentToken).safeTransfer(treasury, paymentFee);
                emit PlatformFeeCollected(_raffleId, paymentFee);
            }
        } else {
            // Full-fill with ERC-20 prize
            uint256 prizeFee = _computeFee(_raffle.prizeAmountOrTokenId);
            IERC20(_raffle.prizeAsset).safeTransfer(_winner, _raffle.prizeAmountOrTokenId - prizeFee);
            IERC20(paymentToken).safeTransfer(_raffle.host, paymentPool - paymentFee);

            uint256 totalFees = prizeFee + paymentFee;
            if (prizeFee > 0)   IERC20(_raffle.prizeAsset).safeTransfer(treasury, prizeFee);
            if (paymentFee > 0) IERC20(paymentToken).safeTransfer(treasury, paymentFee);
            if (totalFees > 0)  emit PlatformFeeCollected(_raffleId, totalFees);
        }
    }
}
