// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title VolEMA
/// @notice Rolling realized-vol estimator using EMA of squared log-returns.
/// @dev Phase 0 stub. Full implementations land in Phase 3.
library VolEMA {
    struct State {
        uint160 lastSqrtPrice;
        uint64 lastTimestamp;
        int256 emaLogReturnSq;
        uint32 sampleCount;
    }

    function updateEMA(
        State storage state,
        uint160 sqrtPriceX96,
        uint64 timestamp,
        uint16 alphaBps
    ) internal {
        state; sqrtPriceX96; timestamp; alphaBps;
        // no-op stub
    }

    function annualizedVolE18(State storage state) internal view returns (uint256) {
        state;
        return 0;
    }
}
