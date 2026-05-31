// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {CrossHedgeVault} from "../../../src/vault/CrossHedgeVault.sol";
import {ICrossHedgeVault} from "../../../src/interfaces/ICrossHedgeVault.sol";
import {ICrossHedgeHook} from "../../../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import {MockERC20} from "../../utils/MockERC20.sol";
import {MockPoolManagerV2} from "../../utils/MockPoolManagerV2.sol";

/// @notice Minimal hook mock returning a healthy TWAP. Configurable sample
///         count so we can test the staleness guard.
contract RebalanceMockHook is ICrossHedgeHook {
    uint160 public twap = uint160(1 << 96); // price = 1.0
    uint32 public samples = 10;
    address public override vault;

    function setTwap(uint160 t, uint32 s) external { twap = t; samples = s; }
    function setVault(address v) external { vault = v; }

    function readTwapSqrtPrice(PoolId, uint32) external view override returns (uint160, uint32) {
        return (twap, samples);
    }
    function harvestPremiums(address) external pure override returns (uint256) { return 0; }
    function getPosition(bytes32) external pure override returns (Position memory p) { return p; }
    function premiumBalance() external pure override returns (uint256) { return 0; }
}

contract DummyRegistry {}

contract CrossHedgeVaultRebalanceTest is Test {
    using PoolIdLibrary for PoolKey;

    CrossHedgeVault internal vault;
    MockPoolManagerV2 internal pm;
    RebalanceMockHook internal hook;
    DummyRegistry internal registry;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    PoolKey internal key;
    PoolId internal pid;

    address internal callbackProxyAddr = makeAddr("callbackProxy");
    address internal strategyRvm = makeAddr("strategyRvm");
    address internal gov;

    bool internal usdcIsToken0_;

    uint160 internal constant SQRT_ONE = uint160(1 << 96);

    function setUp() public {
        gov = address(this);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);
        pm = new MockPoolManagerV2();
        hook = new RebalanceMockHook();
        registry = new DummyRegistry();

        vault = new CrossHedgeVault(
            IERC20(address(usdc)),
            "CrossHedge USDC", "chUSDC",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            uint16(50), uint256(1_000_000e6), uint32(30 minutes)
        );

        // Build pool key with deterministic currency ordering
        usdcIsToken0_ = address(usdc) < address(weth);
        Currency c0 = usdcIsToken0_ ? Currency.wrap(address(usdc)) : Currency.wrap(address(weth));
        Currency c1 = usdcIsToken0_ ? Currency.wrap(address(weth)) : Currency.wrap(address(usdc));
        key = PoolKey({
            currency0: c0, currency1: c1,
            fee: 3000, tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        pid = key.toId();

        // Configure the mock pool
        pm.setPrice(key, SQRT_ONE);   // price 1.0
        pm.setLiquidity(key, 0);

        // Set managed key on the vault
        vault.setManagedKey(key, usdcIsToken0_);

        // Seed the vault with USDC (its reserves). Generous headroom so
        // liquidity deploys + WETH-cover swaps don't exhaust the balance.
        usdc.mint(address(vault), 100_000_000e6);

        // Seed the mock PM with WETH so swaps can deliver WETH out,
        // and with USDC so it can give change if needed.
        weth.mint(address(pm), 1_000_000 ether);
        usdc.mint(address(pm), 100_000_000e6);
    }

    function _alloc(int24 tl, int24 tu, uint128 liq) internal pure returns (ICrossHedgeVault.Allocation memory) {
        return ICrossHedgeVault.Allocation({
            tickLower: tl, tickUpper: tu,
            targetLiquidity: liq, keepIfExists: true
        });
    }

    function _doRebalance(ICrossHedgeVault.Allocation[] memory allocs) internal {
        vm.prank(callbackProxyAddr);
        vault.rebalance(strategyRvm, allocs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          setManagedKey
    // ═══════════════════════════════════════════════════════════════════════

    function test_setManagedKey_GovernanceOnly() public {
        // Fresh vault without managed key
        CrossHedgeVault v2 = new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            50, 1_000_000e6, 30 minutes
        );
        vm.prank(makeAddr("notGov"));
        vm.expectRevert(Errors.Unauthorized.selector);
        v2.setManagedKey(key, usdcIsToken0_);
    }

    function test_setManagedKey_OneTimeOnly() public {
        // Already set in setUp; second call reverts
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.setManagedKey(key, usdcIsToken0_);
    }

    function test_setManagedKey_StoresUsdcIsToken0() public view {
        assertEq(vault.usdcIsToken0(), usdcIsToken0_);
        assertTrue(vault.managedKeySet());
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          rebalance auth
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_OnlyStrategyCallback() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        vault.rebalance(strategyRvm, allocs);
    }

    function test_rebalance_WrongRvmId_Reverts() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        vault.rebalance(makeAddr("badRvm"), allocs);
    }

    function test_rebalance_PausedReverts() public {
        vault.setPaused(true);
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.rebalance(strategyRvm, allocs);
    }

    function test_rebalance_RevertsIfManagedKeyNotSet() public {
        CrossHedgeVault v2 = new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            50, 1_000_000e6, 30 minutes
        );
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.Unauthorized.selector);
        v2.rebalance(strategyRvm, allocs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          unlockCallback auth
    // ═══════════════════════════════════════════════════════════════════════

    function test_unlockCallback_OnlyPoolManager() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.unlockCallback("");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          THE REAL FLOW
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_DeploysLiquidity_SettlesClean() public {
        // The crown jewel: if this doesn't revert with CurrencyNotSettled,
        // our settlement loop balanced every delta.
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));

        _doRebalance(allocs);

        // No revert = settlement succeeded. Verify PM is fully settled.
        assertEq(pm.nonzeroDeltaCount(), 0);
        assertFalse(pm.isUnlocked());
    }

    function test_rebalance_VaultUsdcDecreases() public {
        uint256 balBefore = usdc.balanceOf(address(vault));

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);

        uint256 balAfter = usdc.balanceOf(address(vault));
        // Vault spent USDC deploying liquidity (both as USDC leg and swapped for WETH)
        assertLt(balAfter, balBefore);
    }

    function test_rebalance_PoolLiquidityIncreases() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);

        assertEq(pm.liquidityOf(pid), uint128(1e10));
    }

    function test_rebalance_MultipleAllocations_SettleClean() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](2);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        allocs[1] = _alloc(-1200, 1200, uint128(5e9));
        _doRebalance(allocs);

        assertEq(pm.nonzeroDeltaCount(), 0);
        // Combined liquidity
        assertEq(pm.liquidityOf(pid), uint128(1e10 + 5e9));
    }

    function test_rebalance_EmptyAllocs_NoOp() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        uint256 balBefore = usdc.balanceOf(address(vault));
        _doRebalance(allocs);
        // Nothing deployed
        assertEq(usdc.balanceOf(address(vault)), balBefore);
        assertEq(pm.nonzeroDeltaCount(), 0);
    }

    function test_rebalance_ZeroTargetLiquidity_Skipped() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, 0); // zero liquidity
        uint256 balBefore = usdc.balanceOf(address(vault));
        _doRebalance(allocs);
        assertEq(usdc.balanceOf(address(vault)), balBefore);
        assertEq(pm.liquidityOf(pid), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          TWAP staleness guard
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_StaleTwap_Reverts() public {
        // Hook returns only 2 samples < MIN_TWAP_SAMPLES (3)
        hook.setTwap(SQRT_ONE, 2);

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));

        vm.prank(callbackProxyAddr);
        vm.expectRevert(abi.encodeWithSelector(Errors.TwapStale.selector, uint64(0)));
        vault.rebalance(strategyRvm, allocs);
    }

    function test_rebalance_HealthyTwap_Proceeds() public {
        hook.setTwap(SQRT_ONE, 3); // exactly at threshold
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);
        assertEq(pm.nonzeroDeltaCount(), 0);
    }
    // ═══════════════════════════════════════════════════════════════════════
    //                  Phase 5 Tier 3 A: perBlockSwapCap
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_SwapCapNotTripped_Normal() public {
        // Default cap is 1_000_000e6 USDC; a 1e15 liquidity alloc swaps a
        // small fraction. Should pass through cleanly.
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);
        assertEq(pm.nonzeroDeltaCount(), 0);
    }

    function test_rebalance_SwapCapExceeded_Reverts() public {
        // Deploy a fresh vault with a tiny cap so we can trip it.
        CrossHedgeVault tightVault = new CrossHedgeVault(
            IERC20(address(usdc)), "tight", "t",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            uint16(50),
            uint256(1),          // perBlockSwapCap = 1 wei of USDC
            uint32(30 minutes)
        );
        tightVault.setManagedKey(key, usdcIsToken0_);
        usdc.mint(address(tightVault), 100_000_000e6);

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));

        // Any nonzero swap should exceed the 1-wei cap.
        vm.prank(callbackProxyAddr);
        vm.expectRevert(); // SwapCapExceeded with computed args
        tightVault.rebalance(strategyRvm, allocs);
    }
    // ═══════════════════════════════════════════════════════════════════════
    //              Phase 5 Tier 3 C: ownedAllocations tracking
    // ═══════════════════════════════════════════════════════════════════════

    function test_ownedAllocations_RecordedAfterRebalance() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);

        assertEq(vault.ownedAllocationCount(), 1);
        ICrossHedgeVault.Allocation memory owned = vault.ownedAllocationAt(0);
        assertEq(owned.tickLower, int24(-600));
        assertEq(owned.tickUpper, int24(600));
        assertEq(owned.targetLiquidity, uint128(1e10));
    }

    function test_ownedAllocations_MultipleAllocations_AllRecorded() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](2);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        allocs[1] = _alloc(-1200, 1200, uint128(5e9));
        _doRebalance(allocs);

        assertEq(vault.ownedAllocationCount(), 2);
    }

    function test_ownedAllocations_SameRangeReplaces() public {
        // First rebalance: deploy [-600, 600] with 1e15 liquidity
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);
        assertEq(vault.ownedAllocationCount(), 1);

        // Second rebalance: same range, different liquidity → replaces, doesn't dup
        allocs[0] = _alloc(-600, 600, uint128(2e10));
        _doRebalance(allocs);
        assertEq(vault.ownedAllocationCount(), 1);
        assertEq(vault.ownedAllocationAt(0).targetLiquidity, uint128(2e10));
    }
    // ═══════════════════════════════════════════════════════════════════════
    //         Phase 5 Tier 3 C: share-price stability across rebalance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The headline test: a depositor's share price should not crater
    ///         after the vault deploys a position. The deployed USDC is no
    ///         longer in the balance, but it IS represented in totalAssets via
    ///         ETH-side valuation, so share price stays roughly stable.
    ///
    /// @dev    Uses a FRESH vault with no pre-seeded USDC so the depositor's
    ///         shares mint 1:1. The setUp's pre-seeded vault has 100M USDC
    ///         already in it (for other tests that don't deposit), which would
    ///         trigger OZ ERC4626's inflation defense and round Alice's
    ///         shares to zero. This is a known property of OZ's vault math
    ///         when a vault is "over-funded" before the first depositor.
    function test_sharePrice_StableAcrossRebalance() public {
        // Deploy a fresh vault with NO pre-seeding
        CrossHedgeVault freshVault = new CrossHedgeVault(
            IERC20(address(usdc)), "fresh", "f",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            uint16(50), uint256(1_000_000e6), uint32(30 minutes)
        );
        freshVault.setManagedKey(key, usdcIsToken0_);

        // ─── Step 1: depositor enters as the FIRST USDC source ────────────
        address alice = makeAddr("alice");
        usdc.mint(alice, 10_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(freshVault), 10_000_000e6);
        uint256 aliceShares = freshVault.deposit(10_000_000e6, alice);
        vm.stopPrank();

        assertGt(aliceShares, 0, "alice should receive shares");

        uint256 totalAssetsBefore = freshVault.totalAssets();
        uint256 sharePriceBefore = freshVault.convertToAssets(1e18);
        assertGt(totalAssetsBefore, 0);

        // ─── Step 2: rebalance deploys some USDC ──────────────────────────
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        vm.prank(callbackProxyAddr);
        freshVault.rebalance(strategyRvm, allocs);

        // ─── Step 3: measure share price after ────────────────────────────
        uint256 totalAssetsAfter = freshVault.totalAssets();
        uint256 sharePriceAfter = freshVault.convertToAssets(1e18);

        // The headline assertion: share price didn't crater.
        uint256 drift = sharePriceBefore > sharePriceAfter
            ? sharePriceBefore - sharePriceAfter
            : sharePriceAfter - sharePriceBefore;
        assertLt(
            drift * 100 / sharePriceBefore,
            1,
            "share price drifted more than 1% across rebalance"
        );

        // Alice's redeemable still ~= her deposit
        uint256 aliceRedeemable = freshVault.previewRedeem(aliceShares);
        assertApproxEqRel(aliceRedeemable, 10_000_000e6, 0.01e18);

        // totalAssets after rebalance > simple "balance - liability" because
        // we're now also counting the deployed value
        uint256 simpleBalNet = usdc.balanceOf(address(freshVault));
        assertGt(totalAssetsAfter, simpleBalNet);
    }

    function test_totalAssets_IncludesDeployedValue() public {
        // Without rebalance: totalAssets == balance (no allocations, no
        // liability)
        uint256 baselineTotal = vault.totalAssets();
        uint256 baselineBal = usdc.balanceOf(address(vault));
        assertEq(baselineTotal, baselineBal);

        // After rebalance: balance decreases but deployed-value compensates
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);

        uint256 newBal = usdc.balanceOf(address(vault));
        uint256 newTotal = vault.totalAssets();

        // Balance went down (we deployed)
        assertLt(newBal, baselineBal);

        // Total assets includes the deployed value, so it's higher than newBal
        assertGt(newTotal, newBal);

        // The deployed value is roughly the balance delta
        uint256 deployedFromBalance = baselineBal - newBal;
        uint256 deployedFromValuation = newTotal - newBal;
        // These should be in the same ballpark (within 50% — mock math vs
        // valuation math are independent approximations)
        assertGt(deployedFromValuation, deployedFromBalance / 2);
        assertLt(deployedFromValuation, deployedFromBalance * 2);
    }

    function test_totalAssets_FallsBackWhenTwapStale() public {
        // If the hook's TWAP is too thin, totalAssets safely returns 0
        // deployed value (no revert in view path)
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        _doRebalance(allocs);

        // Now make TWAP stale
        hook.setTwap(uint160(1 << 96), 1); // < MIN_TWAP_SAMPLES (3)

        uint256 totalAfter = vault.totalAssets();
        uint256 balOnly = usdc.balanceOf(address(vault));
        // No deployed value credited; just balance
        assertEq(totalAfter, balOnly);
    }

    function test_totalAssets_ZeroAllocations_BehavesLikePhase2() public {
        // With no rebalance ever called, behavior matches Phase 2 exactly:
        // totalAssets == balance - rebateLiability
        uint256 expected = usdc.balanceOf(address(vault));
        assertEq(vault.totalAssets(), expected);
    }

    function test_newDepositor_GetsSimilarSharesAcrossRebalance() public {
        // Fresh vault so the first deposit isn't washed out by OZ inflation
        // defense against the pre-seeded balance.
        CrossHedgeVault freshVault = new CrossHedgeVault(
            IERC20(address(usdc)), "fresh", "f",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            uint16(50), uint256(1_000_000e6), uint32(30 minutes)
        );
        freshVault.setManagedKey(key, usdcIsToken0_);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        usdc.mint(alice, 5_000_000e6);
        usdc.mint(bob, 5_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(freshVault), 5_000_000e6);
        uint256 aliceShares = freshVault.deposit(5_000_000e6, alice);
        vm.stopPrank();

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = _alloc(-600, 600, uint128(1e10));
        vm.prank(callbackProxyAddr);
        freshVault.rebalance(strategyRvm, allocs);

        vm.startPrank(bob);
        usdc.approve(address(freshVault), 5_000_000e6);
        uint256 bobShares = freshVault.deposit(5_000_000e6, bob);
        vm.stopPrank();

        assertApproxEqRel(bobShares, aliceShares, 0.01e18);
    }
}