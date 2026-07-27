// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ICompensationEscrow
/// @notice Snapshot-gated victim compensation for the guardian
///         economic-security model (spec 2026-07-22 §3.8). Slash proceeds fund
///         per-case claims payable ONLY to holders of record at a pre-drain
///         snapshot, so a coalition that drains and then accumulates shares
///         from exiting holders recoups nothing (finding F1).
interface ICompensationEscrow {
    error NotAuthorizedFunder();
    error SnapshotNotPast();
    error NothingToCompensate();
    error EmptySnapshot();
    error NoClaim();
    error AlreadyRedeemed();
    error ResidueWindowOpen();
    error CaseNotFound();
    error InvalidWindow();
    error ZeroAddress();
    error BackstopIsVault();

    event CaseOpened(
        uint256 indexed caseId, address indexed vault, uint256 indexed snapshotTimestamp, uint256 proceeds
    );
    event ClaimRedeemed(uint256 indexed caseId, address indexed holder, uint256 amount);
    event ResidueSwept(uint256 indexed caseId, address indexed backstop, uint256 amount);
    event AuthorizedFunderSet(address indexed oldFunder, address indexed newFunder);
    event BackstopSet(address indexed oldBackstop, address indexed newBackstop);
    event ResidueWindowSet(uint256 oldWindow, uint256 newWindow);

    function openCase(address vault, uint256 snapshotTimestamp, uint256 proceeds) external returns (uint256 caseId);
    function redeem(uint256 caseId) external returns (uint256 amount);
    function sweepResidue(uint256 caseId) external returns (uint256 amount);

    /// @notice What `holder` may still redeem from `caseId`.
    /// @dev Pro-rata against the case's pinned snapshot:
    ///      `proceeds * getPastVotes(holder, snap) / getPastTotalSupply(snap)`,
    ///      rounded down and CAPPED at the case's own unpaid remainder
    ///      (`proceeds - redeemed`) so a case can never pay out of a sibling
    ///      case's funds. Returns 0 once redeemed or swept.
    ///
    /// @dev CLAIM BASIS (decision D1) — integrators read this: apportionment
    ///      uses the vault's ERC20Votes CHECKPOINTS, not raw balances, because
    ///      Solidity keeps no historical balance. `SyndicateVault._update`
    ///      auto-delegates EVERY receipt (mint and plain transfer), so
    ///      `getPastVotes(h, t)` equals h's balance for any holder that never
    ///      delegated away; the withdrawal queue pays its custody claim through
    ///      to request owners via `claimCompensation`. On a LIVE upgraded
    ///      vault, a holder whose last receipt predates the upgrade and who
    ///      received only by transfer stays undelegated until its next receipt.
    ///
    /// @dev KNOWN OPEN F1 RECOUPMENT CHANNEL: a holder that explicitly
    ///      delegated has its compensation credited to the DELEGATE, not to
    ///      itself. Delegation is free and permissionless, so a coalition can
    ///      solicit delegations pre-drain and collect the delegating cohort's
    ///      compensation. Closed by Plan D/E or a balance checkpoint — see the
    ///      threat model in `CompensationEscrow`'s contract natspec and spec
    ///      §3.8.
    function claimable(uint256 caseId, address holder) external view returns (uint256);
    function caseOf(uint256 caseId)
        external
        view
        returns (
            address vault,
            uint256 snapshotTimestamp,
            uint256 proceeds,
            uint256 redeemed,
            uint256 openedAt,
            uint256 residueWindowAtOpen,
            bool swept
        );

    /// @notice `openedAt + residueWindowAtOpen` for `caseId` — the instant
    ///         `sweepResidue` becomes callable. Reverts `CaseNotFound` for an
    ///         unopened case.
    function deadlineOf(uint256 caseId) external view returns (uint256);
    function totalEscrowed() external view returns (uint256);

    /// @notice The payout token. Exposed so a claimant contract (the withdrawal
    ///         queue's `claimCompensation`) can measure what it actually
    ///         received rather than trusting the escrow's own reporting.
    function wood() external view returns (IERC20);

    function setAuthorizedFunder(address funder) external;
    function setBackstop(address backstop) external;
    function setResidueWindow(uint256 window) external;
}
