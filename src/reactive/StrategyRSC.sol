// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {VolEMA} from "./modules/VolEMA.sol";
import {ReactiveConstants} from "./modules/ReactiveConstants.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";
import {ICrossHedgeVault} from "../interfaces/ICrossHedgeVault.sol";

/// @title StrategyRSC
/// @notice Reactive Smart Contract that tracks per-pool realized vol and
///         total matched notional across origin chains, then on a slow cron
///         emits Callback events targeting CrossHedgeVault.rebalance(...) on
///         the home chain.
///
/// @dev    Lives on Reactive Lasna. Subscribes in RN context (constructor);
///         processes events in RVM context (react).
///
///         MVP allocation logic is intentionally trivial: it just confirms
///         the current matched notional and emits a single Allocation entry
///         per home-chain pool. Real allocation logic (delta-targeting,
///         vol-adjusted exposure caps) is Phase 5 work.
contract StrategyRSC is AbstractReactive {
    // ─── Configuration ─────────────────────────────────────────────────────

    /// @notice Home chain where the CrossHedgeVault lives.
    uint256 public immutable homeChainId;
    /// @notice Address of the CrossHedgeVault on the home chain.
    address public immutable vaultAddress;
    /// @notice Minimum interval between rebalance emissions (seconds).
    uint64 public immutable minCronInterval;
    /// @notice Gas limit to pass on the destination-chain callback.
    uint64 public immutable callbackGasLimit;

    // ─── Per-pool state ────────────────────────────────────────────────────

    struct PoolState {
        VolEMA.State volState;
        uint128 totalMatchedNotional;
        uint64 lastCronTick;
        bool initialized;
    }

    /// @notice Per-(chainId, poolId) state. We key by both because identical
    ///         poolIds can exist on different chains.
    mapping(uint256 => mapping(bytes32 => PoolState)) internal _poolStates;

    /// @notice Track which (chainId, poolId) pairs we've ever seen. Cron
    ///         iterates this list. We deliberately keep it bounded by capping
    ///         the number of pools followed (MVP: 4 pools across 2 chains).
    struct PoolRef {
        uint256 chainId;
        bytes32 poolId;
    }
    PoolRef[] internal _trackedPools;
    mapping(uint256 => mapping(bytes32 => bool)) internal _isTracked;

    /// @notice EMA decay factor in bps.
    uint16 public immutable alphaBps;

    // ─── Events (for debugging / off-chain monitoring) ─────────────────────

    event SnapshotProcessed(uint256 indexed chainId, bytes32 indexed poolId, uint160 sqrtPriceX96, uint64 timestamp);
    event MatchObserved(uint256 indexed chainId, bytes32 indexed poolId, uint128 notional);
    event CronTickSkipped(uint64 nowTs, uint64 lastTick, string reason);
    event RebalanceEmitted(uint256 indexed chainId, address indexed vault, uint64 timestamp);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        uint256 _homeChainId,
        address _vaultAddress,
        uint64 _minCronInterval,
        uint64 _callbackGasLimit,
        uint16 _alphaBps,
        uint256[] memory subscribeChainIds
    ) payable {
        if (_vaultAddress == address(0)) revert Errors.ZeroAddress();
        if (_homeChainId == 0) revert Errors.ZeroAddress(); // reuse: invalid config

        homeChainId = _homeChainId;
        vaultAddress = _vaultAddress;
        minCronInterval = _minCronInterval;
        callbackGasLimit = _callbackGasLimit;
        alphaBps = _alphaBps;

        // Subscriptions only run in RN context. In RVM context, `vm` is true
        // and we skip subscribe calls (they'd revert anyway against the
        // service since RVM can't subscribe).
        if (!vm) {
            for (uint256 i = 0; i < subscribeChainIds.length; i++) {
                uint256 cid = subscribeChainIds[i];
                // Subscribe to PriceSnapshot from ANY contract on this chain
                // (we don't know the hook address yet at construction time).
                service.subscribe(
                    cid,
                    address(0),
                    ReactiveConstants.TOPIC_PRICE_SNAPSHOT,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
                // Subscribe to MatchRecorded from the registry on this chain.
                // Registry addresses also not known yet; subscribe broadly.
                service.subscribe(
                    cid,
                    address(0),
                    ReactiveConstants.TOPIC_MATCH_RECORDED,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE,
                    REACTIVE_IGNORE
                );
            }
            // Subscribe to the cron topic on Lasna itself.
            service.subscribe(
                ReactiveConstants.LASNA_CHAIN_ID,
                ReactiveConstants.SYSTEM_CONTRACT,
                ReactiveConstants.CRON_TOPIC_SLOW_PLACEHOLDER,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            react()
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Entry point called by Reactive infrastructure on every
    ///         subscribed event. Dispatches by topic_0.
    function react(LogRecord calldata log) external override vmOnly {
        // Sender authorization is already enforced upstream by Reactive infra.
        // We trust topic_0 to dispatch routing.

        if (log.topic_0 == ReactiveConstants.TOPIC_PRICE_SNAPSHOT) {
            _handlePriceSnapshot(log);
        } else if (log.topic_0 == ReactiveConstants.TOPIC_MATCH_RECORDED) {
            _handleMatchRecorded(log);
        } else if (log.topic_0 == ReactiveConstants.CRON_TOPIC_SLOW_PLACEHOLDER) {
            _handleCron(log);
        }
        // Unknown topic: silently ignore. Subscriptions can outlive intent.
    }

    // ─── Handler: PriceSnapshot ────────────────────────────────────────────

    /// @dev Expected layout (from CrossHedgeHook.PriceSnapshot):
    ///   topic_0 = TOPIC_PRICE_SNAPSHOT
    ///   topic_1 = poolId (indexed)
    ///   data    = abi.encode(uint160 sqrtPriceX96, uint64 timestamp)
    function _handlePriceSnapshot(LogRecord calldata log) internal {
        bytes32 poolId = bytes32(log.topic_1);

        // Decode non-indexed args from `data`.
        (uint160 sqrtPriceX96, uint64 timestamp) = abi.decode(log.data, (uint160, uint64));

        _ensureTracked(log.chain_id, poolId);

        PoolState storage ps = _poolStates[log.chain_id][poolId];
        VolEMA.updateEMA(ps.volState, sqrtPriceX96, timestamp, alphaBps);
        ps.initialized = true;

        emit SnapshotProcessed(log.chain_id, poolId, sqrtPriceX96, timestamp);
    }

    // ─── Handler: MatchRecorded ────────────────────────────────────────────

    /// @dev MatchRecorded indexed signature has matchId, longPosId, shortPosId
    ///      as topics_1..3. The matchedNotional is in `data`. We can't directly
    ///      tell which pool from the topics (matchId is opaque), but for MVP
    ///      we attribute notional to the chain the event came from. A future
    ///      version could include poolId in the event or carry it in `data`.
    ///
    /// @dev Expected `data` layout (per MatchRecorded event):
    ///   abi.encode(uint64 longChainId, uint64 shortChainId,
    ///              uint128 matchedNotional, uint16 fIntBps, uint64 timestamp)
    function _handleMatchRecorded(LogRecord calldata log) internal {
        (
            uint64 longChainId,
            uint64 shortChainId,
            uint128 matchedNotional,
            ,
            // fIntBps unused here
        ) = abi.decode(log.data, (uint64, uint64, uint128, uint16, uint64));

        // Attribute notional to the long side's chain — that's the side
        // where the directional exposure lives.
        uint256 chain = uint256(longChainId);
        // We don't know poolId from this event; for MVP we aggregate at chain
        // level using a sentinel poolId = bytes32(0). Strategy operates per-
        // chain, not per-pool, for the rebalance decision.
        bytes32 sentinelPool = bytes32(0);

        _ensureTracked(chain, sentinelPool);
        PoolState storage ps = _poolStates[chain][sentinelPool];

        // Cap at uint128 max defensively
        uint256 newTotal = uint256(ps.totalMatchedNotional) + uint256(matchedNotional);
        ps.totalMatchedNotional = newTotal > type(uint128).max
            ? type(uint128).max
            : uint128(newTotal);

        emit MatchObserved(chain, sentinelPool, matchedNotional);

        // Suppress unused warning
        shortChainId;
    }

    // ─── Handler: Cron ─────────────────────────────────────────────────────

    function _handleCron(LogRecord calldata /*log*/) internal {
        uint64 nowTs = uint64(block.timestamp);

        // Throttle: only emit a rebalance if minCronInterval has elapsed
        // since the LAST rebalance for the home chain.
        PoolState storage homeSentinel = _poolStates[homeChainId][bytes32(0)];
        if (nowTs - homeSentinel.lastCronTick < minCronInterval) {
            emit CronTickSkipped(nowTs, homeSentinel.lastCronTick, "throttle");
            return;
        }
        homeSentinel.lastCronTick = nowTs;

        // Build an allocation array. MVP: single trivial allocation telling
        // the vault to provision liquidity in a wide range around current price.
        // Phase 4 will fill in the actual unlock-swap-deploy flow; the vault
        // currently no-ops on rebalance after auth check.
        //
        // We translate matchedNotional → targetLiquidity via a fixed factor
        // (rough proxy). Real conversion uses pool sqrt-price; this is a
        // placeholder until the vault's rebalance is implemented.
        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-1000),
            tickUpper: int24(1000),
            targetLiquidity: uint128(homeSentinel.totalMatchedNotional / 1_000_000),
            keepIfExists: true
        });

        // Encode the destination call: vault.rebalance(rvmId, allocs)
        // The first arg (rvmId) is overwritten by Reactive with our RVM ID;
        // we put address(0) as a placeholder.
        bytes memory payload = abi.encodeWithSelector(
            ICrossHedgeVault.rebalance.selector,
            address(0),
            allocs
        );

        emit Callback(
            homeChainId,
            vaultAddress,
            callbackGasLimit,
            payload
        );
        emit RebalanceEmitted(homeChainId, vaultAddress, nowTs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Views (test helpers)
    // ═══════════════════════════════════════════════════════════════════════

    function getPoolState(uint256 chainId, bytes32 poolId)
        external
        view
        returns (
            uint128 totalMatchedNotional,
            uint64 lastCronTick,
            bool initialized,
            uint32 sampleCount
        )
    {
        PoolState storage ps = _poolStates[chainId][poolId];
        return (
            ps.totalMatchedNotional,
            ps.lastCronTick,
            ps.initialized,
            ps.volState.sampleCount
        );
    }

    function getAnnualizedVol(uint256 chainId, bytes32 poolId)
        external
        view
        returns (uint256)
    {
        return VolEMA.annualizedVolE18(_poolStates[chainId][poolId].volState);
    }

    function trackedPoolCount() external view returns (uint256) {
        return _trackedPools.length;
    }

    function trackedPool(uint256 i) external view returns (uint256 chainId, bytes32 poolId) {
        PoolRef storage r = _trackedPools[i];
        return (r.chainId, r.poolId);
    }

    function isInVm() external view returns (bool) {
        return vm;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Internals
    // ═══════════════════════════════════════════════════════════════════════

    function _ensureTracked(uint256 chainId, bytes32 poolId) internal {
        if (!_isTracked[chainId][poolId]) {
            _isTracked[chainId][poolId] = true;
            _trackedPools.push(PoolRef({chainId: chainId, poolId: poolId}));
        }
    }
}
