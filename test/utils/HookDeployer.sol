// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

/// @title HookDeployer
/// @notice Convenience wrapper around HookMiner for tests.
/// @dev    Caller passes the hook's bytecode + constructor args + permission flags.
///         Returns the salt and deploys via CREATE2.
library HookDeployer {
    /// @notice The canonical CREATE2 deployer used in Foundry tests.
    /// @dev    This matches the default CREATE2 deployer that ships with
    ///         forge-std (0x4e59b44847b379578588920cA78FbF26c0B4956C).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function mine(
        uint160 flags,
        bytes memory creationCode,
        bytes memory constructorArgs
    ) internal view returns (address hookAddress, bytes32 salt) {
        (hookAddress, salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            creationCode,
            constructorArgs
        );
    }
}
