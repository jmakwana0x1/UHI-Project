// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal LP router for adding liquidity to a v4 pool that has the
///         CrossHedge hook installed. Used for smoke testing live deployments.
///
/// @dev    THIS IS NOT PRODUCTION-READY for real-USDC scenarios. It uses an
///         optimistic pre-seed pattern (`safeTransfer 100M tokens → settle`)
///         that only works when tokens have open mint (i.e. MockERC20 test
///         tokens). The pre-seed is needed so the hook's `take()` for premium
///         collection has tokens to claim from.
///
///         In production, the vault is the first LP and the hook skips
///         premium charging on `isVaultSender=true`. After that bootstrap,
///         subsequent LPs satisfy the take through normal modifyLiquidity
///         token flow. This router is for the testing case where there's no
///         vault-first bootstrap.
contract LPRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;

    constructor(IPoolManager _pm) {
        pm = _pm;
    }

    struct AddLiqArgs {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    /// @notice Adds liquidity through the v4 PoolManager unlock pattern.
    ///         Caller must have approved this router for both currencies
    ///         AND the router must hold at least the pre-seed amount of
    ///         both tokens (use MockERC20.mint or transfer from a held
    ///         balance before calling).
    function addLiquidity(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        int256 liquidityDelta
    ) external {
        bytes memory data = abi.encode(AddLiqArgs(key, tickLower, tickUpper, liquidityDelta));
        pm.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "LPRouter: only pm");
        AddLiqArgs memory a = abi.decode(data, (AddLiqArgs));

        // Pre-seed PM with tokens so the hook's take() can succeed.
        // We pre-seed and reclaim the surplus at end-of-unlock.
        uint256 seedAmount = 100_000_000e6;
        pm.sync(a.key.currency0);
        IERC20(Currency.unwrap(a.key.currency0)).safeTransfer(address(pm), seedAmount);
        pm.settle();

        pm.sync(a.key.currency1);
        IERC20(Currency.unwrap(a.key.currency1)).safeTransfer(address(pm), seedAmount);
        pm.settle();

        ModifyLiquidityParams memory mp = ModifyLiquidityParams({
            tickLower: a.tickLower,
            tickUpper: a.tickUpper,
            liquidityDelta: a.liquidityDelta,
            salt: bytes32(0)
        });
        pm.modifyLiquidity(a.key, mp, "");

        _settle(a.key.currency0);
        _settle(a.key.currency1);

        return "";
    }

    function _settle(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        if (d < 0) {
            uint256 owed = uint256(-d);
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(pm), owed);
            pm.settle();
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
        }
    }
}
