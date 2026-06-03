// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {LPRouter} from "../src/periphery/LPRouter.sol";
import {MockERC20} from "../test/utils/MockERC20.sol";
import {INettingRegistry} from "../src/interfaces/INettingRegistry.sol";

/// @notice Smoke test: opens an LP position on a live origin chain and verifies
///         the hook fires + registry records the position.
///
/// Usage (Unichain Sepolia):
///     DEPLOYER_PRIVATE_KEY=0x... \
///     forge script script/OpenPosition.s.sol \
///         --rpc-url https://unichain-sepolia.g.alchemy.com/v2/<KEY> \
///         --broadcast
contract OpenPosition is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        // Load this chain's deployment
        string memory path = string.concat("deployments/", vm.toString(block.chainid), ".json");
        string memory json = vm.readFile(path);

        address pmAddr     = vm.parseJsonAddress(json, ".poolManager");
        address usdcAddr   = vm.parseJsonAddress(json, ".usdc");
        address wethAddr   = vm.parseJsonAddress(json, ".weth");
        address registryAddr = vm.parseJsonAddress(json, ".registry");
        address hookAddr   = vm.parseJsonAddress(json, ".hook");
        bool usdcIsToken0  = vm.parseJsonBool(json, ".usdcIsToken0");

        IPoolManager pm = IPoolManager(pmAddr);
        MockERC20 usdc = MockERC20(usdcAddr);
        MockERC20 weth = MockERC20(wethAddr);

        console2.log("=== OpenPosition smoke test ===");
        console2.log("Chain ID:    ", block.chainid);
        console2.log("Deployer:    ", deployer);
        console2.log("PoolManager: ", pmAddr);
        console2.log("USDC:        ", usdcAddr);
        console2.log("WETH:        ", wethAddr);
        console2.log("Registry:    ", registryAddr);
        console2.log("Hook:        ", hookAddr);
        console2.log("usdcIsToken0:", usdcIsToken0);

        vm.startBroadcast(deployerPk);

        // 1) Deploy the LP router
        LPRouter router = new LPRouter(pm);
        console2.log("");
        console2.log("Deployed LPRouter at:", address(router));

        // 2) Mint sufficient tokens to the router (it needs to hold the pre-seed)
        usdc.mint(address(router), 200_000_000e6);   // 200M USDC (covers 100M pre-seed + LP needs)
        weth.mint(address(router), 200_000_000 ether); // 200M WETH
        console2.log("Minted 200M of each token to router");

        // 3) Reconstruct the PoolKey from deployment metadata
        Currency c0 = usdcIsToken0 ? Currency.wrap(usdcAddr) : Currency.wrap(wethAddr);
        Currency c1 = usdcIsToken0 ? Currency.wrap(wethAddr) : Currency.wrap(usdcAddr);
        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        // 4) Open an LP position. Tick range and liquidity configurable via env:
        //    POSITION_TICK_LOWER (default -600)
        //    POSITION_TICK_UPPER (default 600)
        //    POSITION_LIQUIDITY  (default 1e10)
        //
        // For an above-range "short" position on a pool initialized at tick 0,
        // use POSITION_TICK_LOWER=600 POSITION_TICK_UPPER=1200.
        int24 tl = int24(int256(vm.envOr("POSITION_TICK_LOWER", int256(-600))));
        int24 tu = int24(int256(vm.envOr("POSITION_TICK_UPPER", int256(600))));
        int256 liquidityDelta = vm.envOr("POSITION_LIQUIDITY", int256(1e10));

        console2.log("");
        console2.log("Opening LP position:");
        console2.log("  tickLower:    ", tl);
        console2.log("  tickUpper:    ", tu);
        console2.log("  liquidityDelta:", liquidityDelta);

        router.addLiquidity(key, tl, tu, liquidityDelta);

        vm.stopBroadcast();

        // 5) Read back registry to confirm position was recorded
        // The position ID is keccak256(poolId, owner, tickLower, tickUpper)
        // where owner is the router (the modifyLiquidity sender)
        bytes32 poolId = PoolId.unwrap(key.toId());
        bytes32 posId = keccak256(abi.encode(poolId, address(router), tl, tu));

        INettingRegistry registry = INettingRegistry(registryAddr);

        console2.log("");
        console2.log("=== Verification ===");
        console2.log("Position ID:", vm.toString(posId));
        console2.log("Pool ID:    ", vm.toString(poolId));

        // Note: position lookup requires a getter we may need to add.
        // For now we confirm by event subscription (foundry will print
        // the LPPositionOpened event in the broadcast trace).
        console2.log("");
        console2.log("If you see an LPPositionOpened event in the broadcast trace");
        console2.log("above, the smoke test succeeded.");
    }
}
