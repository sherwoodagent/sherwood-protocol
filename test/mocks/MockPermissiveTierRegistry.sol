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

    /// @dev Permissive mirror of factory provenance: anything that answers
    ///      `vault()` is treated as a strategy clone (a class member), so the
    ///      vault's bound-clone predicate and class-binding check see the same
    ///      shape the real registry reports for a minted clone. Everything else
    ///      (routers, tokens, EOAs) stays a non-member.
    function classOf(address target) external view returns (bytes32) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature("vault()"));
        return ok && ret.length == 32 ? keccak256("permissive-strategy-class") : bytes32(0);
    }

    /// @notice The CALLEE axis (`_guardBatchCalls` PART 2a), split out of
    ///         `isAdapterAllowed` per pashov finding #14.
    /// @dev    Tracks the strong grant here rather than adding a third denial
    ///         switch: no strategy fixture is exercising the demotion asymmetry
    ///         (that lives in `Registry_demoteKeepsCalleeStanding.t.sol` against
    ///         the REAL registry), so mirroring keeps every existing refusal
    ///         test meaning exactly what it meant before the split.
    function isCallableTarget(address target) external view returns (bool) {
        return !denied[target] && !deniedAsAdapter[target];
    }

    /// @dev Uncertified everywhere: `(target, selector)` pairs are never vetted here.
    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }

    function isCounterpartyAllowed(address counterparty) external view returns (bool) {
        return !denied[counterparty];
    }
}
