// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../BatchExecutorLib.sol";
import {IProtocolConfig} from "./IProtocolConfig.sol";

interface ISyndicateGovernor {
    // ── Enums ──

    /// @dev ── THE LIFECYCLE MAP ─ state × transition owner × where the state lives ──
    ///      One conceptual state machine, physically split across two contracts
    ///      (EIP-170): the enum + most transitions live in the governor's
    ///      `ProposalLifecycle` base (resolved by `_computeState`, committed by
    ///      `_commitState`), but the GuardianReview verdict, emergency-review
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
    ///                                         cancelProposal (proposer; near-quorum
    ///                                         guard) or emergencyCancel (vault owner,
    ///                                         Draft/Pending only)
    ///
    ///      Reader's rule of thumb: transitions marked REGISTRY cannot be understood
    ///      from the governor alone — read `GuardianRegistry`'s review bookkeeping.
    enum ProposalState {
        Draft, // collaborative proposal awaiting co-proposer consent
        Pending, // voting active
        GuardianReview, // voting passed, guardian review window active
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
        /// @notice Address of the strategy contract for this proposal. Set at
        ///         propose time; immutable thereafter. Pass `address(0)` for a
        ///         queue-only proposal.
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
        uint256 reviewEnd; // guardian review window end; zero for collaborative drafts
        uint256 executeBy;
        uint256 executedAt;
        ProposalState state;
        /// @dev vetoThresholdBps snapshot taken at Draft -> Pending. Prevents
        ///      mid-vote timelock finalizes from retroactively moving the
        ///      rejection threshold.
        uint256 vetoThresholdBps;
        // Fee snapshot, read from `ProtocolConfig` at propose time.
        /// @dev Only the RECIPIENTS are snapshotted; the protocol and guardian
        ///      SHARES come from `snapshotMgmtSplit`/`snapshotPerfSplit` below.
        ///      `_proposals` is a mapping laid out by member index and the governor
        ///      is a `BeaconProxy`, so reordering or removing a member here shifts
        ///      every later member's offset and corrupts an already-upgraded
        ///      governor's existing proposals unless they are drained first.
        address snapshotProtocolFeeRecipient;
        address snapshotGuardiansFeeRecipient;
        // ── APPENDED FIELDS ONLY BELOW (beacon-upgraded governors; storage parity) ──
        uint256 maxCapital; // risk envelope: net-outflow ceiling
        uint16 maxDrawdownBps; // risk envelope: declared drawdown bound
        /// @notice MAX tier across the proposal's execute calls, resolved via
        ///         the TierRegistry at propose time. 2 whenever no registry
        ///         is wired — the safe default.
        uint8 envelopeTier;
        /// @notice Extractable-value figure the aggregate exposure cap consumes:
        ///         the SUM of per-call contributions across execute AND settlement
        ///         calls, `sum(cap_i * boundBps_i) / 10_000`, where `cap_i` is that
        ///         call's proposer-declared capital declaration and `boundBps_i`
        ///         its certified bound (tier-2 and uncertified calls use 10_000).
        ///         `maxCapital` flat when no registry is wired; caps are still
        ///         metered at execution regardless.
        uint256 requiredCoverage;
        /// @notice WOOD amount of the risk-scaled proposer bond locked in
        ///         the ProposerBondEscrow at propose time. Zero when no
        ///         escrow/ledger is wired or the bond bps is zero.
        uint256 proposerBondWood;
        /// @notice The `ProposerBondEscrow` that actually HOLDS this proposal's
        ///         bond, bound at propose time. The bond is custodial, the escrow
        ///         has no owner and no discretionary exit, and it keys bonds by
        ///         `(governor, proposalId)` — so a release must target this
        ///         address, never the governor's live `_bondEscrow` slot.
        ///         Re-pointing that slot is therefore safe for existing proposals.
        ///         Zero when no bond was locked.
        address proposerBondEscrow;
        /// @notice Management-fee split snapshotted from `ProtocolConfig` at
        ///         propose time, for the same reason every other fee field here
        ///         is snapshotted: a governance change after propose must not
        ///         alter what an in-flight proposal pays. Three `uint16`s, one
        ///         slot.
        IProtocolConfig.MgmtSplit snapshotMgmtSplit;
        /// @notice Performance-fee split snapshotted at propose time. Four
        ///         `uint16`s, one slot.
        IProtocolConfig.PerfSplit snapshotPerfSplit;
        /// @notice The exposure ledger `reclaimProposerBond`'s challenge-window
        ///         gates read for this proposal, pinned at propose time alongside
        ///         the bond and escrow. A factory re-point of the governor's live
        ///         slot after this proposal locks a bond MUST NOT change which
        ///         ledger gates it. Zero when no bond was locked, or the proposal
        ///         predates ledger pinning and falls back to the live slot.
        address proposerBondLedger;
        /// @notice Coverage-proportional net-outflow ceiling, derived and stored
        ///         ONCE at execute and immutable thereafter: `maxCapital` when the
        ///         approve-quorum gate did not run or raised coverage at or above
        ///         what was required, else
        ///         `floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)`.
        ///         `settleProposal` reuses this exact value rather than recomputing
        ///         — a live recompute could cap the unwind below the size
        ///         legitimately deployed at execution. Zero before execution;
        ///         written on EVERY execute path, so a stored zero never means
        ///         unset on an `Executed` proposal.
        uint256 effectiveMaxCapital;
    }

