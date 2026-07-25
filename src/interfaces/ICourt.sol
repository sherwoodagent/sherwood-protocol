// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICourt
/// @notice The two-layer adjudicator for disputed challenges (spec 2026-07-22
///         §3.5, Plan E). Layer 1 is a governance-elected panel, each member
///         holding a slashable bond; layer 2 is a full WOOD vote weighted by
///         `StakedWood.getPastVotes` at the block before the challenged
///         proposal executed. A SEPARATE vote — never the merits appeal —
///         decides whether a ruling was made in bad faith and slashes the
///         panelist's bond (decision D4).
///
/// @dev    PANEL SELECTION IS TRUSTED; PANEL BEHAVIOUR IS BONDED (decision D1).
///         §3.5 says panel members are "elected by WOOD governance", but
///         on-chain elections are a governance subsystem in their own right and
///         are out of scope. The roster is owner-set, where the owner is the
///         governance multisig executing the off-chain election result. The
///         check on a captured roster is the bad-faith track plus the sovereign
///         appeal — not the seating call.
///
/// @dev    SURFACE STAGING. This interface is built across Plan E's tasks:
///         Task 2 (this file's first revision) declares the whole error and
///         enum surface plus the roster/bond functions; Tasks 3-5 add `refer` /
///         `panelRule` / `finalizePanel`, `appeal` / `voteAppeal` /
///         `finalizeAppeal` / `finalizeUnappealed`, and `openBadFaith` /
///         `voteBadFaith` / `finalizeBadFaith`. Errors declared here that no
///         function reverts with yet belong to those later tasks — they are
///         pinned now so the ABI does not churn under consumers.
interface ICourt {
    /// @notice A verdict on a case. `None` MUST be the zero value so an unset
    ///         ruling is never read as `Guilty` — a default-Guilty enum would
    ///         make an untouched storage slot a conviction.
    /// @dev    Tasks 3-6 branch on this; the member names and ordering are
    ///         fixed here and must not be reordered.
    enum Ruling {
        None,
        Guilty,
        NotGuilty
    }

    // ── Errors ──
    // Roster and bonds (Task 2).
    error NotPanelist();
    error PanelBondNotPosted();
    error PanelBondAlreadyPosted();
    /// @notice The member still has a ruling whose bad-faith window can open or
    ///         is open. Blocks BOTH unseating it and returning its bond — if
    ///         either were allowed the bond would escape the bad-faith track
    ///         and the only binding incentive on panel behaviour with it.
    error PanelistHasOpenRuling();
    /// @notice A seated panelist tried to withdraw its bond. A sitting member
    ///         with nothing at stake is not a bonded panel.
    error StillSeated();

    // Adjudication (Tasks 3-5).
    error AlreadyRuled();
    error WrongPhase();
    error WindowClosed();
    error WindowOpen();
    error ParticipationFloorNotMet();
    error AlreadyVoted();
    error NoVotingPower();

    // Shared.
    error ZeroAddress();
    error InvalidParameter();

    // ── Events ──
    /// @param oldSize Seats before the call.
    /// @param newSize Seats after it. Task 3's majority arithmetic reads this
    ///        count, which is why `setPanel` rejects duplicate members.
    event PanelSet(uint256 oldSize, uint256 newSize);
    event PanelistSeated(address indexed member);
    event PanelistUnseated(address indexed member);
    event PanelBondWoodSet(uint256 oldAmount, uint256 newAmount);
    event PanelBondPosted(address indexed member, uint256 amount);
    event PanelBondWithdrawn(address indexed member, uint256 amount);
    /// @notice The member's bond is escrowed at least until `lockedUntil`.
    /// @dev    Emitted by Tasks 3-5 whenever a ruling is recorded or a
    ///         bad-faith vote is opened against one.
    event PanelBondLocked(address indexed member, uint256 lockedUntil);

    // ── Roster (D1) ──
    /// @notice Replace the seated panel with `members`.
    /// @dev    Owner-only: the owner is the governance multisig executing the
    ///         off-chain election (D1). Members present in both the old and new
    ///         lists keep their seat, bond and lock untouched. Reverts
    ///         `PanelistHasOpenRuling` rather than unseating a member whose
    ///         bond the bad-faith track may still need.
    /// @dev    An EMPTY list is legal and decommissions the court. Refusing to
    ///         wire a court with no seated, bonded panel into `ChallengeGame`
    ///         is a deploy-time pre-flight, not a setter invariant.
    function setPanel(address[] calldata members) external;

    /// @notice The seated roster, in the order it was set.
    function panel() external view returns (address[] memory);
    function panelSize() external view returns (uint256);
    function isPanelist(address member) external view returns (bool);

    // ── Member bonds ──
    /// @notice Post (or top up to) the current `panelBondWood`. Pulls only the
    ///         shortfall, so a member is never charged twice for the same seat.
    function postPanelBond() external;

    /// @notice Return a member's posted bond. Only once it has been unseated
    ///         AND no bad-faith window is open against any of its rulings.
    /// @return amount The WOOD returned — what was POSTED, which after a
    ///         lowered requirement can exceed the current `panelBondWood`.
    function withdrawPanelBond() external returns (uint256 amount);

    /// @notice The bond each seated member must post before it can rule.
    function panelBondWood() external view returns (uint256);
    /// @notice WOOD `member` currently has posted, seated or not.
    function panelBondOf(address member) external view returns (uint256);
    /// @notice Timestamp until which `member`'s bond is escrowed against the
    ///         bad-faith track. Zero means free.
    function panelBondLockedUntil(address member) external view returns (uint256);

    /// @notice Whether `member` is seated AND fully bonded — the precondition
    ///         Task 3's `panelRule` enforces. An unbonded panelist is never
    ///         ready to rule.
    function isReadyToRule(address member) external view returns (bool);

    /// @notice WOOD the court holds on behalf of open positions (spec §4). The
    ///         invariant is `wood.balanceOf(court) == bondedWood`: in Task 2
    ///         that is posted panel bonds; Tasks 4 and 5 add open appeal and
    ///         bad-faith bonds to the same accumulator.
    function bondedWood() external view returns (uint256);

    // ── Owner setters ──
    function setPanelBondWood(uint256 newBond) external;
}
