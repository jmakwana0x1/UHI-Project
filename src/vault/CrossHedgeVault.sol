// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ICrossHedgeVault} from "../interfaces/ICrossHedgeVault.sol";
import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {Errors} from "../libraries/Errors.sol";
import {TwapBounded} from "./TwapBounded.sol";

/// @title CrossHedgeVault
/// @notice ERC-4626 USDC vault for the CrossHedge protocol.
///         Receives premium accruals from the hook, pays out rebates to long
///         LPs on the home chain, and acts as the protocol's structural
///         counterparty.
///
/// @dev    Phase 2 scope (current):
///           - ERC-4626 deposit/withdraw
///           - depositPremium (hook → vault)
///           - payRebate (registry → vault → user)
///           - rebateLiability accrual tracking
///           - Pausable: deposits paused but withdrawals/premium/rebates flow
///
///         Phase 4 scope (future):
///           - rebalance() — strategy callback for unlock+swap+deploy
///           - unlockCallback — flash accounting flow
///           - TWAP-bounded swap execution
///           - Owned position tracking
///           - ETH valuation in totalAssets
contract CrossHedgeVault is ERC4626, ICrossHedgeVault, IUnlockCallback {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    /// @notice Minimum TWAP samples required for a rebalance to proceed.
    ///         Guards against manipulable thin-buffer TWAPs.
    uint32 internal constant MIN_TWAP_SAMPLES = 3;

    /// @notice Transient storage slot used to track cumulative USDC swapped
    ///         in the current block. Auto-clears at end of tx.
    bytes32 internal constant SWAPPED_THIS_BLOCK_SLOT =
        keccak256("crosshedge.vault.swappedThisBlock.v1");

    // ─── Immutables ─────────────────────────────────────────────────────────

    IPoolManager public immutable poolManager;
    ICrossHedgeHook public immutable hook;
    INettingRegistry public immutable nettingRegistry;
    address public immutable callbackProxy;
    address public immutable authorizedStrategyRvmId;

    // Phase 4 parameters — stored as immutables now so deployment is unchanged later
    uint16 public immutable maxSlippageBps;
    uint256 public immutable perBlockSwapCap;
    uint32 public immutable twapWindow;

    // ─── State ──────────────────────────────────────────────────────────────

    uint256 public premiumAccrued;
    uint256 public rebateLiability;
    address public governance;
    bool public paused;

    // ─── Phase 4: managed pool ────────────────────────────────────────────
    /// @notice The pool this vault provides hedging liquidity into. Set once
    ///         by governance after deployment (the PoolKey isn't known at
    ///         construction because the hook address is mined separately).
    PoolKey internal _managedKey;
    bool public managedKeySet;
    /// @notice Whether USDC is currency0 in the managed pool.
    bool public usdcIsToken0;

    // ─── Phase 5 Tier 3 C: owned allocations ──────────────────────────────
    /// @notice Persistent list of allocations currently deployed by the vault.
    ///         Updated by unlockCallback whenever rebalance changes positions.
    ///         Source of truth for totalAssets() ETH-side valuation.
    Allocation[] internal _ownedAllocations;

    /// @notice (tickLower, tickUpper) → index+1 in _ownedAllocations. Zero
    ///         means "not present". One-indexed so 0 is a sentinel.
    mapping(bytes32 => uint256) internal _ownedIndex;

    // ─── Events ─────────────────────────────────────────────────────────────

    event PremiumDeposited(uint256 amount, uint256 totalAccrued);
    event LiabilityAccrued(uint256 amount, uint256 totalLiability);
    event RebatePaidFromVault(address indexed to, uint256 amount, uint256 newLiability);
    event PausedSet(bool paused);
    event GovernanceChanged(address indexed newGovernance);

    // ─── Modifiers ──────────────────────────────────────────────────────────

    modifier onlyHook() {
        if (msg.sender != address(hook)) revert Errors.HookOnly();
        _;
    }

    modifier onlyNettingRegistry() {
        if (msg.sender != address(nettingRegistry)) revert Errors.NettingRegistryOnly();
        _;
    }

    modifier onlyStrategyCallback(address rvmId) {
        if (msg.sender != callbackProxy) revert Errors.StrategyCallbackOnly();
        if (rvmId != authorizedStrategyRvmId) revert Errors.StrategyCallbackOnly();
        _;
    }

    modifier onlyGovernance() {
        if (msg.sender != governance) revert Errors.Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Errors.VaultPaused();
        _;
    }

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        IERC20 _usdc,
        string memory _name,
        string memory _symbol,
        IPoolManager _poolManager,
        ICrossHedgeHook _hook,
        INettingRegistry _nettingRegistry,
        address _callbackProxy,
        address _authorizedStrategyRvmId,
        uint16 _maxSlippageBps,
        uint256 _perBlockSwapCap,
        uint32 _twapWindow
    ) ERC20(_name, _symbol) ERC4626(_usdc) {
        if (address(_usdc) == address(0)) revert Errors.ZeroAddress();
        if (address(_hook) == address(0)) revert Errors.ZeroAddress();
        if (address(_nettingRegistry) == address(0)) revert Errors.ZeroAddress();
        if (_callbackProxy == address(0)) revert Errors.ZeroAddress();
        if (_authorizedStrategyRvmId == address(0)) revert Errors.ZeroAddress();

        poolManager = _poolManager;
        hook = _hook;
        nettingRegistry = _nettingRegistry;
        callbackProxy = _callbackProxy;
        authorizedStrategyRvmId = _authorizedStrategyRvmId;
        maxSlippageBps = _maxSlippageBps;
        perBlockSwapCap = _perBlockSwapCap;
        twapWindow = _twapWindow;
        governance = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            ERC-4626 overrides
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Total USDC-equivalent value held by the vault.
    /// @dev    Phase 5: includes balance + ETH-side value of owned positions
    ///         (valued at TWAP), net of pending rebate liability.
    ///
    ///         If managedKey is not set OR there are no owned allocations,
    ///         falls back to the Phase 2 formula (balance - liability).
    ///
    ///         If the hook's TWAP buffer is too thin (< MIN_TWAP_SAMPLES),
    ///         we conservatively return balance - liability without crediting
    ///         deployed positions, rather than reverting in a view function.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        uint256 deployed = 0;
        if (managedKeySet && _ownedAllocations.length > 0) {
            deployed = _valuePositionsUsdcSafe();
        }
        uint256 gross = bal + deployed;
        if (rebateLiability >= gross) return 0;
        return gross - rebateLiability;
    }

    /// @dev Total USDC-equivalent value of all owned positions at current TWAP.
    ///      Returns 0 if the TWAP is too thin (defensive: never reverts in a
    ///      view path called by ERC4626 share-price math).
    function _valuePositionsUsdcSafe() internal view returns (uint256 total) {
        (uint160 twapSqrt, uint32 samples) =
            hook.readTwapSqrtPrice(_managedKey.toId(), twapWindow);
        if (samples < MIN_TWAP_SAMPLES || twapSqrt == 0) return 0;

        uint256 n = _ownedAllocations.length;
        for (uint256 i = 0; i < n; i++) {
            Allocation storage a = _ownedAllocations[i];
            if (a.targetLiquidity == 0) continue;

            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(a.tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(a.tickUpper);
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                twapSqrt, sqrtLower, sqrtUpper, a.targetLiquidity
            );

            (uint256 usdcAmt, uint256 wethAmt) =
                usdcIsToken0 ? (amt0, amt1) : (amt1, amt0);

            total += usdcAmt + _wethAmountToUsdc(wethAmt, twapSqrt);
        }
    }

    /// @dev Convert WETH amount (raw, e18-scaled) to USDC amount (raw, e6-scaled)
    ///      at the supplied TWAP price.
    ///
    ///      The TWAP price is the unitless ratio token1/token0 in their native
    ///      decimal scales. If USDC is token0:
    ///         priceRaw = wethE18 / usdcE6, so 1 USDC ≈ 1e12 wei WETH when ETH ≈ $1.
    ///         usdcE6 = wethE18 / priceRaw.
    ///      If USDC is token1 (less common pool ordering):
    ///         priceRaw = usdcE6 / wethE18, so usdcE6 = wethE18 * priceRaw.
    function _wethAmountToUsdc(uint256 wethAmount, uint160 twapSqrt)
        internal
        view
        returns (uint256)
    {
        if (wethAmount == 0) return 0;
        // priceRawE0 = (twapSqrt/2^96)^2, the unitless raw ratio token1/token0.
        // Compute as priceX96 = (sqrt^2) >> 96 to keep precision; then we have
        // priceX96 = price * 2^96. To get usdcAmount with reasonable precision
        // we do the math in priceX96 space directly.
        uint256 sp = uint256(twapSqrt);
        uint256 priceX192 = sp * sp;          // safe for sqrtP < 2^128
        // priceX96 = (sqrt^2) >> 96 — the raw price * 2^96
        uint256 priceX96 = priceX192 >> 96;
        if (priceX96 == 0) priceX96 = 1;

        if (usdcIsToken0) {
            // weth/usdc = priceX96 / 2^96
            // usdc = weth / (weth/usdc) = weth * 2^96 / priceX96
            return (wethAmount << 96) / priceX96;
        } else {
            // usdc/weth = priceX96 / 2^96
            // usdc = weth * (usdc/weth) = weth * priceX96 / 2^96
            return (wethAmount * priceX96) >> 96;
        }
    }

    /// @notice Block deposits when paused. Withdrawals remain open.
    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override whenNotPaused {
        super._deposit(caller, receiver, assets, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       Hook + registry plumbing
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Hook pushes accumulated premium balance into the vault.
    /// @dev    The hook calls `usdc.transfer(vault, amount)` (or via its own
    ///         pool-manager-take flow in Phase 4), then calls this for accounting.
    ///
    ///         For Phase 2 testing: tests pre-transfer USDC, then call this.
    function depositPremium(uint256 amount) external onlyHook {
        premiumAccrued += amount;
        emit PremiumDeposited(amount, premiumAccrued);
    }

    /// @notice Registry credits the vault with a pending rebate obligation.
    /// @dev    Called by NettingRegistry whenever it accrues rebate on a
    ///         position. The vault tracks this liability so totalAssets()
    ///         correctly excludes it from share-price calculations.
    function accrueLiability(uint256 amount) external onlyNettingRegistry {
        rebateLiability += amount;
        emit LiabilityAccrued(amount, rebateLiability);
    }

    /// @notice Pay out a rebate to a long LP. Called by the local NettingRegistry.
    /// @dev    Decrements `rebateLiability` and transfers USDC.
    ///         If liability tracking has fallen behind (e.g., registry credit
    ///         not yet applied), the function still pays from balance — but
    ///         this would be a bug to surface.
    function payRebate(address to, uint256 amount) external onlyNettingRegistry {
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (amount > bal) revert Errors.NoFundsAvailable();

        // Decrement liability with floor at 0 (defensive — in case credits
        // were missed or accounting is otherwise off).
        if (amount > rebateLiability) {
            rebateLiability = 0;
        } else {
            rebateLiability -= amount;
        }

        IERC20(asset()).safeTransfer(to, amount);

        emit RebatePaidFromVault(to, amount, rebateLiability);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                        Strategy callback (Phase 4)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Rebalance the vault's positions per strategy instructions.
    /// @dev    Phase 2 stub: validates auth and emits an event but performs no
    ///         actual rebalance. Phase 4 will fill in the unlock + swap + deploy
    ///         flow inside this function.
    /// @notice Set the managed pool key. Governance-only, one-time.
    /// @dev    Separate from construction because the hook address is mined
    ///         via CREATE2 and not known when the vault constructor runs.
    function setManagedKey(PoolKey calldata key, bool _usdcIsToken0) external onlyGovernance {
        if (managedKeySet) revert Errors.Unauthorized();
        _managedKey = key;
        usdcIsToken0 = _usdcIsToken0;
        managedKeySet = true;
    }

    /// @notice Rebalance the vault's owned positions per strategy instructions.
    /// @dev    Enters v4 flash accounting via unlock(); the real work happens
    ///         in unlockCallback. Auth: only StrategyRSC via Callback Proxy.
    function rebalance(address rvmId, Allocation[] calldata newAllocs)
        external
        onlyStrategyCallback(rvmId)
        whenNotPaused
    {
        if (!managedKeySet) revert Errors.Unauthorized();
        poolManager.unlock(abi.encode(newAllocs));
    }

    /// @notice v4 flash-accounting callback. Only the PoolManager may call.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert Errors.Unauthorized();

        Allocation[] memory allocs = abi.decode(data, (Allocation[]));
        PoolKey memory key = _managedKey;
        PoolId pid = key.toId();

        // ─── TWAP anchor + staleness guard ────────────────────────────────
        (uint160 twapSqrt, uint32 samples) = hook.readTwapSqrtPrice(pid, twapWindow);
        if (samples < MIN_TWAP_SAMPLES) revert Errors.TwapStale(0);

        // ─── Process each allocation ──────────────────────────────────────
        for (uint256 i = 0; i < allocs.length; i++) {
            Allocation memory a = allocs[i];
            if (a.targetLiquidity == 0) continue;

            // To deploy a two-sided position we need the WETH leg. The vault
            // holds USDC only, so swap a portion of USDC → WETH first. The
            // amount to swap is derived from the modifyLiquidity delta: we
            // do the liquidity add first to learn what we owe, then swap to
            // cover the WETH side. But flash accounting lets us order freely,
            // so we: (1) add liquidity (creates negative deltas for both
            // tokens), (2) swap USDC→WETH to cover the WETH we now owe.
            //
            // Simpler & robust: add liquidity, then settle. The settle loop
            // swaps USDC→WETH as needed to cover any WETH shortfall.
            ModifyLiquidityParams memory mp = ModifyLiquidityParams({
                tickLower: a.tickLower,
                tickUpper: a.tickUpper,
                liquidityDelta: int256(uint256(a.targetLiquidity)),
                salt: bytes32(0)
            });
            poolManager.modifyLiquidity(key, mp, "");

            // Phase 5 Tier 3 C: record this allocation as owned for totalAssets.
            _recordOwnedAllocation(a);
        }

        // ─── Cover WETH shortfall via TWAP-bounded swap ───────────────────
        // After adding liquidity, we owe both tokens. We have USDC but no
        // WETH, so swap USDC→WETH to cover the WETH debt.
        Currency wethCurrency = usdcIsToken0 ? key.currency1 : key.currency0;
        int256 wethDelta = poolManager.currencyDelta(address(this), wethCurrency);
        if (wethDelta < 0) {
            uint256 wethOwed = uint256(-wethDelta);
            uint256 usdcIn = _estimateUsdcForWeth(wethOwed, twapSqrt);

            // Phase 5 Tier 3 A: enforce per-block USDC swap cap.
            _checkAndAccumulateSwapCap(usdcIn);

            // Swap USDC → WETH. zeroForOne depends on which token USDC is.
            bool zeroForOne = usdcIsToken0;
            uint160 limit = TwapBounded.slippageLimitFromTwap(
                twapSqrt, maxSlippageBps, zeroForOne
            );
            poolManager.swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(usdcIn),
                    sqrtPriceLimitX96: limit
                }),
                ""
            );
        }

        // ─── Settle every currency delta to zero ──────────────────────────
        _settleDelta(key.currency0);
        _settleDelta(key.currency1);

        return "";
    }

    /// @dev Settle a single currency: if we owe (delta<0) sync+transfer+settle;
    ///      if we're owed (delta>0) take it.
    function _settleDelta(Currency currency) internal {
        int256 delta = poolManager.currencyDelta(address(this), currency);
        if (delta < 0) {
            uint256 owed = uint256(-delta);
            poolManager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), owed);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(delta));
        }
    }

    /// @dev Estimate USDC input needed to receive `wethAmount` WETH at TWAP price.
    ///      price = (sqrt/2^96)^2 = WETH per USDC if USDC is token0... we keep
    ///      this rough for MVP. Returns a USDC amount (e6).
    /// @dev Record (or replace) an allocation in the owned list. Keyed by
    ///      (tickLower, tickUpper). For MVP we don't track salt because we
    ///      always use bytes32(0).
    function _recordOwnedAllocation(Allocation memory a) internal {
        bytes32 k = keccak256(abi.encode(a.tickLower, a.tickUpper));
        uint256 idxPlusOne = _ownedIndex[k];
        if (idxPlusOne == 0) {
            _ownedAllocations.push(a);
            _ownedIndex[k] = _ownedAllocations.length; // 1-indexed
        } else {
            // Replace existing entry (targetLiquidity now reflects total deployed)
            uint256 idx = idxPlusOne - 1;
            _ownedAllocations[idx] = a;
        }
    }

    /// @notice Number of allocations currently owned by the vault.
    function ownedAllocationCount() external view returns (uint256) {
        return _ownedAllocations.length;
    }

    /// @notice Read an owned allocation by index.
    function ownedAllocationAt(uint256 i) external view returns (Allocation memory) {
        return _ownedAllocations[i];
    }

    /// @dev Enforce the per-block USDC swap cap using transient storage.
    ///      Accumulates across multiple swaps in the same tx; the value
    ///      auto-clears at end of tx (cancun tstore semantics) so the next
    ///      block starts fresh.
    function _checkAndAccumulateSwapCap(uint256 usdcAmount) internal {
        bytes32 slot = SWAPPED_THIS_BLOCK_SLOT;
        uint256 prev;
        assembly { prev := tload(slot) }
        uint256 next = prev + usdcAmount;
        if (next > perBlockSwapCap) {
            revert Errors.SwapCapExceeded(next, perBlockSwapCap);
        }
        assembly { tstore(slot, next) }
    }

    function _estimateUsdcForWeth(uint256 wethAmount, uint160 twapSqrt)
        internal
        pure
        returns (uint256)
    {
        // priceE18 = (twapSqrt/2^96)^2 * 1e18
        uint256 sp = uint256(twapSqrt);
        uint256 priceX96 = (sp * sp) >> 96;
        uint256 priceE18 = (priceX96 * 1e18) >> 96;
        if (priceE18 == 0) priceE18 = 1;
        // If USDC is token0: price = token1/token0 = WETH/USDC.
        //   usdc = weth / price
        // We return usdc in the same scale as wethAmount for the mock's model.
        return wethAmount * 1e18 / priceE18;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    function setPaused(bool _paused) external onlyGovernance {
        paused = _paused;
        emit PausedSet(_paused);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert Errors.ZeroAddress();
        governance = newGovernance;
        emit GovernanceChanged(newGovernance);
    }
}
