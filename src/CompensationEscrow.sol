// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICompensationEscrow} from "./interfaces/ICompensationEscrow.sol";

/// @dev The ERC20Votes read surface the escrow apportions against. Narrow by
///      design (mirrors the IGovernorMinimal pattern) — the escrow never needs
///      the full vault ABI.
interface IVaultVotesMinimal {
    function getPastVotes(address holder, uint256 timestamp) external view returns (uint256);
    function getPastTotalSupply(uint256 timestamp) external view returns (uint256);
}

/**
 * @title CompensationEscrow
 * @notice Victim compensation for a passed challenge (spec 2026-07-22 §3.8).
 *
 *         Slash proceeds do NOT go to the vault's live ERC4626 balance.
 *         `totalAssets` is pro-rata and share transfers are ungated, so paying
 *         the live NAV would let a coalition drain, buy the depressed shares of
 *         exiting honest holders, and recoup its own slash — a recoupment
 *         channel the burn sink never had (finding F1). Instead each conviction
 *         opens a CASE pinned to a pre-drain snapshot, and only holders of
 *         record AT THAT SNAPSHOT can redeem.
 *
 *         Claims are entries in a mapping, never a token: there is no transfer
 *         surface, so a claim cannot be bought from an exiting honest holder.
 *
 * @dev    PAYOUT IS WOOD (§3.8 "WOOD-only payout boundary"): a victim is made
 *         whole in WOOD valued at slash time, which is exactly why §3.7's
 *         covered-TVL cap must bind — it keeps recoverable dollars
 *         proportionate to dollars at risk. v2 multi-collateral pays partly in
 *         stable legs.
 *
 * @dev    CLAIM BASIS (accepted edge, decision D1): apportionment uses the
 *         vault's ERC20Votes checkpoints, not raw balances — Solidity keeps no
 *         historical balance. `SyndicateVault` auto-delegates on receipt, so
 *         `getPastVotes(h, t)` equals h's balance for any holder that never
 *         delegated away. A holder that DID explicitly delegate has its
 *         compensation credited to the delegate instead. Accepted for v1b;
 *         revisit if vault-share delegation becomes common.
 *
 * @dev    Not upgradeable, and not refundable. The separation from the review
 *         path is one of STRUCTURALLY SEPARATE ACCOUNTING, not of a binding
 *         rule: the registry's `refundSlash` pays from the registry's own
 *         funded appeal reserve, never from slash proceeds, so it cannot refund
 *         a verdict. Nothing that reaches this escrow can flow back out through
 *         the registry (spec §4).
 */
