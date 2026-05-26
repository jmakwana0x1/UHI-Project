// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {MockPoolManager} from "./MockPoolManager.sol";
import {MockERC20} from "./MockERC20.sol";
import {HookDeployer} from "./HookDeployer.sol";

/// @title BaseTest
/// @notice Common fixtures shared across CrossHedge tests.
///         Tests inherit from this for the mock PM + USDC/WETH tokens.
abstract contract BaseTest is Test {
    MockPoolManager internal pm;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal vault = makeAddr("vault");
    address internal callbackProxy = makeAddr("callbackProxy");
    address internal matchingRvm = makeAddr("matchingRvm");

    /// @notice Standard hook flags for CrossHedgeHook.
    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG                  |
        Hooks.AFTER_ADD_LIQUIDITY_FLAG               |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG            |
        Hooks.BEFORE_SWAP_FLAG                       |
        Hooks.AFTER_SWAP_FLAG                        |
        Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function _baseSetUp() internal {
        pm = new MockPoolManager();
        // Deterministic addresses: deploy USDC first so it's address < WETH.
        // Mine until USDC < WETH so USDC = token0 in PoolKey.
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        // If addresses happen the wrong way around we tolerate it — the hook
        // is parameterized by usdcIsToken0 via constructor.
    }
}
