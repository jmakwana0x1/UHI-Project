// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title StrategyRSC
/// @notice Slow brain — decides when to rebalance the vault and refill proxies.
/// @dev Lives on Reactive Lasna. Phase 0 stub.
contract StrategyRSC is AbstractReactive {
    uint64 public immutable callbackGasLimit;
    address public immutable vaultAddress;
    uint256 public immutable vaultChainId;

    constructor(
        uint64 _callbackGasLimit,
        address _vaultAddress,
        uint256 _vaultChainId
    ) {
        callbackGasLimit = _callbackGasLimit;
        vaultAddress = _vaultAddress;
        vaultChainId = _vaultChainId;
    }

    function react(LogRecord calldata /*log*/) external vmOnly {
        // routing: MatchRecorded, vault deposit/withdraw, slow cron
    }

    function runSlowCron() internal {
        // evaluate triggers; emit rebalance + refill callbacks
    }
}