contract CompensationEscrow is Ownable2Step, ICompensationEscrow {
    using SafeERC20 for IERC20;

    struct Case {
        address vault;
        uint256 snapshotTimestamp;
        uint256 proceeds;
        uint256 redeemed;
        uint256 openedAt;
        uint256 snapshotSupply; // cached: a past snapshot cannot change
        /// @dev The residue window in force AT OPEN, frozen here. `sweepResidue`
        ///      reads this, NOT the live `residueWindow`: otherwise the owner
        ///      could lower the window to the 30-day floor after the fact and
        ///      sweep a case whose holders were promised longer. The struct
        ///      already carries `openedAt` and `snapshotSupply` for exactly this
        ///      "terms are fixed at open" reason.
        uint256 residueWindowAtOpen;
        bool swept; // residue returned to the backstop; claims are closed
    }

    IERC20 public immutable wood;

    /// @notice The only address permitted to fund cases. In v1b this is
    ///         `StakedWood` (whose `slashToEscrow` opens the case); Plan D's
    ///         challenge game drives that entrypoint.
    address public authorizedFunder;

    /// @notice Where unredeemed residue goes once the window closes — the
    ///         protocol insurance backstop, NEVER the live vault NAV (§3.8).
    address public backstop;

    /// @notice How long holders have to redeem before residue may be swept.
    uint256 public residueWindow = 180 days;

    /// @notice Sum over cases of (proceeds - redeemed - swept). The escrow's
    ///         WOOD balance must never fall below this (fuzz invariant, Task 2).
    uint256 public totalEscrowed;

    uint256 public caseCount;
    mapping(uint256 caseId => Case) internal _cases;
    mapping(uint256 caseId => mapping(address holder => bool)) internal _redeemed;

    constructor(address initialOwner, address wood_) Ownable(initialOwner) {
        if (wood_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
    }

    modifier onlyFunder() {
        if (msg.sender != authorizedFunder) revert NotAuthorizedFunder();
        _;
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev The snapshot timestamp is chosen by the CALLER, not derived here
    ///      (decision D2): §3.8 uses the block before the drain proposal
    ///      executed for predicates 1-4, but the epoch-N opening checkpoint for
    ///      a per-epoch drawdown conviction. Only "is it in the past" is
    ///      enforceable at this layer.
    function openCase(address vault, uint256 snapshotTimestamp, uint256 proceeds)
        external
        onlyFunder
        returns (uint256 caseId)
    {
        if (vault == address(0)) revert ZeroAddress();
        if (snapshotTimestamp >= block.timestamp) revert SnapshotNotPast();
        if (proceeds == 0) revert NothingToCompensate();
        uint256 supply = IVaultVotesMinimal(vault).getPastTotalSupply(snapshotTimestamp);
        // A zero-supply snapshot apportions nothing: reject at open rather than
        // accept WOOD into a case no one can ever redeem.
        if (supply == 0) revert EmptySnapshot();

        caseId = ++caseCount;
        _cases[caseId] = Case({
            vault: vault,
            snapshotTimestamp: snapshotTimestamp,
            proceeds: proceeds,
            redeemed: 0,
            openedAt: block.timestamp,
            snapshotSupply: supply,
            // Freeze the redemption window at the terms in force right now.
            residueWindowAtOpen: residueWindow,
            swept: false
        });
        totalEscrowed += proceeds;
        wood.safeTransferFrom(msg.sender, address(this), proceeds);
        emit CaseOpened(caseId, vault, snapshotTimestamp, proceeds);
    }

    /// @inheritdoc ICompensationEscrow
    function caseOf(uint256 caseId)
        external
        view
        returns (
            address vault,
            uint256 snapshotTimestamp,
            uint256 proceeds,
            uint256 redeemed,
            uint256 openedAt,
            bool swept
        )
    {
        Case storage c = _cases[caseId];
        return (c.vault, c.snapshotTimestamp, c.proceeds, c.redeemed, c.openedAt, c.swept);
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev Pro-rata against the snapshot: `proceeds * votes(h, snap) / supply(snap)`.
    ///      Returns 0 once redeemed or swept, so one call serves both
    ///      "what am I owed" and "what is left". Rounds DOWN, so the sum of
    ///      claims can never exceed `proceeds`; the dust stays in the case and
    ///      leaves with the residue.
    ///
    /// @dev PER-CASE FUND ISOLATION. The pro-rata result is capped at the case's
    ///      own unpaid remainder (`proceeds - redeemed`). Cases share one WOOD
    ///      balance but are separately funded, and the numerator is data read
    ///      from the case's `vault` — an address supplied by the funder. Without
    ///      the cap, a hostile or merely non-standard vault reporting
    ///      `votes > supply` (or several holders whose votes oversum the
    ///      snapshot supply) would let a small case pay out more than it was
    ///      ever funded with, taking the difference from a SIBLING case's funds
    ///      and, past the skew that exhausts the balance, underflowing
    ///      `totalEscrowed -= amount` and bricking redemption protocol-wide.
    ///      With the cap, a case can never pay out more than its own proceeds,
    ///      so the blast radius of a bad `vault` is exactly that one case.
    function claimable(uint256 caseId, address holder) public view returns (uint256) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) return 0;
        if (c.swept) return 0; // residue returned to the backstop; claims closed
        if (_redeemed[caseId][holder]) return 0;
        uint256 votes = IVaultVotesMinimal(c.vault).getPastVotes(holder, c.snapshotTimestamp);
        if (votes == 0) return 0;
        uint256 amt = (c.proceeds * votes) / c.snapshotSupply;
        uint256 remaining = c.proceeds - c.redeemed;
        return amt < remaining ? amt : remaining;
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev Pull-based: each holder redeems its own claim. Effects before
    ///      interaction — the per-holder flag is set BEFORE the transfer, so a
    ///      hooked WOOD cannot re-enter for a second payout.
    function redeem(uint256 caseId) external returns (uint256 amount) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) revert CaseNotFound();
        if (_redeemed[caseId][msg.sender]) revert AlreadyRedeemed();
        amount = claimable(caseId, msg.sender);
        if (amount == 0) revert NoClaim();

        _redeemed[caseId][msg.sender] = true;
        c.redeemed += amount;
        totalEscrowed -= amount;
        wood.safeTransfer(msg.sender, amount);
        emit ClaimRedeemed(caseId, msg.sender, amount);
    }

    /// @inheritdoc ICompensationEscrow
    /// @dev Permissionless: the destination is the owner-set backstop, so an
    ///      arbitrary caller can only accelerate a fixed transfer, never
    ///      redirect it. Residue goes to the protocol insurance backstop and
    ///      NEVER to the vault's live NAV — paying live NAV is precisely the F1
    ///      recoupment channel this contract exists to close (§3.8).
    /// @dev The deadline uses the case's FROZEN `residueWindowAtOpen`, not the
    ///      live `residueWindow`. Reading the live value would let the owner
    ///      lower the window to the 30-day floor and sweep cases opened under a
    ///      longer promise — a retroactive shortening of holders' redemption
    ///      rights. A `setResidueWindow` change therefore governs only cases
    ///      opened after it.
    /// @dev Reverts `ZeroAddress` if no backstop is configured, rather than
    ///      transferring the residue to address(0).
    function sweepResidue(uint256 caseId) external returns (uint256 amount) {
        Case storage c = _cases[caseId];
        if (c.proceeds == 0) revert CaseNotFound();
        if (block.timestamp < c.openedAt + c.residueWindowAtOpen) revert ResidueWindowOpen();
        if (c.swept) revert NothingToCompensate();
        if (backstop == address(0)) revert ZeroAddress();
        amount = c.proceeds - c.redeemed;
        if (amount == 0) revert NothingToCompensate();

        c.swept = true;
        totalEscrowed -= amount;
        wood.safeTransfer(backstop, amount);
        emit ResidueSwept(caseId, backstop, amount);
    }

    // ── Owner setters ──

    function setAuthorizedFunder(address funder) external onlyOwner {
        if (funder == address(0)) revert ZeroAddress();
        emit AuthorizedFunderSet(authorizedFunder, funder);
        authorizedFunder = funder;
    }

    function setBackstop(address backstop_) external onlyOwner {
        if (backstop_ == address(0)) revert ZeroAddress();
        emit BackstopSet(backstop, backstop_);
        backstop = backstop_;
    }

    function setResidueWindow(uint256 window) external onlyOwner {
        // Bounded: a zero window would let residue be swept before holders can
        // realistically redeem; beyond a year the backstop never recovers dust.
        if (window < 30 days || window > 365 days) revert InvalidWindow();
        emit ResidueWindowSet(residueWindow, window);
        residueWindow = window;
    }
}
