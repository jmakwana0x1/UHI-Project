#!/usr/bin/env python3
"""
CrossHedge cost analysis - mainnet projection from first principles.

Run: python3 cost_analysis.py   (or: uv run cost_analysis.py)

Reproduces every number in COST_ANALYSIS.md. Adjust the assumptions at the
top to test sensitivity (REACT price, event volume, destination gas, etc.).

Two Chainlink models are provided so the comparison is honest:
  * chainlink_cost_cron()       - time-based upkeep, fires every minute
                                  (architecture parity with CrossHedge's cron).
  * chainlink_cost_logtrigger() - log-trigger upkeep, performUpkeep fires only
                                  on actual matches (the competent design).
The headline ~66x holds ONLY under cron parity. Under log-triggers the gas gap
compresses to low single digits and the real advantage becomes architectural
(native cross-chain) and trust (public contract, no operator). See the doc.

The single biggest variable: UNICHAIN_BASE_FEE_GWEI.
"""

# ===== Token prices (June 2026) =====
REACT_PRICE_USD = 0.015      # CoinMarketCap, ~$0.015
LINK_PRICE_USD = 7.50        # CoinGecko, ~$7.50 (not load-bearing here)
ETH_PRICE_USD = 3500         # Rough spot

# ===== Time =====
SECONDS_PER_YEAR = 365 * 24 * 3600

# ===== Workload cadences (Reactive Network cron primitives) =====
MATCHING_TICKS_PER_YEAR = SECONDS_PER_YEAR / 60        # Cron10 ~= 60s
STRATEGY_TICKS_PER_YEAR = SECONDS_PER_YEAR / (12 * 60)  # Cron100 ~= 12 min

# ===== Per-tick gas (measured via forge gas-report) =====
RSC_TICK_GAS = 180_000      # MatchingRSC: 4-gate match + pool ops
SRSC_TICK_GAS = 100_000     # StrategyRSC: vol-EMA + threshold check
EVENT_INGEST_GAS = 50_000   # per LPPositionOpened / PriceSnapshot ingest

# ===== Event volume (mid-scale; tune for your scale) =====
LP_OPEN_EVENTS_PER_YEAR = 36_000        # ~100/day across 2 origin chains
PRICE_SNAPSHOT_EVENTS_PER_YEAR = 15_000  # ~20/day per chain
MATCHES_PER_YEAR = 18_000               # ~50% match rate
CALLBACK_GAS_DEST = 130_000             # recordMatch on the registry

# ===== Base fees (mainnet - TUNE for your deployment window) =====
LASNA_BASE_FEE_GWEI = 1.0       # Lasna lightly loaded
UNICHAIN_BASE_FEE_GWEI = 0.5    # CRITICAL VARIABLE
BASE_BASE_FEE_GWEI = 0.005      # Base mainnet typical

# Reactive destination pricing: p_callback = p_base * C * (g + K)
# Approximate the C*(g+K) surcharge as 2x raw gas on L2 destinations.
CALLBACK_SURCHARGE_MULTIPLIER = 2.0

# Chainlink Automation node-operator premium
NODE_OP_PCT = 0.50
CL_PERFORM_GAS_FULL = 110_000 + 200_000 + 80_000  # ~390k: cron + matching + overhead
CL_PERFORM_GAS_RECORD = 130_000 + 80_000          # ~210k: record-only + overhead
CCIP_MSG_USD = 0.10                                # L2->L2 data messaging (docs.chain.link/ccip/billing)


def crosshedge_cost(uni_gwei, base_gwei, lasna_gwei=LASNA_BASE_FEE_GWEI,
                    react_price=REACT_PRICE_USD):
    """CrossHedge annual cost (USD) at given gas conditions."""
    matching_react_gas = (MATCHING_TICKS_PER_YEAR * RSC_TICK_GAS
                          + LP_OPEN_EVENTS_PER_YEAR * EVENT_INGEST_GAS)
    strategy_react_gas = 2 * (STRATEGY_TICKS_PER_YEAR * SRSC_TICK_GAS
                              + PRICE_SNAPSHOT_EVENTS_PER_YEAR * EVENT_INGEST_GAS)
    lasna_react = (matching_react_gas + strategy_react_gas) * lasna_gwei * 1e-9
    lasna_usd = lasna_react * react_price

    cb_uni = MATCHES_PER_YEAR * CALLBACK_GAS_DEST * uni_gwei * 1e-9 * CALLBACK_SURCHARGE_MULTIPLIER
    cb_base = MATCHES_PER_YEAR * CALLBACK_GAS_DEST * base_gwei * 1e-9 * CALLBACK_SURCHARGE_MULTIPLIER
    callback_usd = (cb_uni + cb_base) * ETH_PRICE_USD
    return lasna_usd + callback_usd, lasna_usd, callback_usd


def chainlink_cost_cron(uni_gwei, base_gwei):
    """Architecture-parity Chainlink: time-based upkeep fires every minute on
    both chains, paying destination gas each tick. This is what yields ~66x."""
    avg_gas = (uni_gwei + base_gwei) / 2
    eth = (2 * MATCHING_TICKS_PER_YEAR * CL_PERFORM_GAS_FULL
           * avg_gas * 1e-9 * (1 + NODE_OP_PCT))
    automation_usd = eth * ETH_PRICE_USD
    ccip_usd = 2 * MATCHES_PER_YEAR * CCIP_MSG_USD
    return automation_usd + ccip_usd, automation_usd, ccip_usd


