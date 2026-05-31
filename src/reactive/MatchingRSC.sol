// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {VolEMA} from "./modules/VolEMA.sol";
import {MatchScore} from "./modules/MatchScore.sol";
import {MaxHeap} from "./modules/MaxHeap.sol";
import {ReactiveConstants} from "./modules/ReactiveConstants.sol";

import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";

/// @title MatchingRSC
/// @notice Reactive Smart Contract that maintains a candidate pool of LP
///         positions across origin chains, runs greedy 1:1 matching on cron
///         tick, and emits Callback events that trigger
///         NettingRegistry.recordMatch(...) on both chains involved.
///
/// @dev    Lives on Reactive Lasna. Subscribes in RN context; processes
///         events in RVM context.
///
///         Capacity: capped at MAX_CANDIDATES (default 32). When full, the
///         oldest unmatched candidate is evicted on each new opening.
///
///         The matching algorithm is O(n²) for scoring + heap-based for
///         selection. At n=32, ~1000 pair evaluations per cron tick.
contract MatchingRSC is AbstractReactive {
    using MaxHeap for MaxHeap.Heap;

    /// @notice Capacity cap for the candidate pool. MVP scale.
    uint32 public constant MAX_CANDIDATES = 32;

    /// @notice Hardcoded correlation for MVP (perfect correlation since both
    ///         sides are ETH/USDC pools). Phase 5 could estimate from snapshots.
    uint16 public constant DEFAULT_CORRELATION_BPS = 10_000;

    // ─── Configuration ─────────────────────────────────────────────────────

    /// @notice Per-origin-chain NettingRegistry addresses (chainId → registry).
    mapping(uint256 => address) public registryByChain;

    /// @notice Minimum interval between cron-triggered matching runs.
    uint64 public immutable minCronInterval;

    /// @notice Gas limit to pass on cross-chain callback for recordMatch.
    uint64 public immutable callbackGasLimit;

    /// @notice f_int_bps captured at match time (governance-controlled by registry).
    uint16 public immutable fIntBps;

    /// @notice VolEMA decay factor.
    uint16 public immutable alphaBps;

    // ─── Candidate pool ────────────────────────────────────────────────────

    struct Candidate {
        bytes32 posId;
        uint256 originChainId;
        int256 signedDelta;
        uint128 gamma;
        uint128 notional;       // matchable notional in USDC (e6) — caller estimates
        uint8 horizonBucket;
        uint64 openedAt;
        bool matched;
        bool exists;
    }

    /// @notice posId → Candidate. The canonical lookup.
    mapping(bytes32 => Candidate) internal _candidates;

    /// @notice Iteration list (for O(n²) pair scoring).
    bytes32[] internal _candidateList;

    // ─── Vol tracking (per chain, sentinel pool) ──────────────────────────

    mapping(uint256 => VolEMA.State) internal _volState;

    // ─── Cron throttle ─────────────────────────────────────────────────────

    uint64 public lastCronTick;

    // ─── Events (off-chain monitoring) ────────────────────────────────────

    event CandidateAdded(bytes32 indexed posId, uint256 chainId, int256 signedDelta, uint128 gamma);
    event CandidateRemoved(bytes32 indexed posId, string reason);
    event CandidateEvicted(bytes32 indexed posId);
    event PairMatched(bytes32 indexed matchId, bytes32 longPosId, bytes32 shortPosId, uint128 matchedNotional);
    event MatchCallbackEmitted(uint256 indexed chainId, address indexed registry, bytes32 matchId);
    event CronCompleted(uint32 matchesEmitted, uint64 timestamp);
    event CronTickThrottled(uint64 nowTs, uint64 lastTick);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        uint256[] memory subscribeChainIds,
        address[] memory chainRegistries,
        uint64 _minCronInterval,
        uint64 _callbackGasLimit,
        uint16 _fIntBps,
        uint16 _alphaBps
    ) payable {
        if (subscribeChainIds.length != chainRegistries.length) {
            revert Errors.ZeroAddress(); // reuse: arity mismatch
        }

        minCronInterval = _minCronInterval;
        callbackGasLimit = _callbackGasLimit;
        fIntBps = _fIntBps;
        alphaBps = _alphaBps;

        // Wire registry per chain
        for (uint256 i = 0; i < subscribeChainIds.length; i++) {
            if (chainRegistries[i] == address(0)) revert Errors.ZeroAddress();
            registryByChain[subscribeChainIds[i]] = chainRegistries[i];
        }

        // RN context: subscribe
        if (!vm) {
            for (uint256 i = 0; i < subscribeChainIds.length; i++) {
                uint256 cid = subscribeChainIds[i];
                service.subscribe(
                    cid, address(0),
                    ReactiveConstants.TOPIC_LP_POSITION_OPENED,
                    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                service.subscribe(
                    cid, address(0),
                    ReactiveConstants.TOPIC_LP_POSITION_CLOSED,
                    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
                service.subscribe(
                    cid, address(0),
                    ReactiveConstants.TOPIC_PRICE_SNAPSHOT,
                    REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
                );
            }
            // Fast cron on Lasna
            service.subscribe(
                ReactiveConstants.LASNA_CHAIN_ID,
                ReactiveConstants.SYSTEM_CONTRACT,
                ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            react()
    // ═══════════════════════════════════════════════════════════════════════

    function react(LogRecord calldata log) external override vmOnly {
        if (log.topic_0 == ReactiveConstants.TOPIC_LP_POSITION_OPENED) {
            _handlePositionOpened(log);
        } else if (log.topic_0 == ReactiveConstants.TOPIC_LP_POSITION_CLOSED) {
            _handlePositionClosed(log);
        } else if (log.topic_0 == ReactiveConstants.TOPIC_PRICE_SNAPSHOT) {
            _handlePriceSnapshot(log);
        } else if (log.topic_0 == ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER) {
            _handleCron();
        }
        // Unknown topic: silently ignore.
    }

    // ─── Handler: LPPositionOpened ─────────────────────────────────────────

    /// @dev LPPositionOpened topics:
    ///   topic_0 = TOPIC_LP_POSITION_OPENED
    ///   topic_1 = posId
    ///   topic_2 = poolId (not used by matcher)
    ///   topic_3 = owner (not used by matcher)
    ///   data    = abi.encode(int24 tickLower, int24 tickUpper, uint128 liquidity,
    ///                        int256 signedDelta, uint128 gamma, uint8 horizonBucket,
    ///                        bool unhedged)
    function _handlePositionOpened(LogRecord calldata log) internal {
        bytes32 posId = bytes32(log.topic_1);

        // Reject if already known (shouldn't happen — registry has its own dedup)
        if (_candidates[posId].exists) return;

        (
            ,         // tickLower
            ,         // tickUpper
            ,         // liquidity
            int256 signedDelta,
            uint128 gamma,
            uint8 horizonBucket,
            bool unhedged
        ) = abi.decode(log.data, (int24, int24, uint128, int256, uint128, uint8, bool));

        // Don't enroll unhedged positions — they're informational only
        if (unhedged) return;
        // Don't enroll positions with zero delta
        if (signedDelta == 0) return;

        // Capacity check — evict oldest unmatched if full
        if (_candidateList.length >= MAX_CANDIDATES) {
            _evictOldest();
        }

        // Estimate matchable notional in USDC e6.
        // For MVP we use |signedDelta| / 1e12 — converts e18 ETH delta to e6
        // assuming roughly $1k/ETH. Real notional needs current price; we
        // approximate. Caller (registry) gets the actual matched notional
        // from MatchScore which takes the min of |delta_A|, |delta_B|.
        uint256 absDelta = signedDelta >= 0 ? uint256(signedDelta) : uint256(-signedDelta);
        uint128 notional = absDelta > type(uint128).max * uint256(1e12)
            ? type(uint128).max
            : uint128(absDelta / 1e12);

        _candidates[posId] = Candidate({
            posId: posId,
            originChainId: log.chain_id,
            signedDelta: signedDelta,
            gamma: gamma,
            notional: notional,
            horizonBucket: horizonBucket,
            openedAt: uint64(block.timestamp),
            matched: false,
            exists: true
        });
        _candidateList.push(posId);

        emit CandidateAdded(posId, log.chain_id, signedDelta, gamma);
    }

    // ─── Handler: LPPositionClosed ─────────────────────────────────────────

    function _handlePositionClosed(LogRecord calldata log) internal {
        bytes32 posId = bytes32(log.topic_1);
        if (!_candidates[posId].exists) return;

        _removeCandidate(posId);
        emit CandidateRemoved(posId, "closed");
    }

    // ─── Handler: PriceSnapshot ────────────────────────────────────────────

    function _handlePriceSnapshot(LogRecord calldata log) internal {
        (uint160 sqrtPriceX96, uint64 timestamp) = abi.decode(log.data, (uint160, uint64));
        VolEMA.updateEMA(_volState[log.chain_id], sqrtPriceX96, timestamp, alphaBps);
    }

    // ─── Handler: Cron ─────────────────────────────────────────────────────

    function _handleCron() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs - lastCronTick < minCronInterval) {
            emit CronTickThrottled(nowTs, lastCronTick);
            return;
        }
        lastCronTick = nowTs;

        // Build a heap of valid (long, short) pairs by score
        MaxHeap.Heap storage heap = _newHeap();

        uint256 n = _candidateList.length;
        for (uint256 i = 0; i < n; i++) {
            bytes32 ki = _candidateList[i];
            Candidate storage ci = _candidates[ki];
            if (ci.matched) continue;

            for (uint256 j = i + 1; j < n; j++) {
                bytes32 kj = _candidateList[j];
                Candidate storage cj = _candidates[kj];
                if (cj.matched) continue;

                // Determine long vs short by sign
                // We need to call MatchScore.score with (longDelta, shortDelta, ...)
                // The library handles sign-pairing internally — it just needs
                // opposite signs.
                (uint128 score, uint128 matchable) = MatchScore.score(
                    ci.signedDelta, cj.signedDelta,
                    ci.gamma, cj.gamma,
                    ci.horizonBucket, cj.horizonBucket,
                    DEFAULT_CORRELATION_BPS
                );
                if (score == 0) continue;

                // Record the pair (populates _pairKeyToA/B and pushes to heap)
                _heapPushPair(heap, ki, kj, score);

                // Suppress unused
                matchable;
            }
        }

        // Greedy: pop highest-score pairs, marking matched
        uint32 matchesEmitted;
        while (heap.size() > 0) {
            (bytes32 pairKey, ) = heap.popMax();
            (bytes32 ki, bytes32 kj) = _unpackPairKey(pairKey);
            // Clear the pair-key mapping now that we've consumed it
            delete _pairKeyToA[pairKey];
            delete _pairKeyToB[pairKey];

            Candidate storage ci = _candidates[ki];
            Candidate storage cj = _candidates[kj];

            // Skip if either side already matched (an earlier pop took them)
            if (ci.matched || cj.matched) continue;
            if (!ci.exists || !cj.exists) continue;

            // Determine long/short
            (Candidate storage longCand, Candidate storage shortCand) =
                ci.signedDelta > 0 ? (ci, cj) : (cj, ci);

            // Compute matched notional (min of |deltas|, in USDC e6 approx)
            uint128 matchedNotional =
                longCand.notional < shortCand.notional ? longCand.notional : shortCand.notional;

            // Build matchId
            bytes32 matchId = keccak256(abi.encode(
                longCand.posId, shortCand.posId, block.timestamp
            ));

            ci.matched = true;
            cj.matched = true;

            emit PairMatched(matchId, longCand.posId, shortCand.posId, matchedNotional);

            // Emit Callback events to both registries
            _emitRecordMatchCallback(longCand, shortCand, matchId, matchedNotional);
            matchesEmitted++;
        }

        // Cleanup matched candidates from the list
        _compactCandidateList();

        emit CronCompleted(matchesEmitted, nowTs);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Internals
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev We declare a local heap as storage by using a slot-bound trick:
    ///      since we need transient-style storage across iteration but Solidity
    ///      doesn't give us scoped storage, we use a dedicated permanent
    ///      heap slot and clear it at the start of each cron run.
    MaxHeap.Heap internal _scratchHeap;

    function _newHeap() internal returns (MaxHeap.Heap storage) {
        // Clear heap from previous run by popping all remaining entries.
        // Also clear the pair-key mappings for those entries.
        while (_scratchHeap.size() > 0) {
            (bytes32 pk, ) = _scratchHeap.popMax();
            delete _pairKeyToA[pk];
            delete _pairKeyToB[pk];
        }
        _scratchHeap.init();
        return _scratchHeap;
    }

    /// @dev Pack two posIds into a deterministic pair key (lower id first).
    function _pairKey(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev We can't recover the constituent posIds from the hash, so we cache
    ///      them when we push. For MVP simplicity we use a sister mapping.
    mapping(bytes32 => bytes32) internal _pairKeyToA;
    mapping(bytes32 => bytes32) internal _pairKeyToB;

    function _unpackPairKey(bytes32 pk) internal view returns (bytes32, bytes32) {
        return (_pairKeyToA[pk], _pairKeyToB[pk]);
    }

    /// @dev Override of heap.push to also record constituent pos ids.
    function _heapPushPair(MaxHeap.Heap storage heap, bytes32 ki, bytes32 kj, uint128 score) internal {
        bytes32 pk = _pairKey(ki, kj);
        if (heap.contains(pk)) return;
        bytes32 a = ki < kj ? ki : kj;
        bytes32 b = ki < kj ? kj : ki;
        _pairKeyToA[pk] = a;
        _pairKeyToB[pk] = b;
        heap.push(pk, score);
    }

    function _evictOldest() internal {
        uint64 oldestTs = type(uint64).max;
        bytes32 oldestId;
        for (uint256 i = 0; i < _candidateList.length; i++) {
            bytes32 k = _candidateList[i];
            Candidate storage c = _candidates[k];
            if (c.matched) continue;
            if (c.openedAt < oldestTs) {
                oldestTs = c.openedAt;
                oldestId = k;
            }
        }
        if (oldestId != bytes32(0)) {
            _removeCandidate(oldestId);
            emit CandidateEvicted(oldestId);
        }
    }

    function _removeCandidate(bytes32 posId) internal {
        delete _candidates[posId];
        for (uint256 i = 0; i < _candidateList.length; i++) {
            if (_candidateList[i] == posId) {
                _candidateList[i] = _candidateList[_candidateList.length - 1];
                _candidateList.pop();
                return;
            }
        }
    }

    function _compactCandidateList() internal {
        // Walk backwards removing matched candidates
        uint256 i = _candidateList.length;
        while (i > 0) {
            i--;
            bytes32 k = _candidateList[i];
            if (_candidates[k].matched) {
                _candidateList[i] = _candidateList[_candidateList.length - 1];
                _candidateList.pop();
                // Don't delete _candidates[k] — keep for posterity / events
            }
        }
    }

    function _emitRecordMatchCallback(
        Candidate storage longCand,
        Candidate storage shortCand,
        bytes32 matchId,
        uint128 matchedNotional
    ) internal {
        uint64 longChain = uint64(longCand.originChainId);
        uint64 shortChain = uint64(shortCand.originChainId);

        // Emit to long-side chain
        address longRegistry = registryByChain[longCand.originChainId];
        if (longRegistry != address(0)) {
            bytes memory payload = abi.encodeWithSelector(
                INettingRegistry.recordMatch.selector,
                address(0),  // rvmId placeholder (overwritten by Reactive)
                matchId,
                longCand.posId,
                shortCand.posId,
                longChain,
                shortChain,
                matchedNotional,
                fIntBps
            );
            emit Callback(longCand.originChainId, longRegistry, callbackGasLimit, payload);
            emit MatchCallbackEmitted(longCand.originChainId, longRegistry, matchId);
        }

        // Emit to short-side chain (if different)
        if (shortCand.originChainId != longCand.originChainId) {
            address shortRegistry = registryByChain[shortCand.originChainId];
            if (shortRegistry != address(0)) {
                bytes memory payload = abi.encodeWithSelector(
                    INettingRegistry.recordMatch.selector,
                    address(0),
                    matchId,
                    longCand.posId,
                    shortCand.posId,
                    longChain,
                    shortChain,
                    matchedNotional,
                    fIntBps
                );
                emit Callback(shortCand.originChainId, shortRegistry, callbackGasLimit, payload);
                emit MatchCallbackEmitted(shortCand.originChainId, shortRegistry, matchId);
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Views (test helpers)
    // ═══════════════════════════════════════════════════════════════════════

    function candidateCount() external view returns (uint256) {
        return _candidateList.length;
    }

    function candidateAt(uint256 i) external view returns (Candidate memory) {
        return _candidates[_candidateList[i]];
    }

    function getCandidate(bytes32 posId) external view returns (Candidate memory) {
        return _candidates[posId];
    }

    function isInVm() external view returns (bool) {
        return vm;
    }
}
