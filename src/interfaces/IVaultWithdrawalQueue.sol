// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IVaultRequestQueue
/// @notice Interface for the async request queue paired with `SyndicateVault`
///         (Lane B of the V2 live-NAV design). While a strategy proposal is
///         active (`redemptionsLocked() == true`) LPs escrow exits (shares) and
///         entries (assets) here instead of transacting against an unrealized
///         mid-flight NAV. At settlement the vault stamps ONE frozen price per
///         proposal (`num/den` = realized NAV checkpoint); every request tagged
///         to that proposal then claims at that single, un-front-runnable price.
/// @dev    Functionally this is the "VaultRequestQueue" from the spec, kept
///         under the legacy `IVaultWithdrawalQueue` name.
interface IVaultWithdrawalQueue {
    // ── Errors ──
    error NotVault();
    error NotQueueOwner();
    error AlreadyClaimed();
    error AlreadyCancelled();
    error RequestNotFound();
    error VaultLocked();
    error NotSettled();
    error AlreadySettled();
    error ZeroShares();
    error ZeroAssets();
    error InsufficientShares();
    error WrongKind();

    // ── Types ──
    enum RequestKind {
        Redeem, // escrow shares, claim assets at frozen price
        Deposit // escrow assets, claim shares at frozen price
    }

    struct Request {
        address owner; // recipient of proceeds (shares on deposit, assets on redeem)
        uint256 amount; // Redeem: shares escrowed; Deposit: assets escrowed
        uint256 pid; // proposal active when queued — frozen-price lookup key
        RequestKind kind;
        bool claimed;
        bool cancelled;
        /// @dev Custody interval stamps: `queuedAt` when the
        ///      escrowed amount entered custody, `closedAt` when it left (claim
        ///      or cancel; 0 while still open). Their original consumer — the
        ///      compensation pay-through — is gone with the escrow; they are
        ///      retained as request-lifecycle provenance for indexers.
        uint48 queuedAt;
        uint48 closedAt;
    }

    /// @notice Frozen settlement price for a proposal, stamped at settle.
    ///         `num/den` is the vault's realized assets-per-share at settle,
    ///         carrying the ERC-4626 virtual offsets (num = totalAssets+1,
    ///         den = totalSupply + 10**offset) so the queue reproduces the
    ///         vault's own conversion rounding exactly.
    struct SettlePrice {
        uint256 num;
        uint256 den;
        bool stamped;
    }

    // ── Events ──
    event RedeemQueued(uint256 indexed requestId, address indexed owner, uint256 shares, uint256 indexed pid);
    event DepositQueued(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 indexed pid);
    event RequestClaimed(uint256 indexed requestId, address indexed owner, uint256 inAmount, uint256 outAmount);
    event RequestCancelled(uint256 indexed requestId, address indexed owner);
    event SettlementStamped(uint256 indexed pid, uint256 num, uint256 den);

    // ── Vault-only mutating ──
    function queueRedeem(address owner, uint256 shares, uint256 pid) external returns (uint256 requestId);
    function queueDeposit(address owner, uint256 assets, uint256 pid) external returns (uint256 requestId);
    function stampSettlement(uint256 pid, uint256 num, uint256 den) external;

    // ── Permissionless / owner ──
    function claim(uint256 requestId) external returns (uint256 outAmount);
    function cancel(uint256 requestId) external;

    // ── Views ──
    function vault() external view returns (address);
    function getRequest(uint256 requestId) external view returns (Request memory);
    function getSettlePrice(uint256 pid) external view returns (SettlePrice memory);
    function pendingShares() external view returns (uint256);
    function pendingDepositAssets() external view returns (uint256);
    function reservedAssets() external view returns (uint256);
    function getRequestsByOwner(address owner_) external view returns (uint256[] memory);
    function nextRequestId() external view returns (uint256);
}
