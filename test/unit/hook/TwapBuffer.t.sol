// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TwapBuffer} from "../../../src/hook/TwapBuffer.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

/// @notice Harness exposing the library via external calls so vm.expectRevert
///         works and so the State has a real storage slot.
contract TwapBufferHarness {
    TwapBuffer.Snapshot[256] internal buf;
    uint32 internal head;

    function push(uint160 sqrtPriceX96, uint64 timestamp) external {
        head = TwapBuffer.push(buf, head, sqrtPriceX96, timestamp);
    }

    function mean(uint32 windowSeconds, uint64 nowTs)
        external
        view
        returns (uint160 meanSqrt, uint32 sampleCount, uint64 oldestTs)
    {
        return TwapBuffer.meanSqrtPrice(buf, head, windowSeconds, nowTs);
    }

    function meanWithFreshness(uint32 windowSeconds, uint64 nowTs, uint32 minSamples)
        external
        view
        returns (uint160)
    {
        return TwapBuffer.meanSqrtPriceWithFreshnessCheck(buf, head, windowSeconds, nowTs, minSamples);
    }

    function getHead() external view returns (uint32) {
        return head;
    }

    function getSlot(uint32 i) external view returns (uint160, uint64) {
        return (buf[i].sqrtPriceX96, buf[i].timestamp);
    }
}

