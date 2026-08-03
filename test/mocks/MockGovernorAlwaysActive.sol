// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Test-only, DELIBERATELY PERMISSIVE governor stand-in for strategy
///         suites that exercise `BaseStrategy`-derived math (execute/settle/
///         rebalance), not the clone-ratchet proposal-binding property itself
///         (issue #150, `BaseStrategy.execute()`'s `NotActiveProposalStrategy`
///         check). `strategyOf` answers `msg.sender` regardless of `pid` —
///         "whoever is asking is the active proposal's strategy" — so every
///         existing math/lifecycle scenario in `PortfolioStrategy.t.sol` /
///         `VeniceInferenceStrategy.t.sol` keeps exercising exactly what it
///         always exercised, without per-call-site proposal wiring.
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
///         `PortfolioStrategyAdapterAllowlist.t.sol` /
///         `VeniceInferenceStrategyAdapterAllowlist.t.sol`, which pairs it
///         with a DIFFERENT, non-permissive governor mock,
///         `MockGovernorWithRegistry`, so those files keep their own copy
///         rather than importing this one).
contract MockVaultGovernorStub {
    address public governor;

    constructor(address governor_) {
        governor = governor_;
    }
}
