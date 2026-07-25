// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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

    function claimable(uint256 caseId, address holder) external view returns (uint256);
    function caseOf(uint256 caseId)
        external
        view
        returns (address vault, uint256 snapshotTimestamp, uint256 proceeds, uint256 redeemed, uint256 openedAt);
    function totalEscrowed() external view returns (uint256);

    function setAuthorizedFunder(address funder) external;
    function setBackstop(address backstop) external;
    function setResidueWindow(uint256 window) external;
}
