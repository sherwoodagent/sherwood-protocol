// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../BatchExecutorLib.sol";

interface ISyndicateGovernor {
    // ── Enums ──

    /// @dev ── THE LIFECYCLE MAP ─ state × transition owner × where the state lives ──
    ///      One conceptual state machine, physically split across two contracts
    ///      (EIP-170): the enum + most transitions live in `SyndicateGovernor`
    ///      (`_resolveState`), but the GuardianReview verdict, emergency-review
    ///      state, quorum bookkeeping, and stored emergency settlement calls live
    ///      in `GuardianRegistry` (reached via the thin `GovernorEmergency` shims).
    ///
    ///        Draft          → Pending         approveCollaboration (all co-proposers)
    ///        Draft          → Expired         time (collaborationDeadline passes;
    ///                                         CollaborationDeadlineExpired + _decOpen)
    ///        Pending        → GuardianReview  time (voteEnd passes, veto not met)
    ///        Pending        → Rejected        time (veto threshold reached)
    ///        GuardianReview → Approved        REGISTRY resolveReview: no block quorum
    ///        GuardianReview → Rejected        REGISTRY resolveReview: blocked
    ///        Approved       → Executed        executeProposal (anyone; gate is Approved
    ///                                         state + no other active proposal + cooldown
    ///                                         elapsed — no for-vote quorum exists in
    ///                                         this optimistic model)
    ///        Approved       → Expired         time (executeBy passes)
    ///        Executed       → Settled         settleProposal (proposer any time after
    ///                                         1h; anyone after strategyDuration) — or
    ///                                         the REGISTRY-driven emergency-settle path
    ///                                         (unstick → finalizeEmergencySettle)
    ///        Draft/Pending/GuardianReview/Approved → Cancelled
    ///                                         cancelProposal (proposer; G-H2 near-quorum
    ///                                         guard) or emergencyCancel (vault owner,
    ///                                         Draft/Pending only)
    ///
    ///      Reader's rule of thumb: transitions marked REGISTRY cannot be understood
    ///      from the governor alone — read `GuardianRegistry`'s review bookkeeping.
    enum ProposalState {
        Draft, // collaborative proposal awaiting co-proposer consent
        Pending, // voting active
        GuardianReview, // voting passed, guardian review window active (Task 25)
        Approved, // review ended without block quorum
        Rejected, // voting ended, veto threshold reached OR guardians blocked
        Expired, // execution window passed without execution
        Executed, // strategy is live
        Settled, // P&L calculated, fee distributed
        Cancelled // proposer or owner cancelled
    }

    enum VoteType {
        For,
        Against,
        Abstain
    }

    // ── Structs ──

    struct GovernorParams {
        uint256 votingPeriod;
        uint256 executionWindow;
        uint256 vetoThresholdBps;
        uint256 maxPerformanceFeeBps;
        uint256 cooldownPeriod;
        uint256 collaborationWindow;
        uint256 maxCoProposers;
        uint256 minStrategyDuration;
        uint256 maxStrategyDuration;
    }

    struct StrategyProposal {
        uint256 id;
        address proposer;
        address vault;
        /// @notice Address of the strategy contract for this proposal. In the V2
        ///         live-NAV design the vault reads the strategy's on-venue
        ///         positions and prices them vault-side (via the PriceRouter) —
        ///         the strategy is never trusted for value. Set at propose time;
        ///         immutable thereafter. Pass `address(0)` for a queue-only
        ///         proposal (no instant live-NAV lane).
        address strategy;
        string metadataURI;
        /// @notice Agent performance fee (bps), snapshotted from the vault's
        ///         `agentFeeBps()` at propose time so it is immutable for this
        ///         proposal — an owner change after propose cannot alter what
        ///         voters approved. Clamped to `maxPerformanceFeeBps` at settle.
        uint256 performanceFeeBps;
        uint256 strategyDuration;
        uint256 votesFor;
        uint256 votesAgainst;
        uint256 votesAbstain;
        uint256 snapshotTimestamp;
        uint256 voteEnd;
        uint256 reviewEnd; // guardian review window end (Task 25); zero for collaborative drafts
        uint256 executeBy;
        uint256 executedAt;
        ProposalState state;
        /// @dev G-H6: vetoThresholdBps snapshot taken at Draft -> Pending.
        ///      Prevents mid-vote timelock finalizes from retroactively
        ///      moving the rejection threshold.
        uint256 vetoThresholdBps;
        // ── Fee snapshot (read from ProtocolConfig at propose time) ──
        uint256 snapshotProtocolFeeBps;
        address snapshotProtocolFeeRecipient;
        uint256 snapshotGuardianFeeBps;
        address snapshotGuardiansFeeRecipient;
        /// @notice `IStrategy.selfManagesFees()` snapshotted at propose time (like
        ///         performanceFeeBps). Read from storage at settle so a non-pure
        ///         implementation can't flip it between review and settle (TOCTOU),
        ///         and a broken/EOA strategy can't brick settle via a revert.
        bool selfManagesFees;
        // ── APPENDED FIELDS ONLY BELOW (beacon-upgraded governors; storage parity) ──
        uint256 maxCapital; // risk envelope: net-outflow ceiling (spec §3.1)
        uint16 maxDrawdownBps; // risk envelope: declared drawdown bound
    }

