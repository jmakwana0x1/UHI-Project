// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReactiveConstants
/// @notice Chain IDs, the Reactive system contract address, cron topics, and
///         event topic hashes used by MatchingRSC and StrategyRSC.
///
/// @dev    Cron topic values from Reactive Network docs:
///           - CRON_TOPIC_1   = topic emitted every  1 block on Lasna
///           - CRON_TOPIC_10  = every 10 blocks
///           - CRON_TOPIC_100 = every 100 blocks
///         Lasna block time ≈ 1s, so CRON_TOPIC_100 ≈ 100s cadence.
///
///         For matching we use CRON_TOPIC_100 (~100s ≈ 2 min); for strategy
///         we'd ideally use a slower cron but for MVP we use the same and
///         throttle internally via lastCronTick comparison.
library ReactiveConstants {
    // ─── Chain IDs ─────────────────────────────────────────────────────────
    uint256 internal constant LASNA_CHAIN_ID = 5318008;
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    // ─── System contract ──────────────────────────────────────────────────
    address internal constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    // ─── REACTIVE_IGNORE for "any topic" filtering ────────────────────────
    uint256 internal constant REACTIVE_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    // ─── Cron topics (placeholders; final values from Reactive deploy) ────
    // These are the topic_0 values emitted by the system contract on each
    // cron interval. We use placeholders; the actual values are network-
    // specific and confirmed at deployment time (Phase 5).
    uint256 internal constant CRON_TOPIC_FAST_PLACEHOLDER =
        uint256(keccak256("CRON_FAST"));
    uint256 internal constant CRON_TOPIC_SLOW_PLACEHOLDER =
        uint256(keccak256("CRON_SLOW"));

    // ─── Origin-chain event topic hashes ──────────────────────────────────
    // keccak256 of the canonical event signatures. These must match exactly
    // what CrossHedgeHook + NettingRegistry emit.

    // event PriceSnapshot(PoolId indexed poolId, uint160 sqrtPriceX96, uint64 timestamp);
    uint256 internal constant TOPIC_PRICE_SNAPSHOT =
        uint256(keccak256("PriceSnapshot(bytes32,uint160,uint64)"));

    // event LPPositionOpened(
    //   bytes32 indexed posId, PoolId indexed poolId, address indexed owner,
    //   int24 tickLower, int24 tickUpper, uint128 liquidity,
    //   int256 signedDelta, uint128 gamma, uint8 horizonBucket, bool unhedged
    // );
    uint256 internal constant TOPIC_LP_POSITION_OPENED =
        uint256(keccak256(
            "LPPositionOpened(bytes32,bytes32,address,int24,int24,uint128,int256,uint128,uint8,bool)"
        ));

    // event LPPositionClosed(bytes32 indexed posId, PoolId indexed poolId, address indexed owner);
    uint256 internal constant TOPIC_LP_POSITION_CLOSED =
        uint256(keccak256("LPPositionClosed(bytes32,bytes32,address)"));

    // event MatchRecorded(
    //   bytes32 indexed matchId, bytes32 indexed longPosId, bytes32 indexed shortPosId,
    //   uint64 longChainId, uint64 shortChainId, uint128 matchedNotional,
    //   uint16 fIntBps, uint64 timestamp
    // );
    uint256 internal constant TOPIC_MATCH_RECORDED =
        uint256(keccak256(
            "MatchRecorded(bytes32,bytes32,bytes32,uint64,uint64,uint128,uint16,uint64)"
        ));

    // ─── Default gas limits for cross-chain callbacks ─────────────────────
    uint64 internal constant DEFAULT_MATCH_CALLBACK_GAS = 500_000;
    uint64 internal constant DEFAULT_REBALANCE_CALLBACK_GAS = 2_000_000;
}
