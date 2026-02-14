# Raffled Contract

A gas-optimized, decentralized raffle management system built with Foundry, OpenZeppelin, and Chainlink VRF v2.5 for provably fair randomness.

## Overview

**Raffled** is a production-ready smart contract platform that enables anyone to create and manage trustless raffles on EVM-compatible blockchains. The system leverages Chainlink's decentralized oracle network for:
- **Chainlink VRF v2.5**: Verifiable on-chain randomness for winner selection
- **Chainlink Automation**: Automated raffle expiry detection and execution

### Key Features

✅ **Gas-Optimized Architecture**: Storage packing reduces per-raffle state from 7 slots to 5 slots
✅ **Single Manager Contract**: Prevents fragmentation and simplifies event indexing
✅ **O(1) Winner Selection**: Constant-time winner calculation regardless of participant count
✅ **Dual Payment Support**: Accept payments in native ETH or any ERC-20 token
✅ **Pull-Based Refunds**: Secure CEI pattern for cancelled raffle refunds
✅ **Provably Fair**: Chainlink VRF ensures tamper-proof randomness
✅ **Manual Fallback**: Frontend integration functions for testing and manual resolution

## Architecture

### Core Contract: `RaffleManager.sol`

The `RaffleManager` contract inherits from:
- `VRFConsumerBaseV2Plus` - Chainlink VRF v2.5 integration
- `AutomationCompatibleInterface` - Chainlink Automation compatibility
- `ReentrancyGuard` - Reentrancy protection (OpenZeppelin)
- `Ownable` - Access control (OpenZeppelin)

### Storage Design

Each raffle is stored in a gas-optimized `RaffleData` struct with strategic slot packing:

```solidity
struct RaffleData {
    address      host;           // 20 B  ┐
    uint48       expiry;         //  6 B  │ Slot 0 (27 B used)
    RaffleStatus status;         //  1 B  ┘
    address      prizeAsset;     // 20 B  ┐
    uint96       ticketsSold;    // 12 B  ┘ Slot 1 (32 B used)
    address      paymentAsset;   // 20 B     Slot 2
    uint256      prizeAmount;    // 32 B     Slot 3
    uint256      ticketPrice;    // 32 B     Slot 4
    uint256      maxCap;         // 32 B     Slot 5
}
```

**Gas Savings**: 2 storage slots saved per raffle = ~40,000 gas saved on raffle creation

### Participant Storage

```solidity
mapping(uint256 => address[]) public participants;
```

Each ticket purchased pushes the buyer's address into the array. This design enables:
- **O(1) Winner Selection**: `winner = participants[raffleId][randomWord % length]`
- **Fair Probability**: Multiple tickets = multiple array entries = proportional win chance

## Core Functions

### 1. Create Raffle

```solidity
function createRaffle(
    address _asset,         // Prize token (ERC-20)
    uint256 _amount,        // Prize amount
    address _paymentAsset,  // Payment token (address(0) for ETH)
    uint256 _ticketPrice,   // Price per ticket
    uint256 _maxCap,        // Maximum tickets
    uint256 _duration       // Duration in seconds
) external returns (uint256 raffleId)
```

**Requirements**:
- Host must approve prize tokens before calling
- All parameters must be non-zero
- `maxCap` must fit in `uint96` (max ≈ 7.9 × 10²⁸)

**Process**:
1. Validates parameters
2. Creates raffle with `OPEN` status
3. Locks prize tokens via `SafeERC20.safeTransferFrom()`
4. Emits `RaffleCreated` event

### 2. Enter Raffle

```solidity
function enterRaffle(uint256 _raffleId, uint256 _ticketCount)
    external payable nonReentrant
```

**Requirements**:
- Raffle must be `OPEN` and not expired
- For ETH payments: `msg.value == ticketPrice * ticketCount`
- For ERC-20 payments: Caller must approve tokens first

**Process**:
1. Validates raffle status and capacity
2. Handles payment (ETH or ERC-20)
3. Updates `ticketsSold` counter
4. Pushes buyer address to `participants` array `_ticketCount` times
5. Emits `TicketPurchased` event

### 3. Cancel Raffle

```solidity
function cancelRaffle(uint256 _raffleId) external nonReentrant
```

**Requirements**:
- Raffle must be `OPEN`
- Raffle must be expired (`block.timestamp >= expiry`)
- Max capacity must not be reached

**Process**:
1. Sets status to `CANCELLED`
2. Returns prize to host
3. Emits `RaffleCancelled` event

### 4. Claim Refund

```solidity
function claimRefund(uint256 _raffleId) external nonReentrant
```

**Requirements**:
- Raffle must be `CANCELLED`
- Caller must have purchased tickets

**Process**:
1. Calculates refund: `tickets * ticketPrice`
2. Zeroes user's ticket count (CEI pattern)
3. Transfers refund (ETH or ERC-20)
4. Emits `RefundClaimed` event

### 5. Chainlink Integration

