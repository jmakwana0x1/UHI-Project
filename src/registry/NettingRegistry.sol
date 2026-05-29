// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {IRebatePayer} from "../interfaces/IRebatePayer.sol";
import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title NettingRegistry
/// @notice Per-chain bookkeeper: records cross-chain matches, accrues rebates,
///         pays out on claim, and runs the watchdog state machine.
///
/// @dev    Recipients of cross-chain callbacks:
///           - `recordMatch`, `cancelMatch`, `settleMatch` are only callable
///             via Reactive's Callback Proxy from the authorized MatchingRSC.
///         User-facing:
///           - `claimRebate` — position owner claims accrued USDC.
///           - `pingWatchdog` — anyone can poke; auto-pauses on Reactive silence.
contract NettingRegistry is INettingRegistry {
    // ─── Immutables ─────────────────────────────────────────────────────────

    address public immutable callbackProxy;
    address public immutable authorizedMatchingRvmId;
    ICrossHedgeHook public immutable hook;
    IRebatePayer public immutable rebatePayer;
    uint64 public immutable watchdogWindow;

    // ─── Governed parameters ────────────────────────────────────────────────

    uint16 public fIntBps;
    uint64 public minRebateClaim;
    address public governance;

    // ─── State machine ──────────────────────────────────────────────────────

    uint64 public lastMatchingCallback;
    bool private _matchingActive;

    // ─── Match storage ──────────────────────────────────────────────────────

    enum MatchStatus { None, Active, Cancelled, Settled }

    struct Match {
        bytes32 longPosId;
        bytes32 shortPosId;
        uint64 longChainId;
        uint64 shortChainId;
        uint128 matchedNotional;
        uint64 startedAt;
        uint64 lastAccrualAt;
        uint16 fIntBpsAtMatch; // captured at match time
        MatchStatus status;
    }

    mapping(bytes32 => Match) public matches;
    mapping(bytes32 => bytes32) public posIdToMatch;
    mapping(bytes32 => uint128) public accruedRebate;

    // ─── Events ─────────────────────────────────────────────────────────────

    event MatchRecorded(
        bytes32 indexed matchId,
        bytes32 indexed longPosId,
        bytes32 indexed shortPosId,
        uint64 longChainId,
        uint64 shortChainId,
        uint128 matchedNotional,
        uint16 fIntBps,
        uint64 timestamp
    );
    event MatchCancelled(bytes32 indexed matchId, uint64 timestamp);
    event MatchSettled(bytes32 indexed matchId, uint128 totalAccrued, uint64 timestamp);
    event RebateAccrued(bytes32 indexed posId, uint128 amount, uint64 timestamp);
    event RebateClaimed(bytes32 indexed posId, address indexed to, uint128 amount);
    event MatchingPaused(uint64 lastCallbackTimestamp, uint64 pausedAt);
    event MatchingResumed(uint64 resumedAt);
    event GovernanceChanged(address indexed newGovernance);
    event FIntBpsUpdated(uint16 newFIntBps);
    event MinRebateClaimUpdated(uint64 newMinClaim);

    // ─── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyMatchingCallback(address rvmId) {
        if (msg.sender != callbackProxy) revert Errors.NotCallbackProxy();
        if (rvmId != authorizedMatchingRvmId) revert Errors.WrongRvmId();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Errors.Unauthorized();
        _;
    }

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        address _callbackProxy,
        address _authorizedMatchingRvmId,
        ICrossHedgeHook _hook,
        IRebatePayer _rebatePayer,
        uint64 _watchdogWindow,
        uint16 _fIntBps
    ) {
        if (_callbackProxy == address(0)) revert Errors.ZeroAddress();
        if (_authorizedMatchingRvmId == address(0)) revert Errors.ZeroAddress();
        if (address(_hook) == address(0)) revert Errors.ZeroAddress();
        if (address(_rebatePayer) == address(0)) revert Errors.ZeroAddress();

        callbackProxy = _callbackProxy;
        authorizedMatchingRvmId = _authorizedMatchingRvmId;
        hook = _hook;
        rebatePayer = _rebatePayer;
        watchdogWindow = _watchdogWindow;
        fIntBps = _fIntBps;
        minRebateClaim = 1e6; // 1 USDC default
        governance = msg.sender;

        // Initialize watchdog: matching is "alive" at deployment.
        lastMatchingCallback = uint64(block.timestamp);
        _matchingActive = true;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  Cross-chain callback entry points
    // ═══════════════════════════════════════════════════════════════════════

    function recordMatch(
        address rvmId,
        bytes32 matchId,
        bytes32 longPosId,
        bytes32 shortPosId,
        uint64 longChainId,
        uint64 shortChainId,
        uint128 matchedNotional,
        uint16 fIntBps_
    ) external onlyMatchingCallback(rvmId) {
        // Refresh watchdog liveness on every callback
        _touchWatchdog();

        // Idempotency: same matchId twice is a no-op (Reactive at-least-once)
        Match storage m = matches[matchId];
        if (m.status != MatchStatus.None) return;

        // Conflict check: neither pos can be in another active match
        if (posIdToMatch[longPosId] != bytes32(0)) {
            revert Errors.PositionAlreadyMatched(longPosId);
        }
        if (posIdToMatch[shortPosId] != bytes32(0)) {
            revert Errors.PositionAlreadyMatched(shortPosId);
        }

        m.longPosId = longPosId;
        m.shortPosId = shortPosId;
        m.longChainId = longChainId;
        m.shortChainId = shortChainId;
        m.matchedNotional = matchedNotional;
        m.startedAt = uint64(block.timestamp);
        m.lastAccrualAt = uint64(block.timestamp);
        m.fIntBpsAtMatch = fIntBps_;
        m.status = MatchStatus.Active;

        posIdToMatch[longPosId] = matchId;
        posIdToMatch[shortPosId] = matchId;

        emit MatchRecorded(
            matchId,
            longPosId,
            shortPosId,
            longChainId,
            shortChainId,
            matchedNotional,
            fIntBps_,
            uint64(block.timestamp)
        );
    }

    function cancelMatch(address rvmId, bytes32 matchId)
        external
        onlyMatchingCallback(rvmId)
    {
        _touchWatchdog();

        Match storage m = matches[matchId];
        if (m.status != MatchStatus.Active) revert Errors.MatchNotActive();

        // Accrue any pending rebate before cancelling
        _accrue(matchId, m);

        // Free both posIds for re-matching
        delete posIdToMatch[m.longPosId];
        delete posIdToMatch[m.shortPosId];

        m.status = MatchStatus.Cancelled;
        emit MatchCancelled(matchId, uint64(block.timestamp));
    }

    function settleMatch(address rvmId, bytes32 matchId, bool terminal)
        external
        onlyMatchingCallback(rvmId)
    {
        _touchWatchdog();

        Match storage m = matches[matchId];
        if (m.status != MatchStatus.Active) revert Errors.MatchNotActive();

        uint128 credited = _accrue(matchId, m);

        if (terminal) {
            delete posIdToMatch[m.longPosId];
            delete posIdToMatch[m.shortPosId];
            m.status = MatchStatus.Settled;
            emit MatchSettled(matchId, credited, uint64(block.timestamp));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            User-facing
    // ═══════════════════════════════════════════════════════════════════════

    function claimRebate(bytes32 posId) external {
        // Verify ownership via hook's stored position record
        ICrossHedgeHook.Position memory p = hook.getPosition(posId);
        if (p.owner == address(0) || p.owner != msg.sender) {
            revert Errors.NotPositionOwner();
        }

        uint128 amount = accruedRebate[posId];
        if (amount < minRebateClaim) revert Errors.RebateBelowDust();

        accruedRebate[posId] = 0;

        // External call after state change (CEI)
        rebatePayer.payRebate(msg.sender, uint256(amount));

        emit RebateClaimed(posId, msg.sender, amount);
    }

    function pingWatchdog() external {
        if (!_matchingActive) return;
        if (uint64(block.timestamp) - lastMatchingCallback <= watchdogWindow) return;

        _matchingActive = false;
        emit MatchingPaused(lastMatchingCallback, uint64(block.timestamp));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              Views
    // ═══════════════════════════════════════════════════════════════════════

    function matchingActive() external view returns (bool) {
        return _matchingActive;
    }

    function isHedged(bytes32 posId) external view returns (bool) {
        bytes32 mid = posIdToMatch[posId];
        if (mid == bytes32(0)) return false;
        return matches[mid].status == MatchStatus.Active;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    function setFIntBps(uint16 newBps) external onlyGovernance {
        fIntBps = newBps;
        emit FIntBpsUpdated(newBps);
    }

    function setMinRebateClaim(uint64 newMin) external onlyGovernance {
        minRebateClaim = newMin;
        emit MinRebateClaimUpdated(newMin);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert Errors.ZeroAddress();
        governance = newGovernance;
        emit GovernanceChanged(newGovernance);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Internals
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Refresh watchdog timestamp on any successful callback.
    function _touchWatchdog() internal {
        lastMatchingCallback = uint64(block.timestamp);
        if (!_matchingActive) {
            _matchingActive = true;
            emit MatchingResumed(uint64(block.timestamp));
        }
    }

    /// @notice Compute and credit accrued rebate from m.lastAccrualAt → now.
    ///         Credits the short side (the LP being paid for providing the hedge).
    /// @return credited Amount credited in this call.
    function _accrue(bytes32 /*matchId*/, Match storage m)
        internal
        returns (uint128 credited)
    {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs <= m.lastAccrualAt) return 0;

        uint64 elapsed = nowTs - m.lastAccrualAt;

        // rebate = notional × fIntBps × elapsed / (BPS × SECONDS_PER_YEAR)
        // Watch for overflow: notional ≤ 2^128, fIntBps ≤ 2^16, elapsed ≤ 2^64
        // Product ≤ 2^208, fits in uint256.
        uint256 numerator =
            uint256(m.matchedNotional) * uint256(m.fIntBpsAtMatch) * uint256(elapsed);
        uint256 denominator = uint256(Constants.BPS_DENOMINATOR) * uint256(Constants.SECONDS_PER_YEAR);
        uint256 amount = numerator / denominator;

        if (amount == 0) {
            m.lastAccrualAt = nowTs;
            return 0;
        }

        // Cast safety: amount derived from uint128 × uint16 × uint64 / huge denom.
        // Cap at uint128 max.
        if (amount > type(uint128).max) amount = type(uint128).max;
        credited = uint128(amount);

        // Credit to the short side (the LP receiving funding rate)
        uint128 newBal = accruedRebate[m.shortPosId] + credited;
        // Overflow protection
        if (newBal < credited) {
            newBal = type(uint128).max;
        }
        accruedRebate[m.shortPosId] = newBal;
        m.lastAccrualAt = nowTs;

        // Inform the rebatePayer (vault on home chain, proxy on remotes) so
        // its solvency accounting includes this pending liability.
        rebatePayer.accrueLiability(uint256(credited));

        emit RebateAccrued(m.shortPosId, credited, nowTs);
    }
}
