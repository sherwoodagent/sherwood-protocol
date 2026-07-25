// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

    /// @notice Where the burned slice of a failed challenge's forfeit goes.
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
    ///      blocks a later, legitimate one.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

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
        // A challenge accuses an EXECUTED proposal: there is no drain to allege
        // before execution, and `executedAt` is what §3.8's pre-drain snapshot
        // is derived from on the slash path.
        uint256 executedAt = ISyndicateGovernor(governor).getProposal(proposalId).executedAt;
        if (executedAt == 0) revert NotExecuted();
        if (block.timestamp > executedAt + challengeWindow) revert WindowClosed();

        bytes32 key = _reviewKey(governor, proposalId);
        // One live challenge per proposal — a second would double-freeze and
        // double-account the same coverage.
        if (_liveChallengeId(key) != 0) revert AlreadyChallenged();

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

        // D4: the bond scales with the exposure the filing freezes, converted
        // at the ledger's conservative haircut price. Fail-closed on an unset
        // price and on a bond that floors to zero — an unpriced or free
        // challenge is a free freeze, which is precisely what the bond exists
        // to prevent.
        uint256 priceX8 = exposureLedger.woodUsdPriceX8();
        if (priceX8 == 0) revert InvalidParameter();
        uint256 bondWood = (((coverageUsd * challengerBondBps) / BPS_DENOMINATOR) * 1e8) / priceX8;
        if (bondWood == 0) revert InvalidParameter();

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
            adapterSelector: adapterSelector
        });
        _lastChallenge[key] = challengeId;
        bondedWood += bondWood;

        exposureLedger.freezeCoverage(governor, proposalId);
        wood.safeTransferFrom(msg.sender, address(this), bondWood);
        emit ChallengeFiled(challengeId, governor, proposalId, msg.sender, predicate, bondWood, evidenceURI);
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
    ///      (`filedAt + autoSlashDelay`), so the two are disjoint by
    ///      construction: at the boundary second the silence is already the
    ///      verdict and there is nothing left to contest. A pool that is still
    ///      short at that instant simply loses — which is the point, because a
    ///      part-funded defence is not a defence.
    /// @dev CEI: every storage write lands before the `transferFrom`, so the
    ///      token cannot observe or re-enter a half-updated pool.
    function dispute(uint256 challengeId, uint256 amountWood) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        if (block.timestamp >= c.filedAt + autoSlashDelay) revert WindowClosed();

        // Standing: only a guardian this filing actually accuses. A guardian
        // that released its commitment before the filing covered nothing here
        // and is not at risk, so it has nothing to defend (D2). This is also
        // what BOUNDS the contributor list — the accused set is the ledger's,
        // and each member can appear in it at most once.
        (address[] memory approvers, uint256[] memory committedUsd) =
            exposureLedger.approversOf(c.governor, c.proposalId);
        bool accused;
        for (uint256 i = 0; i < approvers.length; i++) {
            if (approvers[i] == msg.sender && committedUsd[i] != 0) {
                accused = true;
                break;
            }
        }
        if (!accused) revert NotAccusedApprover();

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
            if (block.timestamp < c.filedAt + autoSlashDelay) revert DelayNotElapsed();
            _settle(challengeId, c);
        } else if (status == Status.Disputed) {
            if (block.timestamp < c.filedAt + disputeTimeout) revert DelayNotElapsed();
            _fail(challengeId, c);
        } else {
            revert WrongStatus();
        }
    }

    /// @inheritdoc IChallengeGame
    /// @dev THE COURT SUPPLIES ONLY THE VERDICT BIT. `guilty` reuses `_settle`
    ///      verbatim — the same path an UNDISPUTED challenge takes, so the slash
    ///      is at sWOOD's `maxSlashBps` with no severity ramp (§3.5 "ground truth
    ///      established", D7) — and `!guilty` reuses `_fail`, the same path the
    ///      timeout takes, because a not-guilty ruling and an unruled escalation
    ///      say the same thing about the accused: the disputer was right, so it
    ///      gets its counter-bond back and the challenger's bond forfeits. There
    ///      is deliberately no severity parameter here; a court that could dial
    ///      the slash would be negotiating with the accused, not ruling on them.
    /// @dev RULING BEATS THE TIMEOUT: both branches are terminal and `resolve`
    ///      acts only on `Filed`/`Disputed`, so the clock can never overwrite a
    ///      verdict already handed down. That ordering is the entire point of
    ///      this entrypoint — it is what stops a genuinely guilty approver from
    ///      disputing and running out `disputeTimeout`.
    /// @dev CEI is inherited from `_settle`/`_fail`, which both write the
    ///      terminal status before any external call; the event is emitted first
    ///      so the log reads verdict-then-consequence.
    function rule(uint256 challengeId, bool guilty) external {
        if (msg.sender != court) revert NotCourt();
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Disputed) revert WrongStatus();
        emit ChallengeRuled(challengeId, guilty);
        if (guilty) {
            _settle(challengeId, c);
        } else {
            _fail(challengeId, c);
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
        if (address(swood) == address(0)) revert ZeroAddress();

        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        address[] memory approvers = _accused(governor, proposalId);

        // D6: the vault and the pre-drain instant are re-read from the proposal
        // rather than carried on the challenge — `executedAt - 1` is §3.8's
        // "block before the drain", and it necessarily precedes `filedAt`, so
        // sWOOD's `snapshotTimestamp <= openedAt` bound is satisfied.
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);

        uint256 bond = c.bondWood;
        uint256 pool = c.counterBondWood;
        // READ BEFORE THE TERMINAL WRITE. This is the only thing that keeps the
        // two entries apart — a moment later every challenge here is `Settled`
        // and a full pool is indistinguishable from a partial one.
        bool escalated = c.status == Status.Disputed;
        c.status = Status.Settled;
        bondedWood -= (bond + pool);

        exposureLedger.unfreezeCoverage(governor, proposalId);

        (uint256 slashedWood, uint256 caseId) = swood.slashToEscrow(
            _reviewKey(governor, proposalId), c.filedAt, approvers, swood.maxSlashBps(), p.vault, p.executedAt - 1
        );

        // §3.4: "adapters demote only on a passed challenge" — and only the one
        // the filing actually named (D7).
        if (c.adapterTarget != address(0)) tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector);

        // Exactly `bond + pool` leaves on BOTH branches, matching the decrement
        // above to the wei: the forfeit adds the pool to the challenger's
        // payment, the refund hands the same pool back to the people who paid it.
        if (escalated) {
            wood.safeTransfer(c.challenger, bond + pool);
        } else {
            wood.safeTransfer(c.challenger, bond);
            _refundContributions(challengeId);
        }
        emit ChallengeSettled(challengeId, slashedWood, caseId);
    }

    /// @dev Hands every contribution back to whoever made it. Reached only from
    ///      the undisputed-settle path, where the pool never completed. The
    ///      stored amounts are deliberately NOT zeroed: the challenge is already
    ///      terminal and nothing can re-enter — `dispute` requires `Filed`, and
    ///      both unwind paths require a live status — so leaving them keeps the
    ///      payout auditable at no correctness cost.
    function _refundContributions(uint256 challengeId) private {
        address[] storage list = _contributors[challengeId];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address contributor = list[i];
            // Never zero: an address is listed only by a non-zero contribution,
            // and a repeat contributor only ever adds to it.
            wood.safeTransfer(contributor, _contributed[challengeId][contributor]);
        }
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

        exposureLedger.unfreezeCoverage(governor, proposalId);

        address[] storage list = _contributors[challengeId];
        uint256 n = list.length;
        // Defensive: unreachable from `Disputed`, where the pool is by
        // construction complete and therefore funded by at least one address.
        // Left in so the bond can never be stranded if a future caller widens
        // the reachable states again — the hazard this file has now hit twice.
        if (n == 0) {
            wood.safeTransfer(challenger, bond);
            emit ChallengeFailed(challengeId, 0, 0);
            return;
        }

        // The burn is taken off the top and the REMAINDER is what the funders
        // split, so `burnAmount + sum(winnings) == bond` exactly: the pro-rata
        // pass below is keyed to `payout`, not to `bond`, and its last recipient
        // absorbs the rounding remainder of `payout` rather than of the bond.
        // Integer division makes `burnAmount <= bond`, so `payout` cannot
        // underflow, and a `forfeitBurnBps` of zero reproduces the pre-burn
        // behaviour to the wei.
        uint256 burnAmount = (bond * forfeitBurnBps) / BPS_DENOMINATOR;
        uint256 payout = bond - burnAmount;
        // Skipped when the parameter is zero: a zero-value transfer would only
        // emit a misleading `Transfer` to the dead address.
        if (burnAmount != 0) wood.safeTransfer(BURN_ADDRESS, burnAmount);

        // §3.4: "failed challenge → challenger bond forfeits to the accused" —
        // to the ones that funded the defence, pro-rata to what each put in. The
        // last recipient absorbs the rounding remainder, so the forfeit is
        // distributed to the wei and nothing is stranded here. Each contributor
        // is paid its stake back and its slice of the forfeit in one transfer.
        uint256 distributed;
        uint256 last = n - 1;
        for (uint256 i = 0; i <= last; i++) {
            address contributor = list[i];
            uint256 contributed = _contributed[challengeId][contributor];
            uint256 winnings = i == last ? payout - distributed : (payout * contributed) / pool;
            distributed += winnings;
            wood.safeTransfer(contributor, contributed + winnings);
        }
        emit ChallengeFailed(challengeId, bond, burnAmount);
    }

    /// @dev The accused set: the ledger's covering approvers, filtered to those
    ///      whose committed share is still non-zero. The ledger reports a
    ///      released commitment as zero rather than dropping it, and a guardian
    ///      that released before the filing backed nothing on this proposal, so
    ///      it is not slashed for it.
    /// @dev It returns ADDRESSES ONLY. It used to hand back each guardian's
    ///      committed share and their total as well, because a failed challenge
    ///      paid the forfeit out by coverage; that split is now keyed to
    ///      contribution instead (see `_fail`), so the only remaining consumer is
    ///      the slash list in `_settle`, and the coverage weights are dead.
    function _accused(address governor, uint256 proposalId) internal view returns (address[] memory accused) {
        (address[] memory all, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] != 0) n++;
        }
        accused = new address[](n);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] == 0) continue;
            accused[j] = all[i];
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
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256) {
        return _liveChallengeId(_reviewKey(governor, proposalId));
    }

    function _liveChallengeId(bytes32 key) internal view returns (uint256) {
        uint256 id = _lastChallenge[key];
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
}
