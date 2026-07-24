// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal governor mock exposing the surface StakedWood consumes for
///         owner-unstake gating: `getActiveProposal()` and
///         `openProposalCount()`. The review-window / vault plumbing that used
///         to feed the registry's removed `getProposalView` call-back is gone —
///         the registry now reads windows from `registerReview` state and the
///         vault from `vaultOf` (both wired directly in the tests).
contract MockGovernorMinimal {
    uint256 public _activeProposal;
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
}
