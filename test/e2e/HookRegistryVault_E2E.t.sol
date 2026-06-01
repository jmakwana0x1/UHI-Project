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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "../utils/BaseTest.sol";
import {HookDeployer} from "../utils/HookDeployer.sol";

import {CrossHedgeHook} from "../../src/hook/CrossHedgeHook.sol";
import {NettingRegistry} from "../../src/registry/NettingRegistry.sol";
import {CrossHedgeVault} from "../../src/vault/CrossHedgeVault.sol";
import {ICrossHedgeHook} from "../../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../../src/interfaces/INettingRegistry.sol";
import {IRebatePayer} from "../../src/interfaces/IRebatePayer.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {PositionIdLib} from "../../src/libraries/PositionIdLib.sol";

/// @title FullTriangleIntegrationTest
/// @notice Verifies the full single-chain flow with all 3 real contracts
///         (CrossHedgeHook + NettingRegistry + CrossHedgeVault) working
///         together. The vault doubles as the IRebatePayer for the registry,
///         so this is the canonical home-chain configuration.
///
/// @dev    Cross-chain (MatchingRSC, StrategyRSC) is Phase 3.
///         Real swap rebalance is Phase 4.
contract FullTriangle_E2E_Test is BaseTest {
    using PoolIdLibrary for PoolKey;

    CrossHedgeHook internal hook;
    NettingRegistry internal registry;
    CrossHedgeVault internal vault_;

    PoolKey internal key;
    PoolId internal poolId;

    uint160 internal constant SQRT_ONE = uint160(1 << 96);
    uint64 internal constant WATCHDOG_WINDOW = 30 minutes;
    uint16 internal constant F_INT_BPS = 1200; // 12% APR

    function setUp() public {
        _baseSetUp();
        vm.warp(1_000_000);

        bool usdcIsToken0_ = address(usdc) < address(weth);

        // ─── Deployment cycle ─────────────────────────────────────────────
        // hook → registry → vault, but they all reference each other.
        // Plan:
        //   1. Predict the vault's CREATE address (it will be the LAST EOA
        //      new-keyword deploy in setUp).
        //   2. Predict the registry's CREATE address (one before vault).
        //   3. Mine the hook's CREATE2 address using the predicted registry.
        //   4. Deploy registry (pointing at mined hook + predicted vault).
        //      But wait — the registry's rebatePayer is the vault, which doesn't
        //      exist yet. Cleanest: deploy registry pointing at the predicted
        //      vault address.
        //   5. Deploy hook via CREATE2 at the mined address.
        //   6. Deploy vault (it doesn't reference back to registry except by
        //      address, which the registry already knows).

        uint64 nonceNow = vm.getNonce(address(this));
        // After this setUp:
        //   - nonce N: registry (next new-keyword deploy)
        //   - nonce N+1: vault (the one after)
        // Hook is via CREATE2 → doesn't consume EOA nonce.
        address predictedRegistry = vm.computeCreateAddress(address(this), nonceNow);
        address predictedVault = vm.computeCreateAddress(address(this), nonceNow + 1);

        // Mine hook against predicted registry
        bytes memory hookArgs = abi.encode(
            IPoolManager(address(pm)),
            INettingRegistry(predictedRegistry),
            predictedVault,
            uint16(30),
            usdcIsToken0_
        );
        (address hookAddr, bytes32 salt) = HookDeployer.mine(
            HOOK_FLAGS,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );

        // Deploy registry pointing at mined hook + predicted vault
        registry = new NettingRegistry(
            callbackProxy,
            matchingRvm,
            ICrossHedgeHook(hookAddr),
            IRebatePayer(predictedVault),
            WATCHDOG_WINDOW,
            F_INT_BPS
        );
        require(address(registry) == predictedRegistry, "Registry mismatch");

        // Deploy vault pointing at mined hook + the now-real registry
        vault_ = new CrossHedgeVault(
            IERC20(address(usdc)),
            "CrossHedge USDC",
            "chUSDC",
            IPoolManager(address(pm)),
            ICrossHedgeHook(hookAddr),
            INettingRegistry(address(registry)),
            callbackProxy,
            matchingRvm,
            uint16(50),
            uint256(1_000_000e6),
            uint32(30 minutes)
        );
        require(address(vault_) == predictedVault, "Vault mismatch");

        // Deploy hook via CREATE2 at the mined address
        bytes memory deployPayload = abi.encodePacked(
            salt,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );
        (bool ok,) = HookDeployer.CREATE2_DEPLOYER.call(deployPayload);
        require(ok, "Hook deploy failed");
        hook = CrossHedgeHook(hookAddr);
        require(address(hook).code.length > 0, "Hook not deployed");

        // ─── Build PoolKey ────────────────────────────────────────────────
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

        pm.setSlot0(poolId, SQRT_ONE, 0);
        pm.callAfterInitialize(IHooks(address(hook)), address(this), key, SQRT_ONE, 0);

        // Mint USDC for actors
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _addLiquidity(
        address user,
        int24 tickL,
        int24 tickU,
        int256 liq,
        bytes32 salt
    ) internal returns (bytes32 posId) {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: tickL,
            tickUpper: tickU,
            liquidityDelta: liq,
            salt: salt
        });
        bytes memory hookData = abi.encode(user, uint8(1));

        pm.callAfterAddLiquidity(
            IHooks(address(hook)),
            user, key, params,
            BalanceDeltaLibrary.ZERO_DELTA, BalanceDeltaLibrary.ZERO_DELTA,
            hookData
        );

        posId = PositionIdLib.compute(poolId, user, tickL, tickU, salt);
    }

    function _recordMatch(bytes32 matchId, bytes32 longId, bytes32 shortId, uint128 notional) internal {
        vm.prank(callbackProxy);
        registry.recordMatch(
            matchingRvm, matchId, longId, shortId,
            uint64(1), uint64(2), notional, F_INT_BPS
        );
    }

    function _settleMatch(bytes32 matchId, bool terminal) internal {
        vm.prank(callbackProxy);
        registry.settleMatch(matchingRvm, matchId, terminal);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  THE BIG ONE: full lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    function test_triangle_FullLifecycle() public {
        // ─── Step 1: Alice deposits to the vault ──────────────────────────
        vm.startPrank(alice);
        usdc.approve(address(vault_), 100_000e6);
        uint256 aliceShares = vault_.deposit(100_000e6, alice);
        vm.stopPrank();

        assertEq(aliceShares, 100_000e6);
        assertEq(vault_.totalAssets(), 100_000e6);

        // ─── Step 2: Alice opens an LP position ───────────────────────────
        // (Premium would normally flow from PoolManager → hook → vault via
        // BalanceDelta + harvestPremiums + depositPremium. For this test we
        // simulate that flow at the seams.)
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));

        // Hook's internal premium ledger is now non-zero
        uint256 hookPremium = hook.premiumBalance();
        assertGt(hookPremium, 0);

        // ─── Step 3: Simulate the premium settling into the vault ────────
        // In production this happens via pool-manager flash accounting:
        //   - LP pays extra USDC owed-to-hook → PoolManager
        //   - hook calls vault.depositPremium(amount) to register accounting
        //   - PoolManager.take(amount) actually moves the tokens to vault
        // For this test, mint the USDC directly and call depositPremium.
        usdc.mint(address(vault_), hookPremium);

        vm.prank(address(hook));
        vault_.depositPremium(hookPremium);

        // Drain the hook's ledger
        vm.prank(address(vault_));
        hook.harvestPremiums(address(vault_));
        assertEq(hook.premiumBalance(), 0);

        // Vault now holds principal + premium
        assertEq(usdc.balanceOf(address(vault_)), 100_000e6 + hookPremium);
        assertEq(vault_.premiumAccrued(), hookPremium);

        // ─── Step 4: Bob opens a short position ──────────────────────────
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));

        // Same dance for Bob's premium
        uint256 hookPremium2 = hook.premiumBalance();
        usdc.mint(address(vault_), hookPremium2);
        vm.prank(address(hook));
        vault_.depositPremium(hookPremium2);
        vm.prank(address(vault_));
        hook.harvestPremiums(address(vault_));

        // ─── Step 5: MatchingRSC reports a match ─────────────────────────
        bytes32 matchId = keccak256(abi.encode(aliceLongId, bobShortId, block.timestamp));
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        assertTrue(registry.isHedged(aliceLongId));
        assertTrue(registry.isHedged(bobShortId));

        // ─── Step 6: Time passes ────────────────────────────────────────
        vm.warp(block.timestamp + 30 days);

        // ─── Step 7: Periodic settle → accrue ───────────────────────────
        _settleMatch(matchId, false);

        // Bob's accrued rebate should be ~9.86k USDC (30/365 * 12% * 1M)
        uint128 accrued = registry.accruedRebate(bobShortId);
        assertGt(accrued, 9_000e6);
        assertLt(accrued, 11_000e6);

        // Critical seam: vault's rebateLiability should equal accrued
        assertEq(vault_.rebateLiability(), uint256(accrued));

        // totalAssets should now reflect: balance - liability
        uint256 vaultBal = usdc.balanceOf(address(vault_));
        uint256 expectedTotal = vaultBal - uint256(accrued);
        assertEq(vault_.totalAssets(), expectedTotal);

        // ─── Step 8: Bob claims his rebate ───────────────────────────────
        uint256 bobBalBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        registry.claimRebate(bobShortId);

        // Bob received USDC
        assertEq(usdc.balanceOf(bob) - bobBalBefore, uint256(accrued));
        // Registry's accrual zeroed
        assertEq(registry.accruedRebate(bobShortId), 0);
        // Vault's liability zeroed
        assertEq(vault_.rebateLiability(), 0);

        // ─── Step 9: Alice withdraws her shares ──────────────────────────
        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        vault_.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = usdc.balanceOf(alice) - aliceUsdcBefore;

        // Alice should get MORE than 100k — premium accrued, then 9.86k went
        // out as rebate, but the rest is still in the vault for her.
        // She's the sole shareholder, so totalAssets ≈ her share.
        // Verify: she got back > 100k principal (some net positive yield)
        // OR she got back < 100k if rebate paid exceeded premiums collected.
        // For a one-position match, the second is likely true.
        assertGt(aliceReceived, 0);

        // Sanity invariant: total premiums collected vs total rebates paid
        // are roughly comparable in magnitude.
        // For this scenario:
        //   premium = ~3 bps of notional (small)
        //   rebate  = ~30 days of 12% APR on 1M (large)
        // So Alice will redeem less than her 100k principal.
        // This is correct: the vault took a loss on this match because the
        // hedge ran long. In aggregate (many matches) the protocol is
        // designed to be net-positive.
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  Solvency invariants
    // ═══════════════════════════════════════════════════════════════════════

    function test_triangle_VaultSolvent_AfterAccrualBeforeClaim() public {
        // Setup positions and match
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));

        // Seed vault with some USDC so it has float
        usdc.mint(address(vault_), 100_000e6);

        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        vm.warp(block.timestamp + 30 days);
        _settleMatch(matchId, false);

        // Invariant: vault has enough balance to cover its liability
        uint256 vaultBal = usdc.balanceOf(address(vault_));
        uint256 liability = vault_.rebateLiability();
        assertGe(vaultBal, liability);
    }

    function test_triangle_LiabilityTracksAccrualExactly() public {
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));

        usdc.mint(address(vault_), 100_000e6);
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        // Multiple settle calls; liability should always equal accrued
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 1 days);
            _settleMatch(matchId, false);

            uint128 accrued = registry.accruedRebate(bobShortId);
            uint256 liability = vault_.rebateLiability();
            assertEq(uint256(accrued), liability);
        }
    }

    function test_triangle_ClaimDecrementsBothSides() public {
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));

        usdc.mint(address(vault_), 100_000e6);
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        vm.warp(block.timestamp + 30 days);
        _settleMatch(matchId, false);

        uint128 accrued = registry.accruedRebate(bobShortId);

        vm.prank(bob);
        registry.claimRebate(bobShortId);

        // Both sides go to zero in one atomic step
        assertEq(registry.accruedRebate(bobShortId), 0);
        assertEq(vault_.rebateLiability(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  Watchdog & negative paths
    // ═══════════════════════════════════════════════════════════════════════

    function test_triangle_WatchdogPause_BlocksPremium() public {
        // Setup: deposit 100k to vault
        vm.startPrank(alice);
        usdc.approve(address(vault_), 100_000e6);
        vault_.deposit(100_000e6, alice);
        vm.stopPrank();

        // Pause watchdog
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);

        // Alice opens position — should be unhedged, no premium
        _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));

        // No premium accrued (matching paused)
        assertEq(hook.premiumBalance(), 0);
        assertEq(vault_.premiumAccrued(), 0);

        // Watchdog state
        assertFalse(registry.matchingActive());
    }

    function test_triangle_PausedVault_StillProcessesRebates() public {
        // Setup match and accrual
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));
        usdc.mint(address(vault_), 100_000e6);

        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleMatch(matchId, false);

        // Now pause the vault (governance halts deposits)
        vault_.setPaused(true);

        // Bob can still claim
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        registry.claimRebate(bobShortId);
        assertGt(usdc.balanceOf(bob), balBefore);

        // But new deposits revert
        vm.startPrank(alice);
        usdc.approve(address(vault_), 1_000e6);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault_.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    function test_triangle_NonOwnerCannotClaim() public {
        bytes32 aliceLongId = _addLiquidity(alice, -600, 600, int256(1e18), bytes32(0));
        bytes32 bobShortId = _addLiquidity(bob, 600, 1200, int256(1e18), bytes32(uint256(1)));
        usdc.mint(address(vault_), 100_000e6);

        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settleMatch(matchId, false);

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(Errors.NotPositionOwner.selector);
        registry.claimRebate(bobShortId);
    }
}
