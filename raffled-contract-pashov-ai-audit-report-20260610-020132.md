# 🔐 Security Review — raffled-contract

---

## Scope

|                                  |                                                        |
| -------------------------------- | ------------------------------------------------------ |
| **Mode**                         | filename                                               |
| **Files reviewed**               | `FreeEntryVerifier2.sol` · `RaffleManager7.sol`        |
| **Confidence threshold (1-100)** | 80                                                     |

---

## Findings

[100] **1. Compilation Failure Due to Missing Ownable Inheritance**

`RaffleManager7.setTrustedSigner, setMinDuration, proposeFeeChange, applyFeeChange` · Confidence: 100

**Description**
The contract uses the `onlyOwner` modifier but does not inherit from any contract that defines it (e.g., `Ownable` or `ConfirmedOwner`), resulting in a hard compilation failure.

**Fix**

```diff
+ import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

- contract RaffleManager7 is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, IERC721Receiver, ReentrancyGuard, FreeEntryVerifier2
+ contract RaffleManager7 is VRFConsumerBaseV2Plus, AutomationCompatibleInterface, IERC721Receiver, ReentrancyGuard, FreeEntryVerifier2, Ownable
```
---

[95] **2. Hardcoded EIP-712 Domain Name Mismatch**

`FreeEntryVerifier2.EIP712` · Confidence: 95

**Description**
The EIP-712 domain name is hardcoded to "RaffleManager5", which will cause signature verification to fail for RaffleManager7 if the backend signs with the correct contract name.

**Fix**

```diff
- abstract contract FreeEntryVerifier2 is EIP712("RaffleManager5", "1") {
+ abstract contract FreeEntryVerifier2 is EIP712("RaffleManager", "1") {
```
---

[95] **3. Host Can Steal Participant Funds in Unclaimed ERC-721 Raffles**

`RaffleManager7.hostReclaimUnclaimed` · Confidence: 95

**Description**
The host can reclaim the entire payment pool and the NFT if the winner does not claim the ERC-721 prize within 30 days, permanently locking user refunds because the raffle status remains `COMPLETED`.

**Fix**

```diff
-         // Return payment pool to host
-         uint256 paymentPool = rafflePaymentPool[_raffleId];
-         uint256 paymentFee = _computeFee(paymentPool);
-         if (paymentFee > 0) {
-             IERC20(paymentToken).safeTransfer(treasury, paymentFee);
-         }
-
-         delete rafflePaymentPool[_raffleId];
-         if (paymentPool > 0) {
-             IERC20(paymentToken).safeTransfer(
-                 raffle.host,
-                 paymentPool - paymentFee
-             );
-         }
+         // Allow participants to claim refunds instead of returning funds to the host
+         raffle.status = RaffleStatus.CANCELLED;
```
---

[85] **4. Pagination Wrap-Around Starvation in checkUpkeep**

`RaffleManager7.checkUpkeep` · Confidence: 85

**Description**
The forward scan in `checkUpkeep` can consume the entire `CHECK_UPKEEP_BATCH` budget, preventing the wrap-around scan from executing and causing older expired raffles to be permanently starved from automation checks.

**Fix**

```diff
-         // Wrap: if cursor > 1, scan from 1 up to cursor with remaining batch budget
-         if (start > 1 && count < CHECK_UPKEEP_BATCH) {
+         // Wrap: if cursor > 1, scan from 1 up to cursor with a fresh batch budget
+         if (start > 1) {
+             uint256 wrapCount = 0;
              for (uint256 i = 1; i < start && wrapCount < CHECK_UPKEEP_BATCH; ) {
                  if (
                      raffles[i].status == RaffleStatus.OPEN &&
                      block.timestamp >= raffles[i].expiry
                  ) {
                      return (true, abi.encode(i));
                  }
                  unchecked {
                      ++i;
                      ++wrapCount;
                  }
              }
          }
```
---

[80] **5. Permanent Fund Lock if VRF Request Reverts**

`RaffleManager7.performUpkeep` · Confidence: 80

**Description**
If the Chainlink VRF request reverts (e.g., subscription out of LINK), the raffle remains permanently stuck in `OPEN` status, locking both the host's prize and users' ticket payments with no recovery path.

**Fix**
Allow the host or a permissionless caller to cancel an `OPEN` raffle after its expiry, or implement a `try/catch` around the VRF request to transition the raffle to a `FAILED` state that permits refunds.

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Type Inconsistency in Max Cap Check** — `RaffleManager7.enterFreeRaffle` — Code smells: `totalTickets` is `uint96`, so `totalTickets[_raffleId] + 1` performs `uint96` addition. If `totalTickets` is `type(uint96).max`, this overflows to 0, bypassing the `> maxCap` check, though it subsequently reverts in `_addTickets` due to Solidity 0.8.x built-in overflow checks.
- **Dead Variable in RaffleData** — `RaffleManager7.enterRaffle, enterFreeRaffle` — Code smells: `raffle.ticketsSold` is incremented in `enterRaffle` and `enterFreeRaffle` but is never read anywhere in the contract. `totalTickets` is used for all logic, indicating a leftover variable from a previous iteration that wastes gas.

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [100] | Compilation Failure Due to Missing Ownable Inheritance |
| 2 | [95] | Hardcoded EIP-712 Domain Name Mismatch |
| 3 | [95] | Host Can Steal Participant Funds in Unclaimed ERC-721 Raffles |
| 4 | [85] | Pagination Wrap-Around Starvation in checkUpkeep |
| 5 | [80] | Permanent Fund Lock if VRF Request Reverts |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)