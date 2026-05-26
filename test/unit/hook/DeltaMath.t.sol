// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeltaMath} from "../../../src/hook/DeltaMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @notice Library has no state, no reverts — no harness needed.
contract DeltaMathTest is Test {
    // sqrtPriceX96 representing price = 1.0
    uint160 internal constant P_ONE = uint160(1 << 96);

    // Helpers: anchor at known ticks
    int24 internal constant TICK_NEG_500 = -500;
    int24 internal constant TICK_NEG_100 = -100;
    int24 internal constant TICK_ZERO = 0;
    int24 internal constant TICK_100 = 100;
    int24 internal constant TICK_500 = 500;
    int24 internal constant TICK_1000 = 1000;

    // ════════════════════════════════════════════════════════════════════════
    //                              spotEthDelta
    // ════════════════════════════════════════════════════════════════════════

    function test_spotEthDelta_ZeroLiquidity_ReturnsZero() public pure {
        int256 d = DeltaMath.spotEthDelta(0, P_ONE, TICK_NEG_100, TICK_100, true);
        assertEq(d, 0);
    }

    function test_spotEthDelta_InRange_PositiveDelta() public pure {
        // Liquidity centered on price 1.0 → position holds both tokens.
        // ETH side (token1, since usdcIsToken0=true) should be positive.
        int256 d = DeltaMath.spotEthDelta(1e18, P_ONE, TICK_NEG_100, TICK_100, true);
        assertGt(d, 0);
    }

    function test_spotEthDelta_BelowRange_ZeroEthExposure() public pure {
        // Pool price below tickLower → position is 100% USDC (token0)
        // ETH exposure should be 0.
        uint160 lowPrice = TickMath.getSqrtPriceAtTick(TICK_NEG_500);
        int256 d = DeltaMath.spotEthDelta(1e18, lowPrice, TICK_NEG_100, TICK_100, true);
        assertEq(d, 0);
    }

    function test_spotEthDelta_AboveRange_FullEthExposure() public pure {
        // Pool price above tickUpper → position is 100% ETH (token1)
        // ETH delta = full ETH content of position.
        uint160 highPrice = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 dWide = DeltaMath.spotEthDelta(1e18, highPrice, TICK_NEG_100, TICK_100, true);
        // Compare to a narrower range: narrower range = less max ETH.
        int256 dNarrow = DeltaMath.spotEthDelta(1e18, highPrice, TICK_NEG_100, TICK_ZERO, true);
        assertGt(dWide, dNarrow);
    }

    function test_spotEthDelta_SignFlipsWithTokenOrder() public pure {
        // Same position, but with USDC vs ETH order swapped.
        // For an in-range position, usdcIsToken0=true → ETH delta from amount1.
        // usdcIsToken0=false → ETH delta from amount0.
        // These should typically be different magnitudes (asymmetric concentrated liq).
        int256 dA = DeltaMath.spotEthDelta(1e18, P_ONE, TICK_NEG_100, TICK_100, true);
        int256 dB = DeltaMath.spotEthDelta(1e18, P_ONE, TICK_NEG_100, TICK_100, false);
        assertGt(dA, 0);
        assertGt(dB, 0);
        // At symmetric range around price = 1, the two should be approximately equal.
        // (Both are amount0 vs amount1, which are equal by symmetry.)
        assertApproxEqRel(uint256(dA), uint256(dB), 0.01e18);
    }

    function test_spotEthDelta_MonotoneInLiquidity() public pure {
        int256 dSmall = DeltaMath.spotEthDelta(1e16, P_ONE, TICK_NEG_100, TICK_100, true);
        int256 dLarge = DeltaMath.spotEthDelta(1e18, P_ONE, TICK_NEG_100, TICK_100, true);
        assertGt(dLarge, dSmall);
        // Roughly proportional (100x liquidity → 100x delta)
        assertApproxEqRel(uint256(dLarge), uint256(dSmall) * 100, 0.01e18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                                  gamma
    // ════════════════════════════════════════════════════════════════════════

    function test_gamma_ZeroLiquidity_ReturnsZero() public pure {
        uint128 g = DeltaMath.gamma(0, TICK_NEG_100, TICK_100, P_ONE);
        assertEq(g, 0);
    }

    function test_gamma_InvertedRange_ReturnsZero() public pure {
        uint128 g = DeltaMath.gamma(1e18, TICK_100, TICK_NEG_100, P_ONE);
        assertEq(g, 0);
    }

    function test_gamma_TighterRange_HigherGamma() public pure {
        uint128 gWide = DeltaMath.gamma(1e18, TICK_NEG_500, TICK_500, P_ONE);
        uint128 gNarrow = DeltaMath.gamma(1e18, TICK_NEG_100, TICK_100, P_ONE);
        assertGt(gNarrow, gWide);
    }

    function test_gamma_MoreLiquidity_HigherGamma() public pure {
        uint128 gSmall = DeltaMath.gamma(1e17, TICK_NEG_100, TICK_100, P_ONE);
        uint128 gLarge = DeltaMath.gamma(1e18, TICK_NEG_100, TICK_100, P_ONE);
        assertGt(gLarge, gSmall);
    }

    function test_gamma_LinearInLiquidity() public pure {
        uint128 g1 = DeltaMath.gamma(1e18, TICK_NEG_100, TICK_100, P_ONE);
        uint128 g10 = DeltaMath.gamma(10e18, TICK_NEG_100, TICK_100, P_ONE);
        // 10x liquidity should give exactly 10x gamma (linear)
        assertApproxEqRel(uint256(g10), uint256(g1) * 10, 0.001e18);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                           touchProbability
    // ════════════════════════════════════════════════════════════════════════

    function test_touchProb_BarrierBelowCurrent_ReturnsMax() public pure {
        // Already touched / past barrier.
        uint128 p = DeltaMath.touchProbability(
            uint160(2 << 96),  // current = 2.0
            P_ONE,             // upper = 1.0 (below current!)
            30 days,
            0.5e18             // 50% vol
        );
        // Should saturate to MAX_TOUCH_PROB
        assertEq(p, uint128(0.95e18));
    }

    function test_touchProb_ZeroHorizon_ReturnsZero() public pure {
        uint128 p = DeltaMath.touchProbability(P_ONE, uint160(uint256(P_ONE) * 110 / 100), 0, 0.5e18);
        assertEq(p, 0);
    }

    function test_touchProb_ZeroVol_ReturnsZero() public pure {
        uint128 p = DeltaMath.touchProbability(P_ONE, uint160(uint256(P_ONE) * 110 / 100), 30 days, 0);
        assertEq(p, 0);
    }

    function test_touchProb_NearMoney_HighProb() public pure {
        // Barrier 1% above current, 1 year horizon, 50% vol → high probability.
        uint160 barrier = uint160((uint256(P_ONE) * 1005) / 1000); // 0.5% sqrt-price = 1% price
        uint128 p = DeltaMath.touchProbability(P_ONE, barrier, 365 days, 0.5e18);
        assertGt(p, 0.5e18);
    }

    function test_touchProb_FarOutOfMoney_LowProb() public pure {
        // Barrier 30% above current, 1 day horizon, 20% vol → low probability.
        uint160 barrier = uint160((uint256(P_ONE) * 115) / 100); // 15% sqrt = ~30% price
        uint128 p = DeltaMath.touchProbability(P_ONE, barrier, 1 days, 0.2e18);
        assertLt(p, 0.1e18);
    }

    function test_touchProb_MonotoneInVol() public pure {
        uint160 barrier = uint160((uint256(P_ONE) * 105) / 100);
        uint128 pLowVol = DeltaMath.touchProbability(P_ONE, barrier, 30 days, 0.2e18);
        uint128 pHighVol = DeltaMath.touchProbability(P_ONE, barrier, 30 days, 0.8e18);
        assertGt(pHighVol, pLowVol);
    }

    function test_touchProb_MonotoneInHorizon() public pure {
        uint160 barrier = uint160((uint256(P_ONE) * 105) / 100);
        uint128 pShort = DeltaMath.touchProbability(P_ONE, barrier, 7 days, 0.5e18);
        uint128 pLong = DeltaMath.touchProbability(P_ONE, barrier, 90 days, 0.5e18);
        assertGt(pLong, pShort);
    }

    function test_touchProb_MonotoneInDistance() public pure {
        // Closer barrier = higher probability.
        uint160 near = uint160((uint256(P_ONE) * 1005) / 1000); // 1% above (in price)
        uint160 far = uint160((uint256(P_ONE) * 105) / 100);    // 10% above
        uint128 pNear = DeltaMath.touchProbability(P_ONE, near, 30 days, 0.5e18);
        uint128 pFar = DeltaMath.touchProbability(P_ONE, far, 30 days, 0.5e18);
        assertGt(pNear, pFar);
    }

    function test_touchProb_CappedAtMax() public pure {
        // At-the-money with huge vol & horizon → should cap at 0.95.
        uint160 barrierJustAbove = uint160(uint256(P_ONE) + 1);
        uint128 p = DeltaMath.touchProbability(P_ONE, barrierJustAbove, 365 days, 2e18);
        assertEq(p, uint128(0.95e18));
    }

    // ════════════════════════════════════════════════════════════════════════
    //                         syntheticShortDelta
    // ════════════════════════════════════════════════════════════════════════

    function test_synthShort_ZeroLiquidity_ReturnsZero() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_100);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 d = DeltaMath.syntheticShortDelta(0, sA, sB, 0.5e18, true);
        assertEq(d, 0);
    }

    function test_synthShort_ZeroProb_ReturnsZero() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_100);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 d = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0, true);
        assertEq(d, 0);
    }

    function test_synthShort_NormalCase_Negative() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_100);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 d = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.5e18, true);
        assertLt(d, 0);
    }

    function test_synthShort_HigherProb_LargerCredit() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_100);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 dLow = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.1e18, true);
        int256 dHigh = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.9e18, true);
        // More negative for higher probability
        assertLt(dHigh, dLow);
    }

    function test_synthShort_LinearInProbability() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_100);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_500);
        int256 d_25 = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.25e18, true);
        int256 d_50 = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.5e18, true);
        // 2x probability → 2x credit (and twice as negative)
        // Use absolute values
        uint256 abs25 = uint256(-d_25);
        uint256 abs50 = uint256(-d_50);
        assertApproxEqRel(abs50, abs25 * 2, 0.001e18);
    }

    function test_synthShort_InvertedRange_ReturnsZero() public pure {
        uint160 sA = TickMath.getSqrtPriceAtTick(TICK_500);
        uint160 sB = TickMath.getSqrtPriceAtTick(TICK_100);
        int256 d = DeltaMath.syntheticShortDelta(1e18, sA, sB, 0.5e18, true);
        assertEq(d, 0);
    }

    // ════════════════════════════════════════════════════════════════════════
    //                           Fuzz: properties
    // ════════════════════════════════════════════════════════════════════════

    function testFuzz_spotEthDelta_NeverReverts(
        uint128 liq,
        int24 tL,
        int24 tU,
        bool usdcIsToken0
    ) public pure {
        // Constrain to valid v4 tick range and ordering
        vm.assume(tL >= TickMath.MIN_TICK + 1 && tU <= TickMath.MAX_TICK - 1);
        vm.assume(tL < tU);
        vm.assume(liq < 1e30); // realistic positions

        int256 d = DeltaMath.spotEthDelta(liq, P_ONE, tL, tU, usdcIsToken0);
        // Sanity: never negative for long LPs
        assertGe(d, 0);
    }

    function testFuzz_gamma_NeverReverts(
        uint128 liq,
        int24 tL,
        int24 tU
    ) public pure {
        vm.assume(tL >= TickMath.MIN_TICK + 1 && tU <= TickMath.MAX_TICK - 1);
        // Allow inverted ranges → should return 0 not revert
        uint128 g = DeltaMath.gamma(liq, tL, tU, P_ONE);
        if (liq == 0 || tU <= tL) {
            assertEq(g, 0);
        }
    }

    function testFuzz_touchProb_InRange(
        uint16 barrierBps,
        uint32 horizonHours,
        uint16 volBps
    ) public pure {
        vm.assume(barrierBps > 0 && barrierBps < 5000); // up to 50% price above
        vm.assume(horizonHours > 0 && horizonHours < 24 * 365); // up to 1 yr
        vm.assume(volBps > 0 && volBps < 10_000); // up to 100% vol

        uint160 barrier = uint160((uint256(P_ONE) * (10_000 + uint256(barrierBps) / 2)) / 10_000);
        uint128 p = DeltaMath.touchProbability(
            P_ONE,
            barrier,
            uint64(uint256(horizonHours)) * 3600,
            (uint256(volBps) * 1e18) / 10_000
        );
        assertLe(p, uint128(0.95e18));
    }
}
