// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Predicts all deployment addresses for CrossHedge across Lasna,
///         Unichain Sepolia, and Base Sepolia. Pure computation — no chain
///         interaction needed, just deployer address + assumed nonces.
///
///         Run once and save the output JSON. Subsequent deploy scripts
///         reference these predictions.
///
/// Usage:
///     forge script script/PredictAddresses.s.sol \
///         --sig "run(address)" 0xYourDeployer
contract PredictAddresses is Script {
    function run(address deployer) external {
        // ─── Lasna deployment order ────────────────────────────────────
        // nonce 0: MatchingRSC (one shared instance, subscribes to both origins)
        // nonce 1: StrategyRSC_unichain (homeChainId=1301)
        // nonce 2: StrategyRSC_base     (homeChainId=84532)
        address matchingRsc        = vm.computeCreateAddress(deployer, 0);
        address strategyRscUnichain = vm.computeCreateAddress(deployer, 1);
        address strategyRscBase     = vm.computeCreateAddress(deployer, 2);

        // ─── Origin chain deployment order (identical on every origin) ─
        // nonce 0: MockUSDC
        // nonce 1: MockWETH
        // nonce 2: NettingRegistry
        // nonce 3: CrossHedgeVault
        // nonce 4: CREATE2 hook (NOT a CREATE nonce, mined separately)
        address originUsdc     = vm.computeCreateAddress(deployer, 0);
        address originWeth     = vm.computeCreateAddress(deployer, 1);
        address originRegistry = vm.computeCreateAddress(deployer, 2);
        address originVault    = vm.computeCreateAddress(deployer, 3);

        // ─── Pretty-print + JSON output ────────────────────────────────
        console2.log("=== CrossHedge address predictions ===");
        console2.log("Deployer:", deployer);
        console2.log("");
        console2.log("Lasna (chain 5318007):");
        console2.log("  MatchingRSC          (nonce 0):", matchingRsc);
        console2.log("  StrategyRSC_unichain (nonce 1):", strategyRscUnichain);
        console2.log("  StrategyRSC_base     (nonce 2):", strategyRscBase);
        console2.log("");
        console2.log("Each origin chain (identical addresses iff deployer is fresh on both):");
        console2.log("  MockUSDC        (nonce 0):", originUsdc);
        console2.log("  MockWETH        (nonce 1):", originWeth);
        console2.log("  NettingRegistry (nonce 2):", originRegistry);
        console2.log("  CrossHedgeVault (nonce 3):", originVault);
        console2.log("  CrossHedgeHook  (CREATE2, mined per chain - see DeployOrigin)");

        // Build JSON manually since vm.serializeJson is awkward for our shape.
        // Subsequent scripts read these by exact key path.
        string memory json = "predictions";
        vm.serializeAddress(json, "deployer", deployer);

        string memory lasna = "lasna";
        vm.serializeUint(lasna, "chainId", 5318007);
        vm.serializeAddress(lasna, "matchingRsc", matchingRsc);
        vm.serializeAddress(lasna, "strategyRscUnichain", strategyRscUnichain);
        string memory lasnaJson = vm.serializeAddress(lasna, "strategyRscBase", strategyRscBase);
        vm.serializeString(json, "lasna", lasnaJson);

        string memory origin = "origin";
        vm.serializeAddress(origin, "usdc", originUsdc);
        vm.serializeAddress(origin, "weth", originWeth);
        vm.serializeAddress(origin, "registry", originRegistry);
        string memory originJson = vm.serializeAddress(origin, "vault", originVault);
        vm.serializeString(json, "originTemplate", originJson);

        // Callback proxies (from Reactive Network's docs, verified 2026-05-30)
        string memory proxies = "proxies";
        vm.serializeAddress(proxies, "unichainSepolia", 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4);
        string memory proxiesJson = vm.serializeAddress(proxies, "baseSepolia", 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6);
        string memory finalJson = vm.serializeString(json, "callbackProxies", proxiesJson);

        vm.writeJson(finalJson, "deployments/predictions.json");
        console2.log("");
        console2.log("Wrote deployments/predictions.json");
    }
}
