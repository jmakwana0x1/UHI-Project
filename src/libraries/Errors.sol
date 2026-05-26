// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Errors
/// @notice Centralized custom errors. Per-contract errors are defined here so
///         that callers can decode errors without depending on contract files.
library Errors {
    // ─── Hook ───────────────────────────────────────────────────────────────
    error HookOnlyPoolManager();
    error UnregisteredPool();
    error PremiumDeductionFailed();
    error RingBufferOverflow();
    error TwapStale(uint64 ageSeconds);

    // ─── Registry ───────────────────────────────────────────────────────────
    error NotCallbackProxy();
    error WrongRvmId();
    error MatchAlreadyExists(bytes32 matchId);
    error PositionAlreadyMatched(bytes32 posId);
    error NotPositionOwner();
    error MatchNotActive();
    error RebateBelowDust();
    error NoFundsAvailable();

    // ─── Reactive ───────────────────────────────────────────────────────────
    error VmOnly();
    error RnOnly();
    error UnknownChain(uint256 chainId);
    error CycleGasExhausted();
    error InvalidAllocation();
    error AllocationExceedsAssets(uint256 requested, uint256 available);

    // ─── Vault ──────────────────────────────────────────────────────────────
    error PoolManagerOnly();
    error StrategyCallbackOnly();
    error HookOnly();
    error VaultPaused();
    error SwapExceedsBlockCap(uint256 requested, uint256 cap);
    error SlippageExceeded(uint256 observedBps, uint256 maxBps);
    error DeltaUnsettled(int128 amount0, int128 amount1);
    error PositionNotOwned(bytes32 posId);

    // ─── VaultProxy ─────────────────────────────────────────────────────────
    error NettingRegistryOnly();
    error InsufficientFloat(uint256 requested, uint256 available);

    // ─── Generic ────────────────────────────────────────────────────────────
    error Unauthorized();
    error ZeroAddress();
    error Unimplemented();
}
