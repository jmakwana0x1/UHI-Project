// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {MatchingRSC} from "../src/reactive/MatchingRSC.sol";

contract DebugMatchingRSCDeploy is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(pk);

        uint256[] memory cids = new uint256[](2);
        cids[0] = 1301;
        cids[1] = 84532;

        address[] memory regs = new address[](2);
        regs[0] = 0xf143E0B7ba83bfcE76e0Ec859F7d90DF40FadB25;
        regs[1] = 0xf143E0B7ba83bfcE76e0Ec859F7d90DF40FadB25;

        new MatchingRSC(cids, regs, 60, 1500000, 30, 200);

        vm.stopBroadcast();
    }
}
