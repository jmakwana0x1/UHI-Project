// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapBounded} from "../../../src/vault/TwapBounded.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @notice Tiny harness so vm.expectRevert can catch library reverts.
///         Library calls are inlined; revert needs a real CALL frame.
contract TwapBoundedHarness {
    function check(uint160 exec, uint160 twap, uint16 bps) external pure {
        TwapBounded.checkSlippageAgainstTwap(exec, twap, bps);
    }

    function limit(uint160 twap, uint16 bps, bool zeroForOne) external pure returns (uint160) {
        return TwapBounded.slippageLimitFromTwap(twap, bps, zeroForOne);
    }
}

/// @title TwapBoundedTest
contract TwapBoundedTest is Test {
    TwapBoundedHarness internal h;

    uint160 internal constant ANCHOR = uint160(1 << 96); // sqrtPriceX96 = 1.0
    uint16 internal constant SLIPPAGE_50_BPS = 50;
    uint16 internal constant SLIPPAGE_100_BPS = 100;

    function setUp() public {
        h = new TwapBoundedHarness();
    }

    // ─── checkSlippageAgainstTwap: pass cases ───────────────────────────────

    function test_check_ExactAnchor_Passes() public view {
        h.check(ANCHOR, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_check_WellWithinBound_Passes() public view {
        uint160 exec = uint160((uint256(ANCHOR) * 9990) / 10000);
        h.check(exec, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_check_AtExactBound_Passes() public view {
        // Construct exec from the library's own formula so the boundary aligns
        // exactly (avoids the integer-rounding mismatch that bit us).
        uint256 allowedDelta =
            FullMath.mulDiv(uint256(ANCHOR), uint256(SLIPPAGE_50_BPS), 20_000);
        uint160 exec = uint160(uint256(ANCHOR) - allowedDelta);
        h.check(exec, ANCHOR, SLIPPAGE_50_BPS);
    }

    // ─── checkSlippageAgainstTwap: revert cases ─────────────────────────────

    function test_check_OverBound_Reverts() public {
        uint160 exec = uint160((uint256(ANCHOR) * 9950) / 10000);
        vm.expectRevert();
        h.check(exec, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_check_OverBoundUpward_Reverts() public {
        uint160 exec = uint160((uint256(ANCHOR) * 10050) / 10000);
        vm.expectRevert();
        h.check(exec, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_check_ZeroTwap_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.TwapStale.selector, 0));
        h.check(ANCHOR, 0, SLIPPAGE_50_BPS);
    }

    function test_check_WiderSlippageAllowed_MorePermissive() public view {
        uint160 exec = uint160((uint256(ANCHOR) * 9970) / 10000);
        h.check(exec, ANCHOR, SLIPPAGE_100_BPS);
    }

    function test_check_SymmetryAroundAnchor() public view {
        uint160 above = uint160((uint256(ANCHOR) * 10020) / 10000);
        uint160 below = uint160((uint256(ANCHOR) * 9980) / 10000);
        h.check(above, ANCHOR, SLIPPAGE_100_BPS);
        h.check(below, ANCHOR, SLIPPAGE_100_BPS);
    }

    // ─── slippageLimitFromTwap: zeroForOne ──────────────────────────────────

    function test_limit_ZeroForOne_BelowAnchor() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, true);
        assertLt(lim, ANCHOR);
    }

    function test_limit_ZeroForOne_50bps_CorrectMagnitude() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, true);
        uint256 expectedDelta = FullMath.mulDiv(uint256(ANCHOR), 50, 20_000);
        uint256 actualDelta = uint256(ANCHOR) - uint256(lim);
        assertEq(actualDelta, expectedDelta);
    }

    // ─── slippageLimitFromTwap: !zeroForOne ─────────────────────────────────

    function test_limit_OneForZero_AboveAnchor() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, false);
        assertGt(lim, ANCHOR);
    }

    function test_limit_OneForZero_50bps_CorrectMagnitude() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, false);
        uint256 expectedDelta = FullMath.mulDiv(uint256(ANCHOR), 50, 20_000);
        uint256 actualDelta = uint256(lim) - uint256(ANCHOR);
        assertEq(actualDelta, expectedDelta);
    }

    // ─── slippageLimitFromTwap: bound clamping ──────────────────────────────

    function test_limit_NearMinSqrtPrice_ClampsToMin() public view {
        uint160 nearMin = TickMath.MIN_SQRT_PRICE + 100;
        uint160 lim = h.limit(nearMin, 10_000, true);
        assertGe(lim, TickMath.MIN_SQRT_PRICE);
    }

    function test_limit_NearMaxSqrtPrice_ClampsToMax() public view {
        uint160 nearMax = TickMath.MAX_SQRT_PRICE - 100;
        uint160 lim = h.limit(nearMax, 10_000, false);
        assertLe(lim, TickMath.MAX_SQRT_PRICE);
    }

    function test_limit_ZeroTwap_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.TwapStale.selector, 0));
        h.limit(0, SLIPPAGE_50_BPS, true);
    }

    // ─── Consistency between check and limit ────────────────────────────────

    function test_consistency_LimitMatchesCheckBoundary_ZeroForOne() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, true);
        h.check(lim, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_consistency_LimitMatchesCheckBoundary_OneForZero() public view {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, false);
        h.check(lim, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_consistency_BeyondLimitReverts_ZeroForOne() public {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, true);
        vm.expectRevert();
        h.check(lim - 1, ANCHOR, SLIPPAGE_50_BPS);
    }

    function test_consistency_BeyondLimitReverts_OneForZero() public {
        uint160 lim = h.limit(ANCHOR, SLIPPAGE_50_BPS, false);
        vm.expectRevert();
        h.check(lim + 1, ANCHOR, SLIPPAGE_50_BPS);
    }

    // ─── Fuzz: limit is always within sqrt-price domain ─────────────────────

    function testFuzz_limit_AlwaysInSqrtPriceDomain(
        uint160 twap,
        uint16 slipBps,
        bool zeroForOne
    ) public view {
        vm.assume(twap > TickMath.MIN_SQRT_PRICE && twap < TickMath.MAX_SQRT_PRICE);
        vm.assume(slipBps <= 10_000);

        uint160 lim = h.limit(twap, slipBps, zeroForOne);
        assertGe(lim, TickMath.MIN_SQRT_PRICE);
        assertLe(lim, TickMath.MAX_SQRT_PRICE);
    }

    // ─── Fuzz: check is symmetric in deviation direction ────────────────────

    function testFuzz_check_SymmetricInDirection(uint160 twap, uint16 slipBps, uint16 actualBpsDelta)
        public
        view
    {
        vm.assume(twap > TickMath.MIN_SQRT_PRICE * 2 && twap < TickMath.MAX_SQRT_PRICE / 2);
        vm.assume(slipBps > 0 && slipBps <= 1000);
        vm.assume(actualBpsDelta <= slipBps / 4);

        uint256 delta = (uint256(twap) * uint256(actualBpsDelta)) / 10_000;
        uint160 above = uint160(uint256(twap) + delta);
        uint160 below = uint160(uint256(twap) - delta);

        h.check(above, twap, slipBps);
        h.check(below, twap, slipBps);
    }
}
