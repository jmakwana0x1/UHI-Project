// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/utils/BaseHook.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";

import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";
import {PositionIdLib} from "../libraries/PositionIdLib.sol";
import {DeltaMath} from "./DeltaMath.sol";
import {TwapBuffer} from "./TwapBuffer.sol";

/// @title CrossHedgeHook
/// @notice Uniswap v4 hook for the CrossHedge protocol.
/// @dev    Responsibilities:
///           1. Track every LP position open/close and emit structured events
///              for MatchingRSC to consume.
///           2. Charge a 3 bps entry premium on hedged positions via positive
///              hookDelta on USDC.
///           3. Push price snapshots into a ring buffer used as our own TWAP
///              source (v4 has no native TWAP for vanilla pools).
///           4. Auto-ping the watchdog on every add to keep matching liveness
///              detection up to date.
contract CrossHedgeHook is BaseHook, ICrossHedgeHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using TwapBuffer for TwapBuffer.Snapshot[256];

    // ─── Immutables ─────────────────────────────────────────────────────────

    INettingRegistry public immutable nettingRegistry;
    address public immutable override vault;
    uint16 public immutable premiumBps;
    bool public immutable usdcIsToken0;

    // ─── Constants ──────────────────────────────────────────────────────────

    /// @notice Annualized vol assumption for syntheticShortDelta credit.
    /// @dev    MVP constant. ETH realized vol historically 50-80% annualized;
    ///         60% is a defensible middle. v3 will source from StrategyRSC's
    ///         VolEMA or a dedicated vol oracle.
    uint256 internal constant ANNUALIZED_VOL_E18 = 0.6e18;

    // ─── Per-pool state ─────────────────────────────────────────────────────

    struct PoolState {
        bool registered;
        uint16 largeMoveTickThreshold;
        int24 lastObservedTick;
        uint160 lastObservedSqrtPriceX96;
        uint64 lastSnapshotTimestamp;
        uint32 ringBufferHead;
    }

    mapping(PoolId => PoolState) public poolStates;
    mapping(PoolId => TwapBuffer.Snapshot[256]) internal _ringBuffers;
    mapping(bytes32 => Position) internal _positions;

    uint256 public override premiumBalance;

    // ─── Events ─────────────────────────────────────────────────────────────

    event PoolRegistered(PoolId indexed poolId, address indexed nettingRegistry, uint24 fee);
    event LPPositionOpened(
        bytes32 indexed posId,
        PoolId indexed poolId,
        address indexed owner,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        int256 signedDelta,
        uint128 gamma,
        uint8 horizonBucket,
        bool unhedged
    );
    event LPPositionClosed(bytes32 indexed posId, PoolId indexed poolId, address indexed owner);
    event LargeTickMove(
        PoolId indexed poolId,
        int24 oldTick,
        int24 newTick,
        uint160 newSqrtPriceX96
    );
    event PriceSnapshot(PoolId indexed poolId, uint160 sqrtPriceX96, uint64 timestamp);
    event PremiumCollected(PoolId indexed poolId, bytes32 indexed posId, uint128 amountUsdc);
    event PremiumHarvested(uint256 amount, address indexed to);

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        IPoolManager _poolManager,
        INettingRegistry _registry,
        address _vault,
        uint16 _premiumBps,
        bool _usdcIsToken0
    ) BaseHook(_poolManager) {
        nettingRegistry = _registry;
        vault = _vault;
        premiumBps = _premiumBps;
        usdcIsToken0 = _usdcIsToken0;
    }

    // ─── Hook permission bitmap ─────────────────────────────────────────────

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return Hooks.Permissions({
            beforeInitialize:                false,
            afterInitialize:                 true,
            beforeAddLiquidity:              false,
            afterAddLiquidity:               true,
            beforeRemoveLiquidity:           false,
            afterRemoveLiquidity:            true,
            beforeSwap:                      true,
            afterSwap:                       true,
            beforeDonate:                    false,
            afterDonate:                     false,
            beforeSwapReturnDelta:           false,
            afterSwapReturnDelta:            false,
            afterAddLiquidityReturnDelta:    true,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Hook callbacks
    // ═══════════════════════════════════════════════════════════════════════

    function _afterInitialize(
        address /*sender*/,
        PoolKey calldata key,
        uint160 sqrtPriceX96,
        int24 tick
    ) internal override returns (bytes4) {
        PoolId pid = key.toId();
        PoolState storage ps = poolStates[pid];
        ps.registered = true;
        ps.largeMoveTickThreshold = Constants.DEFAULT_LARGE_MOVE_TICK_THRESHOLD;
        ps.lastObservedTick = tick;
        ps.lastObservedSqrtPriceX96 = sqrtPriceX96;
        ps.lastSnapshotTimestamp = uint64(block.timestamp);

        // Seed the ring buffer with the initial sample.
        ps.ringBufferHead = TwapBuffer.push(
            _ringBuffers[pid],
            0,
            sqrtPriceX96,
            uint64(block.timestamp)
        );

        emit PoolRegistered(pid, address(nettingRegistry), key.fee);
        emit PriceSnapshot(pid, sqrtPriceX96, uint64(block.timestamp));

        return IHooks.afterInitialize.selector;
    }

    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId pid = key.toId();
        if (!poolStates[pid].registered) revert Errors.UnregisteredPool();

        // Removes are NOT routed here (they go to _afterRemoveLiquidity).
        // We only react to positive liquidity changes.
        if (params.liquidityDelta <= 0) {
            return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        uint128 liq = uint128(uint256(params.liquidityDelta));

        // Decode hookData (lenient: empty → defaults).
        (address ownerHint, uint8 horizonBucket) = _decodeHookData(hookData, sender);

        // Read current sqrt-price via StateLibrary.
        (uint160 sqrtP,,,) = poolManager.getSlot0(pid);

        // Compute notional in USDC.
        uint256 notionalUsdc = _computeNotionalUsdc(
            liq,
            sqrtP,
            params.tickLower,
            params.tickUpper
        );

        // Compute signed delta. The sign depends on the position's location
        // relative to the current pool tick:
        //   - tickLower >= currentTick  → above-range, holds USDC only, SHORT ETH
        //     (synthetic delta credit weighted by P(price reaches range))
        //   - otherwise (in-range or below-range) → LONG ETH (spot delta)
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtP);
        int256 signedDelta;
        if (params.tickLower >= currentTick) {
            uint160 sqrtL = TickMath.getSqrtPriceAtTick(params.tickLower);
            uint160 sqrtU = TickMath.getSqrtPriceAtTick(params.tickUpper);
            uint128 touchProb = DeltaMath.touchProbability(
                sqrtP, sqrtU, _horizonSeconds(horizonBucket), ANNUALIZED_VOL_E18
            );
            signedDelta = DeltaMath.syntheticShortDelta(
                liq, sqrtL, sqrtU, touchProb, usdcIsToken0
            );
        } else {
            signedDelta = DeltaMath.spotEthDelta(
                liq, sqrtP, params.tickLower, params.tickUpper, usdcIsToken0
            );
        }
        uint128 gammaVal = DeltaMath.gamma(liq, params.tickLower, params.tickUpper, sqrtP);

        // Compute posId (mirrors v4's internal position key + poolId).
        bytes32 posId = PositionIdLib.compute(
            pid, ownerHint, params.tickLower, params.tickUpper, params.salt
        );

        // ─── Watchdog ping + hedged status ───────────────────────────────
        nettingRegistry.pingWatchdog();
        bool hedged = nettingRegistry.matchingActive();

        // ─── Premium charging ────────────────────────────────────────────
        uint128 premium;
        BalanceDelta hookDelta = BalanceDeltaLibrary.ZERO_DELTA;
        bool isVaultSender = sender == vault;
        bool shouldCharge = hedged && !isVaultSender;

        if (shouldCharge) {
            uint256 raw = (notionalUsdc * uint256(premiumBps)) / Constants.BPS_DENOMINATOR;
            if (raw == 0) {
                shouldCharge = false; // dust position; skip charging
            } else if (raw > uint256(uint128(type(int128).max))) {
                revert Errors.PremiumDeductionFailed();
            } else {
                premium = uint128(raw);
                premiumBalance += raw;
                hookDelta = usdcIsToken0
                    ? toBalanceDelta(int128(premium), int128(0))
                    : toBalanceDelta(int128(0), int128(premium));

                // ─── Phase 5 fix: claim the hook's positive delta ────────
                // v4 applies hookDelta to the hook's account (positive = owed).
                // Without a matching take(), the delta stays unsettled and
                // unlockCallback reverts with CurrencyNotSettled. This was
                // invisible against MockPoolManager (whose take() is a no-op
                // and which doesn't track hook-side deltas) but real v4
                // enforces it strictly.
                Currency usdcCurrency = usdcIsToken0 ? key.currency0 : key.currency1;
                poolManager.take(usdcCurrency, address(this), raw);

                emit PremiumCollected(pid, posId, premium);
            }
        }

        // ─── Store position record ───────────────────────────────────────
        _positions[posId] = Position({
            owner: ownerHint,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            unhedged: !shouldCharge && !isVaultSender,
            liquidity: liq,
            openedAt: uint64(block.timestamp),
            poolId: pid
        });

        // ─── Emit event for RSC ──────────────────────────────────────────
        emit LPPositionOpened(
            posId,
            pid,
            ownerHint,
            params.tickLower,
            params.tickUpper,
            liq,
            signedDelta,
            gammaVal,
            horizonBucket,
            !shouldCharge && !isVaultSender
        );

        // ─── Maybe push a snapshot (rate-limited) ────────────────────────
        _maybePushSnapshot(pid, sqrtP);

        return (IHooks.afterAddLiquidity.selector, hookDelta);
    }

    function _afterRemoveLiquidity(
        address /*sender*/,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta /*delta*/,
        BalanceDelta /*feesAccrued*/,
        bytes calldata hookData
    ) internal override returns (bytes4, BalanceDelta) {
        PoolId pid = key.toId();
        (address ownerHint,) = _decodeHookData(hookData, address(0));
        if (ownerHint == address(0)) ownerHint = msg.sender;

        bytes32 posId = PositionIdLib.compute(
            pid, ownerHint, params.tickLower, params.tickUpper, params.salt
        );

        Position storage p = _positions[posId];
        if (p.owner == address(0)) {
            // Unknown position — possibly opened before hook deployment.
            // No-op tolerated.
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // For full-close (most common case), wipe the record.
        // For partial close, leave the record but update liquidity.
        uint128 removed = uint128(uint256(-params.liquidityDelta));
        if (removed >= p.liquidity) {
            address owner_ = p.owner;
            delete _positions[posId];
            emit LPPositionClosed(posId, pid, owner_);
        } else {
            unchecked {
                p.liquidity -= removed;
            }
        }

        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function _beforeSwap(
        address /*sender*/,
        PoolKey calldata key,
        SwapParams calldata /*params*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId pid = key.toId();
        if (!poolStates[pid].registered) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint160 sqrtP, int24 tick,,) = poolManager.getSlot0(pid);
        PoolState storage ps = poolStates[pid];

        int24 diff = tick > ps.lastObservedTick
            ? tick - ps.lastObservedTick
            : ps.lastObservedTick - tick;

        if (uint256(uint24(diff)) > uint256(ps.largeMoveTickThreshold)) {
            int24 oldTick = ps.lastObservedTick;
            ps.lastObservedTick = tick;
            ps.lastObservedSqrtPriceX96 = sqrtP;
            emit LargeTickMove(pid, oldTick, tick, sqrtP);
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(
        address /*sender*/,
        PoolKey calldata key,
        SwapParams calldata /*params*/,
        BalanceDelta /*delta*/,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        PoolId pid = key.toId();
        if (!poolStates[pid].registered) {
            return (IHooks.afterSwap.selector, int128(0));
        }
        (uint160 sqrtP,,,) = poolManager.getSlot0(pid);
        _maybePushSnapshot(pid, sqrtP);
        return (IHooks.afterSwap.selector, int128(0));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                         External (non-hook)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Drain accumulated premium balance.
    /// @dev    MVP simplification: returns the balance and zeros it. The actual
    ///         token transfer happens via the vault's own premium flow (Phase 4
    ///         wires the vault to pull from the hook's USDC ledger via
    ///         poolManager.take). For Phase 2 testing, this is enough.
    function harvestPremiums(address to) external override returns (uint256 amount) {
        if (msg.sender != vault) revert Errors.HookOnly();
        amount = premiumBalance;
        premiumBalance = 0;
        emit PremiumHarvested(amount, to);
    }

    function getPosition(bytes32 posId)
        external
        view
        override
        returns (Position memory)
    {
        return _positions[posId];
    }

    /// @notice Read TWAP sqrt-price over window.
    function readTwapSqrtPrice(PoolId poolId, uint32 windowSeconds)
        external
        view
        returns (uint160 meanSqrt, uint32 sampleCount)
    {
        (meanSqrt, sampleCount,) = TwapBuffer.meanSqrtPrice(
            _ringBuffers[poolId],
            poolStates[poolId].ringBufferHead,
            windowSeconds,
            uint64(block.timestamp)
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                              Internals
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Map horizon bucket index to seconds for vol-based math.
    /// @dev    Buckets: 0=7d, 1=30d, 2=90d, 3=365d (default).
    function _horizonSeconds(uint8 bucket) private pure returns (uint64) {
        if (bucket == 0) return 7 days;
        if (bucket == 1) return 30 days;
        if (bucket == 2) return 90 days;
        return 365 days;
    }

    function _decodeHookData(bytes calldata hookData, address fallbackOwner)
        internal
        pure
        returns (address owner_, uint8 horizonBucket)
    {
        if (hookData.length == 0) {
            return (fallbackOwner, 1); // 1 = MEDIUM (30d) default
        }
        if (hookData.length < 32) revert Errors.HookDataMalformed();
        // Layout: (address owner, uint8 horizonBucket) abi-encoded
        (owner_, horizonBucket) = abi.decode(hookData, (address, uint8));
        if (owner_ == address(0)) owner_ = fallbackOwner;
    }

    function _computeNotionalUsdc(
        uint128 liq,
        uint160 sqrtP,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256) {
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, liq);

        // notional in USDC = USDC amount + ETH amount converted at current price
        uint256 usdcAmount = usdcIsToken0 ? amount0 : amount1;
        uint256 ethAmount = usdcIsToken0 ? amount1 : amount0;

        // Convert ethAmount (in 1e18 wei) to USDC (1e6) at sqrt-price.
        // price = (sqrtP / Q96)² , in USDC-per-ETH if usdcIsToken0
        // ethAmount_USDC = ethAmount * price * 1e6 / 1e18
        // Using FullMath:
        //   price_X192 = sqrtP² (Q192 fixed point)
        //   ethAmount * price_X192 / Q192 = ethAmount in USDC if usdcIsToken0
        // For our MVP single-pool simplification we compute price first.
        uint256 priceX96 = FullMath.mulDiv(uint256(sqrtP), uint256(sqrtP), FixedPoint96.Q96);

        uint256 ethAsUsdc;
        if (usdcIsToken0) {
            // price_X96 is USDC-per-ETH × 1e? : need to factor in decimals.
            // For MVP simplification: assume USDC is 1e6 and ETH is 1e18.
            // ethAsUsdc = ethAmount * priceX96 / Q96 (this is USDC raw)
            ethAsUsdc = FullMath.mulDiv(ethAmount, priceX96, FixedPoint96.Q96);
        } else {
            // Inverse: ETH-per-USDC. ethAsUsdc = ethAmount * Q96 / priceX96
            if (priceX96 == 0) {
                ethAsUsdc = 0;
            } else {
                ethAsUsdc = FullMath.mulDiv(ethAmount, FixedPoint96.Q96, priceX96);
            }
        }

        return usdcAmount + ethAsUsdc;
    }

    function _maybePushSnapshot(PoolId pid, uint160 sqrtP) internal {
        PoolState storage ps = poolStates[pid];
        uint64 nowTs = uint64(block.timestamp);

        if (nowTs - ps.lastSnapshotTimestamp < Constants.SNAPSHOT_MIN_INTERVAL_SECONDS) {
            return;
        }

        ps.ringBufferHead = TwapBuffer.push(_ringBuffers[pid], ps.ringBufferHead, sqrtP, nowTs);
        ps.lastSnapshotTimestamp = nowTs;
        emit PriceSnapshot(pid, sqrtP, nowTs);
    }
}