    struct CoProposer {
        address agent;
        uint256 splitBps;
    }

    /// @notice Per-proposal risk envelope (spec 2026-07-22 §3.1).
    /// @param maxCapital   Net-outflow ceiling for the execute batch, enforced
    ///                     by the vault at custody level. Nonzero.
    /// @param maxDrawdownBps Declared drawdown envelope; losses beyond it are
    ///                     challengeable (challenge game, later plan). <= 10_000.
    ///                     10_000 (100%) is a legal declaration and means any
    ///                     loss up to the full committed capital is inside the
    ///                     envelope — no drawdown challenge can ever fire. It is
    ///                     the permissive default for pre-envelope flows, not a
    ///                     recommended production value.
    struct RiskEnvelope {
        uint256 maxCapital;
        uint16 maxDrawdownBps;
    }

    // Owner-multisig governs parameter changes via its own delay.

    // ── Errors ──

    error VaultNotRegistered();
    error VaultAlreadyRegistered();
    error NotRegisteredAgent();
    error StrategyDurationTooLong();
    error StrategyDurationTooShort();
    error EmptyExecuteCalls();
    error EmptySettlementCalls();
    error NotWithinVotingPeriod();
    error NoVotingPower();
    error AlreadyVoted();
    error ProposalNotFound();
    error ProposalNotApproved();
    error ExecutionWindowExpired();
    error StrategyAlreadyActive();
    error CooldownNotElapsed();
    error ProposalNotExecuted();
    error ProposalNotCancellable();
    error NotProposer();
    error InvalidVotingPeriod();
    error InvalidExecutionWindow();
    error InvalidVetoThresholdBps();
    error InvalidMaxPerformanceFeeBps();
    error InvalidStrategyDurationBounds();
    error InvalidCooldownPeriod();
    error InvalidVault();
    error ZeroAddress();
    error NotVaultOwner();
    error NotFactory();
    error StrategyDurationNotElapsed();
    error InvalidProtocolFeeBps();
    error InvalidProtocolFeeRecipient();
    /// @notice G-M1: Revert if a vault already has a non-terminal proposal
    ///         (Draft / Pending / GuardianReview / Approved / Executed) when
    ///         a new propose() or approveCollaboration Draft->Pending is
    ///         attempted. Prevents duplicate lifecycles that would race the
    ///         same vault state.
    error VaultHasOpenProposal();
    /// @notice G-M11: Revert if `metadataURI.length` exceeds
    ///         MAX_METADATA_URI_LENGTH. Bounds a calldata-unbounded string
    ///         that would otherwise let a proposer grief gas / event storage.
    error MetadataURITooLong();
    /// @notice Revert if `envelope.maxCapital == 0` at propose — a zero
    ///         net-outflow ceiling would make every execute batch unfundable.
    error ZeroMaxCapital();
    /// @notice Revert if `envelope.maxDrawdownBps > 10_000` at propose — a
    ///         drawdown declaration cannot exceed 100% of committed capital.
    error InvalidDrawdown();
    /// @notice G-M2/G-M6: Revert if `executeCalls.length` or
    ///         `settlementCalls.length` exceeds MAX_CALLS_PER_PROPOSAL. Bounds
    ///         calldata-unbounded arrays that otherwise let a proposer grief
    ///         gas when the batch is executed.
    error TooManyCalls();

    // ── Guardian-review emergency settle errors ──
    error OwnerBondInsufficient();
    error EmergencySettleBlocked();
    error EmergencyNotProposed();

    // ── Guardian-review lifecycle errors ──
    error NotInGuardianReview();
    error EmergencySettleNotReady();
    error RegistryNotSet();

