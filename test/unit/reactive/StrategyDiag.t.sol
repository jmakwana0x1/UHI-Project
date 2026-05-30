// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReactiveConstants} from "../../../src/reactive/modules/ReactiveConstants.sol";
import {MockSystemContract} from "../../utils/reactive/MockSystemContract.sol";

contract StrategyDiagTest is Test {
    function test_diag_EtchPath() public {
        MockSystemContract sys = new MockSystemContract();

        // Print code size before etch
        uint256 codeSizeBefore;
        address target = ReactiveConstants.SYSTEM_CONTRACT;
        assembly { codeSizeBefore := extcodesize(target) }
        emit log_named_uint("code size before etch", codeSizeBefore);

        // Etch
        vm.etch(target, address(sys).code);

        uint256 codeSizeAfter;
        assembly { codeSizeAfter := extcodesize(target) }
        emit log_named_uint("code size after etch", codeSizeAfter);

        // Try to call subscriptionCount() on etched address
        MockSystemContract atTarget = MockSystemContract(payable(target));
        try atTarget.subscriptionCount() returns (uint256 n) {
            emit log_named_uint("subscriptionCount call succeeded with", n);
        } catch Error(string memory reason) {
            emit log_named_string("subscriptionCount reverted with reason", reason);
        } catch (bytes memory data) {
            emit log_named_bytes("subscriptionCount reverted with bytes", data);
        }

        // Also try calling subscribe directly to populate state
        try atTarget.subscribe(1, address(0), 1, 1, 1, 1) {
            emit log_string("subscribe call succeeded");
        } catch {
            emit log_string("subscribe call reverted");
        }

        try atTarget.subscriptionCount() returns (uint256 n) {
            emit log_named_uint("subscriptionCount after one subscribe", n);
        } catch {
            emit log_string("second subscriptionCount call reverted");
        }
    }
}