contract TwapBufferTest is Test {
    TwapBufferHarness internal h;

    uint160 internal constant P = uint160(1 << 96);
    uint64 internal constant T0 = 1_000_000;
    uint32 internal constant WIN_30M = 30 * 60;
    uint32 internal constant WIN_5M = 5 * 60;
    uint32 internal constant WIN_1H = 60 * 60;

    function setUp() public {
        h = new TwapBufferHarness();
    }

    // ─── push semantics ─────────────────────────────────────────────────────

    function test_emptyBuffer_HeadAtZero() public view {
        assertEq(h.getHead(), 0);
    }

    function test_push_AdvancesHead() public {
        h.push(P, T0);
        assertEq(h.getHead(), 1);
        h.push(P, T0 + 60);
        assertEq(h.getHead(), 2);
    }

    function test_push_WritesAtCorrectSlot() public {
        h.push(P, T0);
        (uint160 sp, uint64 ts) = h.getSlot(0);
        assertEq(sp, P);
        assertEq(ts, T0);
    }

    function test_push_Wraps_AtSize() public {
        // Push 257 times — slot 0 should be overwritten.
        for (uint32 i = 0; i < 257; i++) {
            h.push(uint160(uint256(P) + i), T0 + i * 60);
        }
        // After 257 pushes, head is at 257; slot 0 was overwritten by the 257th push (i=256)
        (uint160 sp, uint64 ts) = h.getSlot(0);
        assertEq(sp, uint160(uint256(P) + 256));
        assertEq(ts, T0 + 256 * 60);
        assertEq(h.getHead(), 257);
    }

    // ─── mean: empty/edge cases ─────────────────────────────────────────────

    function test_mean_EmptyBuffer_ReturnsZero() public view {
        (uint160 m, uint32 n, uint64 o) = h.mean(WIN_30M, T0);
        assertEq(m, 0);
        assertEq(n, 0);
        assertEq(o, 0);
    }

    function test_mean_OneSampleInsideWindow() public {
        h.push(P, T0);
        (uint160 m, uint32 n, uint64 o) = h.mean(WIN_30M, T0 + 60);
        assertEq(m, P);
        assertEq(n, 1);
        assertEq(o, T0);
    }

    function test_mean_OneSampleOutsideWindow_ReturnsZero() public {
        h.push(P, T0);
        // Window is 5 min, sample is 10 min old → outside
        (uint160 m, uint32 n, uint64 o) = h.mean(WIN_5M, T0 + 600);
        assertEq(m, 0);
        assertEq(n, 0);
        assertEq(o, 0);
    }

    // ─── mean: basic arithmetic ─────────────────────────────────────────────

    function test_mean_TwoEqualSamples_ReturnsSame() public {
        h.push(P, T0);
        h.push(P, T0 + 60);
        (uint160 m, uint32 n,) = h.mean(WIN_30M, T0 + 120);
        assertEq(m, P);
        assertEq(n, 2);
    }

    function test_mean_TwoSamples_ArithmeticAverage() public {
        uint160 p1 = uint160(uint256(P) * 100 / 100); // P
        uint160 p2 = uint160(uint256(P) * 102 / 100); // 1.02 * P
        h.push(p1, T0);
        h.push(p2, T0 + 60);
        (uint160 m, uint32 n,) = h.mean(WIN_30M, T0 + 120);
        // arithmetic mean = (p1 + p2) / 2
        uint160 expected = uint160((uint256(p1) + uint256(p2)) / 2);
        assertEq(m, expected);
        assertEq(n, 2);
    }

    function test_mean_ThreeSamples() public {
        uint160 p1 = uint160(uint256(P) * 99 / 100);
        uint160 p2 = P;
        uint160 p3 = uint160(uint256(P) * 101 / 100);
        h.push(p1, T0);
        h.push(p2, T0 + 60);
        h.push(p3, T0 + 120);
        (uint160 m, uint32 n,) = h.mean(WIN_30M, T0 + 180);
        uint160 expected = uint160((uint256(p1) + uint256(p2) + uint256(p3)) / 3);
        assertEq(m, expected);
        assertEq(n, 3);
    }

    // ─── mean: window selection ─────────────────────────────────────────────

    function test_mean_OldSamplesExcluded() public {
        // Push 5 samples 10 min apart; ask for 30-min window from latest
        // → should include only last 4 samples (latest, -10m, -20m, -30m at boundary)
        // Boundary case: sample exactly at cutoff IS included (timestamp >= cutoff).
        h.push(uint160(uint256(P) * 90 / 100), T0);          // 40 min before "now"
        h.push(uint160(uint256(P) * 95 / 100), T0 + 600);    // 30 min before
        h.push(uint160(uint256(P) * 100 / 100), T0 + 1200);  // 20 min before
        h.push(uint160(uint256(P) * 105 / 100), T0 + 1800);  // 10 min before
        h.push(uint160(uint256(P) * 110 / 100), T0 + 2400);  // 0 min before (= now)
        uint64 nowTs = T0 + 2400;

        (uint160 m, uint32 n, uint64 oldest) = h.mean(WIN_30M, nowTs);
        // cutoff = nowTs - 1800 = T0 + 600 → sample at T0+600 included; T0 NOT included
        assertEq(n, 4);
        assertEq(oldest, T0 + 600);
        uint256 expectedSum = uint256(uint160(uint256(P) * 95 / 100))
                            + uint256(uint160(uint256(P) * 100 / 100))
                            + uint256(uint160(uint256(P) * 105 / 100))
                            + uint256(uint160(uint256(P) * 110 / 100));
        assertEq(m, uint160(expectedSum / 4));
    }

    function test_mean_SmallerWindowSelectsFewer() public {
        h.push(P, T0);
        h.push(P, T0 + 60);
        h.push(P, T0 + 120);
        h.push(P, T0 + 180);
        h.push(P, T0 + 240);
        uint64 nowTs = T0 + 240;

        // 2-min window: cutoff = nowTs - 120 = T0 + 120 → samples at +120, +180, +240
        (uint160 m, uint32 n,) = h.mean(120, nowTs);
        assertEq(n, 3);
        assertEq(m, P);
    }

    // ─── mean: ring-wrap correctness ────────────────────────────────────────

    function test_mean_AfterWrap_StillCorrect() public {
        // Fill the buffer with 300 samples; final mean should only consider
        // samples within the last 30 minutes regardless of wrap-around.
        for (uint32 i = 0; i < 300; i++) {
            h.push(P, T0 + i * 60);
        }
        // Last sample at T0 + 299*60 = T0 + 17940 (~5 hrs after start)
        uint64 nowTs = T0 + 299 * 60;
        (uint160 m, uint32 n,) = h.mean(WIN_30M, nowTs);
        // 30 min = 1800 s; samples every 60 s → up to 31 samples within window
        // (cutoff is inclusive: samples at nowTs - 1800, ..., nowTs)
        assertEq(n, 31);
        assertEq(m, P);
    }

    function test_mean_FullBuffer_RingDoesNotCorrupt() public {
        // Fill exactly 256 distinct prices, then read back
        for (uint32 i = 0; i < 256; i++) {
            h.push(uint160(uint256(P) + i), T0 + i * 60);
        }
        (uint160 m, uint32 n,) = h.mean(60 * 256, T0 + 256 * 60);
        // All 256 samples within window
        assertEq(n, 256);
        // mean = P + average of 0..255 = P + 127.5 → P + 127 (integer floor)
        uint256 expectedSum = 0;
        for (uint32 i = 0; i < 256; i++) {
            expectedSum += uint256(P) + i;
        }
        assertEq(m, uint160(expectedSum / 256));
    }

    // ─── freshness check ────────────────────────────────────────────────────

    function test_freshness_EmptyBuffer_Reverts() public {
        vm.expectRevert();
        h.meanWithFreshness(WIN_30M, T0, 4);
    }

    function test_freshness_TooFewSamples_Reverts() public {
        h.push(P, T0);
        h.push(P, T0 + 60);
        vm.expectRevert();
        h.meanWithFreshness(WIN_30M, T0 + 120, 4);
    }

    function test_freshness_EnoughSamples_Returns() public {
        for (uint32 i = 0; i < 5; i++) {
            h.push(P, T0 + i * 60);
        }
        uint160 m = h.meanWithFreshness(WIN_30M, T0 + 240, 4);
        assertEq(m, P);
    }

    // ─── Unfilled-slot tolerance ────────────────────────────────────────────

    function test_unfilledSlots_DontPollute() public {
        // Buffer starts empty (all timestamps = 0); push 3 samples, request
        // mean over a wide window. Should only count the 3.
        h.push(P, T0);
        h.push(P, T0 + 60);
        h.push(P, T0 + 120);

        (uint160 m, uint32 n,) = h.mean(WIN_1H, T0 + 240);
        assertEq(n, 3);
        assertEq(m, P);
    }

    // ─── Fuzz: monotone-time pushes preserve count up to SIZE ───────────────

    function testFuzz_pushCount_BoundedBySize(uint8 nPushes) public {
        for (uint8 i = 0; i < nPushes; i++) {
            h.push(P, T0 + uint64(i) * 60);
        }
        assertEq(h.getHead(), nPushes);
        // mean over a huge window should see min(nPushes, 256)
        (uint160 m, uint32 n,) = h.mean(type(uint32).max, T0 + uint64(nPushes) * 60);
        uint32 expected = nPushes > 0 ? (nPushes <= 256 ? uint32(nPushes) : 256) : 0;
        assertEq(n, expected);
        if (n > 0) assertEq(m, P);
    }

    function testFuzz_meanWithinSamples(uint160 minP, uint160 maxP) public {
        vm.assume(minP > 0 && maxP > minP);
        vm.assume(uint256(maxP) - uint256(minP) < uint256(P)); // keep variation reasonable

        h.push(minP, T0);
        h.push(maxP, T0 + 60);
        (uint160 m,,) = h.mean(WIN_30M, T0 + 120);
        // Mean is between the two
        assertGe(m, minP);
        assertLe(m, maxP);
    }
}