def chainlink_cost_logtrigger(uni_gwei, base_gwei):
    """Competent Chainlink: checkUpkeep runs off-chain for free; performUpkeep
    (record-only) fires solely on matches. Plus CCIP to sync events one way and
    record matches back. This is the honest, hard-to-beat comparison."""
    avg_gas = (uni_gwei + base_gwei) / 2
    performs = 2 * MATCHES_PER_YEAR  # record a match on each origin chain
    eth = performs * CL_PERFORM_GAS_RECORD * avg_gas * 1e-9 * (1 + NODE_OP_PCT)
    automation_usd = eth * ETH_PRICE_USD
    # CCIP: sync each LP-open event to the matcher chain + record each match back
    ccip_usd = (LP_OPEN_EVENTS_PER_YEAR + 2 * MATCHES_PER_YEAR) * CCIP_MSG_USD
    return automation_usd + ccip_usd, automation_usd, ccip_usd


# ===== Centralized keeper =====
aws_compute = (20 + 8 + 147) * 12      # Lambda + EC2 + Alchemy RPC x3 ~= $2,100
engineer_lean = 2_500                  # 1 day/mo at $50k opportunity cost
bridge_fees = 3_600                    # CCTP / Across
centralized_lean = aws_compute + engineer_lean + bridge_fees

centralized_sre = (30_000   # fractional SRE
                   + 5_000   # HA infra
                   + 3_000   # monitoring
                   + 15_000  # on-call
                   + 3_600   # bridge fees
                   + 30_000)  # audit (arguably shared with CrossHedge - see doc)


def fmt(x):
    return f"${x:,.0f}"


if __name__ == "__main__":
    uni, base = UNICHAIN_BASE_FEE_GWEI, BASE_BASE_FEE_GWEI
    ch, ch_lasna, ch_cb = crosshedge_cost(uni, base)
    cron_total, cron_auto, cron_ccip = chainlink_cost_cron(uni, base)
    lt_total, lt_auto, lt_ccip = chainlink_cost_logtrigger(uni, base)

    print("=" * 74)
    print("CrossHedge Mainnet Cost Analysis")
    print(f"At Unichain={uni} gwei, Base={base} gwei, ETH=${ETH_PRICE_USD}, REACT=${REACT_PRICE_USD}")
    print("=" * 74)
    print(f"\nCrossHedge on Reactive:               {fmt(ch)}/yr")
    print(f"  Lasna execution (REACT):            {fmt(ch_lasna)}")
    print(f"  Cross-chain callbacks (dest ETH):   {fmt(ch_cb)}")
    print(f"\nChainlink - cron parity (525k ticks): {fmt(cron_total)}/yr")
    print(f"  Automation upkeep x2:               {fmt(cron_auto)}")
    print(f"  CCIP (36k msgs @ $0.10):            {fmt(cron_ccip)}")
    print(f"\nChainlink - log-trigger (competent):  {fmt(lt_total)}/yr")
    print(f"  Automation performUpkeep (matches): {fmt(lt_auto)}")
    print(f"  CCIP (sync + record):               {fmt(lt_ccip)}")
    print(f"\nCentralized keeper (lean):            {fmt(centralized_lean)}/yr + dest gas")
    print(f"Centralized keeper (production SRE):  {fmt(centralized_sre)}/yr + dest gas")
    print("\n" + "-" * 74)
    print(f"Ratio vs Chainlink (cron parity):     {cron_total / ch:.0f}x")
    print(f"Ratio vs Chainlink (log-trigger):     {lt_total / ch:.1f}x")
    print(f"Ratio vs production keeper:           {centralized_sre / ch:.0f}x")
    print("-" * 74)

    print("\nUNICHAIN GAS SENSITIVITY (ratio vs cron-parity Chainlink)")
    print(f"{'Uni gwei':>10} {'CrossHedge':>14} {'CL cron':>14} {'ratio':>8} {'CL log-trig':>14} {'ratio':>8}")
    for g in [0.005, 0.05, 0.5, 1.0, 8.0]:
        c, _, _ = crosshedge_cost(g, base)
        cr, _, _ = chainlink_cost_cron(g, base)
        lt, _, _ = chainlink_cost_logtrigger(g, base)
        print(f"{g:>10.3f} {fmt(c):>14} {fmt(cr):>14} {cr / c:>7.0f}x {fmt(lt):>14} {lt / c:>7.1f}x")

    print("\nREACT PRICE SENSITIVITY (at Unichain=0.5 gwei)")
    print(f"{'REACT $':>10} {'Lasna $':>12} {'CrossHedge':>14} {'vs CL cron':>12}")
    for rp in [0.015, 0.05, 0.161, 1.00, 10.00]:
        c, lasna, _ = crosshedge_cost(uni, base, react_price=rp)
        print(f"{rp:>10.3f} {fmt(lasna):>12} {fmt(c):>14} {cron_total / c:>10.0f}x")