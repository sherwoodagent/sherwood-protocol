// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./ISyndicateGovernor.sol";

/**
 * @title IProposalStatus
 * @notice The proposal-status view the vault consumes from governance — the
 *         ENTIRE surface the vault may learn from the governor. Selector-
 *         compatible with `SyndicateGovernor` (same names/params), so the
 *         governor satisfies this interface without any change; a test fake
 *         satisfies it in ~10 lines (see `test/mocks/MockProposalStatus.sol`).
 *
 *   Deepening rationale: the vault previously type-cast to the full
 *   `ISyndicateGovernor` (43 functions) while reading exactly these three
 *   things. Narrowing the declared dependency concentrates the seam — "what
 *   can the vault possibly learn from governance" is now answerable from this
 *   file alone, and vault tests satisfy one small adapter instead of mocking
 *   governor selectors by hand.
 *
 * @dev `getProposal` returns `ISyndicateGovernor.StrategyProposal` — a
 *      type-only import (the vault reads just `.strategy` from it). The
 *      functional dependency remains these three selectors.
 */
interface IProposalStatus {
    /// @notice Id of the proposal currently binding the vault (0 = none).
    function getActiveProposal() external view returns (uint256);

    /// @notice Count of non-terminal proposals (Pending..Executed). Nonzero ⇒
    ///         instant deposits are gated (see vault `_depositsLocked`).
    function openProposalCount() external view returns (uint256);

    /// @notice Full proposal record; the vault reads only `.strategy`.
    function getProposal(uint256 proposalId) external view returns (ISyndicateGovernor.StrategyProposal memory);
}
