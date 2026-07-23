// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IVaultWithdrawalQueue} from "../interfaces/IVaultWithdrawalQueue.sol";
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
///         `cancel` is allowed ONLY before the request's proposal is stamped
///         (G7): once a settle price is frozen, post-settle cancel would be a
///         free look-back option, so the request must be claimed.
contract VaultWithdrawalQueue is IVaultWithdrawalQueue, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    address public immutable override vault;

    Request[] private _requests; // index 0 unused (sentinel)
    mapping(address => uint256[]) private _byOwner;
    mapping(uint256 pid => SettlePrice) private _settlePrice;
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
    ///      concurrent-exit over-promise, PR #351 finding #6).
    function queueDeposit(address owner_, uint256 assets, uint256 pid) external onlyVault returns (uint256 id) {
        if (assets == 0) revert ZeroAssets();
        id = _push(owner_, assets, pid, RequestKind.Deposit);
        _pendingDepositAssets += assets;
        emit DepositQueued(id, owner_, assets, pid);
    }

    function _push(address owner_, uint256 amount, uint256 pid, RequestKind kind) private returns (uint256 id) {
        id = _requests.length;
        _requests.push(Request({owner: owner_, amount: amount, pid: pid, kind: kind, claimed: false, cancelled: false}));
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
            // shares = assets * den / num (matches ERC-4626 convertToShares at settle)
            outAmount = Math.mulDiv(amount, sp.den, sp.num);
            _pendingDepositAssets -= amount;
            // Push escrowed assets into the vault, then mint at the frozen price.
            IERC20(IRequestableVault(vault).asset()).safeTransfer(vault, amount);
            IRequestableVault(vault).settleDeposit(outAmount, r.owner);
        }
        emit RequestClaimed(requestId, r.owner, amount, outAmount);
    }

    /// @inheritdoc IVaultWithdrawalQueue
    /// @dev G7: cancel is allowed ONLY before the request's proposal is stamped.
    ///      Returns the escrowed shares (Redeem) or assets (Deposit) to the owner.
    function cancel(uint256 requestId) external nonReentrant {
        Request storage r = _req(requestId);
        if (msg.sender != r.owner) revert NotQueueOwner();
        if (r.claimed) revert AlreadyClaimed();
        if (r.cancelled) revert AlreadyCancelled();
        if (_settlePrice[r.pid].stamped) revert AlreadySettled();

        r.cancelled = true;
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
