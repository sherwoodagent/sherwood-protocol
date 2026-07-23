// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IProtocolConfig} from "./interfaces/IProtocolConfig.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
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

    /// @notice Proposal ID -> proposal data
    mapping(uint256 => StrategyProposal) private _proposals;

    /// @notice Proposal ID -> voter -> bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Proposal ID -> vault balance at execution time
    mapping(uint256 => uint256) private _capitalSnapshots;

    /// @notice Currently executing proposal ID (0 if none)
    uint256 private _activeProposal;

    /// @notice Timestamp of last settlement
    uint256 private _lastSettledAt;

    // ── Collaborative proposal storage ──

    /// @notice Proposal ID -> co-proposers array
    mapping(uint256 => CoProposer[]) private _coProposers;

    /// @notice Proposal ID -> co-proposer address -> approved
    /// @dev `internal` (no auto-getter): read only within the governor; not in
    ///      ISyndicateGovernor / cli / app / subgraph / tests. Bytecode lever.
    mapping(uint256 => mapping(address => bool)) internal coProposerApprovals;

    /// @notice Proposal ID -> deadline for co-proposer consent
    /// @dev `internal` (no auto-getter): governor-only read. Bytecode lever.
    mapping(uint256 => uint256) internal collaborationDeadline;

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

    /// @notice Guardian registry. Set in `initialize`; required (non-zero).
    ///         Fees always route here — no separate recipient slot.
    address internal _guardianRegistry;

    // ── Guardian-review storage ──
    // `_emergencyCallsHashes` and `_emergencyCalls` live in GuardianRegistry.
    // Two mapping slots reclaimed into __gap.

    /// @notice Count of non-terminal proposals (Pending, GuardianReview, Approved, Executed).
    ///         Used by `GuardianRegistry.requestUnstakeOwner` alongside
    ///         `_activeProposal` to block owner rage-quit while any proposal
    ///         is in flight. Incremented on Draft -> Pending. Decremented on
    ///         the terminal edge (Rejected / Expired / Cancelled / Settled).
    uint256 private _openProposalCount;

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
    ///      shrunk by 1 for _tierRegistry — Task 5)
    uint256[33] private __gap;

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

    function _getProposal(uint256 id) internal view override returns (StrategyProposal storage) {
        return _proposals[id];
    }

    function _getSettlementCalls(uint256 id) internal view override returns (BatchExecutorLib.Call[] storage) {
        return _settlementCalls[id];
    }

    function _getRegistry() internal view override returns (IGuardianRegistry) {
        return IGuardianRegistry(_guardianRegistry);
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
        // drawdown declaration capped at 100%.
        if (envelope.maxCapital == 0) revert ZeroMaxCapital();
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
        {
            IProtocolConfig cfg = IProtocolConfig(protocolConfig);
            p.snapshotProtocolFeeBps = cfg.protocolFeeBps();
            p.snapshotProtocolFeeRecipient = cfg.protocolFeeRecipient();
            p.snapshotGuardianFeeBps = cfg.guardianFeeBps();
            p.snapshotGuardiansFeeRecipient = cfg.guardiansFeeRecipient();
        }
        if (isCollaborative) {
            p.state = ProposalState.Draft;
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
        // calls; requiredCoverage feeds the aggregate exposure cap (Plan B).
        // Resolved from the STORED calls (via _loadCalls) rather than the
        // calldata array so the `envelope`/`executeCalls` calldata refs are dead
        // by this point — keeps propose() under Yul's stack budget. Reads the
        // same storage array Task 6 re-resolves at execute time.
        _snapshotTier(p, _loadCalls(_executeCalls, proposalId));

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
        if (_resolveState(proposal) != ProposalState.Pending) revert NotWithinVotingPeriod();
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
        if (_resolveState(proposal) != ProposalState.Approved) revert ProposalNotApproved();

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
        proposal.state = ProposalState.Executed;
        proposal.executedAt = block.timestamp;
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
        (uint8 liveTier,) = _resolveTier(calls, proposal.maxCapital);
        if (liveTier > proposal.envelopeTier) revert TierRegressed();

        // Execute the opening calls via the vault. The risk envelope's
        // maxCapital caps the batch's net asset outflow (spec 2026-07-22 §3.1).
        ISyndicateVault(vault).executeGovernorBatch(calls, proposal.maxCapital);

        emit ProposalExecuted(proposalId, vault, balanceBefore);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @notice Settle a strategy. Proposer can settle at any time; anyone else must wait for duration.
    function settleProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_resolveState(proposal) != ProposalState.Executed) revert ProposalNotExecuted();

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
        ProposalState s = _resolveState(proposal);
        if (s == ProposalState.Pending) {
            // Pending: only during the voting period.
            if (block.timestamp > proposal.voteEnd) revert ProposalNotCancellable();
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
        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Draft/Pending only (Task 25) — once a proposal reaches
    ///      GuardianReview or later, the guardian cohort and execution window
    ///      drive resolution and the owner loses unilateral cancel authority.
    function emergencyCancel(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        _requireVaultOwner(proposal.vault);
        ProposalState s = _resolveState(proposal);
        // PR #324 review 4454151855 + Sherlock #8: BOTH Draft and Pending
        // increment the open count, so BOTH must decrement on cancel —
        // otherwise a cancelled Draft soft-locks the vault (every later
        // propose reverts VaultHasOpenProposal).
        if (s != ProposalState.Pending && s != ProposalState.Draft) revert ProposalNotCancellable();
        _decOpen();
        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @dev Decrement the open-proposal counter AND stamp the settle cooldown.
    ///      PR #359 review #1: `_lastSettledAt` is bumped HERE, the single
    ///      chokepoint, rather than at each caller — the lazy `_resolveState`
    ///      terminal path is reachable permissionlessly via
    ///      `resolveProposalState` and previously skipped the bump, letting
    ///      propose→resolve→propose→execute dodge the cooldown.
    function _decOpen() private {
        --_openProposalCount;
        _lastSettledAt = block.timestamp;
    }

    /// @inheritdoc ISyndicateGovernor
    function openProposalCount() public view override(GovernorParameters, ISyndicateGovernor) returns (uint256) {
        return _openProposalCount;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Pending only (Task 25) — post-vote veto flows through
    ///      the guardian-review path rather than unilateral owner action.
    function vetoProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        _requireVaultOwner(proposal.vault);
        if (_resolveState(proposal) != ProposalState.Pending) revert ProposalNotCancellable();
        proposal.state = ProposalState.Rejected;
        // `_activeProposal` is unset during Pending (only set by execute).
        _decOpen();
        emit ProposalVetoed(proposalId, msg.sender);
    }

    // ==================== COLLABORATIVE PROPOSALS ====================

    /// @inheritdoc ISyndicateGovernor
    function approveCollaboration(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        ProposalState storedState = proposal.state;
        ProposalState state = _resolveState(proposal);
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
            proposal.state = ProposalState.Pending;
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
            emit CollaborationTransitionedToPending(proposalId);
        }
    }

    /// @inheritdoc ISyndicateGovernor
    function rejectCollaboration(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_resolveState(proposal) != ProposalState.Draft) revert NotDraftState();

        // Sherlock #9: lead-only. A dissenting co-proposer simply withholds
        // approval (the Draft lapses at the collaboration window).
        if (proposal.proposer != msg.sender) revert NotLeadProposer();

        proposal.state = ProposalState.Cancelled;
        // Sherlock #8: Draft binds the vault — decrement on reject.
        _decOpen();
        emit CollaborationRejected(proposalId, msg.sender);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ==================== VAULT MANAGEMENT ====================

    /// @notice Permissionless: flushes a proposal's lazy terminal-state
    ///         transition (Rejected / Expired) so that
    ///         `_openProposalCount` dec commits.
    /// @dev `_resolveState` dec's the counter when it transitions the proposal
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
    function resolveProposalState(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (proposal.id == 0) revert ProposalNotFound();
        _resolveState(proposal);
    }

    // ==================== VIEWS ====================

    /// @inheritdoc ISyndicateGovernor
    function getProposal(uint256 proposalId) external view returns (StrategyProposal memory p) {
        p = _proposals[proposalId];
        p.state = _resolveStateView(_proposals[proposalId]);
    }

    /// @inheritdoc ISyndicateGovernor
    function getProposalState(uint256 proposalId) external view returns (ProposalState) {
        return _resolveStateView(_proposals[proposalId]);
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
    function getProposalTier(uint256 proposalId) external view returns (uint8) {
        return _proposals[proposalId].envelopeTier;
    }

    /// @inheritdoc ISyndicateGovernor
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256) {
        return _proposals[proposalId].requiredCoverage;
    }

    /// @notice Narrow proposal view consumed by the guardian registry.
    /// @dev Returns a tuple (`voteEnd`, `reviewEnd`, `vault`) encoded to match
    ///      `GuardianRegistry.IGovernorMinimal.ProposalView`. Keeps the registry
    ///      decoupled from the full `StrategyProposal` ABI.
    function getProposalView(uint256 proposalId) external view returns (ProposalViewLite memory v) {
        StrategyProposal storage p = _proposals[proposalId];
        v.voteEnd = p.voteEnd;
        v.reviewEnd = p.reviewEnd;
        v.vault = p.vault;
    }

    /// @dev Mirrors `GuardianRegistry.IGovernorMinimal.ProposalView` for ABI parity.
    struct ProposalViewLite {
        uint256 voteEnd;
        uint256 reviewEnd;
        address vault;
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
        p.state = ProposalState.Pending;
        // G-H6: snapshot vetoThresholdBps so a mid-vote timelock finalize
        // can't retroactively move the threshold for this proposal.
        p.vetoThresholdBps = _params.vetoThresholdBps;
        // Draft doesn't count (not binding on the vault); Pending does.
        unchecked {
            ++_openProposalCount;
        }
    }

    /// @dev Thin store-wrapper around `_resolveTier`, hoisted out of `propose`
    ///      to keep that function under Yul's stack budget (see
    ///      `_initPendingProposal`). Implicit calldata→memory copy of `calls`.
    function _snapshotTier(StrategyProposal storage p, BatchExecutorLib.Call[] memory calls) private {
        // Reads p.maxCapital from storage (written immediately before this call
        // in `propose`) rather than taking it as a stack argument — keeps the
        // propose() call site 1 slot under Yul's stack budget.
        (uint8 tier_, uint256 coverage_) = _resolveTier(calls, p.maxCapital);
        p.envelopeTier = tier_;
        p.requiredCoverage = coverage_;
    }

    /// @dev Proposal tier = max tier across execute calls; coverage = the
    ///      extractable-weighted demand the aggregate exposure cap will consume.
    ///      With no registry wired every proposal is tier 2 / full notional —
    ///      strictly the safe default. `memory` params (not calldata) so Task 6
    ///      can reuse it on storage-loaded calls at execute time.
    function _resolveTier(BatchExecutorLib.Call[] memory calls, uint256 maxCapital)
        private
        view
        returns (uint8 tier, uint256 coverage)
    {
        address registry = _tierRegistry;
        if (registry == address(0)) return (2, maxCapital);
        uint16 maxBoundBps = 0;
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
            if (boundBps > maxBoundBps) maxBoundBps = boundBps;
        }
        coverage = tier == 2 ? maxCapital : (maxCapital * maxBoundBps) / 10_000;
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

    /// @dev Store co-proposers, set deadline, emit event
    function _storeCoProposers(uint256 proposalId, CoProposer[] calldata coProposers) internal {
        for (uint256 i = 0; i < coProposers.length; i++) {
            _coProposers[proposalId].push(coProposers[i]);
        }
        collaborationDeadline[proposalId] = block.timestamp + _params.collaborationWindow;

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

    /// @dev Compute the resolved state and persist any transitions to storage.
    ///      Drives registry-side review resolution when the review window has
    ///      elapsed and no cached resolution exists yet (mutating path).
    function _resolveState(StrategyProposal storage proposal) internal returns (ProposalState) {
        ProposalState stored = proposal.state;
        ProposalState resolved = _resolveStateView(proposal);

        // If the review window ended and the registry hasn't cached a resolution
        // yet, call `resolveReview` once to finalize it. Mirrors the view-path
        // logic but commits the registry-side state.
        if (resolved == ProposalState.GuardianReview && block.timestamp > proposal.reviewEnd) {
            bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(address(this), proposal.id);
            if (blocked) {
                resolved = ProposalState.Rejected;
            } else {
                resolved = block.timestamp > proposal.executeBy ? ProposalState.Expired : ProposalState.Approved;
            }
            emit GuardianReviewResolved(proposal.id, blocked);
        }

        if (resolved != stored) {
            proposal.state = resolved;
            // Sherlock #8: Draft binds the vault — both Draft and non-Draft
            // terminal transitions decrement. Draft additionally emits its
            // telemetry event.
            if (resolved == ProposalState.Rejected || resolved == ProposalState.Expired) {
                _decOpen();
                if (stored == ProposalState.Draft) emit CollaborationDeadlineExpired(proposal.id);
            }
        }
        return resolved;
    }

    /// @dev Pure state resolution logic (view-only, no storage writes).
    ///      Optimistic governance: proposals pass the vote unless AGAINST votes
    ///      reach veto threshold, then transition to GuardianReview until the
    ///      review window ends. After review, they map to Approved or Rejected
    ///      based on the registry's cached resolution.
    function _resolveStateView(StrategyProposal storage proposal) internal view returns (ProposalState) {
        ProposalState stored = proposal.state;

        if (stored == ProposalState.Draft) {
            return block.timestamp > collaborationDeadline[proposal.id] ? ProposalState.Expired : ProposalState.Draft;
        }

        if (stored == ProposalState.Pending) {
            if (block.timestamp <= proposal.voteEnd) return ProposalState.Pending;

            // Voting ended -- optimistic: approved unless AGAINST votes reach veto threshold
            // G-H4: skip the veto check when pastTotalSupply == 0, otherwise
            // the threshold collapses to 0 and every proposal auto-rejects.
            // G-H6: read the snapshot taken at Draft -> Pending, not the live
            // `_params.vetoThresholdBps`, so mid-vote timelock finalizes
            // don't move the bar for in-flight proposals.
            uint256 pastTotalSupply = IVotes(proposal.vault).getPastTotalSupply(proposal.snapshotTimestamp);
            if (pastTotalSupply > 0) {
                uint256 vetoThreshold = (pastTotalSupply * proposal.vetoThresholdBps) / BPS_DENOMINATOR;
                if (proposal.votesAgainst >= vetoThreshold) {
                    return ProposalState.Rejected;
                }
            }

            // Voting passed — fall through to guardian-review handling below.
            return _resolveAfterVote(proposal);
        }

        if (stored == ProposalState.GuardianReview) {
            return _resolveAfterVote(proposal);
        }

        if (stored == ProposalState.Approved) {
            return block.timestamp > proposal.executeBy ? ProposalState.Expired : ProposalState.Approved;
        }

        return stored;
    }

    /// @dev Maps a vote-passed proposal to GuardianReview / Approved / Rejected / Expired
    ///      based on `reviewEnd` and the registry's cached review state.
    function _resolveAfterVote(StrategyProposal storage proposal) internal view returns (ProposalState) {
        if (block.timestamp <= proposal.reviewEnd) return ProposalState.GuardianReview;

        (, bool resolved, bool blocked, bool cohortTooSmall) =
            IGuardianRegistry(_guardianRegistry).getReviewState(address(this), proposal.id);
        if (resolved) {
            if (blocked && !cohortTooSmall) return ProposalState.Rejected;
            return block.timestamp > proposal.executeBy ? ProposalState.Expired : ProposalState.Approved;
        }
        // Review window ended but registry hasn't resolved yet — remain in
        // GuardianReview. Mutating callers (`_resolveState`) will trigger
        // `resolveReview` which maps to Approved / Rejected.
        return ProposalState.GuardianReview;
    }

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
        proposal.state = ProposalState.Settled;
        delete _capitalSnapshots[proposalId];
        // Open emergency reviews are NOT auto-cancelled here — they resolve
        // naturally via `resolveEmergencyReview` at reviewEnd (slashing if the
        // block quorum was met, no-op otherwise) so an owner who opened an
        // adversarial emergency cannot dodge slash by racing a settle.
        _decOpen();

        uint256 totalFee = 0;
        if (pnl > 0) {
            // H2/M4: a self-fee'd strategy (custody model — LPs deposit/redeem into the
            // strategy, shares minted/burned on the vault) crystallises its own fees; the
            // governor's float-delta PnL would misread net deposits as profit and double-
            // charge. Such strategies opt out of ALL governor settle-fees. Read the
            // propose-time snapshot, never a live call (TOCTOU + brick-on-revert).
            if (!proposal.selfManagesFees) {
                (agentFee, totalFee) = _distributeFees(
                    proposalId, vault, asset, proposal.proposer, proposal.performanceFeeBps, uint256(pnl)
                );
            }
        }

        // Stamp the frozen Lane B settle price for this proposal AFTER fees so
        // queued redeemers/depositors settle against the post-fee NAV. No-op if
        // the vault has no withdrawal queue. (Pre-existing gap: no settle path
        // ever called this — the async queue could never settle.)
        ISyndicateVault(vault).onProposalSettled(proposalId);

        emit ProposalSettled(proposalId, vault, pnl, totalFee, block.timestamp - proposal.executedAt);
    }

    /// @dev Clamp `fee` to `cap`, emitting FeeClamped when the clamp fires.
    function _clampPerformanceFee(uint256 proposalId, uint256 fee, uint256 cap) private returns (uint256) {
        if (fee > cap) {
            emit FeeClamped(proposalId, fee, cap);
            return cap;
        }
        return fee;
    }

    /// @dev Distribute protocol, agent, and management fees. Extracted to avoid stack-too-deep.
    ///      Reads fee config from the propose-time snapshot so settlement uses rates and
    ///      recipients that voters actually approved, not any post-vote change.
    ///
    ///      ── THE FEE MAP ─ every bps source, its owner, its cap, its snapshot point ──
    ///      Stage order (1–2 are parallel slices of gross profit; only 3–4 waterfall,
    ///      each computed on what the previous left):
    ///        1. protocolFee  = grossPnl · protocolFeeBps
    ///             source: ProtocolConfig.protocolFeeBps (owner: protocol multisig)
    ///             snapshot: propose time → prop.snapshotProtocolFeeBps/-Recipient
    ///        2. guardianFee  = grossPnl · guardianFeeBps
    ///             source: ProtocolConfig.guardianFeeBps (owner: protocol multisig)
    ///             snapshot: propose time → prop.snapshotGuardianFeeBps/-Recipient
    ///             delivery: WOOD airdrop via Merkl, attributed by GuardianFeeAccrued
    ///        3. agentFee     = netPnl · perfFeeBps
    ///             source: vault.agentFeeBps() (owner: VAULT owner; offset-by-one
    ///             sentinel, default FeeConstants.DEFAULT_AGENT_FEE_BPS = 5%)
    ///             caps: vault-side FeeConstants.MAX_PERFORMANCE_FEE_BPS (15%) at set;
    ///             clamped AGAIN here to the governor's live _params.maxPerformanceFeeBps
    ///             (owner: governor params; the cap-of-caps lives in GovernorParameters)
    ///             snapshot: propose time → prop.performanceFeeBps; split across
    ///             co-proposers by _distributeAgentFee
    ///        4. mgmtFee      = (netPnl − agentFee) · managementFeeBps
    ///             source: vault.managementFeeBps() (owner: vault owner, set at init;
    ///             read LIVE at settle — the one non-snapshotted rate)
    ///      Escape hatch: IStrategy.selfManagesFees() == true (snapshotted at propose)
    ///      skips this ENTIRE waterfall — the strategy must self-collect including the
    ///      protocol's cut (e.g. LeveragedAeroFees.protocolFeeOwed).
    ///      Failure mode: any recipient transfer that reverts escrows in _unclaimedFees
    ///      (pull via claimUnclaimedFees) so settlement never bricks.
    function _distributeFees(
        uint256 proposalId,
        address vault,
        address asset,
        address proposer,
        uint256 perfFeeBps,
        uint256 profit
    ) internal returns (uint256 agentFee, uint256 totalFee) {
        uint256 protocolFee = 0;
        uint256 guardianFee = 0;

        // Read fee config from the propose-time snapshot.
        StrategyProposal storage prop = _proposals[proposalId];
        uint256 snapshotProtocolFeeBps = prop.snapshotProtocolFeeBps;
        address snapshotProtocolFeeRecipient = prop.snapshotProtocolFeeRecipient;
        uint256 snapshotGuardianFeeBps = prop.snapshotGuardianFeeBps;
        address snapshotGuardiansFeeRecipient = prop.snapshotGuardiansFeeRecipient;

        // Protocol fee taken first from gross profit.
        if (snapshotProtocolFeeBps > 0) {
            protocolFee = (profit * snapshotProtocolFeeBps) / BPS_DENOMINATOR;
            if (protocolFee > 0) {
                if (snapshotProtocolFeeRecipient == address(0)) revert InvalidProtocolFeeRecipient();
                _payFee(vault, asset, snapshotProtocolFeeRecipient, protocolFee);
            }
        }

        // Guardian fee — slice of gross PnL routed to the team guardians-fee
        // recipient (a multisig). Swapped to WOOD off-chain and airdropped to
        // approvers/delegators weekly via Merkl. Per-proposal attribution is the
        // GuardianFeeAccrued event + the registry getApproverWeights getter.
        if (snapshotGuardianFeeBps > 0) {
            guardianFee = (profit * snapshotGuardianFeeBps) / BPS_DENOMINATOR;
            if (guardianFee > 0) {
                // Emit the attribution signal ONLY on actual delivery. If the
                // transfer escrows (recipient blacklisted), the asset stays in
                // the vault pending `claimUnclaimedFees` — emitting here would
                // make the off-chain Merkl bot airdrop WOOD for a fee that was
                // never delivered, then double-pay when the escrow is recovered.
                if (_payFee(vault, asset, snapshotGuardiansFeeRecipient, guardianFee)) {
                    emit GuardianFeeAccrued(proposalId, asset, snapshotGuardiansFeeRecipient, guardianFee);
                }
            }
        }

        uint256 netProfit = profit - protocolFee - guardianFee;

        // Agent performance fee from net profit. `perfFeeBps` was snapshotted
        // from the vault at propose time (so it matches what voters approved);
        // clamp it to the governor's tunable maxPerformanceFeeBps so a later
        // cap reduction still applies.
        perfFeeBps = _clampPerformanceFee(proposalId, perfFeeBps, _params.maxPerformanceFeeBps);
        agentFee = (netProfit * perfFeeBps) / BPS_DENOMINATOR;

        // Management fee from remainder after agent fee
        uint256 mgmtFee = ((netProfit - agentFee) * ISyndicateVault(vault).managementFeeBps()) / BPS_DENOMINATOR;

        if (agentFee > 0) {
            _distributeAgentFee(proposalId, vault, asset, proposer, agentFee);
        }
        if (mgmtFee > 0) {
            _payFee(vault, asset, ISyndicateVault(vault).owner(), mgmtFee);
        }

        totalFee = protocolFee + guardianFee + agentFee + mgmtFee;
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
    /// @dev Does NOT require `whenNoActiveProposal` — factory may need to push
    ///      emergency param corrections even during an active proposal.
    function forceSetParams(GovernorParams calldata params) external onlyFactory {
        _validateParamBounds(params);
        _params = params;
        emit ParameterChangeFinalized("forceSetParams", 0, 0);
    }
}
