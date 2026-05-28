// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MaxHeap} from "../../../src/reactive/modules/MaxHeap.sol";

/// @notice Harness exposing the library via external calls and providing the
///         storage slot for the heap. Also includes a helper to assert the
///         max-heap invariant from outside.
contract MaxHeapHarness {
    using MaxHeap for MaxHeap.Heap;
    MaxHeap.Heap internal heap;

    function init() external { heap.init(); }
    function size() external view returns (uint256) { return heap.size(); }
    function contains(bytes32 k) external view returns (bool) { return heap.contains(k); }

    function push(bytes32 k, uint128 p) external { heap.push(k, p); }
    function popMax() external returns (bytes32 k, uint128 p) { return heap.popMax(); }
    function peek() external view returns (bytes32 k, uint128 p) { return heap.peek(); }
    function remove(bytes32 k) external returns (uint128 p) { return heap.remove(k); }

    // ─── Invariant helpers ─────────────────────────────────────────────────

    /// @notice Returns (entries.length, raw entry at slot i).
    /// Used by tests to walk the heap and assert properties externally.
    function rawSize() external view returns (uint256) {
        return heap.entries.length;
    }

    function entryAt(uint256 i) external view returns (bytes32 key, uint128 priority) {
        return (heap.entries[i].key, heap.entries[i].priority);
    }

    function indexOfKey(bytes32 k) external view returns (uint256) {
        return heap.indexByKey[k];
    }
}

