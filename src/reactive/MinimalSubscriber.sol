// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract MinimalSubscriber is AbstractReactive {
    uint256 internal constant ANY_TOPIC = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant EVENT_TOPIC = 0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776;
    uint256 internal constant ORIGIN_CHAIN_ID = 1301; // Ethereum Sepolia

    constructor() payable {
        if (!vm) {
            service.subscribe(
                ORIGIN_CHAIN_ID,
                address(0),
                EVENT_TOPIC,
                ANY_TOPIC,
                ANY_TOPIC,
                ANY_TOPIC
            );
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
