// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRebatePayer} from "./IRebatePayer.sol";

interface ICrossHedgeVault is IRebatePayer {
    struct Allocation {
        int24 tickLower;
        int24 tickUpper;
        uint128 targetLiquidity;
        bool keepIfExists;
    }

    /// @notice Rebalance the vault's owned positions per the supplied allocations.
    /// @dev Callable only by StrategyRSC via Callback Proxy.
    function rebalance(address rvmId, Allocation[] calldata newAllocs) external;

    /// @notice Push accumulated premium balance from the hook into the vault.
    function depositPremium(uint256 amount) external;
}
