// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {MatchingRSC} from "../src/reactive/MatchingRSC.sol";
import {StrategyRSC} from "../src/reactive/StrategyRSC.sol";

/// @notice Deploys CrossHedge's reactive components on Reactive Lasna.
///
/// Deploys (in order, nonces matter):
///   nonce 0: MatchingRSC          (subscribes to Unichain Sepolia + Base Sepolia)
///   nonce 1: StrategyRSC_unichain (homeChainId=1301)
///   nonce 2: StrategyRSC_base     (homeChainId=84532)
///
/// PREREQUISITE: deployer must be fresh on Lasna (nonce 0) and the predicted
/// origin vault addresses must match what DeployOrigin will produce. Run
/// PredictAddresses first and verify the JSON.
///
/// Pass funding amount via --value when running forge script.
///
/// Usage:
///     forge script script/DeployReactive.s.sol \
///         --rpc-url https://lasna-rpc.rnk.dev/ \
///         --private-key $DEPLOYER_PRIVATE_KEY \
///         --broadcast
contract DeployReactive is Script {
    // Cron + callback config (matches what the tests use)
    uint64 constant MIN_CRON_INTERVAL_SECONDS = 60;
    uint64 constant CALLBACK_GAS_LIMIT = 1_500_000;
    uint16 constant ALPHA_BPS = 200;   // EMA alpha for vol estimation
    uint16 constant F_INT_BPS = 30;    // fInt for MatchingRSC

    // REACT funding per RSC at construction (you can override via --value if
    // you split it across calls; this is a sensible default for a demo).
    uint256 constant RSC_FUNDING_REACT = 1 ether;  // 1 REACT each

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        require(block.chainid == 5318007, "must run on Lasna (chainId 5318007)");
        require(vm.getNonce(deployer) == 0, "deployer must be fresh on Lasna (nonce=0)");

        // ─── Load predicted origin addresses ───────────────────────────
        string memory preds = vm.readFile("deployments/predictions.json");
        address predictedRegistry  = vm.parseJsonAddress(preds, ".originTemplate.registry");
        address predictedVault     = vm.parseJsonAddress(preds, ".originTemplate.vault");
        address expectedMatching   = vm.parseJsonAddress(preds, ".lasna.matchingRsc");
        address expectedStratUni   = vm.parseJsonAddress(preds, ".lasna.strategyRscUnichain");
        address expectedStratBase  = vm.parseJsonAddress(preds, ".lasna.strategyRscBase");

        console2.log("=== DeployReactive ===");
        console2.log("Deployer:", deployer);
        console2.log("Predicted MatchingRSC:        ", expectedMatching);
        console2.log("Predicted StrategyRSC_unichain:", expectedStratUni);
        console2.log("Predicted StrategyRSC_base:    ", expectedStratBase);
        console2.log("Predicted origin registry (both): ", predictedRegistry);
        console2.log("Predicted origin vault (both):    ", predictedVault);

        vm.startBroadcast(deployerPk);

        // ─── nonce 0: MatchingRSC ──────────────────────────────────────
        uint256[] memory subscribeChainIds = new uint256[](2);
        subscribeChainIds[0] = 1301;   // Unichain Sepolia
        subscribeChainIds[1] = 84532;  // Base Sepolia

        address[] memory chainRegistries = new address[](2);
        chainRegistries[0] = predictedRegistry;  // same address on both origins
        chainRegistries[1] = predictedRegistry;

        MatchingRSC matchingRsc = new MatchingRSC(
            subscribeChainIds,
            chainRegistries,
            MIN_CRON_INTERVAL_SECONDS,
            CALLBACK_GAS_LIMIT,
            F_INT_BPS,
            ALPHA_BPS
        );
        require(
            address(matchingRsc) == expectedMatching,
            "MatchingRSC address mismatch - deployer nonce changed?"
        );

        // ─── nonce 1: StrategyRSC for Unichain Sepolia ─────────────────
        uint256[] memory uniSubs = new uint256[](1);
        uniSubs[0] = 1301;
        StrategyRSC stratUni = new StrategyRSC(
            1301,                       // homeChainId
            predictedVault,             // vaultAddress (same predicted addr on both origins)
            MIN_CRON_INTERVAL_SECONDS,
            CALLBACK_GAS_LIMIT,
            ALPHA_BPS,
            uniSubs
        );
        require(
            address(stratUni) == expectedStratUni,
            "StrategyRSC_unichain address mismatch"
        );

        // ─── nonce 2: StrategyRSC for Base Sepolia ─────────────────────
        uint256[] memory baseSubs = new uint256[](1);
        baseSubs[0] = 84532;
        StrategyRSC stratBase = new StrategyRSC(
            84532,
            predictedVault,
            MIN_CRON_INTERVAL_SECONDS,
            CALLBACK_GAS_LIMIT,
            ALPHA_BPS,
            baseSubs
        );
        require(
            address(stratBase) == expectedStratBase,
            "StrategyRSC_base address mismatch"
        );

        vm.stopBroadcast();

        // ─── Write actual deployment record ────────────────────────────
        string memory out = "lasnaDeployment";
        vm.serializeUint(out, "chainId", 5318007);
        vm.serializeAddress(out, "matchingRsc", address(matchingRsc));
        vm.serializeAddress(out, "strategyRscUnichain", address(stratUni));
        vm.serializeAddress(out, "strategyRscBase", address(stratBase));
        vm.serializeUint(out, "deployedAtTimestamp", block.timestamp);
        string memory finalJson = vm.serializeUint(out, "deployedAtBlock", block.number);
        vm.writeJson(finalJson, "deployments/lasna.json");

        console2.log("");
        console2.log("=== Deployed ===");
        console2.log("MatchingRSC:        ", address(matchingRsc));
        console2.log("StrategyRSC_unichain:", address(stratUni));
        console2.log("StrategyRSC_base:    ", address(stratBase));
        console2.log("Wrote deployments/lasna.json");
        console2.log("");
        console2.log("");
        console2.log("NEXT: fund each RSC with REACT for callback gas. Run:");
        console2.log("  cast send <RSC_ADDR> --value 1ether --rpc-url $LASNA_RPC --private-key $DEPLOYER_PRIVATE_KEY");
        console2.log("for each of the three RSCs above.");
    }
}
