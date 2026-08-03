// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITokenCourt} from "./interfaces/ITokenCourt.sol";

/// @dev Narrow tier-registry surface: the game may revoke a certification on a
///      passed challenge and nothing else. A role rather than registry
///      ownership, so it can never grant one.
interface ITierRegistryDemoterMinimal {
    function demoteByChallenge(address target, bytes4 selector) external;
}

/**
 * @title ChallengeGame
 * @notice Anyone may post a bonded challenge against an executed proposal,
 *         citing one of five predicates and an evidence pointer. Filing
 *         freezes the coverage that proposal's approvers committed, so the
 *         accused cannot recycle that budget while under challenge.
 *
 * @dev    There is no on-chain predicate verification: an undisputed
 *         challenge auto-slashes after a delay, a disputed one escalates to
 *         the court. The `Predicate` enum is a label carried in the event,
 *         nothing more — verifying it on-chain would need a second security
 *         model per predicate.
 *
 * @dev    Vigilance cost sits with guardians: an approver that stays silent
 *         through the dispute window is slashed on an unproven assertion.
 *         What bounds that is the challenger's bond — sized to the coverage
 *         it freezes and forfeited to the accused when a challenge fails —
 *         plus a dispute window generous relative to the auto-slash delay.
 *
 * @dev    A winning challenger's counter-bond pool forfeits to it on a guilty
 *         verdict, on top of its returned bond — the escalation costs the
 *         accused what it is worth, and the forensic work that caught it is
 *         paid by the side that was wrong.
 *
 * @dev    The accused's defence is bought collectively: any accused approver
 *         may contribute to a shared counter-bond pool, sized to the
 *         challenger's bond regardless of how many identities the accused
 *         side splits across (pinning the TOTAL and letting only the PAYER
 *         vary makes a Sybil split cost exactly what staying whole costs). A
 *         failed challenge's forfeit splits pro-rata to CONTRIBUTION, not
 *         coverage, so an approver that sat out the defence collects none of
 *         the upside it produced.
 *
 * @dev    `forfeitBurnBps` burns a slice of every forfeit before the split:
 *         an attacker who is both challenger and sole pool funder (e.g. two
 *         addresses it controls) would otherwise recover its own forfeit in
 *         full, since it controls every possible recipient. Only destruction
 *         has no beneficiary to round-trip to.
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

    /// @notice Hard floor on `autoSlashDelay` — the guardians' entire window to
    ///         notice a filing and fully fund a counter-bond between them.
    /// @dev    Guards against a compromised or hostile owner collapsing the
    ///         window to zero and turning silence into an instant slash. 48h
    ///         is sized for human response times across time zones and
    ///         survives a weekend, an operator outage, an RPC failure or a
    ///         short chain halt without converting an accusation into an
    ///         automatic slash.
    uint256 public constant MIN_AUTO_SLASH_DELAY = 2 days;

    /// @dev Ceiling on `disputeTimeout` — bounds how long a filing may pin a
    ///      guardian's coverage. A worst-case adjudication needs at most
    ///      `MAX_VOTE_WINDOW + FINALIZE_BUFFER` (15 days) after referral, so 60
    ///      days leaves 45 days of `autoSlashDelay` headroom above that, and
    ///      stays compatible with the cross-contract window invariant
    ///      (`_requireWindowFits`).
    uint256 public constant MAX_DISPUTE_TIMEOUT = 60 days;

    /// @dev THE GAS FLOOR for a permissionless `resolve`.
    ///
    ///      WHAT IT PROTECTS, RESTATED FOR THE BURN. It was written for a
    ///      starved `openCase` child inside `slashToEscrow`, whose out-of-gas
    ///      revert was indistinguishable from a missing selector and so BURNED
    ///      the victims' compensation instead of bubbling. That child is gone: proceeds burn inside sWOOD and
    ///      there is no external sink. What remains is `demoteByChallenge`
    ///      below — a BEST-EFFORT `try/catch` that runs AFTER
    ///      the slash. Under EIP-150 a caller supplying just enough gas to
    ///      finish the slash alone would leave that child 63/64 of a
    ///      nearly-empty frame. Issue #51 posited that this silently starves
    ///      the demotion: the child OOGs, the catch swallows it, and the
    ///      verdict settles with the challenged adapter KEEPING its
    ///      certification. VERIFIED AGAINST THE REAL STACK (openspec
    ///      settle-demotion-gas-floor `design.md`, "Is the silent miss
    ///      reachable?"): that path was never reachable, even before
    ///      `DEMOTION_GAS` existed — an OOG child consumes its entire 63/64
    ///      stipend, leaving the parent only 1/64 of a frame, which is too
    ///      small to pay for the settle's own tail below the demotion (the
    ///      burn/refund transfers and events), so a budget tight enough to
    ///      starve the demotion OOGs the WHOLE settle instead of completing
    ///      it silently. That protection was incidental, though: an artifact
    ///      of these constants' measured slack and the tail's size, neither
    ///      stated nor tested, one refactor (retuned constants, a slimmer
    ///      tail) from disappearing. `DEMOTION_GAS` below makes it
    ///      structural — a settle that clears the floor is GUARANTEED enough
    ///      gas to reach the demotion child with room for it to succeed, not
    ///      merely likely to OOG the whole call before completing silently.
    ///      Everything else after
    ///      the slash reverts the whole call (unguarded `safeTransfer`s) or is
    ///      internal bookkeeping, so it is safe by rollback. The floor is still
    ///      sized per approver plus a base: the slash loop runs first, so a
    ///      flat floor would let a large batch consume it before the work that
    ///      needs protecting.
    ///
    ///      THE CONSTANTS BELOW ARE MEASURED AGAINST THE PRE-BURN PATH and are
    ///      therefore CONSERVATIVE, not tight — the `openCase` child they
    ///      reserved for (~150-200k, plus the allowance dance) no longer runs.
    ///      They are deliberately NOT re-tightened here. A floor measured
    ///      against `slashVerdict` ALONE under-reserves: it misses the bond
    ///      forfeiture, the demote child and the payouts that follow, all
    ///      of which this check must also cover. Re-derive end to end (through
    ///      court `finalize`, as `SlashGasCeiling.t.sol` already does) before
    ///      moving them; over-reserving only rejects an under-gassed caller,
    ///      while under-reserving silently drops demotions.
    ///
    ///      A FLOOR MUST ALSO BE REACHABLE, WHICH THIS ONE WAS NOT. At the
    ///      previous 300k/1M the full-cap floor was
    ///      `100 * 300_000 + 1_000_000 = 31,000,000` — read INSIDE
    ///      `ChallengeGame.rule`, two `CALL`s below an EOA on the court path
    ///      (`finalize` -> `rule`; `_settle` is private and adds no frame,
    ///      and neither contract is proxied). Robinhood Chain (4663) caps a
    ///      transaction at `maxTxGasLimit = 32,000,000`
    ///      (`ArbGasInfo.getGasAccountingParams()`, probed on mainnet
    ///      2026-07-24 — the block `gasLimit` field is Orbit's 2^50 "no block
    ///      cap" sentinel, so the per-tx limit is the binding one). Two
    ///      EIP-150 haircuts put 31,000,000 out of reach of ANY transaction,
    ///      so a conviction against a full cohort could not be mined at all:
    ///      `finalize` bubbles the revert (it swallows only `WrongStatus`),
    ///      the case sits in `Voting`, and the challenge times out through
    ///      `resolve` -> `_fail`, ACQUITTING the accused and paying them the
    ///      challenger's forfeited bond. A gas floor that converts a guilty
    ///      verdict into an acquittal is worse than the mid-array
    ///      out-of-gas it was written to prevent.
    ///
    ///      THE NUMBERS ARE NOW MEASURED, NOT ESTIMATED
    ///      (`test/SlashGasCeiling.t.sol`). A conviction run end to end
    ///      against the real stack — court `finalize`, every approver
    ///      carrying a real non-zero rate, so every one is a genuine
    ///      `_slashOne` — costs:
    ///
    ///          4 approvers      713,853
    ///         52 approvers    5,428,313
    ///        100 approvers   11,176,224
    ///
    ///      which fits `~224*n^2 + 85,659*n + 367,629`: a ~368k fixed base,
    ///      ~86k of linear work per approver, and `slashToEscrow`'s O(n²)
    ///      pairwise dedup scan at ~224 gas per pair (2.24M of the total at
    ///      the cap). Average cost per approver at the cap is ~108k; the
    ///      MARGINAL cost of the hundredth is ~130k. 300k was therefore
    ///      2.3-3.5x over-provisioned, and that over-provisioning — not the
    ///      approver cap — is what made the floor unreachable.
    ///
    ///      180k/approver keeps ~1.4x over the marginal cost of the last
    ///      approver and ~1.7x over the average, which is the headroom that
    ///      matters for the cases this fixture does NOT reproduce: a
    ///      long-lived guardian whose checkpoint trace makes each
    ///      `upperLookupRecent` a deeper binary search than a freshly-staked
    ///      one. The base doubles to 2M rather than shrinking, so the
    ///      `openCase` child (~150-200k observed) keeps well over the >5x
    ///      margin after 63/64 forwarding that the original sizing argued
    ///      for, with the parent's burn/bubble branch still affordable behind
    ///      it.
    ///
    ///      Full-cap floor for a zero-adapter settle (these two terms alone)
    ///      is `100 * 180_000 + 2_000_000 = 20,000,000` against a
    ///      `32,000,000 * (63/64)^3 = 30,523,315` ceiling — 1.5x of slack,
    ///      and 1.8x over what a full-cap conviction actually spends. An
    ///      adapter-naming settle adds `DEMOTION_GAS` below — see that
    ///      constant's natspec for the resulting total and headroom.
    ///      THE APPROVER CAP IS UNCHANGED: `MAX_APPROVERS_PER_PROPOSAL` is
    ///      also the size of the cohort that can underwrite one proposal, so
    ///      cutting it would cut coverage capacity, and the measurement shows
    ///      nothing required that. `test_slashGasFloorFitsRobinhoodMaxTxGas`
    ///      is the CI tripwire that keeps this true.
    uint256 public constant SLASH_GAS_PER_APPROVER = 180_000;
    uint256 public constant SLASH_GAS_BASE = 2_000_000;

    /// @dev THE DEMOTION GAS TERM (issue #51, openspec
    ///      settle-demotion-gas-floor). Added to the floor above ONLY when
    ///      the challenge names a non-zero adapter
    ///      (`c.adapterTarget != address(0)` in `_settle`) — a zero-adapter
    ///      filing demotes nothing and owes nothing for it.
    ///
    ///      THE ADVERSARY: a permissionless `resolve`/`finalize` caller
    ///      dialling gas so the conviction lands but `demoteByChallenge`'s
    ///      child starves under EIP-150's 63/64 forwarding, letting the
    ///      adapter keep its certification with only `AdapterDemotionFailed`
    ///      to show for it. That path is unreachable even without this term
    ///      (see the comment above `SLASH_GAS_PER_APPROVER`), but the
    ///      unreachability was incidental — this term makes the guarantee
    ///      structural instead of emergent.
    ///
    ///      SIZING: `TierRegistry._demote` (`demoteByChallenge`'s callee)
    ///      does a role check, deletes a 2-slot `_configs` entry, may flip
    ///      one bond-release timelock slot 0->nonzero, and emits two events —
    ///      estimated worst case ~45k, ~50k once issue #77 adds a
    ///      `delete _adapterAllowed[target]` inside it. `DEMOTION_GAS =
    ///      200_000` forwards ~197k after 63/64 forwarding even if every gas
    ///      unit before the demotion call was spent exactly to the floor's
    ///      budget — ~4x the estimated worst case including #77's headroom,
    ///      in line with this file's other constants (the per-approver term
    ///      is ~1.4x its measured value, the base >5x). The demotion-cost
    ///      bracketing test in `test/SlashGasCeiling.t.sol` anchors this to a
    ///      measurement against the real `TierRegistry`, not just the
    ///      estimate above.
    ///
    ///      Full-cap floor for an adapter-naming settle is now
    ///      `100 * 180_000 + 2_000_000 + 200_000 = 20,200,000` against the
    ///      same `30,523,315` ceiling — 1.511x headroom (was 1.526x without
    ///      this term; it costs about 1% of the slack).
    ///      `test_slashGasFloorFitsRobinhoodMaxTxGas` gates this in CI.
    uint256 public constant DEMOTION_GAS = 200_000;

    /// @notice Where every burned slice of a challenger's bond goes — both the
    ///         settle path's `settleBurnBps` and the fail path's
    ///         `forfeitBurnBps` send here.
    /// @dev    Not a real burn: WOOD is a plain `IERC20` with no `burn`
    ///         function, and `address(0)` is unusable because OpenZeppelin's
    ///         ERC20 rejects transfers to it (which would brick resolution).
    ///         The conventional dead address has no known key and is
    ///         universally read as destroyed; total supply keeps counting it,
    ///         but nothing in this game can ever spend it again.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Ceiling on `forfeitBurnBps`. The burn prices a self-challenge round
    ///      trip out of profitability without punishing an honest defence: an
    ///      approver that correctly beats a bad-faith filing must still come
    ///      out clearly ahead, or the counter-bond pool stops getting funded.
    ///      Half the forfeit leaves an honest defender the larger share, and
    ///      doubles as a cap on how much a captured owner can destroy per
    ///      failed challenge.
    uint256 internal constant MAX_FORFEIT_BURN_BPS = 5_000;

    /// @dev Ceiling on `settleBurnBps`. Burning the whole bond would make a
    ///      correct filing cost as much as a wrong one, removing the only
    ///      on-chain reason to file at all.
    uint256 internal constant MAX_SETTLE_BURN_BPS = 5_000;

    /// @dev Ceiling on `inconclusiveBurnBps`, identical to `MAX_SETTLE_BURN_BPS`:
    ///      an `Inconclusive` unwind is a non-verdict — nothing was
    ///      adjudicated or recovered — and must never cost the challenger more
    ///      than a verdict that actually recovered value. Equal ceilings alone
    ///      only bound each rate's maximum; `setSettleBurnBps` and
    ///      `setInconclusiveBurnBps` additionally cross-check each other's LIVE
    ///      value to keep that ordering true at every point, not just at the
    ///      ceiling.
    uint256 internal constant MAX_INCONCLUSIVE_BURN_BPS = MAX_SETTLE_BURN_BPS;

    /// @dev Round-2 step of the escalating Inconclusive-burn schedule. Fixed,
    ///      not owner-settable — the schedule's shape is a one-time design
    ///      decision; only its ceiling (`inconclusiveBurnBps`) is a governance
    ///      knob. See `_inconclusiveBurnBpsForRound` for how the schedule
    ///      composes, including the live clamp to `settleBurnBps` that also
    ///      covers this fixed literal.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND2_BPS = 500;

    /// @dev Round-3 step — see `INCONCLUSIVE_BURN_ROUND2_BPS`.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND3_BPS = 1_000;

    /// @notice Bond currency for both the challenger's bond and the accused's
    ///         counter-bond.
    IERC20 public immutable wood;

    /// @notice Source of truth for who covered a proposal and for how much, and
    ///         the contract whose coverage this game freezes (per-proposal,
    ///         never whole-stake). This game must be the ledger's
    ///         `coverageFreezer`.
    IExposureLedger public exposureLedger;

    /// @notice Adapter certification registry. Read on the passed-challenge
    ///         path only; this game must be its `authorizedDemoter`.
    ITierRegistryDemoterMinimal public tierRegistry;

    /// @notice The sole WOOD custodian and the contract that executes the
    ///         verdict slash (`slashVerdict`). This game must be its
    ///         `authorizedSlasher`. Owner-set after construction because the
    ///         role is granted on sWOOD's side and the two are wired in either
    ///         order at deploy time.
    /// @dev    There is no sink to name: slash proceeds burn inside sWOOD, so
    ///         this game cannot redirect them anywhere at all.
    ///
    ///         Nor can it name a payee: `slashVerdict` takes no recipient at
    ///         all, so there is no bounty channel here to bound. The
    ///         prosecutor is paid out of the convicted PROPOSER's forfeited
    ///         bond instead (`ProposerBondEscrow.forfeitBond`), which is the
    ///         one pot a prosecutor cannot fund for itself — a guardian that
    ///         approves a proposal in order to accuse it can move the slash,
    ///         but it can never post the accused's bond. `_settle` forwards
    ///         the challenge's pinned `prosecutorFeeBpsAtFiling` to the escrow
    ///         on every conviction, silence path included.
    IStakedWood public stakedWood;

    /// @notice The adjudicator for disputed challenges — the only address that
    ///         may `rule`.
    /// @dev    The zero address leaves every disputed challenge to time out in
    ///         favour of the accused: no caller can match it, so `rule` is
    ///         unreachable. That makes the court additive and gives governance
    ///         an off-switch — unwire a captured court and fall back to the
    ///         fail-safe timeout instead of being stuck with an adjudicator
    ///         that can force slashes.
    address public court;

    /// @notice The owner's only lever that gates NEW filings: true refuses
    ///         `file` alone. Never checked in `dispute`, `resolve`, `rule`, or
    ///         either claim path.
    /// @dev    Restricted to `file` deliberately: pausing anything that could
    ///         freeze `dispute`/`resolve`/`rule` mid-flight would let a
    ///         disputed-but-not-yet-referred challenge drift into
    ///         `disputeTimeout`'s `_fail` branch and forfeit the challenger's
    ///         bond by owner inaction rather than anything the challenger did.
    ///         The worst a hostile or compromised owner can do with this flag
    ///         is stop new challenges from starting — never freeze one that
    ///         already exists, and never move the economic terms
    ///         (`autoSlashDelayAtFiling`, `disputeTimeoutAtFiling`,
    ///         `settleBurnBpsAtFiling`, `forfeitBurnBpsAtFiling`) a live
    ///         challenge is judged and priced against, since those are pinned
    ///         at filing.
    /// @dev    `setCourt` stays live-read regardless of this pause: pinning the
    ///         court per challenge would strand every open dispute on a dead or
    ///         replaced adjudicator instead of letting governance rescue it.
    bool public filingsPaused;

    /// @notice How long after execution a proposal remains challengeable —
    ///         matches the ledger's coverage window, since coverage that has
    ///         expired out of the exposure buckets can no longer be
    ///         meaningfully frozen.
    uint256 public challengeWindow = 14 days;

    /// @notice Challenger bond as bps of the USD coverage a filing freezes.
    ///         Load-bearing: with no proof required this is the only cost of a
    ///         frivolous filing, and a failed challenge forfeits it to the
    ///         accused approvers.
    uint256 public challengerBondBps = 500;

    /// @notice The slice of a FAILED challenge's forfeited bond that is
    ///         destroyed rather than paid to the guardians that funded the
    ///         defence, in bps of the bond. Default 20%.
    /// @dev    Prices self-challenging. An approver could file against its own
    ///         executed proposal, fund the entire counter-bond pool itself, sit
    ///         out `disputeTimeout`, and collect its contribution back plus
    ///         100% of the forfeit — net cost zero, while every co-approver's
    ///         coverage sat frozen. A `msg.sender != challenger` check is
    ///         theatre (two addresses defeat it), so the slice is burned
    ///         instead: the attacker controls both sides of the trade, so any
    ///         recipient it can reach is a round trip — only destruction has no
    ///         beneficiary to be.
    /// @dev    Taken off the top before the pro-rata split, so it changes only
    ///         the pot size, not who is entitled to it: a free-riding approver
    ///         still collects nothing, and a losing challenger still forfeits
    ///         the whole bond either way.
    /// @dev    Only the forfeit is burned — a guilty ruling pays the challenger
    ///         its bond back plus the whole pool untouched, because there the
    ///         challenger and the accused are genuinely opposed and no round
    ///         trip exists to price.
    uint256 public forfeitBurnBps = 2_000;

    /// @notice Silence window: an uncontested challenge auto-slashes once this
    ///         much time has passed since filing. See `MIN_AUTO_SLASH_DELAY`
    ///         for why its floor is load-bearing.
    uint256 public autoSlashDelay = 7 days;

    /// @notice How long a DISPUTED challenge waits for a ruling before failing
    ///         to the accused. Measured from `filedAt`, like the auto-slash
    ///         delay, and always strictly greater than it — the two setters
    ///         enforce that jointly, because a timeout at or below the slash
    ///         clock would let a contested challenge fail before the slash it
    ///         was raised against was ever due.
    /// @dev    Deliberately generous relative to `autoSlashDelay`: guardians
    ///         carry the vigilance burden, so the escalation they buy with a
    ///         counter-bond must be worth more than the window they lost.
    uint256 public disputeTimeout = 30 days;

    /// @notice Share of a SUCCESSFUL challenger's bond burned on settle, in bps.
    /// @dev    Prices a filing in both directions: refunding the bond in full
    ///         would make the slash of the accused and the demotion of the
    ///         named adapter come for the price of gas alone. 20% is a cost
    ///         rather than a transfer to the accused — paying convicted
    ///         approvers out of a correct filing would invert the incentive
    ///         it's meant to price.
    uint256 public settleBurnBps = 2_000;

    /// @notice Ceiling on `prosecutorFeeBps`, mirroring
    ///         `ProposerBondEscrow.MAX_PROSECUTOR_FEE_BPS`.
    /// @dev    A CONVENIENCE GUARD, NOT THE AUTHORITY. The escrow enforces its
    ///         own bound on every forfeiture and is the contract that actually
    ///         moves the WOOD; this only stops governance setting a rate that
    ///         would be rejected later. The escrow is chosen per proposal, so
    ///         there is no single one to consult at set time — and reading it
    ///         at filing would make the pinned rate depend on an external call
    ///         and pin zero for any proposal carrying no bond at all.
    uint256 public constant MAX_PROSECUTOR_FEE_BPS = 2_000;

    /// @notice Slice of the convicted PROPOSER's forfeited bond paid to the
    ///         challenger that caused the conviction, in bps. Default 5%.
    /// @dev    NOT a slice of the slash. The slash pays nobody — `slashVerdict`
    ///         takes no payee and burns everything it collects — and that
    ///         separation is the point. A reward funded from the slash is a pot
    ///         the prosecutor can fill for itself, by staking, approving the
    ///         proposal it is about to accuse, and collecting a fee sized by
    ///         its own punishment. The proposer's bond cannot be self-funded:
    ///         nobody can post the accused's bond on their behalf, so a
    ///         self-dealing filer pays the bond in full and recovers at most
    ///         `MAX_PROSECUTOR_FEE_BPS` of it. Sybil-proof by construction
    ///         rather than by parameter, which is why no anti-abuse gate rides
    ///         on top of this rate.
    /// @dev    PAID ON EVERY CONVICTION, silence path included — the path this
    ///         reward exists for. A correct filing nobody answered used to pay
    ///         nothing at all AND cost the filer `settleBurnBps` of its bond,
    ///         so the only profitable honest filing was one that provoked a
    ///         fight (issue #91). On the escalated path the challenger already
    ///         takes bond + the forfeited pool; the fee is additive there.
    /// @dev    Pinned per challenge at filing (`prosecutorFeeBpsAtFiling`), so
    ///         a governance change cannot re-rate a challenge already in
    ///         flight. If the escrow rejects a pinned rate, `_settle` retries
    ///         the forfeiture without a fee rather than losing the conviction.
    /// @dev    UNDERIVED. 5% is inherited from the conviction bounty this
    ///         replaced and has never been priced against what a correct filing
    ///         actually costs to produce. Bounded, not justified.
    uint256 public prosecutorFeeBps = 500;

    /// @notice The round-4-and-beyond steady-state share of the challenger's
    ///         bond burned on an `Inconclusive` unwind, in bps. Default 20% —
    ///         see `_inconclusiveBurnBpsForRound` for the full schedule (rounds
    ///         1-3 are fixed, lower steps) and `inconclusiveRounds` for what a
    ///         "round" counts.
    /// @dev    Prices repeated stalling. An attacker can freeze a cohort's
    ///         coverage by filing, funding its own counter-bond, and letting
    ///         turnout miss quorum — `Inconclusive` re-arms the re-challenge
    ///         window (see `_refundAll`), so the cycle is repeatable
    ///         indefinitely. A flat burn rate cannot separate a genuinely
    ///         honest one-shot filer from a grinder, since it is invariant to
    ///         repetition; the rate therefore escalates with the round count
    ///         (`inconclusiveRounds`) instead: round 1 free, round 2 and 3
    ///         fixed steps, round 4+ this variable, clamped live to
    ///         `settleBurnBps`.
    /// @dev    Deliberately below `settleBurnBps` at every tier, enforced by
    ///         both setters cross-checking each other's LIVE value (not merely
    ///         sharing a ceiling): a non-verdict recovered nothing, so it must
    ///         cost strictly less than a verdict that recovered real value.
    ///         See `setInconclusiveBurnBps`/`setSettleBurnBps` for the
    ///         enforcement and `_inconclusiveBurnBpsForRound` for why every
    ///         tier — including the two fixed literals outside that setter
    ///         pair — is additionally clamped there.
    uint256 public inconclusiveBurnBps = 2_000;

    /// @notice WOOD held on behalf of live (`Filed`/`Disputed`) challenges —
    ///         the sum of their challenger bonds and counter-bond pools.
    /// @dev    Invariant: `wood.balanceOf(this) >= bondedWood`. A partial pool
    ///         counts here exactly like a complete one — every terminal path
    ///         refunds, forfeits, or splits it, so the decrement is always
    ///         `bond + pool`, including the burned slice, which leaves the
    ///         contract like any other payout.
    uint256 public bondedWood;

    /// @inheritdoc IChallengeGame
    /// @dev WOOD owed to counter-bond funders of TERMINAL challenges, not yet
    ///      collected. Kept separate from `bondedWood`, which means "held for
    ///      a LIVE challenge" — the invariant "no live challenge implies
    ///      `bondedWood == 0`" depends on the two staying apart. Widens the
    ///      custody invariant to `wood.balanceOf(this) >= bondedWood +
    ///      unclaimedWood`.
    ///
    ///      Never returns to zero exactly on a failed challenge: lazy pro-rata
    ///      shares floor-divide independently, so wei-scale dust stays
    ///      accounted here forever — hence `>=` rather than `==`.
    uint256 public unclaimedWood;

    uint256 public challengeCount;

    /// @inheritdoc IChallengeGame
    /// @dev Never read as a stored absolute — `file` always maxes this value
    ///      against the live `executedAt + challengeWindow` baseline at the
    ///      call site. `challengeWindow` is live, mutable state, so comparing
    ///      only at write time would let a shortened-then-restored window
    ///      leave this mapping holding a deadline smaller than a fresh
    ///      proposal would ever compute, with no setter to fix it. This
    ///      mapping only ever needs to raise the floor, never defend a stored
    ///      value against having gone stale.
    mapping(bytes32 reviewKey => uint256) public challengeableUntil;

    /// @inheritdoc IChallengeGame
    /// @dev How many times this proposal has gone `Inconclusive`. Incremented
    ///      in `_refundAll` alongside the `challengeableUntil` re-arm — a round
    ///      only counts if the proposal is still contestable at all. `file`
    ///      reads it to pin the escalated rate (`_inconclusiveBurnBpsForRound`)
    ///      and resets it to zero once the re-armed window has lapsed with
    ///      nobody refiling inside it.
    /// @dev Keyed on the proposal alone, not `(reviewKey, challenger)`: a
    ///      per-challenger counter would be trivially reset by switching
    ///      identity, undoing the escalation. Per-proposal accounting means
    ///      whoever files next pays for the PROPOSAL's history, not their own
    ///      wallet's.
    mapping(bytes32 reviewKey => uint256) public inconclusiveRounds;

    mapping(uint256 challengeId => Challenge) internal _challenges;

    /// @dev Who has paid into a challenge's counter-bond pool, in first-payment
    ///      order and without duplicates — a repeat contributor tops up its
    ///      existing entry rather than appending a second one. Bounded because
    ///      `dispute` admits only the accused set, which the ledger itself
    ///      caps.
    mapping(uint256 challengeId => address[]) internal _contributors;

    /// @dev Per-contributor totals, kept after resolution rather than cleared
    ///      so the pro-rata split a terminal challenge paid out stays
    ///      reconstructible on-chain; no path re-reads a terminal challenge's
    ///      pool anyway.
    mapping(uint256 challengeId => mapping(address contributor => uint256)) internal _contributed;

    /// @dev The most recent challenge against a proposal. Only meaningful while
    ///      that challenge is still live — `_liveChallengeId` re-checks status
    ///      rather than trusting the pointer, so a terminal challenge never
    ///      blocks a later, legitimate one. Kept for indexers; the blocking
    ///      question is now asked per challenger via `_liveByChallenger`.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

    /// @dev One slot per CHALLENGER, not per proposal: keying by proposal alone
    ///      would let an accused cohort buy free immunity by self-filing and
    ///      self-disputing to occupy the only slot until the challenge window
    ///      shuts — `disputeTimeout` (30d) outlives `challengeWindow` (14d).
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
    ///      independently via `_verdictSlashed` keyed on the same review key.
    ///      Without this flag a second concurrent settle would hit that guard,
    ///      revert `ApproverAlreadySlashed`, and wedge an otherwise-correct
    ///      challenge in `Filed` with no terminal path.
    ///
    ///      This flag is only half the dedup: sWOOD's `_verdictSlashed` is
    ///      keyed on `keccak256(governor, proposalId)`, stable across
    ///      redeployments of this game, while this mapping is per-deployment
    ///      storage that starts empty. Since this contract is not upgradeable,
    ///      redeployment is the supported migration path — `StakedWood.
    ///      setAuthorizedSlasher`, `ExposureLedger.setCoverageFreezer` and
    ///      `TokenCourt.setChallengeGame` all exist to re-point at a new
    ///      deployment. A V1 conviction (a partial slash is the norm) would
    ///      otherwise leave every V2 filing against the same proposal
    ///      believing the liability is uncollected, sending `_settle` into a
    ///      permanent revert with the bond, counter-bond and coverage freeze
    ///      all stranded. `_verdictAlreadyCollected` asks sWOOD's own
    ///      `verdictSlashed` view at both ends, so this flag is a cheap local
    ///      cache of a cross-deployment fact, not the fact itself.
    mapping(bytes32 reviewKey => bool) internal _convicted;

    /// @dev Bounds the constructed `challengeWindow` against the wired
    ///      ledger's own window, the same way `setChallengeWindow` and
    ///      `setExposureLedger` bound it at runtime — a game window above the
    ///      ledger's would let a filing freeze exposure the ledger has already
    ///      aged out of its epoch buckets. Does not check the ledger's
    ///      `coverageFreezer` grant: this contract's address does not exist
    ///      yet while the constructor runs, so the ledger cannot have been
    ///      pointed at it — the deploy scripts' own pre-flight covers that
    ///      wiring step.
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
    ///      earlier challenge in this deployment, or by any earlier deployment
    ///      of this game against the same sWOOD?
    ///
    ///      The local flag is checked first (cheap, answers the common case);
    ///      the sWOOD scan is what makes the answer correct across a redeploy.
    ///      Any hit is decisive: `slashVerdict` reverts `ApproverAlreadySlashed`
    ///      if any accused member is already marked under this `caseKey`, so
    ///      one marked approver means a slash of this cohort can never land
    ///      again.
    ///
    ///      Bounded: the loop runs over the ledger's accused set, which the
    ///      ledger caps, and short-circuits on the first hit.
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
    ///      contract-level note. Adding a branch here for any predicate
    ///      reintroduces the two-security-models problem this design avoids.
    /// @dev CEI: the challenge is recorded before the freeze and before the
    ///      bond transfer, so neither external call can observe or re-enter a
    ///      half-written challenge.
    /// @dev The challenger names the adapter it accuses; the chain does not
    ///      derive it. Derivation would mean re-parsing the proposal's execute
    ///      calls here — a second calldata parser beside the vault's own — and
    ///      a multi-call proposal has no single derivable culprit anyway.
    ///      Naming it is also the more honest model: which adapter misbehaved
    ///      is part of the assertion, filed under the same bond as the rest of
    ///      it.
    function file(
        address governor,
        uint256 proposalId,
        Predicate predicate,
        address adapterTarget,
        bytes4 adapterSelector,
        string calldata evidenceURI
    ) external returns (uint256 challengeId) {
        // Checked first: pausing stops a new filing from starting; it never
        // touches a challenge already in flight — see `filingsPaused`.
        if (filingsPaused) revert FilingsPaused();

        // A challenge accuses an EXECUTED proposal: there is no drain to allege
        // before execution, and `executedAt` is the pre-drain snapshot basis on
        // the slash path. The proposal is read once here and the fields the
        // verdict needs are pinned onto the challenge, so `_settle` cannot be
        // moved by a governor mutating them before resolution.
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);
        uint256 executedAt = p.executedAt;
        if (executedAt == 0) revert NotExecuted();

        // The filing deadline is the LARGER of the ordinary
        // `executedAt + challengeWindow` and whatever `_refundAll` has raised
        // `challengeableUntil` to for an earlier `Inconclusive` unwind on this
        // proposal — without that floor, an `Inconclusive` landing late could
        // make acquittal permanent. Recomputed as a max on every call rather
        // than trusted as a stored absolute, since `challengeWindow` is live,
        // mutable state and a stored value could otherwise go stale below what
        // a fresh proposal would compute.
        //
        // `key` is computed once here for both this gate and the
        // `AlreadyConvicted`/`AlreadyChallenged` checks below.
        bytes32 key = _reviewKey(governor, proposalId);
        uint256 deadline = executedAt + challengeWindow;
        uint256 extended = challengeableUntil[key];
        if (extended > deadline) deadline = extended;
        if (block.timestamp > deadline) revert WindowClosed();

        // The Inconclusive-round streak resets once `challengeableUntil[key]`
        // lapses naturally, checked against that value specifically rather
        // than the combined `deadline` above: once any round has gone
        // Inconclusive, `challengeableUntil[key]` is always >= the ordinary
        // baseline. Reaching this branch means the repetition the schedule
        // prices has stopped, so the counter resets rather than punishing an
        // unrelated later filer with a stale streak.
        if (block.timestamp > challengeableUntil[key] && inconclusiveRounds[key] != 0) {
            inconclusiveRounds[key] = 0;
        }

        // The named adapter must appear in the proposal's own stored execute
        // calls — a membership test over data the governor already holds, not
        // a second calldata parser. Without it, a passed challenge could demote
        // an arbitrary certified adapter anywhere in the registry.
        if (adapterTarget != address(0)) {
            _requireAdapterInProposal(governor, proposalId, adapterTarget, adapterSelector);
        }

        // The approvers underwrote ONE proposal and owe ONE liability. Once a
        // settled challenge has collected it, every later filing must be
        // refused at the door: it could still freeze coverage (barring an
        // accused approver from `claimUnstakeGuardian`) for another
        // `autoSlashDelay` while collecting nothing, cheaply and repeatedly
        // since slots are per-challenger. A failed challenge is different and
        // still allowed: it collected nothing, so the liability is outstanding
        // and a fresh filing is legitimate.
        if (_convicted[key]) revert AlreadyConvicted();
        // One live challenge per CHALLENGER — see `_liveByChallenger`.
        // Concurrency is safe because the freeze is refcounted below and the
        // conviction is deduped by `_convicted`.
        bytes32 challengerKey = _challengerKey(key, msg.sender);
        if (_liveChallengeId(_liveByChallenger[challengerKey]) != 0) revert AlreadyChallenged();

        // The accused set is the ledger's committed approvers: slashing
        // exactly those keeps recovery equal to the sum of their bonds. A
        // released commitment reports zero and contributes nothing to the
        // frozen total.
        (address[] memory covering, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 coverageUsd;
        uint256 accusedCount;
        for (uint256 i = 0; i < committedUsd.length; i++) {
            coverageUsd += committedUsd[i];
            if (committedUsd[i] != 0) accusedCount++;
        }
        if (coverageUsd == 0) revert NothingToFreeze();

        // Same refusal as `_convicted` above, but asked of sWOOD directly:
        // `_convicted` is this deployment's storage and starts empty on a
        // redeploy, while sWOOD's `verdictSlashed` is keyed on
        // `(governor, proposalId)` and survives one. Without this, a game
        // deployed to replace an earlier one would accept filings against a
        // cohort the OLD game already convicted, freeze coverage and take the
        // bond, then be unable to terminate (`_settle`'s `slashVerdict` would
        // revert `ApproverAlreadySlashed`, and `rule` is unreachable from
        // `Filed`).
        //
        // The accused set is the committed cohort, the same one `_settle`
        // sends to `slashVerdict`; a released approver reports zero committed
        // USD and is excluded from both.
        address[] memory accused = new address[](accusedCount);
        for (uint256 i = 0; i < committedUsd.length; i++) {
            if (committedUsd[i] == 0) continue;
            accused[--accusedCount] = covering[i];
        }
        if (_verdictAlreadyCollected(key, accused)) revert AlreadyConvicted();

        // RESERVATIONS ARE NOT LIABILITY. The sum above is what
        // the cohort RESERVED, and `recordApproval` deliberately over-reserves —
        // every approver books up to the full coverage, because at vote time any
        // one of them might end up carrying it alone. So it exceeds what a
        // conviction could ever take, by a factor that GROWS WITH THE APPROVER
        // COUNT: five well-funded approvers on one proposal reserve five times
        // its need. Sizing the bond off it made a proposal more expensive to
        // challenge the better covered it was, while the recoverable total
        // stayed flat — the exact inversion of D4, which sizes the bond to the
        // exposure a filing freezes. `liabilityUsd` is that exposure, asked for
        // once.
        //
        // NOTE — the slash no longer shares this basis. `slashBpsFor` used to
        // price convictions against the same ALLOCATION, which is why this
        // comment once cited it as precedent; it is now punitive and reads no
        // allocation at all. The bond stays allocation-sized regardless: what
        // it must be proportional to is the exposure a filing FREEZES, which is
        // unchanged by how hard the eventual conviction bites.
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

        // The bond scales with the exposure the filing freezes, converted at
        // the ledger's composed WOOD/USD price (X8) — the same haircut-applied
        // price every other conversion in this codebase divides by, so it
        // stays in the same units as `liabilityUsd`'s own numerator and stays
        // fresh with market stress rather than a manually-updated scalar.
        // Fails closed on both an unset price (transient, protocol-wide — wait
        // for governance) and a bond that floors to zero (permanent,
        // proposal-specific — no coverage or price change fixes it), named
        // with separate selectors since the two are opposite failures.
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
            // Both clocks are pinned here: read live, the owner could shorten
            // `autoSlashDelay` after filing and retroactively erase a window
            // the accused was still inside, or raise `disputeTimeout` against
            // a live dispute and extend the freeze.
            autoSlashDelayAtFiling: autoSlashDelay,
            disputeTimeoutAtFiling: disputeTimeout,
            // Both burn rates pinned too: the challenger relies on
            // `settleBurnBps` when it files and cannot withdraw, and the
            // accused rely on `forfeitBurnBps` when funding the counter-bond.
            // A live read would let a post-filing raise take a larger bite of
            // a commitment already made.
            settleBurnBpsAtFiling: settleBurnBps,
            forfeitBurnBpsAtFiling: forfeitBurnBps,
            // Pinned for the same reason: a live read would change what the
            // challenger stood to collect on a conviction it already bonded
            // against. Bounded by `MAX_PROSECUTOR_FEE_BPS` at set time, and
            // bounded AGAIN by the paying escrow at forfeit time — the escrow
            // is the authority, this is the convenience guard.
            prosecutorFeeBpsAtFiling: prosecutorFeeBps,
            // Written only by `_fail`, which is the sole path that gives the
            // pool's funders anything beyond their stake back.
            forfeitPayoutWood: 0,
            // Pinned for the same reason as the other rates above, but to the
            // escalated schedule value rather than the flat
            // `inconclusiveBurnBps` directly — `_inconclusiveBurnBpsForRound`
            // resolves round 1's free rate, round 2/3's fixed steps, or the
            // round-4+ ceiling, whichever applies, clamped live to
            // `settleBurnBps`. Ordered last to match the struct's field order
            // — see `IChallengeGame.Challenge`.
            inconclusiveBurnBpsAtFiling: _inconclusiveBurnBpsForRound(inconclusiveRounds[key]),
            // The escrow holding this proposal's proposer bond, off the same
            // `getProposal` read `executedAt` and `vault` came from. Bound at
            // propose time and never re-pointed for an existing proposal, so
            // pinning it costs nothing: a verdict up to `disputeTimeout` later
            // confiscates from the escrow the bond was locked in, not whatever
            // the governor's live slot says today.
            proposerBondEscrow: p.proposerBondEscrow
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
    /// @dev The pool's target matches the challenger's bond and does not move
    ///      — the accused side buys the escalation at exactly the price the
    ///      challenger paid for the accusation. What changes is only who pays
    ///      it: pinning the total and letting only the payer vary is what
    ///      makes identity-splitting cost exactly what staying whole costs.
    /// @dev The overshoot is clamped, not refunded: `amountWood` is reduced to
    ///      the shortfall so the contract never holds a wei it must later hand
    ///      back for being overpaid.
    /// @dev The status flips to `Disputed` the moment the pool is full, in the
    ///      same call — that is what keeps `_settle`'s two entries
    ///      distinguishable by status alone: `Filed` implies a pool strictly
    ///      below target (never bought a dispute, so refunded) and `Disputed`
    ///      implies a full one (forfeited).
    /// @dev The contribution window closes exactly where the auto-slash opens
    ///      (`filedAt + autoSlashDelayAtFiling`), read from the pinned value
    ///      rather than the live parameter — a live read would let the owner
    ///      shorten `autoSlashDelay` after filing and retroactively close a
    ///      window the accused were still inside.
    /// @dev Open to anyone, not only the accused: a cohort short of funds with
    ///      little time left could otherwise never be topped up. Skin in the
    ///      game is enforced economically rather than by identity — a guilty
    ///      ruling forfeits the whole pool to the challenger, so an outside
    ///      funder risks real capital. This also lets a third party who
    ///      believes the accused innocent pay to force adjudication rather
    ///      than let an unproven silence verdict stand.
    /// @dev CEI: every storage write lands before the `transferFrom`, so the
    ///      token cannot observe or re-enter a half-updated pool.
    /// @dev Best-effort auto-referral, run LAST — after the transfer and both
    ///      events, so it never reorders anything CEI above already
    ///      guarantees. The catch stays broad (any revert swallowed, reported
    ///      via `AutoReferFailed`) and is deliberately unguarded by any gas
    ///      floor: `dispute` is how the accused buy their defence, and a
    ///      revert here would leave the counter-bond incomplete and the
    ///      accused slashed by the silence verdict without ever reaching
    ///      adjudication — unrecoverable. A skipped referral, by contrast, is
    ///      recoverable: `refer` is permissionless and the challenger — who
    ///      wants the slash — is motivated to call it directly if this
    ///      attempt lands in the catch. The window-invariant setters
    ///      (`_requireWindowFits`) bound `autoSlashDelay + voteWindow +
    ///      FINALIZE_BUFFER <= disputeTimeout` against current state on every
    ///      relevant setter call, though not against an already-open
    ///      challenge's pinned clock.
    /// @dev Calling into `court` here widens the trust boundary versus `rule`
    ///      alone: a malicious court could re-enter `game.rule(challengeId,
    ///      ...)` from inside this try block, since `msg.sender == court`
    ///      passes trivially and status is `Disputed` at that point. Not
    ///      exploitable — every storage write happens before this call (CEI
    ///      above), so there is no half-updated state to observe, and forcing
    ///      a verdict through `rule` is a privilege `court` already holds
    ///      unconditionally.
    function dispute(uint256 challengeId, uint256 amountWood) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        // The window this challenge received, not whatever governance
        // currently prefers.
        if (block.timestamp >= c.filedAt + c.autoSlashDelayAtFiling) revert WindowClosed();

        // Open to anyone — see the function natspec. Unchanged: a self-funded
        // round trip (file, then fund your own counter-bond) still costs only
        // `forfeitBurnBps` while coverage stays frozen.
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

        // Best-effort, deliberately unguarded — see the function natspec for
        // why the catch stays broad here (unlike `finalize`'s selector filter)
        // and carries no gas floor.
        if (complete) {
            address courtAddr = court;
            // No court wired means no referral is possible either way — the
            // timeout remains the only path out of `Disputed`.
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
    /// @dev The court supplies only the verdict enum. `Guilty` reuses
    ///      `_settle` verbatim — the same path an undisputed challenge takes,
    ///      so the slash is at sWOOD's `maxSlashBps` with no severity ramp.
    ///      `NotGuilty` reuses `_fail`, the same path the timeout takes: an
    ///      acquittal and an unruled escalation say the same thing about the
    ///      accused. `Inconclusive` reuses `_refundAll`: the vote missed its
    ///      participation floor, so nothing was decided on the merits and both
    ///      sides unwind whole. There is deliberately no severity parameter —
    ///      a court that could dial the slash would be negotiating with the
    ///      accused, not ruling on them.
    /// @dev Ruling beats the timeout: all three branches are terminal and
    ///      `resolve` acts only on `Filed`/`Disputed`, so the clock can never
    ///      overwrite a verdict already handed down — that ordering stops a
    ///      genuinely guilty approver from disputing and running out
    ///      `disputeTimeout`.
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
    ///      covering approvers (proceeds burned), demote the named adapter, and
    ///      return the challenger's bond.
    ///
    ///      Two entries, two pool states, and the status is what separates
    ///      them:
    ///
    ///      — From `Disputed` (a guilty ruling): the pool is exactly
    ///        `bondWood`, since the contribution that completed it is the one
    ///        that flipped the status. The whole pool forfeits to the
    ///        challenger, on top of its returned bond — the escalation costs
    ///        what it is worth, and the challenger that was right is paid by
    ///        the side that was wrong.
    ///
    ///      — From `Filed` (the silence verdict): the pool is strictly below
    ///        `bondWood` — zero, or a part-funded defence that ran out of
    ///        clock. It is refunded to its contributors, who never bought a
    ///        dispute (the escalation only exists once the pool is complete).
    ///        A contributor here is refunded AND still slashed: the slash is
    ///        the verdict, the refund only unwinds a purchase that never
    ///        completed.
    function _settle(uint256 challengeId, Challenge storage c) private {
        IStakedWood swood = stakedWood;
        // Fail closed: without the slasher wired there is no verdict to
        // execute. Not a permanent wedge — `setStakedWood` is the owner
        // escape, and wiring the slasher makes every challenge stuck here
        // resolvable.
        if (address(swood) == address(0)) revert ZeroAddress();

        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        bytes32 key = _reviewKey(governor, proposalId);
        // Rates come from the LEDGER, not one protocol-wide severity: each
        // approver is slashed for what it underwrote. `vault` and `executedAt`
        // are pinned onto the challenge at filing rather than re-read here, so
        // a governor mutating either afterwards cannot move the verdict.
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
        // ASKED OF sWOOD, NOT ONLY OF THE LOCAL FLAG. The
        // local flag catches the concurrent-challenge case this branch was
        // written for; the sWOOD read catches the case it could not — an EARLIER
        // DEPLOYMENT of this game having already collected this cohort under the
        // same, deployment-independent `caseKey`. `file` refuses such a filing at
        // the door, but that gate reads the slasher wired AT FILING TIME and the
        // owner may re-point sWOOD (or the old game may settle a concurrent
        // challenge) at any point afterwards, so the settle path cannot assume it
        // was reachable. Diverting here rather than letting `slashVerdict`
        // revert is the whole point: a revert leaves the challenge in `Filed`
        // with no terminal exit at all, taking the bond, the counter-bond pool
        // and the coverage freeze with it.
        if (_verdictAlreadyCollected(key, approvers)) {
            // A concurrent challenge, or a previous deployment, already
            // collected this proposal's one liability, so the conviction is
            // simply recorded as already-collected rather than re-attempted.
            // The local flag is set so the next `file` is refused by a cheap
            // storage read.
            _convicted[key] = true;
            emit VerdictAlreadyCollected(challengeId, governor, proposalId);
        } else {
            _convicted[key] = true;

            // Enforces the gas floor sWOOD's burn-vs-bubble classifier
            // assumes. Checked as late as possible so everything already
            // spent counts against the caller, not the margin.
            //
            // ADAPTER-NAMING SETTLES ALSO OWE `DEMOTION_GAS`. The slash-only
            // terms above budget for `slashVerdict`; they say nothing about
            // the best-effort `demoteByChallenge` child below, which this
            // settle will attempt whenever `c.adapterTarget != address(0)`.
            // Without the extra term a caller could dial gas to a value that
            // clears the slash but leaves the demotion underfunded — see
            // `DEMOTION_GAS`'s natspec for why that no longer silently drops
            // the demotion. The term is skipped for zero-adapter filings,
            // which demote nothing and owe nothing for it.
            uint256 requiredGas = approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE;
            if (c.adapterTarget != address(0)) {
                requiredGas += DEMOTION_GAS;
            }
            if (gasleft() < requiredGas) {
                revert InsufficientSlashGas();
            }

            // The slash basis is the proposal's EXECUTION
            // instant, pinned at filing — never `filedAt`. `_slashOne` sizes the
            // own-stake leg off `_stakeCheckpoints.upperLookupRecent(openedAt)`,
            // and `requestUnstakeGuardian` pushes a ZERO checkpoint with no
            // cooldown and no transfer. Anchored at `filedAt`, an accused
            // approver zeroed its own basis with one reversible transaction
            // between the drain and the accusation: a 100% conviction took
            // nothing and burned nothing, after which
            // `cancelUnstakeGuardian` put the stake back. `executedAt` predates
            // any state the accused could move in response to being accused,
            // and it is the more correct basis for the delegated leg besides —
            // delegated capital at the drain, not at the accusation.
            // `executedAt - 1 < executedAt` keeps sWOOD's
            // `snapshotTimestamp <= openedAt` bound satisfied.
            // THE SLASH PAYS NOBODY. Every wei taken from the approvers is
            // burned; the prosecutor is paid from the proposer's forfeited
            // bond below instead. The slash used to fund a conviction bounty,
            // gated on whether one of the ACCUSED had funded the counter-bond
            // — a predicate meant to price a staged contest by forcing the
            // stager into the cohort its own conviction slashes. Two things
            // were wrong with it. The accused chose the funding address, so
            // they could zero the prosecutor's fee for free by defending from
            // an unrelated wallet. And the slash is a pot a prosecutor CAN
            // fund for itself, by staking and approving the proposal it is
            // about to accuse, so the predicate needed a cap to stay priced.
            // The proposer's bond has neither problem.
            slashedWood = swood.slashVerdict(key, c.executedAt, approvers, slashBpsPer);

            // The proposer pays too: every slash above falls on the approvers
            // who underwrote the proposal, but the proposer — the actual
            // attacker in the threat model — posted a bond sized to what its
            // proposal could extract. The governor holds it for the whole
            // challenge window; this line is what makes that hold mean
            // something. Confiscating one side without the other is theatre.
            //
            // INSIDE THE `!_convicted` BRANCH, deliberately. A proposal has ONE
            // liability and one bond; a second concurrent challenge reaching a
            // verdict records `VerdictAlreadyCollected` and must not try to
            // confiscate a bond the first one already took.
            //
            // Best-effort, same reasoning as `demoteByChallenge` below: a
            // terminal path must not be hostage to a call that can fail. The
            // bond may legitimately have been reclaimed before filing (a
            // zero-bond proposal, or a re-pointed escrow), and letting a
            // revert here take the whole verdict with it would leave coverage
            // frozen forever and every accused approver barred from
            // `claimUnstakeGuardian` — losing the forfeiture is the smallest
            // of those harms.
            address bondEscrow = c.proposerBondEscrow;
            if (bondEscrow != address(0)) {
                // The prosecutor's fee rides here, pinned at filing like every
                // other rate. It is paid on EVERY conviction, silence or
                // adjudicated, because a correct accusation is equally correct
                // either way — and the silence path is the one where the
                // challenger is otherwise out of pocket, having burned
                // `settleBurnBps` of its bond for a verdict nobody contested.
                try IProposerBondEscrow(bondEscrow)
                    .forfeitBond(governor, proposalId, c.challenger, c.prosecutorFeeBpsAtFiling) returns (
                    address bondProposer, uint256 bondAmount
                ) {
                    emit ProposerBondForfeited(challengeId, governor, proposalId, bondProposer, bondAmount);
                } catch {
                    emit ProposerBondForfeitureFailed(challengeId, governor, proposalId, bondEscrow);
                }
            }

            // Demotes only the adapter the filing named, already checked
            // against the proposal's own execute calls in `file`. Best-effort,
            // deliberately: `demoteByChallenge` is role-gated on the registry's
            // side, so a revocable role pointed elsewhere while this challenge
            // was live must not take the whole verdict down with it — the miss
            // is surfaced as an event and the verdict proceeds; the registry
            // owner's own `demote` fixes it afterward.
            //
            // THE CATCH STAYS BARE, DELIBERATELY (openspec
            // settle-demotion-gas-floor design.md, Decision 2 — selector
            // filtering was considered and rejected). The floor above now
            // refuses, up front, any budget that could starve this call —
            // the caller-selectable failure axis (gas) is closed before the
            // slash even runs. Everything that still reaches this catch is
            // therefore registry-side: on the real `TierRegistry`,
            // `_demote` has no revert path of its own except the role check
            // (F11's revoked `authorizedDemoter`), so there is nothing left
            // for a selector filter to classify — and an out-of-gas child
            // (were one still possible) returns empty revert data no filter
            // can distinguish from a legitimate one anyway. Bubbling a
            // registry-side revert instead of swallowing it would re-open
            // F11's wedge: a challenge that can never settle, bonds
            // stranded, coverage frozen, the accused barred from
            // `claimUnstakeGuardian` — forever, since a role rotation is not
            // something the settle caller can fix by retrying.
            //
            // INSIDE THIS BRANCH, NOT AFTER THE IF/ELSE. Demotion is a
            // consequence of a conviction this settle actually collected. The
            // diverted branch adjudicates nothing — it slashes no one and
            // forfeits no bond — so letting it demote handed out the game's
            // `authorizedDemoter` role for a settle that recovered nothing.
            //
            // That was reachable and cheap. Concurrency is unguarded by
            // design: `_liveByChallenger` is keyed per challenger, `_convicted`
            // is false for every filing made before the first settle, and
            // `_liveCount` is uncapped. An attacker filed N challenges from N
            // addresses naming N different certified adapters touched by one
            // proposal; the first settle collected the liability and the rest
            // diverted here but still demoted, at `settleBurnBps` of a bond
            // that is itself `challengerBondBps` of coverage — roughly 1% of
            // the proposal's coverage per certification revoked.
            if (c.adapterTarget != address(0)) {
                try tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector) {}
                catch {
                    emit AdapterDemotionFailed(challengeId, c.adapterTarget, c.adapterSelector);
                }
            }
        }

        // A correct filing is cheap, not free — but only on the UNADJUDICATED
        // path: a filing nobody answered would otherwise get the slash and
        // adapter demotion for the price of gas, so the burn is what makes the
        // silence verdict cost something. A guilty COURT ruling was tested on
        // the merits and won, so taxing it would price down the filings the
        // mechanism wants. Hence burn on `!escalated`; on `escalated` the
        // challenger takes its bond whole plus the pool the losing side
        // forfeited. Exactly `bond + pool` leaves on both branches, matching
        // the decrement above to the wei.
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
        emit ChallengeSettled(challengeId, slashedWood);
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

    /// @dev Moves a pool from LIVE accounting to UNCLAIMED so its funders can
    ///      collect via `claimContribution`. Two callers, two pool states:
    ///      `_settle`'s undisputed branch reaches this with a part-funded
    ///      pool, `_refundAll`'s inconclusive ruling with a complete one —
    ///      either way the stored amounts are booked as-is. Nothing is
    ///      transferred here; the stored `_contributed` amounts ARE the
    ///      entitlements, and `claimContribution` zeroes them on the way out
    ///      (a pull payment, so one reverting recipient can never brick
    ///      resolution).
    function _bookRefund(uint256 challengeId, uint256 pool) private {
        if (pool != 0) unclaimedWood += pool;
    }

    /// @dev The fail-safe: a disputed challenge escalates to the court. Without
    ///      this path both bonds and the frozen coverage would sit stuck
    ///      forever whenever no court answered, letting anyone pin a
    ///      guardian's budget indefinitely just by filing — so an unruled
    ///      escalation fails in favour of the accused.
    ///
    ///      Also the not-guilty verdict path: this function checks no clock,
    ///      only unwinds the bonds and the freeze, so an acquittal and an
    ///      unruled escalation settle identically — both say the defence was
    ///      right.
    ///
    ///      The forfeit splits pro-rata to CONTRIBUTION, not coverage: paying
    ///      by committed share would let an approver sit out the defence and
    ///      still collect its coverage share of the winnings, which is exactly
    ///      how a collective defence fails to get funded. Keyed to
    ///      contribution, the upside accrues only to whoever bought the
    ///      escalation, in the proportion they bought it.
    ///
    ///      A slice of the forfeit is burned first (`forfeitBurnBps`), and only
    ///      the remainder is split — see that constant for why burning is the
    ///      only sink an approver cannot round-trip through by challenging its
    ///      own proposal and funding the whole counter-bond itself. Taken off
    ///      the top before the pro-rata pass, so it changes only the pot size:
    ///      a non-contributing approver still collects zero.
    ///
    ///      Entry is only ever from `Disputed` — `resolve` sends `Filed` to
    ///      `_settle`, and `rule` demands `Disputed` — so the pool is complete
    ///      and the contributor list non-empty. The empty-list branch below is
    ///      defensive only.
    ///
    ///      That branch deliberately does NOT burn: it is the path where no
    ///      defence was ever bought, so there is no forfeit to take a slice
    ///      of — the bond returns to the challenger intact. `ChallengeFailed`
    ///      reports `(0, 0)` there.
    ///
    ///      Accepted cost, scoped to an unwired game (`court == address(0)`):
    ///      with no adjudicator, a genuinely guilty approver can still dispute
    ///      and run out this clock — strictly better than an indefinite
    ///      freeze, and once a court is wired `rule` beats the timeout and
    ///      closes it.
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
        // Kept so the bond can never be stranded if the reachable states are
        // widened again.
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

        // The forfeit goes to the ones that funded the defence, pro-rata to
        // what each put in — recorded, not paid: storing the total lets each
        // funder compute its own slice in `claimContribution` at O(1), so the
        // contributor list length doesn't matter and no single reverting
        // recipient can brick resolution. The cost is rounding: lazy shares
        // floor-divide independently, so up to `contributors - 1` wei is never
        // claimable, staying in the contract and covered by `unclaimedWood`.
        c.forfeitPayoutWood = payout;
        unclaimedWood += pool + payout;
        emit ChallengeFailed(challengeId, bond, burnAmount);
    }

    /// @dev The `Inconclusive` path — an unwind, not a verdict. The court's
    ///      vote missed its participation floor, so neither side was found
    ///      right or wrong: nothing here is a slash, nothing is a forfeit, and
    ///      the counter-bond pool simply comes back.
    ///
    ///      The challenger's bond is not returned whole: an unpriced or free
    ///      challenge is a free freeze, and this is the one terminal path
    ///      where that rule would otherwise not hold. This contract cannot
    ///      tell an honest challenger whose evidence was real apart from an
    ///      attacker who filed purely to freeze coverage and let turnout do
    ///      the rest — both produce the identical on-chain shape (a completed
    ///      pool, a vote that missed quorum) — so the burn prices the
    ///      ambiguity rather than trying to resolve it, as every other
    ///      terminal path in this contract already does.
    ///
    ///      The rate is deliberately below `settleBurnBps` at every tier — a
    ///      non-verdict recovered nothing, so it must cost strictly less than
    ///      a verdict that recovered real value — enforced by
    ///      `setSettleBurnBps`/`setInconclusiveBurnBps` cross-checking each
    ///      other's live value and by `_inconclusiveBurnBpsForRound`'s own
    ///      clamp for the tiers that setter pair doesn't reach.
    ///
    ///      The burn escalates with the round count rather than staying flat,
    ///      because a flat rate cannot distinguish a one-shot honest filer
    ///      from a grinder (it is invariant to repetition, and the attack this
    ///      burn family exists to price IS repetition). `_refundAll` re-arms
    ///      `challengeableUntil` on every unwind so a stall cannot buy a
    ///      PERMANENT acquittal, which makes the identical free cycle
    ///      otherwise repeatable indefinitely against one proposal —
    ///      escalating the burn re-bounds that repetition without touching
    ///      the window extension itself. See `_inconclusiveBurnBpsForRound`
    ///      for the schedule.
    ///
    ///      The burn comes off the CHALLENGER's bond only, mirroring
    ///      `_settle`'s silence branch — the pool is the accused's own money,
    ///      posted to buy a defence that was never decided on the merits, and
    ///      goes through `_bookRefund` (pull, not push) for the same reason
    ///      `_settle`'s part-funded branch does.
    ///
    ///      No `_convicted` mark and no demotion: nothing was adjudicated, so
    ///      the same proposal is fully re-challengeable the instant this call
    ///      returns.
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

        // Raises the re-challenge floor so a stall cannot buy a permanent
        // acquittal: the accused can stall the pool to the last legal instant
        // inside `autoSlashDelay`, and the verdict would otherwise land past
        // `executedAt + challengeWindow` with no filing gate left standing.
        // `file`'s gate takes the max of this value and the live baseline on
        // every call, so this write only ever needs to avoid raising it
        // needlessly, never guard against shrinking a later read.
        //
        // Skipped when the proposal is already convicted: `file` refuses any
        // further filing against a convicted proposal regardless of this
        // mapping, so an unguarded write would be inert to control flow — but
        // it would still advertise a live re-challenge deadline for a
        // proposal that can never actually be challenged again, a stale
        // signal an indexer would otherwise trust.
        if (!_convicted[rk]) {
            uint256 extended = block.timestamp + challengeWindow;
            if (extended > challengeableUntil[rk]) challengeableUntil[rk] = extended;
            // Every actual `Inconclusive` unwind of a contestable proposal is
            // a repetition, so this increments unconditionally inside the
            // guard above — unlike the re-arm write, which only raises when
            // needed.
            inconclusiveRounds[rk]++;
        }

        _bookRefund(challengeId, pool);

        // Off the challenger's bond only, mirroring `_settle`'s silence
        // branch. `bond - burned` cannot underflow: integer division makes
        // `burned <= bond` for any `inconclusiveBurnBpsAtFiling <=
        // BPS_DENOMINATOR`, kept well below that ceiling by
        // `_inconclusiveBurnBpsForRound`'s clamp.
        uint256 burned = (bond * c.inconclusiveBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burned != 0) {
            wood.safeTransfer(BURN_ADDRESS, burned);
            emit ChallengerBondBurned(challengeId, burned);
        }
        wood.safeTransfer(challenger, bond - burned);
        // Emitted gross, pre-burn: `bond` is the whole pinned bond, not
        // `bond - burned`. `ChallengerBondBurned` above reports the burned
        // slice separately, so the two logs together are exact — a consumer
        // reading only `bondWood` as "what the challenger received" would
        // over-report by `burned`. Kept gross for the same reason
        // `ChallengeFailed` separates `forfeitedWood` and `burnedWood`: what
        // the bond WAS vs. what was destroyed of it are different questions.
        emit ChallengeInconclusive(challengeId, bond, pool);
    }

    /// @dev The escalating schedule. `priorRounds` is how many times this
    ///      proposal has already gone `Inconclusive`, so the round THIS filing
    ///      is attempting is `priorRounds + 1`:
    ///
    ///        priorRounds == 0  ->  attempt 1  ->  0 bps (free)
    ///        priorRounds == 1  ->  attempt 2  ->  `INCONCLUSIVE_BURN_ROUND2_BPS`
    ///        priorRounds == 2  ->  attempt 3  ->  `INCONCLUSIVE_BURN_ROUND3_BPS`
    ///        priorRounds >= 3  ->  attempt 4+ ->  `inconclusiveBurnBps`
    ///
    ///      Always clamped to the live `settleBurnBps`, regardless of tier —
    ///      the round-4+ tier is also guarded at the setter level
    ///      (`setInconclusiveBurnBps`/`setSettleBurnBps` cross-check), but the
    ///      two fixed literals for rounds 2 and 3 are compile-time constants
    ///      the setter pair never touches, so this clamp is what still keeps a
    ///      non-verdict from costing more than a verdict that recovered real
    ///      value if `settleBurnBps` is later lowered. Clamped, not reverted:
    ///      a revert here would make `file` fail whenever governance set
    ///      `settleBurnBps` low, blocking filing entirely.
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

    /// @dev The accused set: the ledger's covering approvers, filtered to
    ///      those whose committed share is still non-zero — a released
    ///      commitment backed nothing on this proposal, so it is neither
    ///      slashed nor paid out of a failed challenge.
    /// @dev Filters rather than passing the ledger's raw output straight
    ///      through: the amounts would be identical either way, but the
    ///      approver array is what names people in the `GuardianSlashed`
    ///      topics and the escrow case, and a guardian that withdrew its
    ///      approval before the drain should not appear in a conviction at
    ///      all.
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

    /// @dev No zero check, unlike every other setter here: the zero address is
    ///      the meaningful "no court" state, not a mis-set one. It is both the
    ///      default and the revocation switch — unwiring a captured court
    ///      returns the game to the fail-safe timeout, which acquits, so the
    ///      worst an unwiring can do is fail to slash.
    /// @dev Guards the re-wire too: pointing at a new non-zero court can break
    ///      the window invariant just as much as raising `autoSlashDelay` or
    ///      `disputeTimeout` can, since a court can be unwired, the clocks
    ///      changed while nothing is wired, then a new court wired in —
    ///      bypassing checks that only apply while a court is live. Checked
    ///      against the NEW court's `voteWindow`/`FINALIZE_BUFFER` by passing
    ///      `newCourt` explicitly rather than reading stale storage.
    function setCourt(address newCourt) external onlyOwner {
        if (newCourt != address(0)) _requireWindowFits(newCourt, autoSlashDelay, disputeTimeout);
        emit CourtSet(court, newCourt);
        court = newCourt;
    }

    /// @dev Re-pointing while challenges are live orphans their freeze: every
    ///      live challenge's `unfreezeCoverage` goes to the NEW ledger, so
    ///      coverage the old one pinned stays frozen forever and the new one
    ///      is unfrozen for challenges it never saw. Re-point only when no
    ///      challenge is live, or drain the live set first.
    /// @dev Re-validates `challengeWindow` against the new ledger's own
    ///      window, not just at `setChallengeWindow` time: re-pointing from a
    ///      ledger with a wider `challengeWindow` to one with a narrower one,
    ///      while this game's own window stays unchanged, could otherwise
    ///      silently let a filing freeze exposure the NEW ledger has already
    ///      aged out of its epoch buckets.
    /// @dev Residual: the ledger's OWN `setChallengeWindow` can shrink its
    ///      window at any time with no reference to any game reading it, since
    ///      the ledger holds no pointer back — this game cannot close that
    ///      door from its side. This guard plus `setChallengeWindow`'s own
    ///      live read close the two doors reachable from this contract; the
    ///      third is a documented gap, not an oversight.
    /// @dev Requires the OTHER half of the grant to already exist:
    ///      `coverageFreezer` is the ledger's side of a two-sided
    ///      relationship, and this setter only ever moves one side of it. A
    ///      fresh ledger's `coverageFreezer` defaults to the zero address, so
    ///      re-pointing at one while a challenge is live would send every
    ///      terminal path into `unfreezeCoverage`'s `NotCoverageFreezer` —
    ///      stranding the bond and pool with no terminal exit, and leaving the
    ///      OLD ledger's freeze permanent since its own `setCoverageFreezer`
    ///      is bricked while any coverage is frozen. Demanding the grant first
    ///      does not remove the orphaning hazard above, but it does keep every
    ///      reachable re-point leaving the terminal paths callable.
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
        // The ledger's window is authoritative, read live rather than
        // restated: it governs the epoch-bucket scan a coverage freeze
        // depends on, so a game window above it would let a filing freeze
        // exposure the ledger has already aged out.
        //
        // Not the whole reachable window, deliberately: `file`'s actual
        // deadline is `max(executedAt + challengeWindow, challengeableUntil[key])`,
        // and an `Inconclusive` unwind can raise `challengeableUntil` well
        // past this bound (`_refundAll`'s "never shorten" guarantee is a
        // separate, already-proven property this bound does not duplicate).
        // A late re-challenge re-derives its own coverage and price live at
        // `file` time, so reaching past this window is not "freezing exposure
        // the ledger has aged out" in the sense this bound exists to prevent.
        if (newWindow > exposureLedger.challengeWindow()) revert InvalidParameter();
        emit ChallengeWindowSet(challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    /// @dev Bounded (0, 10_000]: zero would make filing free, and therefore the
    ///      freeze free.
    function setChallengerBondBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ChallengerBondBpsSet(challengerBondBps, newBps);
        challengerBondBps = newBps;
    }

    /// @dev Bounded [0, `MAX_FORFEIT_BURN_BPS`]. Zero is allowed, unlike
    ///      `setChallengerBondBps` where it would make the freeze free: zero
    ///      here restores the pre-burn behaviour — the whole forfeit paid to
    ///      the funders — a coherent (if exploitable) configuration and the
    ///      off-switch if the burn is ever shown to deter honest defences more
    ///      than it deters self-challenges.
    function setForfeitBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FORFEIT_BURN_BPS) revert InvalidParameter();
        emit ForfeitBurnBpsSet(forfeitBurnBps, newBps);
        forfeitBurnBps = newBps;
    }

    /// @dev Does NOT re-validate `prosecutorFeeBps`, and no longer needs to.
    ///      The fee is paid by `ProposerBondEscrow`, not by the slasher, so
    ///      re-pointing sWOOD cannot strand a pinned rate the new slasher
    ///      would reject. `_settle` also retries the forfeiture without a fee
    ///      if the escrow rejects the pinned rate, so no rate change on either
    ///      side can wedge a conviction.
    /// @dev Also requires the OTHER half of the grant: `authorizedSlasher` is
    ///      sWOOD's side of the same two-sided relationship — pointing this
    ///      game at a sWOOD that has not named it would send every `_settle`
    ///      into `slashVerdict`'s own caller gate, since `Filed`'s only other
    ///      exit (`rule`) demands `Disputed`. The reciprocal pointer is
    ///      already the documented deploy order
    ///      (`swood.setAuthorizedSlasher(game)` then `game.setStakedWood(swood)`),
    ///      so this enforces the sequence the scripts already follow.
    function setStakedWood(address stakedWood_) external onlyOwner {
        if (stakedWood_ == address(0)) revert ZeroAddress();
        if (IStakedWood(stakedWood_).authorizedSlasher() != address(this)) revert RoleNotGranted();
        emit StakedWoodSet(address(stakedWood), stakedWood_);
        stakedWood = IStakedWood(stakedWood_);
    }

    /// @dev Disabled: `Ownable`'s default would leave this contract
    ///      permanently ownerless, and several recovery levers are owner-only
    ///      and irreplaceable — `setStakedWood` un-wedges a challenge stuck on
    ///      an unwired or mis-granted slasher, `setCourt(address(0))` is the
    ///      off-switch for a captured court, and `setExposureLedger` is the
    ///      only way to move the freeze rail. Ownership can still be HANDED
    ///      OVER: `Ownable2Step`'s transfer/accept pair is untouched.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev The invariant spans two contracts, so neither holds it alone. A
    ///      counter-bond pool may complete as late as
    ///      `filedAt + autoSlashDelay`, and from that instant a referral needs
    ///      `voteWindow + FINALIZE_BUFFER` of runway before the challenge dies
    ///      at `filedAt + disputeTimeout`. Violated, the referral window can go
    ///      negative — and the accused chooses when the pool completes, so it
    ///      would defeat adjudication unilaterally by stalling. `c` is a
    ///      parameter rather than always read from `court` so `setCourt` can
    ///      validate the address about to become live, not the stale one
    ///      already in storage. Vacuous with no court wired: there is no
    ///      referral to fit.
    /// @dev Residual: this binds the court's CURRENT `voteWindow`/
    ///      `FINALIZE_BUFFER` against this game's CURRENT `autoSlashDelay`/
    ///      `disputeTimeout`, not against any already-open challenge's PINNED
    ///      values. Two individually-legal owner raises to live state can
    ///      still leave an old challenge's pin no longer fitting the court's
    ///      live clock, causing `refer` to revert `InsufficientClock` for that
    ///      one challenge and resolve it via `_fail` (timeout acquittal)
    ///      regardless of guilt. Owner-only, not adversary-reachable, and
    ///      recoverable — lowering `voteWindow` back restores referability,
    ///      since `refer`'s clock check reads it live. Re-validating every
    ///      open challenge's pin on every setter call would be unbounded work
    ///      this design rejects elsewhere (the pool/contributor loops removed
    ///      for the same reason), so binding setters against current state is
    ///      the achievable half of this invariant.
    function _requireWindowFits(address c, uint256 autoSlash, uint256 timeout) private view {
        if (c == address(0)) return;
        if (autoSlash + ITokenCourt(c).voteWindow() + ITokenCourt(c).FINALIZE_BUFFER() > timeout) {
            revert WindowInvariantViolated();
        }
    }

    /// @dev Bounded [`MIN_AUTO_SLASH_DELAY`, `disputeTimeout`). The floor is
    ///      justified at the constant; the ceiling is the cross-parameter
    ///      invariant — both clocks run from `filedAt`, so a delay at or above
    ///      the dispute timeout would let a contested challenge time out
    ///      before the slash it was raised against ever came due, and the
    ///      accused would have bought its escalation for nothing.
    /// @dev Last check is the cross-contract one (`_requireWindowFits`): the
    ///      two bounds above are this contract's own; the window invariant
    ///      additionally needs the court's `voteWindow`/`FINALIZE_BUFFER`,
    ///      which only exists on `TokenCourt`.
    function setAutoSlashDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_AUTO_SLASH_DELAY || newDelay >= disputeTimeout) revert InvalidParameter();
        _requireWindowFits(court, newDelay, disputeTimeout);
        emit AutoSlashDelaySet(autoSlashDelay, newDelay);
        autoSlashDelay = newDelay;
    }

    /// @dev Bounded (`autoSlashDelay`, `MAX_DISPUTE_TIMEOUT`] — the same
    ///      cross-parameter invariant from the other side, plus a ceiling on
    ///      how long a filing may pin a guardian's coverage.
    /// @dev Last check is the cross-contract one (`_requireWindowFits`) — see
    ///      `setAutoSlashDelay`'s identical note.
    function setDisputeTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout <= autoSlashDelay || newTimeout > MAX_DISPUTE_TIMEOUT) revert InvalidParameter();
        _requireWindowFits(court, autoSlashDelay, newTimeout);
        emit DisputeTimeoutSet(disputeTimeout, newTimeout);
        disputeTimeout = newTimeout;
    }

    /// @dev Bounded [0, `MAX_SETTLE_BURN_BPS`]. Zero is legal and means the
    ///      settle path refunds in full, so governance can retire the burn
    ///      without an upgrade if the off-chain bounty ends up pricing
    ///      filings adequately on its own.
    /// @dev Applies to challenges FILED after the change, not ones settled
    ///      after it: the challenger reads this rate when deciding whether the
    ///      bond is worth posting and cannot withdraw once posted, so leaving
    ///      it live would let a raise take up to half the refund of a filing
    ///      that had already turned out correct.
    /// @dev Also refuses to drop below the live `inconclusiveBurnBps`: sharing
    ///      a ceiling with it bounds both rates' maximums identically but says
    ///      nothing about where either LIVE rate sits, so this cross-check —
    ///      together with `setInconclusiveBurnBps`'s matching check on the
    ///      far side — is what keeps a non-verdict from ever costing more than
    ///      a verdict that recovered real value.
    function setSettleBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SETTLE_BURN_BPS) revert InvalidParameter();
        if (newBps < inconclusiveBurnBps) revert InvalidParameter();
        emit SettleBurnBpsSet(settleBurnBps, newBps);
        settleBurnBps = newBps;
    }

    /// @dev Bounded here by `MAX_PROSECUTOR_FEE_BPS`, a MIRROR of the escrow's
    ///      own constant rather than the binding one: the escrow is
    ///      per-proposal, so there is no single authority to consult at set
    ///      time. The escrow re-enforces its ceiling when it actually pays,
    ///      exactly as sWOOD re-clamps `slashBpsPer` rather than trusting
    ///      `ExposureLedger`. Zero is legal and turns the fee off.
    /// @dev Requires `stakedWood` wired first, unlike every other rate setter
    ///      here, because there is nothing to bound against otherwise. The
    ///      rate is pinned per challenge at filing and outlives any later
    ///      `setStakedWood` — a challenge filed under a since-lowered ceiling
    ///      would carry a pinned rate the new sWOOD rejects forever,
    ///      permanently foreclosing a CONTESTED conviction on that one
    ///      challenge (the silence and dispute-timeout paths are unaffected).
    ///      Failing closed here, at configuration time, is cheap; failing
    ///      closed at resolution time, mid-challenge, is not.
    function setProsecutorFeeBps(uint256 newBps) external onlyOwner {
        // Bounded here only against the absolute scale. The binding ceiling is
        // `ProposerBondEscrow.MAX_PROSECUTOR_FEE_BPS`, enforced by the escrow
        // itself when it pays — the escrow is per-proposal, so there is no
        // single one to consult at this point.
        if (newBps > MAX_PROSECUTOR_FEE_BPS) revert InvalidParameter();
        emit ProsecutorFeeBpsSet(prosecutorFeeBps, newBps);
        prosecutorFeeBps = newBps;
    }

    /// @dev Bounded [0, `MAX_INCONCLUSIVE_BURN_BPS`]. Zero is allowed, exactly
    ///      like `setSettleBurnBps` and `setForfeitBurnBps`: it restores the
    ///      pre-fix behaviour (the whole bond back, untouched) and is the
    ///      off-switch if this burn is ever shown to deter honest filers more
    ///      than it deters the free-freeze it prices.
    /// @dev Also refuses to rise above the live `settleBurnBps`: sharing a
    ///      ceiling with it bounds both rates' maximum legal values
    ///      identically but does not stop this rate being set above an
    ///      unchanged, lower `settleBurnBps` — this cross-check, together with
    ///      `setSettleBurnBps`'s matching check on the far side, is what keeps
    ///      the ordering true.
    /// @dev Applies to challenges FILED after the change, not ones ruled after
    ///      it — same reasoning as `setSettleBurnBps`: the challenger relies
    ///      on this rate the moment it posts the bond, with no way to
    ///      withdraw once a later court vote misses its participation floor.
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
