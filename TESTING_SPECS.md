# Testing Specification: Foundry & Quality Assurance

## Environment Setup
- **Framework**: Foundry (`forge`).
- **Mocks**: Implement `VRFCoordinatorV2_5Mock` for local randomness testing.
- **Time Travel**: Use `vm.warp` to simulate raffle expiry.

## Testing Checklist (99% Coverage Target)
1. **Fuzzing**:
   - Fuzz `ticketCount` in `enterRaffle` to ensure `maxCap` cannot be bypassed.
   - Fuzz `randomWords` to verify winner selection across different array lengths.
2. **Edge Cases**:
   - Raffle with 0 participants at expiry (Status should move to CANCELLED or handle gracefully).
   - Prize asset is a "weird" ERC20 (no return value, fee-on-transfer).
   - Multiple raffles expiring simultaneously (Automation check).
3. **Security**:
   - Reentrancy check on `claimRefund` and `enterRaffle`.
   - Ensure `fulfillRandomWords` can ONLY be called by the VRF Coordinator.
4. **Integration**:
   - Full lifecycle: Create -> Enter -> Warp Time -> Upkeep -> VRF Callback -> Prize Delivery.
