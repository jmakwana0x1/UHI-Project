// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title ICrossHedgeHook
/// @notice External surface of CrossHedgeHook exposed to other protocol contracts.
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
    /// @dev Callable only by the configured vault.
    function harvestPremiums(address to) external returns (uint256 amount);

    /// @notice Get the stored position record for a given posId.
    function getPosition(bytes32 posId) external view returns (Position memory);

    /// @notice Get the current accumulated premium balance held by the hook.
    function premiumBalance() external view returns (uint256);

    /// @notice Address of the vault (used by registry to verify hook config).
    function vault() external view returns (address);

    /// @notice Read the TWAP sqrt-price over a window from the hook's ring buffer.
    /// @param poolId The pool to read.
    /// @param windowSeconds Lookback window in seconds.
    /// @return meanSqrt The arithmetic-mean sqrt-price (Q64.96) over the window.
    /// @return sampleCount Number of snapshots that fell within the window.
    function readTwapSqrtPrice(PoolId poolId, uint32 windowSeconds)
        external
        view
        returns (uint160 meanSqrt, uint32 sampleCount);
}