    struct CoProposer {
        address agent;
        uint256 splitBps;
    }

    /// @notice Per-proposal risk envelope.
    /// @param maxCapital   Net-outflow ceiling for the execute batch, enforced by
    ///                     the vault at custody level. Nonzero.
    /// @param maxDrawdownBps Declared drawdown envelope; losses beyond it are
    ///                     challengeable. `10_000` is a legal declaration meaning
    ///                     any loss up to the full committed capital is inside the
    ///                     envelope, so no drawdown challenge can ever fire — the
    ///                     permissive default for pre-envelope flows, not a
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
    /// @notice `propose` named a `strategy` clone whose `proposer()` is not the
    ///         caller. `StrategyFactory.cloneAndInit` binds `_proposer` to the
    ///         cloning caller (`ProposerMustBeSender`) so that it is "a known
    ///         authorized address", and `BaseStrategy.execute()` then trusts
    ///         `strategyOf(activePid) == address(this)` as its whole
    ///         authorisation. Without this check the governor broke that
    ///         chain: `strategy` was a label written by the proposer and
    ///         consumed as an authorisation fact, so any registered agent
    ///         could name a RIVAL agent's allowlisted clone and drive it to
    ///         `State.Executed` — permanently bricking it (`AlreadyExecuted`
    ///         thereafter) and round-tripping the vault's capital through its
    ///         swap legs on the way.
    error StrategyProposerMismatch();
    /// @notice `propose` named a `strategy` clone initialized against a
    ///         different vault than the one being proposed to.
    error StrategyVaultMismatch();
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
    /// @notice Fail-safe: revert at execute if the proposal's live tier,
    ///         re-resolved from its stored execute calls, is WORSE than the
    ///         `envelopeTier` snapshotted at propose. A certified tier-0/1 adapter
    ///         that demoted since propose leaves the proposal under-covered —
    ///         block execution rather than run a possibly-unbounded batch against
    ///         a bounded-tier coverage price.
    error TierRegressed();
    /// @notice Companion to `TierRegressed`: revert at execute if the live
    ///         re-resolved `requiredCoverage` exceeds the propose-time
    ///         snapshot. Catches a same-tier RE-certification with a HIGHER
    ///         extractableBoundBps (tier unchanged, coverage regressed)
    ///         that the tier-only check waves through while the aggregate
    ///         cap would still trust the stale, lower snapshot.
    error CoverageRegressed();
    /// @notice Fail-safe sibling to `TierRegressed`/`CoverageRegressed`: revert at
    ///         execute if `proposal.maxCapital` now exceeds the LIVE
    ///         `totalAssets() * maxCapitalBps / 10_000` ceiling. The propose-time
    ///         check alone is not sufficient: `_depositsLocked()` rises at PROPOSE
    ///         but `redemptionsLocked()` only at EXECUTE, so between the two a
    ///         proposer can inflate `totalAssets()` with its own deposit to pass
    ///         the propose-time ratio, then redeem that same deposit during the
    ///         vote. Distinct from `MaxCapitalExceedsCeiling` so indexers can tell
    ///         a propose-time rejection from an execute-time regression.
    error MaxCapitalCeilingRegressed();
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
    /// @notice `_bondEscrow` and `_exposureLedger` are two independently
    ///         factory-settable slots with no on-chain pairing guarantee, and
    ///         ledger rotation can outpace escrow rotation in ordinary operation.
    ///         Locking a new bond into an escrow whose own immutable
    ///         `exposureLedger` differs from the ledger this proposal pins would
    ///         hold it where every forfeiture attempt from that ledger's game is
    ///         rejected forever — a convicted proposer keeps the bond. The lock
    ///         is refused rather than creating that state.
    error LedgerEscrowMismatch();
    /// @notice Revert if a vault already has a non-terminal proposal
    ///         (Draft / Pending / GuardianReview / Approved / Executed) when
    ///         a new propose() or approveCollaboration Draft->Pending is
    ///         attempted. Prevents duplicate lifecycles that would race the
    ///         same vault state.
    error VaultHasOpenProposal();
    /// @notice Revert if `metadataURI.length` exceeds
    ///         MAX_METADATA_URI_LENGTH. Bounds a calldata-unbounded string
    ///         that would otherwise let a proposer grief gas / event storage.
    error MetadataURITooLong();
    /// @notice Revert if `envelope.maxCapital == 0` at propose — a zero
    ///         net-outflow ceiling would make every execute batch unfundable.
    error ZeroMaxCapital();
    /// @notice Revert if `envelope.maxCapital` exceeds the governor's ceiling
    ///         (`totalAssets() * maxCapitalBps / 10_000` at propose time).
    ///         Without this, a proposer declares maxCapital = uint256.max and
    ///         the net-outflow cap never binds.
    error MaxCapitalExceedsCeiling();
    /// @notice `reclaimProposerBond` called while the proposal can still reach
    ///         execution. The bond is only returned from a TERMINAL state
    ///         (Rejected / Expired / Cancelled / Settled).
    error ProposalNotTerminal();
    /// @notice `reclaimProposerBond` called for a proposal that never locked a
    ///         bond, or whose bond was already reclaimed (the reclaim zeroes
    ///         the stored amount, so a second call lands here — idempotence).
    error NoBondToReclaim();
    /// @notice `reclaimProposerBond` called on a proposal that EXECUTED, while a
    ///         conviction is still reachable — either the challenge window has not
    ///         run out from `executedAt`, or a filing inside it is still live.
    ///         Terminal is not the same as unchallengeable: the proposer can
    ///         self-settle an hour after execution, and returning the bond there
    ///         would let the only party the bond is posted against outrun every
    ///         path that could take it.
    error ChallengeWindowOpen();
    /// @notice `reclaimProposerBond` called on an EXECUTED proposal while this
    ///         governor has no exposure ledger wired, so the challenge window
    ///         cannot be read. Fails CLOSED deliberately — see the function's
    ///         own natspec for why unwiring the ledger must not become the
    ///         escape hatch from the delay it enforces.
    error ExposureLedgerUnset();
    /// @notice `setMaxCapitalBps` called with 0 or a value above 10_000.
    error InvalidMaxCapitalBps();
    /// @notice Revert if `envelope.maxDrawdownBps > 10_000` at propose — a
    ///         drawdown declaration cannot exceed 100% of committed capital.
    error InvalidDrawdown();
    /// @notice `setTierRegistry` was handed zero or a codeless address (pashov
    ///         finding #1). Un-wiring re-opens `SyndicateVault._guardBatchCalls`
    ///         (it degrades OPEN with no registry); a codeless address bricks
    ///         the guard's typed call. Re-pointing to a real registry is legal.
    error TierRegistryNotWired();
    /// @notice Revert if the realized vault balance at `settleProposal` sits
    ///         below the proposal's declared drawdown floor. `settleProposal`
    ///         freezes the Lane B settle price for every queued deposit and
    ///         redeem, so a settlement that delivered materially less than the
    ///         approved envelope must not be allowed to stamp that price —
    ///         settlement completeness is not all-or-revert at the strategy
    ///         layer, so without this the stamp can be driven arbitrarily low.
    ///         The owner-multisig `unstick` / `finalizeEmergencySettle` paths
    ///         are deliberately NOT gated on it: they are the escape hatch for
    ///         a genuine loss that must still be able to settle.
    /// @param  realized The vault's asset balance when settlement was attempted.
    /// @param  floor    The pre-execute balance less
    ///                  `effectiveMaxCapital * maxDrawdownBps / 10_000` — the
    ///                  absolute drop the declared envelope permits on the
    ///                  capital it actually covers, NOT a percentage of the
    ///                  whole fund.
    error SettlementBelowDrawdownFloor(uint256 realized, uint256 floor);
    /// @notice The settle PRICE fell below the floor anchored at execute
    ///         (pashov finding #2). Distinct from `SettlementBelowDrawdownFloor`,
    ///         which bounds the strategy's absolute capital loss: this one
    ///         bounds what may be FROZEN as the price every queued deposit and
    ///         redeem is paid at. Two different questions, two separate gates —
    ///         the first is waivable to nothing by a 100% drawdown declaration,
    ///         and this one is not.
    error SettlePriceBelowFloor(uint256 ppsNow, uint256 ppsFloor);
    /// @notice Revert if `claimUnclaimedFees` is called for a vault whose
    ///         proposal is currently Executed. An escrowed fee leaving the
    ///         vault mid-strategy is indistinguishable from a strategy loss to
    ///         every asset-balance-differencing consumer — `_finishSettlement`'s
    ///         `pnl` and the `SettlementBelowDrawdownFloor` gate — so the claim
    ///         waits for the settlement that clears `_activeProposal`.
    error VaultProposalActive();
    /// @notice Revert if `executeCalls.length` or `settlementCalls.length`
    ///         exceeds MAX_CALLS_PER_PROPOSAL. Bounds calldata-unbounded
    ///         arrays that otherwise let a proposer grief gas when the batch
    ///         is executed.
    error TooManyCalls();
    /// @notice Revert if `executeCallCaps.length != executeCalls.length` or
    ///         `settlementCallCaps.length != settlementCalls.length` at
    ///         propose (issue #43). Every call must declare exactly one cap.
    error CallCapsLengthMismatch();
    /// @notice Revert if `Σ executeCallCaps` or `Σ settlementCallCaps`
    ///         exceeds `envelope.maxCapital`, evaluated PER BATCH (issue #43)
    ///         — the two batches run in separate transactions, each
    ///         independently bounded by the vault's `maxCapital` net-outflow
    ///         meter, so a batch whose own sum is within `maxCapital` passes
    ///         even when the two sums combined exceed it.
    error CallCapsExceedMaxCapital();
    /// @notice Revert if a call in either array whose (target, selector)
    ///         resolves to tier 2 (uncertified included) declares a cap above
    ///         `totalAssets() * tier2CallCapBps / 10_000` at propose (issue
    ///         #43). `index` disambiguates; arrays are scanned exec-then-settle.
    error Tier2CallCapExceedsCeiling(uint256 index);
    /// @notice `setTier2CallCapBps` called with 0 or a value above 10_000.
    error InvalidTier2CallCapBps();

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
    ///         co-proposer has approved. Prevents front-running the final
    ///         approve tx.
    error CancelNotAllowedNearQuorum();
    /// @notice `rejectCollaboration` is gated to the lead proposer; a
    ///         co-proposer who disagrees must withhold approval (Draft
    ///         lapses naturally at the collaboration window).
    error NotLeadProposer();
    /// @notice Revert when `getVoteWeight` is called on a Draft proposal
    ///         whose snapshotTimestamp hasn't been stamped yet.
    error ProposalInDraft();
    /// @notice Revert if an active co-proposer's rounded share is 0.
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

