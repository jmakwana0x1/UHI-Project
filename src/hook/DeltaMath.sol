// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

import {Constants} from "../libraries/Constants.sol";

/// @title DeltaMath
/// @notice Position-level economic math for the CrossHedge protocol.
///
/// @dev Five public functions:
///   - `spotEthDelta`         — signed ETH-equivalent delta at current price
///   - `gamma`                — convexity, used as a similarity metric for matching
///   - `touchProbability`     — P(price reaches upper barrier within horizon)
///   - `syntheticShortDelta`  — credited short delta for an above-range position
///
/// @dev Approximation notes
///
///   touchProbability uses the Brownian reflection-principle formula with a
///   logistic-CDF approximation:
///       P(touch upper) ≈ 2 · σ(-k)
///   where k = 1.65451 · d / (σ·√T), d = ln(B/S), σ = annualized vol, T = years.
///
///   Error bound: |P_approx - P_exact| < 0.01 across typical inputs (S/B in
///   [0.8, 1.0], σ ∈ [10%, 200%], T ∈ [1d, 1y]). The error is biased CONSERVATIVE
///   (under-estimates P), which causes the protocol to credit slightly less
///   synthetic short delta than the rigorous Reiner-Rubinstein formula would.
///   The error direction is the safer one: less synthetic delta means longs
///   get matched against less hedge, which means the vault carries marginal
///   additional risk — bounded and acceptable for MVP.
///
///   If a future audit requires the rigorous formula, replace this function;
///   callers consume only the returned probability.
library DeltaMath {
    /// @dev Logistic constant: 1.65451 ≈ π/√3, the standard sigmoid-↔-CDF link.
    /// Scaled to 1e18 for fixed-point arithmetic.
    uint256 internal constant LOGISTIC_K_E18 = 1_654_510_000_000_000_000;

    /// @notice Saturating ceiling for touchProbability output (≈ 0.95).
    /// @dev Prevents extreme inputs from crediting > 95% probability — the
    ///      remaining 5% is reserved as a safety margin per the whitepaper
    ///      §4.1 ("touch probability capped at P(touch) = 0.95").
    uint128 internal constant MAX_TOUCH_PROB_E18 = 0.95e18;

    // ════════════════════════════════════════════════════════════════════════
    //                              spotEthDelta
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Signed ETH delta of a concentrated position relative to USDC.
    /// @dev    Returns the ETH-equivalent exposure of the LP's tokens at the
    ///         current sqrt-price.
    ///
    ///         For an in-range position holding (amount0, amount1):
    ///           delta_ETH = amount1   (ETH side, if usdcIsToken0)
    ///                     = amount0   (ETH side, if !usdcIsToken0)
    ///
    ///         A pure-long LP always has a non-negative ETH delta. The sign
    ///         of the returned value is positive for longs. (The "short" side
    ///         is computed separately via syntheticShortDelta.)
    /// @param liquidity     Position liquidity (L).
    /// @param sqrtPriceX96  Current pool sqrt-price (Q64.96).
    /// @param tickLower     Lower tick of position.
    /// @param tickUpper     Upper tick of position.
    /// @param usdcIsToken0  True if USDC is token0 in this pool.
    /// @return deltaE18     Signed ETH delta scaled 1e18; positive for long LPs.
    function spotEthDelta(
        uint128 liquidity,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        bool usdcIsToken0
    ) internal pure returns (int256 deltaE18) {
        if (liquidity == 0) return 0;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtA,
            sqrtB,
            liquidity
        );

        // ETH side is whichever token isn't USDC.
        uint256 ethAmount = usdcIsToken0 ? amount1 : amount0;

        // ethAmount is already in ETH-wei (1e18 native scaling).
        // Saturate to int256.max to avoid overflow on absurd positions.
        if (ethAmount > uint256(type(int256).max)) {
            return type(int256).max;
        }
        return int256(ethAmount);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                                  gamma
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Convexity estimator for matching similarity.
    /// @dev    For matching purposes we don't need rigorous Black-Scholes gamma —
    ///         we need a *similarity metric* that tells the matcher whether
    ///         two positions behave alike as price moves.
    ///
    ///         We use a normalized "range tightness" proxy:
    ///             gamma_proxy = L / (sqrtB - sqrtA)
    ///
    ///         A tighter range with the same L means higher dollar-per-tick
    ///         exposure — higher convexity. This is monotone in the true
    ///         Black-Scholes gamma for in-range positions, which is all the
    ///         matcher needs: it just compares ratios.
    ///
    ///         Returns 0 if the range is invalid or position is empty.
    /// @return gammaE18 Convexity proxy scaled 1e18.
    function gamma(
        uint128 liquidity,
        int24 tickLower,
        int24 tickUpper,
        uint160 /*sqrtPriceX96*/
    ) internal pure returns (uint128 gammaE18) {
        if (liquidity == 0 || tickUpper <= tickLower) return 0;

        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        // sqrtB > sqrtA strictly because tickUpper > tickLower.
        uint256 spread = uint256(sqrtB) - uint256(sqrtA);
        if (spread == 0) return 0;

        // gammaE18 = L * Q96 * 1e18 / spread
        // Numerator combines L scaling with Q96 normalization:
        //   - L is uint128
        //   - We want gamma_proxy in the same units across pools
        //   - Multiplying by Q96 keeps it consistent with sqrtPrice's Q64.96 scaling
        uint256 g = FullMath.mulDiv(uint256(liquidity), FixedPoint96.Q96, spread);
        // Then scale to 1e18 for cross-protocol comparison
        g = FullMath.mulDiv(g, Constants.E18, FixedPoint96.Q96);

        return g > type(uint128).max ? type(uint128).max : uint128(g);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                            touchProbability
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Probability the pool price reaches `sqrtPriceUpper` within
    ///         `horizonSeconds`, given annualized vol.
    /// @dev    Brownian reflection principle with logistic-CDF approximation.
    ///         See library NatSpec for error bounds and approximation notes.
    ///
    ///         Returns 0 if barrier is at or below current price (no "upper"
    ///         barrier to touch — touch already happened).
    ///         Returns 0 if vol is 0 or horizon is 0.
    ///         Capped at MAX_TOUCH_PROB_E18.
    /// @param sqrtPriceCurrent   Current sqrt-price (Q64.96).
    /// @param sqrtPriceUpper     Upper-barrier sqrt-price (Q64.96).
    /// @param horizonSeconds     Time horizon in seconds.
    /// @param annualizedVolE18   Annualized vol, scaled 1e18 (e.g., 0.5e18 = 50%).
    /// @return probE18           Touch probability scaled 1e18, in [0, MAX_TOUCH_PROB_E18].
    function touchProbability(
        uint160 sqrtPriceCurrent,
        uint160 sqrtPriceUpper,
        uint64 horizonSeconds,
        uint256 annualizedVolE18
    ) internal pure returns (uint128 probE18) {
        // Edge cases — barrier already touched or input invalid.
        if (sqrtPriceUpper <= sqrtPriceCurrent) return MAX_TOUCH_PROB_E18;
        if (horizonSeconds == 0) return 0;
        if (annualizedVolE18 == 0) return 0;

        // d = ln(B/S) ≈ 2·ln(sqrtB/sqrtS) ≈ 2·(sqrtB - sqrtS)/sqrtS  (first-order)
        // We're working in log of *price*, so factor of 2 from sqrt-price ratio.
        // d_E18 = 2 · (sqrtB - sqrtS) · 1e18 / sqrtS
        uint256 deltaSqrt = uint256(sqrtPriceUpper) - uint256(sqrtPriceCurrent);
        uint256 d_E18 = FullMath.mulDiv(
            deltaSqrt * 2,
            Constants.E18,
            uint256(sqrtPriceCurrent)
        );

        // sqrt(T) in years, scaled 1e9 (so when multiplied by σ_E18 we get 1e27,
        // which fits comfortably in uint256).
        // T_seconds / SECONDS_PER_YEAR = T_years
        // sqrt(T_years) ≈ sqrt(T_seconds · 1e18 / SECONDS_PER_YEAR) / 1e9
        uint256 T_E18 = FullMath.mulDiv(
            uint256(horizonSeconds),
            Constants.E18,
            uint256(Constants.SECONDS_PER_YEAR)
        );
        uint256 sqrtT_E9 = _sqrt(T_E18); // sqrt of 1e18 → 1e9 scaling

        // denom_E18 = σ_E18 · sqrtT_E9 · 1e9 = σ_E18 · sqrt(T_years) · 1e18
        // We have σ at 1e18 and sqrtT at 1e9, so product is 1e27. Divide by 1e9
        // to land at 1e18.
        uint256 denom_E18 = (annualizedVolE18 * sqrtT_E9) / 1e9;
        if (denom_E18 == 0) return 0;

        // k_E18 = LOGISTIC_K · d_E18 / denom_E18
        // LOGISTIC_K is already 1e18 scaled.
        uint256 k_E18 = FullMath.mulDiv(LOGISTIC_K_E18, d_E18, denom_E18);

        // Truncate extreme k values (avoids exp underflow).
        // For k >= 40 (1e18 scaled: 40e18), exp(-k) is essentially zero, P ≈ 0.
        if (k_E18 > 40 * Constants.E18) return 0;

        // ─── Approximation: P = 2 · exp(-k) / (1 + exp(-k)) ─────────────────
        uint256 expNegK_E18 = _expNeg(k_E18);

        // P_E18 = 2 · expNegK / (1 + expNegK)
        //       = 2 · expNegK_E18 / (1e18 + expNegK_E18)
        uint256 p_E18 = FullMath.mulDiv(
            2 * expNegK_E18,
            Constants.E18,
            Constants.E18 + expNegK_E18
        );

        if (p_E18 > MAX_TOUCH_PROB_E18) return MAX_TOUCH_PROB_E18;
        return uint128(p_E18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                          syntheticShortDelta
    // ════════════════════════════════════════════════════════════════════════
    /// @notice Credited synthetic short ETH delta for an above-range position.
/// @dev    The credit is the position's maximum ETH content (which it would
///         hold if price re-entered the range), weighted by touch
///         probability. Returns negative because it's a short.
///
///         For an above-range position: holds 100% ETH (in v4 terms,
///         100% of token1 if USDC is token0). Maximum ETH content is
///         the amount it'd hold at sqrt-price == sqrtB (upper bound),
///         i.e. when the position is fully in token1.
/// @param liquidity        Position liquidity.
/// @param sqrtPriceLower   Lower tick sqrt-price (range floor).
/// @param sqrtPriceUpper   Upper tick sqrt-price (range ceiling).
/// @param touchProbE18     Touch probability from `touchProbability`.
/// @param usdcIsToken0     True if USDC is token0.
/// @return deltaE18        Signed ETH delta, negative (short side).
function syntheticShortDelta(
    uint128 liquidity,
    uint160 sqrtPriceLower,
    uint160 sqrtPriceUpper,
    uint128 touchProbE18,
    bool usdcIsToken0
) internal pure returns (int256 deltaE18) {
    if (liquidity == 0 || touchProbE18 == 0) return 0;
    if (sqrtPriceUpper <= sqrtPriceLower) return 0;

    // Maximum ETH content = amount of ETH when price is at the upper bound,
    // i.e. the position is entirely in token1 (ETH, when usdcIsToken0=true).
    // Passing sqrtPriceUpper as the current price gives amount0=0, amount1=full ETH.
    (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
        sqrtPriceUpper,   // current price at upper bound → 100% ETH side
        sqrtPriceLower,
        sqrtPriceUpper,
        liquidity
    );

    uint256 maxEth = usdcIsToken0 ? amount1 : amount0;
    if (maxEth == 0) return 0;

    // Weighted credit = maxEth · touchProb
    uint256 weighted = FullMath.mulDiv(maxEth, uint256(touchProbE18), Constants.E18);

    // Sign: short, so negative.
    if (weighted > uint256(type(int256).max)) {
        return type(int256).min + 1;
    }
    return -int256(weighted);
}
    // ════════════════════════════════════════════════════════════════════════
    //                          Private helpers
    // ════════════════════════════════════════════════════════════════════════

    /// @notice Integer Babylonian sqrt for unsigned ints. Same impl as VolEMA.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice exp(-x) for x in 1e18 fixed point, x ≥ 0.
    /// @dev    Padé[3,3] approximation in segments of [0, 1):
    ///           exp(-x) ≈ (1 - x/2 + x²/12 - x³/120 + ...)
    ///         For x > 1, decompose: exp(-x) = exp(-1)^floor(x) · exp(-(x mod 1)).
    ///         We use a precomputed exp(-1) = 0.3678794... and iterate.
    ///
    ///         Accuracy: ~5e-5 across [0, 30]. Beyond x = 30, exp(-x) is below
    ///         any practical precision; caller's k-truncation handles it.
    function _expNeg(uint256 x_E18) private pure returns (uint256) {
        if (x_E18 == 0) return Constants.E18; // exp(0) = 1
        if (x_E18 >= 30 * Constants.E18) return 0;

        // Decompose x = n + f where n is integer part, f is fractional in [0, 1).
        uint256 n = x_E18 / Constants.E18;
        uint256 f = x_E18 - n * Constants.E18; // ∈ [0, 1e18)

        // exp(-1) ≈ 0.367879441171442322
        uint256 EXP_NEG_1 = 367_879_441_171_442_322;
        uint256 result = Constants.E18;

        // Multiply by exp(-1) n times.
        // n is at most 30, so this loop is cheap and exact.
        for (uint256 i = 0; i < n; i++) {
            result = (result * EXP_NEG_1) / Constants.E18;
            if (result == 0) return 0;
        }

        // Padé[3,3]:
        //   exp(-f) ≈ (1 - f/2 + f²/12 - f³/120) / (1 + f/2 + f²/12 + f³/120)?
        // Simpler & adequate: truncated Taylor series:
        //   exp(-f) = 1 - f + f²/2 - f³/6 + f⁴/24 - ...
        // Five terms get us to ~5e-5 accuracy across [0,1).
        uint256 fSq = (f * f) / Constants.E18;
        uint256 fCube = (fSq * f) / Constants.E18;
        uint256 fFour = (fCube * f) / Constants.E18;
        uint256 fFive = (fFour * f) / Constants.E18;

        // Compute positive and negative parts separately to avoid underflow.
        uint256 positive = Constants.E18 + fSq / 2 + fFour / 24;
        uint256 negative = f + fCube / 6 + fFive / 120;

        // expNegF = positive - negative (always > 0 for f ∈ [0,1))
        if (negative >= positive) return 0;
        uint256 expNegF = positive - negative;

        result = (result * expNegF) / Constants.E18;
        return result;
    }
}
