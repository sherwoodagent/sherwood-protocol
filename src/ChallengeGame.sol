// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";

/// @dev Narrow tier-registry surface: the game may REVOKE a certification on a
///      passed challenge and nothing else (spec §3.4, decision D7). A role
///      rather than registry ownership, so it can never grant one.
interface ITierRegistryDemoterMinimal {
    function demoteByChallenge(address target, bytes4 selector) external;
}

/**
 * @title ChallengeGame
 * @notice The challenge trigger of the guardian economic-security model
 *         (spec 2026-07-22 §3.4). Anyone may post a bonded challenge against
 *         an executed proposal, citing one of the five predicates and an
 *         evidence pointer. Filing freezes the coverage that proposal's
 *         approvers committed, so the accused cannot recycle that budget while
 *         under challenge.
 *
 * @dev    THERE IS NO ON-CHAIN PREDICATE VERIFICATION, and that is deliberate
 *         (decision D1). §3.4 adjudicates by SILENCE — "undisputed challenge →
 *         slash auto-executes after a delay; disputed → escalates to §3.5" —
 *         and never asks the chain to verify anything. Only predicates 1, 4
 *         and 5 could be checked on-chain at all; 2 needs a venue-specific
 *         fair-value model and 3 is a funding-graph question. Enforcing some
 *         in code and the rest by judges would run two security models inside
 *         one mechanism, so all five take the identical path here and the
 *         `Predicate` enum is a label carried in the event, nothing more.
 *
 * @dev    THE CONSEQUENCE, stated rather than discovered: vigilance cost moves
 *         to guardians. A guardian that sleeps through the dispute window is
 *         slashed on an unproven assertion. What holds that in check is the
 *         challenger's bond — sized to the coverage it freezes (D4) and
 *         forfeited to the accused when a challenge fails — plus a dispute
 *         window generous relative to the auto-slash delay.
 *
 * @dev    THE DETECTOR INCENTIVE IS THE FORFEITED COUNTER-BOND. §3.4 asks for
 *         "a first-detector bounty sized to cover forensic cost" and warns that
 *         "the challenge trigger must not depend on altruism". An earlier
 *         version of this contract answered both entirely off-chain, with a
 *         bug-bounty program keyed off these events, and refunded the
 *         counter-bond on every outcome. That was wrong twice over:
 *
 *         — A REFUNDED COUNTER-BOND DID NO WORK. Disputing converted a certain
 *           slash into a delayed slash with some chance the court errs, at zero
 *           bond cost, so a genuinely guilty approver always disputed. A
 *           counter-bond returned whatever happens is a deposit, not a stake,
 *           and prices nothing.
 *         — A WINNING CHALLENGER GOT NOTHING: only its own bond back, so the
 *           on-chain payoff of correct forensic work was break-even at best and
 *           the whole incentive rested on a program that can go unfunded or
 *           simply lapse. That is the altruism dependency §3.4 warns against,
 *           merely moved somewhere it could not be audited.
 *
 *         So the pool now FORFEITS TO THE CHALLENGER on a guilty verdict, on
 *         top of its returned bond. The escalation costs the accused what it is
 *         worth, and a challenger that is right is paid by the side that was
 *         wrong. An off-chain bounty may still top this up where forensic cost
 *         outruns the bond — that cost runs from minutes for an obvious
 *         out-of-adapter transfer to days for a funding-graph linkage, and no
 *         constant here can track it — but the mechanism no longer DEPENDS on
 *         one existing.
 *
 * @dev    THE DEFENCE IS BOUGHT COLLECTIVELY, and the total is invariant under
 *         identity-splitting. The counter-bond matches a bond sized to the
 *         SUMMED coverage of all approvers, yet it used to be posted in full by
 *         whichever single guardian happened to answer — so a guardian carrying
 *         20% of the blame paid 100% of the defence, and the other 80%
 *         free-rode. It is now a POOL any accused approver may contribute to.
 *
 *         The target stays pinned to the challenger's bond rather than being
 *         charged per-guardian by coverage share, and that is not an accident:
 *         THE ACCUSED SIDE CHOOSES WHO DISPUTES. Any rule keyed to the payer's
 *         own share is answered by nominating — or manufacturing — the cheapest
 *         identity, so an operator that split itself in two would halve the
 *         bill. Pinning the TOTAL and letting only the PAYER vary is what makes
 *         a Sybil split cost exactly what staying whole costs. Free-riding is
 *         then priced from the other side: a failed challenge's forfeit splits
 *         pro-rata to CONTRIBUTION, not to coverage, so an approver that sat
 *         out the defence collects none of the upside it produced.
 *
 *         That fix has a tail, and `forfeitBurnBps` is the answer to it: paying
 *         the forfeit perfectly back to whoever funded the pool is free money
 *         when the funder IS the challenger, which one operator with two
 *         addresses can arrange against its own proposal. A slice of every
 *         forfeit is therefore burned before the split, because the attacker
 *         controls both sides and any recipient it can reach is a round trip.
 *
 * @dev    Plain `Ownable2Step`, NOT upgradeable — same shape as `TierRegistry`
 *         and `ExposureLedger`, so its storage layout is unconstrained.
 *
 * @dev    Integration requirement: WOOD must be a standard ERC20 — no transfer
 *         fee, no rebasing, no hooks. A fee-on-transfer token would make the
 *         recorded bonds exceed the held balance.
 */
