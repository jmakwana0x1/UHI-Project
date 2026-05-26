// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @title PositionIdLib
/// @notice Derives a deterministic position identifier mirroring v4's internal
///         position key but additionally including the poolId so the hook can
///         disambiguate positions across pools it services.
/// @dev MVP services a single pool; the poolId inclusion is for v3+ multi-pool
///      operation.
library PositionIdLib {
    function compute(
        PoolId poolId,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, owner, tickLower, tickUpper, salt));
    }
}
