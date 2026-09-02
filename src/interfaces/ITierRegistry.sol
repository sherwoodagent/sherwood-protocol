// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ITierRegistry {
    function tierOf(address target, bytes4 selector) external view returns (uint8 tier, uint16 boundBps);
    /// @notice May RECEIVE vault funds through a governor batch — the spender /
    ///         recipient axis (`_guardBatchCalls` PART 2b). The STRONG grant.
    /// @dev    No longer answers "may be named as a batch callee": that is
    ///         `isCallableTarget`, split out per pashov finding #14 so a
    ///         demotion can revoke the right to be PAID without revoking the
    ///         vault's ability to RECLAIM from the address already holding its
    ///         capital.
    function isAdapterAllowed(address adapter) external view returns (bool);
    /// @notice May be named as a CALLEE in a governor batch (`_guardBatchCalls`
    ///         PART 2a). Implied by `isAdapterAllowed` at grant time and
    ///         deliberately OUTLIVING it through a demotion — see
    ///         `TierRegistry.isCallableTarget`. Confers no right to receive value.
    function isCallableTarget(address target) external view returns (bool);
    /// @notice May be bound by a certified strategy template as a lending
    ///         market, position manager or collateral token — and approved by
    ///         it from inside that template's own reviewed code. The WEAK
    ///         grant: implied by `isAdapterAllowed` and implying none of it.
    /// @dev    Weak means "not reachable from proposer-authored batch calldata",
    ///         NOT "never receives funds" — a bound counterparty is approved by
    ///         the template that bound it.
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
    /// @notice The code class `target` currently belongs to — non-zero iff its
    ///         codehash is the ERC-1167 clone of a certified template whose own
    ///         code has not drifted. `bytes32(0)` for everything else.
    /// @dev    Read by `SyndicateVault._requireRecipientVaultBinding` (SHE-209):
    ///         a class member must name the paying vault as its `vault()`.
    ///         Deliberately the SAME `_classOf` the `isAdapterAllowed` class
    ///         fallback uses, so `classOf(x) != 0` is exactly "the class path is
    ///         what can admit `x`". A registry stand-in with no class concept
    ///         returns `bytes32(0)`.
    function classOf(address target) external view returns (bytes32);
}
