// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IRebatePayer
/// @notice Shared surface for any contract that holds USDC to pay out rebates.
///         Implemented by:
///           - CrossHedgeVault (home chain)
///           - VaultProxy (remote chains)
interface IRebatePayer {
    /// @notice Pay a rebate amount to a recipient. Only callable by the
    ///         NettingRegistry that's wired in at construction time.
    function payRebate(address to, uint256 amount) external;

    /// @notice Credit an accrued-but-not-yet-paid rebate liability on the
    ///         payer's books. Called by the NettingRegistry when it accrues
    ///         rebate to a short LP, so the payer's solvency accounting
    ///         (e.g., totalAssets() on an ERC4626 vault) is accurate.
    function accrueLiability(uint256 amount) external;
}
