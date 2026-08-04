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
    function getActiveProposal() external pure returns (uint256) {
        return 1;
    }

    function strategyOf(uint256) external view returns (address) {
        return msg.sender;
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
