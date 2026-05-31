// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract MinimalSubscriber4 is AbstractReactive {
    uint256 internal constant ANY = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    // Cron10 hash from Reactive's demo
    uint256 internal constant CRON_10 = 0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687;

    constructor() payable {
        if (!vm) {
            // EXACT pattern from BasicCronContract demo
            service.subscribe(
                block.chainid,
                address(service),
                CRON_10,
                ANY, ANY, ANY
            );
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
