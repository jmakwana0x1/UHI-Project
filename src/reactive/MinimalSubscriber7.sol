// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {AbstractReactive} from "reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {ReactiveConstants} from "./modules/ReactiveConstants.sol";

contract MinimalSubscriber7 is AbstractReactive {
    uint256 internal constant ANY = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    // ← Take constructor args like MatchingRSC does
    constructor(uint256[] memory subscribeChainIds) payable {
        if (!vm) {
            // Loop pattern from MatchingRSC
            for (uint256 i = 0; i < subscribeChainIds.length; i++) {
                uint256 cid = subscribeChainIds[i];
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_LP_POSITION_OPENED, ANY, ANY, ANY);
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_LP_POSITION_CLOSED, ANY, ANY, ANY);
                service.subscribe(cid, address(0), ReactiveConstants.TOPIC_PRICE_SNAPSHOT, ANY, ANY, ANY);
            }
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
