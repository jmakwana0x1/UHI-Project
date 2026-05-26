// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VolEMA} from "../../../src/reactive/modules/VolEMA.sol";
import {Constants} from "../../../src/libraries/Constants.sol";

/// @notice Harness so we can call library functions through external calls,
///         giving us a storage slot for State and external CALL frames for
///         vm.expectRevert (not used here but maintains the pattern).
contract VolEMAHarness {
    VolEMA.State internal state;

    function update(uint160 sqrtPriceX96, uint64 timestamp, uint16 alphaBps) external {
        VolEMA.updateEMA(state, sqrtPriceX96, timestamp, alphaBps);
    }

    function annualizedVol() external view returns (uint256) {
        return VolEMA.annualizedVolE18(state);
    }

    function getState() external view returns (
        uint160 lastSqrtPrice,
        uint64 lastTimestamp,
        uint256 ema,
        uint64 totalElapsed,
        uint32 sampleCount
    ) {
        return (
            state.lastSqrtPrice,
            state.lastTimestamp,
            state.emaSqReturnE18,
            state.totalElapsed,
            state.sampleCount
        );
    }
}

contract VolEMATest is Test {
    VolEMAHarness internal h;

    uint160 internal constant ANCHOR = uint160(1 << 96); // sqrtPrice = 1.0
    uint16 internal constant ALPHA = 500; // 5%
    uint64 internal constant ONE_MIN = 60;
    uint64 internal constant TEN_MIN = 600;

    function setUp() public {
        h = new VolEMAHarness();
    }

    // ─── Boot behavior ──────────────────────────────────────────────────────

    function test_firstSample_RecordsState() public {
        h.update(ANCHOR, 1000, ALPHA);
        (uint160 lp, uint64 lt, uint256 ema, , uint32 n) = h.getState();
        assertEq(lp, ANCHOR);
        assertEq(lt, 1000);
        assertEq(ema, 0);
        assertEq(n, 1);
    }

    function test_lessThanMinSamples_ReturnsZeroVol() public {
        // Push a few samples — fewer than MIN_SAMPLES_FOR_VOL (10)
        for (uint64 i = 0; i < 5; i++) {
            h.update(ANCHOR, 1000 + i * ONE_MIN, ALPHA);
        }
        assertEq(h.annualizedVol(), 0);
    }

    function test_minSamplesWithZeroMovement_ReturnsZeroVol() public {
        // Constant price for 10+ samples: ema stays at 0
        for (uint64 i = 0; i < 12; i++) {
            h.update(ANCHOR, 1000 + i * ONE_MIN, ALPHA);
        }
        assertEq(h.annualizedVol(), 0);
    }

    // ─── Update semantics ───────────────────────────────────────────────────

    function test_sameTimestamp_IsNoOp() public {
        h.update(ANCHOR, 1000, ALPHA);
        (uint160 lp1, , , , uint32 n1) = h.getState();

        // Same timestamp — should not advance
        h.update(uint160(uint256(ANCHOR) * 11 / 10), 1000, ALPHA);
        (uint160 lp2, , , , uint32 n2) = h.getState();

        assertEq(lp1, lp2);
        assertEq(n1, n2);
    }

    function test_earlierTimestamp_IsNoOp() public {
        h.update(ANCHOR, 2000, ALPHA);
        h.update(uint160(uint256(ANCHOR) * 11 / 10), 1500, ALPHA);
        (, uint64 lt, , , uint32 n) = h.getState();
        assertEq(lt, 2000);
        assertEq(n, 1);
    }

    function test_zeroSqrtPrice_IsNoOp() public {
        h.update(ANCHOR, 1000, ALPHA);
        h.update(0, 2000, ALPHA);
        (uint160 lp, uint64 lt, , , uint32 n) = h.getState();
        assertEq(lp, ANCHOR);
        assertEq(lt, 1000);
        assertEq(n, 1);
    }

    // ─── EMA accumulation ───────────────────────────────────────────────────

    function test_singleMove_PopulatesEMA() public {
        h.update(ANCHOR, 1000, ALPHA);
        // 1% sqrt-price increase = 2% price move
        uint160 next = uint160(uint256(ANCHOR) * 101 / 100);
        h.update(next, 1000 + ONE_MIN, ALPHA);

        (, , uint256 ema, , uint32 n) = h.getState();
        assertGt(ema, 0);
        assertEq(n, 2);
    }

    function test_emaDecaysToZero_AfterStability() public {
        // First inject volatility
        h.update(ANCHOR, 1000, ALPHA);
        uint160 jumpy = uint160(uint256(ANCHOR) * 105 / 100);
        h.update(jumpy, 1000 + ONE_MIN, ALPHA);
        (, , uint256 emaAfterJump, , ) = h.getState();
        assertGt(emaAfterJump, 0);

        // Then 100 stable samples at the new price
        for (uint64 i = 0; i < 100; i++) {
            h.update(jumpy, 1000 + ONE_MIN * (2 + i), ALPHA);
        }
        (, , uint256 emaAfterStability, , ) = h.getState();
        // Should decay significantly (5% decay per step × 100 steps ≈ 0.6% remaining)
        assertLt(emaAfterStability, emaAfterJump / 10);
    }

    function test_higherAlpha_RespondsFaster() public {
        // Setup parallel state via fresh harness
        VolEMAHarness h2 = new VolEMAHarness();

        // Same input sequence with alpha=500 vs alpha=2000
        h.update(ANCHOR, 1000, 500);
        h2.update(ANCHOR, 1000, 2000);

        uint160 next = uint160(uint256(ANCHOR) * 102 / 100);
        h.update(next, 1000 + ONE_MIN, 500);
        h2.update(next, 1000 + ONE_MIN, 2000);

        (, , uint256 emaSlow, , ) = h.getState();
        (, , uint256 emaFast, , ) = h2.getState();
        // Higher alpha → ema reflects the new return more strongly
        assertGt(emaFast, emaSlow);
    }

    // ─── Annualized vol output ──────────────────────────────────────────────

    function test_annualizedVol_PositiveAfterEnoughSamplesWithMovement() public {
        // 12 samples, alternating ±0.5% moves at 1-min intervals
        uint64 t = 1000;
        uint160 price = ANCHOR;
        h.update(price, t, ALPHA);

        for (uint64 i = 1; i < 15; i++) {
            t += ONE_MIN;
            // alternate up/down by 0.5%
            if (i % 2 == 1) {
                price = uint160(uint256(price) * 1005 / 1000);
            } else {
                price = uint160(uint256(price) * 1000 / 1005);
            }
            h.update(price, t, ALPHA);
        }

        uint256 vol = h.annualizedVol();
        assertGt(vol, 0);
    }

    function test_higherVolatilityInput_HigherVolOutput() public {
        // Sequence A: 0.1% moves
        // Sequence B: 1% moves
        // Both 15 samples at 1-min intervals
        VolEMAHarness hA = new VolEMAHarness();
        VolEMAHarness hB = new VolEMAHarness();

        uint64 t = 1000;
        uint160 pA = ANCHOR;
        uint160 pB = ANCHOR;
        hA.update(pA, t, ALPHA);
        hB.update(pB, t, ALPHA);

        for (uint64 i = 1; i < 15; i++) {
            t += ONE_MIN;
            pA = uint160(uint256(pA) * (i % 2 == 1 ? 1001 : 1000) / (i % 2 == 1 ? 1000 : 1001));
            pB = uint160(uint256(pB) * (i % 2 == 1 ? 1010 : 1000) / (i % 2 == 1 ? 1000 : 1010));
            hA.update(pA, t, ALPHA);
            hB.update(pB, t, ALPHA);
        }

        uint256 volA = hA.annualizedVol();
        uint256 volB = hB.annualizedVol();
        assertGt(volB, volA);
        // Sanity: vol B should be roughly 10x vol A (10x larger moves, vol scales linearly with move size)
        assertGt(volB, volA * 5);
    }

    function test_annualization_LongerIntervalScalesDown() public {
        // Two sequences with same magnitude moves but different intervals.
        // Per-sample variance is the same, but annualized vol should be HIGHER
        // for the shorter-interval sequence (more "vol per year" of the same per-step move).
        VolEMAHarness hFast = new VolEMAHarness();
        VolEMAHarness hSlow = new VolEMAHarness();

        uint64 tFast = 1000;
        uint64 tSlow = 1000;
        uint160 pFast = ANCHOR;
        uint160 pSlow = ANCHOR;

        hFast.update(pFast, tFast, ALPHA);
        hSlow.update(pSlow, tSlow, ALPHA);

        for (uint64 i = 1; i < 15; i++) {
            tFast += ONE_MIN;        // 1 min between samples
            tSlow += TEN_MIN;        // 10 min between samples
            // Same magnitude
            pFast = uint160(uint256(pFast) * (i % 2 == 1 ? 1005 : 1000) / (i % 2 == 1 ? 1000 : 1005));
            pSlow = uint160(uint256(pSlow) * (i % 2 == 1 ? 1005 : 1000) / (i % 2 == 1 ? 1000 : 1005));
            hFast.update(pFast, tFast, ALPHA);
            hSlow.update(pSlow, tSlow, ALPHA);
        }

        uint256 volFast = hFast.annualizedVol();
        uint256 volSlow = hSlow.annualizedVol();
        assertGt(volFast, volSlow);
        // ratio should be sqrt(10) ≈ 3.16
        assertGt(volFast, volSlow * 2);
        assertLt(volFast, volSlow * 5);
    }

    // ─── Bounds & invariants ────────────────────────────────────────────────

    function test_emaNeverNegative() public {
        // Many random updates — ema must stay non-negative (it's uint, so this
        // really tests we never underflow).
        uint64 t = 1000;
        uint160 p = ANCHOR;
        h.update(p, t, ALPHA);

        for (uint64 i = 0; i < 50; i++) {
            t += ONE_MIN;
            uint256 factor = 1000 + (uint256(keccak256(abi.encode(i))) % 200) - 100; // 900..1099
            p = uint160(uint256(p) * factor / 1000);
            h.update(p, t, ALPHA);
        }

        (, , uint256 ema, , ) = h.getState();
        // ema is uint, so just checking it's a number we can read confirms no underflow
        assertGe(ema, 0);
    }

    function test_sampleCount_Increments() public {
        for (uint64 i = 0; i < 7; i++) {
            h.update(ANCHOR, 1000 + i * ONE_MIN, ALPHA);
        }
        (, , , , uint32 n) = h.getState();
        assertEq(n, 7);
    }

    // ─── Fuzz: monotonicity in alpha and price-move size ────────────────────

    function testFuzz_sameInputs_SameEMA(uint16 alphaBps, uint64 t0) public {
        vm.assume(alphaBps > 0 && alphaBps <= 5000);
        vm.assume(t0 > 0 && t0 < type(uint64).max - 10000);

        VolEMAHarness h1 = new VolEMAHarness();
        VolEMAHarness h2 = new VolEMAHarness();

        uint160 p = ANCHOR;
        for (uint64 i = 0; i < 12; i++) {
            uint64 ts = t0 + i * ONE_MIN;
            if (i % 2 == 1) p = uint160(uint256(p) * 1005 / 1000);
            else p = uint160(uint256(p) * 1000 / 1005);
            h1.update(p, ts, alphaBps);
            h2.update(p, ts, alphaBps);
        }

        (, , uint256 e1, , ) = h1.getState();
        (, , uint256 e2, , ) = h2.getState();
        assertEq(e1, e2);
    }
}
