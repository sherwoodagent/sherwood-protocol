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

    /// @dev Ceiling on `disputeTimeout`. Beyond this the coverage a filing
    ///      freezes is pinned for longer than any plausible court proceeding,
    ///      which is the griefing side of D5's fail-safe.
    uint256 internal constant MAX_DISPUTE_TIMEOUT = 180 days;

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
    ///         game can never redirect the proceeds of a slash it triggers.
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

    /// @notice The ONLY human backstop in the whole adjudication stack (spec
    ///         §4): true gates `file` alone. Never checked in `dispute`,
    ///         `resolve`, `rule`, or either claim path, so no in-flight
    ///         challenge's rights ever depend on the owner.
    /// @dev    THE ADVERSARY IS THE OWNER ITSELF (spec §4). Pausing referrals —
    ///         i.e. anything that could freeze `dispute`/`resolve`/`rule` mid-
    ///         flight — was rejected for exactly this reason: a disputed-but-
    ///         not-yet-referred challenge would drift into `disputeTimeout`'s
    ///         `_fail` branch and forfeit the challenger's bond by owner
    ///         inaction, not by anything the challenger did. Restricting the
    ///         lever to `file` means the worst a hostile or compromised owner
    ///         can do is stop NEW challenges from starting; it can never reach
    ///         into one that already exists.
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
    mapping(bytes32 reviewKey => bool) internal _convicted;

    constructor(address initialOwner, address wood_, address exposureLedger_, address tierRegistry_)
        Ownable(initialOwner)
    {
        if (wood_ == address(0) || exposureLedger_ == address(0) || tierRegistry_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        exposureLedger = IExposureLedger(exposureLedger_);
        tierRegistry = ITierRegistryDemoterMinimal(tierRegistry_);
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
        if (block.timestamp > executedAt + challengeWindow) revert WindowClosed();

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

        bytes32 key = _reviewKey(governor, proposalId);
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
        // reaches settle and is refunded all but `settleBurnBps` — 0.1% of
        // coverage USD net, from as many funded addresses as it likes, since
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
        (, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 coverageUsd;
        for (uint256 i = 0; i < committedUsd.length; i++) {
            coverageUsd += committedUsd[i];
        }
        if (coverageUsd == 0) revert NothingToFreeze();

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
            // Written only by `_fail`, which is the sole path that gives the
            // pool's funders anything beyond their stake back.
            forfeitPayoutWood: 0
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
        if (_convicted[key]) {
            // A concurrent challenge already collected this proposal's one
            // liability. Settling again would revert inside sWOOD's per-verdict
            // dedup and strand this challenge with no terminal path, so the
            // conviction is simply recorded as already-collected.
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
            (slashedWood, caseId) =
                swood.slashToEscrow(key, c.executedAt, approvers, slashBpsPer, c.vault, c.executedAt - 1);
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
    ///      nothing is a forfeit, both bonds simply come back.
    ///
    ///      THE CHALLENGER'S BOND RETURNS WHOLE, with no `settleBurnBps` slice.
    ///      That burn exists to price a filing nobody answered (🟠F4) — the
    ///      cost of a silence verdict. This challenger WAS answered; the
    ///      dispute pool completed and escalated to the court. Burning an
    ///      unwound bond here would charge the challenger for the
    ///      electorate's apathy — a quorum failure it did not cause and could
    ///      not have prevented — which is a bill nothing in §4 asks it to pay.
    ///
    ///      THE POOL GOES THROUGH `_bookRefund`, NOT A DIRECT TRANSFER, for the
    ///      same reason `_settle`'s part-funded branch does: `dispute` keeps
    ///      open standing precisely because the payout is pull, not push (see
    ///      `claimContribution`), and this path reaches the same unbounded
    ///      contributor list `_settle`'s partial pool does. Pushing here would
    ///      reintroduce the single-reverting-recipient hazard pull-payments
    ///      exist to remove.
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
        _releaseFreeze(_reviewKey(governor, proposalId), governor, proposalId);

        _bookRefund(challengeId, pool);
        wood.safeTransfer(challenger, bond);
        emit ChallengeInconclusive(challengeId, bond, pool);
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
    function setCourt(address newCourt) external onlyOwner {
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
    function setExposureLedger(address ledger) external onlyOwner {
        if (ledger == address(0)) revert ZeroAddress();
        emit ExposureLedgerSet(address(exposureLedger), ledger);
        exposureLedger = IExposureLedger(ledger);
    }

    function setTierRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        emit TierRegistrySet(address(tierRegistry), registry);
        tierRegistry = ITierRegistryDemoterMinimal(registry);
    }

    /// @dev Bounded (0, 90 days]: a zero window makes every proposal
    ///      unchallengeable, and a window far beyond the ledger's coverage
    ///      window would let a filing freeze exposure that has already expired
    ///      out of its epoch buckets.
    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > 90 days) revert InvalidParameter();
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

    function setStakedWood(address stakedWood_) external onlyOwner {
        if (stakedWood_ == address(0)) revert ZeroAddress();
        emit StakedWoodSet(address(stakedWood), stakedWood_);
        stakedWood = IStakedWood(stakedWood_);
    }

    /// @dev Bounded [`MIN_AUTO_SLASH_DELAY`, `disputeTimeout`). The floor is
    ///      justified at the constant; the ceiling is the cross-parameter
    ///      invariant — both clocks run from `filedAt`, so a delay at or above
    ///      the dispute timeout would let a contested challenge time out before
    ///      the slash it was raised against ever came due, and the accused
    ///      would have bought its escalation for nothing.
    function setAutoSlashDelay(uint256 newDelay) external onlyOwner {
        if (newDelay < MIN_AUTO_SLASH_DELAY || newDelay >= disputeTimeout) revert InvalidParameter();
        emit AutoSlashDelaySet(autoSlashDelay, newDelay);
        autoSlashDelay = newDelay;
    }

    /// @dev Bounded (`autoSlashDelay`, `MAX_DISPUTE_TIMEOUT`] — the same
    ///      cross-parameter invariant from the other side, plus a ceiling on how
    ///      long a filing may pin a guardian's coverage.
    function setDisputeTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout <= autoSlashDelay || newTimeout > MAX_DISPUTE_TIMEOUT) revert InvalidParameter();
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
    function setSettleBurnBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_SETTLE_BURN_BPS) revert InvalidParameter();
        emit SettleBurnBpsSet(settleBurnBps, newBps);
        settleBurnBps = newBps;
    }

    /// @dev Gates `file` ONLY (see `filingsPaused`). Deliberately touches
    ///      nothing else — no other setter here, and no path in `dispute`,
    ///      `resolve`, `rule`, or either claim function, ever reads this flag.
    function setFilingsPaused(bool paused) external onlyOwner {
        filingsPaused = paused;
        emit FilingsPausedSet(paused);
    }
}