    // ── Collaborative proposal errors ──
    error NotCoProposer();
    error CollaborationExpired();
    error AlreadyApproved();
    error InvalidSplits();
    error TooManyCoProposers();
    error SplitTooLow();
    error LeadSplitTooLow();
    error DuplicateCoProposer();
    error NotDraftState();
    error InvalidCollaborationWindow();
    error NotAuthorized();
    error InvalidMaxCoProposers();
    error Reentrancy();
    /// @notice Revert if lead tries to cancel a Draft once all-but-one
    ///         co-proposer has approved (G-H2). Prevents front-running the
    ///         final approve tx.
    error CancelNotAllowedNearQuorum();
    /// @notice Sherlock #9 — `rejectCollaboration` is gated to the lead
    ///         proposer; a co-proposer who disagrees must withhold approval
    ///         (Draft lapses naturally at the collaboration window).
    error NotLeadProposer();
    /// @notice Revert when `getVoteWeight` is called on a Draft proposal whose
    ///         snapshotTimestamp hasn't been stamped yet (G-H3). The prior
    ///         silent zero return confused callers who assumed no power.
    error ProposalInDraft();
    /// @notice Revert if an active co-proposer's rounded share is 0 (G-C7).
    /// @dev Prevents silent routing of zero-rounded shares to the lead.
    error CoProposerShareUnderflow();

    error InvalidGuardianFeeBps();
    /// @notice Raised when `guardianFeeBps > 0` would coexist with an unset
    ///         `guardiansFeeRecipient` — at initialize, on `setGuardianFeeBps`
    ///         raising the fee, or on `setGuardiansFeeRecipient(address(0))`
    ///         while the fee is on. Mirrors the protocol-fee recipient coupling.
    error InvalidGuardiansFeeRecipient();
    error ParamsFrozenDuringProposal();

