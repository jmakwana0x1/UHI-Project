// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ReactiveConstants} from "./modules/ReactiveConstants.sol";

contract MinimalSubscriber6 is AbstractReactive {
    uint256 internal constant ANY = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    constructor() payable {
        if (!vm) {
            // 6 origin-chain subscribes (using ReactiveConstants topics)
            service.subscribe(1301, address(0), ReactiveConstants.TOPIC_LP_POSITION_OPENED, ANY, ANY, ANY);
            service.subscribe(1301, address(0), ReactiveConstants.TOPIC_LP_POSITION_CLOSED, ANY, ANY, ANY);
            service.subscribe(1301, address(0), ReactiveConstants.TOPIC_PRICE_SNAPSHOT, ANY, ANY, ANY);
            service.subscribe(84532, address(0), ReactiveConstants.TOPIC_LP_POSITION_OPENED, ANY, ANY, ANY);
            service.subscribe(84532, address(0), ReactiveConstants.TOPIC_LP_POSITION_CLOSED, ANY, ANY, ANY);
            service.subscribe(84532, address(0), ReactiveConstants.TOPIC_PRICE_SNAPSHOT, ANY, ANY, ANY);
            // CRON: using the EXACT constants MatchingRSC uses
            service.subscribe(
                ReactiveConstants.LASNA_CHAIN_ID,
                ReactiveConstants.SYSTEM_CONTRACT,
                ReactiveConstants.CRON_TOPIC_FAST_PLACEHOLDER,
                ANY, ANY, ANY
            );
        }
    }

    function react(IReactive.LogRecord calldata) external pure {}
}
