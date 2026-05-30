// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

import {StrategyRSC} from "../../../src/reactive/StrategyRSC.sol";
import {ReactiveConstants} from "../../../src/reactive/modules/ReactiveConstants.sol";
import {ICrossHedgeVault} from "../../../src/interfaces/ICrossHedgeVault.sol";
import {Errors} from "../../../src/libraries/Errors.sol";

import {MockSystemContract} from "../../utils/reactive/MockSystemContract.sol";

/// @notice Test-only subclass that exposes detectVm() and lets us flip the
///         vm flag between RN-context (for constructor) and VM-context
///         (for react() calls).
contract StrategyRSCHarness is StrategyRSC {
    constructor(
        uint256 _homeChainId,
        address _vaultAddress,
        uint64 _minCronInterval,
        uint64 _callbackGasLimit,
        uint16 _alphaBps,
        uint256[] memory subscribeChainIds
    ) StrategyRSC(
        _homeChainId,
        _vaultAddress,
        _minCronInterval,
        _callbackGasLimit,
        _alphaBps,
        subscribeChainIds
    ) {}

    /// @notice Re-run vm detection. Useful in tests where we toggle code at
    ///         the SERVICE_ADDR between RN-context (mock etched) and VM-context
    ///         (mock removed via vm.etch(addr, "")).
    function recheckVm() external {
        detectVm();
    }

    /// @notice Test-only: directly flip the `vm` flag to true so react() can
    ///         be called without having to wipe the code at SERVICE_ADDR
    ///         (which would also wipe the subscription storage we want to
    ///         assert against).
    function forceVmContext() external {
        vm = true;
    }
}