#### `checkUpkeep` (Off-chain)
```solidity
function checkUpkeep(bytes calldata)
    external view
    returns (bool upkeepNeeded, bytes memory performData)
```

Scans all raffles to find expired `OPEN` raffles. Returns `true` and the `raffleId` when upkeep is needed.

#### `performUpkeep` (On-chain)
```solidity
function performUpkeep(bytes calldata performData) external
```

**Triggered by**: Chainlink Automation or manual call
**Process**:
1. Re-validates raffle is expired and `OPEN`
2. **Edge case**: If zero participants, auto-cancels and returns prize
3. Requests randomness from Chainlink VRF
4. Stores `requestId → raffleId` mapping
5. Emits `VRFRequested` event

#### `fulfillRandomWords` (Callback)
```solidity
function fulfillRandomWords(uint256 _requestId, uint256[] memory _randomWords)
    internal override
```

**Called by**: Chainlink VRF Coordinator (permissioned)
**Process**:
1. Retrieves `raffleId` from request mapping
2. Validates raffle is still `OPEN` (idempotency guard)
3. Calculates winner: `index = randomWords[0] % participants.length`
4. Sets status to `COMPLETED`
5. Transfers prize to winner
6. Emits `WinnerPicked` event

### 6. Manual Winner Selection (Testing/Fallback)

#### By Index
```solidity
function manualFulfillWinner(uint256 _raffleId, uint256 _winnerIndex)
    external nonReentrant
```

#### By Random Word
```solidity
function manualFulfillWinnerByRandomWord(uint256 _raffleId, uint256 _randomWord)
    external nonReentrant
```

These functions allow frontend integration and testing before Chainlink integration is activated.

## Events

```solidity
event RaffleCreated(uint256 indexed raffleId, address indexed host, address prizeAsset, uint256 prizeAmount, address paymentAsset, uint48 expiry);
event TicketPurchased(uint256 indexed raffleId, address indexed buyer, uint256 ticketCount);
event RaffleCancelled(uint256 indexed raffleId);
event WinnerPicked(uint256 indexed raffleId, address indexed winner);
event RefundClaimed(uint256 indexed raffleId, address indexed claimer, uint256 amount);
event VRFRequested(uint256 indexed raffleId, uint256 requestId);
```

## Security Features

### Reentrancy Protection
- All state-changing functions use `nonReentrant` modifier
- Follows Checks-Effects-Interactions (CEI) pattern
- Zero state before external calls in `claimRefund`

### Access Control
- `fulfillRandomWords` only callable by VRF Coordinator
- Prize locked in contract until raffle completion
- Pull-based refunds prevent griefing attacks

### Input Validation
- Comprehensive parameter validation with custom errors
- Overflow protection via Solidity 0.8+ built-in checks
- `SafeERC20` handles non-standard ERC-20 tokens

### Gas Optimization
- Storage slot packing (5 slots vs 7 slots)
- Unchecked counters where overflow is impossible
- O(1) winner selection algorithm
- Immutable VRF configuration

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Git
- A code editor (VS Code recommended)

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd raffled-contract

# Install dependencies
forge install

# Build contracts
forge build
```

### Environment Configuration

Create a `.env` file:

```env
# RPC URLs
RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_API_KEY
MAINNET_RPC_URL=https://mainnet.base.org

# Deployment
PRIVATE_KEY=your_private_key_here

# Chainlink VRF v2.5 (Base Sepolia)
VRF_COORDINATOR=0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE
KEY_HASH=0xc799bd1e3bd4d1a41cd4968997a4e03dfd2a3c7c04b695881138580163f42887
SUBSCRIPTION_ID=your_subscription_id
```

### Running Tests

```bash
# Run all tests
forge test

# Run with gas reporting
forge test --gas-report

# Run with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/Raffle.t.sol

