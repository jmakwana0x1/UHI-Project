// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReactiveConstants} from "../../../src/reactive/modules/ReactiveConstants.sol";
import {MockSystemContract} from "../../utils/reactive/MockSystemContract.sol";
import {StrategyRSC} from "../../../src/reactive/StrategyRSC.sol";

contract StrategyRSCMinHarness is StrategyRSC {
    constructor(uint256 hc, address v, uint64 mci, uint64 cg, uint16 a, uint256[] memory chains)
        StrategyRSC(hc, v, mci, cg, a, chains) {}
    function recheckVm() external { detectVm(); }
}

contract StrategyDiag2Test is Test {
    function test_diag_FullFlow() public {
        // Step 1: etch sys
        MockSystemContract sys = new MockSystemContract();
        vm.etch(ReactiveConstants.SYSTEM_CONTRACT, address(sys).code);

        // Step 2: read code size at SERVICE_ADDR BEFORE deploying RSC
        uint256 sizeBefore;
        address target = ReactiveConstants.SYSTEM_CONTRACT;
        assembly { sizeBefore := extcodesize(target) }
        emit log_named_uint("code size at SERVICE_ADDR before RSC deploy", sizeBefore);

        // Step 3: try subscriptionCount before RSC deploy
        try MockSystemContract(payable(target)).subscriptionCount() returns (uint256 n) {
            emit log_named_uint("subCount before RSC deploy", n);
        } catch {
            emit log_string("subCount before RSC deploy REVERTED");
        }

        // Step 4: deploy RSC
        uint256[] memory chains = new uint256[](2);
        chains[0] = 1301;
        chains[1] = 84532;
        StrategyRSCMinHarness rsc = new StrategyRSCMinHarness(1301, address(0xdead), 1 hours, 2_000_000, 500, chains);

        // Step 5: check code size at SERVICE_ADDR AFTER deploying RSC
        uint256 sizeAfter;
        assembly { sizeAfter := extcodesize(target) }
        emit log_named_uint("code size at SERVICE_ADDR after RSC deploy", sizeAfter);

        // Step 6: try subscriptionCount after RSC deploy
        try MockSystemContract(payable(target)).subscriptionCount() returns (uint256 n) {
            emit log_named_uint("subCount after RSC deploy", n);
        } catch Error(string memory reason) {
            emit log_named_string("subCount after RSC deploy REVERTED with", reason);
        } catch (bytes memory data) {
            emit log_named_bytes("subCount after RSC deploy REVERTED bytes", data);
        }

        // Step 7: also check if vm flag is what we expect
        emit log_named_string("rsc.isInVm()", rsc.isInVm() ? "true" : "false");

        rsc; // suppress unused
    }
}
