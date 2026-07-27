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
/// @dev    Kept under the legacy file/interface name to avoid churning every
///         factory/vault reference; functionally this is the "VaultRequestQueue"
///         from the spec (gains deposit-side + frozen settlement price).
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
    error NotCompensationCase();
    error NothingToClaim();
    /// @dev `claimCompensation` ran with no escrow wired on the factory
    ///      (`ISyndicateFactory.compensationEscrow() == address(0)`).
    error CompensationEscrowNotSet();
    /// @dev `claimCompensation` ran with an empty `requestIds` array. Pulling a
    ///      case without distributing any of it leaves WOOD idling in the queue
    ///      (PR #24 review 🔴N1).
    error NoRequestsSupplied();

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
        /// @dev Custody interval stamps (PR #24 review 🔴1): `queuedAt` when the
        ///      escrowed amount entered custody, `closedAt` when it left (claim
        ///      or cancel; 0 while still open). `claimCompensation` uses these
        ///      to decide whether a redeem request's shares were in queue
        ///      custody at a compensation case's snapshot.
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
    /// @param token The payout token PINNED to this case at pull time. Every
    ///        later payout for the case uses it, so the unit a case was measured
    ///        in can never change under it (PR #24 review 🔴N1).
    event CompensationPulled(
        address indexed escrow, uint256 indexed caseId, uint256 amount, uint256 votesAtSnapshot, address token
    );
    event CompensationPaid(
        address indexed escrow, uint256 indexed caseId, uint256 indexed requestId, address owner, uint256 amount
    );
    /// @notice A supplied request id was passed over instead of reverting the
    ///         batch (PR #24 review 🟡N7): already paid for this case, not a
    ///         redeem, or not in queue custody at the case snapshot.
    event CompensationSkipped(address indexed escrow, uint256 indexed caseId, uint256 indexed requestId);

    // ── Vault-only mutating ──
    function queueRedeem(address owner, uint256 shares, uint256 pid) external returns (uint256 requestId);
    function queueDeposit(address owner, uint256 assets, uint256 pid) external returns (uint256 requestId);
    function stampSettlement(uint256 pid, uint256 num, uint256 den) external;

    // ── Permissionless / owner ──
    function claim(uint256 requestId) external returns (uint256 outAmount);
    function cancel(uint256 requestId) external;

    /// @notice Pay a compensation-escrow case through to redeem-request owners
    ///         whose shares sat in queue custody at the case's snapshot
    ///         (PR #24 review 🔴1: the queue is the holder of record the escrow
    ///         sees; without this the modal victims — LPs whose exit was queued
    ///         when the drain landed — would be paid nothing). First call for a
    ///         case pulls the queue's whole claim (amount MEASURED by balance
    ///         delta, never trusted from the escrow); each request in
    ///         `requestIds` then receives `pulled * shares / queueVotesAtSnap`.
    ///         Permissionless: payout destinations are the requests' own owners.
    /// @dev The escrow is resolved from the factory
    ///      (`ISyndicateFactory.compensationEscrow()`), NOT supplied by the
    ///      caller (PR #24 review 🔴N1) — a caller-chosen escrow controls the
    ///      payout TOKEN, which let an attacker book a case total in a token
    ///      they mint freely and collect it in real WOOD.
    /// @dev Ineligible / already-paid ids are SKIPPED, not reverted (🟡N7), so
    ///      one front-run claim cannot grief a keeper's whole batch.
    /// @return paid Total tokens transferred by this call.
    /// @return processed Ids newly credited by this call.
    /// @return skipped Ids passed over (ineligible, wrong kind, already paid).
    function claimCompensation(uint256 caseId, uint256[] calldata requestIds)
        external
        returns (uint256 paid, uint256 processed, uint256 skipped);

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
