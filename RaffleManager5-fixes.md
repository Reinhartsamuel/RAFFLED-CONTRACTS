# RaffleManager5 — Security Fixes

This document explains every change from RaffleManager4/FreeEntryVerifier to RaffleManager5/FreeEntryVerifier2, mapped to the audit findings they address.

---

## Finding 1 — Anyone Can Pick Raffle Winner (Confidence: 100)

**Problem:** `manualFulfillWinner` had zero access control. Any external caller could specify a `_winnerIndex` after expiry, deterministically selecting the winner and completely bypassing Chainlink VRF.

**Fix:** `manualFulfillWinner` removed entirely. The only winner selection path is now `performUpkeep` → VRF → `fulfillRandomWords`. If VRF fails, `emergencyFinalize` (permissionless after timeout) returns funds.

---

## Finding 2 — Public verifyAndClaim Burns Free Entries (Confidence: 100)

**Problem:** `verifyAndClaim` was `public` with no `msg.sender == user` check. Anyone could front-run `enterFreeRaffle` transactions and permanently burn a user's free entry claim without granting them a ticket.

**Fix:** `verifyAndClaim` is now `internal` in `FreeEntryVerifier2`. It can only be called through `enterFreeRaffle` in the child contract, which validates raffle state before invoking it.

**File:** `FreeEntryVerifier2.sol`

```diff
  function verifyAndClaim(uint256 raffleId, address user, bytes calldata signature)
-     public
+     internal
      returns (bool success)
```

---

## Finding 3 — Unbounded Loop Disables Chainlink Automation (Confidence: 90)

**Problem:** `checkUpkeep` iterated linearly from raffle ID 1 to `raffleCount`, scanning every raffle including completed ones. Gas costs grew unboundedly and eventually exceeded Chainlink Automation limits.

**Fix:** `checkUpkeep` now scans at most `CHECK_UPKEEP_BATCH` (50) raffles per call, starting from `lastCheckedRaffleId + 1`. The cursor advances as raffles are processed.

**File:** `RaffleManager5.sol`

```diff
+ uint256 public lastCheckedRaffleId;
+ uint256 public constant CHECK_UPKEEP_BATCH = 50;

  function checkUpkeep(bytes calldata) external view override returns (bool, bytes memory) {
-     for (uint256 i = 1; i <= raffleCount; ) {
+     uint256 count;
+     for (uint256 i = lastCheckedRaffleId + 1; i <= raffleCount && count < CHECK_UPKEEP_BATCH; ) {
          if (raffles[i].status == RaffleStatus.OPEN && block.timestamp >= raffles[i].expiry) {
              return (true, abi.encode(i));
          }
-         unchecked { ++i; }
+         unchecked { ++i; ++count; }
      }
      return (false, "");
  }
```

---

## Finding 4 — ERC-721 Winner Without Receiver Permanently Locks All Funds (Confidence: 90)

**Problem:** If VRF selected a contract participant without `onERC721Received` as the winner of an ERC-721 raffle, `safeTransferFrom` in `_distribute` reverted, which reverted the entire VRF callback. The raffle was permanently stuck in `PENDING_VRF` with no recovery mechanism.

**Fix:** ERC-721 full-fill raffles now use pull-based distribution. Instead of transferring the NFT immediately in `fulfillRandomWords`, the winner is stored in `pendingERC721Winner` and must call `claimERC721Prize` themselves. The claim function uses `transferFrom` (no `onERC721Received` callback), so contract winners can receive the NFT without implementing `IERC721Receiver`.

**File:** `RaffleManager5.sol`

New state:
```solidity
mapping(uint256 => address) public pendingERC721Winner;
```

In `fulfillRandomWords`:
```diff
  raffle.status = RaffleStatus.COMPLETED;
- _distribute(raffleId, raffle, winner);
+ if (raffle.prizeType == PrizeType.ERC721 && !raffle.underfilled) {
+     pendingERC721Winner[raffleId] = winner;
+     emit ERC721PrizeReady(raffleId, winner);
+ } else {
+     _distribute(raffleId, raffle, winner);
+ }
```

New function:
```solidity
function claimERC721Prize(uint256 _raffleId) external nonReentrant {
    address winner = pendingERC721Winner[_raffleId];
    if (winner == address(0)) revert NoPendingPrize();
    if (msg.sender != winner) revert NotWinner();
    delete pendingERC721Winner[_raffleId];
    _distributeERC721(_raffleId, raffles[_raffleId], winner);
}
```

