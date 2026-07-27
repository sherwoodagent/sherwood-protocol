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
 * @dev    THE DETECTOR INCENTIVE IS OFF-CHAIN, and deliberately so. §3.4 asks
 *         for "a first-detector bounty sized to cover forensic cost", and no
 *         constant in this contract can be sized to that: forensic cost runs
 *         from minutes for an obvious out-of-adapter transfer to days for a
 *         funding-graph linkage. So the bounty is a protocol BUG-BOUNTY
 *         PROGRAM, priced per case off-chain and keyed off this contract's
 *         `ChallengeFiled` / `ChallengeSettled` events — which keeps it
 *         auditable, because every payout points at a filing anyone can read.
 *
 *         NOTE THE CONSEQUENCE for anyone reasoning about incentives, stated
 *         here rather than left to be discovered: ON-CHAIN, A SUCCESSFUL
 *         CHALLENGER ONLY GETS ITS BOND BACK, and a failed one loses the bond
 *         entirely — so the on-chain payoff is break-even at best. Filing is
 *         rational ONLY because of the off-chain program. §3.4 warns that "the
 *         challenge trigger must not depend on altruism"; that warning is
 *         satisfied off-chain, NOT here.
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
    ///         notice a filing and post a counter-bond.
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
    ///         the sum of their challenger bonds and counter-bonds.
    /// @dev    The §4 invariant is `wood.balanceOf(this) >= bondedWood`. With
    ///         the detector incentive off-chain this contract pays out nothing
    ///         but bonds, so the two are equal except for WOOD somebody donated
    ///         here by mistake — which no path ever spends.
    uint256 public bondedWood;

    uint256 public challengeCount;

    mapping(uint256 challengeId => Challenge) internal _challenges;

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
            disputer: address(0),
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
    /// @dev The counter-bond MATCHES the challenger's bond: the accused buys
    ///      the escalation at the same price the challenger paid for the
    ///      accusation, so neither side can price the other out of the game.
    /// @dev The dispute window closes exactly where the auto-slash opens
    ///      (`filedAt + autoSlashDelay`), so the two are disjoint by
    ///      construction: at the boundary second the silence is already the
    ///      verdict and there is nothing left to contest.
    function dispute(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        if (block.timestamp >= c.filedAt + autoSlashDelay) revert WindowClosed();

        // Standing: only a guardian this filing actually accuses. A guardian
        // that released its commitment before the filing covered nothing here
        // and is not at risk, so it has nothing to defend (D2).
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

        uint256 counterBond = c.bondWood;
        c.counterBondWood = counterBond;
        c.disputer = msg.sender;
        c.status = Status.Disputed;
        bondedWood += counterBond;

        wood.safeTransferFrom(msg.sender, address(this), counterBond);
        emit ChallengeDisputed(challengeId, msg.sender, counterBond);
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

    /// @dev THE SILENCE VERDICT (§3.4, D1). Nobody contested inside the window,
    ///      so the assertion stands: the covering approvers are slashed into the
    ///      compensation escrow, the accused adapter loses its certification,
    ///      and the challenger gets its bond back — its bond, and nothing else.
    ///      The detector's reward is the off-chain bug-bounty program keyed off
    ///      `ChallengeSettled`; see the contract-level note.
    function _settle(uint256 challengeId, Challenge storage c) private {
        IStakedWood swood = stakedWood;
        // Fail closed: without the slasher wired there is no verdict to
        // execute, and settling anyway would burn the challenge for nothing.
        if (address(swood) == address(0)) revert ZeroAddress();

        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        // Rates come from the LEDGER, not from one protocol-wide severity: each
        // approver is slashed for what they underwrote. Read before
        // `unfreezeCoverage` below only for readability — unfreezing flips a
        // `_frozen` flag and leaves the bookings intact, so the order is not
        // load-bearing.
        (address[] memory approvers, uint256[] memory slashBpsPer) = _accusedWithRates(governor, proposalId);

        // D6: the vault and the pre-drain instant are re-read from the proposal
        // rather than carried on the challenge — `executedAt - 1` is §3.8's
        // "block before the drain", and it necessarily precedes `filedAt`, so
        // sWOOD's `snapshotTimestamp <= openedAt` bound is satisfied.
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);

        uint256 bond = c.bondWood;
        c.status = Status.Settled;
        bondedWood -= bond;

        exposureLedger.unfreezeCoverage(governor, proposalId);

        // Pin the gas floor sWOOD's burn-vs-bubble classifier assumes (N-4).
        // Checked as late as possible so everything already spent counts
        // against the caller, not the margin.
        if (gasleft() < approvers.length * SLASH_GAS_PER_APPROVER + SLASH_GAS_BASE) {
            revert InsufficientSlashGas();
        }

        (uint256 slashedWood, uint256 caseId) = swood.slashToEscrow(
            _reviewKey(governor, proposalId), c.filedAt, approvers, slashBpsPer, p.vault, p.executedAt - 1
        );

        // §3.4: "adapters demote only on a passed challenge" — and only the one
        // the filing actually named (D7).
        if (c.adapterTarget != address(0)) tierRegistry.demoteByChallenge(c.adapterTarget, c.adapterSelector);

        wood.safeTransfer(c.challenger, bond);
        emit ChallengeSettled(challengeId, slashedWood, caseId);
    }

    /// @dev D5 — THE FAIL-SAFE. A disputed challenge escalates to the court of
    ///      §3.5, which does not exist yet. Without this path both bonds and the
    ///      frozen coverage would sit stuck forever and anyone could pin a
    ///      guardian's budget indefinitely just by filing. So an unruled
    ///      escalation fails in favour of the accused: not slashing is the right
    ///      default when the adjudicator is missing.
    ///
    ///      ACCEPTED COST, stated rather than discovered: until Plan E ships, a
    ///      genuinely guilty approver can dispute and run out this clock. That
    ///      is strictly better than an indefinite freeze, because it keeps the
    ///      mechanism live and bounded.
    function _fail(uint256 challengeId, Challenge storage c) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;
        (address[] memory approvers, uint256[] memory shares, uint256 totalUsd) = _accused(governor, proposalId);

        uint256 bond = c.bondWood;
        uint256 counterBond = c.counterBondWood;
        address disputer = c.disputer;
        address challenger = c.challenger;
        c.status = Status.Failed;
        bondedWood -= (bond + counterBond);

        exposureLedger.unfreezeCoverage(governor, proposalId);

        // The counter-bond was the price of the escalation, not a stake on its
        // outcome: it returns to whoever posted it.
        if (counterBond != 0) wood.safeTransfer(disputer, counterBond);

        // Defensive: the freeze makes an empty accused set unreachable while a
        // challenge is live, but a rewired ledger must not strand the bond.
        if (totalUsd == 0) {
            wood.safeTransfer(challenger, bond);
            emit ChallengeFailed(challengeId, 0);
            return;
        }

        // §3.4: "failed challenge → challenger bond forfeits to the accused",
        // pro-rata to what each of them actually committed (D4). The last
        // recipient absorbs the rounding remainder, so the forfeit is
        // distributed to the wei and nothing is stranded here.
        uint256 distributed;
        uint256 last = approvers.length - 1;
        for (uint256 i = 0; i <= last; i++) {
            uint256 amount = i == last ? bond - distributed : (bond * shares[i]) / totalUsd;
            distributed += amount;
            if (amount != 0) wood.safeTransfer(approvers[i], amount);
        }
        emit ChallengeFailed(challengeId, bond);
    }

    /// @dev The accused set: the ledger's covering approvers, filtered to those
    ///      whose committed share is still non-zero. The ledger reports a
    ///      released commitment as zero rather than dropping it, and a guardian
    ///      that released before the filing backed nothing on this proposal —
    ///      it is neither slashed nor paid out of a failed challenge.
    /// @dev The accused and the rate each is slashed at, in one ledger read.
    ///
    ///      Mirrors `_accused`'s filtering rather than passing the ledger's raw
    ///      output straight through: `slashBpsFor` returns the full HISTORICAL
    ///      approver set (matching `approversOf`), pricing a released commitment
    ///      at 0 bps. `slashToEscrow` would skip those zeros, so the amounts
    ///      would be identical either way — but the approver array is what names
    ///      people in the `GuardianSlashed` topics and the escrow case. A
    ///      guardian who withdrew their approval before the drain owes nothing
    ///      and should not appear in a conviction at all.
    ///
    ///      Both returned arrays come from the same call and are positionally
    ///      aligned by construction, so no cross-call ordering assumption is
    ///      made.
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

    function _accused(address governor, uint256 proposalId)
        internal
        view
        returns (address[] memory accused, uint256[] memory shares, uint256 totalUsd)
    {
        (address[] memory all, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 n;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] != 0) n++;
        }
        accused = new address[](n);
        shares = new uint256[](n);
        uint256 j;
        for (uint256 i = 0; i < all.length; i++) {
            if (committedUsd[i] == 0) continue;
            accused[j] = all[i];
            shares[j] = committedUsd[i];
            totalUsd += committedUsd[i];
            j++;
        }
    }

    // ── Views ──

    /// @inheritdoc IChallengeGame
    function challengeOf(uint256 challengeId) external view returns (Challenge memory) {
        return _challenges[challengeId];
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
