// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

/// @title MockPoolManagerV2
/// @notice A flash-accounting simulator for testing the vault's rebalance flow.
///         Faithfully tracks per-currency deltas and enforces the core v4
///         invariant: every delta must net to zero before unlock() returns,
///         else CurrencyNotSettled.
///
/// @dev    What this mock simulates CORRECTLY:
///           - unlock/unlockCallback inversion
///           - per-currency signed delta ledger
///           - NonzeroDeltaCount → CurrencyNotSettled revert
///           - swap: deltas with correct signs + a simplified constant-price model
///           - modifyLiquidity: deltas based on a simplified liquidity→amount model
///           - settle: measures token transferred in, reduces caller's negative delta
///           - take: transfers token out, increases caller's negative delta
///           - sync: checkpoints balance for settle measurement
///
///         What it does NOT simulate (Phase 5 fork tests cover these):
///           - Real concentrated-liquidity swap curve
///           - Tick crossing, fee accrual
///           - Hook callbacks during swap (beforeSwap/afterSwap)
///           - Real sqrt-price evolution
///
///         Sign convention (matches v4):
///           delta < 0  → caller OWES the manager (must settle)
///           delta > 0  → manager OWES the caller (can take)
contract MockPoolManagerV2 is IPoolManager {
    using PoolIdLibrary for PoolKey;

    // Errors CurrencyNotSettled, AlreadyUnlocked, ManagerLocked,
    // MustClearExactPositiveDelta are inherited from IPoolManager.

    // ─── Flash accounting state ─────────────────────────────────────────────

    bool internal _unlocked;
    mapping(Currency => int256) internal _currencyDelta; // per-caller simplified: single caller at a time
    uint256 internal _nonzeroDeltaCount;

    /// @dev Mirrors _currencyDelta keyed by keccak256(caller, currency) so that
    ///      the real-v4 TransientStateLibrary.currencyDelta accessor (which
    ///      internally calls exttload on this key) works against the mock.
    /// @dev The "caller" we record is the address that triggered the delta
    ///      mutation (the unlock initiator). For our tests this is always
    ///      the vault, set at unlock entry.
    mapping(bytes32 => int256) internal _exttloadDeltas;
    address internal _currentCaller;

    // sync checkpoint: currency → balance recorded at sync time
    mapping(Currency => uint256) internal _syncedBalance;
    Currency internal _syncedCurrency;
    bool internal _hasSynced;

    // ─── Pool price model (simplified) ───────────────────────────────────────
    // We store a fixed sqrtPriceX96 per pool. swap() uses it to compute
    // amountOut = amountIn * price (constant-price, no slippage curve).
    mapping(PoolId => uint160) public sqrtPriceX96Of;
    mapping(PoolId => uint128) public liquidityOf;

    // ─── Events ──────────────────────────────────────────────────────────────

    event SwapExecuted(PoolId indexed poolId, bool zeroForOne, int256 amountSpecified, int256 amount0, int256 amount1);
    event LiquidityModified(PoolId indexed poolId, int256 liquidityDelta, int256 amount0, int256 amount1);
    event Settled(Currency currency, uint256 paid);
    event Taken(Currency currency, address to, uint256 amount);

    // ─── Test setup helpers ──────────────────────────────────────────────────

    function setPrice(PoolKey calldata key, uint160 sqrtPriceX96) external {
        sqrtPriceX96Of[key.toId()] = sqrtPriceX96;
    }

    function setLiquidity(PoolKey calldata key, uint128 liq) external {
        liquidityOf[key.toId()] = liq;
    }

    function currencyDelta(Currency c) external view returns (int256) {
        return _currencyDelta[c];
    }

    function nonzeroDeltaCount() external view returns (uint256) {
        return _nonzeroDeltaCount;
    }

    function isUnlocked() external view returns (bool) {
        return _unlocked;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            unlock
    // ═══════════════════════════════════════════════════════════════════════

    function unlock(bytes calldata data) external override returns (bytes memory result) {
        if (_unlocked) revert AlreadyUnlocked();
        _unlocked = true;
        _currentCaller = msg.sender;

        result = IUnlockCallback(msg.sender).unlockCallback(data);

        if (_nonzeroDeltaCount != 0) revert CurrencyNotSettled();

        _unlocked = false;
        _hasSynced = false;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            swap (simplified)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Constant-price model: amountOut = amountIn * (price or 1/price).
    ///      We honor sign conventions but NOT the real swap curve.
    ///      amountSpecified < 0 = exactIn; > 0 = exactOut. For MVP we only
    ///      support exactIn (negative amountSpecified), which is what the
    ///      vault uses.
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        override
        returns (BalanceDelta swapDelta)
    {
        if (!_unlocked) revert ManagerLocked();
        PoolId id = key.toId();

        // We only model exactIn (negative amountSpecified).
        require(params.amountSpecified < 0, "MockPMV2: only exactIn");
        uint256 amountIn = uint256(-params.amountSpecified);

        // Simplified price: treat sqrtPriceX96 as Q64.96; price = (sqrtP/2^96)^2.
        // For the mock we use a rough integer price ratio to avoid overflow:
        // priceNum/priceDen ≈ (sqrtP^2) / (2^192). We approximate with a
        // 1e18-scaled price to keep amounts sane.
        uint160 sqrtP = sqrtPriceX96Of[id];
        require(sqrtP > 0, "MockPMV2: no price set");

        // price1e18 = (sqrtP/2^96)^2 * 1e18
        // = sqrtP^2 * 1e18 / 2^192
        uint256 priceE18 = _priceE18FromSqrt(sqrtP);

        int128 amount0;
        int128 amount1;

        if (params.zeroForOne) {
            // Sell token0 for token1: amountIn token0 → amountOut token1
            uint256 amountOut = amountIn * priceE18 / 1e18;
            // caller pays token0 (delta0 negative), receives token1 (delta1 positive)
            amount0 = -int128(int256(amountIn));
            amount1 = int128(int256(amountOut));
        } else {
            // Sell token1 for token0: amountIn token1 → amountOut token0
            uint256 amountOut = amountIn * 1e18 / priceE18;
            amount1 = -int128(int256(amountIn));
            amount0 = int128(int256(amountOut));
        }

        _accountDelta(key.currency0, amount0);
        _accountDelta(key.currency1, amount1);

        swapDelta = toBalanceDelta(amount0, amount1);
        emit SwapExecuted(id, params.zeroForOne, params.amountSpecified, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          modifyLiquidity (simplified)
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Simplified: treat liquidityDelta as requiring equal "value" of both
    ///      tokens at current price. Adding liquidity → caller owes both tokens
    ///      (negative deltas). Removing → caller receives both (positive).
    ///      Amounts derived from a flat model: amount0 = |L|, amount1 = |L| * price.
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        override
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        if (!_unlocked) revert ManagerLocked();
        PoolId id = key.toId();

        uint160 sqrtP = sqrtPriceX96Of[id];
        require(sqrtP > 0, "MockPMV2: no price set");

        int256 liqDelta = params.liquidityDelta;
        uint256 absLiq = liqDelta >= 0 ? uint256(liqDelta) : uint256(-liqDelta);

        // Phase 5: use real LiquidityAmounts math so the mock and the vault's
        // valuation function agree. The two pieces share the same library, so
        // every "deploy liquidity then value it" round-trip is consistent.
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(params.tickLower);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(params.tickUpper);
        (uint256 amt0, uint256 amt1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtP, sqrtA, sqrtB, uint128(absLiq));

        int128 amount0;
        int128 amount1;
        if (liqDelta > 0) {
            // adding liquidity → caller owes tokens (negative)
            amount0 = -int128(int256(amt0));
            amount1 = -int128(int256(amt1));
        } else if (liqDelta < 0) {
            // removing liquidity → caller receives tokens (positive)
            amount0 = int128(int256(amt0));
            amount1 = int128(int256(amt1));
        }

        _accountDelta(key.currency0, amount0);
        _accountDelta(key.currency1, amount1);

        // Track pool liquidity
        if (liqDelta > 0) {
            liquidityOf[id] += uint128(absLiq);
        } else if (liqDelta < 0) {
            uint128 cur = liquidityOf[id];
            liquidityOf[id] = absLiq >= cur ? 0 : cur - uint128(absLiq);
        }

        callerDelta = toBalanceDelta(amount0, amount1);
        feesAccrued = toBalanceDelta(0, 0);
        emit LiquidityModified(id, liqDelta, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          sync / settle / take
    // ═══════════════════════════════════════════════════════════════════════

    function sync(Currency currency) external override {
        _syncedCurrency = currency;
        _syncedBalance[currency] = _balanceOf(currency);
        _hasSynced = true;
    }

    /// @dev settle measures how much token arrived since sync and reduces the
    ///      caller's negative delta accordingly.
    function settle() external payable override returns (uint256 paid) {
        if (!_unlocked) revert ManagerLocked();
        Currency c = _syncedCurrency;
        require(_hasSynced, "MockPMV2: must sync before settle");

        uint256 currentBal = _balanceOf(c);
        uint256 prevBal = _syncedBalance[c];
        paid = currentBal > prevBal ? currentBal - prevBal : 0;

        // Reduce caller's negative delta (caller owed `paid` worth)
        _accountDelta(c, int128(int256(paid)));

        _hasSynced = false;
        emit Settled(c, paid);
    }

    function settleFor(address) external payable override returns (uint256) {
        revert("MockPMV2: settleFor not implemented");
    }

    function take(Currency currency, address to, uint256 amount) external override {
        if (!_unlocked) revert ManagerLocked();
        // caller takes tokens out → their delta decreases (more negative / less positive)
        _accountDelta(currency, -int128(int256(amount)));
        IERC20(Currency.unwrap(currency)).transfer(to, amount);
        emit Taken(currency, to, amount);
    }

    function clear(Currency currency, uint256 amount) external override {
        if (!_unlocked) revert ManagerLocked();
        // Zero out a positive delta WITHOUT transfer (forfeits the value).
        require(_currencyDelta[currency] == int256(amount), "MockPMV2: clear must match exact positive delta");
        _accountDelta(currency, -int128(int256(amount)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Internals
    // ═══════════════════════════════════════════════════════════════════════

    function _accountDelta(Currency currency, int128 delta) internal {
        if (delta == 0) return;

        int256 prev = _currencyDelta[currency];
        int256 next = prev + int256(delta);

        // Maintain nonzeroDeltaCount
        if (prev == 0 && next != 0) {
            _nonzeroDeltaCount++;
        } else if (prev != 0 && next == 0) {
            _nonzeroDeltaCount--;
        }

        _currencyDelta[currency] = next;

        // Mirror to the keccak-keyed mapping so TransientStateLibrary's
        // exttload-based read returns the same value.
        bytes32 key = _deltaKey(_currentCaller, currency);
        _exttloadDeltas[key] = next;
    }

    function _deltaKey(address target, Currency currency) internal pure returns (bytes32 key) {
        assembly ("memory-safe") {
            mstore(0, and(target, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(32, and(currency, 0xffffffffffffffffffffffffffffffffffffffff))
            key := keccak256(0, 64)
        }
    }

    function _balanceOf(Currency currency) internal view returns (uint256) {
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /// @dev price1e18 = (sqrtP / 2^96)^2 * 1e18, computed without overflow.
    ///      sqrtP fits in uint160. sqrtP^2 fits in uint320 → we split.
    ///      We compute (sqrtP^2 * 1e18) >> 192 using mulDiv-style reduction.
    function _priceE18FromSqrt(uint160 sqrtP) internal pure returns (uint256) {
        // ratioX128 = sqrtP^2 >> 64  (gives price in Q64.64-ish)
        // To avoid overflow: sqrtP^2 can be up to (2^160)^2 = 2^320. Too big.
        // Use the standard approach: priceX96 = (sqrtP * sqrtP) >> 96, then
        // priceE18 = priceX96 * 1e18 >> 96.
        // But sqrtP*sqrtP overflows uint256 if sqrtP > 2^128.
        // For test prices we keep sqrtP modest (around 2^96 = price ~1).
        // So sqrtP^2 ~ 2^192 fits in uint256.
        uint256 sp = uint256(sqrtP);
        uint256 priceX192 = sp * sp; // fits if sqrtP < 2^128
        // priceE18 = priceX192 * 1e18 / 2^192
        // 2^192 is large; do it in two shifts to preserve precision.
        // priceE18 = (priceX192 >> 96) * 1e18 >> 96
        uint256 priceX96 = priceX192 >> 96;
        uint256 priceE18 = (priceX96 * 1e18) >> 96;
        return priceE18 == 0 ? 1 : priceE18; // floor at 1 to avoid div-by-zero
    }

    // ═══════════════════════════════════════════════════════════════════════
    //          Unused IPoolManager surface (revert if called)
    // ═══════════════════════════════════════════════════════════════════════

    function initialize(PoolKey memory, uint160) external pure override returns (int24) {
        revert("MockPMV2: initialize not implemented");
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata)
        external pure override returns (BalanceDelta)
    {
        revert("MockPMV2: donate not implemented");
    }

    function mint(address, uint256, uint256) external pure override {
        revert("MockPMV2: mint not implemented");
    }

    function burn(address, uint256, uint256) external pure override {
        revert("MockPMV2: burn not implemented");
    }

    function updateDynamicLPFee(PoolKey memory, uint24) external pure override {
        revert("MockPMV2: updateDynamicLPFee not implemented");
    }

    // ─── IProtocolFees / extsload / exttload surface (minimal stubs) ───────

    function protocolFeesAccrued(Currency) external pure override returns (uint256) { return 0; }
    function setProtocolFee(PoolKey memory, uint24) external pure override {}
    function setProtocolFeeController(address) external pure override {}
    function collectProtocolFees(address, Currency, uint256) external pure override returns (uint256) { return 0; }
    function protocolFeeController() external pure override returns (address) { return address(0); }

    function extsload(bytes32) external pure override returns (bytes32) { return bytes32(0); }
    function extsload(bytes32, uint256) external pure override returns (bytes32[] memory) { return new bytes32[](0); }
    function extsload(bytes32[] calldata) external pure override returns (bytes32[] memory) { return new bytes32[](0); }
    function exttload(bytes32 slot) external view override returns (bytes32) {
        return bytes32(uint256(_exttloadDeltas[slot]));
    }
    function exttload(bytes32[] calldata) external pure override returns (bytes32[] memory) { return new bytes32[](0); }

    // ─── ERC6909 surface (minimal stubs) ──────────────────────────────────

    function balanceOf(address, uint256) external pure override returns (uint256) { return 0; }
    function allowance(address, address, uint256) external pure override returns (uint256) { return 0; }
    function isOperator(address, address) external pure override returns (bool) { return false; }
    function transfer(address, uint256, uint256) external pure override returns (bool) { return false; }
    function transferFrom(address, address, uint256, uint256) external pure override returns (bool) { return false; }
    function approve(address, uint256, uint256) external pure override returns (bool) { return false; }
    function setOperator(address, bool) external pure override returns (bool) { return false; }
}