    /// @notice The always-on management fee charged at settlement.
    /// @param assetSeconds The integral the fee was computed from, so an
    ///        indexer can reconstruct the effective rate and the average base
    ///        without replaying every flow.
    event ManagementFeeCharged(uint256 indexed proposalId, address indexed asset, uint256 amount, uint256 assetSeconds);

    /// @notice The performance fee charged at settlement.
    /// @param aboveMark Value above the high-water mark that the fee was
    ///        computed on — not the proposal's raw profit.
    event PerformanceFeeCharged(uint256 indexed proposalId, address indexed asset, uint256 amount, uint256 aboveMark);

    event VoteCast(uint256 indexed proposalId, address indexed voter, VoteType support, uint256 weight);

    event ProposalExecuted(uint256 indexed proposalId, address indexed vault, uint256 capitalSnapshot);

    /// @notice The coverage-proportional effective capital derived at
    ///         execute (issue #27). `coverageRaisedUsd`/`requiredCoverageUsd`
    ///         are both zero when the approve-quorum gate did not run (no
    ///         ledger wired, zero `requiredCoverage`, or tier below the
    ///         quorum threshold) — `effectiveMaxCapital` equals
    ///         `declaredMaxCapital` on that path.
    event EffectiveMaxCapitalSet(
        uint256 indexed proposalId,
        uint256 declaredMaxCapital,
        uint256 effectiveMaxCapital,
        uint256 coverageRaisedUsd,
        uint256 requiredCoverageUsd
    );

