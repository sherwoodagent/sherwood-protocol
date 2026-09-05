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
    /// @notice `stampSettlement` called with a pid below the highest already
    ///         stamped. `_lastStampedPid` is a high-water mark that `claim` and
    ///         `cancel` use as exact complements, so a backwards stamp would
    ///         hold both exits open for the same deposit.
    error StampOutOfOrder();
    error ZeroShares();
    /// @notice `claimRemainder` was called on a Deposit request. The junior leg
    ///         exists only for redeemers, who are the party a float-only stamp
    ///         under-pays.
    error NotRedeemRequest();
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
    /// @notice Assets arrived here on behalf of `pid`'s redeem cohort — their
    ///         share of value a settled strategy delivered late.
    event CohortCredited(uint256 indexed pid, uint256 assets);
    /// @notice A redeemer took their pro-rata slice of what has arrived for
    ///         their cohort so far. Repeatable as more arrives.
    event RemainderClaimed(uint256 indexed requestId, address indexed owner, uint256 assets);
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

    /// @notice Escrowed redeem shares whose settle price is already stamped but
    ///         which have not been claimed. The share-side counterpart of
    ///         `reservedAssets`, and the set the vault excludes from pricing.
    /// @dev    A strict subset of `pendingShares`: pre-stamp escrowed shares
    ///         still float with the pool and belong in the price, because their
    ///         payout is not fixed yet.
    function stampedUnclaimedShares() external view returns (uint256);

    // ── The junior leg: a redeem cohort's share of value that arrived late ──
    //
    // A proposal can settle while its strategy still holds value the market
    // could not release. The settle stamp is computed from float alone, so a
    // redeemer claiming against it leaves their share of that residue behind and
    // it accrues to the LPs who stayed — no attacker, no loss to the protocol, a
    //
    // The stamp stays the SENIOR floor: fully backed, always payable, unchanged.
    // What follows is a JUNIOR claim on real assets as they actually arrive,
    // never on an estimate of what might. If nothing arrives the redeemer keeps
    // the floor, which is exactly today's outcome — so this can only pay more,
    // and can never strand.

    /// @notice Vault-only: book `assets` as belonging to `pid`'s redeem cohort.
    ///         The vault transfers them here immediately before calling.
    function creditCohort(uint256 pid, uint256 assets) external;

    /// @notice Permissionless: pay a redeemer their pro-rata slice of what has
    ///         arrived for their cohort, less what they have already taken.
    /// @dev    Repeatable as more arrives; a zero balance is a no-op rather than
    ///         a revert, so no caller can be griefed into failure.
    /// @return owed Assets paid out by this call.
    function claimRemainder(uint256 requestId) external returns (uint256 owed);

    /// @notice `pid`'s redeem-share count and pricing denominator, both FROZEN
    ///         at its stamp. The fraction an arrival is split by.
    /// @dev    The vault reads this to size the cohort's slice; it deliberately
    ///         does not keep its own copy, so there is one denominator and it
    ///         lives with the requests it describes.
    function cohortOf(uint256 pid) external view returns (uint256 shares, uint256 den);

    /// @notice What `requestId` could claim from its cohort's arrivals right now.
    function claimableRemainder(uint256 requestId) external view returns (uint256);

    /// @notice Assets held here for redeem cohorts and payable to no one else —
    ///         the redeem-side complement of `pendingDepositAssets`.
    function cohortAssets() external view returns (uint256);
    function getRequestsByOwner(address owner_) external view returns (uint256[] memory);
    function nextRequestId() external view returns (uint256);
}
