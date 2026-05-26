// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PositionIdLib} from "../../../src/libraries/PositionIdLib.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/// @title PositionIdLibTest
/// @notice Verifies deterministic position-id derivation. The function is one
///         keccak256; the tests check that it's deterministic, collision-
///         resistant on differing inputs, and stable across reasonable inputs.
contract PositionIdLibTest is Test {
    // ─── Test fixtures ──────────────────────────────────────────────────────

    PoolId internal POOL_A;
    PoolId internal POOL_B;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    int24 internal constant T_LOW = -100;
    int24 internal constant T_HIGH = 100;

    bytes32 internal constant SALT_0 = bytes32(0);
    bytes32 internal constant SALT_1 = bytes32(uint256(1));

    function setUp() public {
        POOL_A = PoolId.wrap(bytes32(uint256(0xAAAA)));
        POOL_B = PoolId.wrap(bytes32(uint256(0xBBBB)));
    }

    // ─── Determinism ────────────────────────────────────────────────────────

    function test_determinism_SameInputsSameOutput() public view {
        bytes32 id1 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 id2 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        assertEq(id1, id2);
    }

    function test_determinism_IsPure() public view {
        // Call many times — must always be identical.
        bytes32 expected = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        for (uint256 i = 0; i < 10; i++) {
            assertEq(
                PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0),
                expected
            );
        }
    }

    // ─── Sensitivity to every input ─────────────────────────────────────────

    function test_sensitivity_DifferentOwners() public view {
        bytes32 idA = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 idB = PositionIdLib.compute(POOL_A, BOB, T_LOW, T_HIGH, SALT_0);
        assertTrue(idA != idB);
    }

    function test_sensitivity_DifferentTickLower() public view {
        bytes32 id1 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 id2 = PositionIdLib.compute(POOL_A, ALICE, T_LOW - 1, T_HIGH, SALT_0);
        assertTrue(id1 != id2);
    }

    function test_sensitivity_DifferentTickUpper() public view {
        bytes32 id1 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 id2 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH + 1, SALT_0);
        assertTrue(id1 != id2);
    }

    function test_sensitivity_DifferentSalt() public view {
        bytes32 id0 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 id1 = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_1);
        assertTrue(id0 != id1);
    }

    function test_sensitivity_DifferentPool() public view {
        bytes32 idA = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_HIGH, SALT_0);
        bytes32 idB = PositionIdLib.compute(POOL_B, ALICE, T_LOW, T_HIGH, SALT_0);
        assertTrue(idA != idB);
    }

    // ─── Edge cases ─────────────────────────────────────────────────────────

    function test_edge_ZeroOwner() public view {
        // Should not revert; just produces some posId.
        bytes32 id = PositionIdLib.compute(POOL_A, address(0), T_LOW, T_HIGH, SALT_0);
        assertTrue(id != bytes32(0));
    }

    function test_edge_ExtremeTicks() public view {
        // Max int24 ticks — should still compute.
        int24 tMax = type(int24).max;
        int24 tMin = type(int24).min;
        bytes32 id = PositionIdLib.compute(POOL_A, ALICE, tMin, tMax, SALT_0);
        assertTrue(id != bytes32(0));
    }

    function test_edge_EqualTicks() public view {
        // Degenerate range (tL == tU) — library doesn't validate, just hashes.
        // Caller's responsibility to filter.
        bytes32 id = PositionIdLib.compute(POOL_A, ALICE, T_LOW, T_LOW, SALT_0);
        assertTrue(id != bytes32(0));
    }

    function test_edge_ZeroPoolId() public view {
        PoolId zeroPool = PoolId.wrap(bytes32(0));
        bytes32 id = PositionIdLib.compute(zeroPool, ALICE, T_LOW, T_HIGH, SALT_0);
        assertTrue(id != bytes32(0));
    }

    // ─── Fuzz ───────────────────────────────────────────────────────────────

    function testFuzz_determinism(
        bytes32 poolBytes,
        address owner,
        int24 tL,
        int24 tU,
        bytes32 salt
    ) public pure {
        PoolId pid = PoolId.wrap(poolBytes);
        bytes32 id1 = PositionIdLib.compute(pid, owner, tL, tU, salt);
        bytes32 id2 = PositionIdLib.compute(pid, owner, tL, tU, salt);
        assertEq(id1, id2);
    }

    function testFuzz_collisionResistance_DifferentOwners(
        bytes32 poolBytes,
        address ownerA,
        address ownerB,
        int24 tL,
        int24 tU,
        bytes32 salt
    ) public pure {
        vm.assume(ownerA != ownerB);
        PoolId pid = PoolId.wrap(poolBytes);
        bytes32 idA = PositionIdLib.compute(pid, ownerA, tL, tU, salt);
        bytes32 idB = PositionIdLib.compute(pid, ownerB, tL, tU, salt);
        assertTrue(idA != idB);
    }

    function testFuzz_collisionResistance_DifferentSalts(
        bytes32 poolBytes,
        address owner,
        int24 tL,
        int24 tU,
        bytes32 saltA,
        bytes32 saltB
    ) public pure {
        vm.assume(saltA != saltB);
        PoolId pid = PoolId.wrap(poolBytes);
        bytes32 idA = PositionIdLib.compute(pid, owner, tL, tU, saltA);
        bytes32 idB = PositionIdLib.compute(pid, owner, tL, tU, saltB);
        assertTrue(idA != idB);
    }
}
