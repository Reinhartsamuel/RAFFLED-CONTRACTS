# Smart Contract Technical Specification: RaffleManager

## Overview
A gas-optimized, decentralized raffle management system using Foundry, OpenZeppelin, and Chainlink VRF v2.5 / Automation.

## Core Architecture
- **Pattern**: Single Manager Contract (prevents fragmentation and simplifies indexing).
- **Inheritance**: `VRFConsumerBaseV2Plus`, `AutomationCompatibleInterface`, `ReentrancyGuard`, `Ownable`.

## State & Gas Optimization
- **Participant Storage**: `mapping(uint256 => address[]) public participants`.
- **Winning Logic**: Selection MUST be $O(1)$. Calculate winner as `participants[raffleId][randomWord % participants[raffleId].length]`.
- **Storage Packing**: Use `uint48` for timestamps and `uint32` for raffle status/config where applicable to fit multiple variables into single slots.

## Functions to Implement
1. `createRaffle(address _asset, uint256 _amount, uint256 _ticketPrice, uint256 _maxCap, uint256 _duration)`
   - Must use `SafeERC20` to lock the prize.
2. `enterRaffle(uint256 _raffleId, uint256 _ticketCount)`
   - Users can buy multiple tickets. Push their address to the array multiple times.
3. `cancelRaffle(uint256 _raffleId)`
   - **Condition**: Only if `expiry` is reached and `maxCap` is NOT met.
   - **Logic**: Set status to `CANCELLED`.
4. `claimRefund(uint256 _raffleId)`
   - **Pattern**: Pull-based. Users call this to get their ETH/Tokens back if the raffle is cancelled.
5. `fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords)`
   - Internal callback. Transfers prize asset directly to the winner wallet.

## Chainlink Integration
- **Automation**: `checkUpkeep` returns true if any raffle is past `expiry` and status is `OPEN`.
- **VRF**: `performUpkeep` calls `requestRandomWords`.
