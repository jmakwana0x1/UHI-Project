// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultProxy} from "../interfaces/IVaultProxy.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {Errors} from "../libraries/Errors.sol";
import {Constants} from "../libraries/Constants.sol";

/// @title VaultProxy
/// @notice Thin per-remote-chain contract holding a USDC float so the local
///         NettingRegistry can pay rebates without bridging on every claim.
///
/// @dev    Funding model (MVP)
///           The actual USDC arrives via external mechanisms (manual seeding
///           for the hookathon demo; CCTP/bridge integration for v3+). The
///           `refill` function is informational — it acknowledges receipt and
///           updates accounting state, but does NOT itself move tokens.
///
///         Auth model
///           - `payRebate` is callable only by the local NettingRegistry.
///           - `refill` and `setFloatTarget` are callable only by StrategyRSC
///             via the Reactive Callback Proxy.
///           - `sweep` is governance-only (emergency).
contract VaultProxy is IVaultProxy {
    using SafeERC20 for IERC20;

    // ─── Immutables ─────────────────────────────────────────────────────────

    IERC20 public immutable usdc;
    INettingRegistry public immutable nettingRegistry;
    address public immutable callbackProxy;
    address public immutable authorizedStrategyRvmId;

    // ─── State ──────────────────────────────────────────────────────────────

    uint256 public floatTarget;
    uint256 public totalRebatesPaid;
    address public governance;

    // ─── Events ─────────────────────────────────────────────────────────────

    event RebatePaidLocal(address indexed to, uint256 amount, uint256 newBalance);
    event FloatLow(uint256 balance, uint256 target);
    event Refilled(uint256 amount, uint256 newBalance);
    event FloatTargetUpdated(uint256 oldTarget, uint256 newTarget);
    event Swept(address indexed to, uint256 amount);
    event GovernanceChanged(address indexed newGovernance);

    // ─── Modifiers ──────────────────────────────────────────────────────────

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

    // ─── Constructor ────────────────────────────────────────────────────────

    constructor(
        IERC20 _usdc,
        INettingRegistry _nettingRegistry,
        address _callbackProxy,
        address _authorizedStrategyRvmId,
        uint256 _initialFloatTarget
    ) {
        if (address(_usdc) == address(0)) revert Errors.ZeroAddress();
        if (address(_nettingRegistry) == address(0)) revert Errors.ZeroAddress();
        if (_callbackProxy == address(0)) revert Errors.ZeroAddress();
        if (_authorizedStrategyRvmId == address(0)) revert Errors.ZeroAddress();

        usdc = _usdc;
        nettingRegistry = _nettingRegistry;
        callbackProxy = _callbackProxy;
        authorizedStrategyRvmId = _authorizedStrategyRvmId;
        floatTarget = _initialFloatTarget;
        governance = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          IRebatePayer surface
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Pay a rebate locally. Only callable by the local NettingRegistry.
    function payRebate(address to, uint256 amount) external onlyNettingRegistry {
        if (to == address(0)) revert Errors.ZeroAddress();

        uint256 bal = usdc.balanceOf(address(this));
        if (amount > bal) {
            revert Errors.InsufficientFloat(amount, bal);
        }

        // Effects first: increment totals before external call.
        totalRebatesPaid += amount;

        // Interaction
        usdc.safeTransfer(to, amount);

        uint256 newBal = bal - amount;
        emit RebatePaidLocal(to, amount, newBal);

        // Signal if balance is below half the target — StrategyRSC subscribes
        // to this event and triggers a refill.
        if (floatTarget > 0 && newBal < floatTarget / 2) {
            emit FloatLow(newBal, floatTarget);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                       Strategy callback surface
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Acknowledge a refill (informational; tokens arrive separately).
    /// @dev The caller (StrategyRSC) signals that `amount` USDC has been or is
    ///      about to be deposited to this contract. For MVP we just emit an
    ///      event; in v3+ this is paired with a CCTP/bridge mint.
    function refill(address rvmId, uint256 amount) external onlyStrategyCallback(rvmId) {
        uint256 newBal = usdc.balanceOf(address(this));
        emit Refilled(amount, newBal);
    }

    /// @notice Update the float-target level.
    function setFloatTarget(address rvmId, uint256 newTarget)
        external
        onlyStrategyCallback(rvmId)
    {
        uint256 old = floatTarget;
        floatTarget = newTarget;
        emit FloatTargetUpdated(old, newTarget);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Governance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emergency sweep of remaining USDC. Governance only.
    /// @dev    For MVP this exists in case the proxy is deprecated or the
    ///         protocol needs to migrate to a new bridge.
    function sweep(address to) external onlyGovernance {
        if (to == address(0)) revert Errors.ZeroAddress();
        uint256 bal = usdc.balanceOf(address(this));
        if (bal > 0) {
            usdc.safeTransfer(to, bal);
        }
        emit Swept(to, bal);
    }

    function transferGovernance(address newGovernance) external onlyGovernance {
        if (newGovernance == address(0)) revert Errors.ZeroAddress();
        governance = newGovernance;
        emit GovernanceChanged(newGovernance);
    }
}
