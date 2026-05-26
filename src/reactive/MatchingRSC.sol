// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title MatchingRSC
/// @notice Cross-chain LP matching engine.
/// @dev Lives on Reactive Lasna. Subscribes to hook events on origin chains;
///      runs a 12-min cron to compute matches; emits Callback events to both
///      chains' NettingRegistry.recordMatch.
///
///      Phase 0 stub.
contract MatchingRSC is AbstractReactive {
    uint64 public immutable callbackGasLimit;

    constructor(uint64 _callbackGasLimit) {
        callbackGasLimit = _callbackGasLimit;
    }

    /// @notice Reactive entry point — invoked on every subscribed log.
    function react(LogRecord calldata /*log*/) external vmOnly {
        // routing: CRON_TOPIC → runCron(); event topics → respective handlers
    }

    // ─── Helpers (stubs) ────────────────────────────────────────────────────

    function runCron() internal {
        // refresh deltas, sort queues, emit Callback events
    }
}
