// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CrossHedgeHook} from "../src/hook/CrossHedgeHook.sol";
import {NettingRegistry} from "../src/registry/NettingRegistry.sol";
import {CrossHedgeVault} from "../src/vault/CrossHedgeVault.sol";
import {ICrossHedgeHook} from "../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../src/interfaces/INettingRegistry.sol";
import {IRebatePayer} from "../src/interfaces/IRebatePayer.sol";

import {HookDeployer} from "../test/utils/HookDeployer.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";

/// @notice Deploys CrossHedge's origin-chain components.
///
/// Auto-detects chain via block.chainid:
///   1301  → Unichain Sepolia (StrategyRSC_unichain, callbackProxy_unichain)
///   84532 → Base Sepolia    (StrategyRSC_base,     callbackProxy_base)
///
/// Deploys (in nonce order):
///   nonce 0: MockUSDC
///   nonce 1: MockWETH
///   nonce 2: NettingRegistry
///   nonce 3: CrossHedgeVault
///   nonce 4: CrossHedgeHook (CREATE2)
///
/// PREREQUISITES:
///   - DEPLOYER_PRIVATE_KEY env var set
///   - deployer is fresh on the target chain (nonce 0)
///   - deployments/lasna.json exists (from DeployReactive)
///   - canonical CREATE2 deployer (0x4e59...) present on this chain
///
/// Usage (example for Unichain Sepolia):
///     DEPLOYER_PRIVATE_KEY=0x... \
///     forge script script/DeployOrigin.s.sol \
///         --rpc-url $UNICHAIN_SEPOLIA_RPC \
///         --broadcast
contract DeployOrigin is Script {
    using PoolIdLibrary for PoolKey;

    // Chain-specific real-v4 PoolManager addresses
    address constant POOL_MANAGER_UNICHAIN_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POOL_MANAGER_BASE_SEPOLIA     = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // Reactive Network callback proxies
    address constant CALLBACK_PROXY_UNICHAIN = 0x9299472A6399Fd1027ebF067571Eb3e3D7837FC4;
    address constant CALLBACK_PROXY_BASE     = 0xa6eA49Ed671B8a4dfCDd34E36b7a75Ac79B8A5a6;

    // Protocol config (matches fork-test defaults)
    uint16 constant PREMIUM_BPS         = 30;             // 0.30% premium charge
    uint16 constant MAX_SLIPPAGE_BPS    = 50;             // 0.50% TWAP-bounded slippage
    uint256 constant PER_BLOCK_SWAP_CAP = 1_000_000e6;    // 1M USDC per block
    uint32 constant TWAP_WINDOW         = 30 minutes;
    uint32 constant WATCHDOG_INTERVAL   = 30 minutes;
    uint16 constant LATEST_VERSION      = 1200;

    // Initial vault USDC reserves (10M)
    uint256 constant INITIAL_VAULT_USDC = 10_000_000e6;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG                  |
        Hooks.AFTER_ADD_LIQUIDITY_FLAG               |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG            |
        Hooks.BEFORE_SWAP_FLAG                       |
        Hooks.AFTER_SWAP_FLAG                        |
        Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        require(vm.getNonce(deployer) == 0, "deployer must be fresh on this chain");

        // ─── Chain-specific config ─────────────────────────────────────
        (address poolManagerAddr, address callbackProxy, address strategyRvm, string memory chainName)
            = _chainConfig();
        IPoolManager pm = IPoolManager(poolManagerAddr);

        require(poolManagerAddr.code.length > 0, "PoolManager not deployed at expected address");
        require(HookDeployer.CREATE2_DEPLOYER.code.length > 0, "canonical CREATE2 deployer missing");

        // Load MatchingRSC from lasna.json (or predictions.json as fallback)
        address matchingRvm = _loadMatchingRvm();

        console2.log("=== DeployOrigin ===");
        console2.log("Chain:        ", chainName);
        console2.log("Chain ID:     ", block.chainid);
        console2.log("Deployer:     ", deployer);
        console2.log("PoolManager:  ", poolManagerAddr);
        console2.log("CallbackProxy:", callbackProxy);
        console2.log("MatchingRVM:  ", matchingRvm);
        console2.log("StrategyRVM:  ", strategyRvm);

        vm.startBroadcast(deployerPk);

        // ─── nonce 0: MockUSDC ─────────────────────────────────────────
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        // nonce 1: MockWETH
        MockERC20 weth = new MockERC20("Mock WETH", "mWETH", 18);
        bool usdcIsToken0 = address(usdc) < address(weth);

        // ─── Predict registry + vault addresses for CREATE2 hook mining ─
        address predictedRegistry = vm.computeCreateAddress(deployer, 2);
        address predictedVault    = vm.computeCreateAddress(deployer, 3);

        // ─── Mine hook address ─────────────────────────────────────────
        bytes memory hookArgs = abi.encode(
            pm,
            INettingRegistry(predictedRegistry),
            predictedVault,
            PREMIUM_BPS,
            usdcIsToken0
        );
        (address hookAddr, bytes32 salt) = HookDeployer.mine(
            HOOK_FLAGS,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );

        // ─── nonce 2: NettingRegistry ──────────────────────────────────
        // Note: authorizedMatchingRvmId is the DEPLOYER address, not the MatchingRSC's
        // contract address. This matches Reactive's AbstractCallback convention where
        // rvm_id = msg.sender (= the deployer wallet) in the RSC's constructor.
        // Callbacks from MatchingRSC arrive with tx.origin = deployer wallet.
        NettingRegistry registry = new NettingRegistry(
            callbackProxy,
            deployer,           // ← was matchingRvm (RSC address); now deployer (wallet)
            ICrossHedgeHook(hookAddr),
            IRebatePayer(predictedVault),
            WATCHDOG_INTERVAL,
            LATEST_VERSION
        );
        require(address(registry) == predictedRegistry, "registry address mismatch");

        // ─── nonce 3: CrossHedgeVault ──────────────────────────────────
        // Note: authorizedStrategyRvmId is the DEPLOYER (same convention as registry).
        // Reactive's StrategyRSC callbacks arrive with tx.origin = deployer wallet.
        CrossHedgeVault vault = new CrossHedgeVault(
            IERC20(address(usdc)),
            "CrossHedge USDC", "chUSDC",
            pm,
            ICrossHedgeHook(hookAddr),
            INettingRegistry(address(registry)),
            callbackProxy, deployer,    // ← was strategyRvm; now deployer
            MAX_SLIPPAGE_BPS,
            PER_BLOCK_SWAP_CAP,
            TWAP_WINDOW
        );
        require(address(vault) == predictedVault, "vault address mismatch");

        // ─── nonce 4: deploy hook via CREATE2 ──────────────────────────
        bytes memory deployPayload = abi.encodePacked(
            salt,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );
        (bool ok,) = HookDeployer.CREATE2_DEPLOYER.call(deployPayload);
        require(ok, "hook CREATE2 deploy failed");
        require(hookAddr.code.length > 0, "hook code not deployed at mined address");

        // ─── Build PoolKey + initialize pool ───────────────────────────
        Currency c0 = usdcIsToken0 ? Currency.wrap(address(usdc)) : Currency.wrap(address(weth));
        Currency c1 = usdcIsToken0 ? Currency.wrap(address(weth)) : Currency.wrap(address(usdc));
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        pm.initialize(key, uint160(1 << 96));   // sqrt-price=1.0

        // ─── Wire managed key into vault ───────────────────────────────
        vault.setManagedKey(key, usdcIsToken0);

        // ─── Seed vault with USDC reserves ─────────────────────────────
        usdc.mint(address(vault), INITIAL_VAULT_USDC);

        vm.stopBroadcast();

        // ─── Write deployment record ───────────────────────────────────
        string memory out = "originDeployment";
        vm.serializeUint(out, "chainId", block.chainid);
        vm.serializeString(out, "chainName", chainName);
        vm.serializeAddress(out, "deployer", deployer);
        vm.serializeAddress(out, "poolManager", poolManagerAddr);
        vm.serializeAddress(out, "callbackProxy", callbackProxy);
        vm.serializeAddress(out, "matchingRvm", matchingRvm);
        vm.serializeAddress(out, "strategyRvm", strategyRvm);
        vm.serializeAddress(out, "usdc", address(usdc));
        vm.serializeAddress(out, "weth", address(weth));
        vm.serializeAddress(out, "registry", address(registry));
        vm.serializeAddress(out, "vault", address(vault));
        vm.serializeAddress(out, "hook", hookAddr);
        vm.serializeBool(out, "usdcIsToken0", usdcIsToken0);
        vm.serializeUint(out, "fee", 3000);
        vm.serializeInt(out, "tickSpacing", int24(60));
        vm.serializeUint(out, "initialVaultUsdc", INITIAL_VAULT_USDC);
        string memory finalJson = vm.serializeUint(out, "deployedAtBlock", block.number);

        string memory outPath = string.concat(
            "deployments/", vm.toString(block.chainid), ".json"
        );
        vm.writeJson(finalJson, outPath);

        console2.log("");
        console2.log("=== Deployed ===");
        console2.log("USDC:    ", address(usdc));
        console2.log("WETH:    ", address(weth));
        console2.log("Registry:", address(registry));
        console2.log("Vault:   ", address(vault));
        console2.log("Hook:    ", hookAddr);
        console2.log("Wrote ", outPath);
    }

    function _chainConfig() internal view returns (
        address poolManagerAddr,
        address callbackProxy,
        address strategyRvm,
        string memory chainName
    ) {
        string memory preds = vm.readFile("deployments/predictions.json");
        if (block.chainid == 1301) {
            return (
                POOL_MANAGER_UNICHAIN_SEPOLIA,
                CALLBACK_PROXY_UNICHAIN,
                vm.parseJsonAddress(preds, ".lasna.strategyRscUnichain"),
                "Unichain Sepolia"
            );
        } else if (block.chainid == 84532) {
            return (
                POOL_MANAGER_BASE_SEPOLIA,
                CALLBACK_PROXY_BASE,
                vm.parseJsonAddress(preds, ".lasna.strategyRscBase"),
                "Base Sepolia"
            );
        } else {
            revert("unsupported chain - this script targets Unichain Sepolia or Base Sepolia");
        }
    }

    function _loadMatchingRvm() internal view returns (address) {
        // Prefer lasna.json (actual deployment); fall back to predictions
        try vm.readFile("deployments/lasna.json") returns (string memory lasnaJson) {
            return vm.parseJsonAddress(lasnaJson, ".matchingRsc");
        } catch {
            string memory preds = vm.readFile("deployments/predictions.json");
            return vm.parseJsonAddress(preds, ".lasna.matchingRsc");
        }
    }
}