    event ProposalSettled(
        uint256 indexed proposalId, address indexed vault, int256 pnl, uint256 performanceFee, uint256 duration
    );

    event ProposalCancelled(uint256 indexed proposalId, address indexed cancelledBy);

    event ProposalVetoed(uint256 indexed proposalId, address indexed vetoedBy);

    event EmergencySettled(uint256 indexed proposalId, address indexed vault, int256 pnl, uint256 customCallCount);

    // There is no setter for the guardian registry. The slot is write-only
    // at `initialize`; migration happens through a governor UUPS upgrade.

    // ── Fee-distribution resilience events ──
    /// @notice Emitted when a per-recipient fee transfer in `_distributeFees` /
    ///         `_distributeAgentFee` reverts (e.g., USDC blacklist). The amount
    ///         is escrowed against `(vault, recipient, token)` in storage (see
    ///         `unclaimedFees`). `reason` dropped from the event to conserve
    ///         governor bytecode — the revert data is visible in the tx trace
    ///         if a debugger needs the underlying cause.
    event FeeTransferFailed(address indexed recipient, address indexed token, uint256 amount);
    /// @notice A failed fee transfer was escrowed for LESS than it charged,
    ///         because the vault could not back the full amount. `charged` is
    ///         what the fee formula produced, `escrowed` what was actually
    ///         booked; the difference is forfeited rather than recorded as a
    ///         claim the vault provably cannot honour. Emitted alongside
    ///         `FeeTransferFailed` so the shortfall is never silent.
    event FeeEscrowCapped(address indexed recipient, address indexed token, uint256 charged, uint256 escrowed);
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

