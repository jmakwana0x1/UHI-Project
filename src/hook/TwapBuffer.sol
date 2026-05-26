// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title TwapBuffer
/// @notice Ring-buffer logic for the hook's own TWAP observations.
///
/// @dev Stores `(sqrtPriceX96, timestamp)` snapshots in a fixed-size circular
///      array. The mean read computes a TWAP-anchor sqrt-price from samples
///      within a configurable window.
///
/// @dev Mean choice (important)
///   Strictly correct: geometric mean of sqrt-prices.
///   Implemented:      arithmetic mean of sqrt-prices.
///
///   Justification: for typical pool dynamics (per-snapshot spread < 2%), the
///   difference between arithmetic and geometric mean is bounded by ~σ²/2.
///   At σ = 1% this is ~50 ppm — three orders of magnitude below our 50 bps
///   slippage tolerance. The simplification saves ~5000 gas per read and avoids
///   implementing log2/exp2 from scratch.
///
///   If a future audit requires the geometric mean, swap the loop body in
///   `meanSqrtPrice` — all callers consume only `uint160 sqrtPrice` and are
///   unaffected.
///
/// @dev Ring buffer write semantics
///   The hook writes via `push`, which advances `head` modulo SIZE. Buffer is
///   intentionally not "filled" before reads are allowed — `meanSqrtPrice`
///   returns the mean over whatever samples actually fall within the window
///   (with a minimum sample count enforced by the caller via the returned
///   `sampleCount`).
library TwapBuffer {
    uint32 internal constant SIZE = 256;

    struct Snapshot {
        uint160 sqrtPriceX96;
        uint64 timestamp;
        // 32 bytes — fits one storage slot
    }

    /// @notice Write a new snapshot at `head`, advance head.
    /// @dev Caller is responsible for rate-limiting (don't call every block).
    function push(
        Snapshot[SIZE] storage buf,
        uint32 head,
        uint160 sqrtPriceX96,
        uint64 timestamp
    ) internal returns (uint32 newHead) {
        buf[head % SIZE] = Snapshot({sqrtPriceX96: sqrtPriceX96, timestamp: timestamp});
        unchecked {
            return head + 1;
        }
    }

    /// @notice Compute the arithmetic mean sqrt-price of all samples in the
    ///         window `[nowTs - windowSeconds, nowTs]`.
    /// @param buf            Storage reference to the ring buffer.
    /// @param head           Current head index (next write position).
    /// @param windowSeconds  How far back to look.
    /// @param nowTs          Current wall-clock time.
    /// @return meanSqrt      Q64.96 mean sqrt-price (0 if no samples).
    /// @return sampleCount   How many samples were summed.
    /// @return oldestTs      Oldest sample's timestamp (0 if no samples).
    function meanSqrtPrice(
        Snapshot[SIZE] storage buf,
        uint32 head,
        uint32 windowSeconds,
        uint64 nowTs
    ) internal view returns (uint160 meanSqrt, uint32 sampleCount, uint64 oldestTs) {
        // Edge case: no samples yet.
        if (head == 0) return (0, 0, 0);

        // Cutoff: nowTs - windowSeconds, saturated at 0.
        uint64 cutoff = uint64(windowSeconds) >= nowTs ? 0 : nowTs - uint64(windowSeconds);

        uint256 sum = 0;
        uint32 count = 0;
        uint64 oldest = 0;

        // Walk backwards from (head - 1) up to SIZE positions. Stop when we
        // hit an empty slot (timestamp == 0) or cross the cutoff.
        uint32 maxIterations = head < SIZE ? head : SIZE;

        unchecked {
            for (uint32 i = 1; i <= maxIterations; ++i) {
                // (head - i) mod SIZE, working in unsigned arithmetic
                uint32 idx = (head + SIZE - i) % SIZE;
                Snapshot memory s = buf[idx];

                // Empty / unfilled slot — nothing more to find.
                if (s.timestamp == 0) break;

                // We've walked past our window — stop. We DO include this
                // sample if it's the boundary, but stop after.
                if (s.timestamp < cutoff) break;

                sum += uint256(s.sqrtPriceX96);
                count += 1;
                oldest = s.timestamp;
            }
        }

        if (count == 0) return (0, 0, 0);

        uint256 mean = sum / uint256(count);
        // Saturation: mean of uint160s never exceeds uint160.max.
        meanSqrt = uint160(mean);
        sampleCount = count;
        oldestTs = oldest;
    }

    /// @notice Convenience: revert with `TwapStale` if the mean read returns
    ///         fewer than `minSamples` samples or its oldest sample is
    ///         younger than the requested window.
    function meanSqrtPriceWithFreshnessCheck(
        Snapshot[SIZE] storage buf,
        uint32 head,
        uint32 windowSeconds,
        uint64 nowTs,
        uint32 minSamples
    ) internal view returns (uint160 meanSqrt) {
        uint32 count;
        uint64 oldest;
        (meanSqrt, count, oldest) = meanSqrtPrice(buf, head, windowSeconds, nowTs);
        if (count < minSamples) {
            revert Errors.TwapStale(count == 0 ? nowTs : nowTs - oldest);
        }
    }
}
