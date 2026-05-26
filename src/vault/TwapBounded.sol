// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title TwapBounded
/// @notice Slippage-bounding helpers anchored to a TWAP sqrt-price.
/// @dev Phase 0 stub. Full implementations land in Phase 4.
library TwapBounded {
    /// @notice Revert if execution sqrt-price strays beyond max bps from TWAP.
    function checkSlippageAgainstTwap(
        uint160 executionSqrtPriceX96,
        uint160 twapSqrtPriceX96,
        uint16 maxSlippageBps
    ) internal pure {
        executionSqrtPriceX96; twapSqrtPriceX96; maxSlippageBps;
        // no-op stub
    }

    /// @notice Compute a sqrtPriceLimit that bounds a swap to within slippage of TWAP.
    function slippageLimitFromTwap(
        uint160 twapSqrtPriceX96,
        uint16 maxSlippageBps,
        bool zeroForOne
    ) internal pure returns (uint160 limit) {
        twapSqrtPriceX96; maxSlippageBps; zeroForOne;
        return 0;
    }
}
