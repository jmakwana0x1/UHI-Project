// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {VaultProxy} from "../../../src/vault/VaultProxy.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import {MockERC20} from "../../utils/MockERC20.sol";

/// @notice We need a placeholder for the NettingRegistry — the proxy doesn't
///         call into it, just stores its address and gates payRebate against
///         msg.sender == nettingRegistry.
contract DummyRegistry {
    // intentionally empty; we use this address as a "registry" caller via vm.prank
}

contract VaultProxyTest is Test {
    VaultProxy internal proxy;
    MockERC20 internal usdc;
    DummyRegistry internal registry;

    address internal callbackProxyAddr = makeAddr("callbackProxy");
    address internal strategyRvm = makeAddr("strategyRvm");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal gov;

    uint256 internal constant INITIAL_FLOAT_TARGET = 100_000e6; // 100k USDC

    function setUp() public {
        gov = address(this);

        usdc = new MockERC20("USDC", "USDC", 6);
        registry = new DummyRegistry();

        proxy = new VaultProxy(
            IERC20(address(usdc)),
            INettingRegistry(address(registry)),
            callbackProxyAddr,
            strategyRvm,
            INITIAL_FLOAT_TARGET
        );

        // Seed the proxy with some USDC float
        usdc.mint(address(proxy), 50_000e6);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Constructor
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_SetsImmutables() public view {
        assertEq(address(proxy.usdc()), address(usdc));
        assertEq(address(proxy.nettingRegistry()), address(registry));
        assertEq(proxy.callbackProxy(), callbackProxyAddr);
        assertEq(proxy.authorizedStrategyRvmId(), strategyRvm);
    }

    function test_constructor_SetsFloatTarget() public view {
        assertEq(proxy.floatTarget(), INITIAL_FLOAT_TARGET);
    }

    function test_constructor_SetsGovernanceToDeployer() public view {
        assertEq(proxy.governance(), gov);
    }

    function test_constructor_RevertsOnZeroUsdc() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultProxy(
            IERC20(address(0)),
            INettingRegistry(address(registry)),
            callbackProxyAddr,
            strategyRvm,
            INITIAL_FLOAT_TARGET
        );
    }

    function test_constructor_RevertsOnZeroRegistry() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultProxy(
            IERC20(address(usdc)),
            INettingRegistry(address(0)),
            callbackProxyAddr,
            strategyRvm,
            INITIAL_FLOAT_TARGET
        );
    }

    function test_constructor_RevertsOnZeroProxy() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultProxy(
            IERC20(address(usdc)),
            INettingRegistry(address(registry)),
            address(0),
            strategyRvm,
            INITIAL_FLOAT_TARGET
        );
    }

    function test_constructor_RevertsOnZeroRvmId() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new VaultProxy(
            IERC20(address(usdc)),
            INettingRegistry(address(registry)),
            callbackProxyAddr,
            address(0),
            INITIAL_FLOAT_TARGET
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            payRebate
    // ═══════════════════════════════════════════════════════════════════════

    function test_payRebate_TransfersUsdcToRecipient() public {
        uint256 balBefore = usdc.balanceOf(alice);

        vm.prank(address(registry));
        proxy.payRebate(alice, 1_000e6);

        assertEq(usdc.balanceOf(alice), balBefore + 1_000e6);
    }

    function test_payRebate_DecrementsProxyBalance() public {
        uint256 balBefore = usdc.balanceOf(address(proxy));

        vm.prank(address(registry));
        proxy.payRebate(alice, 1_000e6);

        assertEq(usdc.balanceOf(address(proxy)), balBefore - 1_000e6);
    }

    function test_payRebate_IncrementsTotalPaid() public {
        vm.prank(address(registry));
        proxy.payRebate(alice, 1_000e6);
        assertEq(proxy.totalRebatesPaid(), 1_000e6);

        vm.prank(address(registry));
        proxy.payRebate(bob, 500e6);
        assertEq(proxy.totalRebatesPaid(), 1_500e6);
    }

    function test_payRebate_OnlyNettingRegistry() public {
        vm.prank(alice);
        vm.expectRevert(Errors.NettingRegistryOnly.selector);
        proxy.payRebate(alice, 1_000e6);
    }

    function test_payRebate_RevertsOnZeroRecipient() public {
        vm.prank(address(registry));
        vm.expectRevert(Errors.ZeroAddress.selector);
        proxy.payRebate(address(0), 1_000e6);
    }

    function test_payRebate_RevertsOnInsufficientFloat() public {
        // Proxy has 50k USDC, request 100k
        vm.prank(address(registry));
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InsufficientFloat.selector, 100_000e6, 50_000e6)
        );
        proxy.payRebate(alice, 100_000e6);
    }

    function test_payRebate_EmitsEvent() public {
        vm.recordLogs();

        vm.prank(address(registry));
        proxy.payRebate(alice, 1_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("RebatePaidLocal(address,uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_payRebate_EmitsFloatLowWhenBalanceLow() public {
        // Proxy has 50k, target is 100k. Half-target = 50k.
        // After paying 5k → balance = 45k, which is < 50k → emit FloatLow.
        vm.recordLogs();

        vm.prank(address(registry));
        proxy.payRebate(alice, 5_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FloatLow(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_payRebate_NoFloatLowWhenBalanceHigh() public {
        // Top up the proxy beyond target so half-target threshold isn't crossed
        usdc.mint(address(proxy), 100_000e6); // now 150k
        // Half-target = 50k. After paying 5k → 145k > 50k. No event.

        vm.recordLogs();

        vm.prank(address(registry));
        proxy.payRebate(alice, 5_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FloatLow(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic, "FloatLow should NOT emit");
        }
    }

    function test_payRebate_NoFloatLowWhenTargetZero() public {
        // Set target = 0, then pay
        vm.prank(callbackProxyAddr);
        proxy.setFloatTarget(strategyRvm, 0);

        vm.recordLogs();
        vm.prank(address(registry));
        proxy.payRebate(alice, 1_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FloatLow(uint256,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != topic);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              refill
    // ═══════════════════════════════════════════════════════════════════════

    function test_refill_OnlyCallbackProxy() public {
        vm.prank(alice);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        proxy.refill(strategyRvm, 50_000e6);
    }

    function test_refill_WrongRvmId_Reverts() public {
        address badRvm = makeAddr("badRvm");
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        proxy.refill(badRvm, 50_000e6);
    }

    function test_refill_EmitsEventWithCurrentBalance() public {
        vm.recordLogs();
        vm.prank(callbackProxyAddr);
        proxy.refill(strategyRvm, 50_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("Refilled(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_refill_DoesNotItselfMoveTokens() public {
        // refill is informational only — verify no balance change.
        uint256 balBefore = usdc.balanceOf(address(proxy));
        vm.prank(callbackProxyAddr);
        proxy.refill(strategyRvm, 50_000e6);
        assertEq(usdc.balanceOf(address(proxy)), balBefore);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          setFloatTarget
    // ═══════════════════════════════════════════════════════════════════════

    function test_setFloatTarget_UpdatesValue() public {
        vm.prank(callbackProxyAddr);
        proxy.setFloatTarget(strategyRvm, 200_000e6);
        assertEq(proxy.floatTarget(), 200_000e6);
    }

    function test_setFloatTarget_OnlyCallbackProxy() public {
        vm.prank(alice);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        proxy.setFloatTarget(strategyRvm, 200_000e6);
    }

    function test_setFloatTarget_WrongRvmId_Reverts() public {
        address badRvm = makeAddr("badRvm");
        vm.prank(callbackProxyAddr);
        vm.expectRevert(Errors.StrategyCallbackOnly.selector);
        proxy.setFloatTarget(badRvm, 200_000e6);
    }

    function test_setFloatTarget_EmitsEvent() public {
        vm.recordLogs();
        vm.prank(callbackProxyAddr);
        proxy.setFloatTarget(strategyRvm, 200_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("FloatTargetUpdated(uint256,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    function test_sweep_TransfersAllUsdcToRecipient() public {
        uint256 proxyBal = usdc.balanceOf(address(proxy));
        uint256 govBalBefore = usdc.balanceOf(gov);

        proxy.sweep(gov);

        assertEq(usdc.balanceOf(address(proxy)), 0);
        assertEq(usdc.balanceOf(gov), govBalBefore + proxyBal);
    }

    function test_sweep_OnlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(Errors.Unauthorized.selector);
        proxy.sweep(alice);
    }

    function test_sweep_RevertsOnZeroRecipient() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        proxy.sweep(address(0));
    }

    function test_sweep_EmptyBalance_StillSucceeds() public {
        // First sweep clears it
        proxy.sweep(gov);
        // Second sweep should not revert even with zero balance
        proxy.sweep(gov);
    }

    function test_transferGovernance_UpdatesGovernance() public {
        proxy.transferGovernance(alice);
        assertEq(proxy.governance(), alice);
    }

    function test_transferGovernance_OldGovCantAct() public {
        proxy.transferGovernance(alice);
        // Old gov (test contract) can no longer sweep
        vm.expectRevert(Errors.Unauthorized.selector);
        proxy.sweep(gov);

        // New gov can
        vm.prank(alice);
        proxy.sweep(alice);
    }

    function test_transferGovernance_OnlyGovernance() public {
        vm.prank(alice);
        vm.expectRevert(Errors.Unauthorized.selector);
        proxy.transferGovernance(alice);
    }

    function test_transferGovernance_ZeroAddress_Reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        proxy.transferGovernance(address(0));
    }
}
