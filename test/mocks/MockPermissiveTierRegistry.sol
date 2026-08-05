// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Allow-by-default `TierRegistry` stand-in for strategy fixtures.
/// @dev    Strategy templates bind their proposer-supplied counterparties to
///         the registry the vault's own governor gates batch approvals against
///         (`vault() -> governor() -> tierRegistry() -> isAdapterAllowed`).
///         Most strategy tests are not exercising that binding — they need it
///         to answer "yes" and get out of the way — so this defaults to
///         permissive and lets a test deny specific addresses to drive the
///         negative path.
///
///         Deliberately NOT permissive-by-omission: `deny` is explicit, so a
///         test that means to exercise a refusal cannot get a false pass from
///         a mock that silently allowed everything it was never told about.
contract MockPermissiveTierRegistry {
    mapping(address => bool) public denied;

    /// @notice Deny (or re-allow) a single address.
    function setDenied(address target, bool value) external {
        denied[target] = value;
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return !denied[adapter];
    }
}
