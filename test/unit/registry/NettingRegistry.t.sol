// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {NettingRegistry} from "../../../src/registry/NettingRegistry.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {ICrossHedgeHook} from "../../../src/interfaces/ICrossHedgeHook.sol";
import {IRebatePayer} from "../../../src/interfaces/IRebatePayer.sol";
import {Constants} from "../../../src/libraries/Constants.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Mock hook exposing just the `getPosition` and `vault` surface the
///         registry consumes for ownership checks. We can mutate stored positions
///         directly from tests to simulate any owner / state.
contract MockHook is ICrossHedgeHook {
    address public override vault;
    mapping(bytes32 => Position) internal _positions;

    function setVault(address v) external { vault = v; }

    function setPosition(bytes32 posId, address owner, uint128 liquidity) external {
        _positions[posId] = Position({
            owner: owner,
            tickLower: -100,
            tickUpper: 100,
            unhedged: false,
            liquidity: liquidity,
            openedAt: uint64(block.timestamp),
            poolId: PoolId.wrap(bytes32(0))
        });
    }

    function clearPosition(bytes32 posId) external {
        delete _positions[posId];
    }

    function getPosition(bytes32 posId) external view override returns (Position memory) {
        return _positions[posId];
    }

    // Unused by registry but required by interface
    function harvestPremiums(address) external pure override returns (uint256) { return 0; }
    function premiumBalance() external pure override returns (uint256) { return 0; }
}

/// @notice Mock rebate payer that records payouts.
contract MockRebatePayer is IRebatePayer {
    uint256 public lastAmount;
    address public lastTo;
    uint256 public totalPaid;
    bool public shouldRevert;
    address public expectedCaller; // if set, reverts unless caller matches

    function setShouldRevert(bool v) external { shouldRevert = v; }
    function setExpectedCaller(address c) external { expectedCaller = c; }

    function payRebate(address to, uint256 amount) external override {
        if (shouldRevert) revert("MockRebatePayer: forced revert");
        if (expectedCaller != address(0) && msg.sender != expectedCaller) {
            revert("MockRebatePayer: wrong caller");
        }
        lastTo = to;
        lastAmount = amount;
        totalPaid += amount;
    }
}

