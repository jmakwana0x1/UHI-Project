// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

import {Constants} from "../../libraries/Constants.sol";

/// @title VolEMA
/// @notice Rolling realized-volatility estimator using an EMA of squared
///         log-returns derived from sqrt-price snapshots.
///
/// @dev Approach
///   1. Receive `(sqrtPriceX96, timestamp)` updates.
///   2. Approximate per-update log-return as r ≈ 2 · Δsqrt / sqrt_old.
///      (First-order expansion of ln(1+x); accurate to ~0.5% for moves up to
///      5% sqrt-price = 10% price. Adequate for vol estimation where the EMA
///      itself contributes more noise than the linearization.)
///   3. Update EMA of r² with weight α (default 5%).
///   4. Annualize using the elapsed wall-clock interval per sample.
///
///      All vols are scaled 1e18.
///
/// @dev Bias note
///   The EMA is biased toward zero for sampleCount < 1/α. Caller should
///   require `state.sampleCount >= MIN_SAMPLES_FOR_VOL` before consuming
///   `annualizedVolE18`. Default MIN_SAMPLES_FOR_VOL = 10 (i.e., trust the
///   output only after ~10 updates, by which point bias is ~40% of α).
library VolEMA {
    /// @notice Minimum sample count before vol is considered trustworthy.
    uint32 internal constant MIN_SAMPLES_FOR_VOL = 10;

    /// @notice Default EMA weight; α = 500 bps (5%). Half-life ~ 14 samples.
    uint16 internal constant DEFAULT_ALPHA_BPS = 500;

    /// @notice Saturating max for EMA to keep arithmetic bounded.
    /// @dev r² ≤ 4 ≈ 4e18 even at huge moves; cap EMA at 1e30 to be safe.
    uint256 internal constant EMA_SATURATION = 1e30;

    /// @notice Internal-VM state for one (pool, RSC) pair.
    struct State {
        uint160 lastSqrtPrice;   // last snapshot's sqrt-price (Q64.96)
        uint64 lastTimestamp;    // last snapshot's wall-clock
        uint256 emaSqReturnE18;  // EMA of squared log-returns, scaled 1e18
        uint64 totalElapsed;     // sum of (timestamp - lastTimestamp), seconds
        uint32 sampleCount;      // number of samples consumed
    }

    /// @notice Push a new snapshot into the EMA.
    /// @dev Caller is responsible for never calling with a timestamp strictly
    ///      less than `state.lastTimestamp`. Identical timestamps are silently
    ///      ignored (no-op) — same-block snapshots are degenerate for vol.
    function updateEMA(
        State storage state,
        uint160 sqrtPriceX96,
        uint64 timestamp,
        uint16 alphaBps
    ) internal {
        // First sample — just record.
        if (state.lastTimestamp == 0) {
            state.lastSqrtPrice = sqrtPriceX96;
            state.lastTimestamp = timestamp;
            state.sampleCount = 1;
            return;
        }

        // Reject same-timestamp (no information).
        if (timestamp <= state.lastTimestamp) return;
        if (sqrtPriceX96 == 0) return;

        uint160 lastSqrt = state.lastSqrtPrice;
        if (lastSqrt == 0) {
            state.lastSqrtPrice = sqrtPriceX96;
            state.lastTimestamp = timestamp;
            unchecked { state.sampleCount += 1; }
            return;
        }

        // ─── Compute r ≈ 2 · Δsqrt / sqrt_old, scaled to 1e18 ─────────────
        // Note: |r| <= ~2 in practice; we work with abs(r) and lose sign info
        //       (we only need r², so sign doesn't matter).
        uint256 absDeltaSqrt = sqrtPriceX96 >= lastSqrt
            ? uint256(sqrtPriceX96) - uint256(lastSqrt)
            : uint256(lastSqrt) - uint256(sqrtPriceX96);

        // |r|_E18 = 2 * absDeltaSqrt * 1e18 / lastSqrt
        // mulDiv keeps full precision through the 1e18 scaling.
        uint256 absR_E18 = FullMath.mulDiv(
            absDeltaSqrt * 2,
            Constants.E18,
            uint256(lastSqrt)
        );

        // ─── r² scaled to 1e18 ────────────────────────────────────────────
        // (r_E18)² is in units of 1e36; divide by 1e18 to land back at 1e18.
        uint256 rSq_E18 = FullMath.mulDiv(absR_E18, absR_E18, Constants.E18);
        if (rSq_E18 > EMA_SATURATION) rSq_E18 = EMA_SATURATION;

        // ─── EMA update: ema_new = α · r² + (1 - α) · ema_old ─────────────
        uint256 alpha = uint256(alphaBps);
        uint256 oneMinusAlpha = uint256(Constants.BPS_DENOMINATOR) - alpha;

        uint256 newEma = (alpha * rSq_E18 + oneMinusAlpha * state.emaSqReturnE18)
            / uint256(Constants.BPS_DENOMINATOR);
        if (newEma > EMA_SATURATION) newEma = EMA_SATURATION;

        // ─── Persist ──────────────────────────────────────────────────────
        unchecked {
            state.totalElapsed += (timestamp - state.lastTimestamp);
            state.sampleCount += 1;
        }
        state.emaSqReturnE18 = newEma;
        state.lastSqrtPrice = sqrtPriceX96;
        state.lastTimestamp = timestamp;
    }

    /// @notice Annualized realized vol in 1e18 fixed point.
    /// @dev Returns 0 if too few samples (caller should treat this as "unknown").
    ///      Returns 0 if no time has elapsed.
    function annualizedVolE18(State storage state) internal view returns (uint256) {
        if (state.sampleCount < MIN_SAMPLES_FOR_VOL) return 0;
        if (state.totalElapsed == 0) return 0;
        if (state.emaSqReturnE18 == 0) return 0;

        // Average interval in seconds (rounded, ≥ 1)
        uint256 nIntervals = uint256(state.sampleCount) - 1;
        if (nIntervals == 0) return 0;
        uint256 avgIntervalSec = uint256(state.totalElapsed) / nIntervals;
        if (avgIntervalSec == 0) avgIntervalSec = 1;

        // annualized_variance_E18 = ema_per_interval_E18 · (SECONDS_PER_YEAR / avgInterval)
        uint256 annualVarE18 = FullMath.mulDiv(
            state.emaSqReturnE18,
            uint256(Constants.SECONDS_PER_YEAR),
            avgIntervalSec
        );

        // vol = sqrt(variance). Both are 1e18 scaled.
        // sqrt(v_E18) = sqrt(v) · 1e9   — so the sqrt of a 1e18 number lands at 1e9.
        // To restore 1e18 scale on the output, multiply by 1e9 first then sqrt:
        //   sqrt(v_E18 · 1e18) = sqrt(v) · 1e18.
        uint256 scaled = annualVarE18 * Constants.E18;
        return _sqrt(scaled);
    }

    /// @notice Babylonian square root. ~7 iterations to convergence on 256-bit input.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        // Initial guess: bit-length-based. Faster than starting at x.
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