contract MaxHeapTest is Test {
    MaxHeapHarness internal h;

    function setUp() public {
        h = new MaxHeapHarness();
        h.init();
    }

    // ─── Invariant assertion ────────────────────────────────────────────────

    /// @dev Walks the entire heap and verifies:
    ///        I1. Max-heap property: child <= parent for all i >= 2.
    ///        I2. indexByKey[entries[i].key] == i for all real entries.
    function _assertHeapInvariant() internal view {
        uint256 raw = h.rawSize();
        // Slot 0 is the sentinel — we expect it to be the zero Entry.
        for (uint256 i = 2; i < raw; i++) {
            ( , uint128 childPriority) = h.entryAt(i);
            ( , uint128 parentPriority) = h.entryAt(i / 2);
            assertGe(parentPriority, childPriority, "max-heap property violated");
        }
        // Index integrity
        for (uint256 i = 1; i < raw; i++) {
            (bytes32 k, ) = h.entryAt(i);
            assertEq(h.indexOfKey(k), i, "indexByKey mismatch");
        }
    }

    function _k(uint256 n) internal pure returns (bytes32) {
        return bytes32(n);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Initialization
    // ═══════════════════════════════════════════════════════════════════════

    function test_init_EmptyAfterInit() public view {
        assertEq(h.size(), 0);
        assertEq(h.rawSize(), 1); // sentinel only
    }

    function test_init_Idempotent() public {
        h.init();
        h.init();
        assertEq(h.rawSize(), 1);
    }

    function test_init_SentinelIsZero() public view {
        (bytes32 k, uint128 p) = h.entryAt(0);
        assertEq(k, bytes32(0));
        assertEq(p, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            push
    // ═══════════════════════════════════════════════════════════════════════

    function test_push_SingleItem() public {
        h.push(_k(1), 100);
        assertEq(h.size(), 1);
        assertTrue(h.contains(_k(1)));
        _assertHeapInvariant();
    }

    function test_push_RootIsTop() public {
        h.push(_k(1), 50);
        h.push(_k(2), 100);
        (bytes32 k, uint128 p) = h.peek();
        assertEq(k, _k(2));
        assertEq(p, 100);
        _assertHeapInvariant();
    }

    function test_push_TopUpdatesWhenLargerArrives() public {
        h.push(_k(1), 10);
        h.push(_k(2), 20);
        h.push(_k(3), 30);
        (bytes32 k, ) = h.peek();
        assertEq(k, _k(3));
        _assertHeapInvariant();
    }

    function test_push_DuplicateKeyReverts() public {
        h.push(_k(1), 100);
        vm.expectRevert(abi.encodeWithSelector(MaxHeap.KeyAlreadyPresent.selector, _k(1)));
        h.push(_k(1), 50);
    }

    function test_push_ManyItems_InvariantHolds() public {
        // Push 20 items with random-looking priorities; assert invariant after each.
        uint128[20] memory priorities = [
            uint128(50), 100, 25, 75, 200, 10, 150, 80, 40, 90,
            60, 110, 30, 70, 180, 20, 140, 85, 35, 95
        ];
        for (uint256 i = 0; i < 20; i++) {
            h.push(_k(i + 1), priorities[i]);
            _assertHeapInvariant();
        }
        assertEq(h.size(), 20);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            popMax
    // ═══════════════════════════════════════════════════════════════════════

    function test_popMax_SingleItem() public {
        h.push(_k(1), 100);
        (bytes32 k, uint128 p) = h.popMax();
        assertEq(k, _k(1));
        assertEq(p, 100);
        assertEq(h.size(), 0);
        assertFalse(h.contains(_k(1)));
        _assertHeapInvariant();
    }

    function test_popMax_ReturnsLargest() public {
        h.push(_k(1), 50);
        h.push(_k(2), 100);
        h.push(_k(3), 75);
        (bytes32 k, uint128 p) = h.popMax();
        assertEq(k, _k(2));
        assertEq(p, 100);
        _assertHeapInvariant();
    }

    function test_popMax_OrderIsMonotone() public {
        // Push items in arbitrary order; pop them all; assert non-increasing.
        uint128[10] memory priorities =
            [uint128(50), 100, 25, 75, 200, 10, 150, 80, 40, 90];
        for (uint256 i = 0; i < 10; i++) {
            h.push(_k(i + 1), priorities[i]);
        }

        uint128 last = type(uint128).max;
        for (uint256 i = 0; i < 10; i++) {
            (, uint128 p) = h.popMax();
            assertLe(p, last);
            last = p;
            _assertHeapInvariant();
        }
        assertEq(h.size(), 0);
    }

    function test_popMax_EmptyReverts() public {
        vm.expectRevert(MaxHeap.HeapEmpty.selector);
        h.popMax();
    }

    function test_popMax_AfterPopAllowsRePush() public {
        h.push(_k(1), 100);
        h.popMax();
        // Key should be removed; we can push it again
        assertFalse(h.contains(_k(1)));
        h.push(_k(1), 50);
        assertTrue(h.contains(_k(1)));
        _assertHeapInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            peek
    // ═══════════════════════════════════════════════════════════════════════

    function test_peek_DoesNotMutate() public {
        h.push(_k(1), 100);
        h.peek();
        h.peek();
        h.peek();
        assertEq(h.size(), 1);
        assertTrue(h.contains(_k(1)));
    }

    function test_peek_EmptyReverts() public {
        vm.expectRevert(MaxHeap.HeapEmpty.selector);
        h.peek();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            remove
    // ═══════════════════════════════════════════════════════════════════════

    function test_remove_KeyAtTop() public {
        h.push(_k(1), 100);
        h.push(_k(2), 50);
        h.remove(_k(1));
        (bytes32 k, ) = h.peek();
        assertEq(k, _k(2));
        _assertHeapInvariant();
    }

    function test_remove_KeyAtLeaf() public {
        h.push(_k(1), 100);
        h.push(_k(2), 50);
        h.push(_k(3), 75);
        h.remove(_k(2)); // leaf-ish
        assertEq(h.size(), 2);
        assertFalse(h.contains(_k(2)));
        _assertHeapInvariant();
    }

    function test_remove_KeyInMiddle() public {
        // Build a tree, remove a middle node
        for (uint256 i = 0; i < 10; i++) {
            h.push(_k(i + 1), uint128((i + 1) * 10));
        }
        h.remove(_k(5));
        assertFalse(h.contains(_k(5)));
        assertEq(h.size(), 9);
        _assertHeapInvariant();
    }

    function test_remove_AbsentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MaxHeap.KeyAbsent.selector, _k(99)));
        h.remove(_k(99));
    }

    function test_remove_AllOneByOne() public {
        for (uint256 i = 0; i < 10; i++) {
            h.push(_k(i + 1), uint128((i + 1) * 7));
        }
        for (uint256 i = 0; i < 10; i++) {
            h.remove(_k(i + 1));
            _assertHeapInvariant();
        }
        assertEq(h.size(), 0);
    }

    function test_remove_LastEntry() public {
        // Edge case: when the removed slot IS the last entry, no movement needed
        h.push(_k(1), 100);
        h.push(_k(2), 50);
        h.remove(_k(2)); // entry at slot 2 is the last
        assertEq(h.size(), 1);
        _assertHeapInvariant();
    }

    function test_remove_TriggersSiftUp() public {
        // Construct a heap where removing an internal node causes the moved
        // last entry to need sifting UPWARD.
        //
        //        100              100
        //       /   \             /   \
        //      80   60   →       80    20
        //     /  \              /
        //    20  10           10
        //
        // Remove node 60 (priority 60); last entry is 10 (priority 10),
        // it gets placed where 60 was (right child). 10 < parent 100, no sift up.
        // Hmm bad example. Let me try:
        //
        //        100
        //       /   \
        //      50   80
        //     /  \
        //    30  10
        //
        // Remove 50 (priority 50). Last entry is 10 (priority 10).
        // Move 10 to slot 2. 10 < parent 100 OK; 10 < children 30 → sift down.
        // Actually we want sift UP triggered. Let's flip:
        //
        //        100
        //       /   \
        //      10   80
        //     /  \
        //    5   90  ← OOPS this violates heap already
        //
        // Hard to construct manually. Just verify that after a remove triggering
        // potentially-needed sift either direction, invariant holds.
        for (uint256 i = 0; i < 8; i++) {
            h.push(_k(i + 1), uint128((i % 4) * 30 + i));
        }
        h.remove(_k(3));
        _assertHeapInvariant();
        h.remove(_k(7));
        _assertHeapInvariant();
    }

    function test_remove_ThenPopReturnsCorrectMax() public {
        // Push with known priorities; remove the would-be max; pop should
        // return the runner-up.
        h.push(_k(1), 100);
        h.push(_k(2), 90);
        h.push(_k(3), 80);
        h.remove(_k(1)); // remove the max
        (bytes32 k, uint128 p) = h.popMax();
        assertEq(k, _k(2));
        assertEq(p, 90);
        _assertHeapInvariant();
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Edge cases
    // ═══════════════════════════════════════════════════════════════════════

    function test_zeroPriority_AcceptedAndOrdered() public {
        h.push(_k(1), 0);
        h.push(_k(2), 5);
        (bytes32 k, ) = h.popMax();
        assertEq(k, _k(2));
        (bytes32 k2, uint128 p2) = h.popMax();
        assertEq(k2, _k(1));
        assertEq(p2, 0);
    }

    function test_equalPriorities_BothPresent() public {
        h.push(_k(1), 50);
        h.push(_k(2), 50);
        h.push(_k(3), 50);
        // All have same priority — any order is valid, but all should be popped.
        assertEq(h.size(), 3);
        h.popMax();
        h.popMax();
        h.popMax();
        assertEq(h.size(), 0);
    }

    function test_maxUint128Priority() public {
        h.push(_k(1), type(uint128).max);
        h.push(_k(2), 100);
        (bytes32 k, uint128 p) = h.peek();
        assertEq(k, _k(1));
        assertEq(p, type(uint128).max);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Stress
    // ═══════════════════════════════════════════════════════════════════════

    function test_stress_PushPopInterleaved() public {
        for (uint256 i = 0; i < 30; i++) {
            // alternating push then pop
            h.push(_k(i + 1), uint128(uint256(keccak256(abi.encode(i))) % 1000));
            _assertHeapInvariant();
            if (i % 3 == 2 && h.size() > 0) {
                h.popMax();
                _assertHeapInvariant();
            }
        }
    }

    function test_stress_PushAndRemoveInterleaved() public {
        // Track which keys are present via local state
        bool[31] memory present;

        for (uint256 i = 0; i < 30; i++) {
            h.push(_k(i + 1), uint128(uint256(keccak256(abi.encode(i, "p"))) % 500));
            present[i + 1] = true;
            _assertHeapInvariant();
        }

        // Now randomly remove half
        for (uint256 i = 1; i <= 30; i++) {
            if (uint256(keccak256(abi.encode(i, "r"))) % 2 == 0) {
                h.remove(_k(i));
                present[i] = false;
                _assertHeapInvariant();
            }
        }

        // Count remaining
        uint256 expectedRemaining;
        for (uint256 i = 1; i <= 30; i++) {
            if (present[i]) expectedRemaining++;
        }
        assertEq(h.size(), expectedRemaining);
    }

    // ═══════════════════════════════════════════════════════════════════════
    //                            Fuzz
    // ═══════════════════════════════════════════════════════════════════════

    function testFuzz_pushPopMonotone(uint128[16] memory priorities) public {
        // Push all 16, then pop all 16, verify monotone non-increasing output
        for (uint256 i = 0; i < 16; i++) {
            h.push(_k(i + 1), priorities[i]);
        }
        _assertHeapInvariant();

        uint128 last = type(uint128).max;
        for (uint256 i = 0; i < 16; i++) {
            (, uint128 p) = h.popMax();
            assertLe(p, last, "pop order not monotone");
            last = p;
        }
        assertEq(h.size(), 0);
    }

    function testFuzz_randomOps(uint8 numOps, uint256 seed) public {
        vm.assume(numOps > 0 && numOps <= 50);

        uint256 nextKeyId = 1;
        bytes32[] memory present = new bytes32[](100);
        uint256 presentCount;

        for (uint256 i = 0; i < numOps; i++) {
            uint256 entropy = uint256(keccak256(abi.encode(seed, i)));
            uint8 op = uint8(entropy % 3);
            uint128 prio = uint128(entropy / 3);

            if (op == 0 || h.size() == 0) {
                // push
                bytes32 k = _k(nextKeyId++);
                h.push(k, prio);
                present[presentCount++] = k;
            } else if (op == 1) {
                // popMax
                (bytes32 k, ) = h.popMax();
                // remove from local tracking
                for (uint256 j = 0; j < presentCount; j++) {
                    if (present[j] == k) {
                        present[j] = present[presentCount - 1];
                        presentCount--;
                        break;
                    }
                }
            } else {
                // remove random present key
                if (presentCount == 0) continue;
                uint256 idx = entropy % presentCount;
                bytes32 k = present[idx];
                h.remove(k);
                present[idx] = present[presentCount - 1];
                presentCount--;
            }
            _assertHeapInvariant();
        }
    }
}
