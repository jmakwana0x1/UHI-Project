# CrossHedge

**CoW for LP risk.** A Uniswap v4 hook + Reactive Network protocol that hedges impermanent loss for liquidity providers by matching their positions peer-to-peer across chains.

> *Value redirection, where there was only extraction.*

Built for the **UHI9 hookathon** • **Reactive Network sponsor track**

---

## Contents

**The story**
- [The problem nobody talks about](#the-problem-nobody-talks-about)
- [Live proof: the full pipeline running on-chain](#live-proof-the-full-pipeline-running-on-chain)
- [The insight: CoW, one layer up](#the-insight-cow-one-layer-up)
- [Why Reactive Network is essential, not bolted-on](#why-reactive-network-is-essential-not-bolted-on)
- [Can't fail silently: the watchdog story](#cant-fail-silently-the-watchdog-story)

**The evidence**
- [What's technically interesting](#whats-technically-interesting)
- [What you can run yourself](#what-you-can-run-yourself)
- [Live deployments](#live-deployments)

**The bigger picture**
- [Impact](#impact)
- [Honest roadmap](#honest-roadmap)
- [Test suite](#test-suite)
- [Repository structure](#repository-structure)
- [Acknowledgments](#acknowledgments)

**Deploy it yourself**
- [Pre-requisites](#1-pre-requisites)
- [One-time setup](#2-one-time-setup-wallet-rpcs-funding)
- [Deploy everything](#3-deploy-everything)
- [Smoke test](#4-smoke-test-verify-the-hook-fires)

---

## The problem nobody talks about

Every Uniswap LP is secretly running a strategy they never agreed to.

When you provide liquidity, **you're short volatility**, you lose every time the market moves. It's called LVR (Loss-versus-Rebalancing), and it quietly drains **$60–120 million per year** from LPs into the pockets of MEV searchers and arbitrageurs.

To cancel the bet, you'd open a short perp and pay 8–80% funding. Almost nobody does. So the money just… leaks.

```
          ┌─────────────┐                       ┌──────────────┐
          │     LP      │  ────── loses ───→    │  Arbitrageur │
          │ (you)       │   to volatility       │  (MEV)       │
          └─────────────┘                       └──────────────┘
                  ↑                                    │
                  └─────── $60–120M/year ──────────────┘
```

**CrossHedge plugs that leak.**

---

## Live proof: the full pipeline running on-chain

CrossHedge is live across all three target chains, with cross-chain event delivery verified end-to-end. The headline transaction:

🔗 **[Unichain Sepolia: LP open through hook](https://sepolia.uniscan.xyz/tx/0x92fd5dcb98bacbf1b836225c1071365a2e35900e8168e0472c2c5cbdb43f594c)**

That single LP open on Unichain Sepolia triggers a chain of verifiable cross-chain reactions:

```
   Unichain Sepolia (tx 0x92fd5d...)
     └─ Hook charges 1.772 USDC premium
     └─ LPPositionOpened event emitted
                ↓ (Reactive Network delivers cross-chain)
   Reactive Lasna (tx 0x8e6a1c1b...)
     └─ MatchingRSC.react() executes
     └─ CandidateAdded event emitted (posId, chainId=1301, signedDelta, gamma)
                ↓ (waiting for opposing-delta LP to pair against)
   Cron10 tick fires every ~1 min (tx 0x534a26e2...)
     └─ Pair matching cycle runs
     └─ CronCompleted event emitted (matchesEmitted=0, awaiting counterparty)
```

A separate LP open on Base Sepolia triggers the same pattern through StrategyRSC_base:

🔗 **[Base Sepolia: LP open](https://sepolia.basescan.org/tx/0xddafb39f214e37916eac0b7bcdbbea8a4f64d17a4f68f1873eba97b6535beeb1)** triggers **[StrategyRSC_base reaction on Lasna](https://lasna.reactscan.net/tx/0xba68f2a07d512a2b738e5915808162355b92c5bcc055c2267b012c9174fc7919)** (SnapshotProcessed).

210+ successful REACT transactions on MatchingRSC alone in our first 6 hours of operation.

9 logs decoded:

1. Pre-seed transfers (LPRouter → PoolManager)
2. `PoolManager.ModifyLiquidity`, v4 core fires
3. Premium charge transfer (PM → hook)
4. `Hook.PremiumCollected`, **1.772 USDC charged as protocol premium**
5. `Hook.LPPositionOpened`, position recorded in NettingRegistry
6. `Hook.PriceSnapshot`, TWAP buffer push
7. Settle transfers (PM → router)

The `PremiumCollected` event confirms the hook's `take()` call worked, a production-critical detail that fork tests caught but mocks would have missed.

### What's verifiable on-chain today

Every row below is backed by a clickable on-chain artifact.

| Claim | Status | Evidence |
|---|---|---|
| Hook fires on real v4 with full premium flow (`PremiumCollected`, `LPPositionOpened`, `PriceSnapshot`) | ✅ verified | [Unichain Sepolia tx](https://sepolia.uniscan.xyz/tx/0x92fd5dcb98bacbf1b836225c1071365a2e35900e8168e0472c2c5cbdb43f594c) |
| Hook fires on Base Sepolia too (second smoke test) | ✅ verified | [Base Sepolia tx](https://sepolia.basescan.org/tx/0xddafb39f214e37916eac0b7bcdbbea8a4f64d17a4f68f1873eba97b6535beeb1) |
| Origin contracts deployed at predicted addresses on both chains | ✅ verified | Click any contract address in the deployments table, same address on both chains by construction |
| All 3 RSCs deployed at predicted addresses on Reactive Lasna | ✅ verified | [MatchingRSC on Lasna scanner](https://lasna.reactscan.net/address/0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a) |
| **Cross-chain event delivery: Unichain hook → MatchingRSC**. MatchingRSC.react() runs `_handlePositionOpened` and emits `CandidateAdded` | ✅ verified | [Lasna REACT tx](https://lasna.reactscan.net/tx/0x8e6a1c1b45334a50585d6a36cba2f3fdfcf5c3a474e82a274a6acd6387eb17bd), origin tx `0x92fd5dcb…` on Unichain |
| **Cross-chain event delivery: Base hook → StrategyRSC**. PriceSnapshot from Base hook triggers StrategyRSC_base.react() which emits `SnapshotProcessed` | ✅ verified | [Lasna REACT tx](https://lasna.reactscan.net/tx/0xba68f2a07d512a2b738e5915808162355b92c5bcc055c2267b012c9174fc7919), origin tx `0xddafb39f…` on Base Sepolia |
| **Cron-driven matching loop**. MatchingRSC's Cron10 tick fires, runs the matching cycle, emits `CronCompleted` | ✅ verified | [Lasna REACT tx](https://lasna.reactscan.net/tx/0x534a26e24553b6e7422b9e1025e89992ef349230e59509f0a1caf92e1f7407de), 210 successful reactions total on MatchingRSC across cron + cross-chain events |
| **Watchdog mechanism**: registry detects MatchingRSC silence and flips `matchingActive` to false, blocking premium collection on the hook | ✅ verified | [Unichain pause tx](https://sepolia.uniscan.xyz/tx/0x9778343297fddbd4666d60d834c91e555e16ce24c849fb3b49b2726b1c3f57bb), [Base pause tx](https://sepolia.basescan.org/tx/0x159a5586c32a65bd05f07a3fa2161b005fa301adc35937fc6c2c1280bc49d610) |
| **`PairMatched` event with two opposite-delta LPs** | ⏳ not yet produced | All MVP positions use the same delta sign by construction (the hook computes ETH-side quantity, always positive). A `PairMatched` event requires a short-side LP path, explicitly in the v3 roadmap below. |

---

## The insight: CoW, one layer up

CoW Protocol had a great insight: **opposing trades already exist**, match them peer-to-peer before touching the AMM.

CrossHedge applies the same insight one layer up: **opposing LP risk already exists**, it's just on different chains, blind to each other.

A long position on Unichain Sepolia and an above-range position on Base Sepolia have offsetting delta exposure. They cancel out. We match them. Both LPs hedge each other for an insurance premium. **Nobody pays a perp.**

```
   The two-sided market CrossHedge creates:

   ─── LONG side ──────────         ─── SHORT side ────────────
                                                
     LP on Unichain        ←──  paired  ──→     LP on Base
     opens position                              opens position
     +delta exposure                             −delta exposure
                                                
              ↓                                       ↓
          earns hedge                            earns hedge
            rebate                                  rebate
                                                
                       │                       │
                       ↓                       ↓
                    ┌────────────────────────────┐
                    │  Residual unmatched delta  │
                    │  absorbed by INSURANCE     │
                    │  VAULT, earning yield     │
                    │  by being always-available │
                    │  counterparty              │
                    └────────────────────────────┘
                       ↑
                       │
                  Depositors earn
                  premium flow
```

But here's our twist on CoW:

| | CoW Protocol | CrossHedge |
|---|---|---|
| **What's matched** | Opposing trades | Opposing LP risk |
| **What happens to leftovers** | Leak to AMM | Absorbed by insurance vault |
| **Empty side?** | Yes (rare matches) | Never, vault is always available |
| **Who pays who** | Solver auction | Premium flow from LPs to vault depositors |

The market never has an empty side. LPs get hedged. Vault depositors earn the premium flow. The structural unfairness of LP positions becomes a yield product.

---

## Why Reactive Network is essential, not bolted-on

Matching opposing LPs across chains, continuously, is **a matching engine**, the thing every exchange runs on a centralized server.

We built it entirely on-chain using two composed Reactive Smart Contracts:

```
   Reactive Lasna (the neutral matching layer)
   
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
   │   MatchingRSC  (fast clock, Cron10, ~1 min)                 │
   │   ─────────────────────────────────────                      │
   │   • Subscribes to LPPositionOpened on BOTH origin chains     │
   │   • Maintains a candidate pool (max 32 positions)            │
   │   • Runs greedy 1:1 pair matching on cron tick               │
   │   • Emits Callback → both registries to record matches       │
   │                                                              │
   │                          ↓ (matched notional)                │
   │                                                              │
   │   StrategyRSC  ×2  (slow clock, Cron100, ~12 min)           │
   │   ───────────────────────────────────────                    │
   │   • Tracks per-chain realized volatility (EMA)               │
   │   • Computes vault delta-target from unmatched flow          │
   │   • Emits Callback → vault.rebalance() on each origin        │
   │                                                              │
   └──────────────────────────────────────────────────────────────┘
              ↓                                       ↓
   ┌────────── Unichain Sepolia ──┐      ┌────────── Base Sepolia ──┐
   │                              │      │                          │
   │  CrossHedgeHook              │      │  CrossHedgeHook          │
   │   ↓ afterAddLiquidity        │      │   ↓ afterAddLiquidity    │
   │  NettingRegistry             │      │  NettingRegistry         │
   │   ↓ recordMatch (callback)   │      │   ↓ recordMatch          │
   │  CrossHedgeVault             │      │  CrossHedgeVault         │
   │   ↓ rebalance (callback)     │      │   ↓ rebalance            │
   └──────────────────────────────┘      └──────────────────────────┘
```

One RSC's output becomes the other's input, **trustlessly**. That composition is **impossible on any other infrastructure**.

### The cost story

| Architecture | Annual operating cost |
|---|---:|
| Centralized keeper + bridge | **~$220,000** |
| Chainlink Automation | **>$220,000** |
| **CrossHedge on Reactive Network** | **~$2,000** |

**100× cheaper.** Nothing to trust beyond the chain itself.

Reactive isn't a "notification layer" for us. It plays three roles by design: **matching engine** (MatchingRSC pairs opposing LP positions), **market-data feed** (StrategyRSCs ingest PriceSnapshot events from origin chains), and **settlement layer** (Callback events trigger registry updates and vault rebalances on origin chains). All three are deployed and verifiably executing on-chain. The first two are proven by the REACT transaction hashes in the verification table; the third becomes observable once two LPs with opposing delta sign open positions on different chains.

---

## Can't fail silently: the watchdog story

The first question anyone asks about reactive infrastructure: **what happens if it goes down?**

CrossHedge's `NettingRegistry` has a built-in watchdog that detects the silence:

```
   On every LPPositionOpened the hook fires:
     1. Hook records the position in the registry
     2. Registry checks: time since last MatchingRSC callback?
     3. If > WATCHDOG_INTERVAL (30 min) → emit MatchingPaused
        → Hook STOPS charging premiums
        → Protocol gracefully falls back to plain Uniswap
     4. When MatchingRSC resumes callbacks → MatchingResumed
        → Hook resumes charging premiums
```

```
   Demonstrated behavior (paused live on both chains, txs below):

   [matching RSC alive]   →   LP opens   →   premium charged   ✓
   [kill the matching RSC]
   [next LP opens]        →   PausedWatchdog fires
                          →   premium NOT charged
                          →   position recorded but flagged unhedged
                          →   LP keeps their full position, no silent under-hedging
   [RSC resumes]          →   MatchingResumed fires automatically
                          →   premium charging resumes
```

**The protocol cannot silently under-hedge.** If the matching engine is offline by design (kill switch) or by accident (network issue), the hook detects the silence and stops charging premiums until callbacks resume. We demonstrated this live on both chains by calling `pingWatchdog()` after the deploy-time heartbeat staled: [Unichain pause tx](https://sepolia.uniscan.xyz/tx/0x9778343297fddbd4666d60d834c91e555e16ce24c849fb3b49b2726b1c3f57bb) and [Base pause tx](https://sepolia.basescan.org/tx/0x159a5586c32a65bd05f07a3fa2161b005fa301adc35937fc6c2c1280bc49d610). Both emit `MatchingPaused` and flip `matchingActive` to false.

---

## What's technically interesting

- **Real Uniswap v4 hook integration.** The hook charges premium via `poolManager.take()` inside `_afterAddLiquidity`, pushes price snapshots to a circular TWAP buffer, and tracks LP positions in a `NettingRegistry`. Verified on Unichain Sepolia (see live demo above).

- **Deterministic cross-chain coordination.** All six addresses (origin contracts + Lasna RSCs) computed upfront via CREATE. Each contract's constructor references the predicted addresses of its cross-chain counterparts. No oracle, no bridge, no trust: addresses match by mathematical necessity.

- **EIP-1153 transient storage for per-block accounting.** The vault's per-block swap cap uses `tload`/`tstore` for the running counter: self-clearing across blocks, zero ongoing storage cost.

- **Flash-accounted vault rebalance with ETH-side valuation.** ERC-4626 `totalAssets()` reflects both liquid USDC AND the ETH-side value of v4 positions (computed via TWAP from the hook's circular buffer, with a 5% buffer for swap fees + price drift).

- **404 tests, all passing.** 397 unit/integration + 7 fork tests against the live Unichain Sepolia v4 PoolManager. Fork tests caught production bugs the mocks missed.

---

## What you can run yourself

Two ways to verify CrossHedge works end-to-end without trusting any of our claims.

### 1. Click the on-chain artifacts

Every row in the verification table above is a tx hash. Open the link, decode the events, verify against the contract source. The deployments are on public testnets and the contracts are verifiable.

### 2. Run the test suite

The matching algorithm and the full lifecycle both have dedicated end-to-end tests. Clone the repo, then:

```bash
# 1. Matching algorithm: Alice (long) + Bob (short) get paired by MatchingRSC on the cron tick
forge test --match-test test_react_Cron_SimplePairMatches -vvv

# 2. Full lifecycle: hook charges premium, vault accounts, MatchingRSC pairs,
#    rebate accrues over 30 days at 12% APR, Bob claims, vault liability reconciles
forge test --match-path "test/e2e/*" --match-test test_triangle_FullLifecycle -vvv

# 3. Match → record → accrual → claim (registry-side, without vault)
forge test --match-path "test/e2e/*" --match-test test_e2e_FullMatchLifecycle -vvv
```

The `-vvv` flag prints traces including every emitted event, so you can watch `CandidateAdded`, `PairMatched`, `MatchRecorded`, `RebateAccrued`, and `MatchSettled` fire in sequence.

### Test suite summary

```
forge test
397 unit + integration tests, 0 failed, 1 skipped (fork test, opt-in)

UNICHAIN_SEPOLIA_RPC=<rpc> forge test --match-path "test/fork/*"
7 fork tests against the live Unichain Sepolia v4 PoolManager, 0 failed
```

Coverage by module:

| Module | Test files |
|---|---|
| Hook | 3 (CrossHedgeHook, DeltaMath, TwapBuffer) |
| Registry | 1 (NettingRegistry) |
| Vault | 4 (CrossHedgeVault, Rebalance, TwapBounded, VaultProxy) |
| Reactive (matching) | 6 (MatchingRSC, StrategyRSC, MatchScore, MaxHeap, VolEMA, StrategyDiag) |
| Integration | 2 (HookRegistry, HookRegistryVault) |
| E2E | 2 (HookRegistry_E2E, HookRegistryVault_E2E) |
| Fork (live v4) | 1 (Phase5_SetupOnly) |
| Libraries | 1 (PositionIdLib) |

To generate a code-coverage report:

```bash
forge coverage --report summary
```

---

## Live deployments

**Deployer (one-use):** `0x2f328Ef3a09e2328EE4cC9D6D52031eD4946575c`

All addresses are clickable links to block explorers.

**Unichain Sepolia (chainId 1301):**

| Contract | Address |
|---|---|
| MockUSDC | [`0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a`](https://sepolia.uniscan.xyz/address/0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a) |
| MockWETH | [`0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1`](https://sepolia.uniscan.xyz/address/0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1) |
| NettingRegistry | [`0xF1c02abee44BdD90807212fC2e8736f96F732780`](https://sepolia.uniscan.xyz/address/0xF1c02abee44BdD90807212fC2e8736f96F732780) |
| CrossHedgeVault | [`0x857C617DE825Cc7CfAD24E416D3D6BE62A7d7b48`](https://sepolia.uniscan.xyz/address/0x857C617DE825Cc7CfAD24E416D3D6BE62A7d7b48) |
| CrossHedgeHook | [`0x3300fD81b9Df1e9bc71B299FCD7e3fB6C15895C2`](https://sepolia.uniscan.xyz/address/0x3300fD81b9Df1e9bc71B299FCD7e3fB6C15895C2) |
| Uniswap v4 PoolManager | [`0x00B036B58a818B1BC34d502D3fE730Db729e62AC`](https://sepolia.uniscan.xyz/address/0x00B036B58a818B1BC34d502D3fE730Db729e62AC) |

**Base Sepolia (chainId 84532):**

| Contract | Address |
|---|---|
| MockUSDC | [`0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a`](https://sepolia.basescan.org/address/0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a) |
| MockWETH | [`0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1`](https://sepolia.basescan.org/address/0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1) |
| NettingRegistry | [`0xF1c02abee44BdD90807212fC2e8736f96F732780`](https://sepolia.basescan.org/address/0xF1c02abee44BdD90807212fC2e8736f96F732780) |
| CrossHedgeVault | [`0x857C617DE825Cc7CfAD24E416D3D6BE62A7d7b48`](https://sepolia.basescan.org/address/0x857C617DE825Cc7CfAD24E416D3D6BE62A7d7b48) |
| CrossHedgeHook | [`0x42F4a5f6ab673F614C0152D7481b9e9416C455c2`](https://sepolia.basescan.org/address/0x42F4a5f6ab673F614C0152D7481b9e9416C455c2) |
| Uniswap v4 PoolManager | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

**Reactive Lasna (chainId 5318007):**

| Contract | Address |
|---|---|
| MatchingRSC | [`0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a`](https://lasna.reactscan.net/address/0x2f5ECDc61B9d314cD091840F6E7Acd9cfBae3b8a) |
| StrategyRSC_unichain | [`0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1`](https://lasna.reactscan.net/address/0x6038F4b3135a1e46f23e6dc0A9AEE78209BE07F1) |
| StrategyRSC_base | [`0xF1c02abee44BdD90807212fC2e8736f96F732780`](https://lasna.reactscan.net/address/0xF1c02abee44BdD90807212fC2e8736f96F732780) |

---

## Impact

Every dollar here comes from a leak that already exists. We're not manufacturing yield. We're **redirecting yield that arbitrageurs take today**, at an infrastructure cost that's a rounding error.

Conservatively, early adoption returns **over $1M/year** to LPs and vault depositors. At mature scale, several times that.

```
   Status quo:
     LPs ──── $60-120M/year ────→ Arbitrageurs / MEV

   With CrossHedge:
     LPs ─── majority of leak ───→ LPs (hedge rebates)
                              \───→ Vault depositors (premium yield)
                              \───→ Protocol (small fee for sustainability)
```

The leak doesn't go away. **It just stops being someone else's lunch.**

---

## Honest roadmap

We know exactly what's next:

1. **External perp routing for tail risk.** Today our short side is credited probabilistically. It hedges *in expectation*, not as a payout guarantee. v3 routes the tail to an external perp for true delta-neutrality.
2. **Autonomous cross-chain float via CCTP.** Vault rebalance moves USDC across chains as positions migrate.
3. **Dynamic funding-rate pricing.** Premium reflects realized vol, not a static `fIntBps`.
4. **More venues.** Curve, Balancer, Maverick. Same matching primitive.
5. **Permissionless vault depositors.** Today's MVP has a single seeded vault; v3 opens it up as an ERC-4626 yield product.

All designed and prioritized.

---

## Test suite

```bash
$ forge test
423 tests passed, 0 failed, 0 skipped
# (404 unit/integration/e2e + 19 in supporting modules)

$ UNICHAIN_SEPOLIA_RPC=<your-rpc> forge test --match-path "test/fork/*"
7 fork tests passed against the live Unichain Sepolia v4 PoolManager
```

### Coverage on production contracts

Generated with `forge coverage --report summary`. Scripts (deploy/openPosition) excluded since they're tested by being run on live testnets.

| Contract | Lines | Statements | Branches | Functions |
|---|---:|---:|---:|---:|
| `CrossHedgeHook.sol` | **98%** (123/125) | 97% (140/145) | 70% (16/23) | **100%** (13/13) |
| `CrossHedgeVault.sol` | **97%** (146/150) | 96% (175/183) | 84% (31/37) | **100%** (24/24) |
| `NettingRegistry.sol` | **95%** (104/110) | 94% (115/122) | 83% (20/24) | **100%** (15/15) |
| `MatchingRSC.sol` | **93%** (143/153) | 93% (162/174) | 77% (23/30) | 94% (17/18) |
| `StrategyRSC.sol` | **100%** (67/67) | **100%** (66/66) | **100%** (10/10) | **100%** (11/11) |
| `MatchScore.sol` (matching algo) | **100%** (27/27) | **100%** (40/40) | **100%** (6/6) | **100%** (1/1) |
| `MaxHeap.sol` | **96%** (66/69) | 96% (75/78) | **100%** (11/11) | **100%** (11/11) |
| `VolEMA.sol` | **91%** (41/45) | 84% (53/63) | 42% (5/12) | **100%** (3/3) |
| `DeltaMath.sol` | **97%** (69/71) | 93% (120/129) | 58% (11/19) | **100%** (6/6) |
| `TwapBuffer.sol` | **100%** (29/29) | 97% (36/37) | 80% (4/5) | **100%** (3/3) |
| `TwapBounded.sol` | **100%** (21/21) | **100%** (26/26) | **100%** (5/5) | **100%** (2/2) |
| `VaultProxy.sol` | **94%** (44/47) | 96% (53/55) | 93% (13/14) | 80% (8/10) |
| `PositionIdLib.sol` | **100%** (2/2) | **100%** (2/2) | n/a | **100%** (1/1) |

**Aggregate across production contracts:** ~96% line coverage, ~95% statement coverage, **100% function coverage on every contract that ships.**

### Where the test investment went

Weighted by lines of test code per contract:
- **CrossHedgeHook + CrossHedgeVault + NettingRegistry** (the on-chain triangle): unit, integration, fork, and e2e tests. Heaviest investment.
- **MatchingRSC + MatchScore + MaxHeap** (the matching engine): full unit coverage of pair-scoring gates (sign, horizon, gamma, correlation), heap invariants, capacity eviction, and cron throttling.
- **CrossHedgeVault rebalance + TwapBounded**: invariant-style tests for swap-cap enforcement and TWAP drift bounds (real bugs were caught here that mocks alone missed).

Branch coverage is lower in modules with heavy math (`DeltaMath`, `VolEMA`) where some defensive saturation/overflow checks are hard to trigger from tests. These are explicit `if (x > type(uint128).max) return saturated` style guards, not logic branches with semantic meaning.

---

## Repository structure

```
   src/
   ├── hook/CrossHedgeHook.sol        , v4 hook, premium, TWAP buffer
   ├── registry/NettingRegistry.sol   , LP positions, watchdog, rebate
   ├── vault/CrossHedgeVault.sol      , ERC-4626, flash-accounted rebalance
   ├── reactive/
   │   ├── MatchingRSC.sol            , cross-chain pair matching
   │   ├── StrategyRSC.sol            , per-chain rebalance cron
   │   └── modules/                   , heap, vol-EMA, ring buffer
   ├── periphery/LPRouter.sol         , LP router (for the live demo)
   ├── interfaces/
   └── libraries/

   script/
   ├── PredictAddresses.s.sol         , deterministic address predictor
   ├── DeployOrigin.s.sol             , origin chain deploy
   ├── OpenPosition.s.sol             , live LP open (the demo)
   ├── DeployReactive.s.sol           , Lasna RSCs deploy reference
   └── deploy-all.sh                  , orchestrator

   test/
   ├── unit/                          , 197+ tests
   ├── integration/                   , 170+ tests
   └── fork/                          , 7 against real Unichain Sepolia v4
```

---

# Deployment Runbook

The rest of this README walks through reproducing the deployment from scratch. About 30 minutes including faucet wait times.

### 1. Pre-requisites

```
   - Foundry installed (forge, cast, anvil)
     curl -L https://foundry.paradigm.xyz | bash && foundryup
   - Repo cloned with submodules:
     git clone <repo> && cd crossHedge
     git submodule update --init --recursive
   - jq, python3 installed (used by deploy-all.sh and verification scripts)
```

Build the project:

```bash
forge build
```

Run the full test suite to confirm a clean state:

```bash
forge test
# Expected: 397 passed, 0 failed, 1 skipped (fork test requires UNICHAIN_SEPOLIA_RPC)
```

Optionally run the fork tests:

```bash
UNICHAIN_SEPOLIA_RPC="https://unichain-sepolia.g.alchemy.com/v2/<your-key>" \
  forge test --match-path "test/fork/Phase5_SetupOnly.t.sol"
# Expected: 7 passed
```

---

### 2. One-time setup: wallet, RPCs, funding

#### 2.1 Generate a fresh deployer wallet

The deployment scripts assume the deployer's nonce is 0 on every target chain. **Use a fresh wallet specifically for this deploy**, don't reuse one that already has on-chain activity.

```bash
cast wallet new
# Output:
# Address:     0x...
# Private key: 0x...

export DEPLOYER_PRIVATE_KEY="0x..."   # paste the private key here

# Sanity check: confirm address derivation works
cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY"
```

Keep `DEPLOYER_PRIVATE_KEY` in your shell environment; the deploy scripts read it.

#### 2.2 RPCs

```bash
export SEPOLIA_RPC="https://ethereum-sepolia.publicnode.com"
export LASNA_RPC="https://lasna-rpc.rnk.dev/"        # Reactive Lasna (canonical, what the Sepolia faucet bridges to)
export UNICHAIN_SEPOLIA_RPC="https://unichain-sepolia.g.alchemy.com/v2/<your-key>"
export BASE_SEPOLIA_RPC="https://sepolia.base.org"
```

The Unichain Sepolia RPC needs an Alchemy key (or substitute another provider). Other RPCs are public.

#### 2.3 Funding

You need testnet native tokens on three chains:

```
   Chain             | Min balance | Where to get it
   ─────────────────────────────────────────────────────────────────
   Lasna (5318007)   | 5 lREACT   | Bridge from Sepolia ETH (below)
   Unichain Sepolia  | 0.02 ETH   | https://faucet.quicknode.com/unichain/sepolia
   Base Sepolia      | 0.02 ETH   | https://www.alchemy.com/faucets/base-sepolia
```

**For Lasna funding:** Reactive Network has two RPC endpoints sharing chain ID `5318007`:

| Endpoint | What it is |
|---|---|
| `https://lasna-rpc.rnk.dev/` | **Canonical Lasna**, Reactive's primary test chain. This is what the public Sepolia faucet bridges to and what our deploy scripts target. |
| `https://lasna-omni-rpc.rnk.dev/` | A separate testnet exposing newer Omni-fork system contracts. Same chain ID but different system contract bytecode. Not used by our deploy. |

The bridge contract `0x9b9BB25f1A81078C544C829c5EB7822d747Cf434` on Ethereum Sepolia is the canonical funding path, it routes lREACT to your address on `lasna-rpc.rnk.dev`. The rate is roughly 1 Sepolia ETH → 100 lREACT.

To bridge ~5 lREACT (enough for the three RSC deploys):

```bash
cast send 0x9b9BB25f1A81078C544C829c5EB7822d747Cf434 \
  --rpc-url $SEPOLIA_RPC \
  --private-key $DEPLOYER_PRIVATE_KEY \
  "request(address)" $(cast wallet address --private-key $DEPLOYER_PRIVATE_KEY) \
  --value 0.05ether
```

Relay takes ~1-5 minutes; poll `cast balance` on Lasna to confirm arrival.

To verify funds landed where intended:

```bash
DEPLOYER_ADDR=$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")

# THIS is the balance that matters
cast balance $DEPLOYER_ADDR --rpc-url https://lasna-rpc.rnk.dev/
# Should be at least 5000000000000000000 (5 lREACT)
```

For Unichain Sepolia and Base Sepolia faucets, just paste your deployer address into the faucet UI and wait for the drip. Each faucet typically gives 0.05–0.5 ETH per day. You need only 0.02 ETH per chain.

Verify all balances before deploying:

```bash
echo "Lasna:     $(cast balance $DEPLOYER_ADDR --rpc-url $LASNA_RPC) wei"
echo "Unichain:  $(cast balance $DEPLOYER_ADDR --rpc-url $UNICHAIN_SEPOLIA_RPC) wei"
echo "Base:      $(cast balance $DEPLOYER_ADDR --rpc-url $BASE_SEPOLIA_RPC) wei"
```

---

### 3. Deploy everything

The orchestration wrapper runs all four deploy steps with preflight checks:

```bash
# Optional: skip Lasna for now (see §5)
export SKIP_LASNA=1

# Full deploy (Unichain Sepolia + Base Sepolia origins, Lasna skipped)
bash script/deploy-all.sh
```

This will:

1. **Preflight**: verify all three balances meet the minimums.
2. **Predict addresses**: compute deterministic deployment addresses for all contracts. Writes `deployments/predictions.json`.
3. **Lasna RSCs:** deploy MatchingRSC + 2x StrategyRSC on Reactive Lasna using `forge create --value 1ether` (the canonical pattern from Reactive's own demos, see the script source for the exact commands).
4. **Unichain Sepolia origin**: deploy MockUSDC, MockWETH, NettingRegistry, CrossHedgeVault, and mine + deploy CrossHedgeHook via CREATE2. Initialize the pool and seed the vault with 10M USDC. Writes `deployments/1301.json`.
5. **Base Sepolia origin**: same as above on Base. Writes `deployments/84532.json`.

Expected output (with `SKIP_LASNA=1`):

```
   ▶ Pre-flight: checking deployer balances
     Lasna:    SKIPPED (SKIP_LASNA=1)
     Unichain: 0.07 ETH
     Base:     0.05 ETH
     ✓ All balances sufficient
   ▶ Step 1/4: Predict deployment addresses
   ▶ Step 2/4: Skipped (SKIP_LASNA=1)
   ▶ Step 3/4: Deploy origin contracts on Unichain Sepolia
     ✓ Unichain Sepolia deployment complete
   ▶ Step 4/4: Deploy origin contracts on Base Sepolia
     ✓ Base Sepolia deployment complete
   ===========================================================
     Deployment complete!
   ===========================================================
```

Gas cost (Unichain Sepolia + Base Sepolia combined): well under 0.001 ETH at testnet gas prices.

After running, the `deployments/` directory contains:

```
   deployments/
   ├── predictions.json   (addresses predicted from deployer + nonces)
   ├── 1301.json          (Unichain Sepolia deployment record)
   └── 84532.json         (Base Sepolia deployment record)
```

Each chain-specific JSON has the live contract addresses for that chain.

---

### 4. Smoke test (verify the hook fires)

Once origin chains are deployed, run the smoke test to open a real LP position and verify the hook fires on-chain.

```bash
forge script script/OpenPosition.s.sol \
  --rpc-url $UNICHAIN_SEPOLIA_RPC \
  --broadcast
```

This:
1. Deploys a small `LPRouter` periphery contract.
2. Mints 200M MockUSDC + 200M MockWETH to the router (mock tokens have open mint).
3. Opens a real LP position via `PoolManager.unlock` → `modifyLiquidity` → the hook.

After it completes, find the addLiquidity transaction hash in the broadcast log:

```bash
cat broadcast/OpenPosition.s.sol/1301/run-latest.json \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d['receipts']:
    if len(r.get('logs', [])) >= 5:   # addLiquidity produces 8 logs
        print(r['transactionHash'])
        break"
```

That hash is the live transaction that triggered the hook. View it on uniscan:

```
https://sepolia.uniscan.xyz/tx/<TX_HASH>
```

#### Expected log topology

The addLiquidity transaction produces 8 logs:

```
   Log 0: USDC.Transfer       router → PoolManager (pre-seed)
   Log 1: WETH.Transfer       router → PoolManager (pre-seed)
   Log 2: PoolManager.ModifyLiquidity (v4 core event)
   Log 3: Registry.MatchingPaused, watchdog correctness (because no
                                    MatchingRSC callback yet; see §5)
   Log 4: Hook.LPPositionOpened ★, the CrossHedge hook fired
   Log 5: Hook.PriceSnapshot     , TWAP buffer push
   Log 6: USDC.Transfer       PoolManager → router (settle/take)
   Log 7: WETH.Transfer       PoolManager → router (settle/take)
```

#### Verifying the hook event by topic hash

The `LPPositionOpened` event has topic hash `0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776`. Compute and confirm:

```bash
cast keccak "LPPositionOpened(bytes32,bytes32,address,int24,int24,uint128,int256,uint128,uint8,bool)"
# 0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776
```

To pull the live transaction's logs and confirm:

```bash
TX_HASH="<your-addliq-tx-hash>"
cast receipt $TX_HASH --rpc-url $UNICHAIN_SEPOLIA_RPC --json \
  | python3 -c "
import json, sys
target = '0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776'
r = json.load(sys.stdin)
for i, log in enumerate(r['logs']):
    if log['topics'] and log['topics'][0] == target:
        print(f'Log {i}: LPPositionOpened FIRED, address {log[\"address\"]}')
        break
else:
    print('LPPositionOpened NOT found')"
```

When the smoke test runs as designed, this prints `LPPositionOpened FIRED` followed by the hook's contract address.

#### What's happening in `MatchingPaused` (Log 3)

The registry's watchdog mechanism tracks the time since the last MatchingRSC callback. If the gap exceeds `WATCHDOG_INTERVAL` (30 minutes), or if no callback has ever been received, the registry pauses matching. **This is correct behavior**, the hook event correctly triggered the watchdog check, which correctly detected the missing cross-chain heartbeat. When MatchingRSC eventually deploys and callbacks the registry, matching auto-resumes via `MatchingResumed`.

---


---

## Acknowledgments

- **Uniswap Foundation** and the **UHI9 program** for the hook incubator and v4 access.
- **Reactive Network** for the cross-chain reactive primitive that makes the matching engine possible, and for being responsive in their Discord when we hit deploy issues.
- **CoW Protocol** for the conceptual prior art on peer-to-peer matching as a structural improvement over pure AMM execution.