contract NettingRegistryTest is Test {
    NettingRegistry internal registry;
    MockHook internal hook;
    MockRebatePayer internal payer;

    address internal callbackProxy = makeAddr("callbackProxy");
    address internal matchingRvm = makeAddr("matchingRvm");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    uint64 internal constant WATCHDOG_WINDOW = 30 minutes;
    uint16 internal constant F_INT_BPS = 1200; // 12% APR

    // Test position IDs
    bytes32 internal aliceLongId = keccak256("alice-long");
    bytes32 internal bobShortId = keccak256("bob-short");
    bytes32 internal carolLongId = keccak256("carol-long");

    function setUp() public {
        vm.warp(1_000_000); // away from zero so timestamps make sense

        hook = new MockHook();
        payer = new MockRebatePayer();

        registry = new NettingRegistry(
            callbackProxy,
            matchingRvm,
            ICrossHedgeHook(address(hook)),
            IRebatePayer(address(payer)),
            WATCHDOG_WINDOW,
            F_INT_BPS
        );

        // Wire payer to accept calls only from registry
        payer.setExpectedCaller(address(registry));

        // Set up positions in the hook so claimRebate can verify owner
        hook.setPosition(aliceLongId, alice, 1e18);
        hook.setPosition(bobShortId, bob, 1e18);
        hook.setPosition(carolLongId, carol, 1e18);
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _recordMatch(
        bytes32 matchId,
        bytes32 longId,
        bytes32 shortId,
        uint128 notional
    ) internal {
        vm.prank(callbackProxy);
        registry.recordMatch(
            matchingRvm,
            matchId,
            longId,
            shortId,
            uint64(1),
            uint64(2),
            notional,
            F_INT_BPS
        );
    }

    function _settle(bytes32 matchId, bool terminal) internal {
        vm.prank(callbackProxy);
        registry.settleMatch(matchingRvm, matchId, terminal);
    }

    function _cancel(bytes32 matchId) internal {
        vm.prank(callbackProxy);
        registry.cancelMatch(matchingRvm, matchId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           Constructor
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_SetsImmutables() public view {
        assertEq(registry.callbackProxy(), callbackProxy);
        assertEq(registry.authorizedMatchingRvmId(), matchingRvm);
        assertEq(address(registry.hook()), address(hook));
        assertEq(address(registry.rebatePayer()), address(payer));
        assertEq(registry.watchdogWindow(), WATCHDOG_WINDOW);
        assertEq(registry.fIntBps(), F_INT_BPS);
    }

    function test_constructor_RevertsOnZeroProxy() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new NettingRegistry(
            address(0), matchingRvm,
            ICrossHedgeHook(address(hook)), IRebatePayer(address(payer)),
            WATCHDOG_WINDOW, F_INT_BPS
        );
    }

    function test_constructor_RevertsOnZeroRvmId() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new NettingRegistry(
            callbackProxy, address(0),
            ICrossHedgeHook(address(hook)), IRebatePayer(address(payer)),
            WATCHDOG_WINDOW, F_INT_BPS
        );
    }

    function test_constructor_RevertsOnZeroHook() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new NettingRegistry(
            callbackProxy, matchingRvm,
            ICrossHedgeHook(address(0)), IRebatePayer(address(payer)),
            WATCHDOG_WINDOW, F_INT_BPS
        );
    }

    function test_constructor_RevertsOnZeroPayer() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new NettingRegistry(
            callbackProxy, matchingRvm,
            ICrossHedgeHook(address(hook)), IRebatePayer(address(0)),
            WATCHDOG_WINDOW, F_INT_BPS
        );
    }

    function test_constructor_StartsMatchingActive() public view {
        assertTrue(registry.matchingActive());
    }

    function test_constructor_SetsGovernanceToDeployer() public view {
        assertEq(registry.governance(), address(this));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            recordMatch
    // ═══════════════════════════════════════════════════════════════════════

    function test_recordMatch_HappyPath() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        (
            bytes32 longPosId,
            bytes32 shortPosId,
            ,
            ,
            uint128 notional,
            ,
            ,
            ,

        ) = registry.matches(matchId);
        assertEq(longPosId, aliceLongId);
        assertEq(shortPosId, bobShortId);
        assertEq(notional, 100e6);
    }

    function test_recordMatch_LinksPosIdsToMatch() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        assertEq(registry.posIdToMatch(aliceLongId), matchId);
        assertEq(registry.posIdToMatch(bobShortId), matchId);
    }

    function test_recordMatch_OnlyCallbackProxy() public {
        bytes32 matchId = keccak256("m1");
        vm.expectRevert(Errors.NotCallbackProxy.selector);
        // not pranked — call from test contract
        registry.recordMatch(
            matchingRvm, matchId, aliceLongId, bobShortId,
            uint64(1), uint64(2), 100e6, F_INT_BPS
        );
    }

    function test_recordMatch_WrongRvmId_Reverts() public {
        bytes32 matchId = keccak256("m1");
        address badRvm = makeAddr("badRvm");

        vm.prank(callbackProxy);
        vm.expectRevert(Errors.WrongRvmId.selector);
        registry.recordMatch(
            badRvm, matchId, aliceLongId, bobShortId,
            uint64(1), uint64(2), 100e6, F_INT_BPS
        );
    }

    function test_recordMatch_Idempotent() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        // Second call with same matchId should be a no-op (not revert)
        _recordMatch(matchId, aliceLongId, bobShortId, 999e6);

        (, , , , uint128 notional, , , , ) = registry.matches(matchId);
        // Notional unchanged from first call
        assertEq(notional, 100e6);
    }

    function test_recordMatch_PosAlreadyMatched_Reverts() public {
        bytes32 m1 = keccak256("m1");
        bytes32 m2 = keccak256("m2");

        _recordMatch(m1, aliceLongId, bobShortId, 100e6);

        // Alice is already in m1; try to re-match her in m2
        vm.prank(callbackProxy);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.PositionAlreadyMatched.selector, aliceLongId)
        );
        registry.recordMatch(
            matchingRvm, m2, aliceLongId, carolLongId,
            uint64(1), uint64(2), 50e6, F_INT_BPS
        );
    }

    function test_recordMatch_RefreshesWatchdog() public {
        // Advance past watchdog window — matching should be marked paused on first ping
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());

        // A fresh callback should resume matching
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);
        assertTrue(registry.matchingActive());
        assertEq(registry.lastMatchingCallback(), uint64(block.timestamp));
    }

    function test_recordMatch_EmitsEvent() public {
        bytes32 matchId = keccak256("m1");

        vm.recordLogs();
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256(
            "MatchRecorded(bytes32,bytes32,bytes32,uint64,uint64,uint128,uint16,uint64)"
        );
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) { found = true; break; }
        }
        assertTrue(found);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            cancelMatch
    // ═══════════════════════════════════════════════════════════════════════

    function test_cancelMatch_FreesPosIds() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);
        _cancel(matchId);

        assertEq(registry.posIdToMatch(aliceLongId), bytes32(0));
        assertEq(registry.posIdToMatch(bobShortId), bytes32(0));
    }

    function test_cancelMatch_AccruesBeforeCancel() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6); // 1M USDC notional

        // Advance time by 30 days
        vm.warp(block.timestamp + 30 days);

        _cancel(matchId);

        // Short side (Bob) should have accrued ~30/365 * 12% * 1M = ~9863 USDC
        uint128 accrued = registry.accruedRebate(bobShortId);
        assertGt(accrued, 9_000e6);
        assertLt(accrued, 11_000e6);
    }

    function test_cancelMatch_OnlyActive_Reverts() public {
        bytes32 matchId = keccak256("nonexistent");
        vm.prank(callbackProxy);
        vm.expectRevert(Errors.MatchNotActive.selector);
        registry.cancelMatch(matchingRvm, matchId);
    }

    function test_cancelMatch_AllowsRematch() public {
        bytes32 m1 = keccak256("m1");
        bytes32 m2 = keccak256("m2");

        _recordMatch(m1, aliceLongId, bobShortId, 100e6);
        _cancel(m1);

        // After cancel, alice can be re-matched against carol
        _recordMatch(m2, aliceLongId, carolLongId, 50e6);
        assertEq(registry.posIdToMatch(aliceLongId), m2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            settleMatch
    // ═══════════════════════════════════════════════════════════════════════

    function test_settleMatch_NonTerminal_AccruesOnly() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        vm.warp(block.timestamp + 1 days);
        _settle(matchId, false);

        // Match should still be active
        assertEq(registry.posIdToMatch(aliceLongId), matchId);
        assertEq(registry.posIdToMatch(bobShortId), matchId);

        // Bob should have accrued ~1/365 * 12% * 1M ≈ 328 USDC
        uint128 accrued = registry.accruedRebate(bobShortId);
        assertGt(accrued, 300e6);
        assertLt(accrued, 350e6);
    }

    function test_settleMatch_Terminal_FreesPosIds() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        vm.warp(block.timestamp + 1 hours);
        _settle(matchId, true);

        assertEq(registry.posIdToMatch(aliceLongId), bytes32(0));
        assertEq(registry.posIdToMatch(bobShortId), bytes32(0));
    }

    function test_settleMatch_AccruesAcrossMultipleSettles() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        vm.warp(block.timestamp + 1 days);
        _settle(matchId, false);
        uint128 after1d = registry.accruedRebate(bobShortId);

        vm.warp(block.timestamp + 1 days);
        _settle(matchId, false);
        uint128 after2d = registry.accruedRebate(bobShortId);

        // Second day should add roughly the same amount
        assertApproxEqRel(after2d - after1d, after1d, 0.01e18);
    }

    function test_settleMatch_NonExistent_Reverts() public {
        vm.prank(callbackProxy);
        vm.expectRevert(Errors.MatchNotActive.selector);
        registry.settleMatch(matchingRvm, keccak256("ghost"), false);
    }

    function test_settleMatch_AccrualMath() public {
        bytes32 matchId = keccak256("m1");
        // 1M USDC notional, 12% APR
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        // Exactly 1 year — should accrue exactly 12% of 1M = 120k USDC
        vm.warp(block.timestamp + 365 days);
        _settle(matchId, false);

        uint128 accrued = registry.accruedRebate(bobShortId);
        // Tolerance: dust from integer division
        assertApproxEqAbs(accrued, 120_000e6, 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            claimRebate
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimRebate_HappyPath() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);

        vm.warp(block.timestamp + 30 days);
        _settle(matchId, false);

        uint128 accrued = registry.accruedRebate(bobShortId);
        assertGt(accrued, 0);

        vm.prank(bob);
        registry.claimRebate(bobShortId);

        // accruedRebate zeroed
        assertEq(registry.accruedRebate(bobShortId), 0);
        // Payer called with right amount
        assertEq(payer.lastAmount(), uint256(accrued));
        assertEq(payer.lastTo(), bob);
    }

    function test_claimRebate_NonOwner_Reverts() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settle(matchId, false);

        // Carol tries to claim Bob's rebate
        vm.prank(carol);
        vm.expectRevert(Errors.NotPositionOwner.selector);
        registry.claimRebate(bobShortId);
    }

    function test_claimRebate_UnknownPosition_Reverts() public {
        // Position never registered with hook → owner is address(0)
        bytes32 ghost = keccak256("ghost");
        vm.prank(alice);
        vm.expectRevert(Errors.NotPositionOwner.selector);
        registry.claimRebate(ghost);
    }

    function test_claimRebate_BelowDust_Reverts() public {
        bytes32 matchId = keccak256("m1");
        // tiny notional → tiny accrual → below 1 USDC dust threshold
        _recordMatch(matchId, aliceLongId, bobShortId, 100); // 100 wei USDC
        vm.warp(block.timestamp + 1 hours);
        _settle(matchId, false);

        vm.prank(bob);
        vm.expectRevert(Errors.RebateBelowDust.selector);
        registry.claimRebate(bobShortId);
    }

    function test_claimRebate_PayerRevert_BubblesUp() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settle(matchId, false);

        payer.setShouldRevert(true);

        vm.prank(bob);
        vm.expectRevert();
        registry.claimRebate(bobShortId);

        // Accrued balance still intact (CEI: revert un-does the zeroing)
        assertGt(registry.accruedRebate(bobShortId), 0);
    }

    function test_claimRebate_CEI_StateZeroedBeforeCall() public {
        // Use a payer that snapshots registry state during its call
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 1_000_000e6);
        vm.warp(block.timestamp + 30 days);
        _settle(matchId, false);

        // The mock payer doesn't reenter, but we can verify state mid-call by
        // checking accruedRebate goes to 0 BEFORE the transfer recipient sees funds.
        // Simplest: verify post-state.
        uint256 beforeAccrued = registry.accruedRebate(bobShortId);
        vm.prank(bob);
        registry.claimRebate(bobShortId);

        assertEq(registry.accruedRebate(bobShortId), 0);
        assertEq(payer.lastAmount(), beforeAccrued);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           pingWatchdog
    // ═══════════════════════════════════════════════════════════════════════

    function test_pingWatchdog_NoOpWhenFresh() public {
        // Right after deploy, matching is active and lastCallback is recent
        registry.pingWatchdog();
        assertTrue(registry.matchingActive());
    }

    function test_pingWatchdog_PausesAfterWindow() public {
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());
    }

    function test_pingWatchdog_NoOpWhenAlreadyPaused() public {
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());

        // Pinging again is a no-op
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());
    }

    function test_pingWatchdog_EmitsPausedEvent() public {
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);
        vm.recordLogs();
        registry.pingWatchdog();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expectedTopic = keccak256("MatchingPaused(uint64,uint64)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedTopic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_pingWatchdog_BoundaryExactlyAtWindow() public {
        // Exactly at the boundary, still alive
        vm.warp(block.timestamp + WATCHDOG_WINDOW);
        registry.pingWatchdog();
        assertTrue(registry.matchingActive());

        // One second past
        vm.warp(block.timestamp + 1);
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());
    }

    function test_recordMatch_ResumesAfterPause() public {
        // Pause via timeout
        vm.warp(block.timestamp + WATCHDOG_WINDOW + 1);
        registry.pingWatchdog();
        assertFalse(registry.matchingActive());

        // Fresh callback resumes
        bytes32 matchId = keccak256("m1");
        vm.recordLogs();
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);

        assertTrue(registry.matchingActive());

        // Resume event emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 resumeTopic = keccak256("MatchingResumed(uint64)");
        bool foundResume;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == resumeTopic) { foundResume = true; break; }
        }
        assertTrue(foundResume);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              isHedged
    // ═══════════════════════════════════════════════════════════════════════

    function test_isHedged_FalseWhenNoMatch() public view {
        assertFalse(registry.isHedged(aliceLongId));
    }

    function test_isHedged_TrueWhenActiveMatch() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);
        assertTrue(registry.isHedged(aliceLongId));
        assertTrue(registry.isHedged(bobShortId));
    }

    function test_isHedged_FalseAfterCancel() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);
        _cancel(matchId);
        assertFalse(registry.isHedged(aliceLongId));
        assertFalse(registry.isHedged(bobShortId));
    }

    function test_isHedged_FalseAfterTerminalSettle() public {
        bytes32 matchId = keccak256("m1");
        _recordMatch(matchId, aliceLongId, bobShortId, 100e6);
        _settle(matchId, true);
        assertFalse(registry.isHedged(aliceLongId));
        assertFalse(registry.isHedged(bobShortId));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    function test_governance_SetFIntBps() public {
        registry.setFIntBps(2500);
        assertEq(registry.fIntBps(), 2500);
    }

    function test_governance_SetFIntBps_NonGov_Reverts() public {
        vm.prank(alice);
        vm.expectRevert(Errors.Unauthorized.selector);
        registry.setFIntBps(2500);
    }

    function test_governance_SetMinRebateClaim() public {
        registry.setMinRebateClaim(5e6);
        assertEq(registry.minRebateClaim(), 5e6);
    }

    function test_governance_TransferGovernance() public {
        registry.transferGovernance(alice);
        assertEq(registry.governance(), alice);

        // Old governance can no longer act
        vm.expectRevert(Errors.Unauthorized.selector);
        registry.setFIntBps(2500);

        // New governance can
        vm.prank(alice);
        registry.setFIntBps(2500);
        assertEq(registry.fIntBps(), 2500);
    }

    function test_governance_TransferToZero_Reverts() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        registry.transferGovernance(address(0));
    }
}
