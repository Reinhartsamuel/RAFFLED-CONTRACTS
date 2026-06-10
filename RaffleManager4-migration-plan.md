# RaffleManager4 Security Hardening Plan

## Priority 0 (Must Fix Before Mainnet)

### Remove Public Manual Winner Selection

Issue:

* Any user can choose the winner by calling `manualFulfillWinner()`.
* Completely bypasses Chainlink VRF.

Required Action:

* Remove `manualFulfillWinner()` from production deployment.

Alternative:

* Restrict with `onlyOwner`.
* Add explicit emergency-only settlement conditions.
* Emit dedicated emergency settlement events.

Success Criteria:

* No path exists that allows arbitrary winner selection.

---

## Priority 1 (High Severity)

### Add VRF Recovery Mechanism

Issue:

* Raffle can become permanently stuck in `PENDING_VRF`.

Required Action:

Add:

```solidity
uint48 vrfRequestedAt;
```

Store request timestamp.

Add:

```solidity
function retryVRFRequest(...)
```

and/or

```solidity
function emergencyFinalize(...)
```

available only after timeout.

Recommended timeout:

```solidity
24 hours
```

Success Criteria:

* No raffle can remain permanently unresolved.

---

### Replace Linear Automation Scan

Issue:

```solidity
for (uint256 i = 1; i <= raffleCount; i++)
```

does not scale.

Required Action:

Maintain:

```solidity
uint256[] activeRaffles;
```

or

```solidity
mapping(uint256 => bool) active;
```

with queue/index tracking.

Success Criteria:

* Automation complexity is O(1) or O(log n).

---

### Add Explicit Emergency Expiry Settlement

Issue:

* Protocol currently relies heavily on Automation availability.

Required Action:

Add:

```solidity
function emergencyCloseExpiredRaffle(...)
```

allowing anyone to settle an expired raffle after a grace period.

Success Criteria:

* Expired raffles are always recoverable.

---

## Priority 2 (Medium Severity)

### Unify Ownership

Issue:

* `owner`
* `verifierOwner`

can diverge.

Required Action:

Remove:

```solidity
address verifierOwner;
```

Use shared ownership model.

Example:

```solidity
Ownable
```

throughout inheritance tree.

Success Criteria:

* Single authority controls administration.

---

### Add Signature Expiration

Current:

```solidity
FreeEntry(
    uint256 raffleId,
    address user
)
```

Proposed:

```solidity
FreeEntry(
    uint256 raffleId,
    address user,
    uint256 deadline
)
```

Verification:

```solidity
require(block.timestamp <= deadline);
```

Success Criteria:

* Old signatures cannot remain valid indefinitely.

---

## Priority 3 (Architecture Improvements)

### Replace Address-Per-Ticket Storage

Current:

```solidity
address[] participants
```

with repeated pushes.

Proposed:

```solidity
struct EntryRange {
    address participant;
    uint256 cumulativeTickets;
}
```

Winner selection:

1. Generate random ticket number.
2. Binary search cumulative ranges.
3. Resolve winner.

Complexity:

Current:

* Storage O(totalTickets)

Proposed:

* Storage O(numberOfBuyers)

Benefits:

* Lower gas
* Lower state growth
* Better long-term scalability

---

### Review Underfilled Raffle Economics

Current:

* Prize returns to host.
* Payment pool raffled.

Evaluate alternatives:

Option A:

* Refund participants.

Option B:

* Minimum participation threshold.

Option C:

* Host chooses behavior at creation.

Success Criteria:

* Economic incentives remain fair under low participation.

```
```
