// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {ICrossHedgeVault} from "../interfaces/ICrossHedgeVault.sol";
import {ICrossHedgeHook} from "../interfaces/ICrossHedgeHook.sol";
import {Constants} from "../libraries/Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title CrossHedgeVault
/// @notice ERC-4626 USDC vault that acts as the structural counterparty.
///         Swaps USDC↔ETH via TWAP-bounded path inside its own pool, deploys
///         above-range concentrated positions, receives premium and rebate
///         accruals.
/// @dev Phase 0 stub.
contract CrossHedgeVault is ERC4626, ICrossHedgeVault {
    using SafeERC20 for IERC20;

    // ─── Immutables ─────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    ICrossHedgeHook public immutable hook;
    address public immutable callbackProxy;
    address public immutable authorizedStrategyRvmId;
    uint16 public immutable maxSlippageBps;
    uint256 public immutable perBlockSwapCap;
    uint32 public immutable twapWindow;

    // ─── Storage ────────────────────────────────────────────────────────────
    uint256 public premiumAccrued;
    uint256 public rebateLiability;
    address public governance;
    bool public paused;

    constructor(
        IERC20 _usdc,
        string memory _name,
        string memory _symbol,
        IPoolManager _poolManager,
        ICrossHedgeHook _hook,
        address _callbackProxy,
        address _authorizedStrategyRvmId,
        uint16 _maxSlippageBps,
        uint256 _perBlockSwapCap,
        uint32 _twapWindow
    ) ERC20(_name, _symbol) ERC4626(_usdc) {
        poolManager = _poolManager;
        hook = _hook;
        callbackProxy = _callbackProxy;
        authorizedStrategyRvmId = _authorizedStrategyRvmId;
        maxSlippageBps = _maxSlippageBps;
        perBlockSwapCap = _perBlockSwapCap;
        twapWindow = _twapWindow;
        governance = msg.sender;
    }

    // ─── ERC-4626 override hooks (stubs) ────────────────────────────────────

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }

    // ─── Strategy callbacks ─────────────────────────────────────────────────

    function rebalance(address rvmId, Allocation[] calldata /*newAllocs*/)
        external
        override
    {
        if (msg.sender != callbackProxy) revert Errors.StrategyCallbackOnly();
        if (rvmId != authorizedStrategyRvmId) revert Errors.StrategyCallbackOnly();
        if (paused) revert Errors.VaultPaused();
        // poolManager.unlock(...) full flow lands in Phase 4
    }

    // ─── Hook callbacks ─────────────────────────────────────────────────────

    function depositPremium(uint256 amount) external override {
        if (msg.sender != address(hook)) revert Errors.HookOnly();
        premiumAccrued += amount;
    }

    // ─── Registry callbacks ─────────────────────────────────────────────────

    function payRebate(address /*to*/, uint256 /*amount*/) external override {
        // stub — full impl: only NettingRegistry, decrement rebateLiability, transfer
    }
}
