// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {ICrossHedgeVault} from "../interfaces/ICrossHedgeVault.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title CrossHedgeHook
/// @notice Per-pool eyes-and-ears: emits structured events for the RSC, charges
///         a 3 bps entry premium on new LP positions, and pings the watchdog.
/// @dev Phase 0 stub. All callbacks return correct selectors so the contract
///      will pass v4's address-permission check after CREATE2 mining.
contract CrossHedgeHook is BaseHook, ICrossHedgeHook {
    using PoolIdLibrary for PoolKey;

    // ─── Immutables ─────────────────────────────────────────────────────────
    INettingRegistry public immutable nettingRegistry;
    address public immutable vault;
    uint16 public immutable premiumBps;

    // ─── Storage stubs ──────────────────────────────────────────────────────
    mapping(bytes32 => Position) internal _positions;
    uint256 public premiumBalance;

    constructor(
        IPoolManager _poolManager,
        INettingRegistry _registry,
        address _vault,
        uint16 _premiumBps
    ) BaseHook(_poolManager) {
        nettingRegistry = _registry;
        vault = _vault;
        premiumBps = _premiumBps;
    }

    // ─── Hook permission bitmap ─────────────────────────────────────────────
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 true,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               true,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            true,
            beforeSwap:                      true,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ─── Hook callbacks (stubs) ─────────────────────────────────────────────

    function _afterInitialize(
        address /*sender*/,
        PoolKey calldata /*key*/,
        uint160 /*sqrtPriceX96*/,
        int24 /*tick*/
    ) internal override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _afterRemoveLiquidity(
        address /*sender*/,
        PoolKey calldata /*key*/,
        ModifyLiquidityParams calldata /*params*/,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(
        address /*sender*/,
        PoolKey calldata /*key*/,
        SwapParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address /*sender*/,
        PoolKey calldata /*key*/,
        SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ─── ICrossHedgeHook surface ────────────────────────────────────────────

    function harvestPremiums(address /*to*/) external override {
        if (msg.sender != vault) revert Errors.HookOnly();
        // full implementation: poolManager.unlock(...) → take USDC → transfer
    }

    function getPosition(bytes32 posId)
        external
        view
        override
        returns (Position memory)
    {
        return _positions[posId];
    }

    function readTwapSqrtPrice(PoolId /*poolId*/, uint32 /*windowSeconds*/)
        external
        view
        override
        returns (uint160)
    {
        return 0;
    }
}
