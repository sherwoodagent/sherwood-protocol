// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICourt} from "./interfaces/ICourt.sol";

/**
 * @title Court
 * @notice Adjudication of disputed challenges (spec 2026-07-22 §3.5, Plan E).
 *         Plan D left a disputed challenge terminal-with-timeout, which means a
 *         genuinely guilty approver can dispute and run out the clock. The
 *         court closes that hole: a bonded panel rules, that ruling is
 *         appealable to a full WOOD vote, and the outcome drives
 *         `ChallengeGame.rule`.
 *
 * @dev    THIS REVISION IS THE ROSTER AND THE MEMBER BONDS ONLY (Plan E Task
 *         2). The panel ruling (Task 3), the token-vote appeal (Task 4) and the
 *         bad-faith track (Task 5) build on this foundation. `ICourt` already
 *         declares their errors and the `Ruling` enum, so those tasks add
 *         functions rather than churning the ABI.
 *
 * @dev    NEITHER HALF IS SAFE ALONE. §3.5: a token vote is incompetent for
 *         forensic questions and capturable at ~$15M mcap; a standalone panel
 *         is bribable with no check above it. The layers cover each other's
 *         failure mode, so this contract MUST NOT be wired into
 *         `ChallengeGame.setCourt` until the panel, the appeal and the
 *         bad-faith track are all live. Task 7 makes that a deploy pre-flight.
 *
 * @dev    Plain `Ownable2Step`, NOT upgradeable — the house shape for the
 *         economic-security contracts (cf. `CompensationEscrow`,
 *         `ChallengeGame`). Storage layout is therefore unconstrained and no
 *         golden pins it.
 *
 * @dev    §4 INVARIANT: `wood.balanceOf(this) >= bondedWood`, matching
 *         `ChallengeGame`'s. In this revision `bondedWood` is exactly the sum
 *         of posted panel bonds; Tasks 4 and 5 add open appeal and bad-faith
 *         bonds to the same accumulator. The court pays out nothing but bonds,
 *         so the two are equal except for WOOD somebody donated here by
 *         mistake — which no path ever spends.
 */
