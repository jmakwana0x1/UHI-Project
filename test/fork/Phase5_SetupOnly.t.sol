// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/libraries/TransientStateLibrary.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICrossHedgeVault} from "../../src/interfaces/ICrossHedgeVault.sol";

import {CrossHedgeHook} from "../../src/hook/CrossHedgeHook.sol";
import {NettingRegistry} from "../../src/registry/NettingRegistry.sol";
import {CrossHedgeVault} from "../../src/vault/CrossHedgeVault.sol";
import {ICrossHedgeHook} from "../../src/interfaces/ICrossHedgeHook.sol";
import {INettingRegistry} from "../../src/interfaces/INettingRegistry.sol";
import {IRebatePayer} from "../../src/interfaces/IRebatePayer.sol";

import {HookDeployer} from "../utils/HookDeployer.sol";
import {MockERC20} from "../utils/MockERC20.sol";

/// @notice First fork test — just verifies that we can fork Unichain Sepolia,
///         mine + deploy our hook against the REAL PoolManager, initialize a
///         pool, and confirm the hook's afterInitialize fires.
///
/// @dev    Auto-skips when UNICHAIN_SEPOLIA_RPC env var is unset, so local
///         dev doesn't need RPC access. To run:
///             export UNICHAIN_SEPOLIA_RPC=<your alchemy url>
///             forge test --match-path "test/fork/Phase5_SetupOnly.t.sol" -vv
/// @notice Helper that wraps unlock+modifyLiquidity for seeding pool liquidity.
///         Acts as its own UnlockCallback target, settles its own deltas.
contract ForkLiquidityRouter is IUnlockCallback {
    using SafeERC20 for IERC20;
    using TransientStateLibrary for IPoolManager;

    IPoolManager public immutable pm;
    constructor(IPoolManager _pm) { pm = _pm; }

    struct AddLiqArgs {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    function addLiquidity(PoolKey calldata key, int24 tl, int24 tu, int256 liq) external {
        bytes memory data = abi.encode(AddLiqArgs(key, tl, tu, liq));
        pm.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(pm), "router: only pm");
        AddLiqArgs memory a = abi.decode(data, (AddLiqArgs));

        // ─── Pre-seed PM with tokens so the hook's take() can succeed ─────
        // The hook may charge premium via take() inside afterAddLiquidity.
        // PM needs to hold tokens before that take fires, or transfer reverts.
        // We pre-seed and reclaim the surplus at end-of-unlock.
        //
        // In production, the vault's rebalance is the first LP into the pool
        // (vault is sender → hook skips premium → no take needed → PM bootstrap
        // happens naturally). This pre-seeding is fork-test-only scaffolding.
        uint256 seedAmount = 100_000_000e6; // 100M of each token, enough for any test
        pm.sync(a.key.currency0);
        IERC20(Currency.unwrap(a.key.currency0)).safeTransfer(address(pm), seedAmount);
        pm.settle();
        pm.sync(a.key.currency1);
        IERC20(Currency.unwrap(a.key.currency1)).safeTransfer(address(pm), seedAmount);
        pm.settle();

        ModifyLiquidityParams memory mp = ModifyLiquidityParams({
            tickLower: a.tickLower,
            tickUpper: a.tickUpper,
            liquidityDelta: a.liquidityDelta,
            salt: bytes32(0)
        });
        pm.modifyLiquidity(a.key, mp, "");

        // Settle/take both currencies. The pre-seed amount comes back via take.
        _settle(a.key.currency0);
        _settle(a.key.currency1);
        return "";
    }

    event RouterDebug(string what, int256 delta, uint256 amount);

    function _settle(Currency c) internal {
        int256 d = pm.currencyDelta(address(this), c);
        emit RouterDebug("pre-settle delta", d, uint256(Currency.unwrap(c) == address(0) ? 0 : 1));
        if (d < 0) {
            uint256 owed = uint256(-d);
            pm.sync(c);
            IERC20(Currency.unwrap(c)).safeTransfer(address(pm), owed);
            uint256 paid = pm.settle();
            emit RouterDebug("settled", int256(paid), owed);
            int256 dPost = pm.currencyDelta(address(this), c);
            emit RouterDebug("post-settle delta", dPost, 0);
        } else if (d > 0) {
            pm.take(c, address(this), uint256(d));
            emit RouterDebug("took", d, 0);
        }
    }
}

