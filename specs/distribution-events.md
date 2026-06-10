# Spec: Add Distribution Events to RaffleManager4

## Problem

`_distribute()` performs all prize/payout transfers but emits no event. Off-chain indexers and the frontend cannot reconstruct what was paid out — only that a `WinnerPicked` occurred. `PlatformFeeCollected` exists but gives no visibility into winner or host payouts.

## Solution

Add **three separate events** — one per distribution path — so every on-chain transfer is transparently indexed.

### Events

#### `UnderfilledPayout`

Emitted when `raffle.underfilled == true` (prize already returned to host, payment pool goes to winner).

```solidity
event UnderfilledPayout(
    uint256 indexed raffleId,
    address indexed winner,
    address paymentToken,
    uint256 winnerAmount,    // paymentPool - fee
    uint256 feeAmount        // to treasury
);
```

#### `NFTPrizeAwarded`

Emitted on full-fill with an ERC-721 prize (indivisible, no prize fee).

```solidity
event NFTPrizeAwarded(
    uint256 indexed raffleId,
    address indexed winner,
    address nftContract,
    uint256 tokenId,
    uint256 hostAmount,      // paymentPool - fee
    uint256 feeAmount        // to treasury
);
```

#### `TokenPrizeAwarded`

Emitted on full-fill with an ERC-20 prize (fee taken from prize + payment pool).

```solidity
event TokenPrizeAwarded(
    uint256 indexed raffleId,
    address indexed winner,
    address prizeAsset,
    uint256 winnerPrizeAmount,  // prizeAmount - prizeFee
    uint256 hostAmount,         // paymentPool - fee
    uint256 prizeFee,
    uint256 paymentFee
);
```

### Placement

All three emit at the **end of `_distribute()`** in their respective `if / else if / else` branches, alongside the existing `PlatformFeeCollected` event.

### Emission calls

```solidity
// Underfilled branch:
emit UnderfilledPayout(
    _raffleId,
    _winner,
    paymentToken,
    paymentPool - paymentFee,
    paymentFee
);

// ERC-721 full-fill branch:
emit NFTPrizeAwarded(
    _raffleId,
    _winner,
    _raffle.prizeAsset,
    _raffle.prizeAmountOrTokenId,
    paymentPool - paymentFee,
    paymentFee
);

// ERC-20 full-fill branch:
emit TokenPrizeAwarded(
    _raffleId,
    _winner,
    _raffle.prizeAsset,
    _raffle.prizeAmountOrTokenId - prizeFee,
    paymentPool - paymentFee,
    prizeFee,
    paymentFee
);
```

### Paths triggered from

- `fulfillRandomWords()` → calls `_distribute()` (Chainlink VRF callback)
- `manualFulfillWinner()` → calls `_distribute()` (manual/testing fallback)

Both paths will now emit the appropriate event.

### Backwards compatibility

- Pure addition — no existing events, functions, or storage are modified.
- Events are appended; no ABI breakage for existing integrations.
