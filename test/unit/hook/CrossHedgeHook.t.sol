// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {BaseTest} from "../../utils/BaseTest.sol";
import {HookDeployer} from "../../utils/HookDeployer.sol";
import {CrossHedgeHook} from "../../../src/hook/CrossHedgeHook.sol";
import {ICrossHedgeHook} from "../../../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {Constants} from "../../../src/libraries/Constants.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {PositionIdLib} from "../../../src/libraries/PositionIdLib.sol";

/// @notice Minimal NettingRegistry mock that lets tests control matchingActive
///         and counts pingWatchdog calls.
contract MockNettingRegistry {
    bool public matchingActive = true;
    uint256 public pingCount;

    function pingWatchdog() external {
        pingCount += 1;
    }

    function setMatchingActive(bool v) external {
        matchingActive = v;
    }
}

contract CrossHedgeHookTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    CrossHedgeHook internal hook;
    MockNettingRegistry internal registry;

    PoolKey internal key;
    PoolId internal poolId;

    // Standard sqrtPrice for price = 1.0
    uint160 internal constant SQRT_ONE = uint160(1 << 96);

    function setUp() public {
        _baseSetUp();

        registry = new MockNettingRegistry();

        // Ensure USDC < WETH for deterministic token0/token1 ordering.
        // If not, swap them via redeployment with deterministic addresses.
        bool usdcIsToken0_;
        if (address(usdc) < address(weth)) {
            usdcIsToken0_ = true;
        } else {
            usdcIsToken0_ = false;
        }

        // Mine the hook address that matches HOOK_FLAGS.
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(pm)),
            INettingRegistry(address(registry)),
            vault,
            uint16(30), // 30 bps premium
            usdcIsToken0_
        );

        (address hookAddr, bytes32 salt) = HookDeployer.mine(
            HOOK_FLAGS,
            type(CrossHedgeHook).creationCode,
            constructorArgs
        );

        // Deploy via the canonical CREATE2 deployer (0x4e59...) explicitly.
        // We can't use `new Contract{salt:}` because that uses `address(this)`
        // as the deployer in Foundry, while HookMiner.find assumes 0x4e59...
        bytes memory deployCode = abi.encodePacked(
            type(CrossHedgeHook).creationCode,
            constructorArgs
        );
        bytes memory deployPayload = abi.encodePacked(salt, deployCode);
        (bool ok, bytes memory ret) = HookDeployer.CREATE2_DEPLOYER.call(deployPayload);
        require(ok, "CREATE2 deploy failed");
        address deployedAddr;
        if (ret.length >= 20) {
            assembly { deployedAddr := mload(add(ret, 20)) }
        } else {
            deployedAddr = hookAddr; // some CREATE2 deployers return empty
        }
        hook = CrossHedgeHook(hookAddr);
        require(address(hook).code.length > 0, "Hook not deployed");
        require(address(hook) == hookAddr, "Hook address mismatch");

        // Build PoolKey
        Currency c0 = usdcIsToken0_
            ? Currency.wrap(address(usdc))
            : Currency.wrap(address(weth));
        Currency c1 = usdcIsToken0_
            ? Currency.wrap(address(weth))
            : Currency.wrap(address(usdc));

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // Initialize the pool's slot0 in the mock PM
        pm.setSlot0(poolId, SQRT_ONE, 0);

        // Trigger hook's afterInitialize manually
        vm.warp(1_000_000);
        pm.callAfterInitialize(IHooks(address(hook)), address(this), key, SQRT_ONE, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          afterInitialize
    // ═══════════════════════════════════════════════════════════════════════

    function test_afterInitialize_RegistersPool() public view {
        (bool registered, , , , , ) = hook.poolStates(poolId);
        assertTrue(registered);
    }

    function test_afterInitialize_SetsInitialState() public view {
        (
            ,
            uint16 threshold,
            int24 lastTick,
            uint160 lastSqrtP,
            uint64 lastTs,
            uint32 head
        ) = hook.poolStates(poolId);

        assertEq(threshold, Constants.DEFAULT_LARGE_MOVE_TICK_THRESHOLD);
        assertEq(lastTick, int24(0));
        assertEq(lastSqrtP, SQRT_ONE);
        assertEq(lastTs, uint64(block.timestamp));
        assertEq(head, 1); // one snapshot pushed
    }

    function test_afterInitialize_ReturnsSelector() public {
        bytes4 sel = pm.callAfterInitialize(
            IHooks(address(hook)), address(this), key, SQRT_ONE, 0
        );
        assertEq(sel, IHooks.afterInitialize.selector);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         afterAddLiquidity
    // ═══════════════════════════════════════════════════════════════════════

    function _defaultAddParams() internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(1e18),
            salt: bytes32(0)
        });
    }

    function _encodeHookData(address owner_, uint8 horizon)
        internal pure returns (bytes memory)
    {
        return abi.encode(owner_, horizon);
    }

    function test_afterAddLiquidity_Hedged_ChargesPremium() public {
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        (bytes4 sel, BalanceDelta hookDelta) = pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice,
            key,
            params,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        assertEq(sel, IHooks.afterAddLiquidity.selector);
        // hookDelta should be positive on USDC side
        if (address(usdc) < address(weth)) {
            assertGt(int256(BalanceDeltaLibrary.amount0(hookDelta)), 0);
            assertEq(int256(BalanceDeltaLibrary.amount1(hookDelta)), 0);
        } else {
            assertEq(int256(BalanceDeltaLibrary.amount0(hookDelta)), 0);
            assertGt(int256(BalanceDeltaLibrary.amount1(hookDelta)), 0);
        }
        assertGt(hook.premiumBalance(), 0);
    }

    function test_afterAddLiquidity_Unhedged_NoPremium() public {
        registry.setMatchingActive(false);

        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        (bytes4 sel, BalanceDelta hookDelta) = pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice,
            key,
            params,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        assertEq(sel, IHooks.afterAddLiquidity.selector);
        assertEq(int256(BalanceDeltaLibrary.amount0(hookDelta)), 0);
        assertEq(int256(BalanceDeltaLibrary.amount1(hookDelta)), 0);
        assertEq(hook.premiumBalance(), 0);
    }

    function test_afterAddLiquidity_VaultSender_NoPremium() public {
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(vault, 1);

        (, BalanceDelta hookDelta) = pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            vault, // sender = vault
            key,
            params,
            BalanceDeltaLibrary.ZERO_DELTA,
            BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        assertEq(int256(BalanceDeltaLibrary.amount0(hookDelta)), 0);
        assertEq(int256(BalanceDeltaLibrary.amount1(hookDelta)), 0);
        assertEq(hook.premiumBalance(), 0);
    }

    function test_afterAddLiquidity_PingsWatchdog() public {
        uint256 before = registry.pingCount();
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );
        assertEq(registry.pingCount(), before + 1);
    }

    function test_afterAddLiquidity_StoresPositionRecord() public {
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        bytes32 posId = PositionIdLib.compute(poolId, alice, -600, 600, bytes32(0));
        ICrossHedgeHook.Position memory p = hook.getPosition(posId);
        assertEq(p.owner, alice);
        assertEq(p.tickLower, int24(-600));
        assertEq(p.tickUpper, int24(600));
        assertEq(p.liquidity, 1e18);
        assertFalse(p.unhedged);
    }

    function test_afterAddLiquidity_UnhedgedFlag_WhenWatchdogPaused() public {
        registry.setMatchingActive(false);

        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        bytes32 posId = PositionIdLib.compute(poolId, alice, -600, 600, bytes32(0));
        ICrossHedgeHook.Position memory p = hook.getPosition(posId);
        assertTrue(p.unhedged);
    }

    function test_afterAddLiquidity_EmitsEvent() public {
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        vm.recordLogs();
        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        bytes32 topicOpened = keccak256(
            "LPPositionOpened(bytes32,bytes32,address,int24,int24,uint128,int256,uint128,uint8,bool)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topicOpened) {
                found = true;
                break;
            }
        }
        assertTrue(found, "LPPositionOpened not emitted");
    }

    function test_afterAddLiquidity_RemoveLiquidityIgnored() public {
        // liquidityDelta < 0 should be no-op in this callback
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -int256(1e18),
            salt: bytes32(0)
        });

        (bytes4 sel, BalanceDelta hookDelta) = pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            ""
        );

        assertEq(sel, IHooks.afterAddLiquidity.selector);
        assertEq(int256(BalanceDeltaLibrary.amount0(hookDelta)), 0);
        assertEq(hook.premiumBalance(), 0);
    }

    function test_afterAddLiquidity_UnregisteredPool_Reverts() public {
        // Build a different PoolKey not yet initialized
        PoolKey memory badKey = PoolKey({
            currency0: Currency.wrap(address(0x111)),
            currency1: Currency.wrap(address(0x222)),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(address(hook))
        });

        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        vm.expectRevert();
        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, badKey, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );
    }

    function test_afterAddLiquidity_PremiumAccumulatesAcrossPositions() public {
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory dataA = _encodeHookData(alice, 1);
        bytes memory dataB = _encodeHookData(bob, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            dataA
        );
        uint256 afterAlice = hook.premiumBalance();

        // Bob uses different salt to avoid posId collision with Alice's
        ModifyLiquidityParams memory paramsBob = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: int256(1e18),
            salt: bytes32(uint256(1))
        });

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            bob, key, paramsBob,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            dataB
        );
        uint256 afterBoth = hook.premiumBalance();

        assertGt(afterAlice, 0);
        assertGt(afterBoth, afterAlice);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         afterRemoveLiquidity
    // ═══════════════════════════════════════════════════════════════════════

    function test_afterRemoveLiquidity_FullClose_DeletesPosition() public {
        ModifyLiquidityParams memory addParams = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, addParams,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        ModifyLiquidityParams memory rmParams = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -int256(1e18),
            salt: bytes32(0)
        });

        pm.callAfterRemoveLiquidity(
            IHooks(address(hook)),
            alice, key, rmParams,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        bytes32 posId = PositionIdLib.compute(poolId, alice, -600, 600, bytes32(0));
        ICrossHedgeHook.Position memory p = hook.getPosition(posId);
        assertEq(p.owner, address(0));
    }

    function test_afterRemoveLiquidity_PartialClose_UpdatesLiquidity() public {
        ModifyLiquidityParams memory addParams = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, addParams,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        ModifyLiquidityParams memory rmParams = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: -int256(4e17), // remove 40%
            salt: bytes32(0)
        });

        pm.callAfterRemoveLiquidity(
            IHooks(address(hook)),
            alice, key, rmParams,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );

        bytes32 posId = PositionIdLib.compute(poolId, alice, -600, 600, bytes32(0));
        ICrossHedgeHook.Position memory p = hook.getPosition(posId);
        assertEq(p.liquidity, uint128(6e17)); // 60% remaining
        assertEq(p.owner, alice); // not deleted
    }

    function test_afterRemoveLiquidity_UnknownPosition_NoOp() public {
        // Remove a position never opened — should not revert
        ModifyLiquidityParams memory rmParams = ModifyLiquidityParams({
            tickLower: -100,
            tickUpper: 100,
            liquidityDelta: -int256(1e18),
            salt: bytes32(0)
        });
        bytes memory data = _encodeHookData(alice, 1);

        (bytes4 sel,) = pm.callAfterRemoveLiquidity(
            IHooks(address(hook)),
            alice, key, rmParams,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );
        assertEq(sel, IHooks.afterRemoveLiquidity.selector);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            beforeSwap
    // ═══════════════════════════════════════════════════════════════════════

    function test_beforeSwap_SmallMove_DoesNotEmit() public {
        // Adjust tick slightly within threshold
        pm.setSlot0(poolId, SQRT_ONE, 10);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();
        pm.callBeforeSwap(IHooks(address(hook)), address(this), key, params, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topicLargeMove = keccak256(
            "LargeTickMove(bytes32,int24,int24,uint160)"
        );
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != topicLargeMove,
                "LargeTickMove should not emit for small move"
            );
        }
    }

    function test_beforeSwap_LargeMove_EmitsEvent() public {
        // Move tick beyond threshold (default 200)
        pm.setSlot0(poolId, uint160(uint256(SQRT_ONE) * 11 / 10), 300);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.recordLogs();
        pm.callBeforeSwap(IHooks(address(hook)), address(this), key, params, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topicLargeMove = keccak256(
            "LargeTickMove(bytes32,int24,int24,uint160)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topicLargeMove) {
                found = true;
                break;
            }
        }
        assertTrue(found, "LargeTickMove not emitted");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                             afterSwap
    // ═══════════════════════════════════════════════════════════════════════

    function test_afterSwap_PushesSnapshotAfterInterval() public {
        // Advance time past SNAPSHOT_MIN_INTERVAL
        vm.warp(block.timestamp + Constants.SNAPSHOT_MIN_INTERVAL_SECONDS + 1);

        // Change sqrtPrice slightly
        pm.setSlot0(poolId, uint160(uint256(SQRT_ONE) * 101 / 100), 100);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, , , , , uint32 headBefore) = hook.poolStates(poolId);
        pm.callAfterSwap(
            IHooks(address(hook)), address(this), key, params,
            BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        (, , , , , uint32 headAfter) = hook.poolStates(poolId);
        assertEq(headAfter, headBefore + 1);
    }

    function test_afterSwap_RateLimitedSnapshot() public {
        // Don't advance time; should NOT push a new snapshot
        pm.setSlot0(poolId, uint160(uint256(SQRT_ONE) * 101 / 100), 100);

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e18,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (, , , , , uint32 headBefore) = hook.poolStates(poolId);
        pm.callAfterSwap(
            IHooks(address(hook)), address(this), key, params,
            BalanceDeltaLibrary.ZERO_DELTA, ""
        );
        (, , , , , uint32 headAfter) = hook.poolStates(poolId);
        assertEq(headAfter, headBefore); // no new snapshot
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         harvestPremiums
    // ═══════════════════════════════════════════════════════════════════════

    function test_harvestPremiums_OnlyVault() public {
        vm.expectRevert(Errors.HookOnly.selector);
        hook.harvestPremiums(alice);
    }

    function test_harvestPremiums_DrainsBalance() public {
        // First accrue some premium
        ModifyLiquidityParams memory params = _defaultAddParams();
        bytes memory data = _encodeHookData(alice, 1);
        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            alice, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            data
        );
        uint256 bal = hook.premiumBalance();
        assertGt(bal, 0);

        vm.prank(vault);
        uint256 amount = hook.harvestPremiums(vault);
        assertEq(amount, bal);
        assertEq(hook.premiumBalance(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          getHookPermissions
    // ═══════════════════════════════════════════════════════════════════════

    function test_getHookPermissions_MatchesFlags() public view {
        Hooks.Permissions memory perms = hook.getHookPermissions();
        assertTrue(perms.afterInitialize);
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.afterAddLiquidityReturnDelta);
        assertTrue(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertFalse(perms.beforeAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterSwapReturnDelta);
        assertFalse(perms.beforeSwapReturnDelta);
    }
}
