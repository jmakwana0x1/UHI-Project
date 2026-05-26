// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/// @title PoolKeyLib
/// @notice Thin convenience layer over v4's PoolKey type.
library PoolKeyLib {
    using PoolIdLibrary for PoolKey;

    function toId(PoolKey memory key) internal pure returns (PoolId) {
        return key.toId();
    }
}
