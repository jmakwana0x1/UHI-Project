// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IVaultProxy} from "../interfaces/IVaultProxy.sol";
import {INettingRegistry} from "../interfaces/INettingRegistry.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title VaultProxy
/// @notice Thin per-remote-chain contract holding a USDC float so the
///         NettingRegistry can pay out rebates locally without bridging
///         on every claim.
/// @dev Phase 0 stub.
contract VaultProxy is IVaultProxy {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;
    INettingRegistry public immutable nettingRegistry;
    address public immutable callbackProxy;
    address public immutable authorizedStrategyRvmId;

    uint256 public floatTarget;
    address public governance;

    constructor(
        IERC20 _usdc,
        INettingRegistry _nettingRegistry,
        address _callbackProxy,
        address _authorizedStrategyRvmId
    ) {
        usdc = _usdc;
        nettingRegistry = _nettingRegistry;
        callbackProxy = _callbackProxy;
        authorizedStrategyRvmId = _authorizedStrategyRvmId;
        governance = msg.sender;
    }

    // ─── IRebatePayer ───────────────────────────────────────────────────────

    function payRebate(address /*to*/, uint256 /*amount*/) external override {
        if (msg.sender != address(nettingRegistry)) revert Errors.NettingRegistryOnly();
        // stub
    }

    // ─── IVaultProxy (strategy callbacks) ───────────────────────────────────

    function refill(address rvmId, uint256 /*amount*/) external override {
        if (msg.sender != callbackProxy) revert Errors.StrategyCallbackOnly();
        if (rvmId != authorizedStrategyRvmId) revert Errors.StrategyCallbackOnly();
        // stub
    }

    function setFloatTarget(address rvmId, uint256 newTarget) external override {
        if (msg.sender != callbackProxy) revert Errors.StrategyCallbackOnly();
        if (rvmId != authorizedStrategyRvmId) revert Errors.StrategyCallbackOnly();
        floatTarget = newTarget;
    }
}
