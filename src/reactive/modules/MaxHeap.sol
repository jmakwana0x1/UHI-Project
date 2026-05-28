// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title MaxHeap
/// @notice Binary max-heap with O(log n) push, pop, and arbitrary-key remove.
///
/// @dev Storage layout (1-indexed):
///        entries[0]   : unused sentinel
///        entries[1]   : root (max-priority entry)
///        entries[i]   : parent = i/2, children = 2i and 2i+1
///
///      `indexByKey[key]` maps a key to its position in `entries`.
///      A value of 0 means "not present" (entries[0] is the sentinel, so
///      no real entry lives there).
///
/// @dev Invariants maintained at all times:
///        I1. For every i in [2, entries.length): entries[i].priority <= entries[i/2].priority
///        I2. For every i in [1, entries.length): indexByKey[entries[i].key] == i
///        I3. For every key with indexByKey[key] > 0: entries[indexByKey[key]].key == key
///        I4. entries[0] is the zero-value Entry (never read except as sentinel)
library MaxHeap {
    struct Entry {
        bytes32 key;
        uint128 priority;
    }

    struct Heap {
        Entry[] entries;
        mapping(bytes32 => uint256) indexByKey;
    }

    /// @notice Initialize an empty heap. Idempotent — pushes the sentinel
    ///         entry to slot 0 if absent. Must be called once before first use.
    function init(Heap storage h) internal {
        if (h.entries.length == 0) {
            h.entries.push(Entry({key: bytes32(0), priority: 0})); // sentinel
        }
    }

    /// @notice Current number of real entries (excludes sentinel).
    function size(Heap storage h) internal view returns (uint256) {
        return h.entries.length == 0 ? 0 : h.entries.length - 1;
    }

    /// @notice Return true if `key` is in the heap.
    function contains(Heap storage h, bytes32 key) internal view returns (bool) {
        return h.indexByKey[key] != 0;
    }

    /// @notice Push a (key, priority) pair. Reverts if key is already present.
    function push(Heap storage h, bytes32 key, uint128 priority) internal {
        if (h.indexByKey[key] != 0) revert KeyAlreadyPresent(key);

        h.entries.push(Entry({key: key, priority: priority}));
        uint256 idx = h.entries.length - 1;
        h.indexByKey[key] = idx;

        _siftUp(h, idx);
    }

    /// @notice Read the max-priority entry without removing it.
    /// @dev Reverts if heap is empty.
    function peek(Heap storage h) internal view returns (bytes32 key, uint128 priority) {
        if (size(h) == 0) revert HeapEmpty();
        Entry storage top = h.entries[1];
        return (top.key, top.priority);
    }

    /// @notice Remove and return the max-priority entry.
    /// @dev Reverts if heap is empty.
    function popMax(Heap storage h) internal returns (bytes32 key, uint128 priority) {
        if (size(h) == 0) revert HeapEmpty();

        Entry storage top = h.entries[1];
        key = top.key;
        priority = top.priority;

        _removeAt(h, 1);
    }

    /// @notice Remove an arbitrary entry by its key.
    /// @dev Reverts if key is absent. Returns the removed priority for callers
    ///      that want it.
    function remove(Heap storage h, bytes32 key) internal returns (uint128 priority) {
        uint256 idx = h.indexByKey[key];
        if (idx == 0) revert KeyAbsent(key);

        priority = h.entries[idx].priority;
        _removeAt(h, idx);
    }

    // ─── Internals ──────────────────────────────────────────────────────────

    /// @dev Remove the entry at `idx` by moving the last entry there and
    ///      re-heapifying. Handles both pop-from-root and arbitrary-key remove.
    function _removeAt(Heap storage h, uint256 idx) private {
        uint256 lastIdx = h.entries.length - 1;
        bytes32 removedKey = h.entries[idx].key;

        if (idx == lastIdx) {
            // Removing the last entry — just pop, no rebalance needed.
            h.entries.pop();
            delete h.indexByKey[removedKey];
            return;
        }

        // Move last entry into idx's slot
        Entry memory moved = h.entries[lastIdx];
        h.entries[idx] = moved;
        h.indexByKey[moved.key] = idx;
        h.entries.pop();
        delete h.indexByKey[removedKey];

        // Re-heapify: try sift up first; if no movement, sift down.
        // (One direction will always be a no-op; we just need to try both.)
        uint256 newIdx = _siftUp(h, idx);
        if (newIdx == idx) {
            _siftDown(h, idx);
        }
    }

    /// @dev Bubble entry at `idx` upward while it's larger than its parent.
    /// @return The final index of the entry after sifting.
    function _siftUp(Heap storage h, uint256 idx) private returns (uint256) {
        while (idx > 1) {
            uint256 parentIdx = idx / 2;
            Entry storage cur = h.entries[idx];
            Entry storage par = h.entries[parentIdx];
            if (cur.priority <= par.priority) break;

            // Swap
            _swap(h, idx, parentIdx);
            idx = parentIdx;
        }
        return idx;
    }

    /// @dev Push entry at `idx` downward while a child is larger.
    function _siftDown(Heap storage h, uint256 idx) private {
        uint256 n = h.entries.length;
        while (true) {
            uint256 left = idx * 2;
            uint256 right = left + 1;
            uint256 largest = idx;

            if (left < n && h.entries[left].priority > h.entries[largest].priority) {
                largest = left;
            }
            if (right < n && h.entries[right].priority > h.entries[largest].priority) {
                largest = right;
            }
            if (largest == idx) break;

            _swap(h, idx, largest);
            idx = largest;
        }
    }

    /// @dev Swap two entries by index, updating indexByKey.
    function _swap(Heap storage h, uint256 i, uint256 j) private {
        Entry memory ei = h.entries[i];
        Entry memory ej = h.entries[j];

        h.entries[i] = ej;
        h.entries[j] = ei;
        h.indexByKey[ei.key] = j;
        h.indexByKey[ej.key] = i;
    }

    // ─── Errors ─────────────────────────────────────────────────────────────

    error KeyAlreadyPresent(bytes32 key);
    error KeyAbsent(bytes32 key);
    error HeapEmpty();
}
