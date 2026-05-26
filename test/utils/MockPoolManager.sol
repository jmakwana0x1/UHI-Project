// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @title MockPoolManager
/// @notice Minimal v4-PoolManager-compatible mock for hook unit tests.
/// @dev    Implements just enough of the PoolManager surface to invoke hook
///         callbacks as if a real PM had called them. Does NOT actually move
///         tokens, manage liquidity, or perform swaps. Hook return values are
///         captured for assertion.
///
///         Tests that need real swap/liquidity semantics use a real
///         PoolManager fork (Phase 2.4 / Phase 4).
contract MockPoolManager {
    using PoolIdLibrary for PoolKey;

    // ─── State exposed for hook reads ───────────────────────────────────────

    // poolId => packed slot0 (sqrtPriceX96 in lower 160 bits, tick in next 24)
    mapping(bytes32 => bytes32) public slots;

    // Last hook return values captured (for assertions)
    bytes4 public lastSelector;
    BalanceDelta public lastBalanceDelta;
    BeforeSwapDelta public lastBeforeSwapDelta;
    uint24 public lastLpFeeOverride;
    int128 public lastInt128Return;

    // ─── extsload (StateLibrary-compatible reads) ───────────────────────────

    function extsload(bytes32 slot) external view returns (bytes32) {
        return slots[slot];
    }

    /// @notice Test helper: directly set the slot0 for a pool.
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick) external {
        // StateLibrary packs:  [24b fee | 24b protocolFee | 24b tick | 160b sqrtPriceX96]
        // We only need sqrtPriceX96 + tick. Compute the same slot key StateLibrary uses.
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        bytes32 packed = bytes32(uint256(sqrtPriceX96))
            | (bytes32(uint256(uint24(tick))) << 160);
        slots[stateSlot] = packed;
    }

    /// @dev Mirrors StateLibrary's _getPoolStateSlot.
    ///      Pools mapping is at slot 6 in PoolManager. (May change across v4 versions —
    ///      check StateLibrary if mocks behave oddly.)
    uint256 internal constant POOLS_SLOT = 6;

    function _getPoolStateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), POOLS_SLOT));
    }

    // ─── Hook invocation helpers ────────────────────────────────────────────

    function callAfterInitialize(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) external returns (bytes4 selector) {
        selector = hook.afterInitialize(sender, key, sqrtPriceX96, tick);
        lastSelector = selector;
    }

    function callAfterAddLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4 selector, BalanceDelta hookDelta) {
        (selector, hookDelta) = hook.afterAddLiquidity(
            sender, key, params, delta, feesAccrued, hookData
        );
        lastSelector = selector;
        lastBalanceDelta = hookDelta;
    }

    function callAfterRemoveLiquidity(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external returns (bytes4 selector, BalanceDelta hookDelta) {
        (selector, hookDelta) = hook.afterRemoveLiquidity(
            sender, key, params, delta, feesAccrued, hookData
        );
        lastSelector = selector;
        lastBalanceDelta = hookDelta;
    }

    function callBeforeSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4 selector, BeforeSwapDelta delta, uint24 lpFeeOverride) {
        (selector, delta, lpFeeOverride) = hook.beforeSwap(sender, key, params, hookData);
        lastSelector = selector;
        lastBeforeSwapDelta = delta;
        lastLpFeeOverride = lpFeeOverride;
    }

    function callAfterSwap(
        IHooks hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4 selector, int128 hookReturn) {
        (selector, hookReturn) = hook.afterSwap(sender, key, params, delta, hookData);
        lastSelector = selector;
        lastInt128Return = hookReturn;
    }

    // ─── No-op stubs for other IPoolManager surface (hook may call these) ───

    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function take(Currency, address, uint256) external pure {}
    function settle() external payable returns (uint256) { return 0; }
    function sync(Currency) external pure {}
}
