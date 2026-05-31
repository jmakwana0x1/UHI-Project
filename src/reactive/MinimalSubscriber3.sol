// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";

contract MinimalSubscriber3 is AbstractReactive {
    uint256 internal constant ANY = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant TOPIC_LP_OPENED = 0xb5ffb5583158989440a397c85aa7c2f9b14abe3e6ae7ffe0e526e3b3cc5a7776;
    // PriceSnapshot(bytes32,uint160,uint64) - from our hook
    uint256 internal constant TOPIC_PRICE = 0x17a7f8aa7479f89ed5b85636e7e276c125313dae1645a8c6ebb28acaf297b83a;
    // LPPositionClosed(bytes32,bytes32,address) - from our hook
    uint256 internal constant TOPIC_LP_CLOSED = 0xebf120e699d41bdb02cac4cee62fd089dbb47c874b269a4d04074c12dc9dc950;

    constructor() payable {
        if (!vm) {
            // 6 subscribes: 3 topics × 2 chains (mirrors MatchingRSC minus cron)
            service.subscribe(1301, address(0), TOPIC_LP_OPENED, ANY, ANY, ANY);
            service.subscribe(1301, address(0), TOPIC_LP_CLOSED, ANY, ANY, ANY);
            service.subscribe(1301, address(0), TOPIC_PRICE, ANY, ANY, ANY);
            service.subscribe(84532, address(0), TOPIC_LP_OPENED, ANY, ANY, ANY);
            service.subscribe(84532, address(0), TOPIC_LP_CLOSED, ANY, ANY, ANY);
            service.subscribe(84532, address(0), TOPIC_PRICE, ANY, ANY, ANY);
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
