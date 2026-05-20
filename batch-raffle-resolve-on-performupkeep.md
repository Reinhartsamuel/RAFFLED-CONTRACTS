Untitled-2
I don't understand how many checkupkeeps call will do in a particular time interval
Automation doesn't work on a fixed time interval per se. Here's the mental model:

How Automation actually works
Chainlink runs off-chain nodes that constantly simulate checkUpkeep against new blocks. On Base Sepolia, a new block arrives roughly every 2 seconds.


Every new block:
  node simulates checkUpkeep() off-chain
      → returns false? → do nothing, wait for next block
      → returns true?  → submit performUpkeep() on-chain
So it's per-block polling, not a timer.

Your scenario: 3 raffles expire simultaneously

Block 100: checkUpkeep → finds raffle 5 → performUpkeep(5) submitted
Block 101: checkUpkeep → finds raffle 7 → performUpkeep(7) submitted  
Block 102: checkUpkeep → finds raffle 23 → performUpkeep(23) submitted
~2 seconds apart each. For 100 expired raffles = ~200 seconds to resolve all.

Why batching matters
With the fix I showed, it becomes:


Block 100: checkUpkeep → finds [5, 7, 23] → performUpkeep([5,7,23]) submitted
Block 101: checkUpkeep → returns false → done
All resolved in one block.

Bottom line
Current code	Batched fix
1 expired raffle	1 block (~2s)	1 block
10 expired raffles	~10 blocks (~20s)	1 block
100 expired raffles	~200 blocks (~6 min)	1 block
For a raffle app where expiry precision matters, batching is worth doing.

is it gonna consume more LINK tokens?
Yes, but not proportionally — and batching is still cheaper overall.

Per-transaction costs
Current (one-at-a-time)	Batched
performUpkeep txs	10	1
Gas per tx (base overhead)	~50k × 10 = 500k	~50k × 1 = 50k
Gas for raffle logic	~X × 10	~X × 10 (same)
Total gas	higher	lower
LINK spent	more	less
Why batched is cheaper
Every transaction pays a fixed base overhead (calldata, tx inclusion, Automation registry cut) regardless of what it does. Batching amortizes that overhead across all raffles in one tx.

The raffle logic gas (VRF calls, transfers) is the same either way — you can't avoid it.

The one caveat
If batching too many raffles in one performUpkeep, you could hit the 500k gas limit you set. Each raffle's performUpkeep costs roughly 100–150k gas (VRF request alone is ~100k).

So realistically with 500k gas limit:

Safe batch size: ~3–4 raffles per tx
Beyond that: increase gas limit or do partial batches
For your current scale this isn't a concern yet.