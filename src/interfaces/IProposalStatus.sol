// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IProposalStatus
 * @notice The proposal-status view the vault consumes from governance — the
 *         ENTIRE surface the vault may learn from the governor. Selector-
 *         compatible with `SyndicateGovernor` (same names/params), so the
 *         governor satisfies this interface without any change; a test fake
 *         satisfies it in ~10 lines (see `test/mocks/MockProposalStatus.sol`).
 *
 *   Narrowing the declared dependency to these three functions concentrates
 *   the seam — "what can the vault possibly learn from governance" is
 *   answerable from this file alone, and vault tests satisfy one small
 *   adapter instead of mocking governor selectors by hand.
 *
 * @dev Every member is a scalar, so this file has no type dependency on
 *      `ISyndicateGovernor` at all — the seam is exactly these three
 *      selectors and nothing else.
 */
interface IProposalStatus {
    /// @notice Id of the proposal currently binding the vault (0 = none).
    function getActiveProposal() external view returns (uint256);

    /// @notice Count of non-terminal proposals (Pending..Executed). Nonzero ⇒
    ///         instant deposits are gated (see vault `depositsLocked`).
    function openProposalCount() external view returns (uint256);

    /// @notice Strategy adapter of a proposal (address(0) = none / opted out of
    ///         live NAV). A scalar — it cannot drift in shape, so callers need
    ///         no defensive try/catch.
    function strategyOf(uint256 proposalId) external view returns (address);
}
