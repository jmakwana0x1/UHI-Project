// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface INettingRegistry {
    // ─── Callback entry points (only MatchingRSC via Callback Proxy) ────────

    /// @notice Persist a new match record. Idempotent on matchId.
    /// @param rvmId First-160-bits slot, overwritten by Reactive — auth check.
    function recordMatch(
        address rvmId,
        bytes32 matchId,
        bytes32 longPosId,
        bytes32 shortPosId,
        uint64 longChainId,
        uint64 shortChainId,
        uint128 matchedNotional,
        uint16 fIntBps
    ) external;

    /// @notice Cancel a recorded match and free both positions for re-matching.
    function cancelMatch(address rvmId, bytes32 matchId) external;

    /// @notice Accrue rebate up to current time and optionally mark match closed.
    function settleMatch(address rvmId, bytes32 matchId, bool terminal) external;

    // ─── User-facing ────────────────────────────────────────────────────────

    /// @notice Claim accrued rebate. Caller must be the position owner.
    function claimRebate(bytes32 posId) external;

    // ─── Watchdog ───────────────────────────────────────────────────────────

    /// @notice Public watchdog poke. Flips matchingActive to false if stale.
    function pingWatchdog() external;

    /// @notice Whether matching is currently considered live.
    function matchingActive() external view returns (bool);

    /// @notice Whether a specific position currently has an active match.
    function isHedged(bytes32 posId) external view returns (bool);
}
