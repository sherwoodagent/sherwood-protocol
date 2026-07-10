// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal governor mock exposing the surface consumed by
///         GuardianRegistry: `getActiveProposal(address)` for owner-unstake
///         gating, and `getProposal(uint256)` returning the review-window
///         timestamps consumed by `openReview` / `voteOnProposal` /
///         `resolveReview`. The returned struct matches the shape of
///         `IGovernorMinimal.ProposalView` defined inside GuardianRegistry.
contract MockGovernorMinimal {
    struct ProposalView {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
    }

    uint256 public _activeProposal;
    mapping(uint256 => ProposalView) internal _proposals;
    /// @dev Per-vault governor: single vault, single open-proposal counter.
    uint256 public _openProposalCount;

    function setActiveProposal(address, uint256 proposalId) external {
        _activeProposal = proposalId;
    }

    /// @dev Test helper — mirrors `SyndicateGovernor.openProposalCount()`
    ///      which StakedWood consults in `requestUnstakeOwner`.
    function setOpenProposalCount(address, uint256 n) external {
        _openProposalCount = n;
    }

    function getActiveProposal() external view returns (uint256) {
        return _activeProposal;
    }

    function openProposalCount() external view returns (uint256) {
        return _openProposalCount;
    }

    /// @dev Sets a proposal with no associated vault. Used by tests that only
    ///      exercise the non-emergency review path.
    function setProposal(uint256 proposalId, uint256 voteEnd, uint256 reviewEnd) external {
        _proposals[proposalId] = ProposalView({voteEnd: voteEnd, reviewEnd: reviewEnd, vault: address(0)});
    }

    /// @dev Sets a proposal with an associated vault for emergency-review tests
    ///      that need `_slashOwner` to resolve the vault address.
    function setProposalWithVault(uint256 proposalId, uint256 voteEnd, uint256 reviewEnd, address vault) external {
        _proposals[proposalId] = ProposalView({voteEnd: voteEnd, reviewEnd: reviewEnd, vault: vault});
    }

    function getProposal(uint256 proposalId) external view returns (ProposalView memory) {
        return _proposals[proposalId];
    }

    /// @dev Mirrors `GuardianRegistry.IGovernorMinimal.getProposalView` (Task 25).
    ///      Registry calls this via the `IGovernorMinimal` interface to read the
    ///      narrow review-window struct without pulling in the full governor ABI.
    function getProposalView(uint256 proposalId) external view returns (ProposalView memory) {
        return _proposals[proposalId];
    }
}