contract Phase5SetupOnlyTest is Test {
    using PoolIdLibrary for PoolKey;

    // Real v4 + USDC on Unichain Sepolia
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant USDC         = 0x31d0220469e10c4E71834a79b1f276d740d3768F;

    IPoolManager internal pm;
    CrossHedgeHook internal hook;
    NettingRegistry internal registry;
    CrossHedgeVault internal vault;
    MockERC20 internal usdc;  // we deploy our own to avoid Circle USDC quirks
    MockERC20 internal weth;  // stand-in for WETH; any ERC20 works
    PoolKey internal key;
    PoolId internal poolId;

    address internal callbackProxy = makeAddr("callbackProxy");
    address internal matchingRvm = makeAddr("matchingRvm");
    address internal strategyRvm = makeAddr("strategyRvm");

    // MUST match BaseTest.HOOK_FLAGS exactly — same hook contract, same flags.
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG                  |
        Hooks.AFTER_ADD_LIQUIDITY_FLAG               |
        Hooks.AFTER_REMOVE_LIQUIDITY_FLAG            |
        Hooks.BEFORE_SWAP_FLAG                       |
        Hooks.AFTER_SWAP_FLAG                        |
        Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function setUp() public {
        // ─── Skip if no RPC configured ────────────────────────────────────
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }

        vm.createSelectFork(rpc);

        // ─── Verify real PoolManager exists at the expected address ───────
        require(POOL_MANAGER.code.length > 0, "PoolManager not deployed at expected address");
        pm = IPoolManager(POOL_MANAGER);

        // ─── Deploy our two ERC20s (USDC stand-in + WETH stand-in) ────────
        // Using our own ERC20s instead of the real testnet USDC because
        // `deal` cheatcodes are more reliable against simple OZ ERC20s.
        usdc = new MockERC20("Mock USDC", "mUSDC", 6);
        weth = new MockERC20("Mock WETH", "mWETH", 18);

        bool usdcIsToken0 = address(usdc) < address(weth);

        // ─── Address-prediction dance for constructor cycle ───────────────
        uint64 nonceNow = vm.getNonce(address(this));
        address predictedRegistry = vm.computeCreateAddress(address(this), nonceNow);
        address predictedVault    = vm.computeCreateAddress(address(this), nonceNow + 1);

        bytes memory hookArgs = abi.encode(
            pm,
            INettingRegistry(predictedRegistry),
            predictedVault,
            uint16(30),  // 30 bps premium
            usdcIsToken0
        );
        (address hookAddr, bytes32 salt) = HookDeployer.mine(
            HOOK_FLAGS,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );

        // Deploy registry (consumes nonce)
        registry = new NettingRegistry(
            callbackProxy,
            matchingRvm,
            ICrossHedgeHook(hookAddr),
            IRebatePayer(predictedVault),
            30 minutes,
            1200
        );
        require(address(registry) == predictedRegistry, "registry addr mismatch");

        // Deploy vault (consumes next nonce)
        vault = new CrossHedgeVault(
            IERC20(address(usdc)),
            "CrossHedge USDC", "chUSDC",
            pm,
            ICrossHedgeHook(hookAddr),
            INettingRegistry(address(registry)),
            callbackProxy, strategyRvm,
            uint16(50),               // 50 bps slippage
            uint256(1_000_000e6),     // 1M per-block swap cap
            uint32(30 minutes)        // TWAP window
        );
        require(address(vault) == predictedVault, "vault addr mismatch");

        // Deploy hook via CREATE2 at the mined address. Requires the canonical
        // CREATE2 deployer to exist at 0x4e59... on Unichain Sepolia.
        require(
            HookDeployer.CREATE2_DEPLOYER.code.length > 0,
            "canonical CREATE2 deployer missing on Unichain Sepolia"
        );
        bytes memory deployPayload = abi.encodePacked(
            salt,
            type(CrossHedgeHook).creationCode,
            hookArgs
        );
        (bool ok,) = HookDeployer.CREATE2_DEPLOYER.call(deployPayload);
        require(ok, "hook CREATE2 deploy failed");
        hook = CrossHedgeHook(hookAddr);
        require(address(hook).code.length > 0, "hook bytecode missing after deploy");

        // ─── Build PoolKey ────────────────────────────────────────────────
        Currency c0 = usdcIsToken0 ? Currency.wrap(address(usdc)) : Currency.wrap(address(weth));
        Currency c1 = usdcIsToken0 ? Currency.wrap(address(weth)) : Currency.wrap(address(usdc));
        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        // ─── Initialize the pool via REAL PoolManager ─────────────────────
        // sqrtPrice = 2^96 → price = 1.0 (USDC ≈ WETH for the test)
        uint160 sqrtPriceX96 = uint160(1 << 96);
        pm.initialize(key, sqrtPriceX96);

        // ─── Deploy the LP router and set the managed key on vault ────────
        router = new ForkLiquidityRouter(pm);
        vault.setManagedKey(key, usdcIsToken0);

        // ─── Mint tokens to the router so it can seed pool liquidity ──────
        // The router needs both tokens to fund a two-sided LP position.
        usdc.mint(address(router), 10_000_000_000e6);  // 10B USDC (need ~200M for pre-seed + LP)
        weth.mint(address(router), 10_000_000 ether);    // 10M WETH

        // ─── Seed pool liquidity around current price ─────────────────────
        // The vault's WETH-cover swap needs counterparty liquidity to swap
        // against. Seed a wide range with substantial liquidity.
        router.addLiquidity(key, int24(-6000), int24(6000), int256(1e13));

        // ─── Seed the vault with USDC reserves ────────────────────────────
        usdc.mint(address(vault), 10_000_000e6);
    }

    ForkLiquidityRouter internal router;

    using StateLibrary for IPoolManager;

    // ═══════════════════════════════════════════════════════════════════════
    //                          THE SETUP-ONLY TEST
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_setupSucceeded() public view {
        // If we got here, all the hard parts worked.
        assertEq(address(vault.poolManager()), POOL_MANAGER);
        assertEq(address(vault.hook()), address(hook));
        // Pool was initialized and seeded with liquidity
        (uint160 sqrtP,,,) = pm.getSlot0(poolId);
        assertGt(sqrtP, 0, "pool not initialized");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          1. Hook fires on add-liquidity
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_addLiquidity_HookFires() public {
        // The router's setUp addLiquidity should have fired the hook.
        // The hook tracks premium accrued; verify it's non-zero (or at least
        // the hook was reachable — premium charging is conditional on the
        // sender NOT being the vault, and the router is not the vault).
        //
        // For this test we just verify the pool has the expected liquidity,
        // proving modifyLiquidity ran through the hook successfully.
        uint128 liq = pm.getLiquidity(poolId);
        assertGt(liq, 0, "no pool liquidity after LP add");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  2. Rebalance settles against real v4
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_rebalance_SettlesAgainstRealV4() public {
        _seedTwapSnapshots();

        // Diagnostic: print vault USDC balance right before rebalance
        emit log_named_uint("vault USDC bal pre-rebalance", usdc.balanceOf(address(vault)));
        emit log_named_uint("vault USDC bal expected", 10_000_000e6);

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-600),
            tickUpper: int24(600),
            targetLiquidity: uint128(1e10),
            keepIfExists: true
        });

        vm.prank(callbackProxy);
        vault.rebalance(strategyRvm, allocs);

        assertEq(vault.ownedAllocationCount(), 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  3. Pool liquidity actually increases
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_rebalance_PoolLiquidityActuallyIncreases() public {
        _seedTwapSnapshots();

        uint128 liqBefore = pm.getLiquidity(poolId);

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-600),
            tickUpper: int24(600),
            targetLiquidity: uint128(1e10),
            keepIfExists: true
        });

        vm.prank(callbackProxy);
        vault.rebalance(strategyRvm, allocs);

        uint128 liqAfter = pm.getLiquidity(poolId);
        assertGt(liqAfter, liqBefore, "pool liquidity did not increase after rebalance");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  4. Vault USDC actually decreases
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_rebalance_VaultUsdcDecreases() public {
        _seedTwapSnapshots();

        uint256 balBefore = usdc.balanceOf(address(vault));

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-600),
            tickUpper: int24(600),
            targetLiquidity: uint128(1e10),
            keepIfExists: true
        });

        vm.prank(callbackProxy);
        vault.rebalance(strategyRvm, allocs);

        uint256 balAfter = usdc.balanceOf(address(vault));
        assertLt(balAfter, balBefore, "vault USDC should have decreased");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  5. totalAssets reflects deployed value
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_totalAssets_IncludesDeployedValue() public {
        _seedTwapSnapshots();

        uint256 totalBefore = vault.totalAssets();
        uint256 balBefore = usdc.balanceOf(address(vault));
        assertEq(totalBefore, balBefore, "no deployment yet, totalAssets == bal");

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](1);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-600),
            tickUpper: int24(600),
            targetLiquidity: uint128(1e10),
            keepIfExists: true
        });

        vm.prank(callbackProxy);
        vault.rebalance(strategyRvm, allocs);

        uint256 totalAfter = vault.totalAssets();
        uint256 balAfter = usdc.balanceOf(address(vault));

        // totalAssets after rebalance > bare balance because deployed value
        // is credited via the valuation function
        assertGt(totalAfter, balAfter, "totalAssets should include deployed value");
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                  6. Multiple allocations settle clean
    // ═══════════════════════════════════════════════════════════════════════

    function test_fork_multipleAllocations_SettleClean() public {
        _seedTwapSnapshots();

        ICrossHedgeVault.Allocation[] memory allocs = new ICrossHedgeVault.Allocation[](2);
        allocs[0] = ICrossHedgeVault.Allocation({
            tickLower: int24(-600), tickUpper: int24(600),
            targetLiquidity: uint128(1e10), keepIfExists: true
        });
        allocs[1] = ICrossHedgeVault.Allocation({
            tickLower: int24(-1200), tickUpper: int24(1200),
            targetLiquidity: uint128(5e9), keepIfExists: true
        });

        vm.prank(callbackProxy);
        vault.rebalance(strategyRvm, allocs);

        assertEq(vault.ownedAllocationCount(), 2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                          Helpers
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev The hook's TWAP requires MIN_TWAP_SAMPLES=3 snapshots. afterInitialize
    ///      pushes 1; setUp's first addLiquidity pushes a 2nd (rate-limited to
    ///      one per 30s). We need a 3rd, so we warp 31+ seconds and do another
    ///      add to trigger _maybePushSnapshot.
    ///
    ///      Each call triggers premium-charging on the dust position; that's
    ///      fine — the router pre-seeds PM with tokens so the hook's take()
    ///      succeeds. Dust premium amounts round to 0 and get skipped by
    ///      the hook's "if (raw == 0)" guard.
    function _seedTwapSnapshots() internal {
        // Push 2 more snapshots beyond the afterInitialize seed.
        // SNAPSHOT_MIN_INTERVAL is 30s. Use absolute timestamps + vm.roll to
        // ensure both warps actually take effect (foundry can cache block
        // state between calls on forks if vm.roll isn't used).
        uint256 t = block.timestamp;
        vm.warp(t + 31);
        vm.roll(block.number + 1);
        router.addLiquidity(key, int24(-60), int24(60), int256(1));

        vm.warp(t + 62);
        vm.roll(block.number + 1);
        router.addLiquidity(key, int24(-60), int24(60), int256(1));
    }
}
