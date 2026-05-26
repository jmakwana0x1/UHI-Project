// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title ReactiveConstants
/// @notice Reactive-specific chain IDs and topic hashes.
/// @dev Topic hashes are placeholders here; computed via keccak256 of the
///      canonical event signatures at deploy time in the RSC constructors.
library ReactiveConstants {
    // ─── Chain IDs (MVP testnets) ───────────────────────────────────────────
    uint256 internal constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 internal constant LASNA_CHAIN_ID = 5318008;

    // ─── Cron topic (system contract emits at fixed block intervals) ────────
    /// @notice The CRON topic_0 emitted by the Reactive system contract.
    /// @dev Filled in at deploy time; sample placeholder kept zero here.
    uint256 internal constant CRON_TOPIC_PLACEHOLDER = 0;
}
