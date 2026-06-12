// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {GovernorParameters} from "./GovernorParameters.sol";
import {GovernorEmergency} from "./GovernorEmergency.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
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
contract SyndicateGovernor is GovernorParameters, GovernorEmergency, UUPSUpgradeable {
    using EnumerableSet for EnumerableSet.AddressSet;

    // ── Storage (existing -- DO NOT reorder) ──
    // P2-1: `_params`, `_protocolFeeBps`, `_protocolFeeRecipient`,
    //       `_guardianFeeBps`, `factory` live in `GovernorParameters`.

    /// @notice Proposal ID counter (1-indexed)
    uint256 private _proposalCount;

    /// @notice Proposal ID -> proposal data
    mapping(uint256 => StrategyProposal) private _proposals;

    /// @notice Proposal ID -> voter -> bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    /// @notice Proposal ID -> vault balance at execution time
    mapping(uint256 => uint256) private _capitalSnapshots;

    /// @notice Vault -> currently executing proposal ID (0 if none)
    mapping(address => uint256) private _activeProposal;

    /// @notice Vault -> timestamp of last settlement
    mapping(address => uint256) private _lastSettledAt;

    /// @notice Set of registered vault addresses
    EnumerableSet.AddressSet private _registeredVaults;

    // ── Collaborative proposal storage ──

    /// @notice Proposal ID -> co-proposers array
    mapping(uint256 => CoProposer[]) private _coProposers;

    /// @notice Proposal ID -> co-proposer address -> approved
    mapping(uint256 => mapping(address => bool)) public coProposerApprovals;

    /// @notice Proposal ID -> deadline for co-proposer consent
    mapping(uint256 => uint256) public collaborationDeadline;

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

    // `_protocolFeeBps` / `_protocolFeeRecipient` / `_guardianFeeBps` live in
    // `GovernorParameters`.

    /// @notice Guardian registry. Set in `initialize`; required (non-zero).
    ///         Fees always route here — no separate recipient slot.
    address internal _guardianRegistry;

    // ── Guardian-review storage ──
    // `_emergencyCallsHashes` and `_emergencyCalls` live in GuardianRegistry.
    // Two mapping slots reclaimed into __gap.

    /// @notice Per-vault count of non-terminal proposals — Pending,
    ///         GuardianReview, Approved, Executed. Used by
    ///         `GuardianRegistry.requestUnstakeOwner` alongside
    ///         `_activeProposal` to block owner rage-quit while any proposal
    ///         binds the vault. Incremented on Draft -> Pending. Decremented
    ///         on the terminal edge (Rejected / Expired / Cancelled / Settled).
    mapping(address => uint256) public openProposalCount;

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

    /// @dev Sherlock #14: propose-time snapshot of (`votingPeriod`,
    ///      `executionWindow`) for COLLABORATIVE proposals only. Packed as
    ///      `(uint128(executionWindow) << 128) | uint128(votingPeriod)` —
    ///      single SSTORE at propose, single SLOAD at `approveCollaboration`.
    ///      Pins timing so a mid-Draft `setVotingPeriod` / `setExecutionWindow`
    ///      by the owner doesn't move the goalposts for co-proposers who
    ///      already approved. Single-proposer path is atomic with propose
    ///      and reads `_params.*` live — no snapshot needed.
    ///      Storing OUTSIDE `StrategyProposal` avoids growing the struct's
    ///      memory footprint in `getProposal` (large savings under via_ir).
    mapping(uint256 proposalId => uint256 packedTiming) private _draftTimingSnap;

    /// @dev Reserved storage for future upgrades (shrunk by 1 for _guardianRegistry,
    ///      shrunk by 1 more for openProposalCount,
    ///      shrunk by 1 more for _unclaimedFees,
    ///      shrunk by 1 more for _approvedCount,
    ///      shrunk by 1 more for _draftTimingSnap (Sherlock #14),
    ///      grew by 1 after P1-1: _guardianFeeRecipient reclaimed,
    ///      grew by 5 after P2-1: _params + _protocolFeeBps +
    ///      _protocolFeeRecipient + _guardianFeeBps + factory moved to
    ///      GovernorParameters,
    ///      grew by 2 after V2: _emergencyCallsHashes + _emergencyCalls moved
    ///      to GuardianRegistry)
    uint256[34] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams memory p, address guardianRegistry_) external initializer {
        if (p.owner == address(0)) revert ZeroAddress();
        if (guardianRegistry_ == address(0)) revert ZeroAddress();
        if (
            p.minStrategyDuration < ABSOLUTE_MIN_STRATEGY_DURATION
                || p.maxStrategyDuration > ABSOLUTE_MAX_STRATEGY_DURATION
                || p.minStrategyDuration > p.maxStrategyDuration
        ) revert InvalidStrategyDurationBounds();
        if (p.collaborationWindow < MIN_COLLABORATION_WINDOW || p.collaborationWindow > MAX_COLLABORATION_WINDOW) {
            revert InvalidCollaborationWindow();
        }
        if (p.maxCoProposers == 0 || p.maxCoProposers > ABSOLUTE_MAX_CO_PROPOSERS) revert InvalidMaxCoProposers();
        if (p.protocolFeeBps > MAX_PROTOCOL_FEE_BPS) revert InvalidProtocolFeeBps();
        if (p.protocolFeeBps > 0 && p.protocolFeeRecipient == address(0)) revert InvalidProtocolFeeRecipient();
        if (p.guardianFeeBps > MAX_GUARDIAN_FEE_BPS) revert InvalidGuardianFeeBps();

        __Ownable_init(p.owner);

        _validateVotingPeriod(p.votingPeriod);
        _validateExecutionWindow(p.executionWindow);
        _validateVetoThresholdBps(p.vetoThresholdBps);
        _validateMaxPerformanceFeeBps(p.maxPerformanceFeeBps);
        _validateCooldownPeriod(p.cooldownPeriod);

        _params = GovernorParams({
            votingPeriod: p.votingPeriod,
            executionWindow: p.executionWindow,
            vetoThresholdBps: p.vetoThresholdBps,
            maxPerformanceFeeBps: p.maxPerformanceFeeBps,
            cooldownPeriod: p.cooldownPeriod,
            collaborationWindow: p.collaborationWindow,
            maxCoProposers: p.maxCoProposers,
            minStrategyDuration: p.minStrategyDuration,
            maxStrategyDuration: p.maxStrategyDuration
        });
        _protocolFeeBps = p.protocolFeeBps;
        _protocolFeeRecipient = p.protocolFeeRecipient;
        _guardianFeeBps = p.guardianFeeBps;
        _guardianRegistry = guardianRegistry_;
        _reentrancyStatus = _NOT_ENTERED;
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
        uint256 performanceFeeBps,
        uint256 strategyDuration,
        BatchExecutorLib.Call[] calldata executeCalls,
        BatchExecutorLib.Call[] calldata settlementCalls,
        CoProposer[] calldata coProposers
    ) external returns (uint256 proposalId) {
        if (!_registeredVaults.contains(vault)) revert VaultNotRegistered();
        if (!ISyndicateVault(vault).isAgent(msg.sender)) revert NotRegisteredAgent();
        // G-M1: block new proposals when the vault still has a non-terminal
        // lifecycle bound to it (Pending / GuardianReview / Approved / Executed).
        // Draft co-proposals do not count toward openProposalCount and are
        // independently gated at their Draft -> Pending transition.
        if (openProposalCount[vault] != 0) revert VaultHasOpenProposal();
        if (performanceFeeBps > _params.maxPerformanceFeeBps) revert PerformanceFeeTooHigh();
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
        p.metadataURI = metadataURI;
        p.performanceFeeBps = performanceFeeBps;
        p.strategyDuration = strategyDuration;
        if (isCollaborative) {
            p.state = ProposalState.Draft;
            // Sherlock #14: snapshot timing params for the collaborative Draft.
            // Pack (executionWindow << 128) | votingPeriod into a single slot
            // so `approveCollaboration` reads them with one SLOAD when it
            // transitions Draft → Pending. Pre-fix, the Draft → Pending
            // transition read `_params.*` LIVE, so an owner mid-Draft
            // `setVotingPeriod` / `setExecutionWindow` moved the goalposts
            // for co-proposers who already approved under the original
            // timing. Single-proposer path is atomic with propose so it
            // reads `_params.*` live in `_initPendingProposal` — no
            // snapshot needed.
            _draftTimingSnap[proposalId] =
                (uint256(uint128(_params.executionWindow)) << 128) | uint256(uint128(_params.votingPeriod));
            // Sherlock #8: lock the vault at Draft creation. Pre-fix,
            // openProposalCount only incremented at Draft→Pending (in
            // approveCollaboration); the up-to-7-day Draft window stayed
            // un-locked, so attackers could deposit between propose and
            // the final approve, then have their fresh balance counted in
            // the Pending snapshot (`block.timestamp - 1`). Counting the
            // Draft as a locking proposal closes the late-deposit window.
            unchecked {
                ++openProposalCount[vault];
            }
        } else {
            _initPendingProposal(p, reviewPeriod_);
        }

        // Store calls separately
        _storeCalls(_executeCalls, proposalId, executeCalls);
        _storeCalls(_settlementCalls, proposalId, settlementCalls);

        // Store co-proposers and set collaboration deadline
        if (coProposers.length > 0) {
            _storeCoProposers(proposalId, coProposers);
        }

        _emitProposalCreated(proposalId, executeCalls.length, settlementCalls.length);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev `nonReentrant` retained — the shared `_reentrancyStatus` latch
    ///      crosses functions. `test_vote_hasNonReentrantGuard` exercises
    ///      a registry-callback reentry path that re-enters `vote()` from
    ///      within a `cancelProposal → registry.cancelReview` chain; the
    ///      latch must be set on `vote()` to block this cross-function
    ///      vector even though `vote()` itself only does staticcalls.
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
    /// @dev `nonReentrant` dropped: state writes at lines 362-364
    ///      (`_activeProposal`, `state=Executed`, `executedAt`) commit BEFORE
    ///      the external `vault.executeGovernorBatch(...)` at line 370.
    ///      Reentry hits `StrategyAlreadyActive` (or `ProposalNotApproved`
    ///      if state-resolved differently). CEI-respected; ~20 bytes saved.
    function executeProposal(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];

        // Resolve state (may transition Pending->Approved/Rejected/Expired or Approved->Expired)
        if (_resolveState(proposal) != ProposalState.Approved) revert ProposalNotApproved();

        address vault = proposal.vault;
        if (_activeProposal[vault] != 0) revert StrategyAlreadyActive();
        // Cooldown check (skip if no prior settlement)
        uint256 lastSettled = _lastSettledAt[vault];
        if (lastSettled != 0 && block.timestamp < lastSettled + _params.cooldownPeriod) {
            revert CooldownNotElapsed();
        }

        // Snapshot vault balance before execution
        address asset = IERC4626(vault).asset();
        uint256 balanceBefore = IERC20(asset).balanceOf(vault);
        _capitalSnapshots[proposalId] = balanceBefore;

        // Update state BEFORE external call (CEI pattern)
        _activeProposal[vault] = proposalId;
        proposal.state = ProposalState.Executed;
        proposal.executedAt = block.timestamp;
        // Counter stays incremented through Executed; decremented once on the
        // Executed -> Settled edge in `_finishSettlement`. `_activeProposal`
        // also guards the Executed window (see `requestUnstakeOwner`).

        // Execute the opening calls via the vault
        ISyndicateVault(vault).executeGovernorBatch(_loadCalls(_executeCalls, proposalId));

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

        // Run the pre-committed settlement calls
        ISyndicateVault(proposal.vault).executeGovernorBatch(_loadCalls(_settlementCalls, proposalId));

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
    /// @dev `nonReentrant` dropped: only the GuardianReview branch has an
    ///      external call (`registry.cancelReview`), and the registry is a
    ///      trusted protocol contract — reentry from it would require an
    ///      upgrade vulnerability in the registry itself. Even on reentry,
    ///      the proposer-only check at line 435 plus the registry's own
    ///      "already resolved" gate on `cancelReview` reverts double-cancel.
    ///      The non-GuardianReview branches make zero external calls.
    function cancelProposal(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (msg.sender != proposal.proposer) revert NotProposer();
        ProposalState s = _resolveState(proposal);
        // PR #359 review #1: `_decOpen` now bumps `_lastSettledAt` internally,
        // so each branch below only needs the decrement call.
        if (s == ProposalState.Pending) {
            // Pending: only during the voting period.
            if (block.timestamp > proposal.voteEnd) revert ProposalNotCancellable();
            _decOpen(proposal.vault);
        } else if (s == ProposalState.GuardianReview) {
            // Close the registry-side review BEFORE marking the proposal
            // Cancelled. Registry reverts the cancelReview if reviewEnd has
            // already elapsed — bubbles up here as the cancel-window closer.
            IGuardianRegistry(_guardianRegistry).cancelReview(proposalId);
            _decOpen(proposal.vault);
        } else if (s == ProposalState.Approved) {
            // Approved means review already resolved as not-blocked. No
            // registry cleanup needed — slashing path is closed.
            _decOpen(proposal.vault);
        } else if (s == ProposalState.Draft) {
            uint256 total = _coProposers[proposalId].length;
            if (total > 1 && _approvedCount[proposalId] + 1 >= total) {
                revert CancelNotAllowedNearQuorum();
            }
            // Sherlock #8: Draft now binds the vault — decrement on cancel.
            _decOpen(proposal.vault);
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
    /// @dev `nonReentrant` dropped: function makes NO external calls. State
    ///      writes (`_decOpen`, `state=Cancelled`) are local SSTOREs only.
    ///      ~20 bytes saved.
    function emergencyCancel(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (msg.sender != OwnableUpgradeable(proposal.vault).owner()) revert NotVaultOwner();
        ProposalState s = _resolveState(proposal);
        // PR #324 review comment 4454151855: BOTH `Draft` and `Pending`
        // increment `openProposalCount` (Sherlock #8 binds Draft at propose
        // time), so BOTH must decrement on cancel. Pre-fix the Draft branch
        // fell through, soft-locking the vault — every subsequent `propose`
        // call would revert `VaultHasOpenProposal` because `openProposalCount`
        // stayed bumped from the cancelled Draft. Mirrors `cancelProposal`'s
        // Draft branch (line 421-422) and `rejectCollaboration` (line 582)
        // which already do this.
        if (s != ProposalState.Pending && s != ProposalState.Draft) revert ProposalNotCancellable();
        // PR #351 review #5 / PR #359 review #1: `_decOpen` bumps
        // `_lastSettledAt` so the cooldown rate-limits
        // propose→cancel→propose→execute.
        _decOpen(proposal.vault);
        proposal.state = ProposalState.Cancelled;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    /// @dev Decrement the open-proposal counter AND stamp the settle cooldown.
    ///      PR #359 review #1: `_lastSettledAt` is bumped HERE, the single
    ///      chokepoint, rather than at each caller. Pre-fix the bump was
    ///      duplicated across 6 cancel/settle branches but MISSED on the lazy
    ///      `_resolveState` terminal-transition path (`:944`), which is
    ///      reachable permissionlessly via `resolveProposalState`. That gap
    ///      let propose→resolve→propose→execute skip the cooldown that gates
    ///      execute-after-settle. Folding the bump into `_decOpen` closes all
    ///      branches and prevents a future `_decOpen` site from reintroducing
    ///      the omission. Every caller wants the bump: a vault whose only open
    ///      proposal just terminated (cancel / veto / reject / block-quorum
    ///      reject / expiry / settle) starts its cooldown from now.
    function _decOpen(address vault) private {
        --openProposalCount[vault];
        _lastSettledAt[vault] = block.timestamp;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Narrowed to Pending only (Task 25) — post-vote veto flows through
    ///      the guardian-review path rather than unilateral owner action.
    /// @dev `nonReentrant` dropped: function makes NO external calls. State
    ///      writes (`state=Rejected`, `_decOpen`) are local SSTOREs only.
    ///      ~20 bytes saved.
    function vetoProposal(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (msg.sender != OwnableUpgradeable(proposal.vault).owner()) revert NotVaultOwner();
        if (_resolveState(proposal) != ProposalState.Pending) revert ProposalNotCancellable();
        proposal.state = ProposalState.Rejected;
        // `_activeProposal` is unset during Pending (only set by execute).
        // PR #359 review #1: `_decOpen` bumps `_lastSettledAt` (same rate-limit
        // invariant as the cancel branches).
        _decOpen(proposal.vault);
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
            // non-terminal proposal bound to it. The Draft can remain and
            // re-attempt once the blocking proposal terminates.
            // Sherlock #8: with Drafts now counting in openProposalCount, the
            // *own* Draft is always in the count — subtract 1 to keep the
            // semantics "another (non-self) open proposal blocks transition".
            if (openProposalCount[proposal.vault] > 1) revert VaultHasOpenProposal();
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
            // G-H6: see propose().
            // Sherlock run #2 #5 (INVALID by design — Low/Info): vetoThresholdBps
            // is intentionally read live at the Draft→Pending transition.
            // The owner multisig is the same authority that runs
            // `setVetoThresholdBps`, so a mid-Draft veto-bar shift is part
            // of the accepted owner trust model. Timing-sensitive params
            // (votingPeriod, executionWindow) ARE snapshotted via
            // `_draftTimingSnap` (Sherlock #14) — the asymmetry is
            // deliberate, not an oversight.
            proposal.vetoThresholdBps = _params.vetoThresholdBps;
            // Sherlock #8: Draft already incremented openProposalCount at
            // propose time. Don't re-increment here.
            emit CollaborationTransitionedToPending(proposalId);
        }
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Sherlock #9: restrict reject to the lead proposer. Pre-fix, any
    ///      co-proposer could unilaterally cancel a Draft by calling this,
    ///      enabling a single hostile co-prop to repeatedly grief the lead.
    ///      A co-proposer who disagrees with the strategy can simply
    ///      withhold their `approveCollaboration` — the Draft lapses at the
    ///      collaboration window without their approval anyway. The explicit
    ///      reject is a UX shortcut for the LEAD to acknowledge "I'm not
    ///      going to land this collab", not a co-prop veto.
    function rejectCollaboration(uint256 proposalId) external {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (_resolveState(proposal) != ProposalState.Draft) revert NotDraftState();

        if (proposal.proposer != msg.sender) revert NotLeadProposer();

        proposal.state = ProposalState.Cancelled;
        // Sherlock #8: Draft now binds the vault — decrement on reject.
        // PR #359 review #1: `_decOpen` bumps `_lastSettledAt` internally.
        _decOpen(proposal.vault);
        emit CollaborationRejected(proposalId, msg.sender);
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ==================== VAULT MANAGEMENT ====================

    /// @inheritdoc ISyndicateGovernor
    function addVault(address vault) external {
        if (msg.sender != owner() && msg.sender != factory) revert NotAuthorized();
        if (vault == address(0)) revert InvalidVault();
        // G-M9: cheap EOA / typo guard via extcodesize. Full ABI probe would
        // cost too much bytecode; this catches the most common operator
        // mistake (pasting an EOA or address(0)-variant) while keeping the
        // check inline. Authorized callers (owner / factory) are still
        // trusted for semantic correctness.
        uint256 size;
        assembly {
            size := extcodesize(vault)
        }
        if (size == 0) revert NotASyndicateVault();
        if (!_registeredVaults.add(vault)) revert VaultAlreadyRegistered();
        emit VaultAdded(vault);
    }

    /// @inheritdoc ISyndicateGovernor
    function removeVault(address vault) external onlyOwner {
        if (!_registeredVaults.remove(vault)) revert VaultNotRegistered();
        emit VaultRemoved(vault);
    }

    /// @notice Permissionless: flushes a proposal's lazy terminal-state
    ///         transition (Rejected / Expired) so that
    ///         `openProposalCount[vault]` dec commits.
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
    function getRegisteredVaults() external view returns (address[] memory) {
        return _registeredVaults.values();
    }

    /// @inheritdoc ISyndicateGovernor
    function getActiveProposal(address vault) external view returns (uint256) {
        return _activeProposal[vault];
    }

    // `openProposalCount(address)` served by the public mapping auto-getter above.

    /// @inheritdoc ISyndicateGovernor
    function getCooldownEnd(address vault) external view returns (uint256) {
        return _lastSettledAt[vault] + _params.cooldownPeriod;
    }

    /// @inheritdoc ISyndicateGovernor
    function getCapitalSnapshot(uint256 proposalId) external view returns (uint256) {
        return _capitalSnapshots[proposalId];
    }

    /// @inheritdoc ISyndicateGovernor
    function isRegisteredVault(address vault) external view returns (bool) {
        return _registeredVaults.contains(vault);
    }

    /// @inheritdoc ISyndicateGovernor
    function getCoProposers(uint256 proposalId) external view returns (CoProposer[] memory) {
        return _coProposers[proposalId];
    }

    /// @inheritdoc ISyndicateGovernor
    function protocolFeeBps() external view returns (uint256) {
        return _protocolFeeBps;
    }

    /// @inheritdoc ISyndicateGovernor
    function protocolFeeRecipient() external view returns (address) {
        return _protocolFeeRecipient;
    }

    /// @inheritdoc ISyndicateGovernor
    function guardianFeeBps() external view returns (uint256) {
        return _guardianFeeBps;
    }

    /// @inheritdoc ISyndicateGovernor
    function guardianRegistry() external view returns (address) {
        return _guardianRegistry;
    }

    /// @dev `setGuardianRegistry` REMOVED — PR #351 review finding #1
    ///      (anajuliabit, code-traced review of beta @ 7dc275ef).
    ///
    ///      Repointing `_guardianRegistry` mid-proposal silently auto-Approved
    ///      any proposal sitting in `GuardianReview` on the *old* registry: on
    ///      the new registry's `resolveReview` the `!r.opened` branch (see
    ///      `GuardianRegistry.sol:725-729`) returns `blocked=false`, discarding
    ///      every Block vote AND the approver slash. The `reviewEnd` gate still
    ///      passes because proposal timing lives on the governor.
    ///
    ///      Same hazard class as **V-H2** (the factory's `setGovernor` was
    ///      removed for the symmetric reason). The legitimate migration path
    ///      (beta stub → real `GuardianRegistry` when WOOD ships) is a
    ///      governor UUPS upgrade — replace the implementation that hardcodes
    ///      the new registry address at `initialize`, not a setter.
    ///
    ///      `_guardianRegistry` remains a storage slot (not `immutable`) only
    ///      because the governor is itself UUPS-upgradeable; the new impl
    ///      writes the new address in its initializer.

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
            ++openProposalCount[p.vault];
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
            bool blocked = IGuardianRegistry(_guardianRegistry).resolveReview(proposal.id);
            if (blocked) {
                resolved = ProposalState.Rejected;
            } else {
                resolved = block.timestamp > proposal.executeBy ? ProposalState.Expired : ProposalState.Approved;
            }
            emit GuardianReviewResolved(proposal.id, blocked);
        }

        if (resolved != stored) {
            proposal.state = resolved;
            // Sherlock #8: Draft now binds the vault — both Draft and
            // non-Draft terminal transitions must decrement. Draft also
            // emits its specific event for telemetry.
            if (resolved == ProposalState.Rejected || resolved == ProposalState.Expired) {
                _decOpen(proposal.vault);
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
            IGuardianRegistry(_guardianRegistry).getReviewState(proposal.id);
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

        // Asset-only measurement (see NatSpec above). Subtract the live-adapter
        // principal forwarded during the Executed window so live-deposit
        // principal is not counted as strategy profit; add live-adapter
        // withdrawals back so a mid-flight LP exit is not counted as a
        // strategy loss (PnL = balance + withdrawn − (snapshot + principal)).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 snapshot = _capitalSnapshots[proposalId] + ISyndicateVault(vault).liveAdapterPrincipal(proposalId);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 balanceAdjusted =
            IERC20(asset).balanceOf(vault) + ISyndicateVault(vault).liveAdapterWithdrawn(proposalId);
        pnl = int256(balanceAdjusted) - int256(snapshot);

        // Finalize state before external transfers to prevent reentrancy on stale state
        _activeProposal[vault] = 0;
        proposal.state = ProposalState.Settled;
        delete _capitalSnapshots[proposalId];
        // Open emergency reviews are NOT auto-cancelled here — they resolve
        // naturally via `resolveEmergencyReview` at reviewEnd (slashing if the
        // block quorum was met, no-op otherwise) so an owner who opened an
        // adversarial emergency cannot dodge slash by racing a settle.
        // PR #359 review #1: `_decOpen` stamps `_lastSettledAt[vault]` — still
        // within the finalize block, before any fee transfer below.
        _decOpen(vault);

        uint256 totalFee = 0;
        if (pnl > 0) {
            (agentFee, totalFee) =
                _distributeFees(proposalId, vault, asset, proposal.proposer, proposal.performanceFeeBps, uint256(pnl));
        }

        emit ProposalSettled(proposalId, vault, pnl, totalFee, block.timestamp - proposal.executedAt);
    }

    /// @dev Distribute protocol, agent, and management fees. Extracted to avoid stack-too-deep.
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

        // Protocol fee taken first from gross profit.
        // I-3: `bps > 0 ⇒ recipient != 0` is enforced at every write site
        // (initialize + setProtocolFeeBps); re-asserting here closes any path
        // that could bypass the bounds dispatcher.
        if (_protocolFeeBps > 0) {
            protocolFee = (profit * _protocolFeeBps) / BPS_DENOMINATOR;
            if (protocolFee > 0) {
                if (_protocolFeeRecipient == address(0)) revert InvalidProtocolFeeRecipient();
                _payFee(vault, asset, _protocolFeeRecipient, protocolFee);
            }
        }

        // Guardian fee — slice of settled PnL routed to the registry (funds
        // per-proposal approver-reward pool). See spec §4.8.
        // Resilient: if the recipient transfer or pool-funding fails
        // (blacklist, misconfigured recipient, registry upgrade bug), emit
        // a diagnostic event and skip the fee so settlement cannot brick.
        // On transfer failure, the fee stays in the vault (LPs benefit).
        // On fund-funding failure (post-transfer), the amount is in the
        // registry but unpooled; ops can recover via the registry owner.
        if (_guardianFeeBps > 0) {
            uint256 fee = (profit * _guardianFeeBps) / BPS_DENOMINATOR;
            address recipient = _guardianRegistry;
            if (fee > 0) {
                try ISyndicateVault(vault).transferPerformanceFee(asset, recipient, fee) {
                    // Sherlock #36 (Run-1 #19): revert if pool-funding fails.
                    // Pre-fix, the inner catch silently swallowed `Disabled()`
                    // / misconfig reverts AFTER the asset had already been
                    // transferred to the registry — assets accumulated un-
                    // poolable forever (MinimalGuardianRegistry has no
                    // withdrawal path). Reverting the inner call rolls back
                    // the outer transfer too (both calls are in the same tx),
                    // so the asset stays in the vault and the operator can
                    // fix the registry config and retry settle.
                    //
                    // Sherlock run #2 #10 (INVALID — direct conflict with the
                    // above): asks to wrap the inner call in its own
                    // try-catch and "swallow" failures to avoid settlement
                    // DoS. Rejected: silently losing guardian fees on
                    // registry misconfig hides operator errors and breaks
                    // the audit trail. Fail-closed is the correct
                    // resolution — Run-1 #19 stands.
                    IGuardianRegistry(recipient).fundProposalGuardianPool(proposalId, asset, fee);
                    guardianFee = fee;
                    emit GuardianFeeAccrued(proposalId, asset, recipient, fee, uint64(block.timestamp));
                } catch {
                    // Transfer failed — fee stays in the vault, LPs benefit.
                    // guardianFee remains 0 so the waterfall reflects reality.
                    emit GuardianFeeDeliveryFailed(proposalId, asset, recipient, fee);
                }
            }
        }

        uint256 netProfit = profit - protocolFee - guardianFee;

        // Agent performance fee from net profit
        agentFee = (netProfit * perfFeeBps) / BPS_DENOMINATOR;

        // Management fee from remainder after agent fee
        uint256 mgmtFee = ((netProfit - agentFee) * ISyndicateVault(vault).managementFeeBps()) / BPS_DENOMINATOR;

        if (agentFee > 0) {
            _distributeAgentFee(proposalId, vault, asset, proposer, agentFee);
        }
        if (mgmtFee > 0) {
            _payFee(vault, asset, OwnableUpgradeable(vault).owner(), mgmtFee);
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
                // Sherlock run #2 #13: stop once the budget is exhausted —
                // pre-fix the loop would keep iterating and a later co-
                // proposer with a non-zero `share` from the splitBps
                // calculation would push `distributed` past `agentFee`
                // (the post-loop clamp only fixed bookkeeping, not the
                // already-executed transfers).
                if (distributed >= agentFee) break;
                bool active = ISyndicateVault(vault).isAgent(coProps[i].agent);
                if (!active) continue;
                uint256 share = (agentFee * coProps[i].splitBps) / BPS_DENOMINATOR;
                if (share == 0) share = 1;
                // Cap to remaining budget — handles both the rounding-floor
                // pad (share = 1) and any splitBps overflow.
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
    function _payFee(address vault, address asset, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        try ISyndicateVault(vault).transferPerformanceFee(asset, recipient, amount) {
        // ok
        }
        catch {
            _unclaimedFees[_unclaimedKey(vault, recipient, asset)] += amount;
            emit FeeTransferFailed(recipient, asset, amount);
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

    // ==================== UUPS ====================

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
