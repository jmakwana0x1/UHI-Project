// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MatchScore} from "../../../src/reactive/modules/MatchScore.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/// @title MatchScoreTest
/// @notice Tests for the greedy matching scorer. Verifies each gate
///         (sign, horizon, gamma, correlation) and the composite score
///         monotonicity properties.
contract MatchScoreTest is Test {
    // ─── Helpers ────────────────────────────────────────────────────────────

    function _good() internal pure returns (
        int256 dA, int256 dB, uint128 gA, uint128 gB,
        uint8 hA, uint8 hB, uint16 corr
    ) {
        // canonical "good match" baseline
        dA   = int256(10 ether);   // long 10 ETH delta
        dB   = -int256(10 ether);  // short 10 ETH delta
        gA   = 1e18;
        gB   = 1e18;
        hA   = 1;                  // 30d
        hB   = 1;                  // 30d
        corr = 10_000;             // 1.00
    }

    // ─── Gate 1: sign ───────────────────────────────────────────────────────

    function test_sameSign_BothPositive_ReturnsZero() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s, uint128 n) = MatchScore.score(
            int256(10 ether), int256(5 ether), gA, gB, hA, hB, c
        );
        assertEq(s, 0);
        assertEq(n, 0);
    }

    function test_sameSign_BothNegative_ReturnsZero() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(
            -int256(10 ether), -int256(5 ether), gA, gB, hA, hB, c
        );
        assertEq(s, 0);
    }

    function test_oneZeroDelta_ReturnsZero() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(0, -int256(5 ether), gA, gB, hA, hB, c);
        assertEq(s, 0);
    }

    // ─── Gate 2: horizon ────────────────────────────────────────────────────

    function test_horizonAdjacent_Passes() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, , , uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, 0, 1, c);
        assertGt(s, 0);
    }

    function test_horizonGapTwo_ReturnsZero() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, , , uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, 0, 2, c);
        assertEq(s, 0);
    }

    function test_horizonGapThree_ReturnsZero() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, , , uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, 0, 3, c);
        assertEq(s, 0);
    }

    // ─── Gate 3: gamma ──────────────────────────────────────────────────────

    function test_gammaIdentical_Passes() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, 1e18, 1e18, hA, hB, c);
        assertGt(s, 0);
    }

    function test_gammaTen_PercentDiff_Passes() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        // 10% diff: 1.0e18 vs 1.1e18; diff / max = 0.1/1.1 = 9.09% < 50% gate
        (uint128 s, ) = MatchScore.score(
            dA, dB, 1e18, uint128(1.1e18), hA, hB, c
        );
        assertGt(s, 0);
    }

    function test_gammaAt_50PercentDiff_ExactlyAtBoundary_Passes() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        // gammaA = 1e18, gammaB = 2e18  →  diff = 1e18, max = 2e18, ratio = 50% exactly
        // Gate is `>` not `≥`, so 50% exactly should PASS.
        (uint128 s, ) = MatchScore.score(
            dA, dB, 1e18, uint128(2e18), hA, hB, c
        );
        assertGt(s, 0);
    }

    function test_gammaOver_50PercentDiff_ReturnsZero() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        // gammaA = 1e18, gammaB = 2.01e18 → diff/max ≈ 50.25% > gate
        (uint128 s, ) = MatchScore.score(
            dA, dB, 1e18, uint128(2.01e18), hA, hB, c
        );
        assertEq(s, 0);
    }

    function test_bothGammaZero_ReturnsZero() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, 0, 0, hA, hB, c);
        assertEq(s, 0);
    }

    // ─── Gate 4: correlation ────────────────────────────────────────────────

    function test_correlationAt50_Passes() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB,) = _good();
        // 50% exactly = 5000 bps. Gate is `<` so 5000 should PASS.
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, hA, hB, 5000);
        assertGt(s, 0);
    }

    function test_correlationBelow50_ReturnsZero() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB,) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, hA, hB, 4999);
        assertEq(s, 0);
    }

    function test_correlationZero_ReturnsZero() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB,) = _good();
        (uint128 s, ) = MatchScore.score(dA, dB, gA, gB, hA, hB, 0);
        assertEq(s, 0);
    }

    // ─── Matchable notional ─────────────────────────────────────────────────

    function test_matchableNotional_IsMinOfAbsDeltas_LongerLong() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (, uint128 n) = MatchScore.score(
            int256(20 ether), -int256(10 ether), gA, gB, hA, hB, c
        );
        assertEq(n, 10 ether);
    }

    function test_matchableNotional_IsMinOfAbsDeltas_LongerShort() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (, uint128 n) = MatchScore.score(
            int256(7 ether), -int256(15 ether), gA, gB, hA, hB, c
        );
        assertEq(n, 7 ether);
    }

    function test_matchableNotional_EqualSides() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        (, uint128 n) = MatchScore.score(dA, dB, gA, gB, hA, hB, c);
        assertEq(n, 10 ether);
    }

    // ─── Composite score properties ─────────────────────────────────────────

    function test_perfectMatch_ScoreEqualsOverlap() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        // identical gammas, identical horizons, perfect correlation → no penalty.
        // score should equal matchable notional = 10 ether.
        (uint128 s, uint128 n) = MatchScore.score(dA, dB, gA, gB, hA, hB, c);
        assertEq(s, n);
        assertEq(s, 10 ether);
    }

    function test_lowerCorrelation_ProducesLowerScore() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, uint8 hA, uint8 hB,) = _good();
        (uint128 s_high, ) = MatchScore.score(dA, dB, gA, gB, hA, hB, 10_000);
        (uint128 s_low,  ) = MatchScore.score(dA, dB, gA, gB, hA, hB, 7_500);
        assertGt(s_high, s_low);
        // 75% correlation should give exactly 0.75 of perfect score
        assertEq(s_low, (s_high * 7500) / 10000);
    }

    function test_horizonGap_AppliesPenalty() public pure {
        (int256 dA, int256 dB, uint128 gA, uint128 gB, , , uint16 c) = _good();
        (uint128 s_same, ) = MatchScore.score(dA, dB, gA, gB, 1, 1, c);
        (uint128 s_adj,  ) = MatchScore.score(dA, dB, gA, gB, 1, 2, c);
        assertGt(s_same, s_adj);
        // 25% penalty per step
        assertEq(s_adj, (s_same * 7500) / 10000);
    }

    function test_gammaDiff_AppliesPenalty() public pure {
        (int256 dA, int256 dB, , , uint8 hA, uint8 hB, uint16 c) = _good();
        (uint128 s_same, ) = MatchScore.score(
            dA, dB, 1e18, 1e18, hA, hB, c
        );
        (uint128 s_diff, ) = MatchScore.score(
            dA, dB, 1e18, uint128(1.2e18), hA, hB, c
        );
        // gamma diff = 0.2e18, max = 1.2e18, penalty = 1 - 0.2/1.2 = 0.8333...
        assertGt(s_same, s_diff);
        // approximate check
        uint128 expected = uint128((uint256(s_same) * 10000) / 12000); // ≈ 0.8333 * s_same
        assertApproxEqAbs(s_diff, expected, expected / 1000); // 0.1% tolerance
    }

    // ─── Edge cases ─────────────────────────────────────────────────────────

    function test_minInt256Delta_Saturates() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        // Very large positive long matched with a small short.
        // Should not revert, should return notional = short side.
        (uint128 s, uint128 n) = MatchScore.score(
            type(int256).max, -int256(1 ether), gA, gB, hA, hB, c
        );
        assertEq(n, 1 ether);
        assertGt(s, 0);
    }

    function test_overlapAbove_uint128Max_Saturates() public pure {
        (, , uint128 gA, uint128 gB, uint8 hA, uint8 hB, uint16 c) = _good();
        // both sides huge (above uint128 max) → notional saturates to uint128.max
        int256 huge = int256(uint256(type(uint128).max)) + 1; // 2^128
        (, uint128 n) = MatchScore.score(huge, -huge, gA, gB, hA, hB, c);
        assertEq(n, type(uint128).max);
    }

    // ─── Fuzz: function is pure & deterministic ─────────────────────────────

    function testFuzz_sameInputs_SameOutput(
        int128 dA, int128 dB,
        uint128 gA, uint128 gB,
        uint8 hA, uint8 hB,
        uint16 corr
    ) public pure {
        (uint128 s1, uint128 n1) = MatchScore.score(
            int256(dA), int256(dB), gA, gB, hA, hB, corr
        );
        (uint128 s2, uint128 n2) = MatchScore.score(
            int256(dA), int256(dB), gA, gB, hA, hB, corr
        );
        assertEq(s1, s2);
        assertEq(n1, n2);
    }

    function testFuzz_sameSign_AlwaysZero(uint128 a, uint128 b) public pure {
        vm.assume(a > 0 && b > 0);
        (uint128 s, uint128 n) = MatchScore.score(
            int256(uint256(a)), int256(uint256(b)),
            1e18, 1e18, 1, 1, 10_000
        );
        assertEq(s, 0);
        assertEq(n, 0);
    }

    function testFuzz_oppositeSignGoodInputs_AlwaysNonZero(
        uint96 absA, uint96 absB
    ) public pure {
        // exclude zero so the sign gate doesn't trip
        vm.assume(absA > 0 && absB > 0);
        (uint128 s, uint128 n) = MatchScore.score(
            int256(uint256(absA)), -int256(uint256(absB)),
            1e18, 1e18, 1, 1, 10_000
        );
        assertGt(s, 0);
        assertGt(n, 0);
        // score equals notional for perfect-match inputs
        assertEq(s, n);
    }
}