New internal function using `transferFrom` instead of `safeTransferFrom`:
```solidity
function _distributeERC721(...) internal {
    // ...
    IERC721(_raffle.prizeAsset).transferFrom(address(this), _winner, _raffle.prizeAmountOrTokenId);
    // ...
}
```

---

## Finding 5 — Ownership Diverges After Transfer (Confidence: 80)

**Problem:** `FreeEntryVerifier` had a separate `verifierOwner` state variable with no transfer mechanism. After a `ConfirmedOwner` ownership transfer, the old deployer retained exclusive control over `setTrustedSigner`.

**Fix:** `FreeEntryVerifier2` removes `verifierOwner` entirely. It provides an internal `_setTrustedSigner` function that the child contract (`RaffleManager5`) exposes with `onlyOwner` access control, using the single `owner()` from `ConfirmedOwner`.

**File:** `FreeEntryVerifier2.sol`

```diff
- address public verifierOwner;
  // removed: onlyVerifierOwner modifier, NotOwner error

+ function _setTrustedSigner(address _newSigner) internal { ... }
```

**File:** `RaffleManager5.sol`

```solidity
function setTrustedSigner(address _newSigner) external onlyOwner {
    _setTrustedSigner(_newSigner);
}
```

---

## Finding 6 — No Recovery From VRF Failure (Confidence: 75)

**Problem:** If Chainlink VRF failed to fulfill (subscription drained, gas limit exceeded, coordinator outage), raffles were permanently stuck in `PENDING_VRF` with no timeout, admin recovery, or fallback mechanism.

**Fix:** Added a permissionless VRF timeout mechanism. `performUpkeep` records `raffleVrfRequestedAt[raffleId]`. After `VRF_TIMEOUT` (24 hours), anyone can call `emergencyFinalize` to return the prize and payment pool to the host. This eliminates Chainlink Automation as a single point of failure — if Automation goes down, anyone can still settle expired raffles.

**File:** `RaffleManager5.sol`

New state:
```solidity
mapping(uint256 => uint48) private raffleVrfRequestedAt;
uint256 public constant VRF_TIMEOUT = 24 hours;
```

In `performUpkeep`:
```diff
  requestIdToRaffleId[requestId] = raffleId;
+ raffleVrfRequestedAt[raffleId] = uint48(block.timestamp);
  raffle.status = RaffleStatus.PENDING_VRF;
```

New function:
```solidity
function emergencyFinalize(uint256 _raffleId) external nonReentrant {
    // Validates PENDING_VRF status and VRF_TIMEOUT elapsed
    // Returns prize to host, payment pool to host for off-chain refunds
}
```

---

## Lead Fix — setMinDuration Missing Lower Bound

**Problem:** NatSpec claimed "Cannot be set below 2 hours" but the code had no enforcement.

**Fix:** `setMinDuration` now reverts if `_newMinDuration < MIN_DURATION_FLOOR` (2 hours).

```diff
  function setMinDuration(uint256 _newMinDuration) external onlyOwner {
+     if (_newMinDuration < MIN_DURATION_FLOOR)
+         revert DurationTooShort(_newMinDuration, MIN_DURATION_FLOOR);
      minDuration = _newMinDuration;
  }
```

---

## Lead Fix — Zero-Participant Raffle Skips Underfilled Flag

**Problem:** When `participants.length == 0`, `performUpkeep` returned the prize but left `underfilled = false` (acknowledged by in-code TODO).

**Fix:** Added `raffle.underfilled = true` in the zero-participant branch.

```diff
  if (participants[raffleId].length == 0) {
+     raffle.underfilled = true;
      raffle.status = RaffleStatus.COMPLETED;
      _returnPrizeToHost(raffleId, raffle);
```

---

## Lead Fix — uint48 Expiry Truncation

**Problem:** `_duration` was validated as uint256 but stored as uint48. Durations ≥ 2^48 silently truncated.

**Fix:** Added overflow check in `_initRaffle`.

```diff
  function _initRaffle(...) internal returns (uint256 raffleId) {
+     if (block.timestamp + _duration > type(uint48).max) revert InvalidParams();
      raffleId = ++raffleCount;
```

---

## Migration Notes

1. **Backend signature format unchanged.** The `FREE_ENTRY_TYPEHASH` is identical: `FreeEntry(uint256 raffleId,address user)`. No backend changes needed.