    // ── Events ──

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        address indexed vault,
        uint256 performanceFeeBps,
        uint256 strategyDuration,
        uint256 executeCallCount,
        uint256 settlementCallCount,
        string metadataURI
    );

    /// @notice Emitted whenever the agent performance fee is clamped to
    ///         `maxPerformanceFeeBps` — at propose (the `agentFeeBps` snapshot
    ///         exceeds the cap) and again at settle if the cap was lowered
    ///         in-flight. Surfaces that the realized fee is the clamped value,
    ///         not the owner's higher intended rate, so voters and indexers can
    ///         detect the divergence. `snapshotted`/`clamped` are indexed (cheap
    ///         topics, no memory encoding) so the dual emit stays under budget.
    event FeeClamped(uint256 indexed proposalId, uint256 indexed snapshotted, uint256 indexed clamped);

    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteType support, uint256 weight);

    event ProposalExecuted(uint256 indexed proposalId, address indexed vault, uint256 capitalSnapshot);

    event ProposalSettled(
        uint256 indexed proposalId, address indexed vault, int256 pnl, uint256 performanceFee, uint256 duration
    );

    event ProposalCancelled(uint256 indexed proposalId, address indexed cancelledBy);

    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoedBy);

    event EmergencySettled(uint256 indexed proposalId, address indexed vault, int256 pnl, uint256 customCallCount);

    // PR #351 review #1: GuardianRegistrySet event removed alongside the
    // `setGuardianRegistry` setter. Repointing mid-proposal silently
    // auto-Approved blocked reviews — same hazard class as V-H2. The
    // registry slot is now write-only at `initialize`; migration happens
    // through a governor UUPS upgrade.

    // ── Fee-distribution resilience events (W-1) ──
    /// @notice Emitted when a per-recipient fee transfer in `_distributeFees` /
    ///         `_distributeAgentFee` reverts (e.g., USDC blacklist). The amount
    ///         is escrowed against `(vault, recipient, token)` in storage (see
    ///         `unclaimedFees`). `reason` dropped from the event to conserve
    ///         governor bytecode — the revert data is visible in the tx trace
    ///         if a debugger needs the underlying cause.
    event FeeTransferFailed(address indexed recipient, address indexed token, uint256 amount);
    /// @notice Emitted when a recipient pulls previously escrowed fees via
    ///         `claimUnclaimedFees`. The originating vault is the caller's
    ///         argument to `claimUnclaimedFees` (traceable via `tx.input`).
    event FeeClaimed(address indexed recipient, address indexed token, uint256 amount);

    // ── Guardian-review emergency settle events ──
    event EmergencySettleProposed(
        uint256 indexed proposalId, address indexed owner, bytes32 callsHash, uint64 reviewEnd
    );
    event EmergencySettleCancelled(uint256 indexed proposalId, address indexed owner);
    event EmergencySettleFinalized(uint256 indexed proposalId, int256 pnl);

    // ── Guardian-review lifecycle events ──
    event GuardianReviewResolved(uint256 indexed proposalId, bool blocked);

    event VaultAdded(address indexed vault);
    event VaultRemoved(address indexed vault);
    // All parameter updates (votingPeriod / executionWindow / vetoThresholdBps /
    // maxPerformanceFeeBps / minStrategyDuration / maxStrategyDuration /
    // cooldownPeriod / collaborationWindow / maxCoProposers / protocolFeeBps /
    // protocolFeeRecipient / factory) are surfaced via the uniform
    // `ParameterChangeFinalized(paramKey, oldValue, newValue)` event. Off-chain
    // consumers filter by `keccak256(name)` rather than per-param topics.

    // ── Collaborative proposal events ──
    event CollaborativeProposalCreated(
        uint256 indexed proposalId, address indexed leadProposer, address[] coProposers, uint256[] splitsBps
    );
    event CollaborationApproved(uint256 indexed proposalId, address indexed agent);
    event CollaborationRejected(uint256 indexed proposalId, address indexed agent);
    event CollaborationTransitionedToPending(uint256 indexed proposalId);
    event CollaborationDeadlineExpired(uint256 indexed proposalId);

    // ── Parameter change event (owner-instant, no queue/cancel) ──
    event ParameterChangeFinalized(bytes32 indexed paramKey, uint256 oldValue, uint256 newValue);

    /// @notice Emitted in `_distributeFees` when `guardianFeeBps > 0`.
    ///         Guardian fee is carved from gross PnL and transferred to
    ///         `recipient` (the team `guardiansFeeRecipient` multisig). This is
    ///         the off-chain Merkl bot's sole attribution signal — it swaps the
    ///         collected asset to WOOD and airdrops to approvers/delegators
    ///         weekly, reading the per-proposal approver split from
    ///         `GuardianRegistry.getApproverWeights`.
    /// @dev `settledAt` is intentionally NOT a field — it equals the emitting
    ///      block's timestamp, which the off-chain bot reads from the log
    ///      metadata. Omitted to keep the EIP-170-capped governor under budget.
    event GuardianFeeAccrued(
        uint256 indexed proposalId, address indexed asset, address indexed recipient, uint256 amount
    );

    // ── Functions ──

    /// @notice Submit a strategy proposal for `vault`. The optional `strategy`
    ///         parameter is the contract that holds the proposal's on-venue
    ///         positions; the vault prices those positions vault-side (V2
    ///         live-NAV redesign — the strategy is never trusted for value).
    ///         Pass `address(0)` for a queue-only proposal (no instant lane).
    /// @dev    The strategy is set immutably at propose time — voters approve
    ///         based on this address, and there is no later bind / rebind path.
    function propose(
        address vault,
        address strategy,
        string calldata metadataURI,
        uint256 strategyDuration,
        RiskEnvelope calldata envelope,
        BatchExecutorLib.Call[] calldata executeCalls,
        BatchExecutorLib.Call[] calldata settlementCalls,
        CoProposer[] calldata coProposers
    ) external returns (uint256 proposalId);

    function vote(uint256 proposalId, VoteType support) external;

    function executeProposal(uint256 proposalId) external;

    function settleProposal(uint256 proposalId) external;

    // ── Guardian-review emergency settle lifecycle ──
    // Owner-driven paths: `unstick` (pre-committed calls) or
    // `emergencySettleWithCalls` + `finalizeEmergencySettle` (guardian-gated).
    function unstick(uint256 proposalId) external;
    function emergencySettleWithCalls(uint256 proposalId, BatchExecutorLib.Call[] calldata calls) external;
    function cancelEmergencySettle(uint256 proposalId) external;
    function finalizeEmergencySettle(uint256 proposalId) external;

    function cancelProposal(uint256 proposalId) external;

    function emergencyCancel(uint256 proposalId) external;

    /// @notice Vault owner vetoes a Pending proposal only, setting it to Rejected.
    /// @dev Narrowed so guardians own post-review blocks — once a proposal
    ///      has passed voting and entered `GuardianReview`, the guardian
    ///      cohort and execution window drive the outcome rather than
    ///      unilateral owner action. Use `emergencyCancel` for Draft/Pending.
    function vetoProposal(uint256 proposalId) external;

    // ── Collaborative proposal functions ──

    function approveCollaboration(uint256 proposalId) external;
    function rejectCollaboration(uint256 proposalId) external;

    // ── Setters (owner-instant; owner is a multisig with external delay) ──

    function setVotingPeriod(uint256 newVotingPeriod) external;
    function setExecutionWindow(uint256 newExecutionWindow) external;
    function setVetoThresholdBps(uint256 newVetoThresholdBps) external;
    function setMaxPerformanceFeeBps(uint256 newMaxPerformanceFeeBps) external;
    function setMinStrategyDuration(uint256 newMinStrategyDuration) external;
    function setMaxStrategyDuration(uint256 newMaxStrategyDuration) external;
    function setCooldownPeriod(uint256 newCooldownPeriod) external;
    function setCollaborationWindow(uint256 newCollaborationWindow) external;
    function setMaxCoProposers(uint256 newMaxCoProposers) external;
    function setProtocolConfig(address newConfig) external;

    // ── Init ──
    /// @notice Initialize a freshly deployed per-vault governor proxy.
    ///         Called once by the factory inside the `BeaconProxy` constructor.
    function initialize(
        address vault_,
        address guardianRegistry_,
        address protocolConfig_,
        address factory_,
        GovernorParams calldata params_
    ) external;

    // ── Factory-only ──
    function forceSetParams(GovernorParams calldata params) external;

    // ── Views ──

    function getProposal(uint256 proposalId) external view returns (StrategyProposal memory);
    function getProposalState(uint256 proposalId) external view returns (ProposalState);
    function getExecuteCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory);
    function getSettlementCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory);
    function getVoteWeight(uint256 proposalId, address voter) external view returns (uint256);
    function hasVoted(uint256 proposalId, address voter) external view returns (bool);
    function proposalCount() external view returns (uint256);
    function getGovernorParams() external view returns (GovernorParams memory);
    function getActiveProposal() external view returns (uint256);
    /// @notice Count of proposals for this vault in any non-terminal state
    ///         (Pending / GuardianReview / Approved / Executed).
    /// @dev Incremented on Draft -> Pending, decremented on the terminal edge
    ///      (Rejected / Expired / Cancelled / Settled). Consumed by
    ///      `GuardianRegistry.requestUnstakeOwner` alongside `getActiveProposal`
    ///      to block rage-quit while any proposal binds the vault — the OR
    ///      check is belt-and-braces so stale-cache transitions can't slip
    ///      through.
    function openProposalCount() external view returns (uint256);
    function getCooldownEnd() external view returns (uint256);
    function getCapitalSnapshot(uint256 proposalId) external view returns (uint256);
    function getCoProposers(uint256 proposalId) external view returns (CoProposer[] memory);
    /// @notice Risk envelope declared by the proposer at propose time
    ///         (spec 2026-07-22 §3.1). Immutable for the proposal's lifetime.
    /// @dev    Returns (0, 0) for a nonexistent proposalId — the zero-value
    ///         convention shared with getCapitalSnapshot / getCoProposers.
    ///         Unambiguous here: `maxCapital == 0` is rejected at propose, so a
    ///         zero `maxCapital` reliably means "no such proposal".
    function getRiskEnvelope(uint256 proposalId) external view returns (uint256 maxCapital, uint16 maxDrawdownBps);
    function vault() external view returns (address);
    function protocolConfig() external view returns (address);

    /// @notice Address of the guardian registry (zero if not yet wired).
    function guardianRegistry() external view returns (address);

    // ── Fee-escrow (W-1) ──

    /// @notice Pull previously escrowed fees after the blacklist / revert
    ///         condition that caused the original settlement transfer has been
    ///         lifted. Escrow is keyed by origin vault — a recipient can only
    ///         claim against the specific vault whose fee transfer failed.
    /// @param vault The vault that originally held the fee asset.
    /// @param token The ERC-20 address the fee was denominated in.
    function claimUnclaimedFees(address vault, address token) external;

    /// @notice Amount of fees escrowed against `(vault, recipient)` in `token`
    ///         awaiting a retryable claim. Zero for `(vault, recipient, token)`
    ///         tuples that never had a failed transfer.
    function unclaimedFees(address vault, address recipient, address token) external view returns (uint256);
}
