// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MatchScore
/// @notice Pure scoring function for greedy 1:1 LP matching.
/// @dev Phase 0 stub. Full implementations land in Phase 3.
library MatchScore {
    function score(
        int256 deltaA,
        int256 deltaB,
        uint128 gammaA,
        uint128 gammaB,
        uint8 horizonA,
        uint8 horizonB,
        uint16 correlationBps
    ) internal pure returns (uint128 matchScore_, uint128 matchableNotional) {
        deltaA; deltaB; gammaA; gammaB; horizonA; horizonB; correlationBps;
        return (0, 0);
    }
}