2. **ERC-721 winners must call `claimERC721Prize`.** Frontends need to detect `ERC721PrizeReady` events and prompt the winner to claim. This is a UX change from RaffleManager4 where prizes were distributed automatically.

3. **`checkUpkeep` pagination.** Chainlink Automation may need to call `checkUpkeep` multiple times to find an expired raffle. This is normal — Automation already supports repeated calls.

4. **`emergencyFinalize` is permissionless.** Anyone can call it after VRF_TIMEOUT. Returns funds to the host, who should distribute refunds to participants off-chain. Consider adding a per-user refund mechanism in a future version if needed.

5. **`manualFulfillWinner` removed.** The only winner selection path is VRF via `performUpkeep` → `fulfillRandomWords`. If VRF fails, `emergencyFinalize` returns funds after the timeout.

---

## Audit Round 2 — Post-Hardening Findings

The second audit pass (12-agent parallel scan of RaffleManager5 + FreeEntryVerifier2) found 5 findings. All addressed below.

---

### Finding R2-1 — `emergencyFinalize` reverts for underfilled raffles [Confidence: 100]

**Problem:** `emergencyFinalize` unconditionally attempts to return the prize to the host, but for underfilled raffles `performUpkeep` already returned the prize via `_returnPrizeToHost` before requesting VRF. The contract no longer holds the prize asset, so the `safeTransfer` reverts, atomically blocking the payment pool return and permanently locking all participant USDC with no recovery path.

**Fix:** Guard the prize-return block in `emergencyFinalize` with `if (!raffle.underfilled)`.

```diff
  raffle.status = RaffleStatus.COMPLETED;
  delete raffleVrfRequestedAt[_raffleId];
  delete pendingERC721Winner[_raffleId];

- // Return prize to host
- if (raffle.prizeType == PrizeType.ERC721) {
-     IERC721(raffle.prizeAsset).safeTransferFrom(
-         address(this), raffle.host, raffle.prizeAmountOrTokenId
-     );
- } else {
-     IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmountOrTokenId);
+ // Return prize to host (skip if already returned by performUpkeep for underfilled raffles)
+ if (!raffle.underfilled) {
+     if (raffle.prizeType == PrizeType.ERC721) {
+         IERC721(raffle.prizeAsset).safeTransferFrom(
+             address(this), raffle.host, raffle.prizeAmountOrTokenId
+         );
+     } else {
+         IERC20(raffle.prizeAsset).safeTransfer(raffle.host, raffle.prizeAmountOrTokenId);
+     }
  }
```

---

### Finding R2-2 — `performUpkeep` accepts non-existent raffle IDs [Confidence: 100]

**Problem:** `performUpkeep` decodes `raffleId` from arbitrary `performData` without validating `raffleId > 0 && raffleId <= raffleCount`. A non-existent raffle resolves to default storage values (status=OPEN, expiry=0) that pass all guard checks. The zero-participant path succeeds (SafeERC20 is a no-op for address(0)), setting `lastCheckedRaffleId = type(uint256).max`. The next `checkUpkeep` call overflows `lastCheckedRaffleId + 1` in checked arithmetic (Solidity 0.8+), permanently reverting and disabling all Chainlink Automation.

**Fix:** Add bounds check at the top of `performUpkeep`.

```diff
  function performUpkeep(bytes calldata performData) external override nonReentrant {
      uint256 raffleId = abi.decode(performData, (uint256));
+     if (raffleId == 0 || raffleId > raffleCount) return;
      RaffleData storage raffle = raffles[raffleId];
```

---

### Finding R2-3 — No timeout for unclaimed ERC-721 full-fill prizes [Confidence: 75]

**Problem:** Full-fill ERC-721 raffles store the winner in `pendingERC721Winner` for pull-based claiming but have no timeout or fallback. If the winner never claims (lost key, inaccessible contract wallet, unaware winner), both the NFT and the host's payment pool are permanently locked. `emergencyFinalize` requires `PENDING_VRF` status (raffle is `COMPLETED`), and `claimERC721Prize` requires `msg.sender == winner`.

**Fix:** Added `ERC721_CLAIM_TIMEOUT` (30 days), `erc721PrizeClaimableAt` tracking, and `hostReclaimUnclaimed` function.

New state + constant:
```solidity
mapping(uint256 => uint48) private erc721PrizeClaimableAt;
uint256 public constant ERC721_CLAIM_TIMEOUT = 30 days;
```

