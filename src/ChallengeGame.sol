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
 * @dev    There is no on-chain predicate verification: an undisputed challenge
 *         auto-slashes after a delay, a disputed one escalates to the court.
 *         The `Predicate` enum is a label carried in the event, nothing more.
 *
 * @dev    Vigilance cost sits with guardians: an approver that stays silent
 *         through the dispute window is slashed on an unproven assertion. What
 *         bounds that is the challenger's bond - sized to the coverage it
 *         freezes, forfeited to the accused when a challenge fails - plus a
 *         dispute window generous relative to the auto-slash delay.
 *
 * @dev    The accused's defence is bought collectively: any party may fund a
 *         shared counter-bond pool, sized to the challenger's bond regardless
 *         of how many identities EITHER side splits across, so a Sybil split
 *         costs exactly what staying whole costs. The pool is keyed per
 *         PROPOSAL, not per challenge - N concurrent filings against one
 *         proposal are answered by ONE pool (see `CounterBondPool`). A failed
 *         challenge's forfeit splits pro-rata to CONTRIBUTION, not coverage, so
 *         an approver that sat out the defence collects none of its upside.
 *
 * @dev    A CONVICTION BURNS THE POOL rather than paying it to the challenger.
 *         Paying it out made the counter-bond a refundable deposit for a guilty
 *         cohort: self-file from a fresh address, fund the proposal's only pool
 *         through that filing, adopt the honest challenge for free, and recover
 *         all but the settle burn of what the defence cost. Burning removes the
 *         thing to claw back, and removes the mirror-image free-ride where a
 *         duplicate filer adopts an honest challenger's pool and races it for
 *         the payout. The challenger's own economics are unchanged: its bond
 *         back net of `settleBurnBps`, plus the prosecutor fee out of the
 *         convicted PROPOSER's bond.
 *
 * @dev    Every payout to the challenger is burned down by a rate first
 *         (`settleBurnBps` on the settle path, `forfeitBurnBps` on the fail
 *         path). An attacker can control both sides of a challenge from two
 *         addresses, so any recipient it can reach is a round trip - only
 *         destruction has no beneficiary to be.
 *
 * @dev    Plain `Ownable2Step`, NOT upgradeable, so its storage layout is
 *         unconstrained. WOOD must be a standard ERC20 - a fee-on-transfer or
 *         rebasing token would make recorded bonds exceed the held balance.
 */