# Run with coverage
forge coverage
```

### Deployment

#### Deploy to Base Sepolia

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

#### Deploy Mock USDC (for testing)

```bash
forge script script/DeployMockUSDC.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  -vvv
```

See [MOCK_USDC_DEPLOYMENT_GUIDE.md](MOCK_USDC_DEPLOYMENT_GUIDE.md) for detailed instructions.

## Testing Strategy

The test suite targets **99% code coverage** with:

### 1. Fuzzing Tests
- Fuzz `ticketCount` in `enterRaffle` to verify capacity checks
- Fuzz `randomWords` to test winner selection across array sizes
- Fuzz prize amounts and ticket prices

### 2. Edge Case Coverage
- Zero participants at expiry
- Single participant
- Max capacity edge cases
- "Weird" ERC-20 tokens (fee-on-transfer, no return value)
- Multiple simultaneous raffles

### 3. Security Tests
- Reentrancy attempts on `claimRefund` and `enterRaffle`
- VRF coordinator access control
- Unauthorized `performUpkeep` calls
- Double-spend prevention

### 4. Integration Tests
```
Full lifecycle flow:
Create Raffle → Enter Raffle → Time Warp → checkUpkeep →
performUpkeep → VRF Callback → Prize Delivery
```

See [TESTING_SPECS.md](TESTING_SPECS.md) for complete testing specifications.

## Gas Benchmarks

| Function | Estimated Gas | Notes |
|----------|--------------|-------|
| `createRaffle()` | ~120,000 | Includes ERC-20 transfer |
| `enterRaffle(1)` | ~70,000 | First ticket (cold storage) |
| `enterRaffle(10)` | ~250,000 | 10 tickets |
| `cancelRaffle()` | ~45,000 | Includes ERC-20 refund |
| `claimRefund()` | ~35,000 | Pull-based refund |
| `performUpkeep()` | ~100,000 | VRF request |
| `fulfillRandomWords()` | ~80,000 | Winner selection + transfer |

## Project Structure

```
raffled-contract/
├── src/
│   ├── RaffleManager.sol              # Main contract
│   └── interfaces/
│       ├── VRFConsumerBaseV2Plus.sol  # Chainlink VRF base
│       ├── VRFV2PlusClient.sol        # VRF client library
│       └── AutomationCompatibleInterface.sol
├── script/
│   ├── Deploy.s.sol                   # Deployment script
│   └── DeployMockUSDC.s.sol          # Mock token deployment
├── test/
│   ├── Raffle.t.sol                  # Test suite
│   └── mocks/
│       └── MockUSDC.sol              # Test token
├── lib/                              # Foundry dependencies
│   ├── forge-std/                    # Foundry standard library
│   └── openzeppelin-contracts/       # OpenZeppelin v5
├── foundry.toml                      # Foundry configuration
├── CONTRACT_SPECS.md                 # Technical specification
├── TESTING_SPECS.md                  # Testing requirements
├── BACKEND_SPECS.md                  # Backend/indexing specs
└── MOCK_USDC_DEPLOYMENT_GUIDE.md    # Deployment guide
```

## Integration Guide

### Frontend Integration

The contract is designed for easy frontend integration:

1. **Event Indexing**: Use [Ponder](https://ponder.sh/) or [Envio](https://envio.dev/) to index events
2. **Manual Resolution**: Provide a "Resolve Now" button calling `performUpkeep()`
3. **Real-time Updates**: Subscribe to events for live raffle status
4. **Winner Display**: Use `WinnerPicked` event for winner announcements

### Backend Requirements

See [BACKEND_SPECS.md](BACKEND_SPECS.md) for:
- Event indexing setup (Ponder/Envio)
- GraphQL API schema
- SIWE authentication
- Off-chain metadata storage
- Webhook notifications

## Chainlink Configuration

### VRF Subscription Setup

1. Visit [Chainlink VRF](https://vrf.chain.link/)
2. Create a subscription
3. Fund with LINK tokens
4. Add `RaffleManager` as consumer
5. Copy subscription ID to `.env`

### Automation Setup

1. Visit [Chainlink Automation](https://automation.chain.link/)
2. Register new upkeep
3. Select "Custom logic" trigger
4. Set `RaffleManager` address
5. Fund upkeep with LINK

## Supported Networks

| Network | Chain ID | VRF Coordinator | Status |
|---------|----------|----------------|--------|
| Base Sepolia | 84532 | `0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE` | ✅ Tested |
| Base Mainnet | 8453 | `0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634` | 🔄 Ready |
| Ethereum Sepolia | 11155111 | `0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B` | 🔄 Ready |

## Useful Commands

### Foundry

```bash
# Build contracts
forge build

# Run tests
forge test

# Format code
forge fmt

# Gas snapshots
forge snapshot

# Local testnet
anvil

# Deploy script
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast

# Verify contract
forge verify-contract <address> RaffleManager --chain-id 84532

# Get contract ABI
forge inspect RaffleManager abi > RaffleManager.json
```

### Cast (Contract Interaction)

```bash
# Check raffle data
cast call <contract> "raffles(uint256)" <raffleId> --rpc-url $RPC_URL

# Get participant count
cast call <contract> "participants(uint256)" <raffleId> --rpc-url $RPC_URL

# Manual upkeep trigger
cast send <contract> "performUpkeep(bytes)" <performData> --private-key $PRIVATE_KEY --rpc-url $RPC_URL
```

## License

MIT License - see [LICENSE](LICENSE) file for details

## Resources

- [Foundry Book](https://book.getfoundry.sh/)
- [Chainlink VRF v2.5 Docs](https://docs.chain.link/vrf)
- [Chainlink Automation Docs](https://docs.chain.link/chainlink-automation)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [Base Network Docs](https://docs.base.org/)

## Contributing

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Run tests (`forge test`)
4. Commit changes (`git commit -m 'Add amazing feature'`)
5. Push to branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## Support

For questions and support:
- Open an issue on GitHub
- Review the specification documents in this repo
- Check the Foundry documentation

---

**Built with ❤️ using [Foundry](https://getfoundry.sh/)** | Powered by [Chainlink](https://chain.link/)
