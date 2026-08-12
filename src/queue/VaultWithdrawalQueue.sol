// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultWithdrawalQueue} from "../interfaces/IVaultWithdrawalQueue.sol";
import {ISyndicateFactory} from "../interfaces/ISyndicateFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

interface IRequestableVault {
    function asset() external view returns (address);
    function redemptionsLocked() external view returns (bool);
    /// @notice True while a mint must not happen — an open proposal, or a
    ///         settled strategy still holding undelivered value. The deposit
    ///         claim below refuses on this, on the same predicate the instant
    ///         path uses (finding #3).
    function depositsLocked() external view returns (bool);
    /// @notice Live assets-to-shares at the current price. The deposit claim
    ///         prices against this rather than a frozen stamp, so a residue that
    ///         has since been swept in is already reflected.
    function convertToShares(uint256 assets) external view returns (uint256);
    /// @notice Queue-only: burn `shares` escrowed here and pay `assets` to `to`.
    function settleRedeem(uint256 shares, uint256 assets, address to) external;
    /// @notice Queue-only: mint `shares` to `to`. Assets were pushed to the
    ///         vault by the queue immediately before this call.
    function settleDeposit(uint256 shares, address to) external;
    /// @notice ERC20Votes read — the queue's own checkpointed custody balance at
    ///         a past instant. Its original consumer was the compensation
    ///         pay-through's denominator, which is gone with the escrow.
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    /// @notice The factory that deployed this vault (and this queue).
    function factory() external view returns (address);
}