contract ChallengeGame is Ownable2Step, IChallengeGame {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard floor on `autoSlashDelay` — the guardians' ENTIRE window to
    ///         notice a filing and FULLY FUND a counter-bond between them.
    /// @dev    Pooling makes this window strictly more load-bearing than it was
    ///         when one guardian posted the whole counter-bond alone: a partial
    ///         pool buys nothing, so the accused must now coordinate several
    ///         independent signers inside the same wall clock. The floor was
    ///         already sized for human response times, which is what makes it
    ///         survive that; a governance change that shortened it would break
    ///         the collective defence before it broke the individual one.
    /// @dev    D1 moved the vigilance burden onto guardians: nothing is proven
    ///         on-chain, so an approver that says nothing for `autoSlashDelay`
    ///         is slashed on an unproven assertion. That is only defensible if
    ///         the window is long enough for a staked professional to actually
    ///         answer, which is a wall-clock question, not an economic one — a
    ///         challenge filed on a Friday night must still be contestable by a
    ///         guardian whose keys sit behind a multisig with human signers in
    ///         several time zones. 48h is the shortest span that spans a
    ///         weekend and survives a single operator outage, an RPC failure or
    ///         a short chain halt without silently converting an accusation
    ///         into an instant slash. Governance may raise the delay; this
    ///         floor stops it (or a compromised owner) from collapsing the
    ///         window to nothing and turning the game into a griefing weapon.
    uint256 public constant MIN_AUTO_SLASH_DELAY = 2 days;

    /// @dev Ceiling on `disputeTimeout` — a ceiling on how long a filing may
    ///      pin a guardian's coverage, not merely a griefing bound (review
    ///      2026-07-29 lock-time reduction). The old 180 days was 6x the
    ///      30-day default with nothing arguing for that headroom: with the
    ///      token court's real clocks a verdict needs at most
    ///      `MAX_VOTE_WINDOW + FINALIZE_BUFFER` (15 days) after referral, so
    ///      60 is still generous — it leaves 45 days of `autoSlashDelay`
    ///      headroom above the 15 days a worst-case adjudication needs, against
    ///      a 7-day default. Compatible with the cross-contract window
    ///      invariant (`_requireWindowFits`): at the `voteWindow` ceiling the
    ///      invariant needs 15 days of runway, so a 60-day timeout still
    ///      permits `autoSlashDelay` up to 45 days.
    uint256 public constant MAX_DISPUTE_TIMEOUT = 60 days;

    /// @dev THE GAS FLOOR sWOOD's natspec requires of its slasher (PR #24
    ///      round-4 N-4 / N-3). `resolve` is permissionless, so the caller
    ///      chooses the gas — exactly the regime where a starved `openCase`
    ///      child inside `slashToEscrow` reads as empty returndata and BURNS
    ///      the victims' compensation instead of bubbling. The floor is sized
    ///      per approver plus a base: the slash loop runs before `openCase`,
    ///      so a flat floor would let a large batch consume it before the
    ///      call that needs protecting. ~300k/approver covers `_slashOne`
    ///      plus the O(n²) dedup share at the 100-approver cap; the 1M base
    ///      leaves the `openCase` child (~150-200k observed) a >5x margin
    ///      after 63/64 forwarding, with the parent's burn/bubble branch
    ///      still affordable behind it.
    uint256 internal constant SLASH_GAS_PER_APPROVER = 300_000;
    uint256 internal constant SLASH_GAS_BASE = 1_000_000;

    /// @notice Where every burned slice of a challenger's bond goes — both the
    ///         SETTLE path's `settleBurnBps` and the FAIL path's
    ///         `forfeitBurnBps` send here.
    /// @dev    NOT A REAL BURN, because WOOD is a plain `IERC20` here — this
    ///         contract holds it behind the standard interface, which has no
    ///         `burn`, and nothing guarantees the deployed token exposes one or
    ///         would let this contract call it. The other candidate sink,
    ///         `address(0)`, is unusable: OpenZeppelin's ERC20 rejects a
    ///         transfer to it, so `safeTransfer(address(0), ...)` would revert
    ///         the whole resolution and pin the challenge in `Disputed`
    ///         forever — a burn that bricks the fail-safe is worse than no burn.
    ///         The conventional dead address is therefore the burn: no key for
    ///         it is known, nothing has ever come back out of it, and every
    ///         explorer and indexer already reads it as destroyed. Total supply
    ///         keeps counting these WOOD; nobody in this game can ever spend
    ///         them again, which is the only property the mechanism needs.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Ceiling on `forfeitBurnBps`. The burn is priced to make a
    ///      self-challenge round trip lose money, NOT to punish an honest
    ///      defence, and past some point the second effect swamps the first: a
    ///      guardian that correctly beat a bad-faith filing must still come out
    ///      clearly ahead, or answering a challenge becomes the losing move and
    ///      the counter-bond stops getting funded at all. Half the forfeit is
    ///      the outer edge of that — it still leaves an honest defender the
    ///      larger share — and it doubles as a cap on how much value a captured
    ///      owner can destroy per failed challenge.
    uint256 internal constant MAX_FORFEIT_BURN_BPS = 5_000;

    /// @dev Ceiling on `settleBurnBps`. Burning the whole bond would make a
    ///      CORRECT filing cost as much as a wrong one, which removes the only
    ///      on-chain reason to file at all.
    uint256 internal constant MAX_SETTLE_BURN_BPS = 5_000;

    /// @dev Ceiling on `inconclusiveBurnBps` (review #1, 2026-07-30). Set
    ///      IDENTICAL to `MAX_SETTLE_BURN_BPS`, not independently chosen,
    ///      because the finding this rate answers is precisely an ordering
    ///      constraint: an `Inconclusive` unwind is a NON-verdict — nothing was
    ///      adjudicated, nothing was recovered — while the settle path's burn
    ///      prices a filing that WAS answered and turned out correct. A
    ///      non-verdict must never be allowed to cost the challenger more than
    ///      a verdict that actually recovered value, or the contract would be
    ///      pricing silence above proof.
    /// @dev THIS CONSTANT ALONE DOES NOT ENFORCE THAT ORDERING (review round
    ///      2, 2026-07-30 — corrected). Equal ceilings bound the two RATES'
    ///      maximum legal values identically; they say nothing about where the
    ///      LIVE rates actually sit, and each setter originally checked only
    ///      its own ceiling. That let the owner set `inconclusiveBurnBps` to
    ///      4,000 while `settleBurnBps` sat at its 500 default — both calls
    ///      individually legal, together inverting the exact ordering this
    ///      constant's own comment claims to guarantee. The two setters below
    ///      now cross-check each other's LIVE value, not just this shared
    ///      ceiling — see `setSettleBurnBps` and `setInconclusiveBurnBps`. This
    ///      is the same class of bug as sWOOD's bounty ceiling, the ledger's
    ///      challenge window and the window invariant's five doors: guarding
    ///      one side of a two-sided constraint guards nothing.
    /// @dev NOW THE ROUND-4-AND-BEYOND STEADY STATE, not a flat rate applied
    ///      to every round (owner decision 2026-07-30, review round 3 —
    ///      escalating the Inconclusive burn). An audit found the flat 5%
    ///      default left `Inconclusive` the CHEAPEST repeatable freeze in the
    ///      contract: ~0.25% of coverage burned per ~13-day round (5% of a
    ///      bond that is itself 5% of coverage) annualizes to ~7.0%/yr to hold
    ///      a cohort's exit blocked, cheaper than the ~12.2%/yr self-deal →
    ///      timeout route (§4 gap 9) already priced and accepted elsewhere. A
    ///      FLAT rate cannot fix that by being set higher or lower: it is
    ///      invariant to repetition, so any single number is either too harsh
    ///      on an honest one-shot filer (whose vote merely missed quorum) or
    ///      too soft on a sustained grind — repetition is exactly the thing a
    ///      flat percentage cannot see. Round count is something the contract
    ///      CAN see (`inconclusiveRounds`), so the rate escalates with it
    ///      instead: see `_inconclusiveBurnBpsForRound` for the schedule. This
    ///      ceiling now bounds only the TOP of that schedule.
    uint256 internal constant MAX_INCONCLUSIVE_BURN_BPS = MAX_SETTLE_BURN_BPS;

    /// @dev Round-2 step of the escalating Inconclusive-burn schedule (owner
    ///      decision 2026-07-30). Unlike `inconclusiveBurnBps` (the round-4+
    ///      steady state), this and `INCONCLUSIVE_BURN_ROUND3_BPS` are fixed
    ///      literals, not owner-settable — the schedule's SHAPE (how fast it
    ///      ramps) is a one-time design decision; only its ultimate ceiling
    ///      (`inconclusiveBurnBps`, capped by `MAX_INCONCLUSIVE_BURN_BPS` and
    ///      cross-checked against `settleBurnBps`) is a governance knob. See
    ///      `_inconclusiveBurnBpsForRound` for how these compose and why the
    ///      result is ALWAYS additionally clamped to the live `settleBurnBps`
    ///      regardless of tier — these two literals are NOT covered by the
    ///      `setSettleBurnBps`/`setInconclusiveBurnBps` cross-check (that
    ///      check only bounds the round-4+ tier), so a `settleBurnBps` lowered
    ///      below 500 or 1,000 needs its own guard at the point the rate is
    ///      actually computed, not at either setter.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND2_BPS = 500;

    /// @dev Round-3 step — see `INCONCLUSIVE_BURN_ROUND2_BPS`'s note.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND3_BPS = 1_000;

    /// @notice Bond currency for both the challenger's bond and the accused's
    ///         counter-bond.
    IERC20 public immutable wood;

    /// @notice Source of truth for WHO covered a proposal and for how much, and
    ///         the contract whose coverage this game freezes (spec §3.4 freeze
    ///         scope: per-proposal, never whole-stake). This game must be the
    ///         ledger's `coverageFreezer`.
    IExposureLedger public exposureLedger;

    /// @notice Adapter certification registry. Read on the PASSED-challenge
    ///         path only (§3.4: "adapters demote only on a passed challenge");
    ///         this game must be its `authorizedDemoter`.
    ITierRegistryDemoterMinimal public tierRegistry;

    /// @notice The sole WOOD custodian and the contract that executes the
    ///         verdict slash (`slashToEscrow`, Plan C). This game must be its
    ///         `authorizedSlasher`. Owner-set AFTER construction because the
    ///         role is granted on sWOOD's side and the two are wired in either
    ///         order at deploy time.
    /// @dev    The compensation escrow is NOT named here: it is owner-set state
    ///         on sWOOD, deliberately not a `slashToEscrow` argument, so this
    ///         game can never redirect the ESCROW portion of a slash it
    ///         triggers to anywhere but that owner-configured sink.
    ///
    ///         CORRECTED (2026-07-29 review): this game CAN name a caller-
    ///         chosen conviction-bounty recipient (`slashToEscrow`'s
    ///         `bountyTo`/`bountyBps`, spec 2026-07-29 §2) — that channel has
    ///         to be caller-chosen, since only the caller knows which
    ///         challenger caused THIS conviction. This game does NOT restate
    ///         `MAX_CONVICTION_BOUNTY_BPS` as its own clamp anywhere:
    ///         `setConvictionBountyBps` and `setStakedWood` both read sWOOD's
    ///         ceiling live rather than duplicating the literal, for the same
    ///         reason sWOOD itself re-clamps `slashBpsPer` rather than
    ///         trusting `ExposureLedger` — sWOOD is the contract that actually
    ///         moves the WOOD, so a compromised or buggy caller here is
    ///         bounded by sWOOD's own ceiling, not by this game's. `_settle`
    ///         (Task 2, spec 2026-07-29 §2) forwards the challenge's pinned
    ///         `convictionBountyBpsAtFiling` ONLY on a CONTESTED escalated
    ///         conviction — a `Guilty` ruling where the challenger did not
    ///         fund its own counter-bond — and passes `(address(0), 0)` on
    ///         every other path: the silence settle, and an escalated
    ///         conviction the challenger self-funded (see `_settle`'s
    ///         `contested` gate).
    IStakedWood public stakedWood;

    /// @notice The adjudicator for disputed challenges (spec §3.5, Plan E) — the
    ///         only address that may `rule`.
    /// @dev    THE ZERO ADDRESS LEAVES PLAN D EXACTLY AS IT WAS: no caller can
    ///         match it, so `rule` is unreachable and a disputed challenge simply
    ///         times out in favour of the accused (D5). That is what makes the
    ///         court additive rather than a breaking change, and it is also the
    ///         off-switch — governance can unwire a captured court and fall back
    ///         to the fail-safe timeout instead of being stuck with an
    ///         adjudicator that can force slashes.
    address public court;

    /// @notice The owner's only lever that gates NEW filings (spec §4): true
    ///         refuses `file` alone. Never checked in `dispute`, `resolve`,
    ///         `rule`, or either claim path.
    /// @dev    WHAT THIS DOES NOT CLAIM: a live challenge's rights are not
    ///         wholly independent of the owner regardless of this flag —
    ///         `rule` still checks the LIVE `court` (not one pinned at
    ///         filing), and the settle path still reads `stakedWood` and
    ///         `exposureLedger` live. An owner that rotates any of those
    ///         mid-dispute changes what a pending challenge resolves into;
    ///         this pause does nothing about that, and was never meant to.
    ///         What IS true, and what this flag is the filing-side half of:
    ///         the ECONOMIC terms a challenge is judged and priced against —
    ///         `autoSlashDelayAtFiling`, `disputeTimeoutAtFiling`,
    ///         `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling` — are pinned
    ///         at filing precisely so the owner cannot move them under a
    ///         challenge already running. This flag adds the same guarantee
    ///         at the door: an owner can stop a NEW challenge from starting,
    ///         never dial the terms of one that already exists.
    /// @dev    THE ADVERSARY IS THE OWNER ITSELF (spec §4). Pausing referrals —
    ///         i.e. anything that could freeze `dispute`/`resolve`/`rule` mid-
    ///         flight — was rejected for exactly this reason: a disputed-but-
    ///         not-yet-referred challenge would drift into `disputeTimeout`'s
    ///         `_fail` branch and forfeit the challenger's bond by owner
    ///         inaction, not by anything the challenger did. Restricting the
    ///         lever to `file` means the worst a hostile or compromised owner
    ///         can do is stop NEW challenges from starting; it can never
    ///         freeze one that already exists.
    /// @dev    `setCourt` STAYS LIVE-READ ON PURPOSE, and this pause changes
    ///         nothing about that. Pinning the court per challenge, the same
    ///         way the economic terms above are pinned, would strand every
    ///         open dispute on a dead or compromised adjudicator the instant
    ///         governance replaced it — the live read is the rescue path that
    ///         lets a broken or replaced court still rule pending disputes,
    ///         instead of forcing all of them into a timeout acquittal.
    bool public filingsPaused;

    /// @notice How long after execution a proposal remains challengeable
    ///         (spec §5: 14d initial, matching the ledger's coverage window —
    ///         coverage that has expired out of the exposure buckets can no
    ///         longer be meaningfully frozen).
    uint256 public challengeWindow = 14 days;

    /// @notice Challenger bond as bps of the USD coverage a filing freezes
    ///         (spec §3.4/§5). Load-bearing: with no proof required this is the
    ///         only cost of a frivolous filing, and a failed challenge forfeits
    ///         it to the accused approvers.
    uint256 public challengerBondBps = 500;

    /// @notice The slice of a FAILED challenge's forfeited bond that is
    ///         destroyed rather than paid to the guardians that funded the
    ///         defence, in bps of the bond. Default 20%.
    /// @dev    THIS IS THE PRICE OF CHALLENGING YOURSELF. Every other rule in
    ///         this contract assumes the challenger and the accused are
    ///         opposing parties. They need not be: an approver can file against
    ///         its OWN executed proposal, post bond `B` as the challenger, then
    ///         fund the entire counter-bond pool itself for another `B`, sit out
    ///         `disputeTimeout` and collect its contribution back plus 100% of
    ///         the forfeit — because it contributed 100% of the pool. Net cost
    ///         zero, while every co-approver's coverage sat frozen for a month.
    ///         Pro-rata-to-contribution killed free-riding and opened exactly
    ///         this, because it made the forfeit follow the payer perfectly.
    /// @dev    A `msg.sender != challenger` check would be theatre: two
    ///         addresses defeat it, and this design has already conceded it
    ///         cannot police identity — it is why the counter-bond target is
    ///         pinned to the bond rather than charged by coverage share.
    /// @dev    SO THE SLICE IS BURNED, and burning is not one option among
    ///         several — it is the only one. The attacker controls both sides of
    ///         the trade, so ANY recipient it can reach is a round trip: paying
    ///         the challenger pays it, paying the contributors pays it (it is
    ///         the sole contributor), and a treasury or fee sink pays whoever
    ///         governs, which the attacker may be or may lobby. Only destruction
    ///         has no beneficiary to be, and the cost then falls on whoever
    ///         forfeited — which on the honest path is a genuinely bad-faith
    ///         challenger and on the attack path is the attacker itself.
    /// @dev    WHAT IT COSTS THE HONEST: a defender that beat a bad-faith filing
    ///         collects 80% of the forfeit instead of 100%. It still profits,
    ///         still recovers its whole contribution, and a free-riding approver
    ///         still collects nothing — the anti-free-ride property is untouched
    ///         because the burn is taken off the TOP, before the pro-rata split,
    ///         and changes only the size of the pot, never its key. The losing
    ///         challenger's position does not move at all: it forfeits the whole
    ///         bond either way, so the burn changes who receives it, not what
    ///         filing costs.
    /// @dev    ONLY THE FORFEIT IS BURNED. A guilty ruling is untouched: the
    ///         challenger still receives its bond back plus the whole pool. That
    ///         asymmetry is deliberate — on the settle path the challenger and
    ///         the accused genuinely are opposed (the accused is being slashed),
    ///         so no round trip exists there to price.
    uint256 public forfeitBurnBps = 2_000;

    /// @notice Silence window: an uncontested challenge auto-slashes once this
    ///         much time has passed since filing (§3.4 "undisputed challenge →
    ///         slash auto-executes after a delay"). See `MIN_AUTO_SLASH_DELAY`
    ///         for why its floor is load-bearing.
    uint256 public autoSlashDelay = 7 days;

    /// @notice How long a DISPUTED challenge waits for a ruling before failing
    ///         to the accused (D5). Measured from `filedAt`, like the auto-slash
    ///         delay, and always strictly greater than it — the two setters
    ///         enforce that jointly, because a timeout at or below the slash
    ///         clock would let a contested challenge fail before the slash it
    ///         was raised against was ever due.
    /// @dev    Deliberately generous relative to `autoSlashDelay`: D1 shifted
    ///         vigilance onto guardians, so the escalation they buy with a
    ///         counter-bond must be worth more than the window they lost.
    uint256 public disputeTimeout = 30 days;

    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in bps.
    /// @dev    A FILING IS NEVER FREE IN EITHER DIRECTION (review 🟠F4). The
    ///         settle path used to refund the bond in full, which the PR body
    ///         framed as "break-even at best" — but break-even means fully
    ///         SUBSIDISED for an attacker whose payoff is the consequence
    ///         rather than the bond: the slash of the accused approvers and the
    ///         demotion of the named adapter both came for the price of gas.
    ///         The companion half of that finding, an arbitrary adapter, is
    ///         closed structurally in `file`; this closes the free half.
    ///
    ///         20% by default, mirroring PR #26's fail-side `burnBps`. It is
    ///         deliberately a cost rather than a transfer to the accused: the
    ///         accused were just convicted, so paying them out of a correct
    ///         filing would invert the incentive it is meant to price.
    uint256 public settleBurnBps = 2_000;

    /// @notice Slice of a verdict slash paid to the challenger that caused it,
    ///         in bps (spec 2026-07-29 §2). Default 5%.
    /// @dev    ESCALATED CONVICTIONS ONLY (see `_settle`'s gate on `escalated`).
    ///         On the silence path an honest filer and a liar are
    ///         indistinguishable to this contract — both produce a real slash
    ///         against a real cohort, both would collect — so any bounty there
    ///         pays liars exactly as well as watchdogs, and the two
    ///         constraints (make honest filing profitable / keep false filing
    ///         unprofitable) are contradictory at every rate. The escalated
    ///         path separates them: the accused contested and lost on the
    ///         merits, and a liar who picks a guardian that is paying
    ///         attention forfeits the whole bond on `NotGuilty`. That is why
    ///         the bounty is safe here at any size, and why no anti-abuse
    ///         bound is needed beyond sWOOD's own ceiling.
    uint256 public convictionBountyBps = 500;

    /// @notice The ROUND-4-AND-BEYOND steady-state share of the challenger's
    ///         bond burned on an `Inconclusive` unwind, in bps (owner decision
    ///         2026-07-30). Default 20% — see `_inconclusiveBurnBpsForRound`
    ///         for the full schedule (rounds 1-3 are fixed, lower steps) and
    ///         `inconclusiveRounds` for what a "round" counts.
    /// @dev    THE LAST FREE FREEZE, CLOSED — THEN FOUND STILL TOO CHEAP. Every
    ///         other terminal path already prices what filing bought: the
    ///         silence settle burns `settleBurnBps`, a failed challenge
    ///         forfeits the whole bond, an escalated guilty verdict correctly
    ///         charges nothing because the filing was right. `Inconclusive`
    ///         was the one path that didn't, until review #1 (2026-07-30)
    ///         added a FLAT burn here. A follow-up audit (review round 3) found
    ///         that flat rate left `Inconclusive` the CHEAPEST repeatable
    ///         freeze in the contract: at the old 5% default, ~0.25% of
    ///         coverage burned per ~13-day round (5% of a bond that is itself
    ///         `challengerBondBps` = 5% of coverage) annualizes to only ~7.0%/yr
    ///         to hold a cohort's exit blocked — CHEAPER than the ~12.2%/yr
    ///         self-deal → timeout griefing route (§4 gap 9) this design
    ///         already prices and accepts elsewhere. Closing "free" and landing
    ///         on "cheapest" was not the goal.
    /// @dev    A FLAT RATE CANNOT FIX THIS AT ANY SINGLE VALUE, because a flat
    ///         percentage is invariant to repetition and the attack IS
    ///         repetition: raise it and a genuinely honest one-shot filer,
    ///         whose vote merely missed the participation floor through no
    ///         fault of its own, is charged the same as a grinder running the
    ///         tenth round against the same proposal; lower it and the grinder
    ///         is untouched. THE ROUND COUNT is the one thing a flat rate
    ///         cannot see that the contract already can (`inconclusiveRounds`
    ///         is incremented in `_refundAll` on every unwind), so the rate now
    ///         escalates with it instead of staying flat. Round 1 (a
    ///         proposal's first-ever attempt, or the first since the streak
    ///         last reset) is FREE — this variable plays no part in it — so an
    ///         honest one-shot filer is charged nothing; round 2 is 5%, round 3
    ///         is 10%, round 4 and every round after reads THIS variable,
    ///         clamped live to `settleBurnBps` (see
    ///         `_inconclusiveBurnBpsForRound`). At the defaults, the steady
    ///         state (20% of bond = 1% of coverage per round) annualizes to
    ///         ~28%/yr — now the MORE expensive of the two repeatable griefing
    ///         routes, not the cheaper one, which is the property this design
    ///         exists to establish.
    /// @dev    IT IS WORSE THAN A SINGLE FREE CYCLE WOULD SUGGEST. The M3 fix
    ///         re-arms `challengeableUntil` on every `Inconclusive` unwind
    ///         precisely so a stall cannot buy a PERMANENT acquittal — but that
    ///         same re-arming means the identical cycle is repeatable
    ///         indefinitely against one proposal for as long as turnout keeps
    ///         missing the floor. Capping the re-arm was rejected: that would
    ///         partially reopen M3, whose whole point is that stalling must buy
    ///         a delay, never an acquittal. Escalating the burn instead is what
    ///         re-bounds the repetition without touching the window extension
    ///         at all — the stall still works, but each additional round costs
    ///         strictly more than the last.
    /// @dev    THIS CONTRACT CANNOT TELL THE TWO POPULATIONS APART WITHIN A
    ///         SINGLE ROUND. An honest challenger whose evidence was real, and
    ///         an attacker who filed purely to freeze a cohort's coverage and
    ///         was content to let turnout do the rest, produce the IDENTICAL
    ///         on-chain shape in any one round: a completed counter-bond pool,
    ///         a vote that missed quorum. There is no per-round signal that
    ///         separates them. What DOES separate the two populations is
    ///         REPETITION — an honest filer has no reason to keep re-filing
    ///         against a proposal whose vote keeps missing quorum, while a
    ///         grinder's whole strategy depends on doing exactly that — so the
    ///         schedule is keyed on repetition rather than trying to price a
    ///         single round harder.
    /// @dev    DELIBERATELY BELOW `settleBurnBps`, and kept that way by BOTH
    ///         setters cross-checking each other's LIVE value (review round 2,
    ///         2026-07-30), not merely by sharing a ceiling with it: a
    ///         non-verdict recovered nothing, so it must cost strictly less
    ///         than a verdict that recovered real value, never more. See
    ///         `setInconclusiveBurnBps`/`setSettleBurnBps` for the enforcement
    ///         and `MAX_INCONCLUSIVE_BURN_BPS` for why the shared ceiling by
    ///         itself was not enough. THAT CHECK COVERS ONLY THIS VARIABLE
    ///         (the round-4+ tier) — rounds 2 and 3 are fixed literals
    ///         (`INCONCLUSIVE_BURN_ROUND2_BPS`/`_ROUND3_BPS`) outside this
    ///         setter pair entirely, which is why `_inconclusiveBurnBpsForRound`
    ///         additionally clamps EVERY tier to the live `settleBurnBps`
    ///         rather than relying on the setters alone.
    uint256 public inconclusiveBurnBps = 2_000;

    /// @notice WOOD held on behalf of live (`Filed`/`Disputed`) challenges —
    ///         the sum of their challenger bonds and counter-bond POOLS.
    /// @dev    The §4 invariant is `wood.balanceOf(this) >= bondedWood`. Every
    ///         wei this contract pays out was a bond or a pool contribution, so
    ///         the two are equal except for WOOD somebody donated here by
    ///         mistake — which no path ever spends. Note that a PARTIAL pool
    ///         counts here exactly like a complete one: the contributions are
    ///         held, and every terminal path either refunds them, forfeits them
    ///         or splits them, so the decrement is always `bond + pool`. The
    ///         BURNED slice is no exception: it is part of the challenger's
    ///         bond, it leaves the contract like any other payout, and it leaves
    ///         this counter with it — `bond + pool` still describes the whole
    ///         decrement, and custody still lands back on `bondedWood` after.
    uint256 public bondedWood;

    /// @inheritdoc IChallengeGame
    /// @dev WOOD owed to counter-bond funders of TERMINAL challenges, not yet
    ///      collected. Deliberately separate from `bondedWood` rather than
    ///      folded into it: `bondedWood` means "held for a LIVE challenge", and
    ///      "no live challenge implies `bondedWood == 0`" is an invariant the
    ///      suite and the §4 fuzz test both lean on. Keeping the two apart
    ///      preserves that while widening the custody invariant to
    ///      `wood.balanceOf(this) >= bondedWood + unclaimedWood`.
    ///
    ///      Never returns to zero exactly on a failed challenge: lazy pro-rata
    ///      shares floor-divide independently, so wei-scale dust stays
    ///      accounted here forever. That is the price of removing the payout
    ///      loop, and it is why the invariant is `>=` rather than `==`.
    uint256 public unclaimedWood;

    uint256 public challengeCount;

    /// @inheritdoc IChallengeGame
    /// @dev NEVER READ AS A STORED ABSOLUTE — `file` always maxes this value
    ///      against the live `executedAt + challengeWindow` baseline at the
    ///      call site, and this mapping never compares against that baseline
    ///      at write time. An earlier version of `_refundAll` wrote
    ///      `challengeableUntil[rk] = max(this write, the PREVIOUS write)`,
    ///      which reads the same but is not: `challengeWindow` is live,
    ///      mutable state, so an owner who shortened it, let a challenge
    ///      unwind while it was short, then restored it, left this mapping
    ///      holding a deadline SMALLER than a fresh proposal would ever
    ///      compute — and with no setter for this mapping, that shrink was
    ///      permanent. `file`'s call-site max is what actually makes
    ///      "extend, never shorten" hold; this mapping only ever needs to
    ///      raise the floor, never defend against having stored a stale one.
    mapping(bytes32 reviewKey => uint256) public challengeableUntil;

    /// @inheritdoc IChallengeGame
    /// @dev HOW MANY TIMES THIS PROPOSAL HAS GONE `Inconclusive` (owner
    ///      decision 2026-07-30, escalating the Inconclusive burn). Incremented
    ///      in `_refundAll` in the same `!_convicted[rk]` neighbourhood that
    ///      already re-arms `challengeableUntil` — a round only counts if the
    ///      proposal is still contestable at all. `file` reads it to pin the
    ///      escalated rate (`_inconclusiveBurnBpsForRound`) and resets it to
    ///      zero whenever the re-armed window has lapsed with nobody refiling
    ///      inside it — see `file`'s own comment for why that reset is keyed
    ///      on `challengeableUntil`, not a simpler elapsed-time clock.
    /// @dev KEYED ON THE PROPOSAL ALONE, NOT `(reviewKey, challenger)` — same
    ///      tradeoff `_convicted` and `challengeableUntil` already make, for
    ///      the same reason: a per-challenger counter is trivially reset by
    ///      switching identity. A sybil filing round 2 from a fresh address
    ///      would read a fresh zero and be priced as round 1 again, exactly
    ///      undoing the escalation this counter exists to enforce. Per-proposal
    ///      accounting closes that: whoever files next pays for the PROPOSAL's
    ///      history, not their own wallet's history against it.
    mapping(bytes32 reviewKey => uint256) public inconclusiveRounds;

    mapping(uint256 challengeId => Challenge) internal _challenges;

    /// @dev Who has paid into a challenge's counter-bond pool, in first-payment
    ///      order and without duplicates — a repeat contributor tops up its
    ///      existing entry rather than appending a second one. This is the
    ///      payout set on BOTH unwind paths: refunds on a settle, refunds plus
    ///      the pro-rata forfeit on a failure. It is bounded because `dispute`
    ///      admits only the accused set, which the ledger itself bounds.
    mapping(uint256 challengeId => address[]) internal _contributors;

    /// @dev Per-contributor totals, kept AFTER resolution rather than cleared:
    ///      the pro-rata split a terminal challenge paid out stays reconstructible
    ///      on-chain, and no path re-reads a terminal challenge's pool anyway
    ///      (`dispute` requires `Filed`, and both unwinds require a live status).
    mapping(uint256 challengeId => mapping(address contributor => uint256)) internal _contributed;

    /// @dev The most recent challenge against a proposal. Only meaningful while
    ///      that challenge is still live — `_liveChallengeId` re-checks status
    ///      rather than trusting the pointer, so a terminal challenge never
    ///      blocks a later, legitimate one. Kept for indexers; the blocking
    ///      question is now asked per challenger via `_liveByChallenger`.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

    /// @dev ONE SLOT PER CHALLENGER, NOT PER PROPOSAL (review 🔴F3). The old
    ///      one-live-challenge-per-proposal rule handed the accused cohort a
    ///      free permanent immunity: `disputeTimeout` (30d) outlives
    ///      `challengeWindow` (14d), so a single self-filed, self-disputed
    ///      challenge occupied the only slot until the window shut, and `_fail`
    ///      returned both bonds to the same cohort. Cost of the squat: zero.
    ///      Keyed by `(reviewKey, challenger)`, an honest filer always has its
    ///      own slot, so the squat denies nothing and only costs the squatter.
    mapping(bytes32 challengerKey => uint256 challengeId) internal _liveByChallenger;

    /// @dev How many challenges against a proposal are live. The coverage
    ///      freeze is REFCOUNTED on this rather than toggled per challenge —
    ///      concurrent filings must not let the first one to terminate unfreeze
    ///      coverage the others are still pinning.
    mapping(bytes32 reviewKey => uint256 liveCount) internal _liveCount;

    /// @dev Whether a proposal's approvers have already been convicted by an
    ///      earlier settled challenge. The approvers' liability is ONE
    ///      liability — they underwrote one proposal — and sWOOD enforces that
    ///      independently via `_verdictSlashed` keyed on the same review key
    ///      (PR #24 🟠N2). Without this flag the second concurrent settle would
    ///      hit that guard, revert `ApproverAlreadySlashed`, and wedge an
    ///      otherwise-correct challenge in `Filed` with no terminal path.
    ///
    ///      THIS FLAG IS ONLY HALF THE DEDUP, and the missing half was a wedge
    ///      of its own (review PR #56 B1). sWOOD's `_verdictSlashed` is keyed on
    ///      `keccak256(governor, proposalId)` — STABLE ACROSS DEPLOYMENTS of
    ///      this game — while this mapping is per-deployment storage that starts
    ///      empty. Redeployment is the supported migration path: this contract
    ///      is not upgradeable, and `StakedWood.setAuthorizedSlasher`,
    ///      `ExposureLedger.setCoverageFreezer` and
    ///      `TokenCourt.setChallengeGame` all exist precisely to re-point at a
    ///      new one. So a V1 conviction — a PARTIAL slash is the norm, the
    ///      approvers keep live stake — leaves every V2 filing against the same
    ///      proposal believing the liability is uncollected. `_settle` would
    ///      then call `slashToEscrow` and revert `ApproverAlreadySlashed` for
    ///      good: `Filed`'s only other exit is `rule`, which demands `Disputed`.
    ///      Bond and counter-bond stranded (`claimContribution` reverts
    ///      `ChallengeNotTerminal`), `_liveCount[key]` never decremented, so the
    ///      coverage stays frozen forever. The authoritative answer is sWOOD's
    ///      own `verdictSlashed` view, now asked at BOTH ends via
    ///      `_verdictAlreadyCollected`, so this flag is a cheap local cache of a
    ///      cross-deployment fact rather than the fact itself.
    mapping(bytes32 reviewKey => bool) internal _convicted;

    /// @dev CONSTRUCTION IS THE THIRD DOOR onto the game/ledger `challengeWindow`
    ///      mismatch, and it was the one left open. `setChallengeWindow` bounds a
    ///      NEW window against the wired ledger and `setExposureLedger` bounds a
    ///      NEW ledger against the current window — but a game deployed straight
    ///      against a ledger whose own `challengeWindow` sits below this
    ///      contract's 14-day default passed through neither, and nothing obliges
    ///      a deployment to call a setter at all. Same bound, same reason (a game
    ///      window above the ledger's lets a filing freeze exposure the ledger has
    ///      already aged out of its epoch buckets), applied at the remaining entry.
    ///
    ///      NOT ALSO CHECKED HERE: the `coverageFreezer` grant `setExposureLedger`
    ///      demands. This address does not exist yet while this body runs, so the
    ///      ledger cannot possibly have been pointed at it — requiring it would
    ///      make every deployment impossible rather than catch a mis-wiring. The
    ///      deploy scripts' own pre-flight covers the wiring step that follows.
    constructor(address initialOwner, address wood_, address exposureLedger_, address tierRegistry_)
        Ownable(initialOwner)
    {
        if (wood_ == address(0) || exposureLedger_ == address(0) || tierRegistry_ == address(0)) revert ZeroAddress();
        if (challengeWindow > IExposureLedger(exposureLedger_).challengeWindow()) revert InvalidParameter();
        wood = IERC20(wood_);
        exposureLedger = IExposureLedger(exposureLedger_);
        tierRegistry = ITierRegistryDemoterMinimal(tierRegistry_);
    }

    /// @dev Has this proposal's ONE liability already been collected — by an
    ///      earlier challenge in this deployment, or by ANY earlier deployment of
    ///      this game against the same sWOOD (review PR #56 B1)?
    ///
    ///      The local flag is checked first: it is a storage read and it answers
    ///      the common case. The sWOOD scan is what makes the answer correct
    ///      across a redeploy. ANY hit is decisive, because `slashToEscrow`
    ///      reverts `ApproverAlreadySlashed` if any member of the array it is
    ///      handed is already marked under this `caseKey` — so one marked
    ///      approver means a slash of this cohort can never land again, and every
    ///      path that would attempt one must be diverted rather than left to
    ///      revert.
    ///
    ///      BOUNDED: the loop runs over the ledger's accused set, which the ledger
    ///      itself caps, and short-circuits on the first hit — the wedge case is
    ///      the cheap one; the ordinary "nothing collected yet" case pays the full
    ///      scan, which is the same order of work the settle path already does.
    ///
    ///      Vacuous with no slasher wired: there is no `_verdictSlashed` to
    ///      consult, and `_settle` fails closed on that separately.
    function _verdictAlreadyCollected(bytes32 key, address[] memory accused) private view returns (bool) {
        if (_convicted[key]) return true;
        IStakedWood swood = stakedWood;
        if (address(swood) == address(0)) return false;
        for (uint256 i = 0; i < accused.length; i++) {
            if (swood.verdictSlashed(key, accused[i])) return true;
        }
        return false;
    }

    /// @dev Same derivation as `ExposureLedger` and `GuardianRegistry`.
    function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    // ── Filing ──

    /// @inheritdoc IChallengeGame
    /// @dev The predicate is recorded and emitted but never read: see the
    ///      contract-level note and D1. Adding a branch here — for any
    ///      predicate — reintroduces the two-security-models problem this
    ///      design exists to avoid.
    /// @dev CEI: the challenge is recorded before the freeze and before the
    ///      bond transfer, so neither external call can observe or re-enter a
    ///      half-written challenge.
    /// @dev THE CHALLENGER NAMES THE ADAPTER it accuses; the chain does not
    ///      derive it. Derivation would mean re-parsing the proposal's execute
    ///      calls here — a second calldata parser beside the vault's
    ///      `_guardBatchCalls`, which is precisely the duplication D1 removed
    ///      from this design — and a multi-call proposal has no single
    ///      derivable culprit anyway. Naming it is also the more honest model:
    ///      a challenge is an assertion, and *which* adapter misbehaved is part
    ///      of the assertion, filed under the same bond as the rest of it.
    function file(
        address governor,
        uint256 proposalId,
        Predicate predicate,
        address adapterTarget,
        bytes4 adapterSelector,
        string calldata evidenceURI
    ) external returns (uint256 challengeId) {
        // THE OWNER'S ONLY LEVER (spec §4), checked FIRST and before anything
        // else runs: pausing stops a NEW filing from ever starting, full stop.
        // It says nothing about any challenge already in flight — see
        // `filingsPaused`'s natspec for why that boundary is deliberate.
        if (filingsPaused) revert FilingsPaused();

        // A challenge accuses an EXECUTED proposal: there is no drain to allege
        // before execution, and `executedAt` is what §3.8's pre-drain snapshot
        // is derived from on the slash path. The whole proposal is read once
        // and the two fields the verdict needs are PINNED onto the challenge
        // (review 🟡F10) — `_settle` used to re-read them from a mutable
        // external up to a dispute-timeout later.
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);
        uint256 executedAt = p.executedAt;
        if (executedAt == 0) revert NotExecuted();

        // M3 (spec §5): the gate is the LARGER of the ordinary
        // `executedAt + challengeWindow` and whatever `_refundAll` has raised
        // `challengeableUntil` to for an earlier `Inconclusive` unwind on
        // this same proposal. Without a raised floor, reaching `Inconclusive`
        // — anywhere from `voteWindow` up to `autoSlashDelay + voteWindow`
        // after filing, since the accused controls when inside that span the
        // counter-bond pool completes — could land past the ordinary window
        // and make the acquittal permanent.
        //
        // RECOMPUTED AS A MAX ON EVERY CALL, NOT READ AS A STORED ABSOLUTE.
        // An earlier version of this gate read `challengeableUntil[key]`
        // directly once non-zero, falling back to the baseline only while it
        // was still zero. `challengeWindow` is live, mutable state, so an
        // owner who shortened it, let a challenge unwind while it was short,
        // then restored it, left the mapping holding a deadline SMALLER than
        // a fresh proposal would ever compute — and with no setter for
        // `challengeableUntil`, that shrink was permanent. Taking the max
        // against the live baseline on every read, rather than trusting
        // whatever was stored at the last write, is what makes "extend,
        // never shorten" true against the thing that actually matters.
        //
        // `key` is computed here, once, rather than again a few lines down —
        // it is needed for both this gate and the `AlreadyConvicted`/
        // `AlreadyChallenged` checks below.
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 deadline = executedAt + challengeWindow;
        uint256 extended = challengeableUntil[key];
        if (extended > deadline) deadline = extended;
        if (block.timestamp > deadline) revert WindowClosed();

        // THE GRIND RESETS WHEN THE WINDOW LAPSES NATURALLY (owner decision
        // 2026-07-30, escalating the Inconclusive burn — see
        // `inconclusiveBurnBps` and `_inconclusiveBurnBpsForRound`). Checked
        // against `challengeableUntil[key]` specifically, not the combined
        // `deadline` above: once any round has gone `Inconclusive`,
        // `challengeableUntil[key]` is always >= the ordinary baseline
        // (`_refundAll` only ever raises it to at least
        // `ruledAt + challengeWindow`, and `ruledAt >= executedAt`), so
        // `block.timestamp > challengeableUntil[key]` can only be true here
        // either while the key was never written (harmless no-op —
        // `inconclusiveRounds[key]` is already zero) or when a FRESH
        // execution has moved the ordinary baseline far enough forward that
        // this filing is legal again despite the last streak's grace window
        // having long since lapsed. Either way, the repetition this schedule
        // prices has stopped, so the counter resets rather than carrying a
        // stale streak forward onto an unrelated later filer — without this,
        // an old, cold proposal would punish a legitimate late filer forever.
        if (block.timestamp > challengeableUntil[key] && inconclusiveRounds[key] != 0) {
            inconclusiveRounds[key] = 0;
        }

        // WHICH ADAPTER A PROPOSAL TOUCHED IS FACT, NOT ASSERTION (review 🟠F4).
        // The filer still NAMES the adapter — D1's argument against deriving it
        // stands — but a named adapter must at least appear in the proposal's
        // own stored execute calls. This is a membership test over data the
        // governor already holds, not a second calldata parser, so it adds no
        // second security model. Without it, a passed challenge demoted an
        // arbitrary certified adapter anywhere in the registry.
        if (adapterTarget != address(0)) {
            _requireAdapterInProposal(governor, proposalId, adapterTarget, adapterSelector);
        }

        // NOTHING LEFT TO COLLECT, SO NOTHING LEFT TO CHALLENGE (review 🟡F12).
        // The approvers underwrote ONE proposal and owe ONE liability; once a
        // settled challenge has collected it, every later filing settles
        // straight into the `VerdictAlreadyCollected` branch and can never
        // reach a slash. It still FROZE the coverage on the way there, though,
        // and the freeze is what bars an accused approver from
        // `claimUnstakeGuardian` — so a filing that could not possibly convict
        // anyone bought another `autoSlashDelay` of lock on already-slashed
        // collateral. Cheaply: the accused have no reason to dispute a filing
        // that cannot take anything more from them, so the griefer reliably
        // reaches settle and is refunded all but `settleBurnBps` — 1% of
        // coverage USD net at the defaults (`settleBurnBps` 20% of a bond
        // that is itself `challengerBondBps` 5% of coverage — fixed while the
        // numbers were in hand, review round 3, 2026-07-30; this comment
        // pre-dates that fix and had been off by 10x), from as many funded
        // addresses as it likes, since
        // 🔴F3 made the slots per-challenger. A failed challenge is different
        // and deliberately still allowed: it collected nothing, so the
        // liability is outstanding and a fresh filing is legitimate.
        if (_convicted[key]) revert AlreadyConvicted();
        // One live challenge per CHALLENGER (review 🔴F3) — see
        // `_liveByChallenger`. Concurrency is safe because the freeze is
        // refcounted below and the conviction is deduped by `_convicted`.
        bytes32 challengerKey = _challengerKey(key, msg.sender);
        if (_liveChallengeId(_liveByChallenger[challengerKey]) != 0) revert AlreadyChallenged();

        // The accused set is the ledger's committed approvers (D2): slashing
        // exactly those is what makes §2's inequality hold, because recovery is
        // the sum of THEIR bonds. A released commitment reports zero, so it
        // contributes nothing to the frozen total.
        (address[] memory covering, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 coverageUsd;
        uint256 accusedCount;
        for (uint256 i = 0; i < committedUsd.length; i++) {
            coverageUsd += committedUsd[i];
            if (committedUsd[i] != 0) accusedCount++;
        }
        if (coverageUsd == 0) revert NothingToFreeze();

        // THE SAME "NOTHING LEFT TO COLLECT" REFUSAL AS `_convicted` ABOVE, ASKED
        // OF THE CONTRACT THAT ACTUALLY KNOWS (review PR #56 B1). `_convicted` is
        // this deployment's storage and starts empty on a redeploy; sWOOD's
        // `verdictSlashed` is keyed on `(governor, proposalId)` and survives one.
        // Without this, a game deployed to replace an earlier one accepted
        // filings against proposals whose cohort the OLD game had already
        // convicted, froze their coverage, took the bond — and then could never
        // terminate: `_settle`'s `slashToEscrow` reverts `ApproverAlreadySlashed`
        // and `rule` is unreachable from `Filed`.
        //
        // REFUSED AT THE DOOR rather than absorbed at settle, for exactly 🟡F12's
        // reason: a challenge that cannot possibly convict anyone must not be
        // able to buy another `autoSlashDelay` of lock on already-slashed
        // collateral. `_settle` is made safe as well (see its own diversion into
        // `VerdictAlreadyCollected`), because the slasher can be re-pointed —
        // and the collection can therefore happen — AFTER a legitimate filing.
        //
        // The accused set is the committed cohort, the same one `_settle` sends
        // to `slashToEscrow`; a released approver reports zero committed USD and
        // is excluded from both.
        address[] memory accused = new address[](accusedCount);
        for (uint256 i = 0; i < committedUsd.length; i++) {
            if (committedUsd[i] == 0) continue;
            accused[--accusedCount] = covering[i];
        }
        if (_verdictAlreadyCollected(key, accused)) revert AlreadyConvicted();

        // RESERVATIONS ARE NOT LIABILITY (review 🟡F13). The sum above is what
        // the cohort RESERVED, and `recordApproval` deliberately over-reserves —
        // every approver books up to the full coverage, because at vote time any
        // one of them might end up carrying it alone. So it exceeds what a
        // conviction could ever take, by a factor that GROWS WITH THE APPROVER
        // COUNT: five well-funded approvers on one proposal reserve five times
        // its need. Sizing the bond off it made a proposal more expensive to
        // challenge the better covered it was, while the recoverable total
        // stayed flat — the exact inversion of D4, which sizes the bond to the
        // exposure a filing freezes. `slashBpsFor` has always priced the slash
        // against the ALLOCATION for this reason; `liabilityUsd` is that same
        // basis, asked for once.
        //
        // CAPPED, NOT REPLACED: an under-covered cohort whose reservations fall
        // short of the need is still priced on what it pledged, because that is
        // all there is to take.
        //
        // CAUGHT, because `liabilityUsd` reads the ASSET feed and this function
        // otherwise reads none. A stale feed must not make filing impossible
        // during exactly the market stress a drain happens in — the same
        // liveness hole the ledger already documents on the slash path. Falling
        // back to the reservation sum over-charges the challenger, which is
        // recoverable; being unable to file at all is not.
        try exposureLedger.liabilityUsd(governor, proposalId) returns (uint256 liability) {
            if (liability != 0 && liability < coverageUsd) coverageUsd = liability;
        } catch {}

        // D4: the bond scales with the exposure the filing freezes, converted
        // at the ledger's conservative haircut price. Fail-closed on an unset
        // price and on a bond that floors to zero — an unpriced or free
        // challenge is a free freeze, which is precisely what the bond exists
        // to prevent.
        // TWO DISTINCT FAILURES, NAMED SEPARATELY (review 🔵F14). They shared
        // `InvalidParameter`, which made them indistinguishable to a caller —
        // and they are opposites. An unset price is TRANSIENT and protocol-wide:
        // wait for governance. A truncated bond is PERMANENT and specific to one
        // proposal: nobody can ever challenge it while the coverage and the
        // price stand, which is a fact worth surfacing rather than hiding behind
        // a shared selector.
        // THE COMPOSED PRICE, the one every other rail divides by (review 🟠F16).
        // This read used to be `woodUsdPriceX8()` — the raw owner-set scalar,
        // seeded at roughly a 30-day low — and it was the ONLY consumer read of
        // that scalar in all of `src/`. Every other conversion, including
        // `proposerBondWood` (the identical formula shape, commented "composed —
        // matches the slash rails"), uses `woodPriceX8()`.
        //
        // Same unit and precision, DIFFERENT NUMBER: `_haircut` applies to the
        // fallback branches too, so the two diverge with no feed wired at all —
        // one `setWoodHaircutBps` call is enough. Since the bond DIVIDES by the
        // price, a stale-high scalar under-charges, and the scalar is stale
        // exactly when it matters: on a WOOD crash the feed follows within
        // minutes while `MIN_PRICE_UPDATE_INTERVAL` holds the scalar for a day.
        // Freezing a guardian's coverage would get cheapest during the market
        // stress a drain happens in, and this bond is the only cost of a
        // frivolous filing.
        //
        // It also mixed bases inside one formula once F13 landed: `liabilityUsd`
        // derives its numerator at the composed price, so numerator and divisor
        // disagreed within the same expression.
        //
        // Fail-closed semantics are preserved — the composed price is zero
        // exactly when its source is, so `WoodPriceUnset` still means unpriced.
        // Reading it composed additionally un-bricks the documented emergency
        // stop: `setWoodUsdPrice(0)` with a healthy feed no longer blocks every
        // filing protocol-wide.
        uint256 priceX8 = exposureLedger.woodPriceX8();
        if (priceX8 == 0) revert WoodPriceUnset();
        uint256 bondWood = (((coverageUsd * challengerBondBps) / BPS_DENOMINATOR) * 1e8) / priceX8;
        if (bondWood == 0) revert BondTooSmall();

        challengeId = ++challengeCount;
        _challenges[challengeId] = Challenge({
            governor: governor,
            proposalId: proposalId,
            challenger: msg.sender,
            bondWood: bondWood,
            counterBondWood: 0,
            predicate: predicate,
            status: Status.Filed,
            filedAt: block.timestamp,
            frozenCoverageUsd: coverageUsd,
            adapterTarget: adapterTarget,
            adapterSelector: adapterSelector,
            executedAt: executedAt,
            vault: p.vault,
            // BOTH CLOCKS ARE PINNED HERE (review 🟠F5). Read live, they let the
            // owner shorten `autoSlashDelay` after a filing and retroactively
            // erase a window the accused was still inside — which is exactly
            // what `MIN_AUTO_SLASH_DELAY`'s own natspec promises cannot happen,
            // since that floor bounds the PARAMETER and not the window any
            // given challenge actually got. Symmetrically it let the timeout be
            // raised against a live dispute, extending the freeze 6x.
            autoSlashDelayAtFiling: autoSlashDelay,
            disputeTimeoutAtFiling: disputeTimeout,
            // AND BOTH BURN RATES, for the same reason (review 🔵F15). The
            // earlier argument for leaving these live — that they price a refund
            // rather than bound a window somebody is relying on — does not hold:
            // the challenger relied on `settleBurnBps` when it decided to file
            // and cannot withdraw, and the accused rely on `forfeitBurnBps`
            // when they decide to fund the counter-bond. A raise after either
            // commitment takes up to half of what the winning side collects, on
            // a challenge that was already correct.
            settleBurnBpsAtFiling: settleBurnBps,
            forfeitBurnBpsAtFiling: forfeitBurnBps,
            // Pinned for the same reason as the rates above (spec 2026-07-29
            // §2): read live, a post-filing raise would change what the
            // challenger stood to collect on a conviction it already bonded
            // itself against. Forwarded to `slashToEscrow` only on an
            // escalated conviction — see `_settle`.
            convictionBountyBpsAtFiling: convictionBountyBps,
            // Written only by `_fail`, which is the sole path that gives the
            // pool's funders anything beyond their stake back.
            forfeitPayoutWood: 0,
            // Pinned for the same reason as every other rate above (review #1,
            // 2026-07-30): the challenger relies on this rate the moment it
            // posts the bond, with no way to withdraw once a court vote later
            // misses its participation floor. A live read would let the owner
            // raise it mid-dispute and take a larger bite of a bond the
            // challenger committed under a lower one. NOW THE ESCALATED
            // SCHEDULE VALUE (owner decision 2026-07-30), not the flat
            // `inconclusiveBurnBps` directly — `_inconclusiveBurnBpsForRound`
            // reads `inconclusiveRounds[key]` (already reset above if the
            // streak lapsed) and returns round 1's free rate, round 2/3's
            // fixed steps, or the round-4+ `inconclusiveBurnBps` ceiling,
            // whichever applies, clamped live to `settleBurnBps`.
            //
            // TRUE APPEND (review round 2, 2026-07-30): ordered here, after
            // `forfeitPayoutWood`, to match the struct's true-append field
            // order — see `IChallengeGame.Challenge`'s own note on why this
            // field sits last rather than grouped with the other `*AtFiling`
            // rates above.
            inconclusiveBurnBpsAtFiling: _inconclusiveBurnBpsForRound(inconclusiveRounds[key])
        });
        _lastChallenge[key] = challengeId;
        _liveByChallenger[challengerKey] = challengeId;
        bondedWood += bondWood;

        // Refcounted: only the first live challenge freezes, only the last one
        // to terminate unfreezes.
        if (_liveCount[key]++ == 0) exposureLedger.freezeCoverage(governor, proposalId);

        wood.safeTransferFrom(msg.sender, address(this), bondWood);
        emit ChallengeFiled(challengeId, governor, proposalId, msg.sender, predicate, bondWood, evidenceURI);
    }

    /// @dev The membership test behind `AdapterNotInProposal`. Matches on
    ///      `(target, selector)` across the proposal's stored execute calls. A
    ///      call with fewer than 4 bytes of calldata carries no selector and
    ///      can only match a filing that names one it cannot have, so it is
    ///      skipped rather than treated as a wildcard.
    function _requireAdapterInProposal(address governor, uint256 proposalId, address target, bytes4 selector)
        private
        view
    {
        BatchExecutorLib.Call[] memory calls = ISyndicateGovernor(governor).getExecuteCalls(proposalId);
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].target != target) continue;
            bytes memory data = calls[i].data;
            if (data.length < 4) continue;
            if (bytes4(data) == selector) return;
        }
        revert AdapterNotInProposal();
    }

    /// @dev Per-challenger slot key. Namespaced under the review key so two
    ///      proposals can never share a slot.
    function _challengerKey(bytes32 key, address challenger) private pure returns (bytes32) {
        return keccak256(abi.encode(key, challenger));
    }

    // ── Dispute ──

    /// @inheritdoc IChallengeGame
    /// @dev THE POOL'S TARGET MATCHES THE CHALLENGER'S BOND, and does not move:
    ///      the accused side buys the escalation at exactly the price the
    ///      challenger paid for the accusation, so neither can price the other
    ///      out of the game. What CHANGED is only who pays it — see the
    ///      contract-level note on identity-splitting for why the total must
    ///      stay pinned here rather than being charged by the payer's own share.
    /// @dev THE OVERSHOOT IS CLAMPED, not refunded. `amountWood` is reduced to
    ///      the shortfall exactly as `ExposureLedger.recordApproval` clamps a
    ///      guardian's share to what a proposal still needs, so the contract
    ///      never holds a wei it must later hand back for having been overpaid.
    ///      That deletes a refund path rather than implementing one, and a
    ///      refund path is precisely where this design strands funds.
    /// @dev THE STATUS FLIPS THE MOMENT THE POOL IS FULL, in the same call. That
    ///      is what keeps `_settle`'s two entries distinguishable by status
    ///      alone: `Filed` implies a pool strictly below target (it never bought
    ///      a dispute, so it is refunded) and `Disputed` implies a full one (it
    ///      did, so it is forfeited). Nothing else in the contract has to
    ///      re-derive which case it is in.
    /// @dev The contribution window closes exactly where the auto-slash opens
    ///      (`filedAt + autoSlashDelayAtFiling`), so the two are disjoint by
    ///      construction: at the boundary second the silence is already the
    ///      verdict and there is nothing left to contest. A pool that is still
    ///      short at that instant simply loses the DISPUTE — the contributions
    ///      themselves are refunded by `_settle` — which is the point, because a
    ///      part-funded defence is not a defence.
    /// @dev THE CLOCK IS THE ONE THIS CHALLENGE RECEIVED, not the one governance
    ///      happens to prefer now (review 🟠F5). Read live, the owner could
    ///      shorten `autoSlashDelay` after a filing and retroactively close a
    ///      contribution window the accused were still inside — and pooling
    ///      makes that strictly worse than it was for a single disputer, because
    ///      a partially-filled pool would lose to a deadline that moved under it
    ///      mid-collection.
    /// @dev CEI: every storage write lands before the `transferFrom`, so the
    ///      token cannot observe or re-enter a half-updated pool.
    /// @dev BEST-EFFORT AUTO-REFERRAL (Task 8), run LAST — after the transfer
    ///      and both events, so it never reorders anything CEI above already
    ///      guarantees. Once the pool completes, `Disputed` is a status with
    ///      nothing to do next until SOMEONE calls `TokenCourt.refer` — an
    ///      unbounded gap between "escalated" and "actually referred" is what
    ///      fed review finding E1's timeout race, because a referral filed too
    ///      close to `disputeTimeout` cannot fit `refer`'s own `voteWindow +
    ///      FINALIZE_BUFFER` clock check and simply never opens. Calling
    ///      `refer` here closes most of that gap for free, on the same
    ///      transaction that already paid to complete the pool.
    ///
    ///      IS THIS THE SAME SEVERITY AS `finalize`'s bare-catch bug one task
    ///      ago (the one that swallowed `InsufficientSlashGas` and burned a
    ///      `Guilty` verdict with no retry path)? NO, and the difference is not
    ///      cosmetic: `refer` is permissionless and stays reachable for as long
    ///      as `filedAt + disputeTimeoutAtFiling - now >= voteWindow +
    ///      FINALIZE_BUFFER` holds, so a skipped auto-referral here is a
    ///      RECOVERABLE miss — literally anyone can call `TokenCourt.refer`
    ///      directly, immediately, no different from the manual fallback this
    ///      whole feature is layered on top of. `rule`'s bare catch swallowed a
    ///      VERDICT, which had no such fallback: once dropped, the accused was
    ///      acquitted by timeout with no path back. A dropped verdict is
    ///      terminal; a skipped referral is a call away from being un-skipped.
    ///      That asymmetry is what makes a broad catch RIGHT here and WRONG
    ///      there — SO THE CATCH STAYS BROAD, any revert swallowed and reported
    ///      via `AutoReferFailed`, unlike `finalize`'s selector-filtered one.
    ///
    ///      AND UNLIKE `finalize`, NOTHING HERE GATES THE CALL ON GAS EITHER —
    ///      an earlier version of this function reverted the whole `dispute`
    ///      when `gasleft()` fell below a floor, reasoning that a starved
    ///      `refer` call should never be allowed to land in the catch. That
    ///      reasoning inverted the two functions' actual risk. `finalize` HAS
    ///      NO `gasleft()` CHECK OF ITS OWN EITHER — the floor that matters
    ///      lives on the callee side, in `ChallengeGame._settle`'s
    ///      `InsufficientSlashGas` — what `finalize` gets right is BUBBLING
    ///      rather than swallowing that revert (its catch is selector-filtered
    ///      to only `WrongStatus`, everything else - `NotCourt` included -
    ///      propagates), and
    ///      that is cheap to do because swallowing is what would be
    ///      catastrophic there: the verdict was already decided, the case's
    ///      tally is intact regardless of how `finalize` reverts, and the
    ///      court holds no WOOD — a reverted `finalize` costs nothing but
    ///      an honest retry. `dispute` is the OPPOSITE shape: it is not
    ///      reporting a decision, it is HOW THE ACCUSED BUY THEIR DEFENCE. If
    ///      this function reverted for insufficient gas, the accused could not
    ///      complete their counter-bond, the auto-slash clock would keep
    ///      running, and they would be slashed by the silence verdict WITHOUT
    ///      EVER REACHING ADJUDICATION — unrecoverable, and strictly worse than
    ///      the miss a gas floor exists to prevent. Guarding a recoverable
    ///      failure (a skipped referral, fixed by anyone calling `refer`
    ///      directly) by manufacturing an unrecoverable one (a denied defence)
    ///      is the wrong trade, not merely an unnecessary one.
    ///
    ///      THE RECOVERY PATH IS ALSO WIDE, not merely present, which is why
    ///      no gas floor is needed to make best-effort acceptable here.
    ///      `refer` is permissionless, and the CHALLENGER — who wants the
    ///      slash and is paid from the forfeited counter-bond pool on a guilty
    ///      ruling — is strongly motivated to call it if this attempt lands in
    ///      the catch. `refer`'s own `InsufficientClock` guard bounds how long
    ///      that window stays open, and — as of the window-invariant setters
    ///      (B3, review 2026-07-29 audit, item 6) — that bound is now PARTLY a
    ///      construction guarantee, not merely a parameter contingency:
    ///      `setAutoSlashDelay`, `setDisputeTimeout`, `setCourt` and
    ///      `TokenCourt.setVoteWindow` / `setChallengeGame` each enforce
    ///      `autoSlashDelay + voteWindow + FINALIZE_BUFFER <= disputeTimeout`
    ///      against whatever the OTHER contract is CURRENTLY wired to at call
    ///      time. What is still a contingency rather than a guarantee: those
    ///      checks bind CURRENT state, not any already-open challenge's PINNED
    ///      clock (see `_requireWindowFits`'s own RESIDUAL note), and the
    ///      deploy pre-flight (Task 10) remains the only check for a pair's
    ///      very FIRST wiring, before either side has anything wired to
    ///      validate against (`setCourt`'s check is vacuous while
    ///      `court == address(0)`, by design — unwiring must always stay
    ///      legal). At today's defaults the invariant holds with room to
    ///      spare: a pool that completes promptly (well inside
    ///      `autoSlashDelay`, typically 7 days) leaves most of
    ///      `disputeTimeout` (30 days) still ahead of it — 17 to 24 days of
    ///      room, depending on when in the 7-day window the pool completes,
    ///      against the ~6 days `voteWindow + FINALIZE_BUFFER` needs by
    ///      default. A late-completing pool has less room, symmetrically, but
    ///      that scarcity is inherent to the clocks `dispute` already runs
    ///      against, not something a gas floor here could change.
    ///
    ///      A GAS FLOOR WOULD ALSO BE NEAR-UNUSABLE ON THE TARGET CHAIN, which
    ///      compounds rather than merely repeats the argument above: sizing a
    ///      structural floor for `refer`'s worst case (the 100-approver
    ///      accused-set cap) landed near a whole Arbitrum-Orbit block's gas —
    ///      close enough to make `dispute` itself unreliable on Robinhood
    ///      (chain 4663) purely to guard a failure mode that recovers itself.
    ///      There is also no cheap count to scale a smaller floor by: `dispute`
    ///      no longer reads `approversOf` at all (open counter-bond standing,
    ///      §4/PR #50), so sizing anything tighter than the worst case would
    ///      mean spending an extra external call solely to size a gas check.
    ///
    ///      THE TRUST BOUNDARY WIDENED HERE, not just the gas discussion above:
    ///      before Task 8 this contract never called OUT to `court` — only
    ///      `court` called IN, via `rule`. Now `dispute` calls into `court`
    ///      itself, so a malicious court can re-enter `game.rule(challengeId,
    ///      ...)` from inside this very try block: `msg.sender == court`
    ///      passes trivially (it IS the court, mid-call), and the challenge's
    ///      status is `Disputed` at that point — exactly what `rule` requires.
    ///      Not exploitable: every storage write this function makes happens
    ///      before the call (the CEI note above), so there is no half-updated
    ///      state for a re-entrant `rule` to observe or corrupt, and forcing a
    ///      verdict through `rule` is a privilege `court` already holds
    ///      unconditionally — reaching it one call frame deeper changes
    ///      nothing about what it can do. Stated rather than left implicit: a
    ///      wired `court` is trusted for re-entrancy now, not only for the
    ///      verdicts it hands back through `rule`.
    function dispute(uint256 challengeId, uint256 amountWood) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        // The window this challenge RECEIVED, not the one governance happens to
        // prefer right now (review 🟠F5).
        if (block.timestamp >= c.filedAt + c.autoSlashDelayAtFiling) revert WindowClosed();

        // ANYONE MAY FUND THE DEFENCE (review 🟠F18). This was restricted to the
        // accused, which answered "who may BUY the escalation" — correct — but
        // once the counter-bond became a POOL the same check silently also
        // answered "who may help FILL it", and those are different questions. A
        // cohort ten percent short with an hour left could not be topped up by
        // anyone: not another guardian, not the protocol itself. The pool
        // failed, everyone was slashed, and the contributions went home.
        //
        // The restriction's OTHER job was bounding the contributor list, because
        // resolution used to loop it and transfer to each. `claimContribution`
        // removed that loop — each claimant computes its own share in O(1) — so
        // the list length no longer matters and the bound is not load-bearing.
        //
        // Skin in the game is enforced ECONOMICALLY, not by identity: a guilty
        // ruling forfeits the whole pool to the challenger, so an outside funder
        // risks real capital rather than buying free influence. That is a
        // strictly better gate than an allowlist — and it lets a third party who
        // believes the accused innocent PAY TO FORCE ADJUDICATION rather than
        // let an unproven silence verdict stand, which is D1's weakest point.
        //
        // What this does NOT change: a self-funded round trip (file, then fund
        // your own counter-bond) still costs only `forfeitBurnBps` while the
        // coverage stays frozen. That is §4 gap 9, "priced, not eliminated" —
        // widened here from the accused to anyone, at the same price, not newly
        // created.
        uint256 target = c.bondWood;
        uint256 pool = c.counterBondWood;
        // `Filed` guarantees `pool < target`, so the shortfall is never zero and
        // a clamped contribution is never zero either.
        uint256 shortfall = target - pool;
        uint256 amount = amountWood < shortfall ? amountWood : shortfall;
        if (amount == 0) revert NothingToContribute();

        // First payment appends; a top-up finds its existing entry. Keeping the
        // list duplicate-free is what makes the failure-path split a single pass
        // over it with no double-payment.
        if (_contributed[challengeId][msg.sender] == 0) _contributors[challengeId].push(msg.sender);
        _contributed[challengeId][msg.sender] += amount;

        pool += amount;
        c.counterBondWood = pool;
        bondedWood += amount;

        bool complete = pool == target;
        if (complete) c.status = Status.Disputed;

        wood.safeTransferFrom(msg.sender, address(this), amount);
        emit CounterBondContributed(challengeId, msg.sender, amount, pool);
        if (complete) emit ChallengeDisputed(challengeId, pool);

        // BEST-EFFORT, AND DELIBERATELY UNGUARDED — the opposite call from
        // `TokenCourt.finalize`, for a reason worth stating rather than
        // pattern-matching. Both wrap a cross-contract call in a `try/catch`;
        // what differs is WHICH SIDE HAS A RETRY PATH.
        //
        //   — `finalize`'s catch had to NARROW to a selector filter: a
        //     swallowed failure there dropped a verdict permanently, with no
        //     way to re-run it, so anything transient must bubble.
        //   — This catch must stay BROAD, and must not be fronted by a gas
        //     floor: `dispute` is how the accused BUYS ITS DEFENCE. A revert
        //     here — for gas, or for anything else the court does — leaves the
        //     counter-bond incomplete, the auto-slash clock running, and the
        //     accused SLASHED BY THE SILENCE VERDICT WITHOUT EVER REACHING
        //     ADJUDICATION. That is unrecoverable.
        //
        // What the catch gives up is recoverable by comparison: `refer` is
        // permissionless, so anyone may open the case afterwards — and the
        // challenger, who wants the slash, is the party most motivated to. At
        // today's defaults the window is wide: a dispute completing inside
        // `autoSlashDelay` leaves 17-24 days of room, depending on when in
        // that window the pool completes, against the ~6 days `refer`'s own
        // `InsufficientClock` guard demands — and that margin is now PARTLY a
        // construction guarantee rather than a pure parameter contingency
        // (the window-invariant setters, B3; see the natspec above
        // `dispute`), though the RESIDUAL documented there still applies to
        // any already-open challenge. Guarding a recoverable failure by
        // manufacturing an unrecoverable one is the wrong trade in every gas
        // regime, which is why no floor stands here.
        if (complete) {
            address courtAddr = court;
            // No court wired means no referral is possible either way — Plan
            // D's timeout remains the only path out of `Disputed`, same as
            // everywhere else in this contract that reads `court` live.
            if (courtAddr != address(0)) {
                try ITokenCourt(courtAddr).refer(challengeId) {}
                catch {
                    emit AutoReferFailed(challengeId);
                }
            }
        }
    }

    // ── Resolution ──

    /// @inheritdoc IChallengeGame
    /// @dev Permissionless on purpose. Neither terminal path lets the caller
    ///      choose anything — the outcome is fixed by the state and the clock —
    ///      so making it open removes the last place a privileged party could
    ///      sit on a verdict.
    function resolve(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        Status status = c.status;
        if (status == Status.Filed) {
            if (block.timestamp < c.filedAt + c.autoSlashDelayAtFiling) revert DelayNotElapsed();
            _settle(challengeId, c);
        } else if (status == Status.Disputed) {
            if (block.timestamp < c.filedAt + c.disputeTimeoutAtFiling) revert DelayNotElapsed();
            _fail(challengeId, c);
        } else {
            revert WrongStatus();
        }
    }

    /// @inheritdoc IChallengeGame
    /// @dev THE COURT SUPPLIES ONLY THE VERDICT ENUM. `Guilty` reuses `_settle`
    ///      verbatim — the same path an UNDISPUTED challenge takes, so the slash
    ///      is at sWOOD's `maxSlashBps` with no severity ramp (§3.5 "ground truth
    ///      established", D7) — `NotGuilty` reuses `_fail`, the same path the
    ///      timeout takes, because a not-guilty ruling and an unruled escalation
    ///      say the same thing about the accused: the disputer was right, so it
    ///      gets its counter-bond back and the challenger's bond forfeits. And
    ///      `Inconclusive` (spec 2026-07-28 §4) reuses `_refundAll`: the vote
    ///      missed its participation floor, so nothing was decided on the
    ///      merits and both sides unwind whole rather than one paying the
    ///      other. There is deliberately no severity parameter here; a court
    ///      that could dial the slash would be negotiating with the accused,
    ///      not ruling on them.
    /// @dev RULING BEATS THE TIMEOUT: all three branches are terminal and
    ///      `resolve` acts only on `Filed`/`Disputed`, so the clock can never
    ///      overwrite a verdict already handed down. That ordering is the
    ///      entire point of this entrypoint — it is what stops a genuinely
    ///      guilty approver from disputing and running out `disputeTimeout`.
    /// @dev CEI is inherited from `_settle`/`_fail`/`_refundAll`, which each
    ///      write the terminal status before any external call; the event is
    ///      emitted first so the log reads verdict-then-consequence.
    function rule(uint256 challengeId, Verdict verdict) external {
        if (msg.sender != court) revert NotCourt();
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Disputed) revert WrongStatus();
        emit ChallengeRuled(challengeId, verdict);
        if (verdict == Verdict.Guilty) {
            _settle(challengeId, c);
        } else if (verdict == Verdict.NotGuilty) {
            _fail(challengeId, c);
        } else {
            _refundAll(challengeId, c);
        }
    }

    /// @dev THE CHALLENGE PASSED. Either nobody contested inside the window and
    ///      the silence IS the adjudication (§3.4, D1), or the court ruled guilty
    ///      (§3.5). Both say the same thing about the accused, so both slash the
    ///      covering approvers into the compensation escrow, demote the named
    ///      adapter, and return the challenger's bond.
    ///
    ///      TWO ENTRIES, TWO POOL STATES — and the status is what separates them.
    ///      This helper's correctness has twice rested on WHO could reach it:
    ///      Plan D could only enter from `Filed`, where the counter-bond was
    ///      structurally zero, so it ignored the counter-bond entirely, and Plan
    ///      E's `Disputed` entry had to add a release before it stopped stranding
    ///      funds. Pooling widens the reachable set AGAIN — a partial pool can
    ///      now arrive here — so the invariants are re-derived rather than
    ///      assumed:
    ///
    ///      — FROM `Disputed` (a guilty ruling): the pool is EXACTLY `bondWood`,
    ///        because the contribution that completed it is the very one that
    ///        flipped the status. THE WHOLE POOL FORFEITS TO THE CHALLENGER, on
    ///        top of its returned bond. This reverses Plan E's rule that a
    ///        counter-bond is "the price of the escalation, not a stake on its
    ///        outcome" — see the contract-level note. Refunded, it made disputing
    ///        free for a guilty approver and left a winning challenger paid
    ///        nothing; forfeited, the escalation costs what it is worth and the
    ///        challenger that was right is paid by the side that was wrong.
    ///
    ///      — FROM `Filed` (the silence verdict): the pool is strictly BELOW
    ///        `bondWood` — zero, or a part-funded defence that ran out of clock.
    ///        IT IS REFUNDED TO ITS CONTRIBUTORS. They never bought a dispute:
    ///        the escalation exists only once the pool is complete, so there is
    ///        no escalation here whose price could be forfeited. Paying a partial
    ///        pool to the challenger would charge for a good never delivered, and
    ///        keeping it would strand it in this contract forever and break §4's
    ///        custody invariant permanently. Note that a contributor is refunded
    ///        AND still slashed: the slash is the verdict, the refund is only the
    ///        unwinding of a purchase that never completed.
    function _settle(uint256 challengeId, Challenge storage c) private {
        IStakedWood swood = stakedWood;
        // Fail closed: without the slasher wired there is no verdict to
        // execute, and settling anyway would burn the challenge for nothing.
        // NOT a wedge (review minor): `setStakedWood` is the owner escape —
        // wiring the slasher makes every challenge stuck here resolvable, and
        // the freeze it holds is released by that same resolution. There is no
        // state a wired deployment can reach in which this branch is terminal.
        if (address(swood) == address(0)) revert ZeroAddress();

        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        bytes32 key = _reviewKey(governor, proposalId);
        // Rates come from the LEDGER, not from one protocol-wide severity: each
        // approver is slashed for what they underwrote. Read before
        // `unfreezeCoverage` below only for readability — unfreezing flips a
        // `_frozen` flag and leaves the bookings intact, so the order is not
        // load-bearing.
        //
        // The proposal is NOT re-read here any more (review 🟡F10): `vault` and
        // `executedAt` are pinned onto the challenge at filing, so the verdict
        // cannot be moved by a governor mutating either between the filing and
        // a resolution up to a dispute timeout later.
        (address[] memory approvers, uint256[] memory slashBpsPer) = _accusedWithRates(governor, proposalId);

        uint256 bond = c.bondWood;
        uint256 pool = c.counterBondWood;
        // READ BEFORE THE TERMINAL WRITE. This is the only thing that keeps the
        // two entries apart — a moment later every challenge here is `Settled`
        // and a full pool is indistinguishable from a partial one.
        bool escalated = c.status == Status.Disputed;
        c.status = Status.Settled;
        bondedWood -= (bond + pool);

        _releaseFreeze(key, governor, proposalId);

        uint256 slashedWood;
        uint256 caseId;
        // ASKED OF sWOOD, NOT ONLY OF THE LOCAL FLAG (review PR #56 B1). The
        // local flag catches the concurrent-challenge case this branch was
        // written for; the sWOOD read catches the case it could not — an EARLIER
        // DEPLOYMENT of this game having already collected this cohort under the
        // same, deployment-independent `caseKey`. `file` refuses such a filing at
        // the door, but that gate reads the slasher wired AT FILING TIME and the
        // owner may re-point sWOOD (or the old game may settle a concurrent
        // challenge) at any point afterwards, so the settle path cannot assume it
        // was reachable. Diverting here rather than letting `slashToEscrow`
        // revert is the whole point: a revert leaves the challenge in `Filed`
        // with no terminal exit at all, taking the bond, the counter-bond pool
        // and the coverage freeze with it.
        if (_verdictAlreadyCollected(key, approvers)) {
            // A concurrent challenge — or a previous deployment of this game —
            // already collected this proposal's one liability. Settling again
            // would revert inside sWOOD's per-verdict dedup and strand this
            // challenge with no terminal path, so the conviction is simply
            // recorded as already-collected. The local flag is set on the way
            // out so the next `file` against this proposal is refused by the
            // cheap storage read rather than re-deriving the same answer.
            _convicted[key] = true;
            emit VerdictAlreadyCollected(challengeId, governor, proposalId);
        } else {
            _convicted[key] = true;

            // Pin the gas floor sWOOD's burn-vs-bubble classifier assumes (N-4).
            // Checked as late as possible so everything already spent counts
            // against the caller, not the margin.
            if (gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE) {
                revert InsufficientSlashGas();
            }

            // D6 + review 🔴F1: the slash basis is the proposal's EXECUTION
            // instant, pinned at filing — never `filedAt`. `_slashOne` sizes the
            // own-stake leg off `_stakeCheckpoints.upperLookupRecent(openedAt)`,
            // and `requestUnstakeGuardian` pushes a ZERO checkpoint with no
            // cooldown and no transfer. Anchored at `filedAt`, an accused
            // approver zeroed its own basis with one reversible transaction
            // between the drain and the accusation: a 100% conviction recovered
            // nothing and opened no compensation case, after which
            // `cancelUnstakeGuardian` put the stake back. `executedAt` predates
            // any state the accused could move in response to being accused,
            // and it is the more correct basis for the delegated leg besides —
            // delegated capital at the drain, not at the accusation.
            // `executedAt - 1 < executedAt` keeps sWOOD's
            // `snapshotTimestamp <= openedAt` bound satisfied.
            // ESCALATED CONVICTIONS ONLY (spec 2026-07-29 §2). On the silence
            // path an honest filer and a liar are indistinguishable to this
            // contract - both produce a real slash against a real cohort and
            // both would collect - so any bounty there pays liars exactly as
            // well as watchdogs, and the two constraints (make honest filing
            // profitable / keep false filing unprofitable) are contradictory at
            // every rate. The escalated path separates them: the accused
            // contested and lost on the merits, and a liar who picks a guardian
            // that is paying attention forfeits the whole bond on `NotGuilty`.
            // That is why the bounty is safe here at any size, and why no
            // anti-abuse bound is needed - PROVIDED the pool that bought the
            // escalation was actually funded by one of the ACCUSED (see
            // `contested` below; PR review 2026-07-29 IMPORTANT-1).
            //
            // A CONTEST IS A DEFENCE THE ACCUSED ACTUALLY BOUGHT (spec 2026-07-29
            // §2). `status == Disputed` only says SOMEBODY completed the pool,
            // and PR #50 opened that to anyone - so a challenger can stage a
            // contest from a second address it controls, recover its own pool
            // on a `Guilty` ruling, and collect the bounty for a fight nobody
            // had. Asking "was the funder the challenger?" is unanswerable:
            // addresses are free, and a same-wallet check is defeated by a
            // second one. Asking "was the funder one of the ACCUSED?" is not -
            // the accused set is the ledger's approver list for this exact
            // proposal (`approvers`, already in memory from
            // `_accusedWithRates` above), so faking membership means staking
            // WOOD and recording an approval on the very proposal you are
            // about to accuse, joining the cohort your own conviction slashes.
            // That converts an unenforceable identity predicate into a
            // verifiable ROLE predicate, and it is what prices the sybil.
            //
            // ACCEPTED FALSE NEGATIVE: a third party who funds a defence
            // because it believes the accused innocent still forces
            // adjudication - `dispute`'s open standing is untouched - but a
            // `Guilty` ruling it provoked pays the challenger no bounty.
            // Narrowing what EARNS the bounty, never what is allowed to
            // happen.
            //
            // BOUNDED, NOT UNBOUNDED: the scan below runs over `approvers`,
            // already capped at the accused-set size (100) and already looped
            // under the gas floor checked just above (`SLASH_GAS_PER_APPROVER`
            // per approver) - no new unbounded work.
            //
            // REENTRANCY NOTE (reviewer Minor): this reads `_contributed`
            // AFTER `c.status = Status.Settled` and after `_releaseFreeze`'s
            // external call into `exposureLedger.unfreezeCoverage`. That is
            // safe today only because `claimableContribution` returns 0 for a
            // `Settled` challenge whose pool is complete (`c.counterBondWood
            // == c.bondWood`, the exact case reachable here), so nothing a
            // re-entrant ledger could trigger can zero `_contributed` before
            // this scan reads it. A future change to that view's Settled
            // branch would silently reopen the bounty to a since-refunded
            // "contributor".
            //
            // The PAYOUT branch below stays keyed on `escalated` alone: a
            // self- or sybil-disputed win still returns the challenger's own
            // bond and pool (nothing new happens there) - this only closes the
            // BOUNTY channel on top of it.
            bool contested;
            if (escalated) {
                for (uint256 i = 0; i < approvers.length; ++i) {
                    if (_contributed[challengeId][approvers[i]] != 0) {
                        contested = true;
                        break;
                    }
                }
            }
            (slashedWood, caseId) = swood.slashToEscrow(
                key,
                c.executedAt,
                approvers,
                slashBpsPer,
                c.vault,
                c.executedAt - 1,
                contested ? c.challenger : address(0),
                contested ? c.convictionBountyBpsAtFiling : 0
            );
        }

        // §3.4: "adapters demote only on a passed challenge" — and only the one
        // the filing actually named (D7), which `file` has already checked
        // against the proposal's own execute calls (🟠F4).
        //
        // BEST-EFFORT, DELIBERATELY (review 🟠F11). `demoteByChallenge` is
        // role-gated on the registry's side, so a single governance transaction
        // — `setAuthorizedDemoter` pointed anywhere else while this challenge
        // was live — used to make this line revert and take the whole verdict
        // with it: `resolve()` could never complete, so the slash never landed,
        // the bond never came back, the coverage stayed frozen, and every
        // accused approver stayed barred from `claimUnstakeGuardian`, forever.
        // A terminal path must not be hostage to a revocable role. Losing the
        // certification revocation is the smallest of those harms and the only
        // recoverable one — the registry owner's own `demote` fixes it — so the
        // miss is surfaced as an event and the verdict proceeds.
        if (c.adapterTarget != address(0)) {
            try tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector) {}
            catch {
                emit AdapterDemotionFailed(challengeId, c.adapterTarget, c.adapterSelector);
            }
        }

        // A CORRECT FILING IS CHEAP, NOT FREE (🟠F4) — ON THE UNADJUDICATED PATH
        // ONLY, which is the scope F4's own argument gives it. That finding
        // exists because a filing nobody answered handed "an attacker whose
        // payoff is the consequence rather than the bond" the slash AND the
        // adapter demotion for the price of gas; the burn is what makes the
        // silence verdict cost something. A guilty COURT ruling is the other
        // entry to this function and it is not that case: the challenge was
        // tested on the merits and won, a bogus one loses there, so the free-
        // consequence attack cannot reach this branch. Taxing an adjudicated
        // win would price down exactly the filings the mechanism wants.
        //
        // Hence: burn on `!escalated`, and on `escalated` the challenger takes
        // its bond whole plus the pool the losing side forfeited.
        //
        // Exactly `bond + pool` leaves on BOTH branches, matching the decrement
        // above to the wei — the burn is a third sink on the silence path, not
        // an extra outflow.
        uint256 burned;
        if (escalated) {
            wood.safeTransfer(c.challenger, bond + pool);
        } else {
            burned = (bond * c.settleBurnBpsAtFiling) / BPS_DENOMINATOR;
            if (burned != 0) {
                wood.safeTransfer(BURN_ADDRESS, burned);
                emit ChallengerBondBurned(challengeId, burned);
            }
            wood.safeTransfer(c.challenger, bond - burned);
            // The part-funded pool moves from live accounting to unclaimed; its
            // funders collect with `claimContribution`. Nothing is pushed, so a
            // single reverting recipient can no longer brick the resolution.
            _bookRefund(challengeId, pool);
        }
        emit ChallengeSettled(challengeId, slashedWood, caseId);
    }

    /// @dev Drops this challenge's hold on the proposal's coverage, unfreezing
    ///      only when it was the last live one. Concurrent filings each pin the
    ///      same coverage, and the first to terminate must not release it out
    ///      from under the others.
    function _releaseFreeze(bytes32 key, address governor, uint256 proposalId) private {
        uint256 live = _liveCount[key];
        // Defensive: a rewired ledger or a re-pointed game must not underflow
        // the refcount into a permanent freeze.
        if (live != 0) {
            _liveCount[key] = live - 1;
            if (live == 1) exposureLedger.unfreezeCoverage(governor, proposalId);
        }
    }

    /// @dev Moves a pool from LIVE accounting to UNCLAIMED, so its funders can
    ///      collect via `claimContribution`. Two callers, two pool states:
    ///      `_settle`'s undisputed branch reaches this with a PART-FUNDED
    ///      pool — the silence verdict landed before any defence completed —
    ///      and `_refundAll`'s inconclusive ruling reaches it with a COMPLETE
    ///      pool — `rule` only accepts `Disputed`, where the pool is by
    ///      construction full. Either way the stored amounts are booked as-is;
    ///      this helper does not care which shape it was handed.
    ///
    ///      This used to loop the contributor list and transfer to each, which
    ///      is what forced `dispute` to keep that list short and made one
    ///      reverting recipient able to brick the whole resolution. Nothing is
    ///      transferred here now; the stored `_contributed` amounts ARE the
    ///      entitlements, and `claimContribution` zeroes them on the way out.
    function _bookRefund(uint256 challengeId, uint256 pool) private {
        if (pool != 0) unclaimedWood += pool;
    }

    /// @dev D5 — THE FAIL-SAFE. A disputed challenge escalates to the court of
    ///      §3.5. Without this path both bonds and the frozen coverage would sit
    ///      stuck forever whenever no court answered, and anyone could pin a
    ///      guardian's budget indefinitely just by filing. So an unruled
    ///      escalation fails in favour of the accused: not slashing is the right
    ///      default when the adjudicator is missing.
    ///
    ///      ALSO THE NOT-GUILTY VERDICT PATH since Plan E: this function asserts
    ///      nothing about the clock — no deadline check, no `filedAt` arithmetic
    ///      — it only unwinds the bonds and the freeze. An acquittal and an
    ///      unruled escalation therefore settle identically, which is correct,
    ///      because both say the defence was right: the pool returns and the
    ///      challenger's bond forfeits.
    ///
    ///      THE FORFEIT IS SPLIT PRO-RATA TO CONTRIBUTION, NOT TO COVERAGE, and
    ///      that reversal is the whole anti-free-riding mechanism. Paying the
    ///      accused SET by committed share — what this did before — meant an
    ///      approver could sit out the defence, let somebody else carry the
    ///      entire counter-bond, and still collect its coverage share of the
    ///      winnings. Every accused approver's best move was therefore to
    ///      contribute nothing, which is exactly how a collective defence fails
    ///      to get funded. Keyed to contribution, the upside accrues only to
    ///      whoever actually bought the escalation that produced it, in the
    ///      proportion they bought it.
    ///
    ///      A SLICE OF THE FORFEIT IS BURNED FIRST (`forfeitBurnBps`), and only
    ///      the remainder is split. The reason is that the two sides of this
    ///      trade need not be two parties: an approver can challenge its own
    ///      proposal and then fund the whole counter-bond itself, so a forfeit
    ///      paid perfectly to contributors is paid straight back to the
    ///      challenger. Burning is the only sink that is not a round trip for
    ///      somebody who controls both sides — see `forfeitBurnBps` for the full
    ///      argument and `BURN_ADDRESS` for why "burn" means a dead address.
    ///      The burn comes off the TOP, before the pro-rata pass, so it changes
    ///      the size of the pot and nothing about how it is keyed: a
    ///      non-contributing approver still collects zero.
    ///
    ///      ENTRY IS ONLY EVER FROM `Disputed` — `resolve` sends `Filed` to
    ///      `_settle`, and `rule` demands `Disputed` — so the pool is complete
    ///      and the contributor list is non-empty. The empty-list branch below is
    ///      defensive only, and it no longer depends on the ledger at all: the
    ///      payout set is this contract's own state, so a rewired ledger cannot
    ///      strand the bond here the way it once could.
    ///
    ///      THAT BRANCH DELIBERATELY DOES NOT BURN. It is not the failure path
    ///      with nobody to pay — it is the path where NO DEFENCE WAS EVER
    ///      BOUGHT, so there is no forfeit to take a slice of: the bond is
    ///      returned to the challenger intact, exactly as it was before this
    ///      parameter existed. Burning there would destroy a bond that is being
    ///      handed BACK, punishing a challenger for a resolution nobody
    ///      contested, and it would price nothing — the self-challenge attack
    ///      cannot reach it, because completing the pool is what produces
    ///      `Disputed` in the first place, and completing the pool means at
    ///      least one contributor. `ChallengeFailed` reports `(0, 0)` there:
    ///      nothing forfeited, nothing burned.
    ///
    ///      ACCEPTED COST, now scoped to an UNWIRED game (`court == address(0)`):
    ///      with no adjudicator, a genuinely guilty approver can still dispute
    ///      and run out this clock. That is strictly better than an indefinite
    ///      freeze, because it keeps the mechanism live and bounded — and once a
    ///      court is wired, `rule` beats the timeout and closes it. Note that
    ///      pooling does not widen this hole: the escalation still costs the
    ///      accused side the full bond, it is merely split among them.
    function _fail(uint256 challengeId, Challenge storage c) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;

        uint256 bond = c.bondWood;
        uint256 pool = c.counterBondWood;
        address challenger = c.challenger;
        c.status = Status.Failed;
        bondedWood -= (bond + pool);

        _releaseFreeze(_reviewKey(governor, proposalId), governor, proposalId);

        // Defensive: unreachable from `Disputed`, where the pool is by
        // construction complete and therefore funded by at least one address.
        // Left in so the bond can never be stranded if a future caller widens
        // the reachable states again — the hazard this file has now hit twice.
        if (pool == 0) {
            wood.safeTransfer(challenger, bond);
            emit ChallengeFailed(challengeId, 0, 0);
            return;
        }

        // The burn is taken off the top and the REMAINDER is what the funders
        // split. Integer division makes `burnAmount <= bond`, so `payout`
        // cannot underflow, and a `forfeitBurnBps` of zero reproduces the
        // pre-burn behaviour to the wei.
        uint256 burnAmount = (bond * c.forfeitBurnBpsAtFiling) / BPS_DENOMINATOR;
        uint256 payout = bond - burnAmount;
        // Skipped when the parameter is zero: a zero-value transfer would only
        // emit a misleading `Transfer` to the dead address.
        if (burnAmount != 0) wood.safeTransfer(BURN_ADDRESS, burnAmount);

        // §3.4: "failed challenge → challenger bond forfeits to the accused" —
        // to the ones that funded the defence, pro-rata to what each put in.
        //
        // RECORDED, NOT PAID (review 🟠F18). This used to loop the contributor
        // list and transfer to each, which forced `dispute` to keep that list
        // short and let a single reverting recipient brick the resolution —
        // stranding both bonds and leaving the coverage frozen, the same class
        // as 🟠F11. Storing the TOTAL to split lets each funder compute its own
        // slice in `claimContribution` at O(1), so the list length stops
        // mattering and open contribution standing becomes safe.
        //
        // The cost is rounding. The push version gave the last recipient the
        // remainder so the forfeit distributed to the wei; lazy shares are
        // floor-divided independently, so up to `contributors - 1` wei is never
        // claimable. It stays in the contract, still covered by `unclaimedWood`,
        // and is bounded at wei scale — the loop is what buying exactness would
        // cost.
        c.forfeitPayoutWood = payout;
        unclaimedWood += pool + payout;
        emit ChallengeFailed(challengeId, bond, burnAmount);
    }

    /// @dev THE `Inconclusive` PATH (spec 2026-07-28 §4) — AN UNWIND, NOT A
    ///      VERDICT. The court's vote missed its participation floor, so
    ///      neither side was found right or wrong: nothing here is a slash,
    ///      nothing is a forfeit, and the counter-bond pool simply comes back.
    ///
    ///      THE CHALLENGER'S BOND IS NO LONGER RETURNED WHOLE (review #1,
    ///      2026-07-30 — reversing this function's own earlier argument). The
    ///      case for a full refund used to be that burning here "would charge
    ///      the challenger for the electorate's apathy — a quorum failure it
    ///      did not cause and could not have prevented." That argument does
    ///      not survive contact with `file`'s own rule, stated plainly in its
    ///      D4 comment: "an unpriced or free challenge is a free freeze, which
    ///      is precisely what the bond exists to prevent." A full refund here
    ///      made this the ONE terminal path where that rule did not hold —
    ///      the silence settle burns `settleBurnBps`, a failed challenge
    ///      forfeits the whole bond, an escalated guilty verdict correctly
    ///      charges nothing because the filing was RIGHT — while an
    ///      `Inconclusive` unwind filed the coverage frozen for the whole
    ///      `autoSlashDelay` plus adjudication window, at the price of gas.
    ///
    ///      AND THIS CONTRACT CANNOT TELL THE TWO CASES APART. An honest
    ///      challenger whose evidence was real and an attacker who filed
    ///      purely to freeze a cohort's coverage — content to let turnout do
    ///      the rest — produce the identical on-chain shape here: a completed
    ///      counter-bond pool, a vote that missed quorum. There is no signal
    ///      to separate them, which is exactly the situation every other burn
    ///      in this contract already prices rather than tries to adjudicate.
    ///
    ///      THE RATE IS DELIBERATELY BELOW `settleBurnBps` AT EVERY TIER, and
    ///      the round-4+ tier's setter (`setInconclusiveBurnBps`) cross-checks
    ///      `settleBurnBps`'s LIVE value to keep it that way (review round 2,
    ///      2026-07-30) — the shared `MAX_INCONCLUSIVE_BURN_BPS` ceiling alone
    ///      was not enough, since equal ceilings bound the two rates' maximums
    ///      identically without saying anything about where either LIVE rate
    ///      sits. A non-verdict recovered nothing, so it must cost strictly
    ///      less than a verdict that recovered real value, never more. See
    ///      `setInconclusiveBurnBps`/`setSettleBurnBps` for that setter-level
    ///      enforcement, and `_inconclusiveBurnBpsForRound` for the SEPARATE
    ///      runtime clamp that covers the round-2/3 fixed steps the setter
    ///      pair does not reach.
    ///
    ///      PRICING EACH ROUND IS WHAT RE-BOUNDS THE REPETITION M3 OTHERWISE
    ///      MAKES FREE. `_refundAll` re-arms `challengeableUntil` on every
    ///      unwind so a stall cannot buy a PERMANENT acquittal — but that same
    ///      re-arming means the identical free cycle was repeatable
    ///      indefinitely against one proposal for as long as turnout kept
    ///      missing the floor. Capping how many times the window could be
    ///      re-armed was rejected in favour of this burn: a cap would partly
    ///      reopen M3, whose whole point is that stalling must buy a delay,
    ///      never an acquittal. Burning instead prices every round without
    ///      touching the window extension at all — the stall still works, it
    ///      is simply no longer free.
    ///
    ///      THE BURN NOW ESCALATES WITH THE ROUND COUNT RATHER THAN STAYING
    ///      FLAT (owner decision, review round 3, 2026-07-30). A flat rate
    ///      turned out to leave `Inconclusive` the CHEAPEST repeatable freeze
    ///      in the contract — a flat percentage cannot distinguish an honest
    ///      one-shot filer from a grinder, because it is invariant to
    ///      repetition, and the attack this whole burn family exists to price
    ///      IS repetition. `inconclusiveRounds` (incremented below) is what
    ///      lets the rate see the thing a flat number cannot: round 1 is FREE,
    ///      so a genuinely honest filer whose vote merely missed quorum once
    ///      pays nothing, while a sustained grind climbs to 5%, then 10%, then
    ///      the steady state in `inconclusiveBurnBps` — annualizing past the
    ///      cost of the self-deal → timeout alternative rather than staying
    ///      under it. See `_inconclusiveBurnBpsForRound` for the schedule.
    ///
    ///      THE POOL IS UNTOUCHED. The burn comes off the CHALLENGER's bond
    ///      only, mirroring `_settle`'s silence branch exactly. The pool is
    ///      the accused's own money, posted to buy a defence that was never
    ///      decided on the merits, and it goes through `_bookRefund`, not a
    ///      direct transfer, for the same reason `_settle`'s part-funded
    ///      branch does: `dispute` keeps open standing precisely because the
    ///      payout is pull, not push (see `claimContribution`), and this path
    ///      reaches the same unbounded contributor list `_settle`'s partial
    ///      pool does. Pushing here would reintroduce the single-reverting-
    ///      recipient hazard pull-payments exist to remove.
    ///
    ///      NO `_convicted` MARK AND NO DEMOTION. Nothing was adjudicated, so
    ///      there is no conviction to record and no adapter to demote — and
    ///      because `_convicted` stays false and this challenge's own slot
    ///      frees on the freeze release below, the SAME proposal is fully
    ///      re-challengeable the instant this call returns (`file`'s
    ///      `AlreadyConvicted`/`AlreadyChallenged` guards both read state this
    ///      path never sets).
    function _refundAll(uint256 challengeId, Challenge storage c) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        uint256 bond = c.bondWood;
        uint256 pool = c.counterBondWood;
        address challenger = c.challenger;

        c.status = Status.Inconclusive;
        bondedWood -= (bond + pool);
        bytes32 rk = _reviewKey(governor, proposalId);
        _releaseFreeze(rk, governor, proposalId);

        // M3 (spec §5): raise the re-challenge floor so a stall cannot buy a
        // permanent acquittal for any challenge filed more than roughly
        // `challengeWindow - autoSlashDelay - voteWindow` after execution —
        // the accused stalls the pool to the last legal instant inside
        // `autoSlashDelay`, the vote runs, and the verdict would otherwise
        // land past `executedAt + challengeWindow` with no filing gate left
        // standing. `file`'s gate takes the max of this value and the live
        // `executedAt + challengeWindow` baseline on every call, so nothing
        // here needs to guard against its OWN write shrinking a later read —
        // only against raising it needlessly.
        //
        // SKIPPED WHEN THE PROPOSAL IS ALREADY CONVICTED. A concurrent
        // challenge against the SAME proposal may have already settled to a
        // conviction while this one was disputed (`_convicted[rk]` true) —
        // `file` refuses ANY further filing against a convicted proposal
        // regardless of what this mapping holds (`AlreadyConvicted`), so an
        // unguarded write here would be inert to control flow either way.
        // It is still worth skipping: left unguarded, the public getter
        // would advertise a live re-challenge deadline for a proposal that
        // can never actually be challenged again — a stale signal an
        // indexer built against this mapping would otherwise trust.
        if (!_convicted[rk]) {
            uint256 extended = block.timestamp + challengeWindow;
            if (extended > challengeableUntil[rk]) challengeableUntil[rk] = extended;
            // ONE MORE ROUND OF THE GRIND, RECORDED (owner decision
            // 2026-07-30). Same guard as the re-arm above and for the same
            // reason: a round against an already-convicted proposal cannot
            // recur (`file` refuses it outright via `AlreadyConvicted`), so
            // counting it would only inflate a schedule nothing can ever read
            // again. Unconditional inside this guard, unlike the re-arm
            // write above — every actual `Inconclusive` unwind of a
            // contestable proposal IS a repetition, whether or not this
            // particular one happened to raise the stored deadline further.
            inconclusiveRounds[rk]++;
        }

        _bookRefund(challengeId, pool);

        // Off the challenger's bond only — mirroring `_settle`'s silence
        // branch to the letter, including the skipped zero-value transfer
        // when the pinned rate is zero. `bond - burned` cannot underflow:
        // integer division makes `burned <= bond` for any
        // `inconclusiveBurnBpsAtFiling <= BPS_DENOMINATOR`, and both
        // `_inconclusiveBurnBpsForRound`'s clamp and the round-4+ setter pair
        // keep the PINNED rate well below that ceiling.
        uint256 burned = (bond * c.inconclusiveBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burned != 0) {
            wood.safeTransfer(BURN_ADDRESS, burned);
            emit ChallengerBondBurned(challengeId, burned);
        }
        wood.safeTransfer(challenger, bond - burned);
        // GROSS, PRE-BURN (review round 3, 2026-07-30 — flagged, not
        // changed): `bond` here is the whole pinned bond, not `bond - burned`.
        // `ChallengerBondBurned` above reports the burned slice separately on
        // the same transaction, so the two logs together are exact — but a
        // consumer that reads only this event's `bondWood` and treats it as
        // "what the challenger received" over-reports by `burned`. Kept gross
        // rather than net for the same reason `ChallengeFailed` reports
        // `forfeitedWood` gross and `burnedWood` separately: the two answer
        // different questions (what the bond WAS vs. what was destroyed of
        // it), and folding them into one net number would answer neither.
        emit ChallengeInconclusive(challengeId, bond, pool);
    }

    /// @dev THE ESCALATING SCHEDULE ITSELF (owner decision 2026-07-30, review
    ///      round 3). `priorRounds` is how many times this PROPOSAL has
    ///      already gone `Inconclusive` (`inconclusiveRounds[key]`, already
    ///      reset by `file` if the last streak lapsed) — the round THIS
    ///      filing is attempting is therefore `priorRounds + 1`:
    ///
    ///        priorRounds == 0  ->  attempt 1  ->  0 bps (free)
    ///        priorRounds == 1  ->  attempt 2  ->  `INCONCLUSIVE_BURN_ROUND2_BPS`
    ///        priorRounds == 2  ->  attempt 3  ->  `INCONCLUSIVE_BURN_ROUND3_BPS`
    ///        priorRounds >= 3  ->  attempt 4+ ->  `inconclusiveBurnBps`
    ///
    ///      ALWAYS CLAMPED TO THE LIVE `settleBurnBps`, regardless of tier —
    ///      not merely for the round-4+ tier, even though that tier is ALSO
    ///      guarded at the setter level (`setInconclusiveBurnBps`/
    ///      `setSettleBurnBps` cross-check each other's live value). The two
    ///      fixed literals for rounds 2 and 3 are NOT covered by that setter
    ///      pair — they are compile-time constants, not owner state — so if
    ///      the owner lowers `settleBurnBps` below 500 or 1,000, nothing at
    ///      setter time stops that (there is nothing there to check against),
    ///      and this clamp is what still keeps a non-verdict from costing more
    ///      than a verdict that recovered real value. CLAMPED, NOT REVERTED:
    ///      a revert here would make `file` itself fail whenever governance
    ///      set `settleBurnBps` low, which would block filing entirely over a
    ///      parameter interaction — clamping silently keeps every rate legal
    ///      and filing always reachable.
    function _inconclusiveBurnBpsForRound(uint256 priorRounds) private view returns (uint256 bps) {
        if (priorRounds == 0) {
            bps = 0;
        } else if (priorRounds == 1) {
            bps = INCONCLUSIVE_BURN_ROUND2_BPS;
        } else if (priorRounds == 2) {
            bps = INCONCLUSIVE_BURN_ROUND3_BPS;
        } else {
            bps = inconclusiveBurnBps;
        }
        uint256 ceiling = settleBurnBps;
        if (bps > ceiling) bps = ceiling;
    }

    /// @dev The accused set: the ledger's covering approvers, filtered to those
    ///      whose committed share is still non-zero. The ledger reports a
    ///      released commitment as zero rather than dropping it, and a guardian
    ///      that released before the filing backed nothing on this proposal —
    ///      it is neither slashed nor paid out of a failed challenge.
    /// @dev The accused and the rate each is slashed at, in one ledger read.
    ///
    ///      Filters rather than passing the ledger's raw output straight
    ///      through: `slashBpsFor` returns the full HISTORICAL approver set
    ///      (matching `approversOf`), pricing a released commitment at 0 bps.
    ///      `slashToEscrow` would skip those zeros, so the amounts would be
    ///      identical either way — but the approver array is what names people
    ///      in the `GuardianSlashed` topics and the escrow case. A guardian who
    ///      withdrew their approval before the drain owes nothing and should not
    ///      appear in a conviction at all.
    ///
    ///      Both returned arrays come from the same call and are positionally
    ///      aligned by construction, so no cross-call ordering assumption is
    ///      made.
    ///
    ///      THIS IS NOW THE ONLY ACCUSED-SET READER. The addresses-only
    ///      `_accused` it replaced had already shed its coverage weights when
    ///      the failure split moved from coverage to contribution (see `_fail`);
    ///      its last consumer was the slash list here, which needs the rates
    ///      too, so the narrower helper is gone rather than left dead.
    function _accusedWithRates(address governor, uint256 proposalId)
        private
        view
        returns (address[] memory accused, uint256[] memory bps)
    {
        (address[] memory all, uint256[] memory allBps) = exposureLedger.slashBpsFor(governor, proposalId);
        uint256 n;
        for (uint256 i = 0; i < allBps.length; i++) {
            if (allBps[i] != 0) n++;
        }
        accused = new address[](n);
        bps = new uint256[](n);
        uint256 j;
        for (uint256 i = 0; i < allBps.length; i++) {
            if (allBps[i] == 0) continue;
            accused[j] = all[i];
            bps[j] = allBps[i];
            j++;
        }
    }

    // ── Views ──

    /// @inheritdoc IChallengeGame
    function challengeOf(uint256 challengeId) external view returns (Challenge memory) {
        return _challenges[challengeId];
    }

    /// @inheritdoc IChallengeGame
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory) {
        return _contributors[challengeId];
    }

    /// @inheritdoc IChallengeGame
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256) {
        return _contributed[challengeId][contributor];
    }

    /// @inheritdoc IChallengeGame
    function claimableContribution(uint256 challengeId, address contributor) public view returns (uint256) {
        Challenge storage c = _challenges[challengeId];
        uint256 contributed = _contributed[challengeId][contributor];
        if (contributed == 0) return 0;

        if (c.status == Status.Failed) {
            // Stake back plus this funder's slice of the forfeit. `pool` is the
            // denominator the shares were promised against, and it is frozen
            // once the challenge is terminal.
            return contributed + (c.forfeitPayoutWood * contributed) / c.counterBondWood;
        }
        if (c.status == Status.Settled) {
            // A COMPLETE pool at settle means the challenge was escalated and
            // the court ruled guilty, so the whole pool forfeited to the
            // challenger and the funders are owed nothing. `Filed` can only
            // reach `_settle` with `pool < bondWood`, so this comparison
            // distinguishes the two entries without a stored flag.
            if (c.counterBondWood == c.bondWood) return 0;
            return contributed; // part-funded defence: stake back, no winnings
        }
        if (c.status == Status.Inconclusive) {
            return contributed; // unwind: stake back, nothing was won or lost
        }
        return 0; // still live — nothing is owed until the outcome is fixed
    }

    /// @inheritdoc IChallengeGame
    function claimContribution(uint256 challengeId) external returns (uint256 amount) {
        Challenge storage c = _challenges[challengeId];
        Status status = c.status;
        if (status != Status.Failed && status != Status.Settled && status != Status.Inconclusive) {
            revert ChallengeNotTerminal();
        }

        amount = claimableContribution(challengeId, msg.sender);
        if (amount == 0) revert NothingToClaim();

        // CEI, and the zeroing is what makes the claim single-shot: the
        // entitlement is derived from `_contributed`, so clearing it before the
        // transfer closes both the re-entrancy door and the double-claim one.
        _contributed[challengeId][msg.sender] = 0;
        unclaimedWood -= amount;

        wood.safeTransfer(msg.sender, amount);
        emit ContributionClaimed(challengeId, msg.sender, amount);
    }

    /// @inheritdoc IChallengeGame
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256) {
        return _liveChallengeId(_lastChallenge[_reviewKey(governor, proposalId)]);
    }

    /// @inheritdoc IChallengeGame
    function liveChallengeCountOf(address governor, uint256 proposalId) external view returns (uint256) {
        return _liveCount[_reviewKey(governor, proposalId)];
    }

    /// @inheritdoc IChallengeGame
    function liveChallengeOfBy(address governor, uint256 proposalId, address challenger)
        external
        view
        returns (uint256)
    {
        return _liveChallengeId(_liveByChallenger[_challengerKey(_reviewKey(governor, proposalId), challenger)]);
    }

    /// @dev Re-checks status rather than trusting a stored pointer, so a
    ///      terminal challenge never blocks a later, legitimate one.
    function _liveChallengeId(uint256 id) internal view returns (uint256) {
        if (id == 0) return 0;
        Status status = _challenges[id].status;
        return (status == Status.Filed || status == Status.Disputed) ? id : 0;
    }

    // ── Owner setters ──

    /// @dev NO ZERO CHECK, unlike every other setter here — the zero address is
    ///      the meaningful "no court" state, not a mis-set one. It is both the
    ///      pre-Plan-E default and the revocation switch: unwiring a captured
    ///      court returns the game to D5's fail-safe timeout, which acquits, so
    ///      the worst an unwiring can do is fail to slash.
    /// @dev GUARDS THE RE-WIRE TOO (review 2026-07-29 audit, item 1 BLOCKER —
    ///      PROVEN executable). Re-pointing to a NEW non-zero court is itself
    ///      a setter that can break the B3 window invariant, and leaving it
    ///      unguarded composed with the vacuous branch in
    ///      `_requireWindowFits` into a full bypass of the three setters that
    ///      WERE guarded: `setCourt(0)` (legal, vacuous) →
    ///      `setAutoSlashDelay`/`setDisputeTimeout` to a value that only
    ///      passes BECAUSE no court is wired → `setCourt(realCourt)`
    ///      (previously unguarded) lands exactly the violation those two
    ///      setters exist to refuse, using the escape hatch each of them
    ///      individually left open. Checked against the NEW court's OWN
    ///      `voteWindow`/`FINALIZE_BUFFER` — passing `newCourt` explicitly
    ///      rather than reading `court` from storage is what makes this
    ///      validate the address about to become live, not the stale one
    ///      still there at call time.
    function setCourt(address newCourt) external onlyOwner {
        if (newCourt != address(0)) _requireWindowFits(newCourt, autoSlashDelay, disputeTimeout);
        emit CourtSet(court, newCourt);
        court = newCourt;
    }

    /// @dev RE-POINTING WHILE CHALLENGES ARE LIVE ORPHANS THEIR FREEZE (review
    ///      minor). Every live challenge's `unfreezeCoverage` goes to the NEW
    ///      ledger, so the coverage the old one pinned stays frozen forever and
    ///      the new one is unfrozen for challenges it never saw. Same class as
    ///      the ledger's own documented `setGuardianRegistry` orphaning, and the
    ///      same remedy: re-point only when no challenge is live, or point back
    ///      and drain the live set first.
    /// @dev RE-VALIDATES `challengeWindow` AGAINST THE NEW LEDGER'S OWN WINDOW
    ///      (same class as `setStakedWood`'s re-point guard, review 2026-07-29
    ///      lock-time reduction, Part C). `setChallengeWindow` only bounds a NEW
    ///      window against whichever ledger is wired at that moment; it says
    ///      nothing about the ledger itself changing later underneath an
    ///      unchanged window. WITHOUT THIS CHECK: re-pointing from a ledger with
    ///      a 30-day `challengeWindow` to one with 7 days, while this game's own
    ///      `challengeWindow` is still 14, would silently reopen the exact gap
    ///      Part C closes — a filing could freeze exposure the NEW ledger has
    ///      already aged out of its epoch buckets, with no setter call on this
    ///      game to catch it. Reverting here, at re-point time, is cheap;
    ///      catching it only the next time someone happens to call
    ///      `setChallengeWindow` is not — that setter might never be called
    ///      again while the mismatch sits live.
    /// @dev RESIDUAL: THE LEDGER-SIDE DOOR THIS GAME CANNOT CLOSE (review
    ///      2026-07-29 audit, item 4 — PROVEN executable). `ExposureLedger.
    ///      setChallengeWindow` can LOWER the ledger's own window at any time
    ///      with no reference to any game at all — the ledger holds no
    ///      pointer back to whichever `ChallengeGame` reads it, so it has
    ///      nothing to check against and cannot be made to. This guard, plus
    ///      `setChallengeWindow`'s own live read above, close 2 of the 3 doors
    ///      onto the same mismatch — this game's `setChallengeWindow` raising
    ///      above the ledger, and this game's `setExposureLedger` re-pointing
    ///      to a smaller-windowed ledger. The third — the LEDGER's owner
    ///      shrinking its `challengeWindow` out from under an already-larger,
    ///      already-legal game window — is unreachable from this contract by
    ///      construction. Left as a documented gap rather than a false sense
    ///      of completeness: closing it would require the LEDGER to track
    ///      every game that reads it, which is the dependency direction this
    ///      design has never taken (the game depends on the ledger, never the
    ///      reverse).
    /// @dev REQUIRES THE OTHER HALF OF THE GRANT TO ALREADY EXIST (review PR #56
    ///      M2, mirroring `TokenCourt.setChallengeGame`'s own re-wire guard).
    ///      `coverageFreezer` is the ledger's side of a TWO-SIDED relationship
    ///      and this setter only ever moved one side of it. A fresh ledger's
    ///      `coverageFreezer` is the zero address, so re-pointing at one while a
    ///      challenge is live sent every terminal path — `_settle`, `_fail`,
    ///      `_refundAll`, all through `_releaseFreeze` — into
    ///      `unfreezeCoverage`'s `NotCoverageFreezer`. That is a WEDGE, not an
    ///      inconvenience: the bond and the counter-bond pool are stranded with
    ///      no terminal exit, and the OLD ledger's `_frozen[key]` stays true
    ///      forever, barring every accused approver from `claimUnstakeGuardian`
    ///      — while that ledger's own `setCoverageFreezer` is bricked by its
    ///      `CoverageFrozen` guard, so the role cannot even be rotated to clean
    ///      up. It also falsified this contract's own claim that a hostile owner
    ///      "can never freeze [coverage] that already exists".
    ///
    ///      Demanding the grant FIRST does not remove the orphaning hazard
    ///      documented above — a correctly-granted new ledger still knows
    ///      nothing about freezes the old one holds — but it does mean every
    ///      reachable re-point leaves the terminal paths callable, which is the
    ///      part that cannot be repaired after the fact.
    function setExposureLedger(address ledger) external onlyOwner {
        if (ledger == address(0)) revert ZeroAddress();
        if (challengeWindow > IExposureLedger(ledger).challengeWindow()) revert InvalidParameter();
        if (IExposureLedger(ledger).coverageFreezer() != address(this)) revert RoleNotGranted();
        emit ExposureLedgerSet(address(exposureLedger), ledger);
        exposureLedger = IExposureLedger(ledger);
    }

    function setTierRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        emit TierRegistrySet(address(tierRegistry), registry);
        tierRegistry = ITierRegistryDemoterMinimal(registry);
    }

    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0) revert InvalidParameter();
        // THE LEDGER'S WINDOW IS AUTHORITATIVE, read live rather than restated.
        // It governs the epoch-bucket scan a coverage freeze depends on, so a
        // game window above it lets a filing freeze exposure the ledger has
        // already aged out - which this bound closes ON THE BASE PATH (the old
        // `90 days` literal sat 6x above the ledger's own 14-day default).
        // Reading it live also means the two cannot drift.
        //
        // NOT THE WHOLE REACHABLE WINDOW, and that is a scope choice, not an
        // oversight (review 2026-07-29 audit, item 3 - PROVEN executable):
        // `file`'s actual deadline is `max(executedAt + challengeWindow,
        // challengeableUntil[key])`, and M3's `_refundAll` can raise
        // `challengeableUntil` to `block.timestamp + challengeWindow` from an
        // `Inconclusive` unwind that itself can land up to `autoSlashDelay +
        // voteWindow` after a filing made up to `challengeWindow` after
        // execution. Composed, the effective reach is
        // `executedAt + 2 * challengeWindow + autoSlashDelay + voteWindow` -
        // roughly 40 days at defaults against this ledger's 14-day window.
        // LEFT OUT OF SCOPE HERE, deliberately: `challengeableUntil` governs
        // whether a FRESH filing is still admitted, not how long any SINGLE
        // challenge's freeze survives - a late re-challenge re-derives its own
        // coverage and price live at `file` time regardless of how far past
        // the ledger's window the deadline sits, so reaching it is not
        // "freezing exposure the ledger has aged out" in the sense this bound
        // exists to prevent. Capping `_refundAll`'s own write against the
        // ledger's window instead would collide with M3's separate,
        // already-proven "never shortens" guarantee (see that path's own
        // natspec) for no gap closed in return - a change to make
        // deliberately, inside M3's own review, not as a side effect of this
        // one.
        if (newWindow > exposureLedger.challengeWindow()) revert InvalidParameter();
        emit ChallengeWindowSet(challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    /// @dev Bounded (0, 10_000]: zero would make filing free, and therefore the
    ///      freeze free (D4).
    function setChallengerBondBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ChallengerBondBpsSet(challengerBondBps, newBps);
        challengerBondBps = newBps;
    }

    /// @dev Bounded [0, `MAX_FORFEIT_BURN_BPS`]. ZERO IS ALLOWED, unlike
    ///      `setChallengerBondBps` where it would make the freeze free: zero
    ///      here restores the pre-burn behaviour — the whole forfeit paid to the
    ///      funders — which is a coherent (if exploitable) configuration and the
    ///      off-switch if the burn is ever shown to deter honest defences more
    ///      than it deters self-challenges. The ceiling is justified at the
    ///      constant: it keeps an honest defender's share the larger one and
    ///      bounds what a captured owner can destroy per failed challenge.
    function setForfeitBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FORFEIT_BURN_BPS) revert InvalidParameter();
        emit ForfeitBurnBpsSet(forfeitBurnBps, newBps);
        forfeitBurnBps = newBps;
    }

    /// @dev RE-VALIDATES `convictionBountyBps` AGAINST THE NEW SLASHER'S OWN
    ///      CEILING (PR review 2026-07-29 IMPORTANT-2). `setConvictionBountyBps`
    ///      only bounds a NEW rate against whichever `stakedWood` is wired at
    ///      that moment; it says nothing about `stakedWood` itself changing
    ///      later underneath an unchanged rate. WITHOUT THIS CHECK: re-pointing
    ///      from a sWOOD with `MAX_CONVICTION_BOUNTY_BPS == 2_000` to one with
    ///      `== 500` while `convictionBountyBps` is still `2_000` would leave
    ///      every open challenge carrying a pinned `convictionBountyBpsAtFiling`
    ///      the NEW slasher's own `slashToEscrow` rejects (`InvalidParameter`)
    ///      the moment `_settle` tries to forward it. THIS DOES NOT STRAND THE
    ///      CHALLENGE ITSELF, even in that unchecked scenario: a `Filed` one
    ///      still settles fine, because the silence path never sets
    ///      `contested` and forwards a bounty of `0` unconditionally,
    ///      regardless of what the pinned rate is; a `Disputed` one still
    ///      times out to `_fail` on a `NotGuilty` ruling or a timeout, neither
    ///      of which ever calls `slashToEscrow`. What breaks is narrower and
    ///      permanent: a CONTESTED conviction (a real `Guilty` ruling on a
    ///      challenge someone else actually disputed) against a challenge
    ///      pinned at a rate now above the new ceiling can never settle,
    ///      because every `_settle` call for it reverts inside sWOOD forever.
    ///      Checked here, at re-point time, is what prevents the owner from
    ///      creating that state in the first place, rather than leaving it to
    ///      surface only once a real conviction tries to land. RESIDUAL: this
    ///      bounds the re-point against the CURRENT `convictionBountyBps`, not
    ///      against every historical `convictionBountyBpsAtFiling` a still-open
    ///      challenge may carry from before a rate DECREASE — the ordinary case
    ///      this closes is the common one, a live rate that was never lowered
    ///      colliding with a lower new ceiling.
    /// @dev ALSO REQUIRES THE OTHER HALF OF THE GRANT (review PR #56 M2, same
    ///      shape as `setExposureLedger`'s `coverageFreezer` check and
    ///      `TokenCourt.setChallengeGame`'s). `authorizedSlasher` is sWOOD's side
    ///      of the same two-sided relationship: point this game at a sWOOD that
    ///      has not named it, and every `_settle` reverts inside
    ///      `slashToEscrow`'s own caller gate — the wedge shape this whole
    ///      review round is about, since `Filed`'s only other exit (`rule`)
    ///      demands `Disputed`. The reciprocal pointer is already the documented
    ///      deploy order (`swood.setAuthorizedSlasher(game)` THEN
    ///      `game.setStakedWood(swood)` — see `DeployPlanD`), so this enforces
    ///      the sequence the scripts already follow rather than imposing a new
    ///      one. `_settle`'s own "`setStakedWood` is the owner escape" note
    ///      stands and is strengthened: the escape now cannot itself be
    ///      mis-aimed at a sWOOD that would reject the verdict.
    function setStakedWood(address stakedWood_) external onlyOwner {
        if (stakedWood_ == address(0)) revert ZeroAddress();
        if (convictionBountyBps > IStakedWood(stakedWood_).MAX_CONVICTION_BOUNTY_BPS()) revert InvalidParameter();
        if (IStakedWood(stakedWood_).authorizedSlasher() != address(this)) revert RoleNotGranted();
        emit StakedWoodSet(address(stakedWood), stakedWood_);
        stakedWood = IStakedWood(stakedWood_);
    }

    /// @dev DISABLED (review PR #56). `Ownable`'s default would leave this
    ///      contract permanently ownerless, and several documented recovery
    ///      levers are owner-only and irreplaceable: `setStakedWood` is the
    ///      stated un-wedge for a challenge stuck on an unwired or mis-granted
    ///      slasher, `setCourt(address(0))` is the stated off-switch for a
    ///      captured court, and `setExposureLedger` is the only way to move the
    ///      freeze rail. Renouncing does not merely reduce privilege here — it
    ///      forecloses the escapes the rest of this contract's reasoning assumes
    ///      exist. Ownership can still be HANDED OVER: `Ownable2Step`'s
    ///      transfer/accept pair is untouched.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev THE INVARIANT SPANS TWO CONTRACTS, so neither holds it alone (B3).
    ///      A counter-bond pool may complete as late as
    ///      `filedAt + autoSlashDelay`, and from that instant a referral needs
    ///      `voteWindow + FINALIZE_BUFFER` of runway before the challenge dies
    ///      at `filedAt + disputeTimeout`. Violated, the referral window can be
    ///      NEGATIVE - and the ACCUSED chooses when the pool completes, so it
    ///      defeats adjudication unilaterally by stalling. The deploy
    ///      pre-flight catches the wiring-time case; this catches the setters
    ///      that could each break it afterwards — INCLUDING RE-WIRING ITSELF
    ///      (review 2026-07-29 audit, item 1): `setCourt` calls this against
    ///      the address it is ABOUT to become, not the stale one already in
    ///      storage, which is why `c` is a PARAMETER here rather than always
    ///      read from `court` — closing the composed bypass where an unwired
    ///      game accepts a violating clock through the vacuous branch below
    ///      and then re-wires unguarded. Vacuous with no court wired: there is
    ///      no referral to fit.
    /// @dev RESIDUAL (same class as `setStakedWood`'s and
    ///      `setConvictionBountyBps`'s own RESIDUAL notes, review 2026-07-29
    ///      audit, item 2 — PROVEN executable): this binds the court's
    ///      CURRENT `voteWindow`/`FINALIZE_BUFFER` against this game's
    ///      CURRENT `autoSlashDelay`/`disputeTimeout` — not against any
    ///      already-open challenge's PINNED `autoSlashDelayAtFiling`/
    ///      `disputeTimeoutAtFiling`. Concretely: file while `disputeTimeout
    ///      == 13 days` (13 pinned, fitting the court's then-current 5-day
    ///      `voteWindow`); the owner later raises the LIVE `disputeTimeout` to
    ///      30 days (passes — still fits the court's 5-day window); the owner
    ///      then raises the court's LIVE `voteWindow` to 14 days (passes —
    ///      `7 + 14 + 1 == 22 <= 30` against the NEW live timeout). Both
    ///      raises are individually guarded and individually legal against
    ///      whatever is CURRENT at each call — but the OLD challenge's pin
    ///      never moved: `refer` reads the new 14-day `voteWindow` against the
    ///      old 13-day pin and can revert `InsufficientClock` from the instant
    ///      of filing onward, resolving that one challenge via `_fail`
    ///      (timeout acquittal) regardless of guilt. OWNER-ONLY, not
    ///      adversary-reachable — neither a challenger nor the accused can
    ///      trigger either raise — and RECOVERABLE: lowering `voteWindow` back
    ///      below the pinned challenge's remaining runway restores its
    ///      referability, precisely because `refer`'s clock check reads
    ///      `voteWindow` live rather than pinning it. Closing this fully would
    ///      mean re-validating every open challenge's own pin on every setter
    ///      call — unbounded work this design has already rejected elsewhere
    ///      (the pool/contributor loops removed for the same reason) — so
    ///      binding SETTERS against CURRENT state is the achievable half of
    ///      this invariant; binding every PAST commitment is not.
    function _requireWindowFits(address c, uint256 autoSlash, uint256 timeout) private view {
        if (c == address(0)) return;
        if (autoSlash + ITokenCourt(c).voteWindow() + ITokenCourt(c).FINALIZE_BUFFER() > timeout) {
            revert WindowInvariantViolated();
        }
    }

    /// @dev Bounded [`MIN_AUTO_SLASH_DELAY`, `disputeTimeout`). The floor is
    ///      justified at the constant; the ceiling is the cross-parameter
    ///      invariant — both clocks run from `filedAt`, so a delay at or above
    ///      the dispute timeout would let a contested challenge time out before
    ///      the slash it was raised against ever came due, and the accused
    ///      would have bought its escalation for nothing.
    /// @dev LAST CHECK IS THE CROSS-CONTRACT ONE (B3, `_requireWindowFits`):
    ///      the two bounds above are this contract's own; the window invariant
    ///      additionally needs the court's `voteWindow`/`FINALIZE_BUFFER`, which
    ///      only exists on `TokenCourt`.
    function setAutoSlashDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_AUTO_SLASH_DELAY || newDelay >= disputeTimeout) revert InvalidParameter();
        _requireWindowFits(court, newDelay, disputeTimeout);
        emit AutoSlashDelaySet(autoSlashDelay, newDelay);
        autoSlashDelay = newDelay;
    }

    /// @dev Bounded (`autoSlashDelay`, `MAX_DISPUTE_TIMEOUT`] — the same
    ///      cross-parameter invariant from the other side, plus a ceiling on how
    ///      long a filing may pin a guardian's coverage.
    /// @dev LAST CHECK IS THE CROSS-CONTRACT ONE (B3, `_requireWindowFits`) —
    ///      see `setAutoSlashDelay`'s identical note.
    function setDisputeTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout <= autoSlashDelay || newTimeout > MAX_DISPUTE_TIMEOUT) revert InvalidParameter();
        _requireWindowFits(court, autoSlashDelay, newTimeout);
        emit DisputeTimeoutSet(disputeTimeout, newTimeout);
        disputeTimeout = newTimeout;
    }

    /// @dev Bounded [0, `MAX_SETTLE_BURN_BPS`]. Zero is legal and means the
    ///      settle path refunds in full — the pre-🟠F4 behaviour — so governance
    ///      can retire the burn without an upgrade if the off-chain bounty ends
    ///      up pricing filings adequately on its own.
    /// @dev Applies to challenges FILED after the change, not to challenges
    ///      settled after it (review 🔵F15). An earlier version of this note
    ///      argued the opposite — that the rate need not be pinned because it
    ///      "prices the refund rather than bounding a window the accused is
    ///      relying on." That distinction does not survive contact with the
    ///      filer: the challenger reads this rate when it decides whether the
    ///      bond is worth posting, and once posted it cannot withdraw. Leaving
    ///      it live let a raise take up to half the refund of a filing that had
    ///      already turned out to be correct, which is the same retroactivity
    ///      `autoSlashDelayAtFiling` exists to prevent.
    /// @dev ALSO REFUSES TO DROP BELOW THE LIVE `inconclusiveBurnBps` (review
    ///      round 2, 2026-07-30). `MAX_INCONCLUSIVE_BURN_BPS ==
    ///      MAX_SETTLE_BURN_BPS` bounds the two rates' CEILINGS identically but
    ///      says nothing about where either LIVE rate sits — checking only
    ///      this setter's own ceiling let the owner drop `settleBurnBps` below
    ///      an unchanged `inconclusiveBurnBps`, inverting the ordering the
    ///      Inconclusive burn exists to guarantee (a non-verdict must never
    ///      cost more than a verdict that recovered real value). This is the
    ///      OTHER of the two doors onto that constraint; see
    ///      `setInconclusiveBurnBps` for the door on the far side, and the
    ///      class of bug this repeats — sWOOD's bounty ceiling, the ledger's
    ///      challenge window, the window invariant's five doors — each
    ///      guarded once and bitten from the side left open.
    function setSettleBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SETTLE_BURN_BPS) revert InvalidParameter();
        if (newBps < inconclusiveBurnBps) revert InvalidParameter();
        emit SettleBurnBpsSet(settleBurnBps, newBps);
        settleBurnBps = newBps;
    }

    /// @dev Bounded by the SLASHER's own ceiling, read live rather than
    ///      restated here: sWOOD enforces `MAX_CONVICTION_BOUNTY_BPS` on every
    ///      call regardless of what this game asks for, so duplicating the
    ///      literal would create two constants that must agree with nothing
    ///      checking that they do. Zero is legal and turns the bounty off.
    /// @dev  REQUIRES `stakedWood` WIRED FIRST (unlike every other rate setter
    ///       here), because there is nothing to bound against otherwise. An
    ///       unwired game could accept a rate `_settle` fail-closes on today
    ///       (`ZeroAddress`), but that rate is PINNED per challenge at filing
    ///       and outlives any later `setStakedWood` — a challenge filed under a
    ///       since-lowered ceiling would carry a pinned rate sWOOD's own
    ///       `slashToEscrow` then rejects forever, permanently foreclosing a
    ///       CONTESTED conviction on that one challenge (NOT "stranding the
    ///       challenge with no terminal path" — see `setStakedWood`'s own
    ///       natspec for the precise, narrower failure this produces: the
    ///       silence and dispute-timeout paths are untouched, only an
    ///       escalated `Guilty` ruling against the affected challenge can never
    ///       settle). Failing closed here, at configuration time, is cheap;
    ///       failing closed at resolution time, mid-challenge, is not. See
    ///       `setStakedWood` for the OTHER direction of this same hazard — a
    ///       re-pointed slasher whose ceiling drops below an unchanged rate.
    function setConvictionBountyBps(uint256 newBps) external onlyOwner {
        IStakedWood swood = stakedWood;
        if (address(swood) == address(0)) revert ZeroAddress();
        if (newBps > swood.MAX_CONVICTION_BOUNTY_BPS()) revert InvalidParameter();
        emit ConvictionBountyBpsSet(convictionBountyBps, newBps);
        convictionBountyBps = newBps;
    }

    /// @dev Bounded [0, `MAX_INCONCLUSIVE_BURN_BPS`] (review #1, 2026-07-30).
    ///      ZERO IS ALLOWED, exactly like `setSettleBurnBps` and
    ///      `setForfeitBurnBps`: it restores the pre-fix behaviour (the whole
    ///      bond back, untouched) and is the off-switch if this burn is ever
    ///      shown to deter honest filers more than it deters the free-freeze
    ///      it exists to price. The ceiling is `MAX_INCONCLUSIVE_BURN_BPS`,
    ///      itself pinned to `MAX_SETTLE_BURN_BPS` — see that constant for why
    ///      a non-verdict must never be allowed to cost more than a verdict
    ///      that recovered real value.
    /// @dev ALSO REFUSES TO RISE ABOVE THE LIVE `settleBurnBps` (review round
    ///      2, 2026-07-30 — the ceiling check above is necessary but not
    ///      sufficient). Sharing a ceiling with `settleBurnBps` bounds both
    ///      rates' MAXIMUM legal values identically; it does not stop this
    ///      rate from being set ABOVE an unchanged, lower `settleBurnBps` — the
    ///      owner could legally raise this to 4,000 while `settleBurnBps` sat
    ///      at its 500 default, both calls individually within their own
    ///      ceilings, together inverting the ordering this burn exists to
    ///      guarantee. This is one of the two doors onto that constraint; see
    ///      `setSettleBurnBps` for the door on the far side.
    /// @dev Applies to challenges FILED after the change, not to ones ruled
    ///      after it — same reasoning as `setSettleBurnBps`'s own note:
    ///      `inconclusiveBurnBpsAtFiling` is what the challenger relied on
    ///      when it posted the bond, and it has no way to withdraw once a
    ///      later court vote misses its participation floor.
    function setInconclusiveBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_INCONCLUSIVE_BURN_BPS) revert InvalidParameter();
        if (newBps > settleBurnBps) revert InvalidParameter();
        emit InconclusiveBurnBpsSet(inconclusiveBurnBps, newBps);
        inconclusiveBurnBps = newBps;
    }

    /// @dev Gates `file` ONLY (see `filingsPaused`). Deliberately touches
    ///      nothing else — no other setter here, and no path in `dispute`,
    ///      `resolve`, `rule`, or either claim function, ever reads this flag.
    function setFilingsPaused(bool paused) external onlyOwner {
        emit FilingsPausedSet(filingsPaused, paused);
        filingsPaused = paused;
    }
}
