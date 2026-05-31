// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract MinimalSubscriber2 is AbstractReactive {
    uint256 internal constant ANY = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant TOPIC_LP = 0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776;

    constructor() payable {
        if (!vm) {
            // Subscribe to LP_OPEN on Unichain Sepolia
            service.subscribe(1301, address(0), TOPIC_LP, ANY, ANY, ANY);
            // Subscribe to LP_OPEN on Base Sepolia
            service.subscribe(84532, address(0), TOPIC_LP, ANY, ANY, ANY);
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
