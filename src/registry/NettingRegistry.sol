// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {IRebatePayer} from "../interfaces/IRebatePayer.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title NettingRegistry
/// @notice Per-chain bookkeeper: records matches received from MatchingRSC,
///         accrues rebates, settles claims, runs the watchdog.
/// @dev Phase 0 stub.
contract NettingRegistry is INettingRegistry {
    // ─── Immutables ─────────────────────────────────────────────────────────
    address public immutable callbackProxy;
    address public immutable authorizedMatchingRvmId;
    address public immutable hook;
    IRebatePayer public immutable rebatePayer;
    uint64 public immutable watchdogWindow;

    // ─── Governed parameters ────────────────────────────────────────────────
    uint16 public fIntBps;
    uint64 public minRebateClaim;

    // ─── State ──────────────────────────────────────────────────────────────
    uint64 public lastMatchingCallback;
    bool private _matchingActive;

    constructor(
        address _callbackProxy,
        address _authorizedMatchingRvmId,
        address _hook,
        IRebatePayer _rebatePayer,
        uint64 _watchdogWindow,
        uint16 _fIntBps
    ) {
        callbackProxy = _callbackProxy;
        authorizedMatchingRvmId = _authorizedMatchingRvmId;
        hook = _hook;
        rebatePayer = _rebatePayer;
        watchdogWindow = _watchdogWindow;
        fIntBps = _fIntBps;
        minRebateClaim = 1e6; // 1 USDC default
        lastMatchingCallback = uint64(block.timestamp);
        _matchingActive = true;
    }

    // ─── Modifiers ──────────────────────────────────────────────────────────
    modifier onlyMatchingCallback(address rvmId) {
        if (msg.sender != callbackProxy) revert Errors.NotCallbackProxy();
        if (rvmId != authorizedMatchingRvmId) revert Errors.WrongRvmId();
        _;
    }

    // ─── Callback entry points (stubs) ──────────────────────────────────────

    function recordMatch(
        address rvmId,
        bytes32 /*matchId*/,
        bytes32 /*longPosId*/,
        bytes32 /*shortPosId*/,
        uint64 /*longChainId*/,
        uint64 /*shortChainId*/,
        uint128 /*matchedNotional*/,
        uint16 /*fIntBps_*/
    ) external override onlyMatchingCallback(rvmId) {
        lastMatchingCallback = uint64(block.timestamp);
        if (!_matchingActive) _matchingActive = true;
    }

    function cancelMatch(address rvmId, bytes32 /*matchId*/)
        external
        override
        onlyMatchingCallback(rvmId)
    {
        // stub
    }

    function settleMatch(address rvmId, bytes32 /*matchId*/, bool /*terminal*/)
        external
        override
        onlyMatchingCallback(rvmId)
    {
        // stub
    }

    function claimRebate(bytes32 /*posId*/) external override {
        // stub
    }

    function pingWatchdog() external override {
        if (!_matchingActive) return;
        if (uint64(block.timestamp) - lastMatchingCallback <= watchdogWindow) return;
        _matchingActive = false;
    }

    // ─── Views ──────────────────────────────────────────────────────────────

    function matchingActive() external view override returns (bool) {
        return _matchingActive;
    }

    function isHedged(bytes32 /*posId*/) external view override returns (bool) {
        return false;
    }
}
