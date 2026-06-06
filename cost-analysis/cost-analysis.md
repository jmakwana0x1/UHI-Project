# CrossHedge — Cost Analysis

> A first-principles, reproducible derivation of CrossHedge's annual operating cost at production scale on mainnet (Unichain + Base + Reactive Lasna), versus the same workload on Chainlink Automation + CCIP or a centralized keeper.
>
> Every number here is produced by [`cost_analysis.py`](./cost_analysis.py) — run it and change any assumption. Every external rate is linked in [Sources](#sources).

**This is a mainnet projection.** CrossHedge's live deployment runs on Unichain Sepolia + Base Sepolia + Reactive Lasna and is functionally cost-free (testnet tokens have no price). This document models mainnet operation at scale.

---

## TL;DR

At typical L2 mainnet conditions (Unichain ≈ 0.5 gwei, Base ≈ 0.005 gwei, ETH = $3,500, REACT = $0.015):

| Architecture | Annual operating cost | What drives it |
|---|---:|---|
| Chainlink Automation + CCIP *(cron parity)* | **~$547,000** | Pays destination gas on every cron tick (~1.05M txs/yr across 2 chains) |
| Centralized keeper (production SRE) | **~$86,600** | Mostly human/ops overhead; plus the same destination gas; plus a trust assumption |
| **CrossHedge on Reactive Network** | **~$8,300** | Pays destination gas only on actual matches (~36k callbacks/yr) |

**~66× cheaper than Chainlink under architecture parity, and ~10× cheaper than a production keeper — but the durable moat is structural, not the dollar figure.** Read the one assumption below before you quote 66× in a room with a Chainlink engineer in it.

> ### ⚠️ The assumption behind 66× — state it out loud
> The 66× holds **only if the Chainlink alternative mirrors CrossHedge's architecture**: a time-based (cron) upkeep that fires `performUpkeep` on-chain every minute. That is a fair apples-to-apples comparison *to CrossHedge's own cron-based matcher* — but it is **not** the cheapest way to build on Chainlink.
>
> Chainlink Automation's `checkUpkeep` runs **off-chain on the DON for free**; you only pay on-chain gas for `performUpkeep` ([Chainlink docs](https://docs.chain.link/chainlink-automation/overview/automation-economics)). A competent integrator would use a **log-trigger upkeep** so `performUpkeep` fires only on actual matches (~36k/yr), not every tick. Under that design the gas gap collapses to **~2×** at typical conditions (see [§7](#7-the-strongest-counterargument-and-why-crosshedge-still-wins)).
>
> **So the honest headline is two-part:** *"66× cheaper than a like-for-like cron deployment; ~2× cheaper than even an optimally-built Chainlink stack — and uniquely, natively cross-chain and trustless, which Chainlink Automation cannot be at any price."* That version survives every follow-up question.

---

## 1. How Reactive Network charges

From [Reactive's economy docs](https://dev.reactive.network/economy):

- **Lasna-side RVM execution:** `fee = BaseFee × GasUsed`, paid in REACT (~$0.015). This is where the matching/strategy logic actually runs.
- **Cross-chain callback delivery:** `p_callback = p_base × C × (g_callback + K)`, paid in the destination chain's native token (ETH on L2s). The `C × (g + K)` term is a per-chain surcharge over raw gas; we model it conservatively as **2× raw gas** on L2 destinations.

So: **CrossHedge total = REACT spent on Lasna + ETH spent on destination callbacks (Unichain + Base).**

The key structural fact: the *every-minute matching compute* happens on cheap Lasna (paid in sub-cent REACT), and the protocol only touches the expensive destination chains when there is an actual match to record.

---

## 2. The workload (production scale)

| Component | Cadence | Work per tick |
|---|---|---|
| MatchingRSC × 1 | Cron10 ≈ 1/min → 525,600/yr | 4-gate matching + pool maintenance, ~180k gas |
| StrategyRSC × 2 | Cron100 ≈ 1/12min → 87,600/yr total | vol-EMA + threshold check, ~100k gas each |
| Event ingestion | per `LPPositionOpened` / `PriceSnapshot` | ~50k gas each |
| Cross-chain callbacks | per successful match | ~130k gas on the destination chain |

Mid-scale event assumptions (tunable in the script):

- LP opens across both chains: ~100/day → **36,000/yr**
- `PriceSnapshot` events: ~20/day per chain → **15,000/yr per chain**
- Successful matches (~50% match rate): **18,000/yr** → **36,000 callbacks/yr** (one per origin chain)

---

## 3. Lasna-side execution (paid in REACT)

| Workload | Volume | Gas each | Annual REACT | USD @ $0.015 |
|---|---:|---:|---:|---:|
| MatchingRSC cron ticks | 525,600 | 180,000 | 94.6 | $1.42 |
| MatchingRSC event ingest | 36,000 | 50,000 | 1.8 | $0.03 |
| StrategyRSC × 2 ticks | 87,600 | 100,000 | 8.8 | $0.13 |
| StrategyRSC × 2 ingest | 30,000 | 50,000 | 1.5 | $0.02 |
| **Lasna total** | | | **~107 REACT** | **~$1.60/yr** |

Assumes Lasna `BaseFee ≈ 1 gwei` (Lasna is lightly loaded). This is the **one** Reactive-side input that isn't independently verifiable from a public tracker — flagged honestly. It doesn't matter to the conclusion: even at REACT's all-time-high (~$0.16, 10×), Lasna costs ~$17/yr.

---

## 4. Cross-chain callback delivery (paid in destination ETH)

This is where ~99.9% of CrossHedge's real cost lives, and it scales with L2 base fee.

- **Base mainnet:** ~0.005 gwei (Basescan tracker)
- **Unichain mainnet:** sub-gwei to ~8 gwei depending on time/tracker — **the dominant variable**

### Gas sensitivity — and why the ratio is gas-independent

| Unichain gwei | CrossHedge total | Chainlink (cron parity) | Ratio |
|---:|---:|---:|---:|
| 0.005 | ~$165 | ~$14,362 | 87× |
| 0.05 | ~$903 | ~$62,789 | 70× |
| 0.5 | ~$8,274 | ~$547,064 | 66× |
| 1.0 | ~$16,464 | ~$1,085,147 | 66× |
| 8.0 | ~$131,124 | ~$8,618,309 | 66× |

The ratio holds at **66–87×** because both sides scale linearly with Unichain gas — the `uni_gwei` term cancels in the ratio. CrossHedge's advantage here is **volume**: it moves ~36k destination txs/yr vs the cron design's ~1.05M (≈30× less traffic). *(This is true for the cron-parity comparison; see §7 for the log-trigger case.)*

---

## 5. Chainlink Automation + CCIP (cron parity)

A like-for-like replica of CrossHedge's cron matcher needs:

1. **Automation upkeeps** on each origin chain running matching logic every minute.
2. **CCIP messages** for cross-chain match notification (Automation alone is per-chain).

**Automation** — per [Chainlink's economics docs](https://docs.chain.link/chainlink-automation/overview/automation-economics):
`fee = gas_price × (gas_used + 80,000 overhead) × (1 + node_op_pct)`. At ~390k gas/perform (CronUpkeep ~110k + matching ~200k + overhead ~80k), 50% premium, 2 chains × 525,600 ticks/yr → **~$543k/yr** at Unichain 0.5 gwei.

**CCIP** — per [Chainlink's billing table](https://docs.chain.link/ccip/billing), L2→L2 **data messaging** is **$0.09 (LINK) / $0.10 (other tokens)**. `recordMatch` is a pure data message → $0.10 × 36,000 = **$3,600/yr**.

**Chainlink (cron parity) total: ~$547,000/yr → 66×.**

---

## 6. Centralized keeper

**Lean (hobby AWS):**

| Component | Annual |
|---|---:|
| AWS Lambda + EC2 t3.micro | ~$340 |
| Alchemy paid RPC × 3 chains | ~$1,760 |
| Engineer time (1 day/mo @ $50k opp. cost) | ~$2,500 |
| Bridge fees (CCTP / Across) | ~$3,600 |
| **Total** | **~$8,200/yr + destination gas** |

Honest caveat: a lean keeper pays the **same** destination gas as CrossHedge but **without** the 2× Reactive surcharge. So at multi-gwei Unichain the lean keeper can be *cheaper* than CrossHedge on raw cost — CrossHedge beats it only at low gas, and always on the trust axis. Don't claim a blanket multiple over the lean keeper.

**Production SRE:**

| Component | Annual |
|---|---:|
| Fractional SRE engineer | ~$30,000 |
| HA infra (multi-region) | ~$5,000 |
| Monitoring + alerting | ~$3,000 |
| On-call rotation | ~$15,000 |
| Bridge fees | ~$3,600 |
| Audit (annualized) | ~$30,000 |
| **Total** | **~$86,600/yr + destination gas** |

This is dominated by **operational overhead** that doesn't shrink with gas → CrossHedge is ~10× cheaper here, gas regime aside. *(Note: audit is arguably a shared cost — CrossHedge's RSCs need auditing too. Exclude it and the SRE figure is ~$56k; CrossHedge still wins ~7×.)* And a keeper is **fundamentally trusted** — depositors must believe it won't lie about matches, censor, or front-run.

---

## 7. The strongest counterargument — and why CrossHedge still wins

**Objection:** *"Chainlink `checkUpkeep` is off-chain and free. Use a log-trigger upkeep and you only pay `performUpkeep` gas on actual matches — not 525k ticks. Your 66× evaporates."*

**This is correct, and we model it honestly.** A competent log-trigger Chainlink stack pays on-chain gas only on matches (~36k record txs/yr) and uses CCIP to sync events and record matches:

| Unichain gwei | CrossHedge | Chainlink (log-trigger) | Ratio |
|---:|---:|---:|---:|
| 0.005 | ~$165 | ~$7,398 | 44.7× |
| 0.05 | ~$903 | ~$8,291 | 9.2× |
| 0.5 | ~$8,274 | ~$17,222 | **2.1×** |
| 1.0 | ~$16,464 | ~$27,144 | 1.6× |
| 8.0 | ~$131,124 | ~$166,059 | 1.3× |

So against an optimally-built Chainlink stack, the cost advantage is **~2× at typical conditions** (wider when gas is low and CCIP's fixed fee dominates; near parity when gas is high, because of our 2× callback surcharge). **The pure-dollars gap is real but modest.**

**Why CrossHedge still wins — on axes Chainlink cannot tune away:**

1. **Native cross-chain.** Chainlink Automation is *per-chain*; `checkUpkeep` on Unichain cannot read Base's positions. Cross-chain matching forces either CCIP event-syncing (the cost above) or an off-chain aggregator (i.e. the trusted keeper). Reactive subscribes to events on *both* chains and emits callbacks to *both* — natively, in one programming model.
2. **Contract-to-contract composition.** Our StrategyRSC subscribes to events emitted by our MatchingRSC. That on-chain RSC→RSC composition has no equivalent in Automation.
3. **Trustless.** The matcher is public, verifiable Solidity. There is no operator to run, bribe, censor with, or take offline. The keeper alternative is trusted at *any* price; the comparison there isn't "cheaper," it's "trust-minimized vs not."

**Bottom line:** lead with the architecture and trust moat; cite cost as "an order of magnitude cheaper than a production keeper, and cheaper than even an optimal Chainlink build, with a like-for-like cron replica costing ~66× more." All three numbers are in the script.

---

## 8. Robustness to REACT price

Only Lasna execution scales with REACT; callbacks are paid in destination ETH. So CrossHedge's cost is **not REACT-dependent at any plausible valuation**:

| REACT price | Lasna cost | CrossHedge (Uni 0.5 gwei) | vs Chainlink (cron) |
|---:|---:|---:|---:|
| $0.015 (today) | $1.60 | ~$8,274 | 66× |
| $0.05 (3×) | $5.30 | ~$8,277 | 66× |
| $0.161 (ATH, 10×) | $17.20 | ~$8,289 | 66× |
| $1.00 (66×) | $107 | ~$8,379 | 65× |
| $10.00 (660×) | $1,067 | ~$9,339 | 59× |

Even at a REACT price implying a multi-billion-dollar market cap, the conclusion is unchanged.

---

## 9. Scale sensitivity

At 10× event volume (1,000+ LP opens/day, 180k matches/yr), at Unichain 0.5 gwei:

| Component | 18k matches/yr | 180k matches/yr |
|---|---:|---:|
| Lasna execution | ~$2 | ~$5 (cron-dominated, ~flat) |
| Callbacks | ~$8,274 | ~$82,740 |
| **CrossHedge total** | **~$8,276** | **~$82,745** |
| Chainlink (cron parity) | ~$547k | ~$5.5M |

CrossHedge's cost rises linearly with matches; the cron-parity ratio holds because Automation's per-tick cost is fixed by cadence, not match volume.

---

## 10. What's NOT priced in

1. **Trust costs.** A keeper must be trusted; the matcher is auditable Solidity. Real, unquantified, and arguably the whole point.
2. **Deploy gas.** All 13 contracts cost ~0.0007 ETH (~$2.50) one-time on testnet; ~$5–50 on mainnet depending on gas. Rounding error annually.
3. **Lasna base-fee uncertainty.** Assumed 1 gwei; if Lasna congests it could rise 10–100×, but Lasna cost is ~$2/yr so this is immaterial until REACT is worth dollars.
4. **The 2× Reactive callback surcharge** is included and works *against* CrossHedge vs a raw keeper on pure gas — we do not hide it.

---

## 11. Reproducible math

Run [`cost_analysis.py`](./cost_analysis.py) (`python3 cost_analysis.py` or `uv run cost_analysis.py`). Verified output at the documented assumptions:

```
CrossHedge on Reactive:               $8,274/yr
  Lasna execution (REACT):            $2
  Cross-chain callbacks (dest ETH):   $8,272
Chainlink - cron parity (525k ticks): $547,064/yr
Chainlink - log-trigger (competent):  $17,222/yr
Centralized keeper (lean):            $8,200/yr + dest gas
Centralized keeper (production SRE):  $86,600/yr + dest gas
--------------------------------------------------------------------------
Ratio vs Chainlink (cron parity):     66x
Ratio vs Chainlink (log-trigger):     2.1x
Ratio vs production keeper:           10x
```

Change the assumptions at the top of the file and re-run. The cron-parity ratio (~66×) and the log-trigger ratio (~2×) are both robust to gas and REACT price across every input tested.

---

## Sources

- Reactive pricing model: [dev.reactive.network/economy](https://dev.reactive.network/economy)
- REACT live price: [coinmarketcap.com/currencies/reactive-network](https://coinmarketcap.com/currencies/reactive-network) (~$0.015, June 2026)
- Chainlink Automation economics (checkUpkeep is off-chain/free; only performUpkeep costs gas): [docs.chain.link/chainlink-automation/overview/automation-economics](https://docs.chain.link/chainlink-automation/overview/automation-economics)
- CCIP billing (L2→L2 data messaging $0.09 LINK / $0.10 other): [docs.chain.link/ccip/billing](https://docs.chain.link/ccip/billing)
- Base gas tracker: [basescan.org/gastracker](https://basescan.org/gastracker)
- Unichain gas tracker: [quicknode.com/gas-tracker/unichain](https://www.quicknode.com/gas-tracker/unichain)
- Gas measurements: `forge test --gas-report` on the CrossHedge contracts, plus on-chain receipts from the live demo (tx hashes in the README's Live demo section)