contract StrategyRSCTest is Test {
    StrategyRSCHarness internal rsc;
    MockSystemContract internal sys;

    address internal vault = makeAddr("vault");
    uint256 internal constant HOME_CHAIN = 1301; // Unichain Sepolia
    uint256 internal constant OTHER_CHAIN = 84532; // Base Sepolia

    uint64 internal constant MIN_CRON_INTERVAL = 1 hours;
    uint64 internal constant CALLBACK_GAS = 2_000_000;
    uint16 internal constant ALPHA_BPS = 500;

    function setUp() public {
        vm.warp(1_000_000);

        // ─── Etch a MockSystemContract at the canonical address ──────────
        // AbstractReactive's constructor checks for code at 0x...fffFfF.
        // If code is present → RN context → subscriptions work.
        // If empty → VM context → react() works.
        // We start in RN context for the constructor.
        sys = new MockSystemContract();
        vm.etch(ReactiveConstants.SYSTEM_CONTRACT, address(sys).code);
        // Wire the etched contract to the mock's storage by re-pointing it.
        // The etched code expects its own storage layout; since vm.etch only
        // copies code, storage is empty at the etched address. We delegate
        // all subscribe() calls through the etched contract — its storage
        // accumulates the subscriptions directly.

        // Deploy strategy in RN context — subscriptions register against the
        // etched system contract at SERVICE_ADDR.
        uint256[] memory chains = new uint256[](2);
        chains[0] = HOME_CHAIN;
        chains[1] = OTHER_CHAIN;

        rsc = new StrategyRSCHarness(
            HOME_CHAIN,
            vault,
            MIN_CRON_INTERVAL,
            CALLBACK_GAS,
            ALPHA_BPS,
            chains
        );

        // ─── Flip to VM context for react() calls ───────────────────────
        // We CANNOT wipe code at SERVICE_ADDR — that would also lose the
        // subscription storage we accumulated during construction (the
        // failing 4 tests would then have nothing to assert against).
        // Instead, directly flip the internal `vm` flag via the harness.
        rsc.forceVmContext();
        require(rsc.isInVm(), "Failed to enter VM context");
    }

    // ─── Helpers ────────────────────────────────────────────────────────────

    /// @dev Returns the etched mock system contract's view. Since we etched
    ///      the mock's code (not its storage), the etched address holds the
    ///      subscriptions accumulated there. We read them by typing the
    ///      SERVICE_ADDR as MockSystemContract.
    function _etchedSys() internal view returns (MockSystemContract) {
        return MockSystemContract(payable(ReactiveConstants.SYSTEM_CONTRACT));
    }

    function _buildPriceSnapshotLog(
        uint256 chainId,
        bytes32 poolId,
        uint160 sqrtPriceX96,
        uint64 timestamp
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0xdead),
            topic_0: ReactiveConstants.TOPIC_PRICE_SNAPSHOT,
            topic_1: uint256(poolId),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(sqrtPriceX96, timestamp),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildMatchRecordedLog(
        uint256 chainId,
        bytes32 matchId,
        bytes32 longPosId,
        bytes32 shortPosId,
        uint64 longChainId,
        uint64 shortChainId,
        uint128 matchedNotional,
        uint16 fIntBps,
        uint64 timestamp
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: chainId,
            _contract: address(0xdead),
            topic_0: ReactiveConstants.TOPIC_MATCH_RECORDED,
            topic_1: uint256(matchId),
            topic_2: uint256(longPosId),
            topic_3: uint256(shortPosId),
            data: abi.encode(longChainId, shortChainId, matchedNotional, fIntBps, timestamp),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function _buildCronLog() internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: ReactiveConstants.LASNA_CHAIN_ID,
            _contract: ReactiveConstants.SYSTEM_CONTRACT,
            topic_0: ReactiveConstants.CRON_TOPIC_SLOW_PLACEHOLDER,
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: "",
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                           Constructor
    // ═══════════════════════════════════════════════════════════════════════

    function test_constructor_SetsImmutables() public view {
        assertEq(rsc.homeChainId(), HOME_CHAIN);
        assertEq(rsc.vaultAddress(), vault);
        assertEq(rsc.minCronInterval(), MIN_CRON_INTERVAL);
        assertEq(rsc.callbackGasLimit(), CALLBACK_GAS);
        assertEq(rsc.alphaBps(), ALPHA_BPS);
    }

    function test_constructor_RegistersSubscriptions() public view {
        MockSystemContract sysAtAddr = _etchedSys();

        // Per chain (2 chains): one PriceSnapshot sub + one MatchRecorded sub
        // Plus one cron sub on Lasna
        // Total: 2 * 2 + 1 = 5 subscriptions
        assertEq(sysAtAddr.subscriptionCount(), 5);
    }

    function test_constructor_SubscribesPriceSnapshotPerChain() public view {
        MockSystemContract sysAtAddr = _etchedSys();
        assertTrue(sysAtAddr.hasSubscription(
            address(rsc), HOME_CHAIN, ReactiveConstants.TOPIC_PRICE_SNAPSHOT
        ));
        assertTrue(sysAtAddr.hasSubscription(
            address(rsc), OTHER_CHAIN, ReactiveConstants.TOPIC_PRICE_SNAPSHOT
        ));
    }

    function test_constructor_SubscribesMatchRecordedPerChain() public view {
        MockSystemContract sysAtAddr = _etchedSys();
        assertTrue(sysAtAddr.hasSubscription(
            address(rsc), HOME_CHAIN, ReactiveConstants.TOPIC_MATCH_RECORDED
        ));
        assertTrue(sysAtAddr.hasSubscription(
            address(rsc), OTHER_CHAIN, ReactiveConstants.TOPIC_MATCH_RECORDED
        ));
    }

    function test_constructor_SubscribesCronOnLasna() public view {
        MockSystemContract sysAtAddr = _etchedSys();
        assertTrue(sysAtAddr.hasSubscription(
            address(rsc),
            ReactiveConstants.LASNA_CHAIN_ID,
            ReactiveConstants.CRON_TOPIC_SLOW_PLACEHOLDER
        ));
    }

    function test_constructor_RevertsOnZeroVault() public {
        uint256[] memory chains = new uint256[](0);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new StrategyRSCHarness(HOME_CHAIN, address(0), MIN_CRON_INTERVAL, CALLBACK_GAS, ALPHA_BPS, chains);
    }

    function test_constructor_RevertsOnZeroHomeChain() public {
        uint256[] memory chains = new uint256[](0);
        vm.expectRevert(Errors.ZeroAddress.selector);
        new StrategyRSCHarness(0, vault, MIN_CRON_INTERVAL, CALLBACK_GAS, ALPHA_BPS, chains);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            react: PriceSnapshot
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_PriceSnapshot_StoresVolSample() public {
        bytes32 poolId = keccak256("pool1");
        IReactive.LogRecord memory log = _buildPriceSnapshotLog(
            HOME_CHAIN, poolId, uint160(1 << 96), uint64(block.timestamp)
        );
        rsc.react(log);

        (, , bool initialized, uint32 sampleCount) = rsc.getPoolState(HOME_CHAIN, poolId);
        assertTrue(initialized);
        assertEq(sampleCount, 1);
    }

    function test_react_PriceSnapshot_TracksPool() public {
        bytes32 poolId = keccak256("pool1");
        IReactive.LogRecord memory log = _buildPriceSnapshotLog(
            HOME_CHAIN, poolId, uint160(1 << 96), uint64(block.timestamp)
        );
        rsc.react(log);

        assertEq(rsc.trackedPoolCount(), 1);
        (uint256 cid, bytes32 pid) = rsc.trackedPool(0);
        assertEq(cid, HOME_CHAIN);
        assertEq(pid, poolId);
    }

    function test_react_PriceSnapshot_AccumulatesAcrossSamples() public {
        bytes32 poolId = keccak256("pool1");
        uint64 t = uint64(block.timestamp);
        uint160 p = uint160(1 << 96);

        for (uint64 i = 0; i < 5; i++) {
            IReactive.LogRecord memory log = _buildPriceSnapshotLog(
                HOME_CHAIN, poolId, p, t + i * 60
            );
            rsc.react(log);
        }

        (, , , uint32 sampleCount) = rsc.getPoolState(HOME_CHAIN, poolId);
        assertEq(sampleCount, 5);
    }

    function test_react_PriceSnapshot_SeparatePerChain() public {
        bytes32 poolId = keccak256("pool1");
        uint64 t = uint64(block.timestamp);

        IReactive.LogRecord memory log1 = _buildPriceSnapshotLog(
            HOME_CHAIN, poolId, uint160(1 << 96), t
        );
        IReactive.LogRecord memory log2 = _buildPriceSnapshotLog(
            OTHER_CHAIN, poolId, uint160(1 << 96), t
        );
        rsc.react(log1);
        rsc.react(log2);

        // Same poolId across two chains tracked as separate entries
        assertEq(rsc.trackedPoolCount(), 2);

        (, , bool initHome,) = rsc.getPoolState(HOME_CHAIN, poolId);
        (, , bool initOther,) = rsc.getPoolState(OTHER_CHAIN, poolId);
        assertTrue(initHome);
        assertTrue(initOther);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          react: MatchRecorded
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_MatchRecorded_AccumulatesNotional() public {
        IReactive.LogRecord memory log = _buildMatchRecordedLog(
            HOME_CHAIN,
            keccak256("m1"), keccak256("alice-long"), keccak256("bob-short"),
            uint64(HOME_CHAIN), uint64(OTHER_CHAIN),
            uint128(1_000_000e6), 1200, uint64(block.timestamp)
        );
        rsc.react(log);

        (uint128 totalNotional, , ,) = rsc.getPoolState(HOME_CHAIN, bytes32(0));
        assertEq(totalNotional, 1_000_000e6);
    }

    function test_react_MatchRecorded_AccumulatesMultiple() public {
        for (uint256 i = 0; i < 3; i++) {
            IReactive.LogRecord memory log = _buildMatchRecordedLog(
                HOME_CHAIN,
                keccak256(abi.encode(i)), keccak256("alice"), keccak256("bob"),
                uint64(HOME_CHAIN), uint64(OTHER_CHAIN),
                uint128(100_000e6), 1200, uint64(block.timestamp)
            );
            rsc.react(log);
        }
        (uint128 totalNotional, , ,) = rsc.getPoolState(HOME_CHAIN, bytes32(0));
        assertEq(totalNotional, 300_000e6);
    }

    function test_react_MatchRecorded_AttributedToLongChain() public {
        // Even if event arrives via OTHER_CHAIN, it should be attributed to
        // the long side's chain (HOME_CHAIN here).
        IReactive.LogRecord memory log = _buildMatchRecordedLog(
            OTHER_CHAIN, // event came from other chain
            keccak256("m1"), keccak256("alice"), keccak256("bob"),
            uint64(HOME_CHAIN), // long is on home chain
            uint64(OTHER_CHAIN),
            uint128(500_000e6), 1200, uint64(block.timestamp)
        );
        rsc.react(log);

        // Notional booked under HOME_CHAIN sentinel, not OTHER_CHAIN
        (uint128 homeNotional, , ,) = rsc.getPoolState(HOME_CHAIN, bytes32(0));
        (uint128 otherNotional, , ,) = rsc.getPoolState(OTHER_CHAIN, bytes32(0));
        assertEq(homeNotional, 500_000e6);
        assertEq(otherNotional, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          react: Cron
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_Cron_EmitsCallback() public {
        // Record some notional so the cron has something to emit about
        IReactive.LogRecord memory matchLog = _buildMatchRecordedLog(
            HOME_CHAIN,
            keccak256("m1"), keccak256("alice"), keccak256("bob"),
            uint64(HOME_CHAIN), uint64(OTHER_CHAIN),
            uint128(1_000_000e6), 1200, uint64(block.timestamp)
        );
        rsc.react(matchLog);

        // Advance time past minCronInterval
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);

        // Fire cron
        IReactive.LogRecord memory cronLog = _buildCronLog();
        vm.recordLogs();
        rsc.react(cronLog);

        // Look for Callback event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackTopic) {
                // Verify the callback targets the home chain + vault address
                uint256 destChain = uint256(logs[i].topics[1]);
                address destContract = address(uint160(uint256(logs[i].topics[2])));
                assertEq(destChain, HOME_CHAIN);
                assertEq(destContract, vault);
                found = true;
                break;
            }
        }
        assertTrue(found, "Callback event not emitted");
    }

    function test_react_Cron_ThrottlesWithinInterval() public {
        // First cron — should fire
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_buildCronLog());

        Vm.Log[] memory logs1 = vm.getRecordedLogs();
        uint256 callbacks1;
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs1.length; i++) {
            if (logs1[i].topics[0] == callbackTopic) callbacks1++;
        }
        assertEq(callbacks1, 1);

        // Immediately fire another cron — should be throttled
        vm.recordLogs();
        rsc.react(_buildCronLog());

        Vm.Log[] memory logs2 = vm.getRecordedLogs();
        uint256 callbacks2;
        for (uint256 i = 0; i < logs2.length; i++) {
            if (logs2[i].topics[0] == callbackTopic) callbacks2++;
        }
        assertEq(callbacks2, 0); // throttled
    }

    function test_react_Cron_FiresAgainAfterInterval() public {
        // Cron 1
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        rsc.react(_buildCronLog());

        // Cron 2 — past interval again
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_buildCronLog());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackTopic) { found = true; break; }
        }
        assertTrue(found);
    }

    function test_react_Cron_CallbackPayloadEncodesRebalanceCall() public {
        // Accumulate some notional first
        IReactive.LogRecord memory matchLog = _buildMatchRecordedLog(
            HOME_CHAIN,
            keccak256("m1"), keccak256("alice"), keccak256("bob"),
            uint64(HOME_CHAIN), uint64(OTHER_CHAIN),
            uint128(2_000_000e6), 1200, uint64(block.timestamp)
        );
        rsc.react(matchLog);

        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_buildCronLog());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        bytes memory payload;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackTopic) {
                // Decode the data field
                payload = abi.decode(logs[i].data, (bytes));
                break;
            }
        }
        require(payload.length > 0, "no payload found");

        // First 4 bytes = selector for rebalance(address, Allocation[])
        bytes4 selector = bytes4(payload);
        assertEq(selector, ICrossHedgeVault.rebalance.selector);
    }

    function test_react_Cron_CallbackHasCorrectGasLimit() public {
        vm.warp(block.timestamp + MIN_CRON_INTERVAL + 1);
        vm.recordLogs();
        rsc.react(_buildCronLog());

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 callbackTopic = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == callbackTopic) {
                // topic_3 = gas_limit (indexed)
                uint64 gasLimit = uint64(uint256(logs[i].topics[3]));
                assertEq(gasLimit, CALLBACK_GAS);
                return;
            }
        }
        revert("Callback not found");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          react: unknown topic
    // ═══════════════════════════════════════════════════════════════════════

    function test_react_UnknownTopic_SilentlyIgnored() public {
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: HOME_CHAIN,
            _contract: address(0xdead),
            topic_0: uint256(keccak256("UnknownEvent(uint256)")),
            topic_1: 0, topic_2: 0, topic_3: 0,
            data: "",
            block_number: 0, op_code: 0,
            block_hash: 0, tx_hash: 0, log_index: 0
        });

        // Should not revert
        rsc.react(log);

        // No state changes
        assertEq(rsc.trackedPoolCount(), 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          Vol estimation
    // ═══════════════════════════════════════════════════════════════════════

    function test_volEstimation_AfterEnoughSamples() public {
        bytes32 poolId = keccak256("pool1");
        uint64 t = uint64(block.timestamp);
        uint160 p = uint160(1 << 96);

        // Push 15 samples with alternating 0.5% moves
        for (uint64 i = 0; i < 15; i++) {
            if (i % 2 == 1) {
                p = uint160(uint256(p) * 1005 / 1000);
            } else if (i > 0) {
                p = uint160(uint256(p) * 1000 / 1005);
            }
            IReactive.LogRecord memory log = _buildPriceSnapshotLog(
                HOME_CHAIN, poolId, p, t + i * 60
            );
            rsc.react(log);
        }

        uint256 vol = rsc.getAnnualizedVol(HOME_CHAIN, poolId);
        assertGt(vol, 0);
    }
}
