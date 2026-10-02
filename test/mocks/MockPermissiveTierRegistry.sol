// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Allow-by-default `TierRegistry` stand-in for strategy fixtures.
/// @dev    Strategy templates bind their proposer-supplied venues to the registry
///         reached through `vault() -> governor() -> tierRegistry() ->
///         isCounterpartyAllowed`. Most strategy tests need that to answer "yes";
///         a test exercising a refusal denies specific addresses explicitly.
contract MockPermissiveTierRegistry {
    mapping(address => bool) public denied;

    /// @notice Deny (or re-allow) a single address.
    function setDenied(address target, bool value) external {
        denied[target] = value;
    }

    /// @dev No class concept in this stand-in.
    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }

    function isCounterpartyAllowed(address counterparty) external view returns (bool) {
        return !denied[counterparty];
    }

    mapping(bytes32 => bool) public deniedMarket;

    /// @notice Deny (or re-allow) a single Morpho market id.
    function setMarketDenied(bytes32 id, bool value) external {
        deniedMarket[id] = value;
    }

    function isMorphoMarketAllowed(bytes32 id) external view returns (bool) {
        return !deniedMarket[id];
    }
}
