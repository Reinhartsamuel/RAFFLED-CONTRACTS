# Mock USDC Deployment Guide

This guide shows you how to deploy Mock USDC to Base Sepolia testnet and integrate it with your Raffled frontend.

## Overview

Instead of using the real USDC on Base Sepolia, you can deploy your own MockUSDC token for testing. This gives you:
- ✅ Unlimited supply to test with
- ✅ No need to request testnet USDC
- ✅ Easy minting for testing
- ✅ Full control over the token

## Option 1: Using the Provided DeployMockUSDC Script (Recommended)

### Step 1: Deploy MockUSDC to Base Sepolia

```bash
cd /Users/reinhartsulilatu/repos/raffled-contract

# Deploy to Base Sepolia testnet
forge script script/DeployMockUSDC.s.sol \
  --rpc-url https://base-sepolia.g.alchemy.com/v2/51MRDeFHeLtd5FrWrTMv0bsusLfs5n8r \
  --broadcast \
  -vvv
```

**Expected output:**
```
...
[Contract Creation] 0x... MockUSDC
...
```

The last address output is your MockUSDC contract address. Copy it!

### Step 2: Copy the Contract Address

Example format: `0x1234567890123456789012345678901234567890`

### Step 3: Update Frontend Configuration

Update your `.env` file in the Raffled-client:

```env
# Add this new variable
VITE_MOCK_USDC_ADDRESS_SEPOLIA=0x1234567890123456789012345678901234567890
```

### Step 4: Update CreateRaffleModal Default Token

Edit `src/components/evm/CreateRaffleModal.tsx`:

```typescript
// Find this line (around line 23):
const [prizeAsset, setPrizeAsset] = useState<Address>(getUSDCAddress(chainId))

// Replace with:
const mockUsdcAddress = import.meta.env.VITE_MOCK_USDC_ADDRESS_SEPOLIA as Address
const [prizeAsset, setPrizeAsset] = useState<Address>(mockUsdcAddress || getUSDCAddress(chainId))
```

### Step 5: Update Form Placeholder

In `CreateRaffleModal.tsx`, find the Prize Token input (around line 161):

```typescript
placeholder="0x036CbD53842c5426634e7929541eC2318f3dCF7e"

// Change to:
placeholder={mockUsdcAddress || "0x036CbD53842c5426634e7929541eC2318f3dCF7e"}
```

### Step 6: Update Form Helper Text

Also update the small text below (around line 164):

```typescript
<small>Default: USDC on {chainId === 84532 ? 'Base Sepolia' : 'Base'}</small>

// Change to:
<small>Default: Mock USDC on {chainId === 84532 ? 'Base Sepolia' : 'Base'}</small>
```

## Option 2: Manually Deploy Without Script

If you prefer Forge directly without the script:

```bash
cd /Users/reinhartsulilatu/repos/raffled-contract

# Compile contracts first
forge build

# Deploy directly
forge create test/mocks/MockUSDC.sol:MockUSDC \
  --rpc-url https://base-sepolia.g.alchemy.com/v2/51MRDeFHeLtd5FrWrTMv0bsusLfs5n8r \
  --private-key 0x733a26696f28bf734bc106b3def0dc4dbd91e3fe577a59c01f3f3712f9181991 \
  --constructor-args 1000000000000 \
  -vvv
```

Constructor arg explanation: `1000000000000` = 1,000,000 USDC (with 6 decimals)

## Using MockUSDC in Your Frontend

### Step 1: Connect Your Wallet

1. Open http://localhost:5173 (or your dev server)
2. Click "Connect Wallet"
3. Select your wallet (MetaMask, WalletConnect, etc.)
4. **Switch to Base Sepolia network**

### Step 2: Get Mock USDC Tokens

You have three options:

#### Option A: Mint directly to yourself (if you have deployer key)
```bash
# In Foundry console
forge console --rpc-url https://base-sepolia.g.alchemy.com/v2/51MRDeFHeLtd5FrWrTMv0bsusLfs5n8r

# Then in console:
usdc = MockUSDC(address(0x...))  // Your deployed MockUSDC
usdc.mint(address(0x...yourAddress), 1000000000000)  // 1,000,000 USDC
```