/// @title VaultWithdrawalQueue (Lane B async request substrate)
/// @notice Per-vault queue for mid-proposal LP flow. Redeems escrow shares and
///         deposits escrow assets while a proposal is active; at settlement the
///         vault stamps one frozen price per proposal and each request claims at
///         that single realized price, so the vault never mints or burns against
///         an unrealized, strategy-influenced NAV.
///
///         Lifecycle:
///           REDEEM:  vault.requestRedeem -> queueRedeem (shares escrowed here)
///                    [settle -> stampSettlement] -> claim -> vault.settleRedeem
///           DEPOSIT: vault.requestDeposit -> queueDeposit (assets escrowed here)
///                    [settle -> stampSettlement] -> claim -> vault.settleDeposit
///
///         `cancel` is allowed ONLY before the request's proposal is stamped:
///         once a settle price is frozen, a post-settle cancel would be a free
///         look-back option.
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
    /// @notice Escrowed redeem shares whose price is already STAMPED but which
    ///         have not been claimed — the share-side counterpart of
    ///         `_reservedAssets`, and the exact set the vault must exclude from
    ///         pricing.
    /// @dev    A STRICT SUBSET OF `_pendingShares`, and the distinction is the
    ///         whole point: pre-stamp escrowed shares still float with the pool
    ///         and belong in the price, because their payout is not fixed yet.
    ///         Only once `stampSettlement` freezes `num/den` does a share stop
    ///         being a claim on the pool and become a claim for a fixed number of
    ///         assets.
    /// @dev    NO CANCEL PATH TO UNWIND: `cancel` reverts for a stamped pid, so
    ///         once a share enters this counter the only exit is `claim`.
    uint256 private _stampedUnclaimedShares;

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
        // MONOTONIC BY ASSERTION, NOT BY ASSUMPTION. Both surviving exits key
        // off `_lastStampedPid` as a high-water mark and are exact complements
        // of each other — `claim` needs `_lastStampedPid >= r.pid`, `cancel`
        // needs its negation — so a LOWER pid stamped after a higher one would
        // make an already-claimable deposit unclaimable AND reopen its cancel
        // exit, which is precisely the costless straddle pashov #10 closed. That
        // ordering follows today from the governor's single-open-proposal
        // invariant, i.e. from another contract; nothing here enforced it, and a
        // cross-contract invariant that two local branches silently depend on is
        // the kind that survives until it doesn't.
        if (pid < _lastStampedPid) revert StampOutOfOrder();
        sp.num = num;
        sp.den = den;
        sp.stamped = true;
        _lastStampedPid = pid;
        uint256 redeemShares = _pidRedeemShares[pid];
        if (redeemShares != 0 && den != 0) {
            uint256 reservedForPid = Math.mulDiv(redeemShares, num, den);
            _pidReserved[pid] = reservedForPid;
            _reservedAssets += reservedForPid;
            // BOTH SIDES MOVE TOGETHER, always. These shares just stopped being
            // a claim on the pool and became a claim for `reservedForPid` fixed
            // assets; pricing must lose the shares at the same instant it loses
            // the assets, or the gap between the two is exactly the mispricing
            // window issue #92 describes.
            _stampedUnclaimedShares += redeemShares;
        }
        emit SettlementStamped(pid, num, den);
    }

    // ── Claim / cancel ──

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev THE TWO KINDS ARE GATED ON DIFFERENT QUESTIONS, deliberately.
    ///
    ///      A REDEEM asks "is my price fixed yet?" — it is paid from the frozen
    ///      stamp of its own pid, whose reserve was denominated against that
    ///      same price, and it needs the vault unlocked so the reserved float is
    ///      actually available.
    ///
    ///      A DEPOSIT asks "is this an honest instant to mint?" — it carries no
    ///      frozen price at all (it is converted live below), so no stamp is
    ///      relevant to it. `depositsLocked()` is the whole gate: no open
    ///      proposal, and no settled strategy still holding a residue. The
    ///      second arm is finding #3 — see the pricing block in the deposit
    ///      branch for why the gate and the live read are both required.
    function claim(uint256 requestId) external nonReentrant returns (uint256 outAmount) {
        Request storage r = _req(requestId);
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        // GATE ON THE PRICE THIS CLAIM ACTUALLY USES, not blindly on the request's
        // own tagged pid.
        //
        // Redeem claims price against their OWN pid's stamp: `requestRedeem` only
        // opens while the proposal it tags is already Executed, and every Executed
        // proposal reaches Settled through a path that stamps, so `r.pid` is
        // always eventually stamped for a redeem.
        //
        // Deposit claims price against `_lastStampedPid` instead, and
        // `requestDeposit` opens on `openProposalCount() != 0` — Draft AND
        // Pending, not just Executed. A proposal can leave Draft/Pending WITHOUT
        // ever settling, so `_settlePrice[r.pid]` can be permanently unstamped for
        // a deposit tagged to one of those, and gating on `r.pid` there reverted
        // forever with no recovery for a pay-on-behalf deposit. Gating on
        // `_lastStampedPid` unlocks the claim at the NEXT real settlement —
        // exactly the price it is charged at below.
        //
        // AT OR AFTER THIS REQUEST, not merely "some stamp exists". Because
        // `stampSettlement` writes `sp.stamped` BEFORE `_lastStampedPid`,
        // `_settlePrice[_lastStampedPid].stamped` is true by construction from
        // the first settlement onward — on its own it is the constant `true`,
        // not a gate. `_lastStampedPid >= r.pid` asks the real question, and
        // makes this the exact complement of `cancel`'s gate: before that
        // instant only cancel is open, after it only claim is.
        bool isRedeem = r.kind == RequestKind.Redeem;
        SettlePrice memory sp;
        if (isRedeem) {
            sp = _settlePrice[r.pid];
            if (!sp.stamped) revert NotSettled();
            if (IRequestableVault(vault).redemptionsLocked()) revert VaultLocked();
        } else {
            // DEPOSITS GATE ON THE VAULT'S OWN MINT PREDICATE, NOT ON A STAMP
            // (finding #3, the attack half). A queued deposit no longer prices
            // against a frozen number, so there is nothing to wait for and no
            // stamp to require — what it needs is an instant at which minting is
            // honest, which is exactly what `depositsLocked()` answers: no open
            // proposal AND no settled strategy still holding a residue. That
            // predicate subsumes `redemptionsLocked()` (an active proposal
            // implies a nonzero open count), so it is the only gate here.
            //
            // This also retires the `_lastStampedPid >= r.pid` requirement,
            // which was never about safety: a deposit tagged to a proposal that
            // left Draft/Pending WITHOUT settling could never satisfy it and
            // reverted forever. Such a request now claims at the next clean
            // instant like any other.
            if (IRequestableVault(vault).depositsLocked()) revert VaultLocked();
        }

        r.claimed = true;
        r.closedAt = uint48(block.timestamp);
        uint256 amount = r.amount;

        if (isRedeem) {
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
            // The share-side release, paired with the asset-side one above. The
            // vault's `_burn` below removes these shares from `totalSupply`, so
            // they must leave this counter in the same call — otherwise pricing
            // would subtract them twice.
            uint256 stamped = _stampedUnclaimedShares;
            _stampedUnclaimedShares = stamped > amount ? stamped - amount : 0;
            IRequestableVault(vault).settleRedeem(amount, outAmount, r.owner);
        } else {
            // PRICED LIVE, NOT AT ANY STAMP (finding #3, the attack half).
            //
            // A stamp is a frozen REALIZED figure taken at settlement, and
            // `totalAssets()` counts only float — so a settlement that left a
            // residue on the strategy stamps a price BELOW what the vault owns.
            // Minting against that number is the skim: claim cheap, then call
            // the permissionless `sweep()` and own a slice of the residue the
            // incumbents paid for. An attacker can induce it rather than wait
            // for it (a fee-free flash loan empties the market's idle balance
            // for one callback frame, forcing under-delivery on demand).
            //
            // Two changes close it together, and neither suffices alone. The
            // gate above admits the claim only at an instant with no residue
            // outstanding; this live read then prices whatever the vault holds
            // AT THAT INSTANT — including a residue already swept in, which a
            // frozen stamp would still be blind to.
            //
            // The escrowed assets never entered the strategy (they sit in this
            // contract, off-vault, uncounted in `totalAssets`), so the honest
            // price is the one prevailing when they actually join the pool.
            // Computed BEFORE the push so the deposit does not dilute its own
            // price. Redeem keeps its stamp deliberately: those shares left the
            // supply at that settlement and the reserve is denominated against
            // that same price.
            //
            // Retires the perpetual look-back call the old frozen pricing
            // created — with no frozen number there is nothing to look back at,
            // which is why `cancel` can now stay open for deposits.
            outAmount = IRequestableVault(vault).convertToShares(amount);
            if (outAmount == 0) revert ZeroShares();
            _pendingDepositAssets -= amount;
            // Push escrowed assets into the vault, then mint at the price read
            // above (pre-push, so the mint is not diluted by its own assets).
            IERC20(IRequestableVault(vault).asset()).safeTransfer(vault, amount);
            IRequestableVault(vault).settleDeposit(outAmount, r.owner);
        }
        emit RequestClaimed(requestId, r.owner, amount, outAmount);
    }

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev A REDEEM cancels only before its proposal is stamped; a DEPOSIT
    ///      cancels at any time. Returns the escrowed shares (Redeem) or assets
    ///      (Deposit) to the owner.
    function cancel(uint256 requestId) external nonReentrant {
        Request storage r = _req(requestId);
        if (msg.sender != r.owner) revert NotQueueOwner();
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        // DEPOSIT CANCEL IS UNCONDITIONALLY OPEN, and that is a CONSEQUENCE of
        // the live pricing in `claim`, not a relaxation of pashov #10.
        //
        // #10 was a costless straddle: `claim` paid a deposit at a FROZEN
        // price, so holding the request was a perpetual look-back call — claim
        // when the stale number mints more, cancel when it does not, with the
        // upside funded by the incumbents. The fix then was to shut cancel
        // exactly when claim opened, keying both gates to `_lastStampedPid`.
        //
        // A deposit now converts LIVE at claim time (see the pricing block in
        // `claim`). There is no stale number to exercise against: claiming
        // always mints at the price prevailing in that instant, so the option
        // is worth zero and the straddle has no payoff to straddle. Cancel is
        // then just "I changed my mind", which is what it was always for — and
        // it must stay open, because the deposit gate can hold a claim shut
        // while a residue is outstanding and a depositor must never be wedged
        // between a closed claim and a closed cancel.
        //
        // Redeem keeps `r.pid`: those shares left the supply at that settlement
        // and `_pidReserved` is denominated against that same frozen price, so
        // its own stamp is the correct and only meaningful gate — and unlike a
        // deposit, a redeem IS paid from a stamp, so the look-back logic still
        // applies to it.
        bool priceFixed = r.kind == RequestKind.Redeem && _settlePrice[r.pid].stamped;
        if (priceFixed) revert AlreadySettled();

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

    /// @inheritdoc IVaultWithdrawalQueue
    function stampedUnclaimedShares() external view returns (uint256) {
        return _stampedUnclaimedShares;
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
