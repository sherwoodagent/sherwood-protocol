// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultWithdrawalQueue} from "../interfaces/IVaultWithdrawalQueue.sol";
import {ICompensationEscrow} from "../interfaces/ICompensationEscrow.sol";
import {ISyndicateFactory} from "../interfaces/ISyndicateFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IRequestableVault {
    function asset() external view returns (address);
    function redemptionsLocked() external view returns (bool);
    /// @notice Queue-only: burn `shares` escrowed here and pay `assets` to `to`.
    function settleRedeem(uint256 shares, uint256 assets, address to) external;
    /// @notice Queue-only: mint `shares` to `to`. Assets were pushed to the
    ///         vault by the queue immediately before this call.
    function settleDeposit(uint256 shares, address to) external;
    /// @notice ERC20Votes read — the queue's own checkpointed custody balance
    ///         at a compensation case's snapshot (pay-through denominator).
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    /// @notice The factory that deployed this vault (and this queue). Source of
    ///         the governance-set compensation escrow — read live, so one
    ///         factory call arms every queue.
    function factory() external view returns (address);
}

/// @title VaultWithdrawalQueue (Lane B async request substrate)
/// @notice Per-vault queue for mid-proposal LP flow. Redeems escrow shares and
///         deposits escrow assets while a proposal is active; at settlement the
///         vault stamps one frozen price per proposal and each request claims
///         at that single realized price — the entire mid-flight price
///         manipulation surface is deleted (the vault never mints/burns against
///         an unrealized, strategy-influenced NAV).
///
///         Lifecycle:
///           REDEEM:  vault.requestRedeem → queueRedeem (shares escrowed here)
///                    [settle → stampSettlement] → claim → vault.settleRedeem
///           DEPOSIT: vault.requestDeposit → queueDeposit (assets escrowed here)
///                    [settle → stampSettlement] → claim → vault.settleDeposit
///
///         `cancel` is allowed ONLY before the request's proposal is stamped:
///         once a settle price is frozen, post-settle cancel would be a free
///         look-back option, so the request must be claimed.
contract VaultWithdrawalQueue is IVaultWithdrawalQueue, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable override vault;

    Request[] private _requests; // index 0 unused (sentinel)
    mapping(address => uint256[]) private _byOwner;
    mapping(uint256 pid => SettlePrice) private _settlePrice;
    /// @dev The pid of the most recent `stampSettlement`. Deposit claims price
    ///      against THIS rather than the pid their request was tagged to — see
    ///      the rationale in `claim`. Redeem claims deliberately keep their own
    ///      pid's price, because their shares left the supply at that settlement
    ///      and `_pidReserved` is denominated against it.
    uint256 private _lastStampedPid;
    /// @notice Redeem shares still queued per proposal. Incremented at
    ///         `queueRedeem`, decremented at `cancel` (pre-stamp) and at `claim`
    ///         (post-stamp). Reaching 0 after stamp means the proposal is fully
    ///         claimed → its remaining `_pidReserved` dust is released.
    mapping(uint256 pid => uint256) private _pidRedeemShares;
    /// @notice Assets reserved for a proposal at stamp time
    ///         (`mulDiv(totalRedeemShares, num, den)`). Decremented as that
    ///         proposal's redeems are claimed; the claim that empties the
    ///         proposal's shares releases whatever remains, so the aggregate
    ///         reserve (`floor(Σ·num/den)`) is released in full and never leaves
    ///         phantom dust — `floor(Σ) ≥ Σfloor`, so per-request payouts alone
    ///         would strand `floor(Σ)−Σfloor` wei of reserve forever.
    mapping(uint256 pid => uint256) private _pidReserved;

    uint256 private _pendingShares; // escrowed redeem shares (not yet claimed/cancelled)
    uint256 private _pendingDepositAssets; // escrowed deposit assets
    uint256 private _reservedAssets; // frozen assets owed to stamped-unclaimed redeems

    /// @dev One pulled compensation-escrow case. `total` is what the escrow
    ///      ACTUALLY transferred here (balance-delta measured), `votes` the
    ///      queue's checkpointed custody balance at the case snapshot — the
    ///      pay-through denominator. Keyed by (escrow, caseId) so a case funded
    ///      by one escrow can never be paid out of another's bookkeeping after
    ///      a governance re-point.
    ///
    ///      `token` PINS the unit `total` was measured in. `total` is a scalar;
    ///      re-reading `escrow.wood()` on a later call would denominate the
    ///      payout in whatever the escrow reports THEN, so an escrow whose
    ///      token changed between the pull and the payout would hand out a
    ///      balance it never contributed. Measured once, paid in the same unit
    ///      forever.
    struct CompCase {
        uint256 total;
        uint256 votes;
        uint256 snapshotTimestamp;
        address token;
        bool pulled;
    }

    mapping(address escrow => mapping(uint256 caseId => CompCase)) private _compCases;
    mapping(address escrow => mapping(uint256 caseId => mapping(uint256 requestId => bool))) private _compClaimed;

    constructor(address vault_) {
        if (vault_ == address(0)) revert NotVault();
        vault = vault_;
        _requests.push(); // sentinel slot at index 0
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    // ── Queueing (vault-only) ──

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev Called by `vault.requestRedeem` after it transferred `shares` into
    ///      this contract's custody (escrowed, not burned).
    function queueRedeem(address owner_, uint256 shares, uint256 pid) external onlyVault returns (uint256 id) {
        if (shares == 0) revert ZeroShares();
        id = _push(owner_, shares, pid, RequestKind.Redeem);
        _pendingShares += shares;
        _pidRedeemShares[pid] += shares;
        emit RedeemQueued(id, owner_, shares, pid);
    }

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev Called by `vault.requestDeposit` after it transferred `assets` into
    ///      this contract's custody (escrowed off-vault so they never inflate
    ///      `totalAssets` / are never swept into the strategy — resolves the
    ///      concurrent-exit over-promise).
    function queueDeposit(address owner_, uint256 assets, uint256 pid) external onlyVault returns (uint256 id) {
        if (assets == 0) revert ZeroAssets();
        id = _push(owner_, assets, pid, RequestKind.Deposit);
        _pendingDepositAssets += assets;
        emit DepositQueued(id, owner_, assets, pid);
    }

    function _push(address owner_, uint256 amount, uint256 pid, RequestKind kind) private returns (uint256 id) {
        id = _requests.length;
        _requests.push(
            Request({
                owner: owner_,
                amount: amount,
                pid: pid,
                kind: kind,
                claimed: false,
                cancelled: false,
                queuedAt: uint48(block.timestamp),
                closedAt: 0
            })
        );
        _byOwner[owner_].push(id);
    }

    // ── Settlement price stamp (vault-only) ──

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev Called once by `vault.onProposalSettled` when proposal `pid` settles.
    ///      Freezes the realized assets-per-share (`num/den`) and reserves the
    ///      asset amount owed to that proposal's queued redeems so a later
    ///      proposal's execution cannot strand them.
    function stampSettlement(uint256 pid, uint256 num, uint256 den) external onlyVault {
        SettlePrice storage sp = _settlePrice[pid];
        if (sp.stamped) revert AlreadySettled();
        sp.num = num;
        sp.den = den;
        sp.stamped = true;
        _lastStampedPid = pid;
        uint256 redeemShares = _pidRedeemShares[pid];
        if (redeemShares != 0 && den != 0) {
            uint256 reservedForPid = Math.mulDiv(redeemShares, num, den);
            _pidReserved[pid] = reservedForPid;
            _reservedAssets += reservedForPid;
        }
        emit SettlementStamped(pid, num, den);
    }

    // ── Claim / cancel ──

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev Claimable once the request's proposal is stamped AND the vault is
    ///      unlocked (no active proposal) — deposit-claim assets must not land
    ///      mid-proposal (they would mis-count as strategy profit) and
    ///      redeem-claim float is only guaranteed available between proposals.
    function claim(uint256 requestId) external nonReentrant returns (uint256 outAmount) {
        Request storage r = _req(requestId);
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        SettlePrice memory sp = _settlePrice[r.pid];
        if (!sp.stamped) revert NotSettled();
        if (IRequestableVault(vault).redemptionsLocked()) revert VaultLocked();

        r.claimed = true;
        r.closedAt = uint48(block.timestamp);
        uint256 amount = r.amount;

        if (r.kind == RequestKind.Redeem) {
            // assets = shares * num / den (matches ERC-4626 convertToAssets at settle)
            outAmount = Math.mulDiv(amount, sp.num, sp.den);
            _pendingShares -= amount;
            // Release reserve against the proposal's stamped aggregate, not the
            // per-request payout, so the claim that empties the proposal's shares
            // frees the whole remainder (incl. the floor(Σ)−Σfloor rounding dust).
            // Otherwise that dust accumulates across proposals until
            // `reservedAssets` exceeds the vault float that backs the true
            // claimable, over-restricting flows and eventually bricking
            // `executeGovernorBatch`.
            uint256 remainingShares = _pidRedeemShares[r.pid] - amount;
            _pidRedeemShares[r.pid] = remainingShares;
            uint256 release;
            if (remainingShares == 0) {
                release = _pidReserved[r.pid]; // final claim: free the entire remainder
                _pidReserved[r.pid] = 0;
            } else {
                release = outAmount; // partial floors always sum below the aggregate → no underflow
                _pidReserved[r.pid] -= outAmount;
            }
            uint256 reserved = _reservedAssets;
            _reservedAssets = reserved > release ? reserved - release : 0;
            IRequestableVault(vault).settleRedeem(amount, outAmount, r.owner);
        } else {
            // PRICED AT THE LATEST SETTLEMENT, not at the request's own pid.
            //
            // A queued deposit has no claim deadline and `cancel` shuts once its
            // proposal stamps, so waiting is strictly free. Pricing at the
            // request's frozen pid therefore handed the depositor a perpetual
            // look-back call on the vault's NAV: hold the request, watch the
            // next proposal settle, and claim only when the OLD price mints
            // more shares — diluting incumbents by the difference, repeatably,
            // and across several requests at once by exercising only the
            // favourable ones.
            //
            // The escrowed assets sat in this contract the whole time and never
            // entered the strategy, so the honest price is the one prevailing
            // when they actually join the pool. Claims are already confined to
            // the gap between proposals (`redemptionsLocked` above), and in that
            // gap the current share price IS the latest stamp. With no later
            // settlement this is the request's own pid and nothing changes.
            //
            // Redeem (above) keeps its own pid deliberately: those shares left
            // the supply at that settlement and `_pidReserved` is denominated
            // against that same price.
            SettlePrice memory dp = _settlePrice[_lastStampedPid];
            if (!dp.stamped) dp = sp; // defensive; `sp.stamped` was required above
            // shares = assets * den / num (matches ERC-4626 convertToShares at settle)
            outAmount = Math.mulDiv(amount, dp.den, dp.num);
            _pendingDepositAssets -= amount;
            // Push escrowed assets into the vault, then mint at the frozen price.
            IERC20(IRequestableVault(vault).asset()).safeTransfer(vault, amount);
            IRequestableVault(vault).settleDeposit(outAmount, r.owner);
        }
        emit RequestClaimed(requestId, r.owner, amount, outAmount);
    }

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev Cancel is allowed ONLY before the request's proposal is stamped.
    ///      Returns the escrowed shares (Redeem) or assets (Deposit) to the owner.
    function cancel(uint256 requestId) external nonReentrant {
        Request storage r = _req(requestId);
        if (msg.sender != r.owner) revert NotQueueOwner();
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        if (_settlePrice[r.pid].stamped) revert AlreadySettled();

        r.cancelled = true;
        r.closedAt = uint48(block.timestamp);
        uint256 amount = r.amount;
        if (r.kind == RequestKind.Redeem) {
            _pendingShares -= amount;
            _pidRedeemShares[r.pid] -= amount;
            IERC20(vault).safeTransfer(r.owner, amount); // shares are an ERC20 (the vault)
        } else {
            _pendingDepositAssets -= amount;
            IERC20(IRequestableVault(vault).asset()).safeTransfer(r.owner, amount);
        }
        emit RequestCancelled(requestId, r.owner);
    }

    // ── Compensation pay-through ──

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev The queue is the holder of record the compensation escrow sees for
    ///      every share sitting in custody at a case's snapshot — and
    ///      `requestRedeem` is only callable while a proposal is open, which is
    ///      exactly the window a drain occupies, so queued exiters are the
    ///      MODAL victims. This pays the queue's claim through to them.
    ///
    ///      TRUST MODEL: the escrow is resolved from governance —
    ///      `ISyndicateFactory(vault.factory()).compensationEscrow()` — and is
    ///      NOT a parameter. A caller-supplied escrow would defend only the
    ///      AMOUNT (balance-delta measured, keyed by (escrow, caseId)) and say
    ///      nothing about the UNIT: since `escrow.wood()` is re-read on every
    ///      call while `cc.total` is measured once, a caller could book a case
    ///      total in a token they mint freely, flip `wood()` to real WOOD, and
    ///      withdraw `total * shares / votes` of the queue's actual balance.
    ///
    ///      What holds:
    ///      - The escrow address is governance state, so no unrelated contract
    ///        can write `_compCases` entries or emit this queue's events.
    ///      - `total` is the measured balance delta across `redeem` — a
    ///        misbehaving escrow that reports a large `claimable` and transfers
    ///        nothing distributes nothing.
    ///      - `cc.token` pins the payout unit at pull time; every later payout
    ///        for the case reads the pin, never the escrow.
    ///      - A case must be distributed by the same call that pulls it, so
    ///        proceeds do not idle in the queue. Enforced by the `paid != 0`
    ///        check at the end (`NoEligibleRequests`) — the `NoRequestsSupplied`
    ///        length check alone is not enough, since a batch of all-skipped
    ///        ids would pull and park, and gating on `processed` instead of
    ///        `paid` would still let an all-dust batch do the same through
    ///        rounding.
    ///      - Payout destinations are the requests' own owners; the caller
    ///        chooses only WHICH requests get processed, never where funds go.
    ///      - `nonReentrant` (shared with `claim`/`cancel`) blocks the escrow's
    ///        `redeem` from re-entering queue state mid-pull.
    ///
    ///      TOKEN COMMINGLING: compensation proceeds and escrowed DEPOSIT
    ///      assets share this contract's balance sheet, so if a vault's
    ///      `asset()` is ever WOOD the two sit in one ERC-20 balance. That is
    ///      safe only because every asset path here is counter-driven
    ///      (`_pendingDepositAssets`, `_reservedAssets`) and every compensation
    ///      payout is bounded by its own case's measured `total` — no path
    ///      reads a raw `balanceOf` to decide what it may send. Any future
    ///      balance-driven path in this contract must not be added.
    ///
    ///      ELIGIBILITY: a redeem request whose custody interval
    ///      [queuedAt, closedAt) covers the snapshot. A request closed AT the
    ///      snapshot timestamp is excluded — the queue's checkpoint at that
    ///      instant no longer includes those shares (and its owner was
    ///      re-checkpointed personally at the same instant), so inclusion
    ///      would double-count against the queue's own votes.
    ///
    ///      ROUNDING: each payout floors; Σ eligible shares == the queue's
    ///      votes at the snapshot, so total payouts never exceed `total` and
    ///      sub-wei dust strands in the queue (mirrors the escrow's own
    ///      dust-to-residue policy; the queue has no rescue path by design).
    ///
    ///      RE-POINTS: this entry point only ever serves the escrow governance
    ///      points at RIGHT NOW, because it may PULL. A case pulled from a
    ///      previous escrow and only partly distributed is finished through
    ///      `distributeCompensation`, which reads the recorded pull and never
    ///      pulls.
    function claimCompensation(uint256 caseId, uint256[] calldata requestIds)
        external
        nonReentrant
        returns (uint256 paid, uint256 processed, uint256 skipped)
    {
        // Pulling a case and distributing none of it is not a use case — it
        // only parks proceeds in the queue. Require the caller to name who
        // gets paid.
        if (requestIds.length == 0) revert NoRequestsSupplied();

        address escrow = ISyndicateFactory(IRequestableVault(vault).factory()).compensationEscrow();
        if (escrow == address(0)) revert CompensationEscrowNotSet();

        CompCase storage cc = _compCases[escrow][caseId];
        if (!cc.pulled) {
            (address caseVault, uint256 snap,,,,,) = ICompensationEscrow(escrow).caseOf(caseId);
            if (caseVault != vault) revert NotCompensationCase();
            uint256 votes = IRequestableVault(vault).getPastVotes(address(this), snap);
            if (votes == 0) revert NothingToClaim();
            IERC20 pullToken = ICompensationEscrow(escrow).wood();
            uint256 balBefore = pullToken.balanceOf(address(this));
            ICompensationEscrow(escrow).redeem(caseId);
            uint256 received = pullToken.balanceOf(address(this)) - balBefore;
            if (received == 0) revert NothingToClaim();
            cc.total = received;
            cc.votes = votes;
            cc.snapshotTimestamp = snap;
            // Pin the unit alongside the scalar — see `CompCase`.
            cc.token = address(pullToken);
            cc.pulled = true;
            emit CompensationPulled(escrow, caseId, received, votes, address(pullToken));
        }

        (paid, processed, skipped) = _distribute(escrow, caseId, requestIds);
        // A call that distributes nothing must revert. The length check above
        // only proves ids were NAMED; with skip-don't-revert for ineligible
        // ids, one ineligible id could satisfy it, pull the case's entire
        // proceeds, and park them here. The gate is on `paid`, not `processed`:
        // a batch whose every eligible id floors to a zero share would
        // otherwise pull the case, mark the ids `_compClaimed`, move nothing,
        // and not revert — reachable when share supply exceeds WOOD proceeds
        // in wei (an 18-decimals-offset vault against a small recovery) with
        // dust-sized requests. The cost is that a legitimately all-dust batch
        // is unclaimable — which the rounding policy already strands by
        // design. Reverting rolls the pull back too (the escrow case stays
        // redeemable). A keeper whose whole batch was front-run loses only
        // gas: everything it named was already paid.
        if (paid == 0) revert NoEligibleRequests();
    }

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev THE RE-POINT REMAINDER PATH. `claimCompensation` books a case
    ///      under the escrow governance pointed at when the case was PULLED,
    ///      and the pull is decoupled from the distribution (a keeper batches
    ///      ids across many transactions). If governance calls
    ///      `setCompensationEscrow(B)` between the pull from A and the last
    ///      batch, every later `claimCompensation` resolves B, finds
    ///      `_compCases[B][caseId].pulled == false`, and tries to pull B's
    ///      case with the same id — a DIFFERENT case, since ids are per-escrow.
    ///      The undistributed remainder of A's case, already sitting in this
    ///      contract's balance, would be stranded forever: there is no rescue
    ///      path here by design.
    ///
    ///      WHY THE `escrow` PARAMETER IS SAFE HERE: a caller-chosen escrow is
    ///      only dangerous when it is the source of a PULL — the queue calling
    ///      `redeem`/`wood()` on a caller-named contract, with the payout UNIT
    ///      coming back from that call. Nothing of that shape survives here:
    ///      - This function NEVER pulls and makes NO call to `escrow` at all —
    ///        the address is used solely as a mapping key.
    ///      - It refuses any key whose case is not already `pulled`
    ///        (`CaseNotPulled`). `pulled` is written in exactly one place:
    ///        `claimCompensation`, after resolving the escrow from governance.
    ///        So the reachable key set is exactly {escrows governance has
    ///        pointed at} — a caller cannot introduce a new one, only select
    ///        among the ones governance already authorized.
    ///      - `total`, `votes`, `snapshotTimestamp` and `token` all come from
    ///        the pin written at pull time; the escrow is never re-read.
    ///      - Payouts still go to the requests' own owners, and each id is
    ///        `_compClaimed`-gated per (escrow, caseId), so selecting a
    ///        different (already-pulled) case cannot double-pay anyone.
    ///      The worst a caller can do is finish distributing money the queue
    ///      already holds, to the owners it is already owed to.
    ///
    ///      The `paid == 0` gate is kept even though there is no pull to roll
    ///      back: without it a caller could mark eligible-but-dust ids
    ///      `_compClaimed` while moving nothing, burning their claim.
    function distributeCompensation(address escrow, uint256 caseId, uint256[] calldata requestIds)
        external
        nonReentrant
        returns (uint256 paid, uint256 processed, uint256 skipped)
    {
        if (requestIds.length == 0) revert NoRequestsSupplied();
        // Distribute-only: the case must ALREADY have been pulled under this
        // escrow by `claimCompensation`. No pull, no external call to `escrow`.
        if (!_compCases[escrow][caseId].pulled) revert CaseNotPulled();

        (paid, processed, skipped) = _distribute(escrow, caseId, requestIds);
        if (paid == 0) revert NoEligibleRequests();
    }

    /// @dev Shared payout loop for both compensation entry points. Reads ONLY
    ///      the recorded `CompCase` — never the escrow — so it is identical
    ///      whether the case was pulled in this transaction or an earlier one
    ///      under an escrow governance has since re-pointed away from.
    function _distribute(address escrow, uint256 caseId, uint256[] calldata requestIds)
        private
        returns (uint256 paid, uint256 processed, uint256 skipped)
    {
        CompCase storage cc = _compCases[escrow][caseId];
        // Read the PINNED token, never the escrow's current answer.
        IERC20 payToken = IERC20(cc.token);
        uint256 snapTs = cc.snapshotTimestamp;
        for (uint256 i = 0; i < requestIds.length; i++) {
            uint256 id = requestIds[i];
            Request storage r = _req(id);
            // SKIP, DON'T REVERT. This is a permissionless helper meant to be
            // run by a keeper over hundreds of ids, and both rejections below
            // are front-runnable. Skipping costs the caller nothing they did
            // not already commit and is reported in `skipped`. Funds are
            // unaffected either way — payouts always go to `r.owner`. NOTE for
            // keeper authors: an OUT-OF-RANGE id still reverts the whole batch
            // (`_req` → `RequestNotFound`) — that is caller error, not
            // front-runnable state, so it stays hard.
            bool eligible = r.kind == RequestKind.Redeem
                // In custody at the snapshot: queued at-or-before it and not yet
                // claimed/cancelled by then. `queuedAt == 0` marks a request from
                // a pre-stamp queue build — its custody interval is unknowable.
                && r.queuedAt != 0 && r.queuedAt <= snapTs && (r.closedAt == 0 || r.closedAt > snapTs)
                && !_compClaimed[escrow][caseId][id];
            if (!eligible) {
                skipped++;
                emit CompensationSkipped(escrow, caseId, id);
                continue;
            }
            _compClaimed[escrow][caseId][id] = true;
            processed++;
            uint256 share = Math.mulDiv(cc.total, r.amount, cc.votes);
            if (share != 0) {
                paid += share;
                payToken.safeTransfer(r.owner, share);
                emit CompensationPaid(escrow, caseId, id, r.owner, share);
            }
        }
    }

    /// @notice Pulled-case bookkeeping for (escrow, caseId): measured proceeds,
    ///         snapshot votes (denominator), snapshot timestamp, the payout
    ///         token pinned at pull time, and the pulled flag.
    /// @dev `escrow` stays a parameter HERE — this is a read, and keeping it
    ///      lets an indexer inspect cases pulled from a previous escrow after a
    ///      governance re-point. Only the money-moving path resolves the escrow
    ///      itself.
    function compensationCase(address escrow, uint256 caseId)
        external
        view
        returns (uint256 total, uint256 votes, uint256 snapshotTimestamp, address token, bool pulled)
    {
        CompCase storage cc = _compCases[escrow][caseId];
        return (cc.total, cc.votes, cc.snapshotTimestamp, cc.token, cc.pulled);
    }

    /// @notice Whether `requestId` already received its share of (escrow, caseId).
    function compensationClaimed(address escrow, uint256 caseId, uint256 requestId) external view returns (bool) {
        return _compClaimed[escrow][caseId][requestId];
    }

    // ── Views ──

    function getRequest(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    function getSettlePrice(uint256 pid) external view returns (SettlePrice memory) {
        return _settlePrice[pid];
    }

    function pendingShares() external view returns (uint256) {
        return _pendingShares;
    }

    function pendingDepositAssets() external view returns (uint256) {
        return _pendingDepositAssets;
    }

    function reservedAssets() external view returns (uint256) {
        return _reservedAssets;
    }

    function getRequestsByOwner(address owner_) external view returns (uint256[] memory) {
        return _byOwner[owner_];
    }

    function nextRequestId() external view returns (uint256) {
        return _requests.length;
    }

    function _req(uint256 id) private view returns (Request storage) {
        if (id == 0 || id >= _requests.length) revert RequestNotFound();
        return _requests[id];
    }
}