#### Option B: Use Etherscan to call mint function
1. Go to [Base Sepolia Etherscan](https://sepolia.basescan.org/)
2. Search for your MockUSDC contract address
3. Go to "Contract" tab
4. Click "Write Contract"
5. Click "Connect Wallet" and connect with Etherscan
6. Call `mint(yourAddress, 1000000000000)`

#### Option C: Ask the deployer to send you tokens
The deployer (account that deployed the contract) has the initial supply.

### Step 3: Create a Raffle with MockUSDC

1. Navigate to the **Manage** tab in the app
2. Click **"Create Raffle"** button
3. The Prize Token field should show your MockUSDC address
4. Fill in the form:
   - **Prize Amount**: `10` (10 USDC)
   - **Payment Token**: `0x0000...0000` (ETH)
   - **Ticket Price**: `0.001` (0.001 ETH)
   - **Max Capacity**: `10`
   - **Duration**: `7` days
5. Click **"Create Raffle"**
6. You'll be prompted to approve MockUSDC tokens
7. Confirm both transactions in your wallet
8. Check the transaction receipt!

## Checking Your Balance

### In the Frontend Form
When you open the Create Raffle form, it shows your MockUSDC balance automatically (if you have tokens).

### On Etherscan
1. Go to [Base Sepolia Etherscan](https://sepolia.basescan.org/)
2. Search for your MockUSDC contract address
3. Go to "Read Contract" tab
4. Call `balanceOf(yourAddress)` to see your balance

### Using Cast (Foundry)
```bash
cast call 0x...mockUsdcAddress "balanceOf(address)" 0x...yourAddress \
  --rpc-url https://base-sepolia.g.alchemy.com/v2/51MRDeFHeLtd5FrWrTMv0bsusLfs5n8r
```

## MockUSDC Contract Details

### Constructor
```solidity
constructor(uint256 supply)
```
- `supply`: Initial token supply (6 decimals, so 1,000,000 USDC = 1000000000000)

### Key Functions
```solidity
// Check balance
function balanceOf(address a) external view returns (uint256)

// Transfer tokens
function transfer(address to, uint256 amount) external returns (bool)

// Approve token spending
function approve(address spender, uint256 amount) external returns (bool)

// Transfer from approved account
function transferFrom(address from, address to, uint256 amount) external returns (bool)

// Mint new tokens (only callable by deployer - see implementation)
function mint(address to, uint256 amount) external
```

### Token Properties
- **Name**: Mock USDC
- **Symbol**: USDC
- **Decimals**: 6
- **Initial Supply**: 1,000,000 USDC (configurable)

## Troubleshooting

### "MockUSDC not found" during deployment
```bash
# Make sure you're in the right directory
cd /Users/reinhartsulilatu/repos/raffled-contract

# Rebuild contracts
forge clean && forge build
```

### Deployment fails with RPC error
- Check your RPC_URL in `.env`
- Check you have enough ETH on deployer account
- Try running locally first: `forge script script/DeployMockUSDC.s.sol`

### Can't approve MockUSDC in frontend
1. Make sure you have MockUSDC tokens in your wallet
2. Make sure the contract address in `.env` is correct
3. Check the browser console for error messages (F12)

### Transaction says "Insufficient balance"
- You don't have enough MockUSDC tokens
- Use the methods above to mint more tokens to your address

### MockUSDC address not updating in frontend
- Clear browser cache: `Ctrl+Shift+Delete` or `Cmd+Shift+Delete`
- Restart dev server: Stop and run `npm run dev` again
- Verify `.env` has the correct address

## Comparing Real vs Mock USDC

| Feature | Real USDC | Mock USDC |
|---------|-----------|-----------|
| Supply | Limited | Unlimited (you control) |
| Decimals | 6 | 6 |
| Testnet Faucet | Need to request | Deploy yourself |
| Gas Cost | Standard | Standard |
| Compatible | Yes | Yes (same ERC-20 interface) |
| Permission | Issued by Circle | You control |

## Next Steps

1. **Deploy MockUSDC** using the script above
2. **Update frontend `.env`** with the deployed address
3. **Get MockUSDC tokens** using one of the methods above
4. **Test raffle creation** with MockUSDC as the prize
5. **Deploy to real USDC** when ready for production

## Script Locations

- **Deployment Script**: `/Users/reinhartsulilatu/repos/raffled-contract/script/DeployMockUSDC.s.sol`
- **MockUSDC Implementation**: `/Users/reinhartsulilatu/repos/raffled-contract/test/mocks/MockUSDC.sol`
- **Frontend Config**: `/Users/reinhartsulilatu/Repos/Raffled-client/.env`
- **Frontend Component**: `/Users/reinhartsulilatu/Repos/Raffled-client/src/components/evm/CreateRaffleModal.tsx`

## For Production

When you're ready to use real USDC:
1. Keep using the same contract address setup
2. Update `.env` to use the real USDC address
3. No other changes needed - same ERC-20 interface!

Real USDC on Base:
- Mainnet: `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`
- Sepolia: `0x036CbD53842c5426634e7929541eC2318f3dCF7e`
