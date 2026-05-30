// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISystemContract} from "reactive-lib/interfaces/ISystemContract.sol";

/// @title MockSystemContract
/// @notice Test mock that records subscribe/unsubscribe calls. We etch this
///         to address 0x...fffFfF in test setUp so that AbstractReactive's
///         constructor finds code there and runs in "RN context", letting
///         subscribe() calls succeed.
contract MockSystemContract is ISystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddr;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] public subscriptions;

    function subscribe(
        uint256 chain_id,
        address _contract,
        uint256 topic_0,
        uint256 topic_1,
        uint256 topic_2,
        uint256 topic_3
    ) external {
        subscriptions.push(Subscription({
            subscriber: msg.sender,
            chainId: chain_id,
            contractAddr: _contract,
            topic0: topic_0,
            topic1: topic_1,
            topic2: topic_2,
            topic3: topic_3
        }));
    }

    function unsubscribe(
        uint256 /*chain_id*/,
        address /*_contract*/,
        uint256 /*topic_0*/,
        uint256 /*topic_1*/,
        uint256 /*topic_2*/,
        uint256 /*topic_3*/
    ) external pure {
        // no-op for tests
    }

    function subscriptionCount() external view returns (uint256) {
        return subscriptions.length;
    }

    function getSubscription(uint256 i) external view returns (Subscription memory) {
        return subscriptions[i];
    }

    function hasSubscription(
        address subscriber,
        uint256 chainId,
        uint256 topic0
    ) external view returns (bool) {
        for (uint256 i = 0; i < subscriptions.length; i++) {
            Subscription memory s = subscriptions[i];
            if (s.subscriber == subscriber && s.chainId == chainId && s.topic0 == topic0) {
                return true;
            }
        }
        return false;
    }

    // ─── IPayable surface (no-ops for tests) ────────────────────────────

    function debt(address /*_recipient*/) external pure returns (uint256) {
        return 0;
    }

    receive() external payable {}
}
