// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {ICrossHedgeVault} from "../interfaces/ICrossHedgeVault.sol";
import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {Errors} from "../libraries/Errors.sol";

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
contract CrossHedgeVault is ERC4626, ICrossHedgeVault {
    using SafeERC20 for IERC20;

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

    /// @notice Total USDC the vault accounts for, net of pending rebate liability.
    /// @dev    Phase 2: returns USDC balance - rebateLiability.
    ///         Phase 4: will additionally include ETH side (via TWAP) and
    ///         accrued pool fees on owned positions.
    function totalAssets() public view override returns (uint256) {
        uint256 bal = IERC20(asset()).balanceOf(address(this));
        if (rebateLiability >= bal) return 0;
        return bal - rebateLiability;
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
    function rebalance(address rvmId, Allocation[] calldata /*newAllocs*/)
        external
        onlyStrategyCallback(rvmId)
        whenNotPaused
    {
        // Phase 4: implement the unlock + swap + deploy flow
        // For now this is a no-op stub so the function exists at its right
        // signature and access control works end-to-end.
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
