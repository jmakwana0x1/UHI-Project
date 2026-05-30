// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {MatchingRSC} from "../../../src/reactive/MatchingRSC.sol";
import {ReactiveConstants} from "../../../src/reactive/modules/ReactiveConstants.sol";
import {INettingRegistry} from "../../../src/interfaces/INettingRegistry.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import {MockSystemContract} from "../../utils/reactive/MockSystemContract.sol";

/// @notice Test harness exposing internal vm flipping and a fresh heap helper.
contract MatchingRSCHarness is MatchingRSC {
    constructor(
        uint256[] memory chains,
        address[] memory registries,
        uint64 _minCronInterval,
        uint64 _callbackGasLimit,
        uint16 _fIntBps,
        uint16 _alphaBps
    ) MatchingRSC(chains, registries, _minCronInterval, _callbackGasLimit, _fIntBps, _alphaBps) {}

    function forceVmContext() external { vm = true; }
}

contract MatchingRSCTest is Test {
    MatchingRSCHarness internal rsc;
    MockSystemContract internal sys;

    uint256 internal constant HOME_CHAIN = 1301;
    uint256 internal constant OTHER_CHAIN = 84532;

    address internal homeRegistry = makeAddr("homeRegistry");
    address internal otherRegistry = makeAddr("otherRegistry");

    uint64 internal constant MIN_CRON_INTERVAL = 60; // 1 min
    uint64 internal constant CALLBACK_GAS = 500_000;
    uint16 internal constant F_INT_BPS = 1200;
    uint16 internal constant ALPHA_BPS = 500;

    function setUp() public {
        vm.warp(1_000_000);

        sys = new MockSystemContract();
        vm.etch(ReactiveConstants.SYSTEM_CONTRACT, address(sys).code);

        uint256[] memory chains = new uint256[](2);
        chains[0] = HOME_CHAIN;
        chains[1] = OTHER_CHAIN;

        address[] memory registries = new address[](2);
        registries[0] = homeRegistry;
        registries[1] = otherRegistry;

        rsc = new MatchingRSCHarness(
            chains, registries,
            MIN_CRON_INTERVAL, CALLBACK_GAS, F_INT_BPS, ALPHA_BPS
        );

        // Flip to VM context without wiping subscription state.
        rsc.forceVmContext();
        require(rsc.isInVm(), "Failed to enter VM context");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    function _etchedSys() internal view returns (MockSystemContract) {
        return MockSystemContract(payable(ReactiveConstants.SYSTEM_CONTRACT));
    }

    /// @dev Build an LPPositionOpened log.
    function _opened(
        uint256 chainId,
        bytes32 posId,
        int256 signedDelta,
        uint128 gamma,
        uint8 horizonBucket,
        bool unhedged
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0xdead),
            topic_0: ReactiveConstants.TOPIC_LP_POSITION_OPENED,
            topic_1: uint256(posId),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(
                int24(-600), int24(600), uint128(1e18),
                signedDelta, gamma, horizonBucket, unhedged
            ),
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });
    }

    function _closed(uint256 chainId, bytes32 posId)
        internal pure returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0xdead),
            topic_0: ReactiveConstants.TOPIC_LP_POSITION_CLOSED,
            topic_1: uint256(posId),
            topic_2: 0, topic_3: 0,
            data: "",
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });
    }

    function _snapshot(uint256 chainId, uint160 sqrtPriceX96, uint64 ts)
        internal pure returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0xdead),
            topic_0: ReactiveConstants.TOPIC_PRICE_SNAPSHOT,
            topic_1: 0, topic_2: 0, topic_3: 0,
            data: abi.encode(sqrtPriceX96, ts),
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });
    }

    function _cron() internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ReactiveConstants.LASNA_CHAIN_ID,
            _contract: ReactiveConstants.SYSTEM_CONTRACT,
            topic_0: ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER,
            topic_1: 0, topic_2: 0, topic_3: 0,
            data: "",
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });
    }

    /// @dev Count Callback events in vm.recordLogs output.
    function _countCallbacks(Vm.Log[] memory logs) internal pure returns (uint256 count) {
        bytes32 topic = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) count++;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Constructor
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_RegistersRegistries() public view {
        assertEq(rsc.registryByChain(HOME_CHAIN), homeRegistry);
        assertEq(rsc.registryByChain(OTHER_CHAIN), otherRegistry);
    }

    function test_constructor_RegistersSubscriptions() public view {
        // 3 subs per chain * 2 chains + 1 cron = 7 subscriptions
        assertEq(_etchedSys().subscriptionCount(), 7);
    }

    function test_constructor_SubscribesAllEventTypesPerChain() public view {
        MockSystemContract s = _etchedSys();
        assertTrue(s.hasSubscription(address(rsc), HOME_CHAIN, ReactiveConstants.TOPIC_LP_POSITION_OPENED));
        assertTrue(s.hasSubscription(address(rsc), HOME_CHAIN, ReactiveConstants.TOPIC_LP_POSITION_CLOSED));
        assertTrue(s.hasSubscription(address(rsc), HOME_CHAIN, ReactiveConstants.TOPIC_PRICE_SNAPSHOT));
        assertTrue(s.hasSubscription(address(rsc), OTHER_CHAIN, ReactiveConstants.TOPIC_LP_POSITION_OPENED));
        assertTrue(s.hasSubscription(address(rsc), OTHER_CHAIN, ReactiveConstants.TOPIC_LP_POSITION_CLOSED));
        assertTrue(s.hasSubscription(address(rsc), OTHER_CHAIN, ReactiveConstants.TOPIC_PRICE_SNAPSHOT));
    }

    function test_constructor_SubscribesCron() public view {
        MockSystemContract s = _etchedSys();
        assertTrue(s.hasSubscription(
            address(rsc),
            ReactiveConstants.LASNA_CHAIN_ID,
            ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER
        ));
    }

    function test_constructor_RevertsOnArityMismatch() public {
        uint256[] memory chains = new uint256[](2);
        address[] memory regs = new address[](1);
        chains[0] = HOME_CHAIN;
        chains[1] = OTHER_CHAIN;
        regs[0] = homeRegistry;
        vm.expectRevert(Errors.ZeroAddress.selector);
        new MatchingRSCHarness(chains, regs, MIN_CRON_INTERVAL, CALLBACK_GAS, F_INT_BPS, ALPHA_BPS);
    }

    function test_constructor_RevertsOnZeroRegistry() public {
        uint256[] memory chains = new uint256[](1);
        address[] memory regs = new address[](1);
        chains[0] = HOME_CHAIN;
        regs[0] = address(0);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new MatchingRSCHarness(chains, regs, MIN_CRON_INTERVAL, CALLBACK_GAS, F_INT_BPS, ALPHA_BPS);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            position opened
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Opened_AddsCandidate() public {
        bytes32 posId = keccak256("alice-long");
        rsc.react(_opened(HOME_CHAIN, posId, int256(10 ether), 1e18, 1, false));
        assertEq(rsc.candidateCount(), 1);

        MatchingRSC.Candidate memory c = rsc.getCandidate(posId);
        assertTrue(c.exists);
        assertEq(c.posId, posId);
        assertEq(c.originChainId, HOME_CHAIN);
        assertEq(c.signedDelta, int256(10 ether));
        assertFalse(c.matched);
    }

    function test_react_Opened_IgnoresUnhedged() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, true));
        assertEq(rsc.candidateCount(), 0);
    }

    function test_react_Opened_IgnoresZeroDelta() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), 0, 1e18, 1, false));
        assertEq(rsc.candidateCount(), 0);
    }

    function test_react_Opened_DedupsSamePosId() public {
        bytes32 p = keccak256("a");
        rsc.react(_opened(HOME_CHAIN, p, int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(HOME_CHAIN, p, int256(20 ether), 1e18, 1, false));
        // Second add ignored
        assertEq(rsc.candidateCount(), 1);
        MatchingRSC.Candidate memory c = rsc.getCandidate(p);
        assertEq(c.signedDelta, int256(10 ether));
    }

    function test_react_Opened_LongAndShortStored() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("alice"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("bob"), -int256(10 ether), 1e18, 1, false));
        assertEq(rsc.candidateCount(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            position closed
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Closed_RemovesCandidate() public {
        bytes32 p = keccak256("a");
        rsc.react(_opened(HOME_CHAIN, p, int256(10 ether), 1e18, 1, false));
        assertEq(rsc.candidateCount(), 1);

        rsc.react(_closed(HOME_CHAIN, p));
        assertEq(rsc.candidateCount(), 0);
        MatchingRSC.Candidate memory c = rsc.getCandidate(p);
        assertFalse(c.exists);
    }

    function test_react_Closed_NonexistentIsNoop() public {
        rsc.react(_closed(HOME_CHAIN, keccak256("ghost")));
        assertEq(rsc.candidateCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            price snapshot
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Snapshot_DoesNotAddCandidate() public {
        rsc.react(_snapshot(HOME_CHAIN, uint160(1 << 96), uint64(block.timestamp)));
        assertEq(rsc.candidateCount(), 0);
    }

    function test_react_Snapshot_DoesNotRevert() public {
        // Just exercise the path
        for (uint64 i = 0; i < 5; i++) {
            rsc.react(_snapshot(HOME_CHAIN, uint160(1 << 96), uint64(block.timestamp) + i * 60));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            cron: matching
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Cron_NoCandidates_NoCallback() public {
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0);
    }

    function test_react_Cron_OneSidedNoMatch() public {
        // Two longs, no shorts → no match possible
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("b"), int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0);
    }

    function test_react_Cron_SimplePairMatches() public {
        // One long + one short = should match
        bytes32 aliceLong = keccak256("alice-long");
        bytes32 bobShort = keccak256("bob-short");
        rsc.react(_opened(HOME_CHAIN, aliceLong, int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, bobShort, -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Two callbacks: one per chain
        assertEq(_countCallbacks(logs), 2);

        // Both candidates marked matched
        MatchingRSC.Candidate memory alice = rsc.getCandidate(aliceLong);
        MatchingRSC.Candidate memory bob = rsc.getCandidate(bobShort);
        assertTrue(alice.matched);
        assertTrue(bob.matched);
    }

    function test_react_Cron_SameChainMatchEmitsOneCallback() public {
        // Long and short on same chain → only one callback (no duplicate to "other chain")
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(HOME_CHAIN, keccak256("b"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 1);
    }

    function test_react_Cron_MatchesRemovedFromList() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("b"), -int256(10 ether), 1e18, 1, false));
        assertEq(rsc.candidateCount(), 2);

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        rsc.react(_cron());

        // After cron, matched candidates are compacted out of the iteration list
        assertEq(rsc.candidateCount(), 0);
    }

    function test_react_Cron_HigherScoreWinsWhenCompeting() public {
        // Alice (long, gamma=1e18) and Bob (long, gamma=2e18, different horizon) compete
        // for Carol (short). The better-scoring pair wins.
        //
        // Carol's horizon = 1 (matches Alice exactly); Bob's horizon = 2 (adjacent).
        // → Alice-Carol scores higher than Bob-Carol → Alice matched, Bob remains.
        rsc.react(_opened(HOME_CHAIN, keccak256("alice"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(HOME_CHAIN, keccak256("bob"), int256(10 ether), 1e18, 2, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("carol"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        rsc.react(_cron());

        MatchingRSC.Candidate memory alice = rsc.getCandidate(keccak256("alice"));
        MatchingRSC.Candidate memory bob = rsc.getCandidate(keccak256("bob"));
        MatchingRSC.Candidate memory carol = rsc.getCandidate(keccak256("carol"));

        // Alice should be matched (best score with Carol — exact horizon)
        assertTrue(alice.matched);
        assertTrue(carol.matched);
        // Bob is left unmatched
        assertFalse(bob.matched);
    }

    function test_react_Cron_MultipleMatchesInOneTick() public {
        // Two longs + two shorts = two matches
        rsc.react(_opened(HOME_CHAIN, keccak256("alice"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(HOME_CHAIN, keccak256("bob"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("carol"), -int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("dave"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        // 2 matches × 2 callbacks each = 4 callbacks
        assertEq(_countCallbacks(logs), 4);
    }

    function test_react_Cron_Throttles() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("b"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        rsc.react(_cron());

        // Immediately after, second cron should be throttled
        rsc.react(_opened(HOME_CHAIN, keccak256("c"), int256(5 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("d"), -int256(5 ether), 1e18, 1, false));

        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Throttle hit; no callbacks emitted
        assertEq(_countCallbacks(logs), 0);
    }

    function test_react_Cron_CallbackPayloadEncodesRecordMatch() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("alice"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("bob"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackTopic) {
                bytes memory payload = abi.decode(logs[i].data, (bytes));
                bytes4 selector = bytes4(payload);
                assertEq(selector, INettingRegistry.recordMatch.selector);
                return; // first one is enough
            }
        }
        revert("no callback found");
    }

    function test_react_Cron_CallbackTargetsCorrectRegistry() public {
        rsc.react(_opened(HOME_CHAIN, keccak256("alice"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("bob"), -int256(10 ether), 1e18, 1, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");

        bool foundHome;
        bool foundOther;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != callbackTopic) continue;
            uint256 destChain = uint256(logs[i].topics[1]);
            address destContract = address(uint160(uint256(logs[i].topics[2])));
            if (destChain == HOME_CHAIN && destContract == homeRegistry) foundHome = true;
            if (destChain == OTHER_CHAIN && destContract == otherRegistry) foundOther = true;
        }
        assertTrue(foundHome, "home callback missing");
        assertTrue(foundOther, "other callback missing");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Eviction
    // ═══════════════════════════════════════════════════════════════════════

    function test_eviction_CapacityCapEnforced() public {
        // Push MAX_CANDIDATES + 1 = 33 positions; oldest should be evicted
        uint32 max = rsc.MAX_CANDIDATES();
        for (uint256 i = 0; i < max + 1; i++) {
            // Alternate signs so they could theoretically match later
            int256 d = i % 2 == 0 ? int256(1 ether) : -int256(1 ether);
            // Different timestamps so eviction order is deterministic
            vm.warp(1_000_000 + i);
            rsc.react(_opened(HOME_CHAIN, keccak256(abi.encode(i)), d, 1e18, 1, false));
        }
        assertEq(rsc.candidateCount(), max);
    }

    function test_eviction_OldestRemoved() public {
        uint32 max = rsc.MAX_CANDIDATES();
        bytes32 oldestId = keccak256(abi.encode(uint256(0)));

        for (uint256 i = 0; i < max + 1; i++) {
            int256 d = i % 2 == 0 ? int256(1 ether) : -int256(1 ether);
            vm.warp(1_000_000 + i);
            rsc.react(_opened(HOME_CHAIN, keccak256(abi.encode(i)), d, 1e18, 1, false));
        }
        // First-pushed candidate is now evicted
        MatchingRSC.Candidate memory c = rsc.getCandidate(oldestId);
        assertFalse(c.exists);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Unknown topic
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_UnknownTopic_SilentlyIgnored() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: HOME_CHAIN,
            _contract: address(0xdead),
            topic_0: uint256(keccak256("Unknown()")),
            topic_1: 0, topic_2: 0, topic_3: 0,
            data: "",
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });
        rsc.react(log);
        assertEq(rsc.candidateCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Mismatched-horizon rejection
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Cron_HorizonGapRejectsMatch() public {
        // Alice horizon=0, Bob horizon=3 → distance 3 > tolerance 1 → no match
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 0, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("b"), -int256(10 ether), 1e18, 3, false));

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0);
    }

    function test_react_Cron_GammaMismatchRejectsMatch() public {
        // |γA - γB| / max(γA, γB) > 50% → reject
        rsc.react(_opened(HOME_CHAIN, keccak256("a"), int256(10 ether), 1e18, 1, false));
        rsc.react(_opened(OTHER_CHAIN, keccak256("b"), -int256(10 ether), uint128(3e18), 1, false));
        // gamma diff / max = 2/3 ≈ 66.6% > 50% → rejected

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_cron());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countCallbacks(logs), 0);
    }
}
