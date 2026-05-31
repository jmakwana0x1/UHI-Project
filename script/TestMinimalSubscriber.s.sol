// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MinimalSubscriber} from "../src/reactive/MinimalSubscriber.sol";

contract TestMinimalSubscriber is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);

        require(block.chainid == 5318007, "must run on Lasna");
        console2.log("Deployer:", deployer);
        console2.log("Deployer balance (lREACT):", deployer.balance / 1e18);

        vm.startBroadcast(pk);

        // Deploy WITH value in the same tx as construction.
        // The canonical demo (BasicDemoReactiveContract) does this — subscribe()
        // is called from constructor and the system contract debits msg.value.
        MinimalSubscriber sub = new MinimalSubscriber{value: 0.5 ether}();
        console2.log("Deployed at:", address(sub));

        vm.stopBroadcast();
        console2.log("Subscribe succeeded!");
    }
}
