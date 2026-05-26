// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Constants} from "../../libraries/Constants.sol";

/// @title MatchScore
/// @notice Pure scoring function for greedy 1:1 LP matching.
/// @dev Caller passes two candidate positions' (delta, gamma, horizon) tuples and
///      the protocol's current correlation estimate (in bps, 10_000 = 1.00).
///
///      Score is 0 if any gate fails (sign / horizon / gamma / correlation).
///      Otherwise score is a quality metric in arbitrary units; higher is better.
///      matchableNotional is the min absolute delta in ETH (1e18) units.
library MatchScore {
    /// @notice Maximum allowed horizon bucket distance (0..3 → diff ≤ HORIZON_TOLERANCE).
    uint8 internal constant HORIZON_TOLERANCE = 1;

    /// @notice Reject if |γA - γB| / max(γA, γB) exceeds this in bps (5000 = 50%).
    uint16 internal constant MAX_GAMMA_DIFF_BPS = 5000;

    /// @notice Reject if correlation below this in bps (5000 = 0.50).
    uint16 internal constant MIN_CORRELATION_BPS = 5000;

    /// @notice Horizon penalty per bucket of difference, in bps (2500 = 25%).
    uint16 internal constant HORIZON_PENALTY_PER_STEP_BPS = 2500;

    /// @notice Compute a match score between two candidate positions.
    /// @param deltaA           Signed ETH delta of position A, scaled 1e18.
    /// @param deltaB           Signed ETH delta of position B, scaled 1e18.
    /// @param gammaA           Non-negative gamma of position A, scaled 1e18.
    /// @param gammaB           Non-negative gamma of position B, scaled 1e18.
    /// @param horizonA         Horizon bucket of A (0=7d, 1=30d, 2=90d, 3=365d).
    /// @param horizonB         Horizon bucket of B.
    /// @param correlationBps   Protocol-supplied correlation estimate (10_000 = 1.00).
    /// @return matchScore_     Quality score; 0 if any gate rejects.
    /// @return matchableNotional Min(|deltaA|, |deltaB|) in ETH units (1e18).
    function score(
        int256 deltaA,
        int256 deltaB,
        uint128 gammaA,
        uint128 gammaB,
        uint8 horizonA,
        uint8 horizonB,
        uint16 correlationBps
    ) internal pure returns (uint128 matchScore_, uint128 matchableNotional) {
        // ─── Gate 1: sign — must be opposite ────────────────────────────────
        if (deltaA == 0 || deltaB == 0) return (0, 0);
        if ((deltaA > 0) == (deltaB > 0)) return (0, 0);

        // ─── Gate 2: horizon distance ───────────────────────────────────────
        uint8 horizonDiff =
            horizonA >= horizonB ? horizonA - horizonB : horizonB - horizonA;
        if (horizonDiff > HORIZON_TOLERANCE) return (0, 0);

        // ─── Gate 3: gamma similarity ───────────────────────────────────────
        uint128 maxGamma = gammaA >= gammaB ? gammaA : gammaB;
        if (maxGamma == 0) return (0, 0); // both gammas zero ⇒ degenerate
        uint128 gammaDiff = gammaA >= gammaB ? gammaA - gammaB : gammaB - gammaA;
        // gammaDiff / maxGamma > 0.50  ⟺  gammaDiff * BPS_DENOMINATOR > maxGamma * 5000
        if (
            uint256(gammaDiff) * Constants.BPS_DENOMINATOR
                > uint256(maxGamma) * MAX_GAMMA_DIFF_BPS
        ) {
            return (0, 0);
        }

        // ─── Gate 4: correlation floor ──────────────────────────────────────
        if (correlationBps < MIN_CORRELATION_BPS) return (0, 0);

        // ─── Compute overlap (matchable amount) ─────────────────────────────
        uint256 absA = deltaA >= 0 ? uint256(deltaA) : uint256(-deltaA);
        uint256 absB = deltaB >= 0 ? uint256(deltaB) : uint256(-deltaB);
        uint256 overlap = absA <= absB ? absA : absB;

        // Saturate the matchable notional into uint128 (positions > 3.4e20 ETH are absurd)
        matchableNotional =
            overlap > type(uint128).max ? type(uint128).max : uint128(overlap);

        // ─── Penalties (scaled in bps then multiplied together) ─────────────
        // gammaPenalty_bps = BPS - (gammaDiff / maxGamma) * BPS
        //                  = BPS - gammaDiff * BPS / maxGamma
        uint256 gammaPenaltyBps = uint256(Constants.BPS_DENOMINATOR)
            - (uint256(gammaDiff) * Constants.BPS_DENOMINATOR) / uint256(maxGamma);

        // horizonPenalty_bps = BPS - horizonDiff * HORIZON_PENALTY_PER_STEP_BPS
        uint256 horizonPenaltyBps = uint256(Constants.BPS_DENOMINATOR)
            - uint256(horizonDiff) * uint256(HORIZON_PENALTY_PER_STEP_BPS);

        // ─── Composite score ────────────────────────────────────────────────
        // score = overlap * correlation * gammaPenalty * horizonPenalty
        //         / BPS^3
        // We progressively divide by BPS to keep intermediates within uint256.
        // overlap is bounded by uint128 (we just saturated). Each factor is ≤ BPS (1e4).
        // overlap * correlationBps  ≤ 2^128 * 1e4  ≤ 2^142. Safe.
        // Then * gammaPenaltyBps / BPS ≤ 2^128 * 1e4. Safe.
        // Then * horizonPenaltyBps / BPS ≤ 2^128 * 1e4. Safe.
        // Final / BPS ≤ 2^128. Fits.
        uint256 s = uint256(matchableNotional);
        s = (s * uint256(correlationBps)) / Constants.BPS_DENOMINATOR;
        s = (s * gammaPenaltyBps) / Constants.BPS_DENOMINATOR;
        s = (s * horizonPenaltyBps) / Constants.BPS_DENOMINATOR;

        matchScore_ = s > type(uint128).max ? type(uint128).max : uint128(s);
    }
}
