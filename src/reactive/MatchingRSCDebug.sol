// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ReactiveConstants} from "./modules/ReactiveConstants.sol";
import {MaxHeap} from "./modules/MaxHeap.sol";

contract MatchingRSCDebug is AbstractReactive {
    using MaxHeap for MaxHeap.Heap;

    mapping(uint256 => address) public registryByChain;
    uint64 public immutable minCronInterval;
    uint64 public immutable callbackGasLimit;
    uint16 public immutable fIntBps;
    uint16 public immutable alphaBps;

    struct Candidate {
        bytes32 posId;
        uint256 originChainId;
        int256 signedDelta;
        uint128 gamma;
        uint128 notional;
        uint8 horizonBucket;
        uint64 openedAt;
        bool matched;
        bool exists;
    }
    mapping(bytes32 => Candidate) internal _candidates;
    bytes32[] internal _candidateList;
    uint64 public lastCronTick;
    mapping(bytes32 => bytes32) internal _pairKeyToA;
    mapping(bytes32 => bytes32) internal _pairKeyToB;

    // ─── NEW: add the heap that MatchingRSC has ──
    MaxHeap.Heap internal _scratchHeap;

    constructor(
        uint256[] memory subscribeChainIds,
        address[] memory chainRegistries,
        uint64 _minCronInterval,
        uint64 _callbackGasLimit,
        uint16 _fIntBps,
        uint16 _alphaBps
    ) payable {
        require(subscribeChainIds.length == chainRegistries.length, "arity");

        minCronInterval = _minCronInterval;
        callbackGasLimit = _callbackGasLimit;
        fIntBps = _fIntBps;
        alphaBps = _alphaBps;

        for (uint256 i = 0; i < subscribeChainIds.length; i++) {
            registryByChain[subscribeChainIds[i]] = chainRegistries[i];
        }

        if (!vm) {
            for (uint256 i = 0; i < subscribeChainIds.length; i++) {
                uint256 cid = subscribeChainIds[i];
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_LP_POSITION_OPENED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_LP_POSITION_CLOSED, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_PRICE_SNAPSHOT, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
            }
            service.subscribe(
                ReactiveConstants.LASNA_CHAIN_ID,
                ReactiveConstants.SYSTEM_CONTRACT,
                ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER,
                REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE
            );
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
