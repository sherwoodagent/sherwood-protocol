// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";
import {GovernorParameters} from "./GovernorParameters.sol";
import {GovernorEmergency} from "./GovernorEmergency.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/**
 * @title SyndicateGovernor
 * @notice Governance system for agent-managed vaults. Agents propose strategies,
 *         shareholders vote, and approved strategies execute via the vault.
 *
 *   - One strategy live per vault at a time
 *   - Cooldown window between strategies for depositor exit
 *   - Permissionless settlement after strategy duration ends
 *   - P&L calculated via balance snapshot diffs
 *   - Vote weight from ERC20Votes checkpoints (timestamp-based snapshots)
 *   - Optimistic governance: proposals pass unless AGAINST votes reach veto threshold
 *   - Collaborative proposals: multiple agents co-submit with fee splits
 *   - Parameter setters are owner-instant (owner multisig enforces external delay)
 *   - Protocol fee taken from profit before agent/management fees
 */
contract SyndicateGovernor is GovernorParameters, GovernorEmergency, Initializable {
    // ── Storage (existing -- DO NOT reorder) ──
    // `vault`, `protocolConfig`, `factory`, `_params` live in `GovernorParameters`.

    /// @notice Proposal ID counter (1-indexed)
    uint256 private _proposalCount;

    // `_proposals` lives in ProposalLifecycle (base owns the state machine).

    /// @notice Proposal ID -> voter -> bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Proposal ID -> vault balance at execution time
    mapping(uint256 => uint256) private _capitalSnapshots;

    /// @notice Currently executing proposal ID (0 if none)
    uint256 private _activeProposal;

    // `_lastSettledAt` lives in ProposalLifecycle (stamped by `_decOpen`).

    // ── Collaborative proposal storage ──

    /// @notice Proposal ID -> co-proposers array
    mapping(uint256 => CoProposer[]) private _coProposers;

    /// @notice Proposal ID -> co-proposer address -> approved
    /// @dev `internal` (no auto-getter): read only within the governor; not in
    ///      ISyndicateGovernor / cli / app / subgraph / tests. Bytecode lever.
    mapping(uint256 => mapping(address => bool)) internal coProposerApprovals;

    // `collaborationDeadline` lives in ProposalLifecycle (read by the base's
    // `_computeState` for the Draft -> Expired edge).

    /// @notice Simple reentrancy lock for execute/settle entrypoints
    uint256 private _reentrancyStatus;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @notice Upper bound on `metadataURI.length` accepted by `propose`. 512
    ///         bytes comfortably fits ipfs / arweave / https pointers while
    ///         capping event-storage and calldata-copy griefing.
    uint256 internal constant MAX_METADATA_URI_LENGTH = 512;
    /// @notice Upper bound on the `executeCalls` and `settlementCalls` arrays
    ///         passed to `propose`. Caps batch size so executeGovernorBatch
    ///         can't be weaponized for gas griefing.
    uint256 internal constant MAX_CALLS_PER_PROPOSAL = 64;

    /// @notice Minimum elapsed time post-execute before the proposer can
    ///         self-settle (skipping `strategyDuration`). Prevents the single-
    ///         block execute → settle skim where a proposer gains
    ///         `performanceFeeBps` on a one-block trade. Anyone other than the
    ///         proposer still waits for `strategyDuration`.
    uint256 internal constant MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE = 1 hours;

    // ── New storage (appended -- UUPS safe) ──

    /// @notice Proposal ID -> execute (opening) calls
    mapping(uint256 => BatchExecutorLib.Call[]) private _executeCalls;

    /// @notice Proposal ID -> settlement (closing) calls
    mapping(uint256 => BatchExecutorLib.Call[]) private _settlementCalls;

    // `_guardianRegistry` lives in ProposalLifecycle. Set in `initialize`
    // (writes the inherited slot) and required (non-zero); fees always
    // route here — no separate recipient slot.

    // ── Guardian-review storage ──
    // `_emergencyCallsHashes` and `_emergencyCalls` live in GuardianRegistry.
    // Two mapping slots reclaimed into __gap.

    // `_openProposalCount` lives in ProposalLifecycle. Counts non-terminal
    // proposals (Draft/Pending/GuardianReview/Approved/Executed); used by
    // `GuardianRegistry.requestUnstakeOwner` alongside `_activeProposal` to
    // block owner rage-quit while any proposal is in flight. Incremented here
    // (Draft/Pending); decremented via the inherited `_decOpen`.

    /// @dev Escrow of fee transfers that reverted (e.g., USDC blacklist) so the
    ///      rest of `_distributeFees` keeps flowing and settlement never bricks.
    ///      Recipients pull via `claimUnclaimedFees`. The underlying amount
    ///      remains in the vault; this mapping is pure bookkeeping.
    ///      Keyed by `keccak256(vault, recipient, token)` so a claim can only
    ///      pull from the vault that actually owes the escrow — prevents the
    ///      cross-vault drain where a recipient with escrow on vault A redirects
    ///      the pull to vault B. Single-level mapping + packed key is chosen
    ///      over a triple-nested mapping to keep governor runtime ≤ 24,550.
    mapping(bytes32 key => uint256) private _unclaimedFees;

    /// @dev Count of co-proposer approvals per proposal. Incremented in
    ///      `approveCollaboration`. Drives both the all-approved transition
    ///      and the near-quorum cancel guard.
    mapping(uint256 proposalId => uint256) private _approvedCount;

    /// @dev Per-Draft snapshot of (executionWindow << 128 | votingPeriod)
    ///      taken at propose. `approveCollaboration` reads it at Draft →
    ///      Pending so a mid-Draft owner param change can't move the
    ///      goalposts for co-proposers who already approved.
    mapping(uint256 proposalId => uint256 packedTiming) private _draftTimingSnap;

    /// @notice Tier registry. Optional: address(0) means every proposal
    ///         resolves to tier 2 / full notional — the safe default. Wired
    ///         post-init via `setTierRegistry` (factory-only, like
    ///         `setProtocolConfig`).
    address internal _tierRegistry;

    /// @notice Exposure ledger. Optional: address(0) skips the covered-TVL
    ///         cap + proposer-bond gates at propose — the pre-ledger safe
    ///         default. Wired post-init via `setExposureLedger`
    ///         (factory-only, like `setTierRegistry`).
    address internal _exposureLedger;

    /// @notice Proposer bond escrow. Optional: address(0) skips bond
    ///         locking. Wired via `setBondEscrow` (factory-only).
    address internal _bondEscrow;

    /// @notice Proposal ID -> per-call gross-outflow caps for the EXECUTE
    ///         (opening) calls, one entry per `_executeCalls[id]` entry,
    ///         denominated in the vault asset. Stored immutably at propose
    ///         (issue #43); coverage is priced from these, and they are
    ///         forwarded to `executeGovernorBatch` unchanged at execute.
    mapping(uint256 => uint256[]) private _executeCallCaps;

    /// @notice Proposal ID -> per-call gross-outflow caps for the SETTLEMENT
    ///         (closing) calls, mirroring `_executeCallCaps`. Forwarded at
    ///         settle, `unstick`, and re-resolved at execute-time regression
    ///         checks; NOT forwarded on the owner-supplied
    ///         `finalizeEmergencySettle` path (empty caps there — design.md D3).
    mapping(uint256 => uint256[]) private _settlementCallCaps;

    /// @notice Proposal ID -> per-call gross-outflow caps for the SETTLEMENT
    ///         calls, SCALED by the same coverage ratio as `effectiveMaxCapital`
    ///         (issue #27 design D7) and persisted at execute so `settleProposal`
    ///         reads byte-identical caps however much later it runs, with no
    ///         live recompute. Populated on EVERY execute path (identity copy
    ///         of `_settlementCallCaps` when the quorum gate did not run or
    ///         coverage was full) — never left empty for an `Executed`
    ///         proposal.
    mapping(uint256 => uint256[]) private _effectiveSettlementCallCaps;

    /// @dev Reserved storage for future upgrades. Carved by 3 slots (from 31)
    ///      for the three mappings above — append-only: every pre-existing
    ///      named variable keeps its slot, and the mappings occupy exactly
    ///      the front of what used to be gap space. See
    ///      `script/syndicate-governor-layout.golden.json` (regenerated,
    ///      task 5.1).
    uint256[28] private __gap;

    /// @param minVotingPeriod_   Per-deployment floor for `votingPeriod` (mainnet 24h).
    /// @param minCooldownPeriod_ Per-deployment floor for `cooldownPeriod` (mainnet 1h).
    /// @dev Floors are impl-time immutables (bytecode, not storage) forwarded to
    ///      `GovernorParameters`; a testnet impl may deploy lower floors and be
    ///      wired in via `GovernorBeacon.upgradeTo` without any storage migration.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 minVotingPeriod_, uint256 minCooldownPeriod_)
        GovernorParameters(minVotingPeriod_, minCooldownPeriod_)
    {
        _disableInitializers();
    }

    function initialize(
        address vault_,
        address guardianRegistry_,
        address protocolConfig_,
        address factory_,
        GovernorParams calldata params_
    ) external initializer {
        if (guardianRegistry_ == address(0) || protocolConfig_ == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        _validateParamBounds(params_);
        vault = vault_;
        _guardianRegistry = guardianRegistry_;
        protocolConfig = protocolConfig_;
        factory = factory_;
        _params = params_;
        _reentrancyStatus = _NOT_ENTERED;
        // Bootstrap owner: if no vault is wired at deploy, the deployer acts as
        // the vault-owner stand-in for parameter setters. In production, factory_
        // owner serves this role until the vault association is completed.
        if (vault_ == address(0)) {
            _bootstrapOwner = factory_;
        }
    }

    modifier nonReentrant() {
        _emergencyReentrancyEnter();
        _;
        _emergencyReentrancyLeave();
    }

    // ── GovernorEmergency virtual accessor overrides ──

    function _getSettlementCalls(uint256 id) internal view override returns (BatchExecutorLib.Call[] storage) {
        return _settlementCalls[id];
    }

    function _getSettlementCallCaps(uint256 id) internal view override returns (uint256[] storage) {
        return _settlementCallCaps[id];
    }

    function _emergencyReentrancyEnter() internal override {
        if (_reentrancyStatus == _ENTERED) revert Reentrancy();
        _reentrancyStatus = _ENTERED;
    }

    function _emergencyReentrancyLeave() internal override {
        _reentrancyStatus = _NOT_ENTERED;
    }

    function _finishSettlementHook(uint256 id, StrategyProposal storage p) internal override returns (int256, uint256) {
        return _finishSettlement(id, p);
    }

    // ==================== PROPOSAL LIFECYCLE ====================

    /// @inheritdoc ISyndicateGovernor
    function propose(
        address vault,
        address strategy,
        string calldata metadataURI,
        uint256 strategyDuration,
        RiskEnvelope calldata envelope,
        BatchExecutorLib.Call[] calldata executeCalls,
        uint256[] calldata executeCallCaps,
        BatchExecutorLib.Call[] calldata settlementCalls,
        uint256[] calldata settlementCallCaps,
        CoProposer[] calldata coProposers
    ) external returns (uint256 proposalId) {
        if (vault != GovernorParameters.vault) revert VaultNotRegistered();
        if (!ISyndicateVault(vault).isAgent(msg.sender)) revert NotRegisteredAgent();
        // Blocks new proposals when the vault still has a non-terminal
        // lifecycle bound to it (Pending / GuardianReview / Approved / Executed).
        // Draft co-proposals do not count toward openProposalCount and are
        // independently gated at their Draft -> Pending transition.
        if (_openProposalCount != 0) revert VaultHasOpenProposal();
        if (strategyDuration > _params.maxStrategyDuration) revert StrategyDurationTooLong();
        if (strategyDuration < _params.minStrategyDuration) revert StrategyDurationTooShort();
        if (executeCalls.length == 0) revert EmptyExecuteCalls();
        if (settlementCalls.length == 0) revert EmptySettlementCalls();
        // Caps batch sizes. Kept HERE (not folded into `_validateAndStoreBatch`
        // below) to preserve the original check ORDER relative to
        // `MetadataURITooLong`/`ZeroMaxCapital`/`InvalidDrawdown` below — tests
        // pin which error fires first on a doubly-invalid proposal, and this
        // is pure `.length` arithmetic on params already read by the two
        // lines above, so it costs nothing extra on the stack budget (the
        // cap-array-specific checks, which DO need the new calldata params,
        // still live in the deferred helper).
        if (executeCalls.length > MAX_CALLS_PER_PROPOSAL || settlementCalls.length > MAX_CALLS_PER_PROPOSAL) {
            revert TooManyCalls();
        }
        // Reject any call in either array whose target the vault's
        // privileged-batch-target predicate flags (issue #118). Runs here,
        // bounded by the TooManyCalls cap above, before any state write or
        // state-changing external call (lockBond).
        _rejectPrivilegedTargets(vault, executeCalls, settlementCalls);
        // Caps metadata URI length.
        if (bytes(metadataURI).length > MAX_METADATA_URI_LENGTH) revert MetadataURITooLong();
        // Risk envelope: nonzero outflow ceiling, clamped to the maxCapitalBps
        // ceiling, drawdown declaration capped at 100%.
        if (envelope.maxCapital == 0) revert ZeroMaxCapital();
        // maxCapital ceiling is enforced in `_snapshotTierAndGate` below —
        // same tx, hoisted off this frame for Yul stack budget.
        if (envelope.maxDrawdownBps > 10_000) revert InvalidDrawdown();

        if (coProposers.length > 0) {
            _validateCoProposers(vault, coProposers);
        }

        proposalId = ++_proposalCount;

        // Per-call capital declarations (issue #43): validate AND store in
        // ONE early call so the `executeCallCaps`/`settlementCallCaps`
        // calldata refs die immediately after, instead of staying live
        // across the rest of this function — Yul stack-too-deep mitigation
        // (design.md Risks, "validate-while-storing"). A revert here rolls
        // back the `_proposalCount` increment above alongside everything
        // else, so ordering validation after it costs nothing. Never folded
        // into #118's `_rejectPrivilegedTargets` staticcall-probe loop
        // (design.md D6): different subject (capital vs targets), different
        // failure mode (this never degrades open; it depends on nothing
        // optional).
        _validateAndStoreBatch(
            proposalId, executeCalls, executeCallCaps, settlementCalls, settlementCallCaps, envelope.maxCapital
        );

        bool isCollaborative = coProposers.length > 0;

        // Review period defaults to zero when registry isn't wired; state machine
        // still works (voteEnd == reviewEnd → immediate transition to Approved).
        uint256 reviewPeriod_ = IGuardianRegistry(_guardianRegistry).reviewPeriod();

        // Sequential storage writes instead of struct literal to avoid Yul
        // stack-too-deep under the coverage config (optimizer/viaIR off).
        // votesFor / votesAgainst / votesAbstain / executedAt default to 0.
        StrategyProposal storage p = _proposals[proposalId];
        p.id = proposalId;
        p.proposer = msg.sender;
        p.vault = vault;
        p.strategy = strategy;
        p.metadataURI = metadataURI;
        p.performanceFeeBps =
            _clampPerformanceFee(proposalId, ISyndicateVault(vault).agentFeeBps(), _params.maxPerformanceFeeBps);
        p.strategyDuration = strategyDuration;
        // Risk envelope snapshot — immutable for this proposal's lifetime.
        // Sequential writes (not struct literal) per the stack-too-deep note above.
        p.maxCapital = envelope.maxCapital;
        p.maxDrawdownBps = envelope.maxDrawdownBps;
        // Snapshot protocol and guardian fee config at propose time so settlement
        // uses rates/recipients that voters actually saw, not a post-vote change.
        _snapshotFeeConfig(p);
        if (isCollaborative) {
            _transition(p, ProposalState.Draft);
            // Written HERE, not in `_storeCoProposers` (which runs after
            // `_snapshotTierAndGate`): `lockBond` is a state-changing external
            // call, and a WOOD with a transfer hook can re-enter the governor
            // mid-propose. A Draft observed with `collaborationDeadline == 0`
            // resolves to Expired (the base's `_computeState` Draft -> Expired
            // edge), which permissionless `resolveProposalState` would commit —
            // bricking the proposal (`approveCollaboration` then reverts
            // `NotDraftState` forever).
            collaborationDeadline[proposalId] = block.timestamp + _params.collaborationWindow;
            // Snapshot timing params for the collaborative Draft so the
            // Draft → Pending transition can't be moved by a mid-Draft owner
            // param change. Packed (executionWindow << 128 | votingPeriod).
            _draftTimingSnap[proposalId] =
                (uint256(uint128(_params.executionWindow)) << 128) | uint256(uint128(_params.votingPeriod));
            // Locks the vault at Draft creation: an unlocked Draft would let
            // an attacker deposit between propose and the final approve,
            // inflating the balance counted in the Pending snapshot.
            unchecked {
                ++_openProposalCount;
            }
        } else {
            _initPendingProposal(p, reviewPeriod_);
        }

        // Tier resolution: proposal tier = MAX tier across execute calls;
        // requiredCoverage (per-call SUM over execute AND settlement calls)
        // feeds the aggregate exposure cap. Resolved from the STORED calls
        // (via _loadCalls) rather than the calldata arrays so the
        // `envelope`/`executeCalls` calldata refs are dead by this point —
        // keeps propose() under Yul's stack budget. Reads the same storage
        // arrays re-resolved at execute time.
        _snapshotTierAndGate(p, _loadCalls(_executeCalls, proposalId));

        if (coProposers.length > 0) {
            _storeCoProposers(proposalId, coProposers);
        }

        _emitProposalCreated(proposalId, executeCalls.length, settlementCalls.length);
    }

    /// @inheritdoc ISyndicateGovernor
    function vote(uint256 proposalId, VoteType support) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        if (_commitState(proposal) != ProposalState.Pending) revert NotWithinVotingPeriod();
        if (_hasVoted[proposalId][msg.sender]) revert AlreadyVoted();

        // Vote weight from ERC20Votes checkpoint at proposal creation.
        uint256 weight = IVotes(proposal.vault).getPastVotes(msg.sender, proposal.snapshotTimestamp);
        if (weight == 0) revert NoVotingPower();

        _hasVoted[proposalId][msg.sender] = true;

        if (support == VoteType.For) {
            proposal.votesFor += weight;
        } else if (support == VoteType.Against) {
            proposal.votesAgainst += weight;
        } else {
            proposal.votesAbstain += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    /// @inheritdoc ISyndicateGovernor
    function executeProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];

        // Resolve state (may transition Pending->Approved/Rejected/Expired or Approved->Expired)
        if (_commitState(proposal) != ProposalState.Approved) revert ProposalNotApproved();

        address vault = proposal.vault;
        if (_activeProposal != 0) revert StrategyAlreadyActive();
        // Cooldown check (skip if no prior settlement)
        uint256 lastSettled = _lastSettledAt;
        if (lastSettled != 0 && block.timestamp < lastSettled + _params.cooldownPeriod) {
            revert CooldownNotElapsed();
        }

        // Snapshot vault balance before execution
        address asset = IERC4626(vault).asset();
        uint256 balanceBefore = IERC20(asset).balanceOf(vault);
        _capitalSnapshots[proposalId] = balanceBefore;

        // Update state BEFORE external call (CEI pattern)
        _activeProposal = proposalId;
        _transition(proposal, ProposalState.Executed);
        // INVARIANT (issue #35): THIS STAMP MUST PRECEDE THE
        // `requireApproveQuorum` GATE BELOW, IN THE SAME TRANSACTION. The
        // gate reads each approver's LIVE `slashableBondUsd`, which is sound
        // ONLY because every sWOOD stake mutation checkpoints at
        // `block.timestamp`, so the checkpoint at `executedAt` equals the
        // live stake the gate just read — the gate and the eventual verdict
        // slash (anchored at this same `executedAt` by `ChallengeGame`) are
        // then provably valuing the same WOOD. Move the gate out of this
        // transaction, or ahead of this line, and that equality stops being
        // structural and becomes an accident of call ordering.
        proposal.executedAt = block.timestamp;
        // Start the management-fee clock. Must follow `_activeProposal` so the
        // vault's `totalAssets()` reads live NAV through the now-active lane,
        // and must precede the execute batch so capital deployed by it is
        // picked up by the batch's own base-changing hooks rather than being
        // missed. Accrual runs from here to settle and nowhere else — the gap
        // between proposals is free.
        ISyndicateVault(vault).startManagementAccrual();
        // Counter stays incremented through Executed; decremented once on the
        // Executed -> Settled edge in `_finishSettlement`. `_activeProposal`
        // also guards the Executed window (see `requestUnstakeOwner`).

        // Load the stored execute calls once — reused by the tier re-resolve
        // and the vault batch below (single SLOAD-loop; cold path, no stack risk).
        BatchExecutorLib.Call[] memory calls = _loadCalls(_executeCalls, proposalId);

        // Fail-safe on stale certification. A proposal priced at tier 0/1
        // whose adapter demoted (codehash change, revocation) since propose
        // is under-covered — block execution rather than run a
        // possibly-unbounded batch against a bounded-tier coverage price.
        // Tier alone misses a same-tier re-certification with a higher
        // extractableBoundBps — also revert when the re-resolved coverage
        // exceeds the propose-time snapshot.
        (uint8 liveTier, uint256 liveCoverage) = _resolveTierAndCoverage(
            calls,
            _loadCaps(_executeCallCaps, proposalId),
            _loadCalls(_settlementCalls, proposalId),
            _loadCaps(_settlementCallCaps, proposalId),
            proposal.maxCapital,
            false
        );
        if (liveTier > proposal.envelopeTier) revert TierRegressed();
        if (liveCoverage > proposal.requiredCoverage) revert CoverageRegressed();

        // Fail-safe sibling to the two regression checks above (audit issue
        // #181 finding #9). The propose-time `_checkMaxCapitalCeiling` call
        // (via `_snapshotTierAndGate`) alone is NOT sufficient: it prices
        // `maxCapital` against `totalAssets()` at PROPOSE, and nothing stops
        // the proposer from inflating that denominator with its own deposit
        // right before proposing, then withdrawing the same deposit during
        // the 24h vote. The two capital locks read different counters —
        // `_depositsLocked()` (blocks new deposits) rises at PROPOSE via
        // `openProposalCount() != 0`, while `redemptionsLocked()` (blocks
        // withdrawals) rises only at EXECUTE via `getActiveProposal() != 0`
        // — so the proposer's own capital is free to leave in the gap,
        // shrinking the float the ceiling was computed against while
        // `maxCapital` itself stays pinned at its inflated-denominator value.
        // Re-running the identical ratio check here, against LIVE
        // `totalAssets()`, immediately before the batch is dispatched,
        // closes that window. Distinct revert from the propose-time
        // `MaxCapitalExceedsCeiling` so the two are never conflated off-chain.
        if (proposal.maxCapital > _capitalCeiling()) revert MaxCapitalCeilingRegressed();

        // A coverage-consuming proposal at/above the tier threshold cannot
        // execute without a bond-encumbered approve quorum: silence alone no
        // longer passes it, so an identified, stake-backed approver is always
        // on the hook. Every tier is fail-closed, not tier 2 alone. A revert
        // here leaves the proposal Approved — it expires at `executeBy`
        // unless covering approvals arrive first, so suppressing the cohort
        // blocks execution without forcing cancellation.
        //
        // RUNS AFTER `proposal.executedAt = block.timestamp` ABOVE, IN THE
        // SAME TRANSACTION — load-bearing (issue #35, see the stamp's own
        // note). This gate's live read is what makes it sound to leave
        // every OTHER post-execution ledger read (`allocatedUsd`,
        // `liabilityUsd`, `settleCoverage`) anchored at `executedAt` instead:
        // the two are provably equal at this one instant. Hoisted into
        // `_deriveAndStoreEffectiveCapital` (an INTERNAL call, so the
        // invariant's "same transaction" reach is unaffected) purely for
        // this function's own Yul stack budget — every OTHER `SyndicateGovernor.sol`
        // stack-budget note in this file hoists for the identical reason.
        // Derives and stores `effectiveMaxCapital` (issue #27 design D3-D5)
        // from the gate's raised-vs-required coverage figures — `maxCapital`
        // unchanged when the gate does not run (no ledger wired, zero
        // `requiredCoverage`, or tier below the quorum threshold; issue #43's
        // all-zero-cap proposals legitimately reach here ungated, since the
        // per-call meter already enforces zero extractable value) — and
        // scales the stored per-call caps (issue #43) by the same factor,
        // persisting the scaled settlement caps for `settleProposal` to reuse
        // byte-identical, however much later it runs.
        uint256[] memory scaledExecuteCaps =
            _deriveAndStoreEffectiveCapital(proposalId, proposal, _exposureLedger, asset);

        // Execute the opening calls via the vault. The risk envelope's
        // effective capital (issue #27's coverage-proportional ceiling,
        // `maxCapital` whenever coverage was full or the gate did not run)
        // caps the batch's net asset outflow (batch-level); the
        // coverage-scaled per-call caps (issue #43) additionally bound each
        // call's own gross outflow (BatchExecutorLib-level) — two distinct
        // accounting layers, both mandatory on this path (design.md D4).
        ISyndicateVault(vault).executeGovernorBatch(calls, scaledExecuteCaps, proposal.effectiveMaxCapital);

        emit ProposalExecuted(proposalId, vault, balanceBefore);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @notice Settle a strategy. Proposer can settle at any time; anyone else must wait for duration.
    function settleProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_commitState(proposal) != ProposalState.Executed) revert ProposalNotExecuted();

        uint256 minWait =
            msg.sender == proposal.proposer ? MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE : proposal.strategyDuration;
        if (block.timestamp < proposal.executedAt + minWait) {
            revert StrategyDurationNotElapsed();
        }

        // Run the pre-committed settlement calls under the SAME effective
        // capital cap execution ran under (issue #27 design D4) — reused
        // from storage, NEVER recomputed, so a coverage drop between execute
        // and settle (a guardian withdrawing, or slashed on an unrelated
        // proposal) cannot cap the unwind below the size legitimately
        // deployed at execution. An honest unwind is net-INFLOW (netOutflow
        // == 0), so any finite cap passes it trivially — the cap only binds
        // a malicious proposer who parked extraction in settlementCalls to
        // self-settle after 1h and drain uncapped. The PERSISTED, coverage-
        // scaled per-call settlement caps (issue #43 x #27 design D7)
        // additionally bound each settlement call's own gross outflow —
        // extraction parked in a single settlement call is bounded per call,
        // not only by the batch-level effective capital.
        ISyndicateVault(proposal.vault)
            .executeGovernorBatch(
                _loadCalls(_settlementCalls, proposalId),
                _loadCaps(_effectiveSettlementCallCaps, proposalId),
                proposal.effectiveMaxCapital
            );

        _finishSettlement(proposalId, proposal);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Proposer abandonment is allowed at any pre-execute stage. Symmetric
    ///      with `settleProposal` (proposer-anytime), which already lets the
    ///      proposer abandon mid-strategy at no penalty. Cancel-Approved /
    ///      cancel-GuardianReview are strictly less harmful than early settle —
    ///      no capital was deployed, no fees accrued. Cancel during
    ///      GuardianReview drives the registry's `cancelReview` so a stale
    ///      `resolveReview` after `reviewEnd` cannot still slash approvers
    ///      (registry cancelReview reverts after reviewEnd, mirroring
    ///      cancelEmergency — proposer must commit at that point).
    ///      `_lastSettledAt` is bumped on every cancel branch that decrements
    ///      the open count, rate-limiting propose-cancel-propose-execute via
    ///      the same cooldown that gates execute after a successful settle.
    function cancelProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (msg.sender != proposal.proposer) revert NotProposer();
        ProposalState s = _commitState(proposal);
        if (s == ProposalState.Pending) {
            // Pending: only during the voting period.
            if (block.timestamp > proposal.voteEnd) revert ProposalNotCancellable();
            // The review was registered at the Draft -> Pending transition, so
            // it must be closed here too — otherwise a keeper opens it at
            // `voteEnd` and guardians are slashed for approving a proposal that
            // is already Cancelled. Best-effort (see `_closeReviewIfRegistered`);
            // in this branch `block.timestamp <= voteEnd < reviewEnd` and the
            // review cannot yet be open, so it takes the never-opened path.
            _closeReviewIfRegistered(proposal);
            _decOpen();
        } else if (s == ProposalState.GuardianReview) {
            // Close the registry-side review BEFORE marking the proposal
            // Cancelled. Registry reverts the cancelReview if reviewEnd has
            // already elapsed — bubbles up here as the cancel-window closer.
            IGuardianRegistry(_guardianRegistry).cancelReview(proposalId);
            _decOpen();
        } else if (s == ProposalState.Approved) {
            // Approved means review already resolved as not-blocked. No
            // registry cleanup needed — slashing path is closed.
            _decOpen();
        } else if (s == ProposalState.Draft) {
            // Blocks lead cancel once all-but-one co-prop has approved,
            // preventing a front-run of the final approve tx. A single
            // co-proposer Draft (total == 1) stays cancellable — "all but one"
            // is zero approvals there, which must not lock the lead out.
            // Shared with `rejectCollaboration`'s IDENTICAL Draft -> Cancelled
            // transition (audit issue #181 finding #16) so the two lead-abort
            // paths can never drift apart.
            _requireNotNearQuorum(proposalId);
            // Draft binds the vault — decrement on cancel.
            _decOpen();
        } else {
            revert ProposalNotCancellable();
        }
        _transition(proposal, ProposalState.Cancelled);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Draft/Pending only — once a proposal reaches
    ///      GuardianReview or later, the guardian cohort and execution window
    ///      drive resolution and the owner loses unilateral cancel authority.
    function emergencyCancel(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        _requireVaultOwner(proposal.vault);
        ProposalState s = _commitState(proposal);
        // BOTH Draft and Pending increment the open count, so BOTH must
        // decrement on cancel — otherwise a cancelled Draft soft-locks the
        // vault (every later propose reverts VaultHasOpenProposal).
        if (s != ProposalState.Pending && s != ProposalState.Draft) revert ProposalNotCancellable();
        // Pending carries a registered review (Draft does not — the window is
        // pushed on the Draft -> Pending transition, and the guard inside
        // `_closeReviewIfRegistered` no-ops for the Draft case).
        _closeReviewIfRegistered(proposal);
        _decOpen();
        _transition(proposal, ProposalState.Cancelled);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // `_decOpen()` and `openProposalCount()` are inherited from
    // ProposalLifecycle (single chokepoint: `_decOpen` decrements the counter
    // AND stamps `_lastSettledAt` so the permissionless lazy terminal path via
    // `resolveProposalState` can't dodge the settle cooldown).

    /// @inheritdoc ISyndicateGovernor
    /// @dev Single reclaim entrypoint for all terminal paths (settle / cancel
    ///      / expiry / emergency) rather than a hook in each. Permissionless
    ///      is safe because `releaseBond` always pays the proposer recorded
    ///      at lock time — a caller can only accelerate the refund, never
    ///      redirect it.
    ///
    ///      Rejected / Expired / Cancelled release immediately: those
    ///      proposals never executed, so there is nothing a challenge could
    ///      allege.
    ///
    ///      A bond already confiscated by a conviction is acknowledged, not
    ///      reverted: `ProposerBondEscrow.forfeitBond` deletes the escrow
    ///      record without touching this proposal's `proposerBondWood`, so a
    ///      forfeited bond would otherwise pass every gate below and die
    ///      forever in the escrow's `NoBond`. Detected by reading the pinned
    ///      escrow's `bondOf` — the governor still records a bond but the
    ///      escrow holds none for this key — and handled BEFORE the
    ///      executed-proposal gates (a forfeited bond has no window left to
    ///      wait out): zero `proposerBondWood`, emit
    ///      `ProposerBondForfeitureAcknowledged`, return without transferring.
    ///      A second call then hits the ordinary `NoBondToReclaim` path, the
    ///      same terminal answer as after a normal release.
    ///
    ///      Settled proposals wait `challengeWindow` after `executedAt`, and
    ///      only release while the ledger's per-proposal coverage freeze is
    ///      clear — a proposer who executes a drain and self-settles within
    ///      `MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE` cannot walk away with
    ///      the bond before `ChallengeGame` can confiscate it. Checking both
    ///      elapsed time AND the freeze matters because a late filing can
    ///      convict after `challengeWindow` has passed on its own.
    ///
    ///      Elapsed time and the freeze are not sufficient on their own: the
    ///      adversary is a proposer racing an `Inconclusive` unwind's re-armed
    ///      window. `ChallengeGame._refundAll` releases the coverage freeze AND
    ///      raises `challengeableUntil[reviewKey]` to
    ///      `block.timestamp + challengeWindow` in the same call, so between
    ///      that unwind and the re-armed deadline both gates above are open
    ///      while a conviction — and with it `forfeitBond` — is still
    ///      reachable. The third gate therefore asks the game itself and
    ///      mirrors `ChallengeGame.file`'s own deadline,
    ///      `max(executedAt + game.challengeWindow(), challengeableUntil[rk])`.
    ///      All three gates run against `proposal.proposerBondLedger`, the
    ///      ledger PINNED at propose time (falling back to the live
    ///      `_exposureLedger` slot only for a pre-pin proposal that recorded
    ///      no ledger) — never the live slot directly. The escrow pointer was
    ///      already pinned per proposal; the ledger now is too, so a factory
    ///      re-point of `_exposureLedger` after this proposal settles (the
    ///      `_openProposalCount` guard on `setExposureLedger` no longer holds
    ///      by then) cannot detach these gates from a still-convictable
    ///      challenge.
    ///      Reading the game's window rather than only `challengeableUntil`
    ///      also covers the ledger owner lowering the LEDGER's window below the
    ///      game's, which nothing on the game side prevents.
    ///
    ///      Strict `>`: `file` admits while `block.timestamp <= deadline`, so
    ///      at the deadline itself a filing is still legal and reclaim must
    ///      still refuse.
    ///
    ///      Skipped entirely when the ledger's `coverageFreezer` is unset. With
    ///      no freezer, `ExposureLedger.freezeCoverage` (onlyFreezer) can never
    ///      fire and `ProposerBondEscrow.forfeitBond` (caller must BE the
    ///      freezer) can never collect, so no conviction is reachable and there
    ///      is nothing for this gate to protect; an unwired or rotated-away
    ///      freezer must not strand an honest proposer's bond. A non-zero
    ///      freezer that REVERTS or cannot be read fails closed — recover by
    ///      rotating `coverageFreezer` ON THE PINNED LEDGER (its owner-side
    ///      surface, e.g. `ExposureLedger.setCoverageFreezer`); re-pointing
    ///      this governor's live `_exposureLedger` slot no longer reaches an
    ///      already-locked bond's gates. Note the asymmetry: a freezer that
    ///      ANSWERS zero passes rather than failing closed, so "fails closed"
    ///      covers unreadability, not every unhelpful answer — whether that
    ///      should also fail closed is an open, separately-tracked decision;
    ///      the forfeiture-acknowledge path above is the fix for the
    ///      indistinguishable-permanent-revert half of the same finding. Note
    ///      `challengeableUntil` is zero for an untouched key and zero is not
    ///      a sentinel, so an unchallenged proposal still reclaims on the
    ///      ordinary schedule.
    ///
    ///      Releases against `proposal.proposerBondEscrow` (bound at propose),
    ///      NOT the live `_bondEscrow` slot: the escrow has no owner and no
    ///      discretionary exit, and its bond key is (governor, proposalId), so
    ///      releasing against a re-pointed slot would strand the WOOD forever.
    function reclaimProposerBond(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        ProposalState s = _commitState(proposal);
        if (
            s != ProposalState.Rejected && s != ProposalState.Expired && s != ProposalState.Cancelled
                && s != ProposalState.Settled
        ) {
            revert ProposalNotTerminal();
        }
        uint256 bond = proposal.proposerBondWood;
        if (bond == 0) revert NoBondToReclaim();
        address escrow = proposal.proposerBondEscrow;
        // Forfeiture acknowledge (issue #117 L1): the governor still records
        // a bond, but a conviction already made `forfeitBond` delete the
        // escrow's record for this key. `bondOf` reports (proposer, amount);
        // amount == 0 here is exact — the only two record-deleting exits are
        // this reclaim's own release (which zeroes proposerBondWood in the
        // same transaction) and forfeiture, so the half-state where the
        // escrow is empty but proposerBondWood is still nonzero can only mean
        // forfeiture. Handled before the window gates: a forfeited bond has
        // nothing left to wait out, and gate 3 below could otherwise revert
        // ChallengeWindowOpen for a bond that no longer exists.
        (, uint256 held) = IProposerBondEscrow(escrow).bondOf(address(this), proposalId);
        if (held == 0) {
            proposal.proposerBondWood = 0;
            emit ProposerBondForfeitureAcknowledged(proposalId, bond);
            return;
        }
        // The challenge-window hold, for EXECUTED proposals only. Ordered after
        // the `bond == 0` check so a proposal that never posted a bond still
        // reports `NoBondToReclaim` rather than being told to wait for a window
        // it has nothing at stake in.
        uint256 executedAt = proposal.executedAt;
        if (executedAt != 0) {
            // Pinned at propose time (issue #116): a factory re-point of the
            // live `_exposureLedger` slot after this proposal locked its bond
            // must not change which ledger these gates read. Zero pin means a
            // pre-upgrade proposal that recorded no ledger — fall back to the
            // live slot so it keeps its exact pre-pin behavior.
            address ledger = proposal.proposerBondLedger;
            if (ledger == address(0)) ledger = _exposureLedger;
            // Fails closed: fail-open would let the factory (`onlyFactory` on
            // `setExposureLedger` — a protocol-level actor, not this vault's
            // own owner) bypass this delay in one transaction via
            // `setExposureLedger(0)`. The freeze cannot strand the bond
            // permanently — rotating the pinned ledger's own
            // `coverageFreezer` makes it reclaimable again.
            if (ledger == address(0)) revert ExposureLedgerUnset();
            if (block.timestamp < executedAt + IExposureLedger(ledger).challengeWindow()) {
                revert ChallengeWindowOpen();
            }
            if (IExposureLedger(ledger).isCoverageFrozen(address(this), proposalId)) {
                revert ChallengeWindowOpen();
            }
            // Gate 3: the game's LIVE filing deadline. See the natspec above
            // for why the two gates above are not sufficient on their own.
            address freezer = IExposureLedger(ledger).coverageFreezer();
            if (freezer != address(0)) {
                uint256 deadline = executedAt + IChallengeGame(freezer).challengeWindow();
                // Same review-key derivation as `ChallengeGame._reviewKey`
                // (abi.encode, not encodePacked).
                uint256 extended =
                    IChallengeGame(freezer).challengeableUntil(keccak256(abi.encode(address(this), proposalId)));
                if (extended > deadline) deadline = extended;
                // Strict: `file` still admits at `block.timestamp == deadline`.
                if (block.timestamp <= deadline) revert ChallengeWindowOpen();
            }
        }
        // Effects before interaction: zeroing first makes the reclaim
        // idempotent (a second call reverts NoBondToReclaim) and closes any
        // re-entrant double-release through a hooked WOOD.
        proposal.proposerBondWood = 0;
        IProposerBondEscrow(escrow).releaseBond(proposalId);

        // Best-effort settleCoverage self-trigger (issue #33, design D1):
        // this is the backstop that IS provably past `executeBy` for every
        // executed proposal (the challenge-window math guarantees it — see
        // `_settleCoverageBestEffort`'s natspec), so it collapses the
        // reservations an early settlement-time trigger had to skip.
        // Successful-release path only — never on the forfeiture-acknowledge
        // early return above, whose conviction already reprices the cohort
        // through the slash machinery.
        _settleCoverageBestEffort(proposalId, proposal);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Pending only — post-vote veto flows through the
    ///      guardian-review path rather than unilateral owner action.
    function vetoProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        _requireVaultOwner(proposal.vault);
        if (_commitState(proposal) != ProposalState.Pending) revert ProposalNotCancellable();
        _transition(proposal, ProposalState.Rejected);
        // Same registered-review cleanup as the Pending branch of
        // `cancelProposal`: a vetoed proposal can never execute, so its review
        // must not stay open for a keeper to slash its approvers on.
        _closeReviewIfRegistered(proposal);
        // `_activeProposal` is unset during Pending (only set by execute).
        _decOpen();
        emit ProposalVetoed(proposalId, msg.sender);
    }

    // ==================== COLLABORATIVE PROPOSALS ====================

    /// @inheritdoc ISyndicateGovernor
    function approveCollaboration(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        ProposalState storedState = proposal.state;
        ProposalState state = _commitState(proposal);
        // Give a specific error for expired collaboration windows
        if (state != ProposalState.Draft) {
            if (storedState == ProposalState.Draft && block.timestamp > collaborationDeadline[proposalId]) {
                revert CollaborationExpired();
            }
            revert NotDraftState();
        }

        _requireCoProposer(proposalId);
        if (!ISyndicateVault(proposal.vault).isAgent(msg.sender)) revert NotRegisteredAgent();
        if (coProposerApprovals[proposalId][msg.sender]) revert AlreadyApproved();

        coProposerApprovals[proposalId][msg.sender] = true;
        unchecked {
            ++_approvedCount[proposalId];
        }
        emit CollaborationApproved(proposalId, msg.sender);

        if (_approvedCount[proposalId] == _coProposers[proposalId].length) {
            // Blocks Draft -> Pending if the vault already has ANOTHER
            // non-terminal proposal bound to it. The *own* Draft is already
            // in the count — "> 1" keeps the semantics "another (non-self)
            // open proposal blocks the transition".
            if (_openProposalCount > 1) revert VaultHasOpenProposal();
            uint256 reviewPeriod_ = IGuardianRegistry(_guardianRegistry).reviewPeriod();
            _transition(proposal, ProposalState.Pending);
            // -1: see propose().
            proposal.snapshotTimestamp = block.timestamp - 1;
            // Timing comes from the propose-time snapshot, not live
            // `_params.*`. Single SLOAD; bit-shift to unpack.
            uint256 packed = _draftTimingSnap[proposalId];
            proposal.voteEnd = block.timestamp + uint128(packed); // low 128 = votingPeriod
            proposal.reviewEnd = proposal.voteEnd + reviewPeriod_;
            proposal.executeBy = proposal.reviewEnd + (packed >> 128); // high 128 = executionWindow
            // vetoThresholdBps reads live by design — the owner trust model
            // covers a mid-Draft shift.
            proposal.vetoThresholdBps = _params.vetoThresholdBps;
            // The Draft already incremented _openProposalCount at propose
            // time — do NOT re-increment here.
            // Push the review window to the registry so it can resolve the
            // guardian review without calling back. Guarded on
            // `reviewEnd > voteEnd`: when `reviewPeriod == 0` (registry not
            // wired / unit-test mock) `reviewEnd == voteEnd` and the registry
            // would revert `InvalidReviewWindow` — the base's `_afterVote`
            // treats that collapsed window as cleared.
            // LOAD-BEARING: this predicate must stay identical to the one
            // `_afterVote` tests. A proposal that gets past it there without
            // having been registered here auto-approves with no guardian
            // review — see the SECURITY INVARIANT in `ProposalLifecycle`.
            if (proposal.reviewEnd > proposal.voteEnd) {
                IGuardianRegistry(_guardianRegistry).registerReview(proposalId, proposal.voteEnd, proposal.reviewEnd);
            }
            emit CollaborationTransitionedToPending(proposalId);
        }
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Same Draft -> Cancelled transition, by the same actor
    ///      (`proposal.proposer == msg.sender`), as `cancelProposal`'s Draft
    ///      branch — gated by the identical `_requireNotNearQuorum` guard
    ///      (audit issue #181 finding #16). Without it, a lead near quorum
    ///      could dodge `cancelProposal`'s `CancelNotAllowedNearQuorum` by
    ///      calling this entrypoint instead, keeping a free last-instant
    ///      abort and burning co-proposers' approve gas at will.
    function rejectCollaboration(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_commitState(proposal) != ProposalState.Draft) revert NotDraftState();

        // Lead-only. A dissenting co-proposer simply withholds approval (the
        // Draft lapses at the collaboration window).
        if (proposal.proposer != msg.sender) revert NotLeadProposer();

        _requireNotNearQuorum(proposalId);

        _transition(proposal, ProposalState.Cancelled);
        // Draft binds the vault — decrement on reject.
        _decOpen();
        emit CollaborationRejected(proposalId, msg.sender);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ==================== VAULT MANAGEMENT ====================

    /// @notice Permissionless: flushes a proposal's lazy terminal-state
    ///         transition (Rejected / Expired) so that
    ///         `_openProposalCount` dec commits.
    /// @dev `_commitState` dec's the counter when it transitions the proposal
    ///      into a terminal state, but each mutating caller (`vote`,
    ///      `executeProposal`, `settleProposal`, `cancelProposal`,
    ///      `emergencyCancel`, `vetoProposal`, collaborative approve/reject)
    ///      reverts if the resolved state isn't in its allow-list, rolling
    ///      back the dec. Without this flush, a vote that pushes
    ///      `votesAgainst` past `vetoThresholdBps` or an approved-but-
    ///      unexecuted proposal past `executeBy` would pin the counter at 1,
    ///      bricking future `propose()` (VaultHasOpenProposal) and owner
    ///      `requestUnstakeOwner` (which also OR-checks `openProposalCount`).
    ///      Idempotent: re-calling after the transition has already committed
    ///      is a no-op.
    function resolveProposalState(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        _commitState(proposal);
    }

    // ==================== VIEWS ====================

    /// @inheritdoc ISyndicateGovernor
    function getProposal(uint256 proposalId) external view returns (StrategyProposal memory p) {
        p = _proposals[proposalId];
        // Overwrite the returned memory copy's state with the authoritative
        // resolved value (tuple-destructure into the memory field — this is a
        // returned-struct copy, not the storage single-writer path).
        (p.state,) = _computeState(_proposals[proposalId]);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Delegates to the base `stateOf` so the interface accessor and the
    ///      authoritative resolver can never drift.
    function getProposalState(uint256 proposalId) external view returns (ProposalState) {
        return stateOf(proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getExecuteCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        return _loadCalls(_executeCalls, proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getSettlementCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        return _loadCalls(_settlementCalls, proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getCallCaps(uint256 proposalId)
        external
        view
        returns (uint256[] memory executeCallCaps, uint256[] memory settlementCallCaps)
    {
        executeCallCaps = _loadCaps(_executeCallCaps, proposalId);
        settlementCallCaps = _loadCaps(_settlementCallCaps, proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getVoteWeight(uint256 proposalId, address voter) external view returns (uint256) {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        // Draft proposals have snapshotTimestamp == 0, so reading
        // getPastVotes would silently return 0. Revert instead.
        if (proposal.snapshotTimestamp == 0) revert ProposalInDraft();
        return IVotes(proposal.vault).getPastVotes(voter, proposal.snapshotTimestamp);
    }

    /// @inheritdoc ISyndicateGovernor
    function hasVoted(uint256 proposalId, address voter) external view returns (bool) {
        return _hasVoted[proposalId][voter];
    }

    /// @inheritdoc ISyndicateGovernor
    function proposalCount() external view returns (uint256) {
        return _proposalCount;
    }

    /// @inheritdoc ISyndicateGovernor
    function getActiveProposal() external view returns (uint256) {
        return _activeProposal;
    }

    /// @inheritdoc ISyndicateGovernor
    function getCooldownEnd() external view returns (uint256) {
        return _lastSettledAt + _params.cooldownPeriod;
    }

    /// @inheritdoc ISyndicateGovernor
    function getCapitalSnapshot(uint256 proposalId) external view returns (uint256) {
        return _capitalSnapshots[proposalId];
    }

    /// @inheritdoc ISyndicateGovernor
    function getCoProposers(uint256 proposalId) external view returns (CoProposer[] memory) {
        return _coProposers[proposalId];
    }

    /// @inheritdoc ISyndicateGovernor
    function getRiskEnvelope(uint256 proposalId) external view returns (uint256 maxCapital, uint16 maxDrawdownBps) {
        StrategyProposal storage p = _proposals[proposalId];
        return (p.maxCapital, p.maxDrawdownBps);
    }

    /// @inheritdoc ISyndicateGovernor
    function getEffectiveMaxCapital(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].effectiveMaxCapital;
    }

    /// @inheritdoc ISyndicateGovernor
    function guardianRegistry() external view returns (address) {
        return _guardianRegistry;
    }

    /// @inheritdoc ISyndicateGovernor
    function tierRegistry() external view returns (address) {
        return _tierRegistry;
    }

    /// @inheritdoc ISyndicateGovernor
    function exposureLedger() external view returns (address) {
        return _exposureLedger;
    }

    /// @inheritdoc ISyndicateGovernor
    function bondEscrow() external view returns (address) {
        return _bondEscrow;
    }

    /// @inheritdoc ISyndicateGovernor
    function getProposalTier(uint256 proposalId) external view returns (uint8) {
        return _proposals[proposalId].envelopeTier;
    }

    /// @inheritdoc ISyndicateGovernor
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].requiredCoverage;
    }

    /// @notice Strategy adapter of a proposal (address(0) = none / opted out of
    ///         live NAV). Scalar seam for the vault — replaces the vault's
    ///         full-struct getProposal read.
    function strategyOf(uint256 proposalId) external view returns (address) {
        return _proposals[proposalId].strategy;
    }

    /// @notice Narrow proposal view: (`voteEnd`, `reviewEnd`, `vault`, ...,
    ///         `executedAt`).
    /// @dev The guardian registry no longer calls this (it reads its own
    ///      pushed `reviewWindow` and `vaultOf`), but `ExposureLedger` reads
    ///      `.vault` through this getter on the approve-vote path, and reads
    ///      `.executedAt` on every post-execution coverage read to anchor a
    ///      guardian's slashable-stake basis (issue #35;
    ///      `IStakedWood.slashableStakeAt`). Do not remove until those
    ///      consumers migrate.
    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory v) {
        StrategyProposal storage p = _proposals[proposalId];
        v.voteEnd = p.voteEnd;
        v.reviewEnd = p.reviewEnd;
        v.vault = p.vault;
        // `executeBy + strategyDuration` bounds the LATEST instant this proposal
        // can still be settling, which is what the exposure ledger sizes a
        // guardian's commitment against. Read at approve time, before
        // execution has happened, so `executeBy` is the conservative anchor —
        // `executedAt` is not known yet and may never be set.
        v.executeBy = p.executeBy;
        v.strategyDuration = p.strategyDuration;
        // 0 until `executeProposal` stamps it (see the invariant note at that
        // assignment). `ExposureLedger` treats 0 as "no anchor yet — read
        // live", exactly matching what a not-yet/never-executed proposal
        // means for a verdict that cannot exist.
        v.executedAt = p.executedAt;
    }

    /// @dev Narrow proposal tuple returned by `getProposalView`. Memory-only
    ///      — this struct is never stored, so appending `executedAt` is an
    ///      ABI extension with no storage-layout effect (issue #35).
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
        uint256 executedAt;
    }

    // ==================== INTERNAL ====================

    /// @dev Hoisted out of `propose` to keep that function under Yul's
    ///      stack budget when `forge coverage` runs (optimizer + viaIR off).
    ///      Reads `vault` from storage (already written by caller) to keep
    ///      the call-site arg count to two.
    function _initPendingProposal(StrategyProposal storage p, uint256 reviewPeriod_) private {
        // -1 closes the same-block flash-delegate window.
        p.snapshotTimestamp = block.timestamp - 1;
        p.voteEnd = block.timestamp + _params.votingPeriod;
        p.reviewEnd = p.voteEnd + reviewPeriod_;
        p.executeBy = p.reviewEnd + _params.executionWindow;
        _transition(p, ProposalState.Pending);
        // Snapshots vetoThresholdBps so a mid-vote timelock finalize can't
        // retroactively move the threshold for this proposal.
        p.vetoThresholdBps = _params.vetoThresholdBps;
        // Draft doesn't count (not binding on the vault); Pending does.
        unchecked {
            ++_openProposalCount;
        }
        // Push the review window to the registry so it can resolve the guardian
        // review without a call-back. Guarded on `reviewEnd > voteEnd`: with
        // `reviewPeriod == 0` (registry not wired / unit-test mock) the window
        // collapses and the registry would revert `InvalidReviewWindow` — the
        // base's `_afterVote` treats that collapsed window as cleared.
        // LOAD-BEARING: this predicate must stay identical to the one
        // `_afterVote` tests. A proposal that gets past it there without having
        // been registered here auto-approves with no guardian review — see the
        // SECURITY INVARIANT in `ProposalLifecycle`.
        if (p.reviewEnd > p.voteEnd) {
            IGuardianRegistry(_guardianRegistry).registerReview(p.id, p.voteEnd, p.reviewEnd);
        }
    }

    /// @dev Shared ratio: `maxCapitalBps` (governor param, default 100%) of
    ///      the vault's LIVE `totalAssets()`. Both call sites below re-derive
    ///      this from live state rather than a snapshot, so they only differ
    ///      in WHEN they run and WHICH error they revert with.
    function _capitalCeiling() private view returns (uint256) {
        return (IERC4626(GovernorParameters.vault).totalAssets() * maxCapitalBps()) / BPS_DENOMINATOR;
    }

    /// @dev Propose-time half of the maxCapital ceiling. Without it, a
    ///      proposer declares maxCapital = uint256.max and the net-outflow
    ///      cap (vault-enforced on execute AND settlement batches) never
    ///      binds. Hoisted out of `propose` to stay under Yul's stack budget
    ///      (see `_initPendingProposal`); reads the vault from storage
    ///      (validated == the propose arg at the top of `propose`) for the
    ///      same reason — one fewer stack slot.
    ///
    ///      NOT sufficient on its own (audit issue #181 finding #9): this
    ///      check prices `maxCapital` against `totalAssets()` at PROPOSE, and
    ///      the vault's two capital locks read different counters —
    ///      deposits are blocked from `openProposalCount() != 0` (set here,
    ///      at propose), but redemptions are blocked only from
    ///      `getActiveProposal() != 0` (set later, at execute). A proposer
    ///      can inflate `totalAssets()` with its own deposit immediately
    ///      before proposing, pass this gate, then withdraw that same
    ///      deposit during the vote — shrinking the float this ratio was
    ///      computed against while `maxCapital` stays pinned at its
    ///      inflated-denominator value. `executeProposal` re-runs the same
    ///      `_capitalCeiling()` ratio against live totals immediately before
    ///      dispatch (`MaxCapitalCeilingRegressed`) to close that window —
    ///      see the natspec there.
    function _checkMaxCapitalCeiling(uint256 maxCapital) private view {
        if (maxCapital > _capitalCeiling()) revert MaxCapitalExceedsCeiling();
    }

    /// @dev Propose-time half of issue #118's fix: rejects any target in
    ///      EITHER call array that the vault's own privileged-batch-target
    ///      predicate flags (the vault itself, or its bound withdrawal
    ///      queue) — the SAME predicate `_guardBatchCalls` enforces at
    ///      execute/settle time (`isPrivilegedBatchTarget`, single-sourced
    ///      on the vault so this check cannot drift from it). Denylist half
    ///      ONLY: the registry-gated selector half of the vault's guard
    ///      depends on mutable, even codehash-sensitive, state
    ///      (`isAdapterAllowed`) and would prove nothing about settle time —
    ///      deliberately not evaluated here (design.md, issue #118).
    ///
    ///      Consumed via staticcall as a capability probe, mirroring the
    ///      vault's own `tierRegistry()` staticcall pattern in
    ///      `_guardBatchCalls`: a failed or malformed call (a vault that
    ///      predates this view) degrades OPEN — propose must never brick on
    ///      a fail-early check. `executeGovernorBatch`'s guard remains the
    ///      authoritative enforcement on every batch path regardless of
    ///      whether this check ran, degraded open, or was skipped.
    function _rejectPrivilegedTargets(
        address vault_,
        BatchExecutorLib.Call[] calldata executeCalls_,
        BatchExecutorLib.Call[] calldata settlementCalls_
    ) private view {
        // Capability probe: address(0) is never a privileged target, so this
        // call's SUCCESS (not its result) is what gates the loop below.
        (bool ok, bytes memory ret) =
            vault_.staticcall(abi.encodeCall(ISyndicateVault.isPrivilegedBatchTarget, (address(0))));
        if (!ok || ret.length != 32) return;

        for (uint256 i = 0; i < executeCalls_.length; i++) {
            _revertIfPrivilegedTarget(vault_, executeCalls_[i].target);
        }
        for (uint256 i = 0; i < settlementCalls_.length; i++) {
            _revertIfPrivilegedTarget(vault_, settlementCalls_[i].target);
        }
    }

    /// @dev staticcall (not a typed call) so a vault that stops answering
    ///      mid-loop (it cannot: the probe above already proved it exists,
    ///      and this is a `view` in the same tx) still degrades open rather
    ///      than reverting propose for an unrelated reason.
    function _revertIfPrivilegedTarget(address vault_, address target) private view {
        (bool ok, bytes memory ret) =
            vault_.staticcall(abi.encodeCall(ISyndicateVault.isPrivilegedBatchTarget, (target)));
        if (ok && ret.length == 32 && abi.decode(ret, (bool))) {
            revert ISyndicateVault.DisallowedBatchTarget(target);
        }
    }

    /// @dev Propose-time cap-array validation AND storage of BOTH the calls
    ///      and the caps, combined into ONE call (issue #43). Combined
    ///      deliberately: `propose`'s Yul stack budget is documented at the
    ///      edge, and two new calldata array params tipped it over even after
    ///      the validate-and-store-caps-together mitigation alone (design.md
    ///      Risks). Folding `_storeCalls` in here too means `executeCalls`/
    ///      `settlementCalls`/`executeCallCaps`/`settlementCallCaps` are ALL
    ///      referenced only within this one early call — called right after
    ///      `proposalId` is minted — instead of staying live stack slots
    ///      across the rest of `propose`'s body (calls previously lived until
    ///      a separate `_storeCalls` call much later). No external calls, no
    ///      degrading — sibling to (never folded into) #118's
    ///      `_rejectPrivilegedTargets` staticcall-probe loop (design.md D6).
    ///      Checks, in order:
    ///        1. Each cap array's length equals its call array's length
    ///           (`CallCapsLengthMismatch`) — every call must declare exactly
    ///           one cap.
    ///        2. `Σ executeCallCaps <= maxCapital` AND
    ///           `Σ settlementCallCaps <= maxCapital`, evaluated PER BATCH,
    ///           never combined (`CallCapsExceedMaxCapital`) — the execute and
    ///           settlement batches run in separate transactions, each
    ///           independently bounded by the vault's `maxCapital` net-outflow
    ///           meter, so requiring the COMBINED sum under `maxCapital` would
    ///           halve every proposal's settlement budget for no safety gain.
    ///      Overflow is a non-issue: `cap_i <= maxCapital <= totalAssets()`
    ///      and each array is bounded by `MAX_CALLS_PER_PROPOSAL` (checked
    ///      just above this helper's call site). Only reverts BEFORE any
    ///      storage write in this function is committed — a revert here
    ///      still rolls back the `_proposalCount` bump from `propose`'s CEI
    ///      ordering, so validating after storing nothing yet is safe.
    function _validateAndStoreBatch(
        uint256 proposalId,
        BatchExecutorLib.Call[] calldata executeCalls,
        uint256[] calldata executeCallCaps,
        BatchExecutorLib.Call[] calldata settlementCalls,
        uint256[] calldata settlementCallCaps,
        uint256 maxCapital
    ) private {
        if (executeCallCaps.length != executeCalls.length || settlementCallCaps.length != settlementCalls.length) {
            revert CallCapsLengthMismatch();
        }
        uint256 execSum;
        for (uint256 i = 0; i < executeCallCaps.length; i++) {
            execSum += executeCallCaps[i];
        }
        if (execSum > maxCapital) revert CallCapsExceedMaxCapital();
        uint256 settleSum;
        for (uint256 i = 0; i < settlementCallCaps.length; i++) {
            settleSum += settlementCallCaps[i];
        }
        if (settleSum > maxCapital) revert CallCapsExceedMaxCapital();
        _storeCalls(_executeCalls, proposalId, executeCalls);
        _storeCalls(_settlementCalls, proposalId, settlementCalls);
        _storeCaps(_executeCallCaps, proposalId, executeCallCaps);
        _storeCaps(_settlementCallCaps, proposalId, settlementCallCaps);
    }

    /// @dev Resolves and stores the proposal's tier + required coverage, then
    ///      runs the propose-time gates: the maxCapital ceiling check, the
    ///      exposure ledger's covered-TVL cap, and the risk-scaled proposer
    ///      bond (which PULLS WOOD from the proposer — a state-changing
    ///      external call, see the CEI note at the `lockBond` site below).
    ///      Hoisted out of `propose` to keep that function under Yul's stack
    ///      budget (see `_initPendingProposal`). Reads p.maxCapital / p.id from
    ///      storage (written before this call in `propose`) rather than taking
    ///      them as stack arguments — the propose() call site must stay exactly
    ///      `(p, _loadCalls(...))`-shaped or Yul goes "too deep by 1 slot".
    function _snapshotTierAndGate(StrategyProposal storage p, BatchExecutorLib.Call[] memory execCalls) private {
        // Envelope ceiling check. Lives here (not in propose's validation
        // block) purely for the same stack-budget reason — an extra call
        // frame in propose() tips it over. Same-tx revert either way.
        _checkMaxCapitalCeiling(p.maxCapital);
        // checkCeiling=true: this IS the propose-time sweep the per-call
        // tier-2 ceiling runs inside (design.md D1/D2). Caps are loaded from
        // storage (stored by `propose` via `_storeCaps` before this call
        // runs) rather than taken as stack arguments, for the same
        // stack-budget reason `execCalls` already is.
        (uint8 tier_, uint256 coverage_) = _resolveTierAndCoverage(
            execCalls,
            _loadCaps(_executeCallCaps, p.id),
            _loadCalls(_settlementCalls, p.id),
            _loadCaps(_settlementCallCaps, p.id),
            p.maxCapital,
            true
        );
        p.envelopeTier = tier_;
        p.requiredCoverage = coverage_;
        // Skipped when unwired — the pre-ledger safe default matches the
        // tierRegistry pattern.
        address ledger = _exposureLedger;
        if (ledger != address(0)) {
            address asset = IERC4626(GovernorParameters.vault).asset();
            IExposureLedger(ledger).requireWithinCoveredTvlCap(asset, coverage_);
            // Fails on the PROPOSER, not on the cohort: a duration whose
            // settlement outruns the ledger's booking horizon would
            // otherwise leave every approve vote unable to book, turning the
            // review block-only.
            //
            // `p.executeBy` is still zero on the collaborative path —
            // `_initPendingProposal` writes it, and `propose` only calls
            // that on the non-collaborative branch, so a co-proposed
            // strategy sits in Draft until `approveCollaboration`. Compute
            // the worst-case deadline instead: a Draft may idle for
            // `collaborationWindow` before activating, then run
            // voting -> review -> execution.
            uint256 deadline = p.executeBy;
            if (deadline == 0) {
                ISyndicateGovernor.GovernorParams memory gp = _params;
                deadline = block.timestamp + gp.collaborationWindow + gp.votingPeriod
                    + IGuardianRegistry(_guardianRegistry).reviewPeriod() + gp.executionWindow;
            }
            IExposureLedger(ledger).requireWithinCoverageHorizon(deadline, p.strategyDuration);
            address escrow = _bondEscrow;
            if (escrow != address(0)) {
                uint256 bondWood = IExposureLedger(ledger).proposerBondWood(asset, coverage_);
                if (bondWood != 0) {
                    // FAIL CLOSED ON A MISMATCHED PAIR, before any state
                    // write. `_bondEscrow` and `_exposureLedger` are
                    // independently factory-settable with no on-chain pairing
                    // guarantee (`setBondEscrow` requires draining all
                    // outstanding bonds first; `setExposureLedger` only
                    // requires `_openProposalCount == 0`, a much weaker
                    // gate — ledger rotation routinely outpaces escrow
                    // rotation in ordinary operation). Locking a bond into an
                    // escrow whose own immutable `exposureLedger` differs
                    // from `ledger` would price/pin it against a ledger whose
                    // live game the escrow will never recognize as the
                    // authorized convictor — `forfeitBond` would revert
                    // `NotAuthorizedConvictor` forever, and a convicted
                    // proposer would keep the bond (audit finding, PR #136
                    // round 1).
                    if (IProposerBondEscrow(escrow).exposureLedger() != ledger) {
                        revert LedgerEscrowMismatch();
                    }
                    // Bind the bond to THIS escrow AND this ledger:
                    // `reclaimProposerBond` releases against the stored escrow
                    // and gates against the stored ledger, so re-pointing
                    // `_bondEscrow` / `_exposureLedger` later cannot strand
                    // the bond or detach its reclaim gates (the escrow has no
                    // owner and no discretionary exit; its bond key is
                    // (governor, proposalId), so nobody else can address it).
                    // All three writes precede the external call (CEI).
                    p.proposerBondWood = bondWood;
                    p.proposerBondEscrow = escrow;
                    p.proposerBondLedger = ledger;
                    // STATE-CHANGING external call: `lockBond` pulls WOOD via
                    // `transferFrom`, so a WOOD with a transfer hook can
                    // re-enter this governor here. INVARIANT: every
                    // proposal-state field the lifecycle reads must ALREADY be
                    // written by this point (including
                    // `collaborationDeadline`, hoisted into `propose`'s
                    // isCollaborative branch for exactly this reason). Do not
                    // move a state write below this call.
                    IProposerBondEscrow(escrow).lockBond(p.id, p.proposer, bondWood);
                }
            }
        }
    }

    /// @dev Proposal tier = max tier across EXECUTE calls (batch-wide,
    ///      unchanged — design.md D2: every consumer of the aggregate tier
    ///      wants the fail-closed max). Coverage (issue #43) is the SUM of
    ///      PER-CALL contributions across BOTH execute and settlement calls:
    ///        coverage = Σ (cap_i * boundBps_i) / 10_000,
    ///      boundBps_i = the certified bound for tier-0/1 calls, 10_000 (full
    ///      notional) for tier-2/uncertified calls, cap_i = that call's OWN
    ///      declared gross-outflow cap. Monotonic in every cap and every
    ///      boundBps — the property the regression guard and issue #27's
    ///      proportional scaling both lean on.
    ///
    ///      With no registry wired every proposal is tier 2 / full notional
    ///      (coverage = maxCapital) — the pre-registry safe default is NOT
    ///      made cheaper by per-call caps. `memory` params (not calldata) so
    ///      this can be reused on storage-loaded calls at execute time.
    ///
    ///      `checkCeiling` gates the per-call tier-2 ceiling (true at propose,
    ///      false at execute re-resolve — post-propose tier drift is the
    ///      regression guards' job, not a second ceiling check).
    function _resolveTierAndCoverage(
        BatchExecutorLib.Call[] memory execCalls,
        uint256[] memory execCaps,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256[] memory settleCaps,
        uint256 maxCapital,
        bool checkCeiling
    ) private view returns (uint8 tier, uint256 coverage) {
        address registry = _tierRegistry;
        if (registry == address(0)) return (2, maxCapital);
        uint256 tier2Ceiling = checkCeiling
            ? (IERC4626(GovernorParameters.vault).totalAssets() * tier2CallCapBps()) / BPS_DENOMINATOR
            : type(uint256).max;
        (uint8 execTier, uint256 execCoverage) = _scanCalls(registry, execCalls, execCaps, checkCeiling, tier2Ceiling);
        (, uint256 settleCoverage) = _scanCalls(registry, settleCalls, settleCaps, checkCeiling, tier2Ceiling);
        tier = execTier;
        coverage = execCoverage + settleCoverage;
    }

    /// @dev Max tier and Σ (cap_i * boundBps_i) / 10_000 across `calls`,
    ///      resolved through the TierRegistry. When `checkCeiling` is set,
    ///      also enforces the per-call tier-2 ceiling in the SAME sweep (one
    ///      registry scan, not two): any call whose resolved tier is 2
    ///      (uncertified included) must declare `caps[i] <= tier2Ceiling`,
    ///      else `Tier2CallCapExceedsCeiling(i)` — `i` is this array's own
    ///      index; exec and settle are scanned as two separate calls to this
    ///      function, exec first (design.md D2).
    function _scanCalls(
        address registry,
        BatchExecutorLib.Call[] memory calls,
        uint256[] memory caps,
        bool checkCeiling,
        uint256 tier2Ceiling
    ) private view returns (uint8 tier, uint256 coverage) {
        for (uint256 i = 0; i < calls.length; i++) {
            bytes memory d = calls[i].data;
            bytes4 sel;
            if (d.length >= 4) {
                // memory-safe: pure read of an in-bounds offset of `d`'s own
                // memory-array content (guarded by the `d.length >= 4` check
                // above), no writes. Annotated so the via-ir pipeline's
                // memory-safety proof is not blocked contract-wide by this
                // block, unlocking memory-based stack spilling elsewhere
                // (issue #43's `propose` Yul stack budget).
                assembly ("memory-safe") {
                    sel := mload(add(d, 32))
                }
            }
            (uint8 t, uint16 boundBps) = ITierRegistry(registry).tierOf(calls[i].target, sel);
            if (t > tier) tier = t;
            uint256 cap_i = caps[i];
            if (checkCeiling && t == 2 && cap_i > tier2Ceiling) revert Tier2CallCapExceedsCeiling(i);
            coverage += (cap_i * boundBps) / 10_000;
        }
    }

    /// @dev Push calldata calls into a storage mapping slot
    function _storeCalls(
        mapping(uint256 => BatchExecutorLib.Call[]) storage target,
        uint256 proposalId,
        BatchExecutorLib.Call[] calldata calls
    ) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            target[proposalId].push(calls[i]);
        }
    }

    /// @dev Copy calls from storage to memory
    function _loadCalls(mapping(uint256 => BatchExecutorLib.Call[]) storage source, uint256 proposalId)
        internal
        view
        returns (BatchExecutorLib.Call[] memory result)
    {
        BatchExecutorLib.Call[] storage stored = source[proposalId];
        result = new BatchExecutorLib.Call[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            result[i] = stored[i];
        }
    }

    /// @dev Push calldata caps into a storage mapping slot, mirroring
    ///      `_storeCalls`. Introduced ahead of the propose() ABI change (§4)
    ///      so §3 already has the storage primitive; not yet called from
    ///      `propose` (nothing populates `_executeCallCaps`/
    ///      `_settlementCallCaps` until §4 stores the new calldata params).
    function _storeCaps(mapping(uint256 => uint256[]) storage target, uint256 proposalId, uint256[] calldata caps)
        internal
    {
        for (uint256 i = 0; i < caps.length; i++) {
            target[proposalId].push(caps[i]);
        }
    }

    /// @dev Copy caps from storage to memory, mirroring `_loadCalls`.
    function _loadCaps(mapping(uint256 => uint256[]) storage source, uint256 proposalId)
        internal
        view
        returns (uint256[] memory result)
    {
        uint256[] storage stored = source[proposalId];
        result = new uint256[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            result[i] = stored[i];
        }
    }

    /// @dev Push a MEMORY caps array into a storage mapping slot — the
    ///      memory-argument counterpart to `_storeCaps` (which takes
    ///      `calldata`, the only location a propose()-time param can have).
    ///      Needed because the scaled settlement caps this change persists
    ///      (issue #27 design D7) are computed in memory at execute, not
    ///      received as calldata.
    function _storeCapsMemory(mapping(uint256 => uint256[]) storage target, uint256 proposalId, uint256[] memory caps)
        private
    {
        for (uint256 i = 0; i < caps.length; i++) {
            target[proposalId].push(caps[i]);
        }
    }

    /// @dev Derives, stores, and emits the coverage-proportional effective
    ///      capital (issue #27 design D3-D5) at execute, and scales the
    ///      stored per-call caps (issue #43 design D7) by the same factor,
    ///      persisting the scaled settlement caps for `settleProposal` to
    ///      reuse verbatim. Hoisted out of `executeProposal` to keep that
    ///      function's local-variable count under Yul's stack budget — the
    ///      same reason every other multi-step helper in this file is
    ///      hoisted. An INTERNAL call, so issue #35's "same transaction"
    ///      invariant on the `requireApproveQuorum` gate (see the call site's
    ///      own note) is unaffected by the function boundary.
    ///
    ///      `effectiveMaxCapital = maxCapital` when the gate does not run (no
    ///      ledger wired, zero `requiredCoverage`, or tier below the quorum
    ///      threshold) or when the raised coverage is at/above what is
    ///      required; otherwise
    ///      `floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)`,
    ///      which can floor to zero on dust coverage (a zero net-outflow cap
    ///      — fail-closed, accepted per design D5). `requireApproveQuorum`
    ///      itself already reverts on a raised aggregate of exactly zero, so
    ///      this function is only ever reached with either a skipped gate or
    ///      a nonzero raised figure — the division below never sees a zero
    ///      denominator on the scaling branch (`requiredCoverageUsd == 0`
    ///      implies the gate did not run, since `coverageUsd` is zero only
    ///      when `requiredCoverage == 0`, which alone skips the gate).
    function _deriveAndStoreEffectiveCapital(
        uint256 proposalId,
        StrategyProposal storage proposal,
        address ledger,
        address asset
    ) private returns (uint256[] memory scaledExecuteCaps) {
        uint256 maxCapital = proposal.maxCapital;
        uint256 coverageRaisedUsd;
        uint256 requiredCoverageUsd;
        // `requiredCoverage == 0` keeps optimistic passage: a proposal that
        // can extract nothing needs no covering signer. Reachable as of
        // issue #43: an all-zero-cap proposal (with a wired registry)
        // legitimately prices to zero — it declares zero asset-extractable
        // value, and the per-call meter enforces exactly that declaration,
        // so no covering signer is needed for a batch that cannot move the
        // asset out of custody.
        bool gated = ledger != address(0) && proposal.requiredCoverage != 0
            && proposal.envelopeTier >= IExposureLedger(ledger).quorumTierThreshold();
        if (gated) {
            (coverageRaisedUsd, requiredCoverageUsd) = IExposureLedger(ledger)
                .requireApproveQuorum(address(this), proposalId, asset, proposal.requiredCoverage);
        }

        bool scale = gated && coverageRaisedUsd < requiredCoverageUsd;
        uint256 effectiveMaxCapital = scale ? (maxCapital * coverageRaisedUsd) / requiredCoverageUsd : maxCapital;
        proposal.effectiveMaxCapital = effectiveMaxCapital;
        emit EffectiveMaxCapitalSet(proposalId, maxCapital, effectiveMaxCapital, coverageRaisedUsd, requiredCoverageUsd);

        uint256[] memory settlementCaps = _loadCaps(_settlementCallCaps, proposalId);
        scaledExecuteCaps = _loadCaps(_executeCallCaps, proposalId);
        if (scale) {
            scaledExecuteCaps =
                _scaleCaps(scaledExecuteCaps, coverageRaisedUsd, requiredCoverageUsd, effectiveMaxCapital);
            settlementCaps = _scaleCaps(settlementCaps, coverageRaisedUsd, requiredCoverageUsd, effectiveMaxCapital);
        }
        // Persisted on EVERY path (identity copy when `scale` is false) so
        // `settleProposal` always reads from `_effectiveSettlementCallCaps`
        // with no branch on whether the gate ran.
        _storeCapsMemory(_effectiveSettlementCallCaps, proposalId, settlementCaps);
    }

    /// @dev Scales each cap by `raised/required` (floor, matching
    ///      `coverageUsd`'s own floor discipline) and defensively re-asserts
    ///      the scaled sum against `bound` (issue #27 design D7). Term-wise
    ///      floors cannot mathematically exceed `bound` given the
    ///      propose-time invariant `Σ caps <= maxCapital`
    ///      (`_validateAndStoreBatch`): `Σ floor(cap_i * s) <= floor(Σ cap_i *
    ///      s) <= floor(maxCapital * s) == bound`. The re-assert is kept
    ///      anyway as belt-and-braces per the spec — on a hypothetical
    ///      violation the LARGEST scaled cap absorbs the (dust-sized) excess,
    ///      deterministically and without touching any other term. A cap
    ///      that floors to zero stays zero (fail-closed, design D5/D7).
    function _scaleCaps(uint256[] memory caps, uint256 raised, uint256 required, uint256 bound)
        private
        pure
        returns (uint256[] memory scaled)
    {
        uint256 n = caps.length;
        scaled = new uint256[](n);
        uint256 sum;
        uint256 maxIdx;
        uint256 maxVal;
        for (uint256 i = 0; i < n; i++) {
            uint256 c = (caps[i] * raised) / required;
            scaled[i] = c;
            sum += c;
            if (c >= maxVal) {
                maxVal = c;
                maxIdx = i;
            }
        }
        if (sum > bound) {
            uint256 excess = sum - bound;
            scaled[maxIdx] = excess >= maxVal ? 0 : maxVal - excess;
        }
    }

    /// @dev Emit ProposalCreated event (reads from storage to avoid stack-too-deep in propose())
    function _emitProposalCreated(uint256 proposalId, uint256 executeCallCount, uint256 settlementCallCount) internal {
        StrategyProposal storage p = _proposals[proposalId];
        emit ProposalCreated(
            proposalId,
            p.proposer,
            p.vault,
            p.performanceFeeBps,
            p.strategyDuration,
            executeCallCount,
            settlementCallCount,
            p.metadataURI
        );
    }

    /// @dev Verify caller is a co-proposer on the given proposal
    function _requireCoProposer(uint256 proposalId) internal view {
        CoProposer[] storage coProps = _coProposers[proposalId];
        for (uint256 i = 0; i < coProps.length; i++) {
            if (coProps[i].agent == msg.sender) return;
        }
        revert NotCoProposer();
    }

    /// @dev Anti-front-run guard for the lead's Draft -> Cancelled abort,
    ///      shared by `cancelProposal`'s Draft branch and
    ///      `rejectCollaboration` (audit issue #181 finding #16). Both are
    ///      the SAME actor (`proposal.proposer`) performing the SAME
    ///      transition on the SAME state, so they must share one check or a
    ///      lead near quorum could always route around whichever entrypoint
    ///      enforces it. Blocks the lead once all-but-one co-proposer has
    ///      approved, preventing a front-run of the final approve tx. A
    ///      single co-proposer Draft (`total == 1`) stays cancellable —
    ///      "all but one" is zero approvals there, which must not lock the
    ///      lead out.
    function _requireNotNearQuorum(uint256 proposalId) private view {
        uint256 total = _coProposers[proposalId].length;
        if (total > 1 && _approvedCount[proposalId] + 1 >= total) {
            revert CancelNotAllowedNearQuorum();
        }
    }

    /// @dev Store co-proposers, emit event. `collaborationDeadline` is NOT set
    ///      here — `propose` writes it in the `isCollaborative` branch, before
    ///      any external call, so the Draft is never observable with a zero
    ///      deadline (which the base's `_computeState` maps to Expired). See the
    ///      ordering comment at the `lockBond` call site.
    function _storeCoProposers(uint256 proposalId, CoProposer[] calldata coProposers) internal {
        for (uint256 i = 0; i < coProposers.length; i++) {
            _coProposers[proposalId].push(coProposers[i]);
        }

        address[] memory coAddrs = new address[](coProposers.length);
        uint256[] memory splits = new uint256[](coProposers.length);
        for (uint256 i = 0; i < coProposers.length; i++) {
            coAddrs[i] = coProposers[i].agent;
            splits[i] = coProposers[i].splitBps;
        }
        emit CollaborativeProposalCreated(proposalId, msg.sender, coAddrs, splits);
    }

    /// @dev Validate co-proposer array: registered agents, no duplicates, valid splits
    function _validateCoProposers(address vault, CoProposer[] calldata coProposers) internal view {
        if (coProposers.length > _params.maxCoProposers) revert TooManyCoProposers();

        uint256 totalCoSplitBps = 0;
        for (uint256 i = 0; i < coProposers.length; i++) {
            address coAgent = coProposers[i].agent;
            uint256 splitBps = coProposers[i].splitBps;

            if (!ISyndicateVault(vault).isAgent(coAgent)) revert NotRegisteredAgent();

            // Cannot be the lead proposer.
            if (coAgent == msg.sender) revert DuplicateCoProposer();

            if (splitBps < MIN_SPLIT_BPS) revert SplitTooLow();

            for (uint256 j = 0; j < i; j++) {
                if (coProposers[j].agent == coAgent) revert DuplicateCoProposer();
            }

            totalCoSplitBps += splitBps;
        }

        // Lead split = 10000 - totalCoSplitBps (must be >= 10%)
        if (totalCoSplitBps > 9000) revert LeadSplitTooLow();
    }

    // State resolution lives in ProposalLifecycle: mutating callers use
    // `_commitState` (resolves + fires the registry economic commit on the
    // concluding review transition), read-only callers use `_computeState` /
    // `stateOf` (the ONE pure resolver — a TRUE view that never lags
    // determinable reality).

    /// @dev Finalize a settled proposal: compute P&L, distribute fees, clear
    ///      counters. Invoked by both happy-path `settleProposal` and the
    ///      emergency settle lifecycle (`unstick` / `finalizeEmergencySettle`).
    ///
    ///      PnL is measured purely against `IERC20(asset).balanceOf(vault)`.
    ///      Any non-asset balance the strategy still holds at settlement time
    ///      (mTokens / LP NFTs / reward tokens / perp margin) counts as a
    ///      LOSS of the corresponding asset balance the strategy started
    ///      with. Strategies MUST fully unwind all non-asset positions and
    ///      return the underlying to the vault before `_finishSettlement` is
    ///      called. If a strategy cannot unwind, callers should wait past
    ///      `strategyDuration` and drive the emergency-settle path with
    ///      governance-approved custom calls via `emergencySettleWithCalls`.
    /// @dev  Best-effort `settleCoverage` self-trigger (issue #33,
    ///       settle-coverage-self-trigger design D1/D2). Settlement is NOT
    ///       reliably past a proposal's `executeBy` (a proposer self-settle
    ///       at `executedAt + 1 hours`, or any `strategyDuration` shorter than
    ///       the remaining execution window, lands before it), so
    ///       `_settleCoverageBestEffort` guards on `block.timestamp >
    ///       proposal.executeBy` and skips silently otherwise — the
    ///       `reclaimProposerBond` trigger is the backstop that IS provably
    ///       past `executeBy` for every executed proposal.
    function _finishSettlement(uint256 proposalId, StrategyProposal storage proposal)
        internal
        returns (int256 pnl, uint256 agentFee)
    {
        address vault = proposal.vault;
        address asset = IERC4626(vault).asset();

        // Asset-only measurement (see NatSpec above).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 snapshot = _capitalSnapshots[proposalId];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 balanceAdjusted = IERC20(asset).balanceOf(vault);
        pnl = int256(balanceAdjusted) - int256(snapshot);

        // Finalize state before external transfers to prevent reentrancy on stale state
        _activeProposal = 0;
        _transition(proposal, ProposalState.Settled);
        delete _capitalSnapshots[proposalId];
        // Open emergency reviews are NOT auto-cancelled here — they resolve
        // naturally via `resolveEmergencyReview` at reviewEnd (slashing if the
        // block quorum was met, no-op otherwise) so an owner who opened an
        // adversarial emergency cannot dodge slash by racing a settle.
        _decOpen();

        // ── Two-number fee model ──
        // Ordering is load-bearing: management fee first (it lowers assets and
        // therefore price per share), then the high-water-mark comparison, then
        // performance. Reversing any pair would charge performance on assets the
        // management fee already took, or ratchet the mark past value the fund
        // never banked.
        //
        // The management fee is charged on EVERY settlement — profit, flat or
        // loss. It is what funds the parties doing continuous work (the agent
        // managing the book, the guardian network reviewing) in months when
        // there is no profit to share.
        uint256 totalFee = _chargeManagementFee(proposalId, vault, asset, proposal.proposer);

        // No strategy self-report can exempt a proposal from the performance
        // leg (issue #151 deleted that mechanism: it was a self-reported
        // opt-out for a custody-model strategy that never shipped, and it let
        // any registered agent skip the performance fee by pointing a
        // proposal at a contract that claimed to self-manage fees). Every
        // proposal is charged the same way.
        // Always called regardless — see `chargeNew`.
        {
            uint256 perfFee;
            (agentFee, perfFee) = _chargePerformanceFee(proposalId, vault, asset, proposal.proposer, true);
            totalFee += perfFee;
        }

        // Stamp the frozen Lane B settle price for this proposal AFTER fees so
        // queued redeemers/depositors settle against the post-fee NAV. No-op if
        // the vault has no withdrawal queue.
        ISyndicateVault(vault).onProposalSettled(proposalId);

        emit ProposalSettled(proposalId, vault, pnl, totalFee, block.timestamp - proposal.executedAt);

        // LAST operation of finalization (design D1): a gas-starved child
        // here leaves no meaningful work unfunded behind it. Covers
        // `settleProposal`, `unstick`, and `finalizeEmergencySettle` in one
        // place (all three route through `_finishSettlement`).
        _settleCoverageBestEffort(proposalId, proposal);
    }

    /// @notice Best-effort self-trigger of the exposure ledger's
    ///         `settleCoverage(address(this), proposalId)` so cohort capacity
    ///         relief no longer depends on an external keeper (issue #33,
    ///         settle-coverage-self-trigger design D1/D2). Never reverts.
    /// @dev    Guard first: `settleCoverage` itself reverts `ReviewNotClosed`
    ///         unless `pv.executeBy != 0 && block.timestamp > pv.executeBy` —
    ///         mirrored here exactly, including the `== 0` disjunct.
    ///         `proposal.executeBy` stays zero for a collaborative Draft that
    ///         never reaches Pending (collaboration-window timeout ->
    ///         Expired, or a lead cancel -> Cancelled via `cancelProposal`'s
    ///         Draft branch) — `_snapshotTierAndGate` locks a bond and pins
    ///         `proposerBondLedger` on that path regardless. Without the
    ///         `== 0` check, `block.timestamp <= 0` is always false, so the
    ///         guard would NOT skip and the ledger call would run only to
    ///         revert `ReviewNotClosed` itself (since the ledger reads the
    ///         same zero `executeBy`) — caught by the bare catch below, but
    ///         a spurious `CoverageSettleFailed` for a proposal that was
    ///         never capable of a real failure. Settlement is NOT reliably
    ///         past `executeBy` either (a proposer self-settle at
    ///         `executedAt + 1 hours`, or a `strategyDuration` shorter than
    ///         the remaining execution window, lands before it), so an
    ///         early call here is a statically-knowable no-op. Skipping it
    ///         silently (no call, no event) rather than attempting-and-
    ///         catching keeps `CoverageSettleFailed` meaning "the call
    ///         reverted", not "this ran too early" — the `reclaimProposerBond`
    ///         trigger is provably past `executeBy` for every executed
    ///         proposal and retries it there.
    /// @dev    Ledger resolution mirrors the reclaim gates' pinned-first rule
    ///         (issue #116): the ledger pinned on the proposal at bond-lock
    ///         time, falling back to the live `_exposureLedger` slot only for
    ///         a proposal that recorded none, skipping entirely when both are
    ///         zero (no ledger means no coverage was ever booked).
    /// @dev    Bare catch, deliberately (design D2/D3): everything reaching it
    ///         is either ledger-side (e.g. `NoWoodPrice` during a feed
    ///         outage) or gas starvation, and revert-data cannot reliably
    ///         distinguish either. No gas floor (design D3): a gas-starved
    ///         trigger degrades to the exact pre-change status quo —
    ///         over-reserved, the conservative direction — surfaced by
    ///         `CoverageSettleFailed` and permissionlessly repairable via the
    ///         unchanged external `ExposureLedger.settleCoverage`.
    function _settleCoverageBestEffort(uint256 proposalId, StrategyProposal storage proposal) private {
        if (proposal.executeBy == 0 || block.timestamp <= proposal.executeBy) return;
        address ledger = proposal.proposerBondLedger;
        if (ledger == address(0)) ledger = _exposureLedger;
        if (ledger == address(0)) return;
        try IExposureLedger(ledger).settleCoverage(address(this), proposalId) {}
        catch {
            emit CoverageSettleFailed(proposalId, ledger);
        }
    }

    /// @dev Snapshot every fee rate, recipient and split in force at propose
    ///      time so settlement pays what voters actually approved rather than a
    ///      post-vote governance change.
    ///
    ///      Extracted from `propose` rather than inlined: `propose` sits at the
    ///      Yul stack-depth limit (its own arguments alone nearly fill the
    ///      frame), and the reads below need more slots than remain. Keeping
    ///      them in a separate frame is what makes the snapshot affordable.
    ///
    ///      The splits are deliberately NOT validated here. `ProtocolConfig` is
    ///      born valid and rejects an invalid write, so a zero-sum split is
    ///      unreachable for a real config; reverting would only ever fire
    ///      against a mock, and would turn a fee-accounting problem into a
    ///      settlement-liveness one. The charge functions skip a zero-sum split
    ///      instead.
    function _snapshotFeeConfig(StrategyProposal storage p) private {
        IProtocolConfig cfg = IProtocolConfig(protocolConfig);
        p.snapshotProtocolFeeRecipient = cfg.protocolFeeRecipient();
        p.snapshotGuardiansFeeRecipient = cfg.guardiansFeeRecipient();
        p.snapshotMgmtSplit = cfg.mgmtSplit();
        p.snapshotPerfSplit = cfg.perfSplit();
    }

    /// @dev Clamp `fee` to `cap`, emitting FeeClamped when the clamp fires.
    function _clampPerformanceFee(uint256 proposalId, uint256 fee, uint256 cap) private returns (uint256) {
        if (fee > cap) {
            emit FeeClamped(proposalId, fee, cap);
            return cap;
        }
        return fee;
    }

    /// @dev Charge the always-on management fee and divide it three ways.
    ///      Extracted to avoid stack-too-deep.
    ///
    ///      ── THE FEE MAP — two depositor-facing numbers, everyone else paid
    ///      out of internal splits ──
    ///      The two fees are independent and each is ONE division of ONE
    ///      base. No recipient's share is reduced by another's.
    ///
    ///        1. managementFee = assetSeconds · managementFeeBps / (10_000 · 365d)
    ///             base: fund assets integrated over the proposal's life, from
    ///             the vault's accrual accumulator (`consumeManagementAccrual`)
    ///             charged: on EVERY settlement — profit, flat, or loss
    ///             source: vault.managementFeeBps() — read LIVE, and safely so:
    ///             it is written only at vault `initialize` and has no setter,
    ///             so it cannot move between propose and settle
    ///             split: prop.snapshotMgmtSplit → agent / protocol / guardian
    ///
    ///        2. performanceFee = aboveHighWaterMark · perfFeeBps
    ///             base: value above the fund's previous PEAK price per share,
    ///             read AFTER the management fee (which lowers it)
    ///             charged: only when the fund is above its mark
    ///             source: vault.agentFeeBps() (owner: VAULT owner; offset-by-one
    ///             sentinel, default FeeConstants.DEFAULT_AGENT_FEE_BPS = 5%)
    ///             caps: vault-side FeeConstants.MAX_PERFORMANCE_FEE_BPS (30%) at set;
    ///             clamped AGAIN here to the governor's live _params.maxPerformanceFeeBps
    ///             (factory default = the 20% headline)
    ///             snapshot: propose time → prop.performanceFeeBps
    ///             split: prop.snapshotPerfSplit → agent / protocol / guardian / owner
    ///             then: the high-water mark ratchets to the post-fee price
    ///
    ///      The agent's slice of BOTH fees flows through `_distributeAgentFee`,
    ///      so co-proposer splits apply to management as well as carry.
    ///      Guardian delivery is a WOOD airdrop via Merkl, attributed by the
    ///      GuardianFeeAccrued event.
    ///      Failure mode: any recipient transfer that reverts escrows in _unclaimedFees
    ///      (pull via claimUnclaimedFees) so settlement never bricks.
    /// @return mgmtFee The whole management fee charged.
    function _chargeManagementFee(uint256 proposalId, address vault, address asset, address proposer)
        internal
        returns (uint256 mgmtFee)
    {
        // Consume-and-reset: hands back the integral and stops the clock, so
        // the gap before the next proposal accrues nothing.
        uint256 assetSeconds = ISyndicateVault(vault).consumeManagementAccrual();
        StrategyProposal storage prop = _proposals[proposalId];
        // Read live rather than snapshotted, and safe to do so: `_managementFeeBps`
        // is written only at `SyndicateVault.initialize` and has no setter, so it
        // cannot move between propose and settle. A snapshot would be equivalent
        // and would cost `propose` a stack slot it does not have.
        uint256 rateBps = ISyndicateVault(vault).managementFeeBps();

        // The fee owed for the WHOLE proposal.
        mgmtFee = (assetSeconds * rateBps) / (BPS_DENOMINATOR * 365 days);

        if (mgmtFee == 0) return 0;

        IProtocolConfig.MgmtSplit memory s = prop.snapshotMgmtSplit;
        // A zero-sum split is unreachable for a real config (ProtocolConfig is
        // born valid and validates every write), but skipping beats reverting:
        // a bricked settlement is the worse failure.
        if (uint256(s.agentBps) + s.protocolBps + s.guardianBps != BPS_DENOMINATOR) return 0;

        uint256 toProtocol = (mgmtFee * s.protocolBps) / BPS_DENOMINATOR;
        uint256 toGuardian = (mgmtFee * s.guardianBps) / BPS_DENOMINATOR;
        // A leg whose recipient was never configured pays nothing and folds
        // into the agent's remainder. Paying it anyway would send to
        // address(0): the transfer reverts, `_payFee` escrows it against
        // address(0), and it becomes permanently unclaimable — a silent burn
        // of 10% of every management fee.
        if (prop.snapshotProtocolFeeRecipient == address(0)) toProtocol = 0;
        if (prop.snapshotGuardiansFeeRecipient == address(0)) toGuardian = 0;
        // The agent takes the remainder rather than its own floor-divided
        // share, so rounding dust lands with the largest earner instead of
        // stranding in the vault.
        uint256 toAgent = mgmtFee - toProtocol - toGuardian;

        if (toProtocol > 0) _payFee(vault, asset, prop.snapshotProtocolFeeRecipient, toProtocol);
        if (toGuardian > 0) {
            // Attribution signal only on actual delivery — see the note in
            // `_chargePerformanceFee`.
            if (_payFee(vault, asset, prop.snapshotGuardiansFeeRecipient, toGuardian)) {
                emit GuardianFeeAccrued(proposalId, asset, prop.snapshotGuardiansFeeRecipient, toGuardian);
            }
        }
        // The agent's slice follows the co-proposer split, exactly as carry does.
        if (toAgent > 0) _distributeAgentFee(proposalId, vault, asset, proposer, toAgent);

        emit ManagementFeeCharged(proposalId, asset, mgmtFee, assetSeconds);
    }

    /// @dev Charge the performance fee on value above the high-water mark and
    ///      divide it four ways in ONE split. Each recipient's share is
    ///      computed from the full fee, never from what another recipient
    ///      left behind.
    ///
    ///      Must run AFTER the management fee: that fee lowers the vault's
    ///      assets and therefore its price per share, so reading the above-mark
    ///      base first would charge performance on assets already taken.
    /// @return agentFee The agent's slice, reported for the settle event.
    /// @return perfFee  The whole fee charged.
    /// @param chargeNew Always `true` as of both #151 (deleted the
    ///        `selfManagesFees` opt-out that used to pass `false`) and #54
    ///        (deleted `consumeCrystallizedPerf`, the other reason a `false`
    ///        call still had to run — releasing fees already crystallized
    ///        from Lane A instant exiters). Both original reasons for this
    ///        parameter to exist are now gone, so it is provably vacuous —
    ///        this is #54's determination, per #151's own note deferring it.
    ///        NOT removed here: filed as a follow-up on #151 rather than
    ///        folded into this change, to keep this PR's diff to Lane A
    ///        retirement only.
    function _chargePerformanceFee(uint256 proposalId, address vault, address asset, address proposer, bool chargeNew)
        internal
        returns (uint256 agentFee, uint256 perfFee)
    {
        StrategyProposal storage prop = _proposals[proposalId];

        // Profit measured against the fund's previous peak, not against this
        // proposal's own starting balance — a fund that fell and recovered has
        // already paid for this ground.
        uint256 base = chargeNew ? ISyndicateVault(vault).aboveHighWaterMark() : 0;

        if (base > 0) {
            // Snapshotted at propose so it matches what voters approved, then
            // clamped to the governor's tunable ceiling so a later cap reduction
            // still bites. The clamp emits and continues rather than reverting.
            uint256 perfFeeBps = _clampPerformanceFee(proposalId, prop.performanceFeeBps, _params.maxPerformanceFeeBps);
            perfFee = (base * perfFeeBps) / BPS_DENOMINATOR;
        }

        IProtocolConfig.PerfSplit memory s = prop.snapshotPerfSplit;
        // A zero-sum split is unreachable for a real config; skipping beats
        // reverting, since a bricked settlement is the worse failure. Still
        // ratchet so the mark is not left stale.
        if (uint256(s.agentBps) + s.protocolBps + s.guardianBps + s.ownerBps != BPS_DENOMINATOR) {
            ISyndicateVault(vault).ratchetHighWaterMark();
            return (0, 0);
        }

        if (perfFee > 0) {
            uint256 toProtocol = (perfFee * s.protocolBps) / BPS_DENOMINATOR;
            uint256 toGuardian = (perfFee * s.guardianBps) / BPS_DENOMINATOR;
            uint256 toOwner = (perfFee * s.ownerBps) / BPS_DENOMINATOR;
            // Same unconfigured-recipient rule as the management leg: fold into
            // the agent's remainder rather than escrowing against address(0),
            // where the amount would be permanently unclaimable.
            if (prop.snapshotProtocolFeeRecipient == address(0)) toProtocol = 0;
            if (prop.snapshotGuardiansFeeRecipient == address(0)) toGuardian = 0;
            agentFee = perfFee - toProtocol - toGuardian - toOwner;

            if (toProtocol > 0) _payFee(vault, asset, prop.snapshotProtocolFeeRecipient, toProtocol);
            if (toGuardian > 0) {
                // Emit the attribution signal ONLY on actual delivery. If the
                // transfer escrows (recipient blacklisted), the asset stays in
                // the vault pending `claimUnclaimedFees` — emitting here would
                // make the off-chain Merkl bot airdrop WOOD for a fee that was
                // never delivered, then double-pay when the escrow is recovered.
                if (_payFee(vault, asset, prop.snapshotGuardiansFeeRecipient, toGuardian)) {
                    emit GuardianFeeAccrued(proposalId, asset, prop.snapshotGuardiansFeeRecipient, toGuardian);
                }
            }
            if (toOwner > 0) _payFee(vault, asset, ISyndicateVault(vault).owner(), toOwner);
            if (agentFee > 0) _distributeAgentFee(proposalId, vault, asset, proposer, agentFee);

            emit PerformanceFeeCharged(proposalId, asset, perfFee, base);
        }

        // Ratchet last, against the post-fee price. Monotonic: a loss leaves the
        // mark where it was, which is what makes the recovery free.
        ISyndicateVault(vault).ratchetHighWaterMark();
    }

    /// @dev Distribute agent fee to co-proposers (if any) and lead proposer. Extracted to avoid stack-too-deep.
    /// @dev Assumes a non-fee-on-transfer (FOT) asset. `distributed += share` is
    ///      booked at the requested-transfer amount, not the received amount, so the
    ///      lead's rounding remainder is computed against the requested total. If a
    ///      future vault ever onboards an FOT asset, `_distributeAgentFee` would
    ///      double-count the burn — the lead would be credited what was skimmed and
    ///      under-paid to match. USDC (the only V1 asset) is non-FOT; this branch
    ///      stays pinned by the `non-FOT` asset requirement in the vault audit.
    /// @dev The split is agreed and validated at PROPOSE time
    ///      (`_validateCoProposers`, against each co-proposer's THEN-live
    ///      agent status) — settle honours that recorded split rather than
    ///      re-resolving it against a possibly-mutated LIVE status. A
    ///      co-proposer removed after propose (`removeAgent` is `onlyOwner`
    ///      with no lifecycle gate) still does not get paid, but its earned
    ///      share is FORFEITED back to the vault (left undistributed) rather
    ///      than folded into the lead's remainder (audit issue #181 finding
    ///      #17): folding it into `leadShare` would let an owner who has
    ///      seated itself as lead strip co-proposers right before settle to
    ///      redirect their already-earned entitlement to itself. The lead's
    ///      own `leadShare` is therefore always exactly its propose-time
    ///      split (`agentFee - Σ co-proposer shares`, active or not),
    ///      independent of which co-proposers are still active at settle.
    function _distributeAgentFee(uint256 proposalId, address vault, address asset, address proposer, uint256 agentFee)
        internal
    {
        if (agentFee == 0) return;
        CoProposer[] storage coProps = _coProposers[proposalId];
        if (coProps.length > 0) {
            uint256 distributed = 0;
            uint256 forfeited = 0;
            for (uint256 i = 0; i < coProps.length; i++) {
                // Stop once the budget is exhausted — otherwise a later
                // co-proposer's non-zero share could push `distributed +
                // forfeited` past `agentFee`.
                if (distributed + forfeited >= agentFee) break;
                uint256 share = (agentFee * coProps[i].splitBps) / BPS_DENOMINATOR;
                if (share == 0) share = 1;
                // Cap to remaining budget — handles both the rounding-floor pad
                // (share = 1) and any splitBps overflow.
                uint256 remaining = agentFee - distributed - forfeited;
                if (share > remaining) share = remaining;
                if (ISyndicateVault(vault).isAgent(coProps[i].agent)) {
                    _payFee(vault, asset, coProps[i].agent, share);
                    distributed += share;
                } else {
                    // Forfeited, not redirected — stays undistributed in the
                    // vault. See the function-level note above.
                    forfeited += share;
                }
            }
            // The lead's fixed propose-time share. Subtracting `forfeited`
            // here (not just `distributed`) is what keeps a removed
            // co-proposer's entitlement OUT of the lead's payout.
            uint256 leadShare = agentFee - distributed - forfeited;
            if (leadShare > 0) {
                _payFee(vault, asset, proposer, leadShare);
            }
        } else {
            _payFee(vault, asset, proposer, agentFee);
        }
    }

    /// @dev Per-recipient fee transfer wrapped in try/catch. On failure
    ///      (e.g. USDC blacklist) the amount is escrowed against `recipient`
    ///      so settlement never bricks. Recipients pull via
    ///      `claimUnclaimedFees` once the failure condition is lifted.
    /// @return delivered true when the transfer landed; false when it escrowed
    ///         into `_unclaimedFees` (recipient blacklisted / transfer revert).
    function _payFee(address vault, address asset, address recipient, uint256 amount)
        internal
        returns (bool delivered)
    {
        if (amount == 0) return true;
        try ISyndicateVault(vault).transferPerformanceFee(asset, recipient, amount) {
            return true;
        } catch {
            _unclaimedFees[_unclaimedKey(vault, recipient, asset)] += amount;
            emit FeeTransferFailed(recipient, asset, amount);
            return false;
        }
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev `nonReentrant` here is uniformity with every other state-changing
    ///      governor entrypoint, not the closure of a live hole. The old
    ///      reasoning was, and remains, correct: CEI is respected (escrow slot
    ///      cleared before the external `transferPerformanceFee` call), so a
    ///      reentrant call with the same `(vault, msg.sender, token)` key sees
    ///      a zeroed slot and short-circuits harmlessly. CEI stays the primary
    ///      defense; the latch is defence-in-depth that closes the
    ///      re-derivation cost the next time surrounding code changes — being
    ///      the one unguarded entrypoint among guarded siblings is the
    ///      asymmetry that turns into a bug later, not a bug today.
    function claimUnclaimedFees(address vault, address token) external nonReentrant {
        bytes32 k = _unclaimedKey(vault, msg.sender, token);
        uint256 amt = _unclaimedFees[k];
        if (amt == 0) return;
        _unclaimedFees[k] = 0;
        ISyndicateVault(vault).transferPerformanceFee(token, msg.sender, amt);
        emit FeeClaimed(msg.sender, token, amt);
    }

    /// @inheritdoc ISyndicateGovernor
    function unclaimedFees(address vault, address recipient, address token) external view returns (uint256) {
        return _unclaimedFees[_unclaimedKey(vault, recipient, token)];
    }

    function _unclaimedKey(address vault, address recipient, address token) private pure returns (bytes32) {
        return keccak256(abi.encode(vault, recipient, token));
    }

    // ==================== FACTORY ADMIN ====================

    /// @inheritdoc ISyndicateGovernor
    function setProtocolConfig(address newConfig) external onlyFactory {
        if (newConfig == address(0)) revert ZeroAddress();
        protocolConfig = newConfig;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev address(0) is legal: it un-wires the registry and every subsequent
    ///      proposal resolves to tier 2 / full notional — the safe default, so
    ///      no zero-check (unlike `setProtocolConfig`, where zero would brick
    ///      fee snapshots).
    function setTierRegistry(address newRegistry) external onlyFactory {
        emit TierRegistrySet(_tierRegistry, newRegistry);
        _tierRegistry = newRegistry;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev address(0) is legal: it un-wires the ledger and the covered-TVL cap
    ///      + proposer-bond gates are then skipped — the pre-ledger safe
    ///      default (mirrors `setTierRegistry`).
    ///
    ///      WIRING ORDER (precondition): seed `setAssetFeed(vaultAsset, ...)`
    ///      AND `setCoveredTvlCapUsd(...)` on the ledger BEFORE wiring it here.
    ///      The gates are fail-closed by design, so a wired ledger with an
    ///      unpriceable vault asset (`FeedNotConfigured` / `StalePrice`) or a
    ///      zero cap (`CoveredTvlCapExceeded`) halts ALL proposal creation for
    ///      this vault.
    ///
    ///      RECOVERY: `address(0)` is accepted here, but the factory has NO
    ///      path that passes it — both callers
    ///      (`createSyndicate` and `pushWiring`) SKIP unset slots rather than
    ///      writing zero, precisely so wiring can never be silently removed.
    ///      Un-wiring an already-wired governor is therefore not reachable in
    ///      practice. Recover instead at the ledger (ledger-owner:
    ///      `setAssetFeed` / `setCoveredTvlCapUsd`), or point the factory at a
    ///      fresh permissive ledger and `pushWiring` this governor.
    ///
    ///      Re-pointing this slot does NOT move a POST-UPGRADE bond's reclaim
    ///      gates: `reclaimProposerBond` pins the ledger it gates against
    ///      onto the proposal at propose time (`proposal.proposerBondLedger`)
    ///      and reads that, not this live slot, for any bond locked by THIS
    ///      governor implementation.
    ///
    ///      IT DOES MOVE A LEGACY BOND'S GATES. `proposerBondLedger` is a
    ///      field appended to `StrategyProposal` by the fix for issue #116;
    ///      any proposal that locked a bond under a PRIOR governor
    ///      implementation never wrote it, so it reads `address(0)` forever,
    ///      and `reclaimProposerBond`'s fallback resolves that to THIS live
    ///      slot — reproducing, for that entire cohort, the exact re-point
    ///      bypass this fix exists to close. `setExposureLedger`'s only guard
    ///      (`_openProposalCount > 0`) stops blocking a re-point the moment a
    ///      legacy proposal itself settles (`_decOpen()` fires in
    ///      `_finishSettlement`, before that proposal's bond-hold window even
    ///      starts) — so an ORDINARY ledger migration, no malice required,
    ///      silently detaches a legacy bond's challenge-window protection.
    ///      Accepted trade-off (design.md, `fix-proposer-bond-reclaim-gates`,
    ///      Decision D2): bricking every pre-upgrade bond was judged worse.
    ///      Operational requirement: drain every outstanding legacy bond
    ///      (`reclaimProposerBond` or a genuine conviction) before re-pointing
    ///      this slot after deploying this fix.
    function setExposureLedger(address newLedger) external onlyFactory {
        // Not while proposals are open: a proposal created before the ledger
        // existed carries no booked coverage, but `executeProposal` starts
        // demanding it the moment the ledger is wired, making those
        // proposals permanently unexecutable. Refusing the wiring here is
        // the only point where that failure is visible rather than silent
        // at execute time.
        //
        // Un-wiring (`newLedger == 0`) is exempt: it can only relax the execute
        // gate, never brick a proposal that was relying on it.
        if (newLedger != address(0) && _openProposalCount > 0) revert ParamsFrozenDuringProposal();
        emit ExposureLedgerSet(_exposureLedger, newLedger);
        _exposureLedger = newLedger;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev address(0) is legal: it un-wires the escrow and no bond is locked at
    ///      propose.
    ///
    ///      Unlike `setTierRegistry`, this slot has CUSTODIAL meaning: the
    ///      escrow holds real WOOD for already-created proposals. Re-point it
    ///      only at ZERO outstanding bonds. Bonds already locked are released
    ///      against the escrow stored per proposal
    ///      (`StrategyProposal.proposerBondEscrow`), never this live slot — so
    ///      re-pointing is safe for existing proposals, and a new escrow applies
    ///      only to proposals created after the change.
    function setBondEscrow(address newEscrow) external onlyFactory {
        emit BondEscrowSet(_bondEscrow, newEscrow);
        _bondEscrow = newEscrow;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Does NOT require `whenNoActiveProposal` — factory may need to push
    ///      emergency param corrections even during an active proposal.
    function forceSetParams(GovernorParams calldata params) external onlyFactory {
        _validateParamBounds(params);
        _params = params;
        emit ParameterChangeFinalized("forceSetParams", 0, 0);
    }
}
