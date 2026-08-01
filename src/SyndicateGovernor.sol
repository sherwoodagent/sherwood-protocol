// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {IProposerBondEscrow} from "./interfaces/IProposerBondEscrow.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
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

    // `_proposals` migrated to ProposalLifecycle (base owns the state machine).

    /// @notice Proposal ID -> voter -> bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Proposal ID -> vault balance at execution time
    mapping(uint256 => uint256) private _capitalSnapshots;

    /// @notice Currently executing proposal ID (0 if none)
    uint256 private _activeProposal;

    // `_lastSettledAt` migrated to ProposalLifecycle (stamped by `_decOpen`).

    // ── Collaborative proposal storage ──

    /// @notice Proposal ID -> co-proposers array
    mapping(uint256 => CoProposer[]) private _coProposers;

    /// @notice Proposal ID -> co-proposer address -> approved
    /// @dev `internal` (no auto-getter): read only within the governor; not in
    ///      ISyndicateGovernor / cli / app / subgraph / tests. Bytecode lever.
    mapping(uint256 => mapping(address => bool)) internal coProposerApprovals;

    // `collaborationDeadline` migrated to ProposalLifecycle (read by the base's
    // `_computeState` for the Draft -> Expired edge).

    /// @notice Simple reentrancy lock for execute/settle entrypoints
    uint256 private _reentrancyStatus;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    /// @notice G-M11: upper bound on `metadataURI.length` accepted by
    ///         `propose`. 512 bytes comfortably fits ipfs / arweave / https
    ///         pointers while capping event-storage and calldata-copy griefing.
    uint256 internal constant MAX_METADATA_URI_LENGTH = 512;
    /// @notice G-M2/G-M6: upper bound on the `executeCalls` and
    ///         `settlementCalls` arrays passed to `propose`. Caps batch size
    ///         so executeGovernorBatch can't be weaponized for gas griefing.
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

    // `_guardianRegistry` migrated to ProposalLifecycle. Still set in
    // `initialize` (writes the inherited slot) and required (non-zero); fees
    // always route here — no separate recipient slot.

    // ── Guardian-review storage ──
    // `_emergencyCallsHashes` and `_emergencyCalls` live in GuardianRegistry.
    // Two mapping slots reclaimed into __gap.

    // `_openProposalCount` migrated to ProposalLifecycle. Counts non-terminal
    // proposals (Draft/Pending/GuardianReview/Approved/Executed); used by
    // `GuardianRegistry.requestUnstakeOwner` alongside `_activeProposal` to
    // block owner rage-quit while any proposal is in flight. Incremented here
    // (Draft/Pending); decremented via the inherited `_decOpen`.

    /// @dev Escrow of fee transfers that reverted (e.g., USDC blacklist) so the
    ///      rest of `_distributeFees` keeps flowing and settlement never bricks.
    ///      Recipients pull via `claimUnclaimedFees`. The underlying amount
    ///      remains in the vault; this mapping is pure bookkeeping. (W-1)
    ///      Keyed by `keccak256(vault, recipient, token)` so a claim can only
    ///      pull from the vault that actually owes the escrow — prevents the
    ///      cross-vault drain where a recipient with escrow on vault A redirects
    ///      the pull to vault B. Single-level mapping + packed key is chosen
    ///      over triple-nested mapping to keep governor runtime ≤ 24,550.
    mapping(bytes32 key => uint256) private _unclaimedFees;

    /// @dev Count of co-proposer approvals per proposal. Incremented in
    ///      `approveCollaboration`. Drives both the all-approved transition
    ///      and the G-H2 near-quorum cancel guard.
    mapping(uint256 proposalId => uint256) private _approvedCount;

    /// @dev Sherlock #14: per-Draft snapshot of (executionWindow << 128 |
    ///      votingPeriod) taken at propose. `approveCollaboration` reads it at
    ///      Draft → Pending so a mid-Draft owner param change can't move the
    ///      goalposts for co-proposers who already approved.
    mapping(uint256 proposalId => uint256 packedTiming) private _draftTimingSnap;

    /// @notice Tier registry (spec 2026-07-22 §3.2). Optional: address(0) means
    ///         every proposal resolves to tier 2 / full notional — the safe
    ///         default. Wired post-init via `setTierRegistry` (factory-only,
    ///         like `setProtocolConfig`).
    address internal _tierRegistry;

    /// @notice Exposure ledger (Plan B, spec §3.7/§3.9). Optional: address(0)
    ///         skips the covered-TVL cap + proposer-bond gates at propose — the
    ///         pre-ledger safe default. Wired post-init via `setExposureLedger`
    ///         (factory-only, like `setTierRegistry`).
    address internal _exposureLedger;

    /// @notice Proposer bond escrow (Plan B, spec §3.9). Optional: address(0)
    ///         skips bond locking. Wired via `setBondEscrow` (factory-only).
    address internal _bondEscrow;

    /// @dev Reserved storage for future upgrades (shrunk by 1 for _guardianRegistry,
    ///      shrunk by 1 more for openProposalCount,
    ///      shrunk by 1 more for _unclaimedFees,
    ///      shrunk by 1 more for _approvedCount,
    ///      grew by 1 after P1-1: _guardianFeeRecipient reclaimed,
    ///      grew by 5 after P2-1: _params + _protocolFeeBps +
    ///      _protocolFeeRecipient + _guardianFeeBps + factory moved to
    ///      GovernorParameters,
    ///      grew by 2 after V2: _emergencyCallsHashes + _emergencyCalls moved
    ///      to GuardianRegistry,
    ///      shrunk by 1 for _draftTimingSnap — Sherlock #14 restored,
    ///      shrunk by 1 for _tierRegistry — Task 5,
    ///      shrunk by 2 for _exposureLedger + _bondEscrow — Plan B Task 8)
    uint256[31] private __gap;

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
            // Use tx.origin as bootstrap owner: the deployer's EOA. In tests,
            // vm.prank(owner) sets msg.sender so we read the owner address that
            // will be used to call setters. We must capture it at init time.
            // Since we don't have an explicit owner param, use the factory for now.
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

    function _emergencyReentrancyEnter() internal override {
        if (_reentrancyStatus == _ENTERED) revert Reentrancy();
        _reentrancyStatus = _ENTERED;
    }

    function _emergencyReentrancyLeave() internal override {
        _reentrancyStatus = _NOT_ENTERED;
    }

    // ── V2: emergency-call storage moved to GuardianRegistry ──

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
        BatchExecutorLib.Call[] calldata settlementCalls,
        CoProposer[] calldata coProposers
    ) external returns (uint256 proposalId) {
        if (vault != GovernorParameters.vault) revert VaultNotRegistered();
        if (!ISyndicateVault(vault).isAgent(msg.sender)) revert NotRegisteredAgent();
        // G-M1: block new proposals when the vault still has a non-terminal
        // lifecycle bound to it (Pending / GuardianReview / Approved / Executed).
        // Draft co-proposals do not count toward openProposalCount and are
        // independently gated at their Draft -> Pending transition.
        if (_openProposalCount != 0) revert VaultHasOpenProposal();
        if (strategyDuration > _params.maxStrategyDuration) revert StrategyDurationTooLong();
        if (strategyDuration < _params.minStrategyDuration) revert StrategyDurationTooShort();
        if (executeCalls.length == 0) revert EmptyExecuteCalls();
        if (settlementCalls.length == 0) revert EmptySettlementCalls();
        // G-M2/G-M6: cap batch sizes.
        if (executeCalls.length > MAX_CALLS_PER_PROPOSAL || settlementCalls.length > MAX_CALLS_PER_PROPOSAL) {
            revert TooManyCalls();
        }
        // G-M11: cap metadata URI length.
        if (bytes(metadataURI).length > MAX_METADATA_URI_LENGTH) revert MetadataURITooLong();
        // Risk envelope (spec 2026-07-22 §3.1): nonzero outflow ceiling,
        // clamped to the maxCapitalBps ceiling (finding 3), drawdown
        // declaration capped at 100%.
        if (envelope.maxCapital == 0) revert ZeroMaxCapital();
        // maxCapital ceiling (finding 3) is enforced in `_snapshotTierAndGate` below —
        // same tx, hoisted off this frame for Yul stack budget.
        if (envelope.maxDrawdownBps > 10_000) revert InvalidDrawdown();

        // Validate co-proposers if present
        if (coProposers.length > 0) {
            _validateCoProposers(vault, coProposers);
        }

        proposalId = ++_proposalCount;

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
        // Snapshot the strategy's self-fee flag at propose (like performanceFeeBps)
        // so settle reads storage, not a live call: closes the TOCTOU flip between
        // review and settle and the brick vector where a settle-time revert would
        // strand normal AND emergency settlement. No try/catch — a revert here is
        // the intended fail-fast (an EOA / broken strategy fails at propose).
        p.selfManagesFees = strategy != address(0) && IStrategy(strategy).selfManagesFees();
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
            // Sherlock #14: snapshot timing params for the collaborative Draft
            // so the Draft → Pending transition can't be moved by a mid-Draft
            // owner param change. Packed (executionWindow << 128 | votingPeriod).
            _draftTimingSnap[proposalId] =
                (uint256(uint128(_params.executionWindow)) << 128) | uint256(uint128(_params.votingPeriod));
            // Sherlock #8: lock the vault at Draft creation. Pre-fix the
            // up-to-collaboration-window Draft stayed un-locked, letting
            // attackers deposit between propose and the final approve and have
            // the fresh balance counted in the Pending snapshot.
            unchecked {
                ++_openProposalCount;
            }
        } else {
            _initPendingProposal(p, reviewPeriod_);
        }

        // Store calls separately
        _storeCalls(_executeCalls, proposalId, executeCalls);
        _storeCalls(_settlementCalls, proposalId, settlementCalls);

        // Tier resolution (spec §3.2): proposal tier = MAX tier across execute
        // calls; requiredCoverage (finding 5: per-call SUM over execute AND
        // settlement calls) feeds the aggregate exposure cap (Plan B).
        // Resolved from the STORED calls (via _loadCalls) rather than the
        // calldata arrays so the `envelope`/`executeCalls` calldata refs are
        // dead by this point — keeps propose() under Yul's stack budget. Reads
        // the same storage arrays Task 6 re-resolves at execute time.
        _snapshotTierAndGate(p, _loadCalls(_executeCalls, proposalId));

        // Store co-proposers and set collaboration deadline
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

        // Get vote weight from ERC20Votes checkpoint at proposal creation
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
        proposal.executedAt = block.timestamp;
        // Start the management-fee clock. Must follow `_activeProposal` so the
        // vault's `totalAssets()` reads live NAV through the now-active lane,
        // and must precede the execute batch so capital deployed by it is
        // picked up by the batch's own base-changing hooks rather than being
        // missed. Accrual runs from here to settle and nowhere else — the gap
        // between proposals is free (design.md Decision 4).
        ISyndicateVault(vault).startManagementAccrual();
        // Counter stays incremented through Executed; decremented once on the
        // Executed -> Settled edge in `_finishSettlement`. `_activeProposal`
        // also guards the Executed window (see `requestUnstakeOwner`).

        // Load the stored execute calls once — reused by the tier re-resolve
        // and the vault batch below (single SLOAD-loop; cold path, no stack risk).
        BatchExecutorLib.Call[] memory calls = _loadCalls(_executeCalls, proposalId);

        // Spec §3.2: fail-safe on stale certification. A proposal priced at
        // tier 0/1 whose adapter demoted (codehash change, revocation) since
        // propose is under-covered — block execution rather than run a
        // possibly-unbounded batch against a bounded-tier coverage price.
        // Finding 5(b): tier alone misses a same-tier RE-certification with a
        // HIGHER extractableBoundBps — also revert when the re-resolved
        // coverage exceeds the propose-time snapshot Plan B will consume.
        (uint8 liveTier, uint256 liveCoverage) =
            _resolveTierAndCoverage(calls, _loadCalls(_settlementCalls, proposalId), proposal.maxCapital);
        if (liveTier > proposal.envelopeTier) revert TierRegressed();
        if (liveCoverage > proposal.requiredCoverage) revert CoverageRegressed();

        // Plan B (spec §3.3a): a coverage-consuming proposal at/above the tier
        // threshold cannot execute without a bond-encumbered approve quorum —
        // silence no longer passes it, so R1 always has an identified,
        // stake-backed approver to hold liable. The §3.10 ROE arithmetic (spec
        // §4 gate 2) is now validated, so the launch threshold is 0 — EVERY
        // tier is fail-closed, not tier 2 alone (ADR 2026-07-27). Coverage was
        // always sized per-tier and correctly; what was missing was enforcing
        // it below tier 2.
        // A revert here leaves the proposal Approved: it expires at `executeBy`
        // unless covering approvals arrive first (the cold-start behaviour
        // §3.3a wants — suppressing the cohort blocks execution, never forces it).
        {
            address ledger = _exposureLedger;
            // `requiredCoverage == 0` keeps optimistic passage: spec §3.3a
            // carves out "proposals that move no coverage-consuming value", and
            // demanding a covering signer for a proposal that can extract
            // nothing is pure throughput loss (review finding M-1). Largely
            // defensive today — `propose` rejects `maxCapital == 0`
            // (`ZeroMaxCapital`), so zero coverage at tier 2 is not currently
            // reachable — but the gate should key on extractable value, which is
            // what the quorum actually underwrites.
            if (
                ledger != address(0) && proposal.requiredCoverage != 0
                    && proposal.envelopeTier >= IExposureLedger(ledger).quorumTierThreshold()
            ) {
                IExposureLedger(ledger)
                    .requireApproveQuorum(address(this), proposalId, asset, proposal.requiredCoverage);
            }
        }

        // Execute the opening calls via the vault. The risk envelope's
        // maxCapital caps the batch's net asset outflow (spec 2026-07-22 §3.1).
        ISyndicateVault(vault).executeGovernorBatch(calls, proposal.maxCapital);

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

        // Run the pre-committed settlement calls under the SAME maxCapital cap
        // as execute. An honest unwind is net-INFLOW (netOutflow == 0), so any
        // finite cap passes it trivially — the cap only binds a malicious
        // proposer who parked extraction in settlementCalls to self-settle
        // after 1h and drain uncapped.
        ISyndicateVault(proposal.vault)
            .executeGovernorBatch(_loadCalls(_settlementCalls, proposalId), proposal.maxCapital);

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
            // G-H2: block lead cancel once all-but-one co-prop has approved,
            // preventing a front-run of the final approve tx. A single
            // co-proposer Draft (total == 1) stays cancellable — "all but one"
            // is zero approvals there, which must not lock the lead out.
            uint256 total = _coProposers[proposalId].length;
            if (total > 1 && _approvedCount[proposalId] + 1 >= total) {
                revert CancelNotAllowedNearQuorum();
            }
            // Sherlock #8: Draft binds the vault — decrement on cancel.
            _decOpen();
        } else {
            revert ProposalNotCancellable();
        }
        _transition(proposal, ProposalState.Cancelled);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Draft/Pending only (Task 25) — once a proposal reaches
    ///      GuardianReview or later, the guardian cohort and execution window
    ///      drive resolution and the owner loses unilateral cancel authority.
    function emergencyCancel(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        _requireVaultOwner(proposal.vault);
        ProposalState s = _commitState(proposal);
        // PR #324 review 4454151855 + Sherlock #8: BOTH Draft and Pending
        // increment the open count, so BOTH must decrement on cancel —
        // otherwise a cancelled Draft soft-locks the vault (every later
        // propose reverts VaultHasOpenProposal).
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
    /// @dev Spec §3.9. ONE reclaim entrypoint rather than hooks in the settle /
    ///      cancel / expiry / emergency paths — fewer seams to keep in sync,
    ///      and the lazy terminal resolution means expiry has no hook to attach
    ///      to anyway. Permissionless is safe because `releaseBond` pays the
    ///      proposer the ESCROW recorded at lock time, so an arbitrary caller
    ///      can only accelerate the refund, never redirect it.
    ///
    ///      Rejected / Expired / Cancelled all return the bond: forfeiture is
    ///      exclusively a passed-challenge outcome (Plan C) — a guardian block
    ///      is not a conviction, and an expired proposal moved no funds.
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
        // Effects before interaction: zeroing first makes the reclaim
        // idempotent (a second call reverts NoBondToReclaim) and closes any
        // re-entrant double-release through a hooked WOOD.
        proposal.proposerBondWood = 0;
        IProposerBondEscrow(escrow).releaseBond(proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Pending only (Task 25) — post-vote veto flows through
    ///      the guardian-review path rather than unilateral owner action.
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
            // G-M1: block Draft -> Pending if the vault already has ANOTHER
            // non-terminal proposal bound to it. Sherlock #8: the *own* Draft
            // is already in the count — "> 1" keeps the semantics "another
            // (non-self) open proposal blocks the transition".
            if (_openProposalCount > 1) revert VaultHasOpenProposal();
            // Transition to Pending -- voting begins
            uint256 reviewPeriod_ = IGuardianRegistry(_guardianRegistry).reviewPeriod();
            _transition(proposal, ProposalState.Pending);
            // -1: see propose() (G-C1).
            proposal.snapshotTimestamp = block.timestamp - 1;
            // Sherlock #14: timing comes from the propose-time snapshot, not
            // live `_params.*`. Single SLOAD; bit-shift to unpack.
            uint256 packed = _draftTimingSnap[proposalId];
            proposal.voteEnd = block.timestamp + uint128(packed); // low 128 = votingPeriod
            proposal.reviewEnd = proposal.voteEnd + reviewPeriod_;
            proposal.executeBy = proposal.reviewEnd + (packed >> 128); // high 128 = executionWindow
            // G-H6: see propose(). vetoThresholdBps reads live BY DESIGN
            // (Sherlock run #2 #5 — owner trust model covers a mid-Draft shift).
            proposal.vetoThresholdBps = _params.vetoThresholdBps;
            // Sherlock #8: the Draft already incremented _openProposalCount at
            // propose time — do NOT re-increment here.
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
    function rejectCollaboration(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_commitState(proposal) != ProposalState.Draft) revert NotDraftState();

        // Sherlock #9: lead-only. A dissenting co-proposer simply withholds
        // approval (the Draft lapses at the collaboration window).
        if (proposal.proposer != msg.sender) revert NotLeadProposer();

        _transition(proposal, ProposalState.Cancelled);
        // Sherlock #8: Draft binds the vault — decrement on reject.
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

    // V1.5 cleanup: dropped `getProposalCalls(uint256)` (concat helper).
    // Off-chain consumers call `getExecuteCalls + getSettlementCalls`
    // directly — same data, no duplicate storage→memory copy loop. The
    // legacy concat dispatcher cost ~150-250 bytes of governor runtime.

    /// @inheritdoc ISyndicateGovernor
    function getExecuteCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        return _loadCalls(_executeCalls, proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getSettlementCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory) {
        return _loadCalls(_settlementCalls, proposalId);
    }

    /// @inheritdoc ISyndicateGovernor
    function getVoteWeight(uint256 proposalId, address voter) external view returns (uint256) {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        // G-H3: Draft proposals have snapshotTimestamp == 0, so reading
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

    /// @notice Narrow proposal view: (`voteEnd`, `reviewEnd`, `vault`).
    /// @dev RETAINED: the guardian registry no longer calls this (it reads its own
    ///      pushed `reviewWindow` and `vaultOf`), but the Plan B `ExposureLedger`
    ///      reads `.vault` through this getter on the approve-vote path. Do not
    ///      remove until that consumer migrates to the registry's `vaultOf`.
    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory v) {
        StrategyProposal storage p = _proposals[proposalId];
        v.voteEnd = p.voteEnd;
        v.reviewEnd = p.reviewEnd;
        v.vault = p.vault;
        // `executeBy + strategyDuration` bounds the LATEST instant this proposal
        // can still be settling, which is what the exposure ledger sizes a
        // guardian's commitment against (ADR 2026-07-26). Read at approve time,
        // before execution has happened, so `executeBy` is the conservative
        // anchor — `executedAt` is not known yet and may never be set.
        v.executeBy = p.executeBy;
        v.strategyDuration = p.strategyDuration;
    }

    /// @dev Narrow proposal tuple returned by `getProposalView`.
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
        uint256 executeBy;
        uint256 strategyDuration;
    }

    // ==================== INTERNAL ====================

    /// @dev Hoisted out of `propose` to keep that function under Yul's
    ///      stack budget when `forge coverage` runs (optimizer + viaIR off).
    ///      Reads `vault` from storage (already written by caller) to keep
    ///      the call-site arg count to two.
    function _initPendingProposal(StrategyProposal storage p, uint256 reviewPeriod_) private {
        // -1 closes the same-block flash-delegate window (G-C1).
        p.snapshotTimestamp = block.timestamp - 1;
        p.voteEnd = block.timestamp + _params.votingPeriod;
        p.reviewEnd = p.voteEnd + reviewPeriod_;
        p.executeBy = p.reviewEnd + _params.executionWindow;
        _transition(p, ProposalState.Pending);
        // G-H6: snapshot vetoThresholdBps so a mid-vote timelock finalize
        // can't retroactively move the threshold for this proposal.
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

    /// @dev Finding 3: without a ceiling, a proposer declares
    ///      maxCapital = uint256.max and the net-outflow cap (vault-enforced on
    ///      execute AND settlement batches) never binds. Ceiling =
    ///      `maxCapitalBps` (governor param, default 100%) of the vault's
    ///      totalAssets() at propose time. Hoisted out of `propose` to stay
    ///      under Yul's stack budget (see `_initPendingProposal`); reads the
    ///      vault from storage (validated == the propose arg at the top of
    ///      `propose`) for the same reason — one fewer stack slot.
    function _checkMaxCapitalCeiling(uint256 maxCapital) private view {
        uint256 ceiling = (IERC4626(GovernorParameters.vault).totalAssets() * maxCapitalBps()) / BPS_DENOMINATOR;
        if (maxCapital > ceiling) revert MaxCapitalExceedsCeiling();
    }

    /// @dev Resolves and stores the proposal's tier + required coverage, then
    ///      runs the Plan B propose-time gates: the maxCapital ceiling check,
    ///      the exposure ledger's covered-TVL cap, and the risk-scaled proposer
    ///      bond (which PULLS WOOD from the proposer — a state-changing
    ///      external call, see the CEI note at the `lockBond` site below).
    ///      Hoisted out of `propose` to keep that function under Yul's stack
    ///      budget (see `_initPendingProposal`). Reads p.maxCapital / p.id from
    ///      storage (written before this call in `propose`) rather than taking
    ///      them as stack arguments — the propose() call site must stay exactly
    ///      `(p, _loadCalls(...))`-shaped or Yul goes "too deep by 1 slot".
    function _snapshotTierAndGate(StrategyProposal storage p, BatchExecutorLib.Call[] memory execCalls) private {
        // Finding 3: envelope ceiling check. Lives here (not in propose's
        // validation block) purely for the same stack-budget reason — an extra
        // call frame in propose() tips it over. Same-tx revert either way.
        _checkMaxCapitalCeiling(p.maxCapital);
        (uint8 tier_, uint256 coverage_) =
            _resolveTierAndCoverage(execCalls, _loadCalls(_settlementCalls, p.id), p.maxCapital);
        p.envelopeTier = tier_;
        p.requiredCoverage = coverage_;
        // Plan B gates (spec §3.7 + §3.9). Skipped when unwired — the
        // pre-ledger safe default matches the tierRegistry pattern.
        address ledger = _exposureLedger;
        if (ledger != address(0)) {
            address asset = IERC4626(GovernorParameters.vault).asset();
            IExposureLedger(ledger).requireWithinCoveredTvlCap(asset, coverage_);
            // Fail on the PROPOSER, not on the cohort (review N4): a duration
            // whose settlement outruns the ledger's booking horizon would
            // otherwise leave every approve vote unable to book, turning the
            // review block-only.
            // `p.executeBy` IS STILL ZERO ON THE COLLABORATIVE PATH (review
            // N11). `_initPendingProposal` writes it, and `propose` only calls
            // that on the non-collaborative branch — a co-proposed strategy
            // sits in Draft until `approveCollaboration`, which re-runs no
            // ledger gate. Passing the raw field made the check
            // `strategyDuration > block.timestamp`, unsatisfiable on any real
            // chain, so the gate silently could not fire for co-proposed
            // strategies. (Foundry's default `t = 1` hides it.)
            //
            // Compute the WORST-CASE deadline instead, which is well-defined
            // before any of it is written and covers both paths from the one
            // site: a Draft may idle for `collaborationWindow` before
            // activating, then run voting -> review -> execution.
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
                    // Bind the bond to THIS escrow: `reclaimProposerBond`
                    // releases against the stored address, so re-pointing
                    // `_bondEscrow` later cannot strand it (the escrow has no
                    // owner and no discretionary exit; its bond key is
                    // (governor, proposalId), so nobody else can address it).
                    // Both writes precede the external call (CEI).
                    p.proposerBondWood = bondWood;
                    p.proposerBondEscrow = escrow;
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

    /// @dev Proposal tier = max tier across EXECUTE calls; coverage = the
    ///      extractable-weighted demand the aggregate exposure cap will consume.
    ///
    ///      Finding 5(a): coverage is the SUM of per-call contributions across
    ///      BOTH execute and settlement calls — a single MAX bound under-counted
    ///      multi-adapter batches (two 50%-bound adapters can each extract
    ///      their bound) and ignored settlement-routed extraction entirely
    ///      (settlement calls are arbitrary, pre-committed calldata). Per-call
    ///      notional is not threaded through in Plan A, so each call
    ///      conservatively uses maxCapital as its notional:
    ///        coverage = maxCapital * Σ(boundBps_i) / 10_000,
    ///      boundBps_i = the certified bound for tier-0/1 calls, 10_000 (full
    ///      notional) for tier-2/uncertified calls. Monotonic and
    ///      never-under-counting; deliberately OVER-counts multi-call batches
    ///      (n tier-2 calls price n×maxCapital). Plan B should thread a
    ///      per-call notional through to tighten this — requiredCoverage is
    ///      inert in Plan A (never consumed), so over-counting costs nothing
    ///      today and can only make Plan B's aggregate cap conservative.
    ///
    ///      With no registry wired every proposal is tier 2 / full notional
    ///      (coverage = maxCapital) — the pre-registry safe default; Plan B's
    ///      cap cannot operate without a registry anyway. `memory` params (not
    ///      calldata) so Task 6 can reuse it on storage-loaded calls at
    ///      execute time.
    function _resolveTierAndCoverage(
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256 maxCapital
    ) private view returns (uint8 tier, uint256 coverage) {
        address registry = _tierRegistry;
        if (registry == address(0)) return (2, maxCapital);
        (uint8 execTier, uint256 execBps) = _scanCalls(registry, execCalls);
        (, uint256 settleBps) = _scanCalls(registry, settleCalls);
        tier = execTier;
        // Σ boundBps ≤ 10_000 * 2 * MAX_CALLS_PER_PROPOSAL and maxCapital ≤
        // totalAssets (propose ceiling) — no realistic overflow.
        coverage = (maxCapital * (execBps + settleBps)) / 10_000;
    }

    /// @dev Max tier and Σ extractable-bound bps (10_000 per tier-2 call)
    ///      across `calls`, resolved through the TierRegistry.
    function _scanCalls(address registry, BatchExecutorLib.Call[] memory calls)
        private
        view
        returns (uint8 tier, uint256 sumBps)
    {
        for (uint256 i = 0; i < calls.length; i++) {
            bytes memory d = calls[i].data;
            bytes4 sel;
            if (d.length >= 4) {
                assembly {
                    sel := mload(add(d, 32))
                }
            }
            (uint8 t, uint16 boundBps) = ITierRegistry(registry).tierOf(calls[i].target, sel);
            if (t > tier) tier = t;
            sumBps += boundBps;
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

            // Must be registered agent
            if (!ISyndicateVault(vault).isAgent(coAgent)) revert NotRegisteredAgent();

            // Cannot be the lead proposer
            if (coAgent == msg.sender) revert DuplicateCoProposer();

            // Minimum split
            if (splitBps < MIN_SPLIT_BPS) revert SplitTooLow();

            // Check for duplicates within co-proposers array
            for (uint256 j = 0; j < i; j++) {
                if (coProposers[j].agent == coAgent) revert DuplicateCoProposer();
            }

            totalCoSplitBps += splitBps;
        }

        // Lead split = 10000 - totalCoSplitBps (must be >= 10%)
        if (totalCoSplitBps > 9000) revert LeadSplitTooLow();
    }

    // State resolution folded into ProposalLifecycle: mutating callers use
    // `_commitState` (resolves + fires the registry economic commit on the
    // concluding review transition), read-only callers use `_computeState` /
    // `stateOf` (the ONE pure resolver — a TRUE view that never lags
    // determinable reality).

    /// @dev Finalize a settled proposal: compute P&L, distribute fees, clear
    ///      counters. Invoked by both happy-path `settleProposal` and the
    ///      emergency settle lifecycle (`unstick` / `finalizeEmergencySettle`).
    ///
    ///      G-H1: PnL is measured purely against `IERC20(asset).balanceOf(vault)`.
    ///      Any non-asset balance the strategy still holds at settlement time
    ///      (mTokens / LP NFTs / reward tokens / perp margin) counts as a
    ///      LOSS of the corresponding asset balance the strategy started
    ///      with. Strategies MUST fully unwind all non-asset positions and
    ///      return the underlying to the vault before `_finishSettlement` is
    ///      called. If a strategy cannot unwind, callers should wait past
    ///      `strategyDuration` and drive the emergency-settle path with
    ///      governance-approved custom calls via `emergencySettleWithCalls`.
    function _finishSettlement(uint256 proposalId, StrategyProposal storage proposal)
        internal
        returns (int256 pnl, uint256 agentFee)
    {
        address vault = proposal.vault;
        address asset = IERC4626(vault).asset();

        // Asset-only measurement (see NatSpec above). PnL is the realized float
        // delta minus the interim LP net flow: Lane A deposits and instant
        // exits during the proposal move the vault's float but are principal,
        // not strategy performance, so charging fees on them would be wrong.
        // The vault resets the accumulator in `onProposalSettled` (called below,
        // after fees).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 snapshot = _capitalSnapshots[proposalId];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 balanceAdjusted = IERC20(asset).balanceOf(vault);
        pnl = int256(balanceAdjusted) - int256(snapshot) - ISyndicateVault(vault).interimNetFlow();

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

        // H2/M4: a self-fee'd strategy (custody model — LPs deposit/redeem into the
        // strategy, shares minted/burned on the vault) crystallises its own fees; the
        // governor's float-delta PnL would misread net deposits as profit and double-
        // charge. Read the propose-time snapshot, never a live call (TOCTOU +
        // brick-on-revert).
        //
        // The opt-out covers the PERFORMANCE leg only. `selfManagesFees` exists
        // because float-delta PnL misreads custody deposits as profit — a defect
        // in profit measurement. The management fee does not use PnL at all
        // (it is capital x time), so the reason for the exemption does not reach
        // it (design.md Decision 3).
        // Always called, even on the self-managed path — see `chargeNew`.
        {
            uint256 perfFee;
            (agentFee, perfFee) =
                _chargePerformanceFee(proposalId, vault, asset, proposal.proposer, !proposal.selfManagesFees);
            totalFee += perfFee;
        }

        // Stamp the frozen Lane B settle price for this proposal AFTER fees so
        // queued redeemers/depositors settle against the post-fee NAV. No-op if
        // the vault has no withdrawal queue. (Pre-existing gap: no settle path
        // ever called this — the async queue could never settle.)
        ISyndicateVault(vault).onProposalSettled(proposalId);

        emit ProposalSettled(proposalId, vault, pnl, totalFee, block.timestamp - proposal.executedAt);
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
    ///      instead (design.md Decision 8).
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
    ///      Unlike the four-step waterfall this replaced, the two fees are
    ///      independent and each is ONE division of ONE base. No recipient's
    ///      share is reduced by another's.
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
    ///      Escape hatch: IStrategy.selfManagesFees() == true (snapshotted at
    ///      propose) skips the PERFORMANCE leg only — the management fee does
    ///      not use PnL, so the misread-PnL reason for the exemption does not
    ///      reach it (design.md Decision 3). No in-tree strategy currently sets
    ///      the flag; any that does must implement its own protocol-fee leg.
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

        // The fee owed for the WHOLE proposal, including the time exiters'
        // capital was present — the accumulator kept ticking on it.
        mgmtFee = (assetSeconds * rateBps) / (BPS_DENOMINATOR * 365 days);

        // Release what instant exiters already paid. This is the fix for the
        // double-charge: the figure above still contains the exiters' share, so
        // paying out the full amount must be funded partly from their parked
        // contribution rather than entirely from the fund. Releasing raises
        // `totalAssets()` by exactly that contribution, so the depositors who
        // stayed bear only `mgmtFee - crystallized`. (The performance leg needs
        // no equivalent: exited shares are burned, so they are absent from its
        // base by construction.)
        uint256 crystallized = ISyndicateVault(vault).consumeCrystallizedMgmt();
        if (crystallized > mgmtFee) {
            // Rounding only — the parked amount is a pro-rata slice of the same
            // accrual. Pay out what was actually collected.
            mgmtFee = crystallized;
        }

        if (mgmtFee == 0) return 0;

        IProtocolConfig.MgmtSplit memory s = prop.snapshotMgmtSplit;
        // A zero-sum split is unreachable for a real config (ProtocolConfig is
        // born valid and validates every write), but skipping beats reverting:
        // a bricked settlement is the worse failure (design.md Decision 8).
        if (uint256(s.agentBps) + s.protocolBps + s.guardianBps != BPS_DENOMINATOR) return 0;

        uint256 toProtocol = (mgmtFee * s.protocolBps) / BPS_DENOMINATOR;
        uint256 toGuardian = (mgmtFee * s.guardianBps) / BPS_DENOMINATOR;
        // A leg whose recipient was never configured pays nothing and folds
        // into the agent's remainder. Paying it anyway would send to
        // address(0): the transfer reverts, `_payFee` escrows it against
        // address(0), and it becomes permanently unclaimable — a silent burn
        // of 10% of every management fee. This could not happen under the
        // previous model, where the guardian leg was its own rate that
        // defaulted to zero; here it is a share of the split and is always
        // present.
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
    ///      divide it four ways in ONE split — not the sequential waterfall this
    ///      replaces, which compounded four separate haircuts on the same
    ///      profit. Each recipient's share is computed from the full fee, never
    ///      from what another recipient left behind.
    ///
    ///      Must run AFTER the management fee: that fee lowers the vault's
    ///      assets and therefore its price per share, so reading the above-mark
    ///      base first would charge performance on assets already taken.
    /// @return agentFee The agent's slice, reported for the settle event.
    /// @return perfFee  The whole fee charged.
    /// @param chargeNew False on the `selfManagesFees` path: the strategy
    ///        collects its own performance fee, so settlement charges none.
    ///        The function still runs, because fees already crystallized from
    ///        instant exiters must be released and paid — skipping the call
    ///        entirely would strand them in the vault forever, permanently
    ///        excluded from `totalAssets()` and therefore lost to depositors.
    function _chargePerformanceFee(uint256 proposalId, address vault, address asset, address proposer, bool chargeNew)
        internal
        returns (uint256 agentFee, uint256 perfFee)
    {
        StrategyProposal storage prop = _proposals[proposalId];

        // Profit measured against the fund's previous peak, not against this
        // proposal's own starting balance — a fund that fell and recovered has
        // already paid for this ground.
        //
        // Read BEFORE releasing the parked performance fees: those assets sit
        // in the vault but already belong to the recipients, and releasing them
        // raises `totalAssets()` and therefore the price per share. Reading
        // after would charge a performance fee on money the fund does not own.
        uint256 base = chargeNew ? ISyndicateVault(vault).aboveHighWaterMark() : 0;

        if (base > 0) {
            // Snapshotted at propose so it matches what voters approved, then
            // clamped to the governor's tunable ceiling so a later cap reduction
            // still bites. The clamp emits and continues rather than reverting.
            uint256 perfFeeBps = _clampPerformanceFee(proposalId, prop.performanceFeeBps, _params.maxPerformanceFeeBps);
            perfFee = (base * perfFeeBps) / BPS_DENOMINATOR;
        }

        // Now safe to release: whatever instant exiters already paid is
        // distributed on top of what settlement charges the stayers.
        perfFee += ISyndicateVault(vault).consumeCrystallizedPerf();

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
    /// @dev G-M10: Assumes a non-fee-on-transfer (FOT) asset. `distributed += share` is
    ///      booked at the requested-transfer amount, not the received amount, so the
    ///      lead's rounding remainder is computed against the requested total. If a
    ///      future vault ever onboards an FOT asset, `_distributeAgentFee` would
    ///      double-count the burn — the lead would be credited what was skimmed and
    ///      under-paid to match. USDC (the only V1 asset) is non-FOT; this branch
    ///      stays pinned by the `non-FOT` asset requirement in the vault audit.
    function _distributeAgentFee(uint256 proposalId, address vault, address asset, address proposer, uint256 agentFee)
        internal
    {
        if (agentFee == 0) return;
        CoProposer[] storage coProps = _coProposers[proposalId];
        if (coProps.length > 0) {
            uint256 distributed = 0;
            for (uint256 i = 0; i < coProps.length; i++) {
                // Sherlock run #2 #13: stop once the budget is exhausted — pre-fix
                // the loop kept iterating and a later co-proposer's non-zero share
                // pushed `distributed` past `agentFee` (the post-loop clamp only
                // fixed bookkeeping, not the already-executed transfers).
                if (distributed >= agentFee) break;
                bool active = ISyndicateVault(vault).isAgent(coProps[i].agent);
                if (!active) continue;
                uint256 share = (agentFee * coProps[i].splitBps) / BPS_DENOMINATOR;
                if (share == 0) share = 1;
                // Cap to remaining budget — handles both the rounding-floor pad
                // (share = 1) and any splitBps overflow.
                uint256 remaining = agentFee - distributed;
                if (share > remaining) share = remaining;
                _payFee(vault, asset, coProps[i].agent, share);
                distributed += share;
            }
            uint256 leadShare = agentFee - distributed;
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
    ///      `claimUnclaimedFees` once the failure condition is lifted. (W-1)
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
    /// @dev No `nonReentrant` required: CEI is respected (escrow slot cleared
    ///      before the external `transferPerformanceFee` call). A reentrant
    ///      call with the same `(vault, msg.sender, token)` key sees a zeroed
    ///      slot and short-circuits. Different keys are independent escrows.
    function claimUnclaimedFees(address vault, address token) external {
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
    ///      RECOVERY (corrected, review finding I-3): `address(0)` is accepted
    ///      here, but the factory has NO path that passes it — both callers
    ///      (`createSyndicate` and `pushWiring`) SKIP unset slots rather than
    ///      writing zero, precisely so wiring can never be silently removed.
    ///      Un-wiring an already-wired governor is therefore not reachable in
    ///      practice. Recover instead at the ledger (ledger-owner:
    ///      `setAssetFeed` / `setCoveredTvlCapUsd`), or point the factory at a
    ///      fresh permissive ledger and `pushWiring` this governor.
    function setExposureLedger(address newLedger) external onlyFactory {
        // NOT WHILE PROPOSALS ARE OPEN (review n3). A proposal created before
        // the ledger existed carries no booked coverage — nobody could have
        // booked any — but `executeProposal` starts demanding it the moment the
        // ledger is wired, so those proposals become permanently unexecutable.
        //
        // The M3 change made this worse rather than better: the approve hook now
        // books nothing instead of reverting, so the failure moved from LOUD at
        // vote time to SILENT until execute. Refusing the wiring is the only
        // point where it is still visible.
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