contract Court is Ownable2Step, ICourt {
    using SafeERC20 for IERC20;

    /// @notice Upper bound on seated members. `setPanel` loops over the old and
    ///         new rosters and de-duplicates in O(n²); the bound keeps that
    ///         gas-safe. §3.5 contemplates a panel of ~5, so this is generous.
    uint256 public constant MAX_PANEL_SIZE = 21;

    IERC20 public immutable wood;

    /// @notice The seated roster, in the order `setPanel` received it. Kept
    ///         alongside `isPanelist` because replacing the panel needs to
    ///         enumerate the members it is unseating, and because Task 7's
    ///         deploy pre-flight has to check every seat is bonded.
    address[] internal _panel;

    /// @inheritdoc ICourt
    mapping(address member => bool) public isPanelist;

    /// @inheritdoc ICourt
    uint256 public panelBondWood;

    /// @inheritdoc ICourt
    mapping(address member => uint256) public panelBondOf;

    /// @inheritdoc ICourt
    /// @dev Monotonically non-decreasing per member, written only through
    ///      `_lockPanelBond`. A deadline rather than an open-ruling COUNTER on
    ///      purpose: a bad-faith vote that is never opened has nothing to
    ///      decrement it, so a counter would strand the bond forever, whereas a
    ///      deadline simply expires.
    mapping(address member => uint256) public panelBondLockedUntil;

    /// @inheritdoc ICourt
    /// @dev Counts EVERY posted panel bond, seated or not: an unseated member
    ///      whose bond is still locked against the bad-faith track is still
    ///      WOOD this contract holds and must still balance.
    uint256 public bondedWood;

    /// @param initialOwner   The governance multisig that executes the off-chain
    ///                       panel election (D1).
    /// @param wood_          The WOOD token every bond here is denominated in.
    /// @param panelBondWood_ The per-member bond. Must be non-zero: a zero bond
    ///                       is a panel with no skin in the game, which is the
    ///                       entire binding incentive on panel behaviour.
    constructor(address initialOwner, address wood_, uint256 panelBondWood_) Ownable(initialOwner) {
        if (wood_ == address(0)) revert ZeroAddress();
        if (panelBondWood_ == 0) revert InvalidParameter();
        wood = IERC20(wood_);
        panelBondWood = panelBondWood_;
        emit PanelBondWoodSet(0, panelBondWood_);
    }

    // ─────────────────────────── Roster (D1) ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev THE UNSEAT GUARD IS LOAD-BEARING. A member is refused unseating
    ///      while `_hasOpenRuling` holds, because Task 5's bad-faith track
    ///      slashes `panelBondOf[member]` and `withdrawPanelBond` opens the
    ///      moment a member leaves the roster. Without the guard, the owner (or
    ///      a member that lobbied the owner) could rotate a panelist out the
    ///      instant it made a corrupt ruling, its bond would become withdrawable
    ///      before anyone could vote on it, and the bond would stop binding
    ///      anything. It is a DELAY, not a life sentence: the lock expires with
    ///      the bad-faith window.
    function setPanel(address[] calldata members) external onlyOwner {
        uint256 newSize = members.length;
        if (newSize > MAX_PANEL_SIZE) revert InvalidParameter();

        // Validate before mutating: no zero address, no duplicates. A duplicate
        // would inflate `panelSize`, which Task 3's majority and
        // "every seat has voted" arithmetic reads.
        for (uint256 i; i < newSize; ++i) {
            if (members[i] == address(0)) revert ZeroAddress();
            for (uint256 j = i + 1; j < newSize; ++j) {
                if (members[i] == members[j]) revert InvalidParameter();
            }
        }

        uint256 oldSize = _panel.length;
        for (uint256 i; i < oldSize; ++i) {
            address member = _panel[i];
            if (_contains(members, member)) continue; // retained: seat, bond and lock untouched
            if (_hasOpenRuling(member)) revert PanelistHasOpenRuling();
            isPanelist[member] = false;
            emit PanelistUnseated(member);
        }

        delete _panel;
        for (uint256 i; i < newSize; ++i) {
            address member = members[i];
            if (!isPanelist[member]) {
                isPanelist[member] = true;
                emit PanelistSeated(member);
            }
            _panel.push(member);
        }

        emit PanelSet(oldSize, newSize);
    }

    /// @inheritdoc ICourt
    function panel() external view returns (address[] memory) {
        return _panel;
    }

    /// @inheritdoc ICourt
    function panelSize() external view returns (uint256) {
        return _panel.length;
    }

    // ─────────────────────────── Member bonds ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev Pulls the SHORTFALL, not the full requirement, so a member that
    ///      already posted under a lower `panelBondWood` tops up rather than
    ///      double-paying. Effects before the interaction: `panelBondOf` and
    ///      `bondedWood` are written before the transfer, so a hooked WOOD
    ///      cannot re-enter and post twice against one balance.
    function postPanelBond() external {
        if (!isPanelist[msg.sender]) revert NotPanelist();
        uint256 posted = panelBondOf[msg.sender];
        uint256 required = panelBondWood;
        if (posted >= required) revert PanelBondAlreadyPosted();

        uint256 amount = required - posted;
        panelBondOf[msg.sender] = required;
        bondedWood += amount;
        wood.safeTransferFrom(msg.sender, address(this), amount);
        emit PanelBondPosted(msg.sender, amount);
    }

    /// @inheritdoc ICourt
    /// @dev TWO GUARDS, BOTH LOAD-BEARING:
    ///      1. `StillSeated` — a sitting panelist may not pull its bond, or it
    ///         would rule with nothing at stake.
    ///      2. `PanelistHasOpenRuling` — an unseated member may not pull its
    ///         bond while a bad-faith window is open against any of its
    ///         rulings, or the ruling it just made would be unpunishable.
    ///      Returns what was POSTED, not the current requirement: if the owner
    ///      lowered `panelBondWood` after the member bonded, the excess is the
    ///      member's and leaving it stranded would break the §4 equality.
    function withdrawPanelBond() external returns (uint256 amount) {
        if (isPanelist[msg.sender]) revert StillSeated();
        if (_hasOpenRuling(msg.sender)) revert PanelistHasOpenRuling();
        amount = panelBondOf[msg.sender];
        if (amount == 0) revert PanelBondNotPosted();

        panelBondOf[msg.sender] = 0;
        bondedWood -= amount;
        wood.safeTransfer(msg.sender, amount);
        emit PanelBondWithdrawn(msg.sender, amount);
    }

    /// @inheritdoc ICourt
    /// @dev Measured against the LIVE requirement, never "posted something
    ///      once": raising `panelBondWood` un-readies every member below the
    ///      new bar until it tops up, which is the point of raising it.
    function isReadyToRule(address member) public view returns (bool) {
        return isPanelist[member] && panelBondOf[member] >= panelBondWood;
    }

    // ─────────────────────── Hooks for Tasks 3-5 ───────────────────────

    /// @dev The single choke point Task 3's `panelRule` MUST call before
    ///      recording a vote. Split from `isReadyToRule` only to report which
    ///      of the two preconditions failed.
    function _requireReadyToRule(address member) internal view {
        if (!isPanelist[member]) revert NotPanelist();
        if (panelBondOf[member] < panelBondWood) revert PanelBondNotPosted();
    }

    /// @dev Whether `member`'s bond is still needed by the bad-faith track.
    ///      Nothing in this revision writes `panelBondLockedUntil`, so today it
    ///      is uniformly false and the roster/withdraw guards are inert — by
    ///      construction, since there are no rulings yet. TASK 3 wires it up by
    ///      calling `_lockPanelBond(member, finalizedAt + badFaithWindow)` when
    ///      a panelist records a ruling, and TASK 5 extends the lock for as
    ///      long as a bad-faith vote against that ruling stays open. The guards
    ///      are implemented now so that wiring is a one-line change rather than
    ///      a security property someone has to remember to add.
    function _hasOpenRuling(address member) internal view returns (bool) {
        return block.timestamp < panelBondLockedUntil[member];
    }

    /// @dev Extends `member`'s bond lock to `until`. NEVER shortens it: two
    ///      open rulings against one member must not let the earlier deadline
    ///      release the bond the later one still needs.
    function _lockPanelBond(address member, uint256 until) internal {
        if (until > panelBondLockedUntil[member]) {
            panelBondLockedUntil[member] = until;
            emit PanelBondLocked(member, until);
        }
    }

    // ─────────────────────────── Owner setters ───────────────────────────

    /// @inheritdoc ICourt
    /// @dev Governs future posts and future readiness only; it never moves WOOD
    ///      already posted, so `bondedWood` is untouched here. Raising it leaves
    ///      seated members un-ready (see `isReadyToRule`) until they top up;
    ///      lowering it leaves them over-bonded until they withdraw.
    function setPanelBondWood(uint256 newBond) external onlyOwner {
        if (newBond == 0) revert InvalidParameter();
        emit PanelBondWoodSet(panelBondWood, newBond);
        panelBondWood = newBond;
    }

    // ─────────────────────────── Internals ───────────────────────────

    function _contains(address[] calldata list, address member) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == member) return true;
        }
        return false;
    }
}
