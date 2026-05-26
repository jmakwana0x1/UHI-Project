// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IRebatePayer
/// @notice Common surface that both the home-chain Vault and the remote-chain
///         VaultProxy implement so the NettingRegistry can pay rebates without
///         caring which kind of contract sits behind the address.
interface IRebatePayer {
    /// @notice Pay a rebate amount in USDC to the specified recipient.
    /// @dev MUST revert if caller is not the local NettingRegistry.
    function payRebate(address to, uint256 amount) external;
}
