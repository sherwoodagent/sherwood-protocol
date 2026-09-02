// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Test-only, DELIBERATELY PERMISSIVE governor stand-in for strategy
///         suites that exercise `BaseStrategy`-derived math (execute/settle/
///         rebalance), not the clone-ratchet proposal-binding property itself
///         (issue #150, `BaseStrategy.execute()`'s `NotActiveProposalStrategy`
///         check). `strategyOf` answers `msg.sender` regardless of `pid` —
///         "whoever is asking is the active proposal's strategy" — so every
///         existing math/lifecycle scenario in `PortfolioStrategy.t.sol`
///         keeps exercising exactly what it always exercised, without
///         per-call-site proposal wiring.
/// @dev    NEVER use this for a test that is actually about the binding check
///         itself — those need precise, non-permissive wiring. See
///         `test/audit-fixes/Strategy_cloneRatchetBinding.t.sol` and
///         `test/mocks/MockProposalStatus.sol` (the real governor's and
///         vault's own `IProposalStatus` seam).
contract MockGovernorAlwaysActive {
    /// @notice Second hop of the binding walk `vault() → governor() →
    ///         tierRegistry()`. Defaults to `address(0)`.
    /// @dev    `PortfolioStrategy._initialize` is fail-closed on registry
    ///         resolution, so any suite whose strategies must reach init has
    ///         to point this at a registry. Left zero by default so this stub
    ///         stays inert for callers that only need the `strategyOf` seam.
    address public tierRegistry;

    function setTierRegistry(address registry) external {
        tierRegistry = registry;
    }

    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
    }
}

/// @notice Permissive tier-registry stand-in: allows every adapter and price
///         source, and attests every token↔price-source pairing.
/// @dev    For suites that are about strategy math, not about governance
///         binding — it gets them past `_initialize`'s fail-closed registry
///         resolution without each one hand-rolling a registry. A suite that
///         is actually testing the binding needs precise, non-permissive
///         wiring instead (see `PortfolioStrategyAdapterAllowlist.t.sol`).
contract MockPermissiveTierRegistry {
    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    /// @dev SHE-209: no class concept in this stand-in — every address is a
    ///      non-member, so the vault's class-binding check never fires.
    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }

    /// @dev Callee axis (pashov finding #14). Permissive like its sibling —
    ///      fixtures using this mock are resolving the binding path, not
    ///      exercising the demotion asymmetry.
    function isCallableTarget(address) external pure returns (bool) {
        return true;
    }

    function isPriceSourceForToken(address, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @notice Minimal vault stand-in exposing only `governor()` — the one hop
///         `BaseStrategy.execute()` reads off `vault()`. Mirrors
///         `MockVaultWithGovernor` (declared locally in
///         `PortfolioStrategyAdapterAllowlist.t.sol`, which pairs it with a
///         DIFFERENT, non-permissive governor mock, `MockGovernorWithRegistry`,
///         so that file keeps its own copy rather than importing this one).
contract MockVaultGovernorStub {
    address public governor;

    /// @dev `BaseStrategy.onlyProposer` re-checks the vault's live agent set on
    ///      every proposer-gated call, so a vault stub must answer `isAgent` or
    ///      every `rebalance` / `rebalanceDelta` / `updateParams` fails closed.
    ///      Stored inverted so the zero-value default is "still an agent" — the
    ///      ordinary case — with `setAgent(a, false)` for tests that want the
    ///      revoked-agent path.
    mapping(address => bool) internal _revoked;

    constructor(address governor_) {
        governor = governor_;
    }

    function isAgent(address a) external view returns (bool) {
        return !_revoked[a];
    }

    function setAgent(address a, bool allowed) external {
        _revoked[a] = !allowed;
    }
}
