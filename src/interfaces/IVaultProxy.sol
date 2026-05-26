// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IRebatePayer} from "./IRebatePayer.sol";

interface IVaultProxy is IRebatePayer {
    /// @notice Refill the local USDC float. Strategy callback only.
    function refill(address rvmId, uint256 amount) external;

    /// @notice Update the target float level. Strategy callback only.
    function setFloatTarget(address rvmId, uint256 newTarget) external;
}
