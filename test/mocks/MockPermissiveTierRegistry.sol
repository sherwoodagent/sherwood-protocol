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
///         TWO AXES, mirroring the real registry. `isAdapterAllowed` is the
///         strong grant (batch callee, approve spender, transfer recipient);
///         `isCounterpartyAllowed` is the weak one a strategy binds through,
///         implied by the strong one. `setDenied` removes both, so the existing
///         refusal tests keep meaning what they meant; `setDeniedAsAdapter`
///         removes only the strong one, which is how a test expresses "listed
///         as a counterparty, NOT as an adapter" — the configuration the split
///         exists to make possible.
contract MockPermissiveTierRegistry {
    mapping(address => bool) public denied;
    mapping(address => bool) public deniedAsAdapter;

    /// @notice Deny (or re-allow) a single address on BOTH axes.
    function setDenied(address target, bool value) external {
        denied[target] = value;
    }

    /// @notice Deny (or re-allow) a single address on the ADAPTER axis only.
    function setDeniedAsAdapter(address target, bool value) external {
        deniedAsAdapter[target] = value;
    }

    function isAdapterAllowed(address adapter) external view returns (bool) {
        return !denied[adapter] && !deniedAsAdapter[adapter];
    }

    function isCounterpartyAllowed(address counterparty) external view returns (bool) {
        return !denied[counterparty];
    }
}
