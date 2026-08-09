# Base Weekly Rewards — Application Pack

**Program:** Base Builder Rewards ("Weekly Rewards") · 2 ETH distributed weekly to active builders
**Portal:** https://www.builderscore.xyz/ (powered by Talent Protocol — redirected to talent.app on visit)
**Source of criteria:** docs.base.org/get-started/get-funded (fetched 2026-08-06)

---

## 1. What the program actually is (read this first)

From the official docs — **it is NOT a one-time grant application.** It is an **activity/score system**:

> - Build anything on Base (prototypes welcome)
> - Share your progress on social media
> - Earn weekly rewards based on activity
> - No minimum project size required
> - "Prototyping counts! Early-stage projects and experiments are explicitly encouraged."
> - Perfect for: first-time Base builders, experimenting devs, weekend projects/hackathon submissions, educational content

**Implication for you:** the "application" is (a) a builder profile on builderscore.xyz, (b) shipping on Base, and (c) posting progress on socials (X/Farcaster). The weekly score is what earns the 2 ETH share. **Your weekly shipping log IS the application.**

---

## 2. Setup checklist (builderscore.xyz)

1. Visit https://www.builderscore.xyz/ and connect your wallet (Base network)
2. Link your X (Twitter) account — required for the social-activity scoring
3. Link your GitHub if the portal offers it
4. Complete the builder profile fields: name, bio, project, links
   *(exact field names vary — the portal is Talent Protocol-based; fill in what's there)*
5. Set your profile to public

**Fill-in placeholders (gather before you start):**
- Wallet address: `0x________` (the deployer wallet 0x753dfc03b4d37b3a316d0fe5ab9f677c0d3c20f8, or a dedicated builder wallet — your call)
- X handle: `@________`
- Farcaster: `________`
- Brand name (if renaming away from "Raffled" for the B2B pivot): `________`

---

## 3. Builder profile write-up (copy-paste ready)

> **Project:** Raffled — on-chain raffles with verifiable randomness, built on Base.
>
> **What it is:** A smart-contract platform (RaffledCore) that lets anyone create trustless raffles where prizes are locked on-chain and winners are picked by Chainlink VRF v2.5 — provably fair, zero custody. Supports ERC-20 and ERC-721 prizes, USDC ticket payments, EIP-712 signed free entries (verifiable allowlist raffles), and an underfill-protection design where hosts get their prize back if a raffle doesn't fill.
>
> **Progress so far:**
> - RaffledCore deployed and verified on **Base Sepolia** (`0xc17eee20B4990021bE9cc8eCB7833706465bb8b9`, block 42,699,846)
> - Chainlink VRF v2.5 + Chainlink Automation integrated (paginated upkeep)
> - Security-reviewed (Pashov AI report, June 2026) with all findings fixed (A0 patch: EIP-712 domain corrected, richer RaffleCreated event, permissionless `cancelExpiredRaffle` for stuck-VRF recovery)
> - Ponder indexer running — GraphQL API serving 20+ indexed raffles with leaderboards and win proofs
> - Frontend (React/Vite + Reown AppKit): raffle creation wizard, buy/claim flows, **public verify-fairness page** (shows VRF request → random word → winner derivation), and an iframe embed for hosts
> - Test raffles live on Sepolia with real prize flow end-to-end (create → enter → VRF → winner paid)
>
> **What's next:** deploy the audited RaffledCore to **Base mainnet**, launch the B2B product (raffle-as-a-service: projects run VRF-verified allowlist/whitelist raffles in 2 minutes), and publish the first mainnet case studies.
>
> **Why Base:** cheapest EVM L2 with the strongest consumer ecosystem; USDC-native; the whole stack (VRF, indexer, frontend) is already built on Base tooling.
>
> **Links:** deployed contract on Basescan (Sepolia), frontend at raffled.tuttilabs.xyz, public repo: github.com/reinhartsamuel/raffled-client

**Do NOT link the private contract repo** (`RAFFLED-CONTRACTS`) in a public profile — use the Basescan-verified contract link instead. It proves the code is on-chain without exposing your private repo.

---

## 4. Weekly shipping log (the actual "application")

Post once per week, every week. Format: **what shipped → proof → what's next.** Templates:

**Week A — Deploy/mainnet prep**
> Building on @base this week: audited RaffledCore ready for mainnet — Chainlink VRF v2.5 + Automation, ERC20/ERC721 prizes, USDC payments, EIP-712 free entries, underfill protection. Audit findings all fixed. Contract: [basescan link]. Next: mainnet deploy + first pilot raffles.

**Week B — Mainnet deploy**
> RaffledCore is LIVE on @base mainnet. [address]. First mainnet raffle: [link]. Winners picked by Chainlink VRF — verify any draw on the proof page: [link]. Next: onboarding 5 pilot projects.

**Week C — Pilot/usage**
> This week on Raffled: X raffles hosted by Y projects, Z tickets sold, first repeat host. Zero custody, VRF-verified, underfill-protected. If you run a community — raffle your next drop with us: [link].

**Week D — Builder Grant angle**
> Building @base public goods: open raffle infra any project can use. Indexer live, proof pages live, mainnet live. Applying for Base Builder Grants with shipped code, not promises. Feedback welcome: [link].

**Rules of thumb:**
- Include one concrete proof per post (tx link, address, screenshot, metric)
- Tag @base and use #BasedBuilder / #OnchainSummer-style tags (check current ones)
- Cross-post to Farcaster if you use it
- Consistency > polish — the program rewards activity

---

## 5. What's already done vs. your next actions

| Item | Status |
|---|---|
| Docs criteria verified | Done (this file) |
| Portal identified (builderscore.xyz / Talent Protocol) | Done |
| Builder profile filled in | You — wallet, X, GitHub links |
| Wallet address decided | You |
| Weekly post template | Done (above) |
| First shipping post | You — Week A template, this week |

---

## 6. Sequencing with the rest of the plan

1. **This week:** fill the builderscore.xyz profile + post Week A (mainnet-prep / audit-fixed story)
2. **Then:** mainnet deploy of A0 RaffledCore → Week B post with the tx link
3. **Then:** 5 pilot projects → Week C posts with metrics
4. **Day 60–90:** Base Builder Grants (the *other*, retroactive grant) — shipped code + usage data as evidence

The Weekly Rewards score compounds: every week you ship + post, your standing improves, and the same proof (mainnet tx, pilot metrics) is reused verbatim in the Builder Grants application later.
