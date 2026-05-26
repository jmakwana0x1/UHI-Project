// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ICrossHedgeHook
/// @notice External surface of CrossHedgeHook exposed to other protocol contracts.
///         Standard v4 hook callbacks are exposed via IHooks; this interface only
///         lists non-hook entry points.
interface ICrossHedgeHook {
    struct Position {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        bool unhedged;
        uint128 liquidity;
        uint64 openedAt;
        PoolId poolId;
    }

    /// @notice Drain the hook's accumulated premium ledger into the vault.
    /// @dev Callable only by the configured vault. Performs poolManager.unlock
    ///      to convert the hook's positive USDC delta into a real transfer.
    function harvestPremiums(address to) external;

    /// @notice Get the stored position record for a given posId.
    function getPosition(bytes32 posId) external view returns (Position memory);

    /// @notice Read the geometric-mean TWAP sqrt-price over a window.
    /// @return sqrtPriceX96 The Q64.96 sqrt-price.
    function readTwapSqrtPrice(PoolId poolId, uint32 windowSeconds)
        external
        view
        returns (uint160 sqrtPriceX96);
}
