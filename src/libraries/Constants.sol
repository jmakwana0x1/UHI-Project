// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Constants
/// @notice Protocol-wide numeric constants. Centralized so that audit and tests
///         have a single source of truth for precision and time conventions.
library Constants {
    // ─── Precision ──────────────────────────────────────────────────────────
    /// @notice Scaling factor for ETH-denominated quantities (1e18).
    uint256 internal constant ETH_PRECISION = 1e18;
    /// @notice Scaling factor for USDC-denominated quantities (1e6).
    uint256 internal constant USDC_PRECISION = 1e6;
    /// @notice Scaling factor for fixed-point probability and bps-derived ratios (1e18).
    uint256 internal constant E18 = 1e18;

    // ─── Basis points ───────────────────────────────────────────────────────
    /// @notice Denominator for bps math.
    uint16 internal constant BPS_DENOMINATOR = 10_000;
    /// @notice Default protocol entry premium: 30 bps = 0.30%.
    uint16 internal constant DEFAULT_PREMIUM_BPS = 30;
    /// @notice Default internal funding rate: 1200 bps APR.
    uint16 internal constant DEFAULT_F_INT_BPS = 1200;
    /// @notice Default max slippage allowed on vault swap relative to TWAP.
    uint16 internal constant DEFAULT_MAX_SLIPPAGE_BPS = 50;

    // ─── Time ───────────────────────────────────────────────────────────────
    /// @notice Seconds in a year (365 days), used in APR-based accrual math.
    uint64 internal constant SECONDS_PER_YEAR = 365 days;
    /// @notice Default watchdog timeout: 30 minutes.
    uint64 internal constant DEFAULT_WATCHDOG_WINDOW = 30 minutes;
    /// @notice Default TWAP window for vault swap anchoring.
    uint32 internal constant DEFAULT_TWAP_WINDOW = 30 minutes;
    /// @notice Minimum holding period for a position to be eligible for rebate.
    uint64 internal constant MIN_HOLD_FOR_REBATE = 1 hours;

    // ─── Hook configuration ─────────────────────────────────────────────────
    /// @notice Size of the per-pool snapshot ring buffer.
    uint32 internal constant RING_BUFFER_SIZE = 256;
    /// @notice Minimum samples required before TWAP reads are accepted.
    uint32 internal constant MIN_SAMPLES_FOR_TWAP = 4;
    /// @notice Default tick threshold for the cheap large-move detector.
    uint16 internal constant DEFAULT_LARGE_MOVE_TICK_THRESHOLD = 200;
    /// @notice Snapshot rate-limit: minimum seconds between pushed snapshots.
    uint64 internal constant SNAPSHOT_MIN_INTERVAL_SECONDS = 30;

    // ─── Match parameters ───────────────────────────────────────────────────
    /// @notice Minimum notional size in USDC for a position to be matched.
    uint128 internal constant MIN_MATCH_NOTIONAL_USDC = 1_000 * 1e6;
    /// @notice Maximum positions processed per matching cron cycle.
    uint8 internal constant MAX_POSITIONS_PER_CYCLE = 50;
    /// @notice Maximum matches emitted per matching cron cycle.
    uint8 internal constant MAX_MATCHES_PER_CYCLE = 20;

    // ─── Strategy parameters ────────────────────────────────────────────────
    /// @notice Vol shift threshold (bps) that triggers a rebalance.
    uint16 internal constant REBALANCE_VOL_SHIFT_BPS = 3000;
    /// @notice Utilization floor (bps) below which a rebalance is triggered.
    uint16 internal constant REBALANCE_UTIL_FLOOR_BPS = 5000;
    /// @notice Maximum gap between rebalances before one is forced.
    uint64 internal constant MAX_REBALANCE_GAP = 7 days;
    /// @notice Maximum fraction (bps) of vault assets that can sit on remote chains.
    uint16 internal constant MAX_REMOTE_FLOAT_FRACTION_BPS = 3000;

    // ─── Reactive callback gas ──────────────────────────────────────────────
    /// @notice Default gas limit forwarded with Reactive Callback events.
    uint64 internal constant DEFAULT_CALLBACK_GAS_LIMIT = 1_500_000;

    // ─── Reactive special values ────────────────────────────────────────────
    /// @notice Wildcard topic value for Reactive subscriptions.
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    /// @notice Reactive system contract address (same on Mainnet and Lasna).
    address internal constant REACTIVE_SYSTEM_CONTRACT =
        0x0000000000000000000000000000000000fffFfF;
}