In `fulfillRandomWords`:
```diff
  if (raffle.prizeType == PrizeType.ERC721 && !raffle.underfilled) {
      pendingERC721Winner[raffleId] = winner;
+     erc721PrizeClaimableAt[raffleId] = uint48(block.timestamp);
      emit ERC721PrizeReady(raffleId, winner);
```

In `claimERC721Prize`:
```diff
  delete pendingERC721Winner[_raffleId];
+ delete erc721PrizeClaimableAt[_raffleId];
  _distributeERC721(_raffleId, raffles[_raffleId], winner);
```

New function:
```solidity
function hostReclaimUnclaimed(uint256 _raffleId) external nonReentrant {
    // Only host can call, only after ERC721_CLAIM_TIMEOUT
    // Returns NFT and payment pool to host
}
```

---

### Finding R2-4 — `checkUpkeep` pagination cursor skips lower-numbered raffles [Confidence: 75]

**Problem:** `lastCheckedRaffleId` only advances forward inside `performUpkeep`. Raffles with lower IDs that expire after higher-ID raffles are permanently invisible to Chainlink Automation.

**Fix:** `checkUpkeep` now wraps around: after scanning forward from the cursor to `raffleCount`, it scans from ID 1 up to the cursor with the remaining batch budget. This catches raffles that expired after being skipped by a forward cursor jump.

```diff
  function checkUpkeep(bytes calldata) external view override returns (bool, bytes memory) {
+     uint256 start = lastCheckedRaffleId + 1;
      uint256 count;
-     for (uint256 i = lastCheckedRaffleId + 1; i <= raffleCount && count < CHECK_UPKEEP_BATCH; ) {
+     for (uint256 i = start; i <= raffleCount && count < CHECK_UPKEEP_BATCH; ) {
          if (raffles[i].status == RaffleStatus.OPEN && block.timestamp >= raffles[i].expiry) {
              return (true, abi.encode(i));
          }
          unchecked { ++i; ++count; }
      }
+     // Wrap: scan from 1 up to cursor with remaining batch budget
+     if (start > 1 && count < CHECK_UPKEEP_BATCH) {
+         for (uint256 i = 1; i < start && count < CHECK_UPKEEP_BATCH; ) {
+             if (raffles[i].status == RaffleStatus.OPEN && block.timestamp >= raffles[i].expiry) {
+                 return (true, abi.encode(i));
+             }
+             unchecked { ++i; ++count; }
+         }
+     }
      return (false, "");
  }
```

---

### Finding R2-5 — Single `performUpkeep` revert blocks all subsequent automation [Confidence: 75]

**Problem:** If `performUpkeep` reverts for a specific raffle (e.g., prize token blacklisted, paused, or non-standard), the pagination cursor never advances past that raffle. `checkUpkeep` keeps returning the same expired raffle, `performUpkeep` keeps reverting, and all raffles with higher IDs are never automatically discovered.

**Mitigation:** Primarily mitigated by R2-2 (bounds check prevents non-existent raffle DoS) and R2-4 (wrapping scan catches raffles before the cursor). The remaining edge case — a valid raffle whose prize token is permanently broken — is an inherent limitation of the pagination pattern. If this occurs, manual `performUpkeep` calls with specific raffle IDs for other raffles can still be used to advance the cursor. No code change beyond R2-2 and R2-4.

---

### Lead — VRF callback failure amplifies R2-1 for underfilled raffles

Fixed `CALLBACK_GAS_LIMIT=300_000` with no admin override. If the VRF callback fails for an underfilled raffle (token blacklist, gas exhaustion, complex hooks), the raffle enters PENDING_VRF. R2-1's fix ensures `emergencyFinalize` can now recover these raffles (the `!raffle.underfilled` guard skips the already-returned prize). Fully mitigated by R2-1.

---

### Lead — Fee-on-transfer prize token permanently locks all funds

`createRaffleERC20` accepts any ERC-20 as the prize asset. If a fee-on-transfer token is used, the contract receives less than `prizeAmountOrTokenId`. Both `_distribute` and `emergencyFinalize` attempt to transfer the full stored amount, reverting and locking both the prize remainder and all participant USDC. `paymentToken` is expected to be USDC (immutable, constructor-set) but prize tokens are unconstrained. Self-harm risk for the host, with collateral damage to participants. Not fixed — hosts should use standard ERC-20 tokens as prizes.