    /// @notice Tier registry wired (or un-wired, newRegistry == address(0)).
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);

    /// @notice Exposure ledger wired (or un-wired, newLedger == address(0)).
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);

    /// @notice Proposer bond escrow wired (or un-wired, newEscrow == address(0)).
    event BondEscrowSet(address indexed oldEscrow, address indexed newEscrow);

    /// @notice `reclaimProposerBond` reached a proposal whose bond had already
    ///         been forfeited by a conviction (the pinned escrow reports none
    ///         held while the governor still recorded `amount`). The recorded
    ///         amount is zeroed and nothing is transferred — this is the
    ///         terminal, distinguishable outcome in place of a permanent
    ///         `NoBond` revert from the escrow.
    event ProposerBondForfeitureAcknowledged(uint256 indexed proposalId, uint256 amount);

    /// @notice The governor's best-effort self-trigger of the exposure ledger's
    ///         `settleCoverage` reverted — at settlement finalization or after a
    ///         bond reclaim. Mirrors the house best-effort pattern: a bare catch,
    ///         both identifying fields indexed, no revert-data payload, and the
    ///         terminal path is never bricked by it.
    /// @dev    A caller who dials gas to starve this trigger achieves only the
    ///         pre-change status quo — the cohort's reservations stay over-booked,
    ///         the conservative direction — visibly and permissionlessly
    ///         repairably, since anyone may re-call the external
    ///         `ExposureLedger.settleCoverage`. `ledger` names the collaborator to
    ///         retry against.
    event CoverageSettleFailed(uint256 indexed proposalId, address indexed ledger);

    /// @notice Emitted in `_distributeFees` when `guardianFeeBps > 0`. The guardian
    ///         fee is carved from gross PnL and transferred to `recipient`. This is
    ///         the off-chain Merkl bot's sole attribution signal — it swaps the
    ///         collected asset to WOOD and airdrops to approvers weekly, reading
    ///         the per-proposal split from `GuardianRegistry.getApproverWeights`.
    /// @dev `settledAt` is intentionally NOT a field — it equals the emitting
    ///      block's timestamp, which the bot reads from the log metadata. Omitted
    ///      to keep the EIP-170-capped governor under budget.
    event GuardianFeeAccrued(
        uint256 indexed proposalId, address indexed asset, address indexed recipient, uint256 amount
    );

    // ── Functions ──

    /// @notice Submit a strategy proposal for `vault`. The optional `strategy`
    ///         parameter is the contract that holds the proposal's on-venue
    ///         positions; the vault prices those positions vault-side, so the
    ///         strategy is never trusted for value. Pass `address(0)` for a
    ///         queue-only proposal.
    /// @dev    The strategy is set immutably at propose time — voters approve based
    ///         on this address, and there is no later rebind path.
    /// @dev    `executeCallCaps` and `settlementCallCaps` are parallel arrays, one
    ///         `uint256` per entry in the corresponding call array: each call's own
    ///         declared gross-outflow cap, denominated in the vault asset. Zero is
    ///         a legal declaration at every tier. Each sum must be
    ///         `<= envelope.maxCapital`, checked PER BATCH and never combined — the
    ///         two batches run in separate transactions, each independently bounded
    ///         by the vault's net-outflow meter, and an honest settlement
    ///         legitimately re-moves the same capital the execute batch deployed.
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
    ) external returns (uint256 proposalId);

    function vote(uint256 proposalId, VoteType support) external;

    /// @dev Re-checks `maxCapital` against the LIVE
    ///      `totalAssets() * maxCapitalBps / 10_000` ceiling immediately before
    ///      dispatching the execute batch, in addition to
    ///      `TierRegressed`/`CoverageRegressed`. The propose-time gate alone is not
    ///      sufficient: a proposer can inflate `totalAssets()` with its own deposit
    ///      right before proposing, then redeem it during the vote, since deposits
    ///      are blocked from PROPOSE but withdrawals only from EXECUTE. Reverts
    ///      `MaxCapitalCeilingRegressed`, distinct from the propose-time error.
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
    /// @dev Lead-only Draft -> Cancelled transition, gated by the SAME near-quorum
    ///      guard `cancelProposal`'s Draft branch enforces. This is the identical
    ///      actor performing the identical state transition, so the two must share
    ///      one check or a lead could dodge the guard by calling whichever
    ///      entrypoint it does not cover.
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
    /// @notice Set the ceiling on `envelope.maxCapital`, in bps of the vault's
    ///         `totalAssets()` at propose time. Bounds: 1..10_000.
    function setMaxCapitalBps(uint256 newMaxCapitalBps) external;
    /// @notice Effective maxCapital ceiling in bps of TVL (10_000 = 100%, the
    ///         default when never set).
    function maxCapitalBps() external view returns (uint256);
    /// @notice Set the per-call tier-2 (uncertified) capital-cap ceiling, in
    ///         bps of the vault's `totalAssets()` at propose time (issue #43).
    ///         Bounds: 1..10_000.
    function setTier2CallCapBps(uint256 newTier2CallCapBps) external;
    /// @notice Effective per-call tier-2 ceiling in bps of TVL (10_000 = no
    ///         ceiling, the inert default when never set).
    function tier2CallCapBps() external view returns (uint256);
    function setProtocolConfig(address newConfig) external;
    /// @notice Wire the tier registry. Factory-only, like
    ///         `setProtocolConfig`. address(0) un-wires: every proposal then
    ///         resolves to tier 2 / full notional — the safe default.
    function setTierRegistry(address newRegistry) external;
    /// @notice Wire the exposure ledger. Factory-only. `address(0)` un-wires: the
    ///         covered-TVL cap, the proposer bond gate AND the approve quorum are
    ///         then skipped. The quorum is load-bearing whenever
    ///         `quorumTierThreshold == 0` applies it at every tier, so a governor
    ///         created while the factory's ledger is unset carries no coverage gate
    ///         at all until `pushWiring` reaches it.
    /// @dev Precondition: seed the ledger's asset feed and covered-TVL cap BEFORE
    ///      wiring it. The gates fail closed, so a wired ledger with an unpriceable
    ///      vault asset or a zero cap halts all proposal creation for this vault.
    ///      There is no `setExposureLedger(0)` escape hatch once wired — both
    ///      factory call sites skip re-wiring when the factory's own ledger is
    ///      unset — so fixing the feed or cap on the ledger itself is the remedy.
    function setExposureLedger(address newLedger) external;
    /// @notice Wire the proposer bond escrow. Factory-only. address(0)
    ///         un-wires: the bond is not locked at propose.
    /// @dev CUSTODIAL slot — re-point only at zero outstanding bonds. Bonds
    ///      already locked are released against the per-proposal stored escrow
    ///      (`StrategyProposal.proposerBondEscrow`), so re-pointing is safe for
    ///      existing proposals; a new escrow applies only to future ones.
    function setBondEscrow(address newEscrow) external;

    /// @notice Permissionless: return the proposer bond once the proposal has
    ///         reached a terminal state.
    /// @dev Rejection, expiry and cancellation all RETURN the bond — forfeiture is
    ///      exclusively a passed-challenge outcome, and a guardian block is not a
    ///      conviction. Safe to leave permissionless: the escrow pays only the
    ///      proposer it recorded at lock time, so a third-party caller can
    ///      accelerate the refund but never redirect it. Idempotent.
    function reclaimProposerBond(uint256 proposalId) external;

    // ── Init ──
    /// @notice Initialize a freshly deployed per-vault governor proxy.
    ///         Called once by the factory inside the `BeaconProxy` constructor.
    /// @param tierRegistry_ MANDATORY, must hold code (pashov finding #1). The
    ///        registry is wired HERE, not in a follow-up `setTierRegistry`, so
    ///        no governor ever exists with the batch guard's allowlist absent.
    function initialize(
        address vault_,
        address guardianRegistry_,
        address protocolConfig_,
        address factory_,
        address tierRegistry_,
        GovernorParams calldata params_
    ) external;

    // ── Factory-only ──
    function forceSetParams(GovernorParams calldata params) external;

    // ── Views ──

    function getProposal(uint256 proposalId) external view returns (StrategyProposal memory);
    function getProposalState(uint256 proposalId) external view returns (ProposalState);
    function getExecuteCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory);
    function getSettlementCalls(uint256 proposalId) external view returns (BatchExecutorLib.Call[] memory);
    /// @notice The per-call gross-outflow caps declared at propose time
    ///         (issue #43), immutable for the proposal's lifetime. Positional
    ///         against `getExecuteCalls`/`getSettlementCalls` — the interface
    ///         issue #27's proportional sizing will consume (design.md D7).
    function getCallCaps(uint256 proposalId)
        external
        view
        returns (uint256[] memory executeCallCaps, uint256[] memory settlementCallCaps);
    function getVoteWeight(uint256 proposalId, address voter) external view returns (uint256);
    function hasVoted(uint256 proposalId, address voter) external view returns (bool);
    function proposalCount() external view returns (uint256);
    function getGovernorParams() external view returns (GovernorParams memory);
    function getActiveProposal() external view returns (uint256);
    /// @notice Count of proposals for this vault in any non-terminal state.
    /// @dev Incremented on Draft -> Pending, decremented on the terminal edge.
    ///      Consumed by `requestUnstakeOwner` alongside `getActiveProposal` to
    ///      block rage-quit while any proposal binds the vault — the OR check is
    ///      belt-and-braces so stale-cache transitions cannot slip through.
    function openProposalCount() external view returns (uint256);
    function getCooldownEnd() external view returns (uint256);
    function getCapitalSnapshot(uint256 proposalId) external view returns (uint256);

    /// @notice Ceiling applied to `maxDrawdownBps` when deriving the settle-PRICE
    ///         floor (pashov finding #2). Declared here so an interface-only
    ///         consumer can read the cap that gates it without binding to the
    ///         concrete governor.
    function MAX_STAMP_DRAWDOWN_BPS() external view returns (uint256);

    /// @notice The vault price per share recorded at execute, which the
    ///         settle-price floor is measured against.
    /// @dev    `recorded == false` means no anchor exists for this proposal —
    ///         it predates the upgrade, has not executed, or has already
    ///         settled — and the floor therefore stands down. The floor a
    ///         pending settle will face is
    ///         `ppsAtExecute * (10_000 - min(maxDrawdownBps, MAX_STAMP_DRAWDOWN_BPS)) / 10_000`,
    ///         with `unstick` using the cap alone in place of the declared bps.
    function getPpsSnapshot(uint256 proposalId) external view returns (uint256 ppsAtExecute, bool recorded);
    function getCoProposers(uint256 proposalId) external view returns (CoProposer[] memory);
    /// @notice Risk envelope declared by the proposer at propose time.
    ///         Immutable for the proposal's lifetime.
    /// @dev    Returns (0, 0) for a nonexistent proposalId — the zero-value
    ///         convention shared with getCapitalSnapshot / getCoProposers.
    ///         Unambiguous here: `maxCapital == 0` is rejected at propose, so a
    ///         zero `maxCapital` reliably means "no such proposal".
    function getRiskEnvelope(uint256 proposalId) external view returns (uint256 maxCapital, uint16 maxDrawdownBps);

    /// @notice The coverage-proportional effective capital stored at execute
    ///         (issue #27) — 0 before execution, `maxCapital` on ungated
    ///         paths, otherwise the coverage-scaled ceiling. `getRiskEnvelope`
    ///         keeps returning the DECLARED `maxCapital`; this returns what
    ///         the proposal actually ran (or will run) at.
    function getEffectiveMaxCapital(uint256 proposalId) external view returns (uint256);
    function vault() external view returns (address);
    function protocolConfig() external view returns (address);

    /// @notice Address of the guardian registry (zero if not yet wired).
    function guardianRegistry() external view returns (address);

    /// @notice Address of the tier registry (zero if not wired — tier 2 default).
    function tierRegistry() external view returns (address);

    /// @notice Address of the exposure ledger (zero if not wired — gates skipped).
    function exposureLedger() external view returns (address);

    /// @notice Address of the proposer bond escrow (zero if not wired — no bond).
    function bondEscrow() external view returns (address);

    /// @notice MAX tier across the proposal's execute calls, resolved at
    ///         propose time. Returns 0 for a nonexistent proposalId — pair
    ///         with `getRiskEnvelope` (maxCapital == 0 means "no such
    ///         proposal") when disambiguation matters.
    function getProposalTier(uint256 proposalId) external view returns (uint8);

    /// @notice Extractable-value coverage the proposal demands from the
    ///         aggregate exposure cap. Snapshotted at propose time as the
    ///         per-call SUM across execute and settlement calls (see
    ///         `StrategyProposal.requiredCoverage`); re-checked at execute
    ///         (`CoverageRegressed`).
    function getRequiredCoverage(uint256 proposalId) external view returns (uint256);

    // ── Fee-escrow ──

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

    /// @notice Total escrowed fee liability against `vault` in `token`, summed
    ///         over every recipient — the aggregate `unclaimedFees` never had.
    /// @dev    Read by `SyndicateVault.totalAssets()` so escrowed fees stop
    ///         counting as LP equity (pashov review finding #3). The assets
    ///         sit in the vault but are owed to fee recipients, so a vault that
    ///         cannot see this figure prices its shares above its real equity
    ///         and lets redeemers take the difference.
    function outstandingEscrow(address vault, address token) external view returns (uint256);
}
