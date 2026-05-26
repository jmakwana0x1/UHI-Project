// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title TwapBounded
/// @notice Slippage-bounding helpers anchored to a TWAP sqrt-price.
/// @dev Works directly in sqrt-price space to avoid an explicit square root.
///      For a price bound of `maxSlippageBps`, the sqrt-price bound is
///      `maxSlippageBps / 2` to first order (since price = sqrt_price²).
///      Implementation uses linear approximation: √(1+x) ≈ 1 + x/2 for small x.
///      Approximation error is O(x²/8); at 50 bps this is ~6.25e-8, far below
///      precision requirements.
///
///      All sqrt-prices are Q64.96 (uint160).
library TwapBounded {
    /// @notice Twice the bps denominator. Used because sqrt-space slippage
    ///         is half the price-space slippage.
    uint256 internal constant TWICE_BPS = uint256(Constants.BPS_DENOMINATOR) * 2;

    /// @notice Revert if the executed sqrt-price strays beyond `maxSlippageBps`
    ///         from the TWAP anchor.
    /// @param executionSqrtPriceX96 The sqrt-price observed after the swap.
    /// @param twapSqrtPriceX96      The TWAP anchor we measure against.
    /// @param maxSlippageBps        Max permitted price deviation, in bps
    ///                              (e.g., 50 = 0.50%).
    function checkSlippageAgainstTwap(
        uint160 executionSqrtPriceX96,
        uint160 twapSqrtPriceX96,
        uint16 maxSlippageBps
    ) internal pure {
        if (twapSqrtPriceX96 == 0) revert Errors.TwapStale(0);

        // Compute |exec - twap| as a uint256 (no underflow risk)
        uint256 delta = executionSqrtPriceX96 >= twapSqrtPriceX96
            ? uint256(executionSqrtPriceX96) - uint256(twapSqrtPriceX96)
            : uint256(twapSqrtPriceX96) - uint256(executionSqrtPriceX96);

        // Allowed sqrt-price deviation = twap * (maxSlippageBps / 20_000)
        //                              = twap * maxSlippageBps / (2 * BPS)
        uint256 allowedDelta =
            FullMath.mulDiv(uint256(twapSqrtPriceX96), uint256(maxSlippageBps), TWICE_BPS);

        if (delta > allowedDelta) {
            // Compute observed bps for the error payload (in price-space terms,
            // so double the sqrt-space ratio).
            uint256 observedSqrtBps =
                FullMath.mulDiv(delta, Constants.BPS_DENOMINATOR, uint256(twapSqrtPriceX96));
            uint256 observedPriceBps = observedSqrtBps * 2;
            revert Errors.SlippageExceeded(observedPriceBps, uint256(maxSlippageBps));
        }
    }

    /// @notice Compute a sqrtPriceLimitX96 that bounds an in-flight swap to
    ///         within `maxSlippageBps` (price-space) of the TWAP anchor.
    /// @param twapSqrtPriceX96 The TWAP anchor.
    /// @param maxSlippageBps   Max permitted price deviation, in bps.
    /// @param zeroForOne       Swap direction. true ⟹ price decreasing,
    ///                         limit is a lower bound. false ⟹ price
    ///                         increasing, limit is an upper bound.
    /// @return limit           Q64.96 sqrt-price limit to pass to
    ///                         poolManager.swap.
    function slippageLimitFromTwap(
        uint160 twapSqrtPriceX96,
        uint16 maxSlippageBps,
        bool zeroForOne
    ) internal pure returns (uint160 limit) {
        if (twapSqrtPriceX96 == 0) revert Errors.TwapStale(0);

        uint256 delta =
            FullMath.mulDiv(uint256(twapSqrtPriceX96), uint256(maxSlippageBps), TWICE_BPS);

        if (zeroForOne) {
            // Price moves down; floor the limit at v4's MIN_SQRT_PRICE+1.
            // (v4 requires limit > MIN_SQRT_PRICE when zeroForOne.)
            uint256 raw = uint256(twapSqrtPriceX96) - delta;
            uint256 floor_ = uint256(TickMath.MIN_SQRT_PRICE) + 1;
            limit = uint160(raw > floor_ ? raw : floor_);
        } else {
            // Price moves up; ceil the limit at v4's MAX_SQRT_PRICE-1.
            uint256 raw = uint256(twapSqrtPriceX96) + delta;
            uint256 ceil_ = uint256(TickMath.MAX_SQRT_PRICE) - 1;
            limit = uint160(raw < ceil_ ? raw : ceil_);
        }
    }
}
