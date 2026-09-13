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
 * @dev    There is no on-chain predicate verification. The `Predicate` enum is
 *         a label carried in the event, nothing more.
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

    /// @notice Hard floor on `voteWindow` - the guardians' entire window to
    ///         notice a filing and decide it between them.
    /// @dev    Guards against a hostile owner collapsing the window to zero and
    ///         turning a filing into an instant verdict. 48h survives a weekend,
    ///         an operator outage or a short chain halt.
    uint256 public constant MIN_VOTE_WINDOW = 2 days;

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
    ///      floor was 31,000,000 against Robinhood Chain's `maxTxGasLimit` of
    ///      32,000,000, which the EIP-150 haircut puts out of reach of any
    ///      transaction: a conviction against a full cohort could not be mined,
    ///      the challenge would run out its clock, and the accused would be
    ///      ACQUITTED. A gas floor that converts a guilty verdict into an
    ///      acquittal is worse than the out-of-gas it was written to prevent.
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
    ///      Re-derive end to end through `resolve` before moving these:
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
    /// @dev    The only sink an attacker controlling both sides of a challenge
    ///         cannot reach.
    /// @dev    Not a real burn: WOOD is a plain `IERC20` with no `burn`, and
    ///         `address(0)` is unusable because OpenZeppelin's ERC20 rejects
    ///         transfers to it, which would brick resolution. Total supply keeps
    ///         counting it, but nothing here can ever spend it again.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev Ceiling on `forfeitBurnBps`. The burn prices a self-challenge round
    ///      trip out of profitability without making a wrong-but-honest filing
    ///      cost the whole bond. Half the bond also caps how much a captured
    ///      owner can destroy per failed challenge.
    uint256 internal constant MAX_FORFEIT_BURN_BPS = 5_000;

    /// @dev Ceiling on `settleBurnBps`. Burning the whole bond would make a
    ///      correct filing cost as much as a wrong one, removing the only
    ///      on-chain reason to file at all.
    uint256 internal constant MAX_SETTLE_BURN_BPS = 5_000;

    /// @notice Bond currency for the challenger's bond.
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

    /// @notice The owner's only lever that gates NEW filings: true refuses
    ///         `file` alone. Never checked in `resolve`.
    /// @dev    Restricted to `file` deliberately: pausing anything mid-flight
    ///         would let a live challenge drift past its window and lose the
    ///         challenger's burn by owner inaction. The worst this flag can do
    ///         is stop new challenges from starting - it can never freeze one
    ///         that exists, nor move the terms a live challenge is priced
    ///         against, which are pinned at filing.
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

    /// @notice The slice of a FAILED challenge's bond that is destroyed rather
    ///         than returned to the challenger, in bps. Default 20%.
    /// @dev    Prices self-challenging. An approver could file against its own
    ///         executed proposal and let the challenge fail, freezing every
    ///         co-approver's coverage for a whole window at net cost zero. A
    ///         `msg.sender != challenger` check is theatre (two addresses defeat
    ///         it), so the slice is burned instead.
    uint256 public forfeitBurnBps = 2_000;

    /// @notice The window a challenge is decided in, measured from `filedAt`.
    ///         See `MIN_VOTE_WINDOW` for why its floor is load-bearing.
    uint256 public voteWindow = 7 days;

    /// @notice Share of a SUCCESSFUL challenger's payout burned on settle, in
    ///         bps. Read the live value off the initialiser below rather than
    ///         trusting any figure quoted in prose - it has drifted twice.
    /// @dev    Prices a filing in both directions: refunding in full would make
    ///         the slash and the adapter demotion come for the price of gas. It
    ///         is a cost, not a transfer to the accused - paying convicted
    ///         approvers out of a correct filing would invert the incentive.
    /// @dev    Sized against the honest filer's net payoff,
    ///         `proposerBondBps * prosecutorFeeBps - challengerBondBps *
    ///         settleBurnBps` (see `honestFilingNetPayoffBps`). The reward side
    ///         cannot be raised - `prosecutorFeeBps` is already AT
    ///         `MAX_PROSECUTOR_FEE_BPS`, which `ProposerBondEscrow` enforces
    ///         independently - so this cost term is the only lever left.
    ///         Lowering it does not subsidise fabricated filings: it burns a
    ///         slice of a WINNING challenger's bond, and a false accuser instead
    ///         pays `forfeitBurnBps` of the bond on a different path.
    uint256 public settleBurnBps = 500;

    /// @notice Share of the votable stake that must vote to convict, in basis
    ///         points. Bounded like the registry's block quorum; pinned onto
    ///         each challenge at filing.
    uint256 public challengeQuorumBps = 3_000;

    /// @dev One vote per guardian per challenge.
    mapping(uint256 challengeId => mapping(address voter => bool)) internal _voted;

    /// @dev The approvers this challenge accuses, so the vote can refuse them
    ///      in O(1). Written in the loop `file` already runs over the cohort.
    mapping(uint256 challengeId => mapping(address approver => bool)) internal _accusedApprover;

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
    /// @dev    PAID ON EVERY CONVICTION - the filer is otherwise out of pocket.
    /// @dev    Pinned per challenge at filing, so a governance change cannot
    ///         re-rate a challenge in flight. If the escrow rejects a pinned
    ///         rate, `_settle` retries at zero rather than losing the conviction.
    uint256 public prosecutorFeeBps = 2_000;

    /// @notice WOOD held on behalf of live (`Filed`) challenges - the sum of
    ///         their challenger bonds.
    /// @dev    Invariant: `wood.balanceOf(this) >= bondedWood`.
    uint256 public bondedWood;

    uint256 public challengeCount;

    /// @inheritdoc IChallengeGame
    /// @dev Never read as a stored absolute - `file` always maxes this value
    ///      against the live `executedAt + strategyDuration + challengeWindow`
    ///      baseline. `challengeWindow` is mutable state, so comparing only at
    ///      write time would let a shortened-then-restored window leave this
    ///      mapping below what a fresh proposal would compute, with no setter to
    ///      fix it. It only ever needs to raise the floor.
    mapping(bytes32 reviewKey => uint256) public challengeableUntil;

    mapping(uint256 challengeId => Challenge) internal _challenges;

    /// @dev The most recent challenge against a proposal. Only meaningful while
    ///      that challenge is still live — `_liveChallengeId` re-checks status
    ///      rather than trusting the pointer, so a terminal challenge never
    ///      blocks a later, legitimate one. Kept for indexers; the blocking
    ///      question is now asked per challenger via `_liveByChallenger`.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

    /// @dev One slot per CHALLENGER, not per proposal: keying by proposal alone
    ///      would let an accused cohort buy free immunity by self-filing to
    ///      occupy the only slot until the challenge window shuts.
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

        // The named adapter must appear in the proposal's own stored execute
        // calls — a membership test over data the governor already holds, not
        // a second calldata parser. Without it, a passed challenge could demote
        // an arbitrary certified adapter anywhere in the registry.
        if (adapterTarget != address(0)) {
            _requireAdapterInProposal(governor, proposalId, adapterTarget, adapterSelector);
        }

        // The approvers underwrote ONE proposal and owe ONE liability. Once a
        // settled challenge has collected it, every later filing must be refused
        // at the door: it could still freeze coverage for another `voteWindow`
        // while collecting nothing. A FAILED challenge is
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

        challengeId = ++challengeCount;
        // Same refusal as `_convicted` above, but asked of sWOOD directly, whose
        // `verdictSlashed` key survives a redeploy of this game. Without it, a
        // replacement game would accept filings against a cohort the OLD game
        // already convicted, freeze coverage and take the bond, then be unable to
        // terminate: `_settle` would revert `ApproverAlreadySlashed`.
        address[] memory accused = new address[](accusedCount);
        for (uint256 i = 0; i < lockedWood.length; i++) {
            if (lockedWood[i] == 0) continue;
            accused[--accusedCount] = covering[i];
            _accusedApprover[challengeId][covering[i]] = true;
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

        // The electorate is pinned ONCE, here, and one second back. sWOOD
        // checkpoints are keyed on the second a stake changes and a same-key
        // push overwrites, so reading the current timestamp would let a stake
        // planted in this very block sit in the numerator but not the
        // denominator. `GuardianRegistry.snapshotAt` hardens the stamp the same
        // way, for the same reason.
        IStakedWood swood = stakedWood;
        if (address(swood) == address(0)) revert ZeroAddress();
        uint256 snapshotAt = block.timestamp - 1;
        uint256 votable = swood.getPastTotalVotes(snapshotAt);
        for (uint256 i = 0; i < accused.length; i++) {
            uint256 w = swood.getPastStake(accused[i], snapshotAt);
            votable = votable > w ? votable - w : 0;
        }
        // Nobody outside the accused cohort could decide it, so the filing is
        // refused rather than taking a bond it can only burn.
        if (votable == 0) revert NoVotableStake();

        _challenges[challengeId] = Challenge({
            governor: governor,
            proposalId: proposalId,
            challenger: msg.sender,
            bondWood: bondWood,
            predicate: predicate,
            status: Status.Filed,
            filedAt: block.timestamp,
            frozenCoverageUsd: coverageUsd,
            adapterTarget: adapterTarget,
            adapterSelector: adapterSelector,
            executedAt: executedAt,
            vault: p.vault,
            // The clock is pinned here: read live, the owner could shorten
            // `voteWindow` after filing and retroactively erase a window the
            // accused was still inside.
            voteWindowAtFiling: voteWindow,
            // Both burn rates pinned too: the challenger relies on
            // `settleBurnBps` when it files and cannot withdraw, and on
            // `forfeitBurnBps` for what it gets back if it loses. A live read
            // would let a post-filing raise take a larger bite of a commitment
            // already made.
            settleBurnBpsAtFiling: settleBurnBps,
            forfeitBurnBpsAtFiling: forfeitBurnBps,
            // Pinned for the same reason: a live read would change what the
            // challenger stood to collect on a conviction it already bonded
            // against. Bounded by `MAX_PROSECUTOR_FEE_BPS` at set time and again
            // by the paying escrow, which is the authority.
            prosecutorFeeBpsAtFiling: prosecutorFeeBps,
            // The escrow holding this proposal's proposer bond, off the same
            // `getProposal` read. Bound at propose time and never re-pointed, so
            // a verdict up to `voteWindow` later confiscates from the escrow the
            // bond was locked in.
            proposerBondEscrow: p.proposerBondEscrow,
            votableStakeAtFiling: votable,
            quorumBpsAtFiling: challengeQuorumBps,
            convictWeight: 0,
            acquitWeight: 0
        });
        _lastChallenge[key] = challengeId;
        _liveByChallenger[challengerKey] = challengeId;
        bondedWood += bondWood;

        // Refcounted for the UNFREEZE only: the last live challenge to terminate
        // releases it. The ledger hears about EVERY filing, because `liveUntil`
        // (this challenge's worst-case end) can outlive the first freeze's
        _liveCount[key]++;
        exposureLedger.freezeCoverage(governor, proposalId, block.timestamp + voteWindow);

        wood.safeTransferFrom(msg.sender, address(this), bondWood);
        emit ChallengeFiled(challengeId, governor, proposalId, msg.sender, predicate, bondWood, evidenceURI);
    }

    /// @dev The membership test behind `AdapterNotInProposal`. Matches on
    ///      `(target, selector)` across BOTH committed legs — the execute calls
    ///      and the settlement calls — because coverage prices both. A call with
    ///      fewer than 4 bytes of calldata carries no selector and can only
    ///      match a filing that names one it cannot have, so it is skipped
    ///      rather than treated as a wildcard.
    function _requireAdapterInProposal(address governor, uint256 proposalId, address target, bytes4 selector)
        private
        view
    {
        if (_callsContain(ISyndicateGovernor(governor).getExecuteCalls(proposalId), target, selector)) return;
        if (_callsContain(ISyndicateGovernor(governor).getSettlementCalls(proposalId), target, selector)) return;
        revert AdapterNotInProposal();
    }

    function _callsContain(BatchExecutorLib.Call[] memory calls, address target, bytes4 selector)
        private
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].target != target) continue;
            bytes memory data = calls[i].data;
            if (data.length < 4) continue;
            if (bytes4(data) == selector) return true;
        }
        return false;
    }

    /// @dev Per-challenger slot key. Namespaced under the review key so two
    ///      proposals can never share a slot.
    function _challengerKey(bytes32 key, address challenger) private pure returns (bytes32) {
        return keccak256(abi.encode(key, challenger));
    }

    // ── Deciding ──

    /// @notice Cast a guardian's vote on a live challenge. Weight is the
    ///         voter's staked WOOD one second before the filing — the same
    ///         instant the challenge's votable stake was measured at.
    /// @dev The accused approvers are refused: they underwrote the proposal the
    ///      challenge accuses, so their weight is out of the denominator too.
    function voteOnChallenge(uint256 challengeId, bool convict) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        if (block.timestamp >= c.filedAt + c.voteWindowAtFiling) revert WindowClosed();
        if (_accusedApprover[challengeId][msg.sender]) revert AccusedCannotVote();
        if (_voted[challengeId][msg.sender]) revert AlreadyVoted();

        IStakedWood swood = stakedWood;
        if (address(swood) == address(0)) revert ZeroAddress();
        if (!swood.isActiveGuardian(msg.sender)) revert NoVotableStake();
        uint256 weight = swood.getPastStake(msg.sender, c.filedAt - 1);
        if (weight == 0) revert NoVotableStake();

        _voted[challengeId][msg.sender] = true;
        if (convict) c.convictWeight += weight;
        else c.acquitWeight += weight;
        emit ChallengeVoteCast(challengeId, msg.sender, convict, weight);
    }

    // ── Resolution ──

    /// @inheritdoc IChallengeGame
    /// @dev Permissionless on purpose. The terminal path lets the caller choose
    ///      nothing - the outcome is fixed by state and the clock - so opening
    ///      it removes the last place a privileged party could sit on a verdict.
    function resolve(uint256 challengeId) external {
        Challenge storage c = _challenges[challengeId];
        if (c.status != Status.Filed) revert WrongStatus();
        // Monotone: there is no un-vote, so a reached quorum can settle at once.
        uint256 votable = c.votableStakeAtFiling;
        if (votable != 0 && c.convictWeight * BPS_DENOMINATOR >= c.quorumBpsAtFiling * votable) {
            _settle(challengeId, c);
            return;
        }
        if (block.timestamp < c.filedAt + c.voteWindowAtFiling) revert DelayNotElapsed();
        _fail(challengeId, c);
    }

    function _settle(uint256 challengeId, Challenge storage c) private {
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
        bondedWood -= bond;

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
                // EVERY conviction - the challenger is otherwise out of pocket.
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

        // A correct filing is cheap, not free. A `msg.sender != challenger`
        // check would be theatre (two addresses defeat it), so the cost is
        // charged by rate, not by identity.
        uint256 burned = (bond * c.settleBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burned != 0) {
            wood.safeTransfer(BURN_ADDRESS, burned);
            emit ChallengerBondBurned(challengeId, burned);
        }
        wood.safeTransfer(c.challenger, bond - burned);
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

    function _rearmChallengeWindow(bytes32 rk, address governor, uint256 proposalId) private {
        if (_convicted[rk]) return;
        uint256 extended = block.timestamp + challengeWindow;
        if (extended > challengeableUntil[rk]) challengeableUntil[rk] = extended;
        exposureLedger.pinCoverageUntil(governor, proposalId, challengeableUntil[rk]);
    }

    function _fail(uint256 challengeId, Challenge storage c) private {
        address governor = c.governor;
        uint256 proposalId = c.proposalId;

        uint256 bond = c.bondWood;
        address challenger = c.challenger;
        c.status = Status.Failed;
        bondedWood -= bond;

        bytes32 rk = _reviewKey(governor, proposalId);
        _releaseFreeze(rk, governor, proposalId);
        // Silence adjudicated nothing, so the proposal stays challengeable. A
        // voted acquittal DID adjudicate, and spends the window.
        if (c.acquitWeight == 0) _rearmChallengeWindow(rk, governor, proposalId);

        // Integer division keeps `burnAmount <= bond`, so the remainder cannot
        // underflow, and a zero rate returns the bond whole.
        uint256 burnAmount = (bond * c.forfeitBurnBpsAtFiling) / BPS_DENOMINATOR;
        if (burnAmount != 0) {
            wood.safeTransfer(BURN_ADDRESS, burnAmount);
            emit ChallengerBondBurned(challengeId, burnAmount);
        }
        wood.safeTransfer(challenger, bond - burnAmount);
        emit ChallengeFailed(challengeId, bond, burnAmount);
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
    function challengeOf(uint256 challengeId) external view returns (Challenge memory) {
        return _challenges[challengeId];
    }

    /// @inheritdoc IChallengeGame
    function challengeTallyOf(uint256 challengeId)
        external
        view
        returns (uint256 convictWeight, uint256 votableStake, uint256 quorumBps)
    {
        Challenge storage c = _challenges[challengeId];
        return (c.convictWeight, c.votableStakeAtFiling, c.quorumBpsAtFiling);
    }

    /// @inheritdoc IChallengeGame
    function hasVotedOn(uint256 challengeId, address voter) external view returns (bool) {
        return _voted[challengeId][voter];
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
        return status == Status.Filed ? id : 0;
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
    ///      `NotCoverageFreezer` - stranding the bond, and leaving the
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
    ///      `slashVerdict`'s caller gate. This enforces the deploy order the
    ///      scripts already follow.
    function setStakedWood(address stakedWood_) external onlyOwner {
        if (stakedWood_ == address(0)) revert ZeroAddress();
        if (IStakedWood(stakedWood_).authorizedSlasher() != address(this)) revert RoleNotGranted();
        emit StakedWoodSet(address(stakedWood), stakedWood_);
        stakedWood = IStakedWood(stakedWood_);
    }

    /// @dev Disabled: two recovery levers are owner-only and irreplaceable -
    ///      `setStakedWood` un-wedges a challenge stuck on an unwired slasher,
    ///      and `setExposureLedger` is the only way to move the freeze rail.
    ///      Ownership can still be HANDED OVER via `Ownable2Step`.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev Floored at `MIN_VOTE_WINDOW`: a window the owner could collapse to
    ///      zero would turn a filing into an instant verdict.
    function setVoteWindow(uint256 newWindow) external onlyOwner {
        if (newWindow < MIN_VOTE_WINDOW) revert InvalidParameter();
        emit VoteWindowSet(voteWindow, newWindow);
        voteWindow = newWindow;
    }

    /// @notice Set the convict quorum, in basis points of the votable stake.
    /// @dev Floored well above zero: a quorum a single dust guardian could meet
    ///      would make the vote a formality rather than a decision.
    function setChallengeQuorumBps(uint256 newBps) external onlyOwner {
        if (newBps < 1_000 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ChallengeQuorumBpsSet(challengeQuorumBps, newBps);
        challengeQuorumBps = newBps;
    }

    /// @dev Bounded [0, `MAX_SETTLE_BURN_BPS`]. Zero is legal and means the
    ///      settle path refunds in full.
    /// @dev Applies to challenges FILED after the change, not ones settled after
    ///      it: the challenger reads this rate when deciding whether the bond is
    ///      worth posting and cannot withdraw once posted.
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

    /// @dev Gates `file` ONLY (see `filingsPaused`). Deliberately touches
    ///      nothing else — no other setter here, and no path in `resolve`, ever
    ///      reads this flag.
    function setFilingsPaused(bool paused) external onlyOwner {
        emit FilingsPausedSet(filingsPaused, paused);
        filingsPaused = paused;
    }
}