contract ChallengeGame is Ownable2Step, IChallengeGame {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard floor on `autoSlashDelay` - the guardians' entire window to
    ///         notice a filing and fully fund a counter-bond between them.
    /// @dev    Guards against a hostile owner collapsing the window to zero and
    ///         turning silence into an instant slash. 48h survives a weekend, an
    ///         operator outage or a short chain halt.
    uint256 public constant MIN_AUTO_SLASH_DELAY = 2 days;

    /// @dev Ceiling on `disputeTimeout` - bounds how long a filing may pin a
    ///      guardian's coverage. A worst-case adjudication needs at most
    ///      `MAX_VOTE_WINDOW + FINALIZE_BUFFER` (15 days) after referral, so 60
    ///      days stays compatible with `_requireWindowFits`.
    uint256 public constant MAX_DISPUTE_TIMEOUT = 60 days;

    /// @dev Minimum guaranteed runway between the worst-case referral clock
    ///      (`autoSlash + voteWindow + FINALIZE_BUFFER`) and `disputeTimeout`.
    ///      Bare equality guarantees only ONE SECOND of slack when the accused
    ///      stalls pool completion - and therefore the in-transaction
    ///      auto-referral in `dispute` - to the last legal instant. That
    ///      referral is best-effort and the permissionless retry that recovers
    ///      from a miss (`ITokenCourt.refer`) runs in a LATER transaction, at a
    ///      later timestamp, eating straight into the slack.
    /// @dev PUBLIC, not internal: `TokenCourt`'s mirror-image checks and the
    ///      wiring script's pre-flight must hold the SAME margin, or a raise on
    ///      the far side can seat a configuration this contract would refuse.
    uint256 public constant MIN_REFERRAL_SLACK = 1 hours;

    /// @notice Floor on the SETTLE WINDOW `[autoSlashDelay, disputeTimeout)` -
    ///         the time a permissionless `resolve` has to convict an undisputed
    ///         no court wired `_requireWindowFits` is vacuous, so without this
    ///         floor the owner could set `disputeTimeout = autoSlashDelay + 1`
    ///         and make every LATER un-backed filing effectively unconvictable.
    ///         That is a new owner power - before the deadline existed the
    ///         window had no right edge - so it is bounded here, in BOTH
    ///         setters, regardless of court wiring. One day is the same order
    ///         as `FINALIZE_BUFFER`: it survives a chain halt or a keeper
    ///         outage, and a challenger who cannot call `resolve` within a day
    ///         of the silence verdict was not going to. With a court wired the
    ///         referral invariant (`voteWindow + FINALIZE_BUFFER +
    ///         MIN_REFERRAL_SLACK`) already implies a wider window.
    uint256 public constant MIN_SETTLE_WINDOW = 1 days;

    /// @dev THE GAS FLOOR for a permissionless `resolve`, sized per approver
    ///      plus a base because the slash loop runs first and a flat floor would
    ///      let a large batch consume it before the work that needs protecting.
    ///      What it protects is the best-effort `demoteByChallenge` child below:
    ///      under EIP-150 a caller supplying just enough gas to finish the slash
    ///      alone would leave that child 63/64 of a nearly-empty frame, and its
    ///      OOG would be swallowed by the catch while the adapter keeps its
    ///      certification. Everything else after the slash either reverts the
    ///      whole call (unguarded `safeTransfer`s) or is internal bookkeeping,
    ///      so it is safe by rollback.
    ///
    ///      A FLOOR MUST ALSO BE REACHABLE. At a previous 300k/1M the full-cap
    ///      floor was 31,000,000, read two `CALL`s below an EOA on the court
    ///      path, against Robinhood Chain's `maxTxGasLimit` of 32,000,000. Two
    ///      EIP-150 haircuts put it out of reach of any transaction, so a
    ///      conviction against a full cohort could not be mined: the case sits
    ///      in `Voting`, the challenge times out through `_fail`, and the
    ///      accused is ACQUITTED and paid the challenger's forfeited bond. A gas
    ///      floor that converts a guilty verdict into an acquittal is worse than
    ///      the out-of-gas it was written to prevent.
    ///
    ///      THE NUMBERS ARE MEASURED, NOT ESTIMATED
    ///      (`test/SlashGasCeiling.t.sol`): 713,853 gas at 4 approvers,
    ///      5,428,313 at 52, 11,176,224 at 100 - fitting
    ///      `~224*n^2 + 85,659*n + 367,629`, the quadratic term being the O(n^2)
    ///      pairwise dedup scan. 180k/approver keeps ~1.4x over the marginal
    ///      cost of the hundredth approver, headroom for a long-lived guardian
    ///      whose deeper checkpoint trace this fixture does not reproduce. The
    ///      2M base keeps a large multiple over any child call. Full-cap floor
    ///      for a zero-adapter settle is 20,000,000 against a
    ///      `32,000,000 * (63/64)^3 = 30,523,315` ceiling.
    ///      `test_slashGasFloorFitsRobinhoodMaxTxGas` is the CI tripwire.
    ///      Re-derive end to end through court `finalize` before moving these:
    ///      over-reserving only rejects an under-gassed caller, while
    ///      under-reserving silently drops demotions.
    uint256 public constant SLASH_GAS_PER_APPROVER = 180_000;
    uint256 public constant SLASH_GAS_BASE = 2_000_000;

    /// @dev Added to the floor above ONLY when the challenge names a non-zero
    ///      adapter - a zero-adapter filing demotes nothing and owes nothing.
    ///      Closes the axis where a permissionless caller dials gas so the
    ///      conviction lands but `demoteByChallenge`'s child starves under
    ///      EIP-150 forwarding, leaving only `AdapterDemotionFailed` behind.
    ///
    ///      SIZING: `TierRegistry._demote` does a role check, deletes a 2-slot
    ///      entry, may flip one timelock slot, and emits two events - worst case
    ///      ~50k. 200_000 forwards ~197k after 63/64 forwarding even if every
    ///      unit before the call was spent to the floor's budget. Full-cap floor
    ///      for an adapter-naming settle is 20,200,000 against the same
    ///      30,523,315 ceiling - 1.511x headroom, gated in CI by
    ///      `test_slashGasFloorFitsRobinhoodMaxTxGas`.
    uint256 public constant DEMOTION_GAS = 200_000;

    /// @notice Where every burned slice of a challenger's bond goes - both the
    ///         settle path's `settleBurnBps` and the fail path's
    ///         `forfeitBurnBps` send here.
    /// @dev    Not a real burn: WOOD is a plain `IERC20` with no `burn`, and
    ///         `address(0)` is unusable because OpenZeppelin's ERC20 rejects
    ///         transfers to it, which would brick resolution. Total supply keeps
    ///         counting it, but nothing here can ever spend it again.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Ceiling on `forfeitBurnBps`. The burn prices a self-challenge round
    ///      trip out of profitability without punishing an honest defence: an
    ///      approver that correctly beats a bad-faith filing must still come out
    ///      clearly ahead, or the counter-bond pool stops getting funded. Half
    ///      the forfeit also caps how much a captured owner can destroy per
    ///      failed challenge.
    uint256 internal constant MAX_FORFEIT_BURN_BPS = 5_000;

    /// @dev Ceiling on `settleBurnBps`. Burning the whole bond would make a
    ///      correct filing cost as much as a wrong one, removing the only
    ///      on-chain reason to file at all.
    uint256 internal constant MAX_SETTLE_BURN_BPS = 5_000;

    /// @dev Ceiling on `inconclusiveBurnBps`, identical to `MAX_SETTLE_BURN_BPS`
    ///      so a non-verdict can never be configured to cost more than the
    ///      WORST-CASE verdict. The setters do NOT cross-check each other's LIVE
    ///      values: that coupling made the round-4+ tier of the Inconclusive
    ///      ladder collapse onto round 3's fixed rate. See
    ///      `_inconclusiveBurnBpsForRound`.
    uint256 internal constant MAX_INCONCLUSIVE_BURN_BPS = MAX_SETTLE_BURN_BPS;

    /// @dev Round-1 step of the escalating Inconclusive-burn schedule. NO
    ///      ATTEMPT IS EVER FREE: `dispute` is open to anyone, so an attacker
    ///      can file, fund its own counter-bond pool in full, and let turnout
    ///      miss quorum - re-arming `challengeableUntil` and re-pinning the
    ///      ledger for a full `disputeTimeout` plus `challengeWindow` of frozen
    ///      coverage at the cost of gas alone. Sized at half of round 2,
    ///      continuing the doubling shape backwards (250/500/1,000, then
    ///      `inconclusiveBurnBps`). Fixed, not owner-settable - only the ceiling
    ///      is a governance knob. See `_inconclusiveBurnBpsForRound`.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND1_BPS = 250;

    /// @dev Round-2 step. Fixed, not owner-settable: the schedule's shape is a
    ///      one-time design decision; only its round-4+ ceiling
    ///      (`inconclusiveBurnBps`) is a governance knob.
    uint256 internal constant INCONCLUSIVE_BURN_ROUND2_BPS = 500;

    /// @dev Round-3 step. NOT REACHABLE AT THE CURRENT `settleBurnBps` (500):
    ///      rounds 1-3 are clamped to that live value, so this literal realises
    ///      as 500 and round 3 charges the same as round 2 - the accepted cost
    ///      of halving `settleBurnBps` for prosecutor economics. The literal
    ///      stays at 1,000 because it is the schedule's DESIGN shape, which the
    ///      clamp reduces rather than replaces. Escalation past round 2 comes
    ///      from the unclamped round-4+ tier, so the realised curve is
    ///      250/500/500/1,000.
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
    /// @dev    There is no sink and no payee to name: slash proceeds burn inside
    ///         sWOOD and `slashVerdict` takes no recipient. The prosecutor is
    ///         paid out of the convicted PROPOSER's forfeited bond instead, the
    ///         one pot a prosecutor cannot fund for itself.
    IStakedWood public stakedWood;

    /// @notice The adjudicator for disputed challenges - the only address that
    ///         may `rule`.
    /// @dev    The zero address leaves `rule` unreachable, so a disputed
    ///         challenge can only exit through the timeout in `resolve`. That
    ///         makes the court additive and gives governance an off-switch for a
    ///         captured adjudicator.
    /// @dev    A TIMEOUT'S OUTCOME DEPENDS ON `Challenge.courtAtFiling`, NOT ON
    ///         THIS LIVE VALUE. A challenge filed while this was zero unwinds
    ///         through `_refundAll` - a non-verdict, not an acquittal - because
    ///         a `Guilty` ruling was never a possibility its pool's funders
    ///         could have lost to. Wiring or unwiring afterwards changes nothing
    ///         about how that challenge resolves.
    address public court;

    /// @notice The owner's only lever that gates NEW filings: true refuses
    ///         `file` alone. Never checked in `dispute`, `resolve`, `rule`, or
    ///         either claim path.
    /// @dev    Restricted to `file` deliberately: pausing anything mid-flight
    ///         would let a disputed-but-unreferred challenge drift into
    ///         `disputeTimeout`'s `_fail` branch and forfeit the challenger's
    ///         bond by owner inaction. The worst this flag can do is stop new
    ///         challenges from starting - it can never freeze one that exists,
    ///         nor move the terms a live challenge is priced against, which are
    ///         pinned at filing.
    bool public filingsPaused;

    /// @notice How long after execution a proposal remains challengeable —
    ///         matches the ledger's coverage window, since coverage that has
    ///         expired out of the exposure buckets can no longer be
    ///         meaningfully frozen.
    uint256 public challengeWindow = 14 days;

    /// @notice Challenger bond as bps of the USD coverage a filing freezes.
    ///         Load-bearing: with no proof required this is the only cost of a
    ///         frivolous filing, and a failed challenge forfeits it.
    /// @dev 150 (1.5%). The filer's loss on a CORRECT uncontested filing is
    ///      `challengerBondBps * settleBurnBps`, so a smaller bond buys the
    ///      headroom to keep `settleBurnBps` meaningful. See
    ///      `honestFilingBreaksEven`.
    uint256 public challengerBondBps = 150;

    /// @notice The slice of a FAILED challenge's forfeited bond that is
    ///         destroyed rather than paid to the guardians that funded the
    ///         defence, in bps of the bond. Default 20%.
    /// @dev    Prices self-challenging. An approver could file against its own
    ///         executed proposal, fund the entire counter-bond pool itself, sit
    ///         out `disputeTimeout`, and collect its contribution back plus 100%
    ///         of the forfeit - net cost zero, while every co-approver's
    ///         coverage sat frozen. A `msg.sender != challenger` check is
    ///         theatre (two addresses defeat it), so the slice is burned
    ///         instead.
    /// @dev    Taken off the top before the pro-rata split, so it changes only
    ///         the pot size, not who is entitled to it.
    /// @dev    This rate prices the FAIL path's round trip only. The escalated
    ///         (guilty-ruling) branch has its own, priced with
    ///         `settleBurnBpsAtFiling` - see `_settle` - reusing the silence
    ///         branch's rate rather than adding a second knob for one problem.
    uint256 public forfeitBurnBps = 2_000;

    /// @notice Silence window: an uncontested challenge auto-slashes once this
    ///         much time has passed since filing. See `MIN_AUTO_SLASH_DELAY`
    ///         for why its floor is load-bearing.
    uint256 public autoSlashDelay = 7 days;

    /// @notice How long a DISPUTED challenge waits for a ruling before failing
    ///         to the accused. Measured from `filedAt`, like the auto-slash
    ///         delay, and always strictly greater than it - a timeout at or
    ///         below the slash clock would let a contested challenge fail before
    ///         the slash it was raised against was ever due.
    uint256 public disputeTimeout = 30 days;

    /// @notice Share of a SUCCESSFUL challenger's payout burned on settle, in
    ///         bps. Read the live value off the initialiser below rather than
    ///         trusting any figure quoted in prose - it has drifted twice.
    /// @dev    Prices a filing in both directions: refunding in full would make
    ///         the slash and the adapter demotion come for the price of gas. It
    ///         is a cost, not a transfer to the accused - paying convicted
    ///         approvers out of a correct filing would invert the incentive.
    /// @dev    Applied to the CHALLENGER'S BOND on both of `_settle`'s branches.
    ///         It used to take its slice off the forfeited counter-bond pool on
    ///         the escalated branch instead - an identical amount, since a
    ///         complete pool equals the bond - but the pool is no longer a
    ///         challenger payout at all: a conviction burns it whole. See
    ///         `_settle`.
    /// @dev    Sized against the honest filer's net payoff,
    ///         `proposerBondBps * prosecutorFeeBps - challengerBondBps *
    ///         settleBurnBps` (see `honestFilingNetPayoffBps`). The reward side
    ///         cannot be raised - `prosecutorFeeBps` is already AT
    ///         `MAX_PROSECUTOR_FEE_BPS`, which `ProposerBondEscrow` enforces
    ///         independently - so this cost term is the only lever left.
    ///         Lowering it does not subsidise fabricated filings: it burns a
    ///         slice of a WINNING challenger's bond, and a false accuser instead
    ///         forfeits the WHOLE bond on a different path.
    /// @dev    ACCEPTED COST: rounds 1-3 of `_inconclusiveBurnBpsForRound` are
    ///         clamped to this value, so at 500 the 250/500/1,000 ladder
    ///         realises as 250/500/500 and round 3 stops escalating. The
    ///         escalation is deferred, not lost - round 4+ reads the unclamped
    ///         `inconclusiveBurnBps`. Below 500 rung 2 collapses as well.
    uint256 public settleBurnBps = 500;

    /// @notice Ceiling on `prosecutorFeeBps`, mirroring
    ///         `ProposerBondEscrow.MAX_PROSECUTOR_FEE_BPS`.
    /// @dev    A CONVENIENCE GUARD, NOT THE AUTHORITY. The escrow enforces its
    ///         own bound on every forfeiture and is the contract that moves the
    ///         WOOD. The escrow is chosen per proposal, so there is no single
    ///         one to consult at set time.
    uint256 public constant MAX_PROSECUTOR_FEE_BPS = 2_000;

    /// @notice Slice of the convicted PROPOSER's forfeited bond paid to the
    ///         challenger that caused the conviction, in bps.
    /// @dev    NOT a slice of the slash, and that separation is the point. A
    ///         reward funded from the slash is a pot the prosecutor can fill for
    ///         itself, by staking, approving the proposal it is about to accuse,
    ///         and collecting a fee sized by its own punishment. The proposer's
    ///         bond cannot be self-funded: a self-dealing filer pays the bond in
    ///         full and recovers at most `MAX_PROSECUTOR_FEE_BPS` of it.
    ///         Sybil-proof by construction rather than by parameter.
    /// @dev    PAID ON EVERY CONVICTION, silence path included - the path this
    ///         reward exists for, where the filer is otherwise out of pocket. On
    ///         the escalated path the challenger already takes bond plus the
    ///         forfeited pool; the fee is additive there.
    /// @dev    Pinned per challenge at filing, so a governance change cannot
    ///         re-rate a challenge in flight. If the escrow rejects a pinned
    ///         rate, `_settle` retries at zero rather than losing the conviction.
    uint256 public prosecutorFeeBps = 2_000;

    /// @notice The round-4-and-beyond steady-state share of the challenger's
    ///         bond burned on an `Inconclusive` unwind, in bps - see
    ///         `_inconclusiveBurnBpsForRound` for the full schedule (rounds 1-3
    ///         are fixed, lower steps) and `inconclusiveRounds` for what a round
    ///         counts.
    /// @dev    Prices repeated stalling. An attacker can freeze a cohort's
    ///         coverage by filing, funding its own counter-bond, and letting
    ///         turnout miss quorum - `Inconclusive` re-arms the re-challenge
    ///         window, so the cycle repeats indefinitely. A flat rate is
    ///         invariant to repetition and so cannot separate an honest one-shot
    ///         filer from a grinder; the rate escalates with the round count
    ///         instead.
    /// @dev    Rounds 1-3 are held at or below `settleBurnBps` BY THE CLAMP in
    ///         `_inconclusiveBurnBpsForRound`, not by their own literals: a
    ///         non-verdict must never cost an honest, few-attempt filer more
    ///         than a verdict that recovered real value. Round 4+ is
    ///         DELIBERATELY NOT bound to the live `settleBurnBps` - that
    ///         coupling made the ladder's top tier collapse onto round 3, since
    ///         raising it required raising `settleBurnBps` first, which breaks
    ///         `honestFilingBreaksEven`. It is bounded only by
    ///         `MAX_INCONCLUSIVE_BURN_BPS`, on the reasoning that round 4+ is
    ///         reached only after three prior unwinds against the same proposal.
    uint256 public inconclusiveBurnBps = 1_000;

    /// @notice WOOD held on behalf of live (`Filed`/`Disputed`) challenges - the
    ///         sum of their challenger bonds and counter-bond pools.
    /// @dev    Invariant: `wood.balanceOf(this) >= bondedWood`. A partial pool
    ///         counts here exactly like a complete one - every terminal path
    ///         refunds, forfeits or splits it, so the decrement is always
    ///         `bond + pool`, the burned slice included.
    uint256 public bondedWood;

    /// @inheritdoc IChallengeGame
    /// @dev WOOD owed to counter-bond funders of TERMINAL challenges, not yet
    ///      collected. Kept separate from `bondedWood`, which means held for a
    ///      LIVE challenge - the invariant that no live challenge implies
    ///      `bondedWood == 0` depends on the two staying apart. Widens the
    ///      custody invariant to `balanceOf(this) >= bondedWood + unclaimedWood`.
    ///      Never returns to zero exactly on a failed challenge: lazy pro-rata
    ///      shares floor-divide independently, so wei-scale dust stays accounted
    ///      here forever - hence `>=` rather than `==`.
    uint256 public unclaimedWood;

    uint256 public challengeCount;

    /// @inheritdoc IChallengeGame
    /// @dev Never read as a stored absolute - `file` always maxes this value
    ///      against the live `executedAt + strategyDuration + challengeWindow`
    ///      baseline. `challengeWindow` is mutable state, so comparing only at
    ///      write time would let a shortened-then-restored window leave this
    ///      mapping below what a fresh proposal would compute, with no setter to
    ///      fix it. It only ever needs to raise the floor.
    mapping(bytes32 reviewKey => uint256) public challengeableUntil;

    /// @inheritdoc IChallengeGame
    /// @dev How many times this proposal has gone `Inconclusive`. Incremented in
    ///      `_refundAll` alongside the `challengeableUntil` re-arm - a round only
    ///      counts if the proposal is still contestable. `file` reads it to pin
    ///      the escalated rate and resets it once the re-armed window lapses
    ///      with nobody refiling.
    /// @dev Keyed on the proposal alone, not `(reviewKey, challenger)`: a
    ///      per-challenger counter would be reset by switching identity.
    mapping(bytes32 reviewKey => uint256) public inconclusiveRounds;

    mapping(uint256 challengeId => Challenge) internal _challenges;

    /// @notice How a counter-bond pool ended. `Open` is the only live state;
    ///         both terminal outcomes CLOSE the pool to further contributions,
    ///         which is what makes a resolution single-shot.
    // `PoolOutcome` lives on `IChallengeGame` so views returning it can be
    // declared there; inherited here, so every `PoolOutcome.X` below is
    // unchanged.

    /// @notice ONE COUNTER-BOND POOL PER PROPOSAL PER ROUND, not one per
    ///
    /// @dev    THE BUG THIS REPLACES. `_liveByChallenger` gives every ADDRESS
    ///         its own filing slot and `_liveCount` is uncapped, so N addresses
    ///         open N concurrent challenges against one proposal. With the pool
    ///         keyed per challenge, `dispute`'s target was `c.bondWood` N times
    ///         over: the accused cohort had to raise N counter-bonds in LIQUID
    ///         WOOD inside `autoSlashDelay`, while `file`'s `freezeCoverage`
    ///         barred every named approver from `claimUnstakeGuardian` and so
    ///         from paying out of stake. Any ONE filing they could not answer
    ///         auto-slashed the whole cohort at the severity ceiling through
    ///         `_settle`'s silence branch. The audit's numbers: 67 filings
    ///         demanded 502,500 USD of fresh liquid WOOD against 500,000 USD of
    ///         frozen stake, for ~25,000 USD of attacker cost.
    ///
    /// @dev    THE FIX IS THE SAME PRINCIPLE THE CONTRACT ALREADY APPLIES TO THE
    ///         DEFENDERS' OWN SYBIL SPLIT: the pool is sized to ONE bond
    ///         regardless of how many identities the OTHER side splits across.
    ///         Funding it once buys the escalation for every live challenge on
    ///         the key at once - see `_poolBacked`.
    ///
    /// @param target The bond the pool must match. Raised to the LARGEST live
    ///        bond while the pool is still incomplete, then frozen: a raise
    ///        after completion would un-complete a pool the accused already paid
    ///        for and strip every sibling of the dispute it bought. Concurrent
    ///        filings can carry different bonds, since `file`'s two oracle
    ///        fallbacks price differently from the live feed.
    /// @param weight Total ever contributed. It IS the live pool while `Open`,
    ///        and stays afterwards as the pro-rata denominator a failed
    ///        challenge's forfeit is split by. Not a second `amount` field: an
    ///        `Open` pool holds exactly `weight`, and a closed one holds nothing.
    /// @param completedAt When `weight` first reached `target`; zero means never.
    ///        Recorded rather than folded into a status flag because whether a
    ///        given challenge is DISPUTED asks whether the pool completed inside
    ///        THAT challenge's own silence window - see `_poolBacked`.
    /// @param outcome Burned by a conviction, released by the last live
    ///        challenge terminating without one.
    struct CounterBondPool {
        uint256 target;
        uint256 weight;
        uint256 completedAt;
        PoolOutcome outcome;
    }

    /// @dev Keyed by `(reviewKey, round)`, never by challenge - see
    ///      `_currentPoolKey`.
    mapping(bytes32 poolKey => CounterBondPool) internal _pools;

    /// @dev Who has paid into a pool, in first-payment order and without
    ///      duplicates - a repeat contributor tops up its existing entry.
    mapping(bytes32 poolKey => address[]) internal _contributors;

    /// @dev Per-contributor totals. NEVER CLEARED, unlike the pre-fix
    ///      per-challenge mapping that a claim zeroed: one pool can owe several
    ///      payouts (its own stake back, plus a share of the forfeited bond of
    ///      every challenge on the key that failed), so the weight has to
    ///      survive the first claim. What is single-shot is the two claim flags
    ///      below, not the record.
    mapping(bytes32 poolKey => mapping(address contributor => uint256)) internal _contributed;

    /// @dev The round's raised total immediately after this contributor's latest payment.
    mapping(bytes32 poolKey => mapping(address contributor => uint256)) internal _contributedMark;

    /// @dev Has this contributor already taken its STAKE back out of a
    ///      `Released` pool? One flag per pool, not per challenge, because the
    ///      stake comes back exactly once however many challenges shared it.
    mapping(bytes32 poolKey => mapping(address contributor => bool)) internal _stakeClaimed;

    /// @dev Has this contributor already taken its share of THIS challenge's
    ///      forfeited bond? Per challenge, because each failed challenge on a
    ///      shared pool forfeits its own bond into the same split.
    mapping(uint256 challengeId => mapping(address contributor => bool)) internal _forfeitClaimed;

    /// @dev Which pool round a proposal is on. Bumped when a pool resolves, so
    ///      the next round after an `Inconclusive` unwind starts empty instead
    ///      of inheriting a completed pool - which would hand a fresh filing an
    ///      instant, unfunded `Disputed`.
    mapping(bytes32 reviewKey => uint256) internal _poolRound;

    /// @dev The pool a challenge was filed into, pinned at filing. Read rather
    ///      than re-derived because the round may have advanced (or the pool
    ///      burned out from under a still-live sibling) by the time this
    ///      challenge terminates.
    mapping(uint256 challengeId => bytes32 poolKey) internal _poolOf;

    /// @dev The most recent challenge against a proposal. Only meaningful while
    ///      that challenge is still live — `_liveChallengeId` re-checks status
    ///      rather than trusting the pointer, so a terminal challenge never
    ///      blocks a later, legitimate one. Kept for indexers; the blocking
    ///      question is now asked per challenger via `_liveByChallenger`.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

    /// @dev One slot per CHALLENGER, not per proposal: keying by proposal alone
    ///      would let an accused cohort buy free immunity by self-filing and
    ///      self-disputing to occupy the only slot until the challenge window
    ///      shuts, since `disputeTimeout` (30d) outlives `challengeWindow` (14d).
    ///      Per-challenger, an honest filer always has its own slot.
    mapping(bytes32 challengerKey => uint256 challengeId) internal _liveByChallenger;

    /// @dev How many challenges against a proposal are live. The coverage
    ///      freeze is REFCOUNTED on this rather than toggled per challenge —
    ///      concurrent filings must not let the first one to terminate unfreeze
    ///      coverage the others are still pinning.
    mapping(bytes32 reviewKey => uint256 liveCount) internal _liveCount;

    /// @dev Whether a proposal's approvers have already been convicted by an
    ///      earlier settled challenge. The approvers underwrote one proposal and
    ///      owe ONE liability, which sWOOD enforces independently via
    ///      `_verdictSlashed` on the same review key. Without this flag a second
    ///      concurrent settle would hit that guard, revert
    ///      `ApproverAlreadySlashed`, and wedge an otherwise-correct challenge in
    ///      `Filed` with no terminal path.
    ///
    ///      Only half the dedup: sWOOD's key is stable across redeployments of
    ///      this game while this mapping is per-deployment storage that starts
    ///      empty. `_verdictAlreadyCollected` asks sWOOD's own `verdictSlashed`
    ///      view at both ends, so this flag is a cheap local cache of a
    ///      cross-deployment fact, not the fact itself.
    mapping(bytes32 reviewKey => bool) internal _convicted;

    /// @dev Bounds the constructed `challengeWindow` against the wired ledger's
    ///      own window, as `setChallengeWindow` and `setExposureLedger` do at
    ///      runtime - a game window above the ledger's would let a filing freeze
    ///      exposure the ledger has already aged out of its epoch buckets. Does
    ///      not check the ledger's `coverageFreezer` grant: this address does not
    ///      exist yet, so the deploy scripts cover that step.
    constructor(address initialOwner, address wood_, address exposureLedger_, address tierRegistry_)
        Ownable(initialOwner)
    {
        if (wood_ == address(0) || exposureLedger_ == address(0) || tierRegistry_ == address(0)) revert ZeroAddress();
        if (challengeWindow > IExposureLedger(exposureLedger_).challengeWindow()) revert InvalidParameter();
        wood = IERC20(wood_);
        exposureLedger = IExposureLedger(exposureLedger_);
        tierRegistry = ITierRegistryDemoterMinimal(tierRegistry_);
    }

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
    /// @dev The predicate is recorded and emitted but never read - branching on
    ///      it reintroduces the two-security-models problem this design avoids.
    /// @dev CEI: the challenge is recorded before the freeze and before the bond
    ///      transfer, so neither external call can observe a half-written one.
    /// @dev The challenger names the adapter it accuses; the chain does not
    ///      derive it. Derivation would mean a second calldata parser beside the
    ///      vault's own, and a multi-call proposal has no single derivable
    ///      culprit anyway. Which adapter misbehaved is part of the assertion,
    ///      filed under the same bond as the rest of it.
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
        // the slash path. Read once here and pinned onto the challenge, so
        // `_settle` cannot be moved by a governor mutating the record.
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);
        uint256 executedAt = p.executedAt;
        if (executedAt == 0) revert NotExecuted();

        bytes32 key = _reviewKey(governor, proposalId);
        uint256 deadline = executedAt + p.strategyDuration + challengeWindow;
        uint256 extended = challengeableUntil[key];
        if (extended > deadline) deadline = extended;
        if (block.timestamp > deadline) revert WindowClosed();

        // The Inconclusive-round streak resets once `challengeableUntil[key]`
        // lapses naturally, checked against that value rather than the combined
        // `deadline`: reaching this branch means the repetition the schedule
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
        // settled challenge has collected it, every later filing must be refused
        // at the door: it could still freeze coverage for another
        // `autoSlashDelay` while collecting nothing. A FAILED challenge is
        // different - it collected nothing, so a fresh filing is legitimate.
        if (_convicted[key]) revert AlreadyConvicted();
        // One live challenge per CHALLENGER — see `_liveByChallenger`.
        // Concurrency is safe because the freeze is refcounted below and the
        // conviction is deduped by `_convicted`.
        bytes32 challengerKey = _challengerKey(key, msg.sender);
        if (_liveChallengeId(_liveByChallenger[challengerKey]) != 0) revert AlreadyChallenged();

        (address[] memory covering, uint256[] memory lockedWood) = exposureLedger.pledgedOf(governor, proposalId);
        uint256 lockedTotal;
        uint256 accusedCount;
        for (uint256 i = 0; i < lockedWood.length; i++) {
            lockedTotal += lockedWood[i];
            if (lockedWood[i] != 0) accusedCount++;
        }
        if (lockedTotal == 0) revert NothingToFreeze();

        // Same refusal as `_convicted` above, but asked of sWOOD directly, whose
        // `verdictSlashed` key survives a redeploy of this game. Without it, a
        // replacement game would accept filings against a cohort the OLD game
        // already convicted, freeze coverage and take the bond, then be unable to
        // terminate: `_settle` would revert `ApproverAlreadySlashed` and `rule`
        // is unreachable from `Filed`.
        address[] memory accused = new address[](accusedCount);
        for (uint256 i = 0; i < lockedWood.length; i++) {
            if (lockedWood[i] == 0) continue;
            accused[--accusedCount] = covering[i];
        }
        if (_verdictAlreadyCollected(key, accused)) revert AlreadyConvicted();

        uint256 coverageUsd;
        try exposureLedger.unsharedLiabilityUsd(governor, proposalId) returns (uint256 liability) {
            coverageUsd = liability;
        } catch {
            revert WoodPriceUnset();
        }

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
            // against. Bounded by `MAX_PROSECUTOR_FEE_BPS` at set time and again
            // by the paying escrow, which is the authority.
            prosecutorFeeBpsAtFiling: prosecutorFeeBps,
            // Written only by `_fail`, which is the sole path that gives the
            // pool's funders anything beyond their stake back.
            forfeitPayoutWood: 0,
            inconclusiveBurnBpsAtFiling: _inconclusiveBurnBpsForRound(inconclusiveRounds[key] + _liveCount[key]),
            // The escrow holding this proposal's proposer bond, off the same
            // `getProposal` read. Bound at propose time and never re-pointed, so
            // a verdict up to `disputeTimeout` later confiscates from the escrow
            // the bond was locked in.
            proposerBondEscrow: p.proposerBondEscrow,
            // Pinned like every other `*AtFiling` term. `rule` is unreachable
            // whenever `court` is unwired, so a Disputed challenge with no
            // adjudicator AVAILABLE AT FILING can only exit through a timeout -
            // collapsing the pool funder's risk to zero and turning every dispute
            // into a guaranteed forfeit funded by the challenger. `resolve` reads
            // this pin, not the live `court`.
            courtAtFiling: court,
            defenceWeight: 0,
            defendedAt: 0
        });
        _lastChallenge[key] = challengeId;
        _liveByChallenger[challengerKey] = challengeId;
        bondedWood += bondWood;

        bytes32 poolKey = _currentPoolKey(key);
        _poolOf[challengeId] = poolKey;
        CounterBondPool storage pool = _pools[poolKey];
        if (pool.completedAt == 0 && bondWood > pool.target) pool.target = bondWood;

        // Refcounted for the UNFREEZE only: the last live challenge to terminate
        // releases it. The ledger hears about EVERY filing, because `liveUntil`
        // (this challenge's worst-case end) can outlive the first freeze's
        _liveCount[key]++;
        exposureLedger.freezeCoverage(governor, proposalId, block.timestamp + disputeTimeout);

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

    /// @dev The proposal's CURRENT pool. The round is part of the key rather
    ///      than the pool being cleared in place, because a resolved pool's
    ///      `_contributed` weights must survive as the denominator for claims
    ///      that have not been collected yet - possibly long after a later round
    ///      has opened. Domain-separated from `_challengerKey`, which hashes a
    ///      2-tuple over the same review key.
    function _currentPoolKey(bytes32 key) private view returns (bytes32) {
        return keccak256(abi.encode("counterBondPool", key, _poolRound[key]));
    }

    function _poolBacked(Challenge storage c, CounterBondPool storage p) private view returns (bool) {
        if (c.defendedAt != 0) return true;
        uint256 completedAt = p.completedAt;
        return completedAt != 0 && completedAt >= c.filedAt && completedAt < c.filedAt + c.autoSlashDelayAtFiling;
    }

    // ── Dispute ──

    /// @inheritdoc IChallengeGame
    /// @dev The pool's target matches the LARGEST live challenger bond on the
    ///      proposal and does not move once the pool completes - the accused
    ///      side buys the escalation at exactly the price ONE challenger paid
    ///      for its accusation, however many accusations are open. Pinning the
    ///      total and letting only the payer vary is what makes identity-
    ///      splitting cost exactly what staying whole costs - on BOTH sides,
    /// @dev The overshoot is clamped, not refunded, so the contract never holds a
    ///      wei it must later hand back.
    /// @dev Completion is recorded on the POOL, and which challenges it disputes
    ///      is derived from it (`_poolBacked`), because one contribution can
    ///      dispute an unbounded number of live challenges and writing a status
    ///      to each would be an unbounded loop. `_settle`'s two entries are told
    ///      apart by that same derivation rather than by a stored enum.
    /// @dev The contribution window closes exactly where the auto-slash opens,
    ///      read from the pinned `autoSlashDelayAtFiling` so the owner cannot
    ///      retroactively close a window the accused were still inside.
    /// @dev Open to anyone, not only the accused: a cohort short of funds could
    ///      otherwise never be topped up. Skin in the game is enforced
    ///      economically - a guilty ruling forfeits the whole pool - so an
    ///      outside funder risks real capital.
    /// @dev THAT RISK IS REAL ONLY WHEN AN ADJUDICATOR WAS PINNED AT FILING
    ///      (`Challenge.courtAtFiling != address(0)`). A `Guilty` ruling is the
    ///      only way the pool loses everything, and `rule` is unreachable for a
    ///      challenge with no court PINNED, whether or not one is LIVE - a court
    ///      wired in after a zero-pin filing must not retroactively expose a pool
    ///      that funded itself believing no ruling was possible. Without that
    ///      pin, funding the pool would be a risk-free return funded entirely by
    ///      the challenger's forfeited bond, so no rational party would file.
    /// @dev CEI: every storage write lands before the `transferFrom`.
    /// @dev Best-effort auto-referral, run LAST. The catch stays broad and
    ///      carries no gas floor deliberately: `dispute` is how the accused buy
    ///      their defence, and a revert here would leave the counter-bond
    ///      incomplete and the accused slashed by the silence verdict without
    ///      ever reaching adjudication - unrecoverable. A skipped referral is
    ///      recoverable, since `refer` is permissionless and the challenger wants
    ///      the slash.
    /// @dev Calling into `court` here widens the trust boundary versus `rule`
    ///      alone: a malicious court could re-enter `rule` from inside this try
    ///      block. Not exploitable - every storage write happens first, and
    ///      forcing a verdict through `rule` is a privilege `court` already holds
    ///      unconditionally.
    function dispute(uint256 challengeId, uint256 amountWood) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        bytes32 poolKey = _poolOf[challengeId];
        CounterBondPool storage p = _pools[poolKey];
        // A pool that a terminal outcome already burned or released is CLOSED,
        // whatever the challenge it is reached through still says. Reopening it
        // is what would let a conviction be answered after the fact - see
        // `_burnPool`.
        if (p.outcome != PoolOutcome.Open) revert WrongStatus();
        // A completed pool answers only what it was raised against; a challenge
        // it does not answer buys its OWN defence at the same target.
        bool own = p.completedAt != 0;
        if (own && _poolBacked(c, p)) revert WrongStatus();
        // The window this challenge received, not whatever governance
        // currently prefers.
        if (block.timestamp >= c.filedAt + c.autoSlashDelayAtFiling) revert WindowClosed();

        // Open to anyone - see the function natspec.
        uint256 target = p.target;
        // An incomplete defence guarantees `raised < target`, so the shortfall is
        // never zero and a clamped contribution is never zero either.
        uint256 raised = own ? c.defenceWeight : p.weight;
        uint256 shortfall = target - raised;
        uint256 amount = amountWood < shortfall ? amountWood : shortfall;
        if (amount == 0) revert NothingToContribute();

        raised += amount;
        uint256 pool = p.weight + amount;
        p.weight = pool;
        bool complete = raised == target;
        if (own) {
            c.defenceWeight = raised;
            if (complete) c.defendedAt = block.timestamp;
        } else if (complete) {
            // Recorded, not fanned out: every live challenge on this key whose
            // own silence window still contains this instant becomes disputed by
            // derivation. See `_poolBacked` for why that is not a loop.
            p.completedAt = block.timestamp;
        }
        _bookContribution(challengeId, c.courtAtFiling, poolKey, amount, pool, complete);
    }

    /// @dev The tail every counter-bond payment shares: the contributor record,
    ///      custody, and - on the payment that completes a defence - the dispute
    ///      event and the best-effort referral. Kept as one code path so burn,
    ///      release and forfeit accounting cannot diverge between the two.
    function _bookContribution(
        uint256 challengeId,
        address courtAtFiling,
        bytes32 poolKey,
        uint256 amount,
        uint256 pool,
        bool complete
    ) private {
        // First payment appends; a top-up finds its existing entry. Keeping the
        // list duplicate-free makes the failure-path split a single pass.
        if (_contributed[poolKey][msg.sender] == 0) _contributors[poolKey].push(msg.sender);
        _contributed[poolKey][msg.sender] += amount;
        _contributedMark[poolKey][msg.sender] = pool;
        bondedWood += amount;

        wood.safeTransferFrom(msg.sender, address(this), amount);
        emit CounterBondContributed(challengeId, msg.sender, amount, pool);
        if (!complete) return;
        emit ChallengeDisputed(challengeId, pool);

        // Best-effort, deliberately unguarded - see `dispute`'s natspec.
        if (courtAtFiling != address(0) && court != address(0)) {
            try ITokenCourt(courtAtFiling).refer(challengeId) {}
            catch {
                emit AutoReferFailed(challengeId);
            }
        }
    }

    // ── Resolution ──

    /// @inheritdoc IChallengeGame
    /// @dev Permissionless on purpose. Neither terminal path lets the caller
    ///      choose anything - the outcome is fixed by state and the clock - so
    ///      opening it removes the last place a privileged party could sit on a
    ///      verdict.
    /// @dev THE DISPUTED-TIMEOUT BRANCH IS TWO-WAY. With no adjudicator ever
    ///      pinned at filing, `rule` was never reachable, so running out the
    ///      clock says nothing about the accused: it routes to `_refundAll`, a
    ///      non-verdict, exactly like a court's own `Inconclusive`. With a court
    ///      pinned it routes to `_fail`, which also re-arms the re-challenge
    ///      window - a court WAS pinned, yet nothing adjudicated the merits. Only
    ///      `rule`'s genuine `NotGuilty` entry does not re-arm.
    function resolve(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        // `Filed` is the only stored live status now - `Disputed` is derived
        // from the shared pool, so a terminal challenge still falls straight
        // through to `WrongStatus`.
        if (c.status != Status.Filed) revert WrongStatus();
        bytes32 poolKey = _poolOf[challengeId];
        if (!_poolBacked(c, _pools[poolKey])) {
            if (block.timestamp < c.filedAt + c.autoSlashDelayAtFiling) revert DelayNotElapsed();
            if (block.timestamp >= c.filedAt + c.disputeTimeoutAtFiling) {
                // Stale: past the hard end. Unwind, never convict.
                _refundAll(challengeId, c, poolKey);
            } else {
                _settle(challengeId, c, poolKey);
            }
        } else {
            if (block.timestamp < c.filedAt + c.disputeTimeoutAtFiling) revert DelayNotElapsed();
            if (c.courtAtFiling == address(0)) {
                // No adjudicator was ever guaranteed reachable - see
                // `Challenge.courtAtFiling`.
                _refundAll(challengeId, c, poolKey);
            } else {
                // A court WAS pinned but never ruled - a non-verdict, not an
                // acquittal. `true` tells `_fail` to re-arm the re-challenge
                // window, unlike `rule`'s `NotGuilty` entry.
                _fail(challengeId, c, poolKey, true);
            }
        }
    }

    /// @inheritdoc IChallengeGame
    /// @dev The court supplies only the verdict enum. `Guilty` reuses `_settle`
    ///      verbatim, so the slash is at sWOOD's `maxSlashBps` with no severity
    ///      ramp. `NotGuilty` reuses `_fail`'s PAYOUT but NOT its re-challenge
    ///      re-arm: here an adjudicator genuinely looked at the merits and
    ///      cleared the accused. `Inconclusive` reuses `_refundAll`. There is
    ///      deliberately no severity parameter - a court that could dial the
    ///      slash would be negotiating with the accused, not ruling on them.
    /// @dev Ruling beats the timeout: all three branches are terminal and
    ///      `resolve` acts only on `Filed`/`Disputed`, so the clock can never
    ///      overwrite a verdict already handed down.
    function rule(uint256 challengeId, Verdict verdict) external {
        if (msg.sender != court) revert NotCourt();
        Challenge storage c = _challenges[challengeId];
        bytes32 poolKey = _poolOf[challengeId];
        if (c.status != Status.Filed || !_poolBacked(c, _pools[poolKey])) revert WrongStatus();
        if (c.courtAtFiling == address(0)) revert NotCourt();
        // Hard deadline - see the natspec. Checked AFTER the status/court gates
        // so a terminal challenge still reports `WrongStatus` to the court.
        if (block.timestamp >= c.filedAt + c.disputeTimeoutAtFiling) revert WindowClosed();
        emit ChallengeRuled(challengeId, verdict);
        if (verdict == Verdict.Guilty) {
            _settle(challengeId, c, poolKey);
        } else if (verdict == Verdict.NotGuilty) {
            // A genuine ruling on the merits - no re-arm. See `_fail`.
            _fail(challengeId, c, poolKey, false);
        } else {
            _refundAll(challengeId, c, poolKey);
        }
    }

    function _settle(uint256 challengeId, Challenge storage c, bytes32 poolKey) private {
        IStakedWood swood = stakedWood;
        // Fail closed: without the slasher wired there is no verdict to execute.
        // Not a permanent wedge - `setStakedWood` is the owner escape.
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
        c.status = Status.Settled;
        // The pool's own WOOD leaves `bondedWood` inside `_burnPool`, once, on
        // whichever challenge resolves it first - never here, or a second
        // challenge sharing the pool would decrement it twice.
        bondedWood -= bond;
        // Pinned for the record: what this challenge's pool had raised. A
        // shared, still-live pool cannot be read off a terminal challenge's
        // storage any other way.
        c.counterBondWood = _pools[poolKey].weight;

        _releaseFreeze(key, governor, proposalId);

        uint256 slashedWood;
        if (_verdictAlreadyCollected(key, approvers)) {
            // Already collected, so the conviction is recorded rather than
            // re-attempted. The local flag makes the next `file` a cheap read.
            _convicted[key] = true;
            emit VerdictAlreadyCollected(challengeId, governor, proposalId);
        } else {
            _convicted[key] = true;

            uint256 requiredGas = approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE;
            if (c.adapterTarget != address(0)) {
                requiredGas += DEMOTION_GAS;
            }
            if (gasleft() < requiredGas) {
                revert InsufficientSlashGas();
            }

            slashedWood = swood.slashVerdict(key, c.executedAt, approvers, slashBpsPer);

            address bondEscrow = c.proposerBondEscrow;
            if (bondEscrow != address(0)) {
                // The prosecutor's fee rides here, pinned at filing. Paid on
                // EVERY conviction, silence included - that is the path where the
                // challenger is otherwise out of pocket.
                try IProposerBondEscrow(bondEscrow)
                    .forfeitBond(governor, proposalId, c.challenger, c.prosecutorFeeBpsAtFiling) returns (
                    address bondProposer, uint256 bondAmount
                ) {
                    emit ProposerBondForfeited(challengeId, governor, proposalId, bondProposer, bondAmount);
                } catch {
                    try IProposerBondEscrow(bondEscrow).forfeitBond(governor, proposalId, c.challenger, 0) returns (
                        address bondProposer, uint256 bondAmount
                    ) {
                        emit ProposerBondForfeited(challengeId, governor, proposalId, bondProposer, bondAmount);
                    } catch {
                        emit ProposerBondForfeitureFailed(challengeId, governor, proposalId, bondEscrow);
                    }
                }
            }

            if (c.adapterTarget != address(0)) {
                try tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector) {}
                catch {
                    emit AdapterDemotionFailed(challengeId, c.adapterTarget, c.adapterSelector);
                }
            }
        }

        // A correct filing is cheap, not free. The burn is a slice of the
        // CHALLENGER'S OWN BOND on both entries now - the pool is no longer a
        // payout that could be burned down instead, it is closed below (burned
        // when it completed, returned to its funders when it did not). A
        // `msg.sender != challenger` check would be theatre anyway (two
        // addresses defeat it), so the cost is charged by rate, not by identity.
        uint256 burned = (bond * c.settleBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burned != 0) {
            wood.safeTransfer(BURN_ADDRESS, burned);
            emit ChallengerBondBurned(challengeId, burned);
        }
        wood.safeTransfer(c.challenger, bond - burned);
        if (_poolBacked(c, _pools[poolKey])) {
            _burnPool(key, poolKey, challengeId);
        } else {
            _releasePoolIfLast(key, poolKey, challengeId);
        }
        emit ChallengeSettled(challengeId, slashedWood);
    }

    function _burnPool(bytes32 rk, bytes32 poolKey, uint256 challengeId) private {
        CounterBondPool storage p = _pools[poolKey];
        if (p.outcome != PoolOutcome.Open) return;
        p.outcome = PoolOutcome.Burned;
        _poolRound[rk]++;
        uint256 amount = p.weight;
        if (amount != 0) {
            bondedWood -= amount;
            wood.safeTransfer(BURN_ADDRESS, amount);
        }
        emit CounterBondPoolBurned(challengeId, amount);
    }

    function _releasePoolIfLast(bytes32 rk, bytes32 poolKey, uint256 challengeId) private {
        if (_liveCount[rk] != 0) return;
        _releasePool(rk, poolKey, challengeId);
    }

    function _releasePool(bytes32 rk, bytes32 poolKey, uint256 challengeId) private {
        CounterBondPool storage p = _pools[poolKey];
        if (p.outcome != PoolOutcome.Open) return;
        p.outcome = PoolOutcome.Released;
        _poolRound[rk]++;
        uint256 amount = p.weight;
        if (amount != 0) {
            bondedWood -= amount;
            unclaimedWood += amount;
        }
        emit CounterBondPoolReleased(challengeId, amount);
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

    function _rearmChallengeWindow(bytes32 rk, address governor, uint256 proposalId) private {
        if (_convicted[rk]) return;
        uint256 extended = block.timestamp + challengeWindow;
        if (extended > challengeableUntil[rk]) challengeableUntil[rk] = extended;
        exposureLedger.pinCoverageUntil(governor, proposalId, challengeableUntil[rk]);
    }

    function _fail(uint256 challengeId, Challenge storage c, bytes32 poolKey, bool unadjudicatedTimeout) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;

        uint256 bond = c.bondWood;
        uint256 pool = _pools[poolKey].weight;
        address challenger = c.challenger;
        c.status = Status.Failed;
        // Only this challenge's own bond. The shared pool leaves `bondedWood`
        // exactly once, in `_releasePoolIfLast` below or in a sibling's
        // `_burnPool` - never per failing challenge.
        bondedWood -= bond;
        c.counterBondWood = pool;

        bytes32 rk = _reviewKey(governor, proposalId);
        _releaseFreeze(rk, governor, proposalId);

        // See this function's natspec for why the timeout entry re-arms and the
        // ruling entry does not.
        if (unadjudicatedTimeout) {
            _rearmChallengeWindow(rk, governor, proposalId);
        }

        // Defensive: unreachable, since a challenge only fails once the pool
        // completed. Kept so the bond can never be stranded if the reachable
        // states are widened again.
        if (pool == 0) {
            _releasePoolIfLast(rk, poolKey, challengeId);
            wood.safeTransfer(challenger, bond);
            emit ChallengeFailed(challengeId, 0, 0);
            return;
        }

        // The burn is taken off the top and the REMAINDER is what the funders
        // split. Integer division makes `burnAmount <= bond`, so `payout` cannot
        // underflow, and a zero rate reproduces the pre-burn behaviour.
        uint256 burnAmount = (bond * c.forfeitBurnBpsAtFiling) / BPS_DENOMINATOR;
        uint256 payout = bond - burnAmount;

        c.forfeitPayoutWood = payout;
        unclaimedWood += payout;
        _releasePoolIfLast(rk, poolKey, challengeId);

        // Skipped when the parameter is zero: a zero-value transfer would only
        // emit a misleading `Transfer` to the dead address.
        if (burnAmount != 0) wood.safeTransfer(BURN_ADDRESS, burnAmount);
        emit ChallengeFailed(challengeId, bond, burnAmount);
    }

    function _refundAll(uint256 challengeId, Challenge storage c, bytes32 poolKey) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        uint256 bond = c.bondWood;
        uint256 pool = _pools[poolKey].weight;
        address challenger = c.challenger;

        c.status = Status.Inconclusive;
        // This challenge's bond only - the shared pool is accounted once, in
        // `_releasePoolIfLast` below.
        bondedWood -= bond;
        c.counterBondWood = pool;
        bytes32 rk = _reviewKey(governor, proposalId);
        _releaseFreeze(rk, governor, proposalId);

        if (!_convicted[rk]) {
            _rearmChallengeWindow(rk, governor, proposalId);
            inconclusiveRounds[rk]++;
        }

        _releasePoolIfLast(rk, poolKey, challengeId);

        // Off the challenger's bond only, mirroring `_settle`'s silence branch.
        // `bond - burned` cannot underflow: integer division keeps
        // `burned <= bond` for any rate at or below `BPS_DENOMINATOR`.
        uint256 burned = (bond * c.inconclusiveBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burned != 0) {
            wood.safeTransfer(BURN_ADDRESS, burned);
            emit ChallengerBondBurned(challengeId, burned);
        }
        wood.safeTransfer(challenger, bond - burned);
        // Emitted gross, pre-burn: `ChallengerBondBurned` above reports the
        // burned slice separately, so the two logs together are exact. What the
        // bond WAS and what was destroyed of it are different questions.
        emit ChallengeInconclusive(challengeId, bond, pool);
    }

    function _inconclusiveBurnBpsForRound(uint256 priorRounds) private view returns (uint256 bps) {
        if (priorRounds == 0) {
            bps = INCONCLUSIVE_BURN_ROUND1_BPS;
        } else if (priorRounds == 1) {
            bps = INCONCLUSIVE_BURN_ROUND2_BPS;
        } else if (priorRounds == 2) {
            bps = INCONCLUSIVE_BURN_ROUND3_BPS;
        } else {
            // Round 4+: bounded by `MAX_INCONCLUSIVE_BURN_BPS` via its setter,
            // deliberately NOT reclamped to `settleBurnBps` here.
            return inconclusiveBurnBps;
        }
        uint256 ceiling = settleBurnBps;
        if (bps > ceiling) bps = ceiling;
    }

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
    /// @dev TWO FIELDS ARE SYNTHESISED, because the counter-bond pool is shared
    ///      across every challenge on a proposal and cannot live in any one
    ///      challenge's storage:
    ///
    ///      - `counterBondWood` reports the pool's raised total while the
    ///        challenge is live, and the value pinned at termination afterwards.
    ///      - `status` reports `Disputed` for a live challenge whose pool
    ///        completed inside its own silence window (`_poolBacked`). Nothing
    ///        ever STORES `Disputed`: one contribution disputes every live
    ///        challenge on the key at once, and writing a status to each would be
    ///        inflate. `TokenCourt.refer` reads this view, so it sees the same
    ///        answer `rule` and `resolve` derive internally.
    function challengeOf(uint256 challengeId) external view returns (Challenge memory) {
        Challenge memory m = _challenges[challengeId];
        if (m.status == Status.Filed) {
            Challenge storage c = _challenges[challengeId];
            CounterBondPool storage p = _pools[_poolOf[challengeId]];
            m.counterBondWood = p.weight;
            if (_poolBacked(c, p)) m.status = Status.Disputed;
        }
        return m;
    }

    /// @inheritdoc IChallengeGame
    function counterBondContributors(uint256 challengeId) external view returns (address[] memory) {
        return _contributors[_poolOf[challengeId]];
    }

    /// @inheritdoc IChallengeGame
    function counterBondContributionOf(uint256 challengeId, address contributor) external view returns (uint256) {
        return _contributed[_poolOf[challengeId]][contributor];
    }

    /// @inheritdoc IChallengeGame
    function counterBondPoolOf(uint256 challengeId)
        external
        view
        returns (uint256 poolWood, uint256 targetWood, uint256 raisedWood, uint256 completedAt, bool burned)
    {
        CounterBondPool storage p = _pools[_poolOf[challengeId]];
        raisedWood = p.weight;
        return (
            p.outcome == PoolOutcome.Open ? raisedWood : 0,
            p.target,
            raisedWood,
            p.completedAt,
            p.outcome == PoolOutcome.Burned
        );
    }

    /// @inheritdoc IChallengeGame
    /// @dev THE FULL OUTCOME, because `counterBondPoolOf`'s `bool burned` cannot
    ///      express it. That flag is `outcome == Burned`, which collapses `Open`
    ///      and `Released` into the same `false` — and those two differ in the
    ///      one way an invariant cares about: an `Open` pool HOLDS what it
    ///      raised, a `Released` one has handed it to `unclaimedWood`.
    ///
    ///      Without this, a property asserting "a live challenge's pool still
    ///      holds what it raised" has to be weakened to `<=` to avoid firing on
    ///      terminal-pool-with-live-sibling, which is a normal state on both the
    ///      burn and the release paths — and a `<=` there asserts almost
    ///      nothing. Exposed as a separate view rather than widening
    ///      `counterBondPoolOf`'s tuple, which would break every existing
    ///      destructuring of it for no gain.
    function poolOutcomeOf(uint256 challengeId) external view returns (PoolOutcome) {
        return _pools[_poolOf[challengeId]].outcome;
    }

    /// @inheritdoc IChallengeGame
    /// @dev TWO INDEPENDENT ENTITLEMENTS, each single-shot on its own flag:
    ///
    ///      - THE STAKE, owed once per POOL and only once it was `Released` -
    ///        which happens when the last live challenge on the proposal
    ///        terminates without a conviction. A conviction burns the pool
    ///        instead, and burned is not claimable.
    ///      - THE FORFEIT SHARE, owed once per FAILED CHALLENGE, pro-rata to
    ///        contribution. Several challenges can fail into one pool, so this
    ///        is asked of the challenge named here while the denominator is the
    ///        pool's total.
    ///
    ///      Reported as zero while the named challenge is live, so this view and
    ///      `claimContribution`'s `ChallengeNotTerminal` gate never disagree.
    function claimableContribution(uint256 challengeId, address contributor) public view returns (uint256 owed) {
        Challenge storage c = _challenges[challengeId];
        Status status = c.status;
        if (status != Status.Failed && status != Status.Settled && status != Status.Inconclusive) {
            return 0; // still live — nothing is owed until the outcome is fixed
        }

        bytes32 poolKey = _poolOf[challengeId];
        uint256 contributed = _contributed[poolKey][contributor];
        if (contributed == 0) return 0;

        CounterBondPool storage p = _pools[poolKey];
        if (p.outcome == PoolOutcome.Released && !_stakeClaimed[poolKey][contributor]) owed = contributed;
        if (status == Status.Failed && !_forfeitClaimed[challengeId][contributor]) {
            uint256 payout = c.forfeitPayoutWood;
            uint256 weight = c.counterBondWood;
            if (payout != 0 && weight != 0 && _contributedMark[poolKey][contributor] <= weight) {
                owed += (payout * contributed) / weight;
            }
        }
    }

    /// @inheritdoc IChallengeGame
    function claimContribution(uint256 challengeId) external returns (uint256 amount) {
        Challenge storage c = _challenges[challengeId];
        Status status = c.status;
        if (status != Status.Failed && status != Status.Settled && status != Status.Inconclusive) {
            revert ChallengeNotTerminal();
        }

        bytes32 poolKey = _poolOf[challengeId];
        uint256 contributed = _contributed[poolKey][msg.sender];
        if (contributed == 0) revert NothingToClaim();
        CounterBondPool storage p = _pools[poolKey];

        // CEI, and the flags are what make each leg single-shot. `_contributed`
        // itself is NOT cleared, unlike the pre-fix per-challenge version: it is
        // the pro-rata weight for every other challenge on this pool that may
        // still fail, so a claim here must not erase a later claim's basis.
        if (p.outcome == PoolOutcome.Released && !_stakeClaimed[poolKey][msg.sender]) {
            _stakeClaimed[poolKey][msg.sender] = true;
            amount = contributed;
        }
        if (status == Status.Failed && !_forfeitClaimed[challengeId][msg.sender]) {
            uint256 payout = c.forfeitPayoutWood;
            uint256 weight = c.counterBondWood;
            if (payout != 0 && weight != 0 && _contributedMark[poolKey][msg.sender] <= weight) {
                _forfeitClaimed[challengeId][msg.sender] = true;
                amount += (payout * contributed) / weight;
            }
        }
        if (amount == 0) revert NothingToClaim();

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

    /// @inheritdoc IChallengeGame
    /// @dev VIEW ONLY - reports the inequality, it does not enforce it.
    ///      `challengerBondBps * settleBurnBps <= proposerBondBps *
    ///      prosecutorFeeBps` is the break-even condition for a CORRECT,
    ///      UNCONTESTED filing: the challenger's net payoff on that path is the
    ///      difference of those two products, scaled by coverage and the WOOD
    ///      price, both of which cancel out of the SIGN. A `false` result means
    ///      silence is the accused's dominant strategy against the CURRENT
    ///      configuration. Recompute the margin from the four live values rather
    ///      than trusting any worked example in prose - one has gone stale twice.
    ///
    ///      This contract deliberately does NOT gate any setter on the result.
    ///      The values that would make it `true` trade off against
    ///      `challengerBondBps`'s anti-spam role, `settleBurnBps`'s own pricing
    ///      purpose, and `proposerBondBps`'s cost to legitimate proposers - and
    ///      `proposerBondBps` is not even a knob this contract owns. It is read
    ///      LIVE from the wired `exposureLedger`, so this always reports against
    ///      current policy on both sides, not any one challenge's filing-time pin.
    /// @dev THE BOOLEAN ALONE HIDES MAGNITUDE. The comparison is monotone in the
    ///      correct direction, but collapsing it to `true`/`false` erases WHERE
    ///      on that line the configuration sits - in particular
    ///      `settleBurnBps == 0` zeroes the cost side and this always returns
    ///      `true`, a materially different state from a large positive margin at
    ///      a non-trivial burn rate. `honestFilingNetPayoffBps` reports the
    ///      SIGNED difference instead; this is kept for backward compatibility.
    function honestFilingBreaksEven() external view returns (bool) {
        return challengerBondBps * settleBurnBps <= exposureLedger.proposerBondBps() * prosecutorFeeBps;
    }

    /// @inheritdoc IChallengeGame
    /// @dev EXACT FOR BOTH CONVICTION BRANCHES SINCE FINDING #10. It used to be
    ///      a lower bound, because the escalated branch paid `bond + pool -
    ///      burned` and the forfeited counter-bond was pure upside this figure
    ///      left out. The pool is now BURNED on a conviction rather than paid to
    ///      anyone (see `_settle`), so silence and a `Guilty` ruling return the
    ///      challenger the identical `bond - burned` plus the same prosecutor
    ///      fee, and this figure prices both.
    function honestFilingNetPayoffBps() external view returns (int256) {
        // Same two products `honestFilingBreaksEven` compares, returned as a
        // difference rather than reduced to a sign. Every bps rate here is
        // bounded by `BPS_DENOMINATOR`, so neither product can approach
        // `int256`'s range and the casts below can never wrap.
        uint256 rewardBps = exposureLedger.proposerBondBps() * prosecutorFeeBps;
        uint256 costBps = challengerBondBps * settleBurnBps;
        return int256(rewardBps) - int256(costBps);
    }

    // ── Owner setters ──

    /// @dev No zero check, unlike every other setter here: the zero address is
    ///      the meaningful no-court state, both the default and the revocation
    ///      switch. Unwiring a captured court returns the game to the fail-safe
    ///      timeout, which acquits, so the worst it can do is fail to slash.
    /// @dev Guards the re-wire too: a court can be unwired, the clocks changed
    ///      while nothing is wired, then a new court wired in - bypassing checks
    ///      that only apply while a court is live. Checked against the NEW
    ///      court's clocks by passing `newCourt` explicitly.
    function setCourt(address newCourt) external onlyOwner {
        if (newCourt != address(0)) _requireWindowFits(newCourt, autoSlashDelay, disputeTimeout);
        emit CourtSet(court, newCourt);
        court = newCourt;
    }

    /// @dev Re-pointing while challenges are live orphans their freeze: every
    ///      live challenge's `unfreezeCoverage` goes to the NEW ledger, so
    ///      coverage the old one pinned stays frozen forever. Re-point only when
    ///      no challenge is live.
    /// @dev Re-validates `challengeWindow` against the new ledger's own window:
    ///      re-pointing from a wider ledger window to a narrower one could
    ///      otherwise let a filing freeze exposure the NEW ledger has aged out.
    ///      Residual: the ledger's own setter can shrink its window at any time
    ///      with no reference to any game reading it, and this contract cannot
    ///      close that door from its side.
    /// @dev Requires the OTHER half of the grant to already exist. A fresh
    ///      ledger's `coverageFreezer` defaults to zero, so re-pointing at one
    ///      mid-challenge would send every terminal path into
    ///      `NotCoverageFreezer` - stranding the bond and pool, and leaving the
    ///      OLD ledger's freeze permanent.
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
    ///      `setChallengerBondBps` where it would make the freeze free: zero here
    ///      restores the pre-burn behaviour and is the off-switch if the burn
    ///      ever deters honest defences more than self-challenges.
    function setForfeitBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_FORFEIT_BURN_BPS) revert InvalidParameter();
        emit ForfeitBurnBpsSet(forfeitBurnBps, newBps);
        forfeitBurnBps = newBps;
    }

    /// @dev Does NOT re-validate `prosecutorFeeBps`: the fee is paid by
    ///      `ProposerBondEscrow`, not the slasher, so re-pointing sWOOD cannot
    ///      strand a pinned rate, and `_settle` retries at zero anyway.
    /// @dev Requires the OTHER half of the grant: pointing this game at a sWOOD
    ///      that has not named it would send every `_settle` into
    ///      `slashVerdict`'s caller gate, since `Filed`'s only other exit
    ///      (`rule`) demands `Disputed`. This enforces the deploy order the
    ///      scripts already follow.
    function setStakedWood(address stakedWood_) external onlyOwner {
        if (stakedWood_ == address(0)) revert ZeroAddress();
        if (IStakedWood(stakedWood_).authorizedSlasher() != address(this)) revert RoleNotGranted();
        emit StakedWoodSet(address(stakedWood), stakedWood_);
        stakedWood = IStakedWood(stakedWood_);
    }

    /// @dev Disabled: several recovery levers are owner-only and irreplaceable -
    ///      `setStakedWood` un-wedges a challenge stuck on an unwired slasher,
    ///      `setCourt(address(0))` is the off-switch for a captured court, and
    ///      `setExposureLedger` is the only way to move the freeze rail.
    ///      Ownership can still be HANDED OVER via `Ownable2Step`.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _requireWindowFits(address c, uint256 autoSlash, uint256 timeout) private view {
        if (c == address(0)) return;
        if (autoSlash + ITokenCourt(c).voteWindow() + ITokenCourt(c).FINALIZE_BUFFER() + MIN_REFERRAL_SLACK > timeout) {
            revert WindowInvariantViolated();
        }
    }

    /// @dev Bounded [`MIN_AUTO_SLASH_DELAY`, `disputeTimeout - MIN_SETTLE_WINDOW`].
    ///      Both clocks run from `filedAt`, so a delay at or above the dispute
    ///      timeout would let a contested challenge time out before the slash it
    ///      was raised against came due, and the accused would have bought its
    ///      escalation for nothing; and since the timeout is now also the hard
    ///      end of slashability, the settle window between the two keeps
    ///      `MIN_SETTLE_WINDOW` whether or not a court is wired. The last check
    ///      is the cross-contract one, which additionally needs the court's own
    ///      clocks.
    function setAutoSlashDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_AUTO_SLASH_DELAY || newDelay + MIN_SETTLE_WINDOW > disputeTimeout) {
            revert InvalidParameter();
        }
        _requireWindowFits(court, newDelay, disputeTimeout);
        emit AutoSlashDelaySet(autoSlashDelay, newDelay);
        autoSlashDelay = newDelay;
    }

    /// @dev Bounded [`autoSlashDelay + MIN_SETTLE_WINDOW`, `MAX_DISPUTE_TIMEOUT`]
    ///      - the same cross-parameter invariant from the other side, plus a
    ///      ceiling on how long a filing may pin a guardian's coverage. Last
    ///      check is the cross-contract one, as in `setAutoSlashDelay`.
    function setDisputeTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < autoSlashDelay + MIN_SETTLE_WINDOW || newTimeout > MAX_DISPUTE_TIMEOUT) {
            revert InvalidParameter();
        }
        _requireWindowFits(court, autoSlashDelay, newTimeout);
        emit DisputeTimeoutSet(disputeTimeout, newTimeout);
        disputeTimeout = newTimeout;
    }

    /// @dev Bounded [0, `MAX_SETTLE_BURN_BPS`]. Zero is legal and means the
    ///      settle path refunds in full.
    /// @dev Applies to challenges FILED after the change, not ones settled after
    ///      it: the challenger reads this rate when deciding whether the bond is
    ///      worth posting and cannot withdraw once posted.
    /// @dev Deliberately does NOT cross-check `inconclusiveBurnBps`. That
    ///      coupling pinned `inconclusiveBurnBps <= settleBurnBps` at all times,
    ///      making the ladder's round-4+ tier unreachable above round 3's fixed
    ///      rate. See `_inconclusiveBurnBpsForRound`.
    function setSettleBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SETTLE_BURN_BPS) revert InvalidParameter();
        emit SettleBurnBpsSet(settleBurnBps, newBps);
        settleBurnBps = newBps;
    }

    /// @dev Bounded here by `MAX_PROSECUTOR_FEE_BPS`, a MIRROR of the escrow's
    ///      own constant rather than the binding one: the escrow is per-proposal,
    ///      so there is no single authority to consult at set time. It
    ///      re-enforces its ceiling when it pays. Zero turns the fee off.
    /// @dev The rate is pinned per challenge at filing and outlives any later
    ///      `setStakedWood`, so a challenge filed under a since-lowered ceiling
    ///      would carry a rate the escrow rejects - which `_settle`'s zero-fee
    ///      retry is what recovers from.
    function setProsecutorFeeBps(uint256 newBps) external onlyOwner {
        // The binding ceiling is the escrow's own, enforced when it pays.
        if (newBps > MAX_PROSECUTOR_FEE_BPS) revert InvalidParameter();
        emit ProsecutorFeeBpsSet(prosecutorFeeBps, newBps);
        prosecutorFeeBps = newBps;
    }

    /// @dev Bounded [0, `MAX_INCONCLUSIVE_BURN_BPS`]. Zero restores the pre-fix
    ///      behaviour and is the off-switch if this burn ever deters honest
    ///      filers more than the free-freeze it prices.
    /// @dev Deliberately does NOT refuse rising above the live `settleBurnBps`.
    ///      Paired with the matching check on the far side, that pinned
    ///      `inconclusiveBurnBps <= settleBurnBps` at all times and made the
    ///      round-4+ tier indistinguishable from round 3. See
    ///      `_inconclusiveBurnBpsForRound`.
    /// @dev Applies to challenges FILED after the change - same reasoning as
    ///      `setSettleBurnBps`.
    function setInconclusiveBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_INCONCLUSIVE_BURN_BPS) revert InvalidParameter();
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
