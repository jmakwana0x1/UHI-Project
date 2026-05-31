// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {CrossHedgeVault} from "../../../src/vault/CrossHedgeVault.sol";
import {ICrossHedgeVault} from "../../../src/interfaces/ICrossHedgeVault.sol";
import {ICrossHedgeHook} from "../../../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import {MockERC20} from "../../utils/MockERC20.sol";
import {MockPoolManager} from "../../utils/MockPoolManager.sol";

/// @notice Placeholder contracts so the vault has non-zero addresses for hook
///         and registry. The vault only checks msg.sender against these
///         addresses for gating; it doesn't call into them in Phase 2 tests.
contract DummyHook {}
contract DummyRegistry {}

contract CrossHedgeVaultTest is Test {
    CrossHedgeVault internal vault;
    MockERC20 internal usdc;
    MockPoolManager internal pm;
    DummyHook internal hook;
    DummyRegistry internal registry;

    address internal callbackProxyAddr = makeAddr("callbackProxy");
    address internal strategyRvm = makeAddr("strategyRvm");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal gov;

    function setUp() public {
        gov = address(this);

        usdc = new MockERC20("USDC", "USDC", 6);
        pm = new MockPoolManager();
        hook = new DummyHook();
        registry = new DummyRegistry();

        vault = new CrossHedgeVault(
            IERC20(address(usdc)),
            "CrossHedge USDC",
            "chUSDC",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr,
            strategyRvm,
            uint16(50),
            uint256(1_000_000e6),
            uint32(30 minutes)
        );

        // Seed users with USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Constructor
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_SetsImmutables() public view {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.poolManager()), address(pm));
        assertEq(address(vault.hook()), address(hook));
        assertEq(address(vault.nettingRegistry()), address(registry));
        assertEq(vault.callbackProxy(), callbackProxyAddr);
        assertEq(vault.authorizedStrategyRvmId(), strategyRvm);
        assertEq(vault.maxSlippageBps(), 50);
        assertEq(vault.perBlockSwapCap(), 1_000_000e6);
        assertEq(vault.twapWindow(), 30 minutes);
    }

    function test_constructor_SetsNameAndSymbol() public view {
        assertEq(vault.name(), "CrossHedge USDC");
        assertEq(vault.symbol(), "chUSDC");
    }

    function test_constructor_SetsGovernance() public view {
        assertEq(vault.governance(), gov);
    }

    function test_constructor_StartsUnpaused() public view {
        assertFalse(vault.paused());
    }

    function test_constructor_RevertsOnZeroHook() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(0)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, strategyRvm,
            50, 1_000_000e6, 30 minutes
        );
    }

    function test_constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(0)),
            callbackProxyAddr, strategyRvm,
            50, 1_000_000e6, 30 minutes
        );
    }

    function test_constructor_RevertsOnZeroProxy() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            address(0), strategyRvm,
            50, 1_000_000e6, 30 minutes
        );
    }

    function test_constructor_RevertsOnZeroRvmId() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new CrossHedgeVault(
            IERC20(address(usdc)), "x", "x",
            IPoolManager(address(pm)),
            ICrossHedgeHook(address(hook)),
            INettingRegistry(address(registry)),
            callbackProxyAddr, address(0),
            50, 1_000_000e6, 30 minutes
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERC-4626 deposit
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit_FirstDeposit_MintsShares() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = vault.deposit(1_000e6, alice);
        vm.stopPrank();

        assertEq(shares, 1_000e6); // first deposit: 1:1
        assertEq(vault.balanceOf(alice), 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    function test_deposit_TotalAssetsReflectsBalance() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 5_000e6);
    }

    function test_deposit_MultipleDepositors_FairShares() public {
        // Alice deposits 1000 first
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        // Bob deposits 2000 → should get 2x Alice's shares
        vm.startPrank(bob);
        usdc.approve(address(vault), 2_000e6);
        uint256 bobShares = vault.deposit(2_000e6, bob);
        vm.stopPrank();

        assertEq(bobShares, 2 * vault.balanceOf(alice));
    }

    function test_deposit_Paused_Reverts() public {
        vault.setPaused(true);

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERC-4626 withdraw
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdraw_ReturnsUsdc() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        vault.withdraw(500e6, alice, alice);
        uint256 balAfter = usdc.balanceOf(alice);
        vm.stopPrank();

        assertEq(balAfter - balBefore, 500e6);
    }

    function test_withdraw_Paused_StillWorks() public {
        // Deposit first
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        vm.stopPrank();

        // Pause
        vault.setPaused(true);

        // Withdraw should still work
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);

        assertEq(usdc.balanceOf(alice) - (1_000_000e6 - 1_000e6 + 500e6), 0);
    }

    function test_redeem_FullExit() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, alice);
        uint256 shares = vault.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          depositPremium
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositPremium_OnlyHook() public {
        vm.prank(alice);
        vm.expectRevert(Errors.HookOnly.selector);
        vault.depositPremium(100e6);
    }

    function test_depositPremium_IncrementsCounter() public {
        vm.prank(address(hook));
        vault.depositPremium(100e6);
        assertEq(vault.premiumAccrued(), 100e6);

        vm.prank(address(hook));
        vault.depositPremium(50e6);
        assertEq(vault.premiumAccrued(), 150e6);
    }

    function test_depositPremium_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(address(hook));
        vault.depositPremium(100e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PremiumDeposited(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_depositPremium_WorksWhenPaused() public {
        vault.setPaused(true);
        // Premium flow should still work even when deposits are paused
        vm.prank(address(hook));
        vault.depositPremium(100e6);
        assertEq(vault.premiumAccrued(), 100e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         accrueLiability
    // ═══════════════════════════════════════════════════════════════════════

    function test_accrueLiability_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NettingRegistryOnly.selector);
        vault.accrueLiability(500e6);
    }

    function test_accrueLiability_Increments() public {
        vm.prank(address(registry));
        vault.accrueLiability(500e6);
        assertEq(vault.rebateLiability(), 500e6);

        vm.prank(address(registry));
        vault.accrueLiability(250e6);
        assertEq(vault.rebateLiability(), 750e6);
    }

    function test_accrueLiability_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(address(registry));
        vault.accrueLiability(500e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("LiabilityAccrued(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            payRebate
    // ═══════════════════════════════════════════════════════════════════════

    function test_payRebate_OnlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NettingRegistryOnly.selector);
        vault.payRebate(bob, 100e6);
    }

    function test_payRebate_RevertsOnZeroRecipient() public {
        vm.prank(address(registry));
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.payRebate(address(0), 100e6);
    }

    function test_payRebate_TransfersUsdc() public {
        // Seed vault with USDC (simulating deposits + premium)
        usdc.mint(address(vault), 10_000e6);

        // Registry accrued some liability
        vm.prank(address(registry));
        vault.accrueLiability(1_000e6);

        // Pay it out
        uint256 balBefore = usdc.balanceOf(bob);
        vm.prank(address(registry));
        vault.payRebate(bob, 1_000e6);

        assertEq(usdc.balanceOf(bob), balBefore + 1_000e6);
        assertEq(vault.rebateLiability(), 0);
    }

    function test_payRebate_PartialPayment() public {
        usdc.mint(address(vault), 10_000e6);

        vm.prank(address(registry));
        vault.accrueLiability(1_000e6);

        vm.prank(address(registry));
        vault.payRebate(bob, 400e6);

        assertEq(vault.rebateLiability(), 600e6);
    }

    function test_payRebate_InsufficientFunds_Reverts() public {
        // Vault has 0 USDC; trying to pay rebate reverts
        vm.prank(address(registry));
        vm.expectRevert(Errors.NoFundsAvailable.selector);
        vault.payRebate(bob, 100e6);
    }

    function test_payRebate_OveraccountedLiability_FloorsAtZero() public {
        usdc.mint(address(vault), 10_000e6);

        // Pay rebate without prior accrual (liability is 0)
        // This is defensive: the function should handle the case where credits
        // were missed, not revert. rebateLiability stays at 0.
        vm.prank(address(registry));
        vault.payRebate(bob, 500e6);

        assertEq(vault.rebateLiability(), 0);
    }

    function test_payRebate_WorksWhenPaused() public {
        usdc.mint(address(vault), 10_000e6);

        vault.setPaused(true);

        // Rebate flow still works
        vm.prank(address(registry));
        vault.payRebate(bob, 100e6);
        assertEq(usdc.balanceOf(bob), 1_000_000e6 + 100e6);
    }

    function test_payRebate_EmitsEvent() public {
        usdc.mint(address(vault), 10_000e6);
        vm.recordLogs();

        vm.prank(address(registry));
        vault.payRebate(bob, 100e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("RebatePaidFromVault(address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           totalAssets
    // ═══════════════════════════════════════════════════════════════════════

    function test_totalAssets_NetOfRebateLiability() public {
        // Vault has 10k USDC, 1k liability → totalAssets = 9k
        usdc.mint(address(vault), 10_000e6);

        vm.prank(address(registry));
        vault.accrueLiability(1_000e6);

        assertEq(vault.totalAssets(), 9_000e6);
    }

    function test_totalAssets_LiabilityExceedsBalance_ReturnsZero() public {
        // Defensive: if liability somehow exceeds balance, return 0 (not underflow)
        usdc.mint(address(vault), 1_000e6);

        vm.prank(address(registry));
        vault.accrueLiability(5_000e6);

        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_AfterDepositAndPremium() public {
        // Alice deposits 5k, hook deposits 100 premium
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, alice);
        vm.stopPrank();

        // Hook sends premium USDC + calls depositPremium
        usdc.mint(address(vault), 100e6);
        vm.prank(address(hook));
        vault.depositPremium(100e6);

        // totalAssets should reflect 5100
        assertEq(vault.totalAssets(), 5_100e6);
    }

    function test_totalAssets_SharesAppreciateFromPremium() public {
        // Alice deposits 5000 → gets 5000 shares (1:1)
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        vault.deposit(5_000e6, alice);
        vm.stopPrank();

        // Hook delivers 500 USDC of premium → vault now holds 5500 USDC
        usdc.mint(address(vault), 500e6);
        vm.prank(address(hook));
        vault.depositPremium(500e6);

        // Alice's shares now redeem for ~5500 USDC.
        // OZ's ERC4626 rounds previewRedeem DOWN for solvency safety, so we
        // tolerate 1 wei. This is OpenZeppelin's documented inflation-protection
        // behavior, not a bug in our vault.
        uint256 redeemable = vault.previewRedeem(vault.balanceOf(alice));
        assertApproxEqAbs(redeemable, 5_500e6, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            rebalance (stub)
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_OnlyStrategyCallback() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);

        vm.prank(alice);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        vault.rebalance(strategyRvm, allocs);
    }

    function test_rebalance_WrongRvmId_Reverts() public {
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        address badRvm = makeAddr("badRvm");

        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        vault.rebalance(badRvm, allocs);
    }

    function test_rebalance_PausedReverts() public {
        vault.setPaused(true);

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.VaultPaused.selector);
        vault.rebalance(strategyRvm, allocs);
    }

    function test_rebalance_RevertsWhenManagedKeyNotSet() public {
        // Phase 4: rebalance now requires a managed PoolKey to be set first.
        // This vault (from setUp) never calls setManagedKey, so rebalance
        // must revert. Full rebalance behavior is covered in
        // CrossHedgeVaultRebalance.t.sol against MockPoolManagerV2.
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](0);
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.rebalance(strategyRvm, allocs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    function test_setPaused_OnlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.setPaused(true);
    }

    function test_setPaused_TogglesState() public {
        vault.setPaused(true);
        assertTrue(vault.paused());
        vault.setPaused(false);
        assertFalse(vault.paused());
    }

    function test_transferGovernance_UpdatesGov() public {
        vault.transferGovernance(alice);
        assertEq(vault.governance(), alice);
    }

    function test_transferGovernance_OldGovCantAct() public {
        vault.transferGovernance(alice);
        vm.expectRevert(Errors.Unauthorized.selector);
        vault.setPaused(true);
    }

    function test_transferGovernance_ZeroAddress_Reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vault.transferGovernance(address(0));
    }
}
