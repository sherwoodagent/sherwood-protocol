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
import {IStrategy} from "./interfaces/IStrategy.sol";
import {ICallSandbox} from "./interfaces/ICallSandbox.sol";
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
    /// @notice Ceiling applied to `maxDrawdownBps` when deriving the SETTLE-PRICE
    ///         loss — that stays whatever voters approved, up to 10_000.
    /// @dev    Why a cap rather than rejecting `maxDrawdownBps == 10_000` at
    ///         propose: rejecting it would make the P&L envelope answer for the
    ///         stamp's safety, which is the exact conflation this finding is
    ///         about, and it would invalidate `GovEnvelope.permissive` — the
    ///         fixture nearly every suite builds on. Capping keeps the two
    ///         questions separate: declare any loss you like, but the price a
    ///         permissionless caller may FREEZE is bounded regardless.
    ///
    ///         9_000 leaves a 100%-drawdown proposal a floor at 10% of the
    ///         execute-time price — far above the ~0 a flash-loaned settle
    ///         produces. It is NOT "far below any honest settlement": on a
    ///         proposal whose voters declared `maxDrawdownBps == 10_000`, an
    ///         honest loss past 90% is exactly the case this bar refuses. That
    ///         is a deliberate liveness trade, not an oversight — see the
    ///         residual-risk note below and
    ///         `test_subFloorSettlementIsClearedByFinalizeEmergencySettle`.
    ///
    ///         WHAT THIS BOUNDS, STATED PLAINLY. The floor does not close the
    ///         dilution attack; it prices it. An attacker who delivers 10% of
    ///         the capital instead of 0% settles just above the bar and mints
    ///         at ~10x the fair share count, then `sweep()` returns the
    ///         withheld remainder. For a queued deposit `D` against vault
    ///         assets `TA` that is `10D / (TA + 10D)` of the vault: ~60% at
    ///         `D = 0.2·TA`, ~82% at `D = TA`. What changes is the price of the
    ///         attack — the pre-fix version cost ~0 (a flash loan, repaid in
    ///         frame), this one requires REAL capital proportional to the vault
    ///         and locks it for the whole strategy term. "Bounded at 10x
    ///         dilution for an attacker willing to fund it", not "closed".
    ///
    ///         WHY NOT 5_000 (2x dilution for the same shape)? Because the bar
    ///         is symmetric: every bps of tightening moves an equal band of
    ///         HONEST settlements off `settleProposal` AND off `unstick` (which
    ///         derives its backstop from this same constant) and onto
    ///         `finalizeEmergencySettle` — owner bond, guardian review, a full
    ///         `reviewPeriod`, and a frozen vault for the duration. At 5_000
    ///         that band is every loss past 50%, which is a routine outcome for
    ///         a permissive envelope; at 9_000 it is a loss past 90%, which is
    ///         near-total. Revisit if the emergency path ever becomes cheap
    ///         enough that routing honest severe losses through it is not a
    ///         liveness regression.
    uint256 public constant MAX_STAMP_DRAWDOWN_BPS = 9_000;

    // ── Storage (existing -- DO NOT reorder) ──
    // `vault`, `protocolConfig`, `factory`, `_params` live in `GovernorParameters`.

    /// @notice Proposal ID counter (1-indexed)
    uint256 private _proposalCount;

    // `_proposals` lives in ProposalLifecycle (base owns the state machine).

    /// @notice Proposal ID -> voter -> bool
    mapping(uint256 => mapping(address => bool)) private _hasVoted;

    struct Ballot {
        VoteType support;
        uint256 weight;
        uint256 cast;
    }

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
    /// @notice Upper bounds on a `proposeWithSandbox` payload. MUST EQUAL
    ///         `CallSandbox.MAX_CALLS` / `MAX_DECLARED_TOKENS` — mirrored here
    ///         rather than read from the implementation because this runs on
    ///         every propose and the sandbox address is two external hops away,
    ///         and pinned equal by `test_sandboxBounds_matchImplementation`. A
    ///         governor bound ABOVE the sandbox's would let a proposal pass
    ///         review and then revert `InvalidCallSet` at execute, unfixably.
    uint256 internal constant MAX_SANDBOX_CALLS = 32;
    uint256 internal constant MAX_SANDBOX_TOKENS = 16;

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

    /// @dev Escrow of fee transfers that reverted (e.g. USDC blacklist) so the
    ///      rest of `_distributeFees` keeps flowing and settlement never bricks.
    ///      Recipients pull via `claimUnclaimedFees`; the underlying stays in the
    ///      vault and this mapping is pure bookkeeping. Keyed by
    ///      `keccak256(vault, recipient, token)` so a claim can only pull from the
    ///      vault that owes the escrow — otherwise a recipient with escrow on
    ///      vault A could redirect the pull to vault B.
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
    ///         and persisted at execute so `settleProposal` reads byte-identical
    ///         caps however much later it runs. Populated on EVERY execute path,
    ///         so it is never empty for an `Executed` proposal.
    mapping(uint256 => uint256[]) private _effectiveSettlementCallCaps;

    /// @notice Outstanding escrowed fee liability per `(vault, token)` — the
    /// @dev `_unclaimedFees` is keyed per RECIPIENT with no total, so the vault
    ///      holding the escrowed assets could not see that it owed them and
    ///      `totalAssets()` counted them as LP equity. Appended before `__gap`,
    ///      which shrinks 28 -> 27; every pre-existing variable keeps its slot.
    mapping(address vault => mapping(address token => uint256)) private _escrowedFees;

    /// @notice Proposal ID -> the vault's price per share at EXECUTE, captured
    /// @dev THE ANCHOR THE SETTLE-PRICE FLOOR IS MEASURED AGAINST, and the
    ///      reason it cannot be faked. Taken while the vault still physically
    ///      holds the capital, so it is a real ratio (~par) rather than the
    ///      near-zero figure the vault reports for the whole Executed window,
    ///      during which `totalAssets()` counts only idle float.
    ///
    ///      A PRIOR-BLOCK READ WOULD NOT SUBSTITUTE. Robinhood Chain blocks are
    ///      ~100ms, so "last block" is no economic barrier at all, and one block
    ///      before settlement the capital is still deployed — that reading is
    ///      also ~0. What makes this anchor unreachable is the DISTANCE (a whole
    ///      strategy term) and the INSTANT (pre-deployment), not its age.
    ///
    ///      Appended before `__gap`, which shrinks 27 -> 26; every pre-existing
    ///      variable keeps its slot. Regenerate the golden with
    ///      `./script/check-layout-goldens.sh --update-golden`.
    mapping(uint256 => uint256) private _ppsSnapshots;

    /// @notice Proposal ID -> the vault asset a `proposeWithSandbox` payload asks
    ///         the sandbox to be funded with. Zero for every ordinary proposal.
    /// @dev THE ONE FIELD BOTH PRICING AND DISPATCH READ. Written before
    ///      `_snapshotTierAndGate` runs, because that is where required coverage
    ///      is computed and the proposer bond is locked — a funding figure
    ///      written after it would be priced at zero and the bond would
    ///      under-charge, the same "read state a later call in this transaction
    ///      establishes" ordering bug the residue netting hit.
    mapping(uint256 => uint256) private _sandboxFunding;

    /// @notice Proposal ID -> the arbitrary call set the sandbox runs.
    /// @dev Also the EXISTENCE FLAG: a non-empty array is what "this proposal has
    ///      a sandbox" means everywhere, which is why an empty payload is refused
    ///      at propose rather than stored.
    mapping(uint256 => ICallSandbox.Call[]) private _sandboxCalls;

    /// @notice Proposal ID -> non-asset tokens the payload declares it may hold.
    /// @dev Forwarded verbatim to `runSandbox`, where they become what the
    ///      vault's residue probes can see. Undeclared leftovers are stranded in
    ///      the sandbox by construction — never priced into a deposit, never
    ///      collectable — which is the honest failure mode.
    mapping(uint256 => address[]) private _sandboxTokens;

    uint256 private _voteExitPid;

    uint256 private _voteExitShares;

    mapping(uint256 => mapping(address => Ballot)) private _ballots;

    /// @dev Reserved storage for future upgrades. Carved by 3 slots (from 31)
    ///      for the three mappings above, then 1 more for `_escrowedFees`, then
    ///      1 more for `_ppsSnapshots`, then 3 more for the sandbox payload
    ///      (23 -> 20) — append-only. See
    ///      `script/syndicate-governor-layout.golden.json`.
    uint256[20] private __gap;

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
        address tierRegistry_,
        GovernorParams calldata params_
    ) external initializer {
        if (guardianRegistry_ == address(0) || protocolConfig_ == address(0) || factory_ == address(0)) {
            revert ZeroAddress();
        }
        if (tierRegistry_.code.length == 0) revert TierRegistryNotWired();
        _validateParamBounds(params_);
        vault = vault_;
        _guardianRegistry = guardianRegistry_;
        protocolConfig = protocolConfig_;
        factory = factory_;
        _tierRegistry = tierRegistry_;
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

    function _getEffectiveSettlementCallCaps(uint256 id) internal view override returns (uint256[] storage) {
        return _effectiveSettlementCallCaps[id];
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
        proposalId = _propose(
            vault,
            strategy,
            metadataURI,
            strategyDuration,
            envelope,
            executeCalls,
            executeCallCaps,
            settlementCalls,
            settlementCallCaps,
            coProposers
        );
    }

    /// @inheritdoc ISyndicateGovernor
    function proposeWithSandbox(
        SandboxPayload calldata sandbox,
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
        // Payload validation only. Every OTHER gate — agent registration, the
        // open-proposal lock, the envelope, the batch caps — belongs to the
        // shared `_propose` body below and is not restated here, so the two
        // entry points can never diverge on what a valid proposal is.
        if (sandbox.calls.length == 0) revert EmptySandboxCalls();
        // THE SANDBOX'S OWN BOUNDS, NOT `MAX_CALLS_PER_PROPOSAL`. `CallSandbox.init`
        // refuses more than 32 calls or 16 declared tokens, and the batch bound is
        // 64 — so validating against the batch figure here would accept a payload
        // that reverts `InvalidCallSet` at execute, after the proposer's bond was
        // locked and the review period spent, with no path to fix it.
        if (sandbox.calls.length > MAX_SANDBOX_CALLS) revert TooManyCalls();
        if (sandbox.declaredTokens.length > MAX_SANDBOX_TOKENS) revert TooManySandboxTokens();
        for (uint256 i = 0; i < sandbox.calls.length; i++) {
            if (sandbox.calls[i].target == address(0)) revert ZeroSandboxTarget(i);
        }
        for (uint256 i = 0; i < sandbox.declaredTokens.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (sandbox.declaredTokens[i] == sandbox.declaredTokens[j]) {
                    revert DuplicateSandboxToken(sandbox.declaredTokens[i]);
                }
            }
        }
        if (sandbox.funding == 0) revert ZeroSandboxFunding();
        if (ISyndicateVault(vault).sandboxImplementation() == address(0)) {
            revert SandboxNotAvailable(vault);
        }
        // THE SANDBOX SPENDS THE DECLARED ENVELOPE, NOT A SECOND ONE. Bounding
        // funding by `maxCapital` here is what lets `executeProposal` subtract
        // the funded amount from the capital handed to the execute batch without
        // ever underflowing, and it keeps the figure voters approved as the true
        // ceiling on everything this proposal can move.
        if (sandbox.funding > envelope.maxCapital) {
            revert SandboxFundingExceedsMaxCapital(sandbox.funding, envelope.maxCapital);
        }

        uint256 expectedId = _proposalCount + 1;
        _storeSandbox(expectedId, sandbox);

        proposalId = _propose(
            vault,
            strategy,
            metadataURI,
            strategyDuration,
            envelope,
            executeCalls,
            executeCallCaps,
            settlementCalls,
            settlementCallCaps,
            coProposers
        );
        if (proposalId != expectedId) revert SandboxProposalIdMismatch(expectedId, proposalId);
        emit SandboxPayloadStored(proposalId, sandbox.funding, sandbox.calls.length, sandbox.declaredTokens.length);
    }

    /// @inheritdoc ISyndicateGovernor
    function sandboxPayload(uint256 proposalId) external view returns (SandboxPayload memory payload) {
        ICallSandbox.Call[] storage stored = _sandboxCalls[proposalId];
        uint256 n = stored.length;
        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](n);
        for (uint256 i = 0; i < n; i++) {
            calls[i] = ICallSandbox.Call({target: stored[i].target, data: stored[i].data});
        }
        payload = SandboxPayload({
            funding: _sandboxFunding[proposalId], calls: calls, declaredTokens: _sandboxTokens[proposalId]
        });
    }

    /// @dev The shared `propose` body. Split out so `proposeWithSandbox` reaches
    ///      exactly the same lifecycle — same gates, same order, same storage
    ///      writes — instead of a parallel copy that could drift from it.
    function _propose(
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
    ) private returns (uint256 proposalId) {
        if (vault != GovernorParameters.vault) revert VaultNotRegistered();
        if (!ISyndicateVault(vault).isAgent(msg.sender)) revert NotRegisteredAgent();
        // (`openspec/changes/owner-bond-proposal-gate`)
        if (!IGuardianRegistry(_guardianRegistry).ownerBondLive(vault)) revert OwnerBondNotLive();
        // Blocks new proposals when the vault still has a non-terminal
        // lifecycle bound to it (Pending / GuardianReview / Approved / Executed).
        // Draft co-proposals do not count toward openProposalCount and are
        // independently gated at their Draft -> Pending transition.
        if (_openProposalCount != 0) revert VaultHasOpenProposal();
        if (strategy != address(0) && strategy.code.length != 0) {
            (bool okP, bytes memory pRet) = strategy.staticcall(abi.encodeCall(IStrategy.proposer, ()));
            address declaredProposer = (okP && pRet.length == 32) ? abi.decode(pRet, (address)) : address(0);
            if (declaredProposer != address(0)) {
                if (declaredProposer != msg.sender) revert StrategyProposerMismatch();
                (bool okV, bytes memory vRet) = strategy.staticcall(abi.encodeCall(IStrategy.vault, ()));
                if (okV && vRet.length == 32 && abi.decode(vRet, (address)) != vault) {
                    revert StrategyVaultMismatch();
                }
            }
        }
        if (strategyDuration > _params.maxStrategyDuration) revert StrategyDurationTooLong();
        if (strategyDuration < _params.minStrategyDuration) revert StrategyDurationTooShort();
        if (executeCalls.length == 0) revert EmptyExecuteCalls();
        if (settlementCalls.length == 0) revert EmptySettlementCalls();
        // Caps batch sizes. Kept HERE rather than folded into
        // `_validateAndStoreBatch` to preserve the check ORDER relative to the
        // errors below — tests pin which fires first on a doubly-invalid
        // proposal — and because it is pure `.length` arithmetic on params
        // already read, so it costs nothing on the stack budget.
        if (executeCalls.length > MAX_CALLS_PER_PROPOSAL || settlementCalls.length > MAX_CALLS_PER_PROPOSAL) {
            revert TooManyCalls();
        }
        // Reject any call in either array whose target the vault's
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

        _validateAndStoreBatch(
            proposalId, executeCalls, executeCallCaps, settlementCalls, settlementCallCaps, envelope.maxCapital
        );

        bool isCollaborative = coProposers.length > 0;

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
            // call, and a WOOD with a transfer hook can re-enter mid-propose. A
            // Draft observed with `collaborationDeadline == 0` resolves to
            // Expired, which permissionless `resolveProposalState` would commit —
            // bricking the proposal forever.
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

        // Tier resolution: proposal tier = MAX tier across execute AND
        // settlement calls; `requiredCoverage` is the per-call SUM over execute
        // AND settlement calls. Resolved from the STORED calls rather than the calldata arrays
        // so those refs are dead by this point — keeps `propose` under Yul's
        // stack budget. Reads the same storage arrays re-resolved at execute.
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

        uint256 weight = IVotes(proposal.vault).getPastVotes(msg.sender, proposal.snapshotTimestamp);
        uint256 liveWeight = IVotes(proposal.vault).getVotes(msg.sender);
        if (liveWeight < weight) weight = liveWeight;
        if (weight == 0) revert NoVotingPower();

        _hasVoted[proposalId][msg.sender] = true;
        // if the voter's weight later moves. What is stored is the CAPPED
        // weight -- the snapshot figure less anything already gone -- so the
        // recompute below can never restore weight the voter did not carry
        // when they voted.
        _ballots[proposalId][msg.sender] = Ballot({support: support, weight: weight, cast: weight});

        if (support == VoteType.For) {
            proposal.votesFor += weight;
        } else if (support == VoteType.Against) {
            proposal.votesAgainst += weight;
        } else {
            proposal.votesAbstain += weight;
        }

        emit VoteCast(proposalId, msg.sender, support, weight);
    }

    function notifyShareExit(uint256 shares) external {
        if (msg.sender != GovernorParameters.vault) return;
        if (shares == 0) return;
        (uint256 pid,) = _openVote();
        if (pid == 0) return;

        if (_voteExitPid != pid) {
            _voteExitPid = pid;
            _voteExitShares = 0;
        }
        _voteExitShares += shares;
    }

    function notifyVotingWeightMoved(address voter) external {
        if (msg.sender != GovernorParameters.vault) return;
        (uint256 pid, StrategyProposal storage p) = _openVote();
        if (pid == 0) return;

        Ballot storage b = _ballots[pid][voter];
        uint256 cast = b.cast;
        if (cast == 0) return;

        uint256 live = IVotes(p.vault).getVotes(voter);
        uint256 want = live < cast ? live : cast;
        uint256 have = b.weight;
        if (want == have) return;
        b.weight = want;

        if (want < have) {
            uint256 cut = have - want;
            if (b.support == VoteType.For) p.votesFor -= cut;
            else if (b.support == VoteType.Against) p.votesAgainst -= cut;
            else p.votesAbstain -= cut;
            emit VoteWithdrawnOnExit(pid, voter, cut);
        } else {
            uint256 back = want - have;
            if (b.support == VoteType.For) p.votesFor += back;
            else if (b.support == VoteType.Against) p.votesAgainst += back;
            else p.votesAbstain += back;
            emit VoteRestoredOnReturn(pid, voter, back);
        }
    }

    function _openVote() internal view returns (uint256 pid, StrategyProposal storage p) {
        pid = _proposalCount;
        p = _proposals[pid];
        if (p.id == 0 || p.state != ProposalState.Pending || block.timestamp > p.voteEnd) pid = 0;
    }

    function _exitedDuringVote(uint256 proposalId) internal view override returns (uint256) {
        return _voteExitPid == proposalId ? _voteExitShares : 0;
    }

    /// @inheritdoc ISyndicateGovernor
    function executeProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];

        // Resolve state (may transition Pending->Approved/Rejected/Expired or Approved->Expired)
        if (_commitState(proposal) != ProposalState.Approved) revert ProposalNotApproved();

        address vault = proposal.vault;
        if (_activeProposal != 0) revert StrategyAlreadyActive();
        // propose and execute (`slashOwnerBond` has no open-proposal gate).
        // (`openspec/changes/owner-bond-proposal-gate`)
        if (!IGuardianRegistry(_guardianRegistry).ownerBondLive(vault)) revert OwnerBondNotLive();
        // Cooldown check (skip if no prior settlement)
        uint256 lastSettled = _lastSettledAt;
        if (lastSettled != 0 && block.timestamp < lastSettled + _params.cooldownPeriod) {
            revert CooldownNotElapsed();
        }

        // Snapshot vault balance before execution
        address asset = IERC4626(vault).asset();
        uint256 balanceBefore = IERC20(asset).balanceOf(vault);
        _capitalSnapshots[proposalId] = balanceBefore;
        _ppsSnapshots[proposalId] = ISyndicateVault(vault).pricePerShare() + 1;

        // Update state BEFORE external call (CEI pattern)
        _activeProposal = proposalId;
        _transition(proposal, ProposalState.Executed);
        proposal.executedAt = block.timestamp;
        // Start the management-fee clock. Must follow `_activeProposal` so the
        // vault's `totalAssets()` reads live NAV through the now-active lane, and
        // must precede the execute batch so capital it deploys is picked up by
        // the batch's own base-changing hooks. Accrual runs from here to settle
        // and nowhere else.
        ISyndicateVault(vault).startManagementAccrual();
        // Counter stays incremented through Executed; decremented once on the
        // Executed -> Settled edge in `_finishSettlement`. `_activeProposal`
        // also guards the Executed window (see `requestUnstakeOwner`).

        // Load the stored execute calls once — reused by the tier re-resolve
        // and the vault batch below (single SLOAD-loop; cold path, no stack risk).
        BatchExecutorLib.Call[] memory calls = _loadCalls(_executeCalls, proposalId);

        uint256 sandboxFunding = _sandboxFunding[proposalId];
        (uint8 liveTier, uint256 liveCoverage) = _resolveTierAndCoverage(
            calls,
            _loadCaps(_executeCallCaps, proposalId),
            _loadCalls(_settlementCalls, proposalId),
            _loadCaps(_settlementCallCaps, proposalId),
            proposal.maxCapital,
            false
        );
        if (liveTier > proposal.envelopeTier) revert TierRegressed();
        if (liveCoverage + sandboxFunding > proposal.requiredCoverage) revert CoverageRegressed();

        if (proposal.maxCapital > _capitalCeiling()) revert MaxCapitalCeilingRegressed();

        uint256[] memory scaledExecuteCaps =
            _deriveAndStoreEffectiveCapital(proposalId, proposal, _exposureLedger, asset);

        uint256 batchCapital = proposal.effectiveMaxCapital;
        if (sandboxFunding != 0) {
            uint256 maxCapital = proposal.maxCapital;
            uint256 scaledFunding =
                batchCapital == maxCapital ? sandboxFunding : (sandboxFunding * batchCapital) / maxCapital;
            // A payload whose coverage floored to nothing runs NOTHING. Minting
            // an unfunded sandbox would still execute arbitrary calldata — from
            // an address holding no capital, so nothing could be lost, but it
            // would also consume the one-sandbox-per-proposal slot and emit a
            // run that under-covered guardians never underwrote at that size.
            if (scaledFunding != 0) {
                batchCapital -= scaledFunding;
                ISyndicateVault(vault)
                    .runSandbox(proposalId, _loadSandboxCalls(proposalId), _sandboxTokens[proposalId], scaledFunding);
            }
        }

        ISyndicateVault(vault).executeGovernorBatch(calls, scaledExecuteCaps, batchCapital);

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

        ISyndicateVault(proposal.vault)
            .executeGovernorBatch(
                _loadCalls(_settlementCalls, proposalId),
                _loadCaps(_effectiveSettlementCallCaps, proposalId),
                proposal.effectiveMaxCapital
            );

        {
            uint256 basis = _capitalSnapshots[proposalId];
            uint256 allowance = (proposal.effectiveMaxCapital * proposal.maxDrawdownBps) / BPS_DENOMINATOR;
            // `allowance >= basis` covers the declared-total-loss envelope
            // (`maxDrawdownBps == 10_000` on a proposal committing the whole
            // float): the floor is zero, so any realized balance settles. That
            // is the envelope working as declared, not a hole.
            if (basis > allowance) {
                uint256 floor = basis - allowance;
                uint256 realized = IERC20(IERC4626(proposal.vault).asset()).balanceOf(proposal.vault);
                if (realized < floor) revert SettlementBelowDrawdownFloor(realized, floor);
            }
        }

        _requireSettlePriceAboveFloorHook(proposalId, proposal, false);

        _finishSettlement(proposalId, proposal);
    }

    function _requireSettlePriceAboveFloorHook(uint256 proposalId, StrategyProposal storage proposal, bool rescuePath)
        internal
        view
        override
    {
        // Zero means a proposal executed before this upgrade landed: there is no
        // anchor to measure against, and inventing one would gate in-flight
        // proposals on a figure never recorded. Those keep the pre-fix
        // behaviour rather than becoming unsettleable. The +1 offset at the
        // write site is what keeps this branch meaning ONLY that.
        uint256 anchor = _ppsSnapshots[proposalId];
        if (anchor == 0) return;
        uint256 ppsAtExecute = anchor - 1;

        uint256 declared = rescuePath ? MAX_STAMP_DRAWDOWN_BPS : proposal.maxDrawdownBps;
        if (declared > MAX_STAMP_DRAWDOWN_BPS) declared = MAX_STAMP_DRAWDOWN_BPS;
        uint256 ppsFloor = (ppsAtExecute * (BPS_DENOMINATOR - declared)) / BPS_DENOMINATOR;

        uint256 ppsNow = ISyndicateVault(proposal.vault).pricePerShare();
        if (ppsNow < ppsFloor) revert SettlePriceBelowFloor(ppsNow, ppsFloor);
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Proposer abandonment is allowed at any pre-execute stage, symmetric
    ///      with `settleProposal` (proposer-anytime), which already lets the
    ///      proposer abandon mid-strategy at no penalty — cancelling before
    ///      execute is strictly less harmful, since no capital was deployed and
    ///      no fees accrued. Cancel during GuardianReview drives the registry's
    ///      `cancelReview` so a stale `resolveReview` cannot still slash
    ///      approvers. `_lastSettledAt` is bumped on every cancel branch that
    ///      decrements the open count, rate-limiting propose-cancel-propose-
    ///      execute via the same cooldown that gates execute after a settle.
    function cancelProposal(uint256 proposalId) external nonReentrant {
        StrategyProposal storage proposal = _proposals[proposalId];
        if (msg.sender != proposal.proposer) revert NotProposer();
        ProposalState s = _commitState(proposal);
        if (s == ProposalState.Pending) {
            // Pending: only during the voting period.
            if (block.timestamp > proposal.voteEnd) revert ProposalNotCancellable();
            // The review was registered at the Draft -> Pending transition, so it
            // must be closed here too — otherwise a keeper opens it at `voteEnd`
            // and guardians are slashed for approving a Cancelled proposal.
            // Best-effort; in this branch the review cannot yet be open.
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
            // Blocks lead cancel once all-but-one co-proposer has approved,
            // preventing a front-run of the final approve tx. A single
            // co-proposer Draft stays cancellable. Shared with
            // `rejectCollaboration`'s IDENTICAL transition so the two lead-abort
            // paths cannot drift apart.
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
    /// @dev Single reclaim entrypoint for all terminal paths (settle / cancel /
    ///      expiry / emergency) rather than a hook in each. Permissionless is safe
    ///      because `releaseBond` always pays the proposer recorded at lock time —
    ///      a caller can only accelerate the refund, never redirect it.
    ///
    ///      Rejected / Expired / Cancelled release immediately: those proposals
    ///      never executed, so there is nothing a challenge could allege.
    ///
    ///      A bond already confiscated by a conviction is acknowledged, not
    ///      reverted: `forfeitBond` deletes the escrow record without touching
    ///      this proposal's `proposerBondWood`, so a forfeited bond would
    ///      otherwise pass every gate below and die forever in the escrow's
    ///      `NoBond`. Detected by reading the pinned escrow's `bondOf` and handled
    ///      BEFORE the executed-proposal gates, since a forfeited bond has no
    ///      window left to wait out.
    ///
    ///      Settled proposals wait `strategyDuration + challengeWindow` after
    ///      `executedAt`, and release only while the ledger's per-proposal
    ///      coverage freeze is clear — a proposer who executes a drain and
    ///      self-settles cannot walk away with the bond before `ChallengeGame` can
    ///      confiscate it.
    ///
    ///      Elapsed time and the freeze are not sufficient on their own: the
    ///      adversary is a proposer racing an `Inconclusive` unwind's re-armed
    ///      window. `ChallengeGame._refundAll` releases the freeze AND raises
    ///      `challengeableUntil` in the same call, so between that unwind and the
    ///      re-armed deadline both gates are open while a conviction is still
    ///      reachable. The third gate therefore asks the game itself and mirrors
    ///      `ChallengeGame.file`'s own deadline,
    ///      `max(executedAt + strategyDuration + game.challengeWindow(),
    ///      challengeableUntil[rk])`. The `+ strategyDuration` term is
    ///      load-bearing and must track `file` exactly: without it these gates
    ///      lift up to 30 days before `file` stops admitting, releasing the very
    ///      bond a successful challenge is paid out of. Reading the game's window
    ///      rather than only `challengeableUntil` also covers the ledger owner
    ///      lowering the LEDGER's window below the game's, which nothing on the
    ///      game side prevents. Strict `>`: `file` admits while
    ///      `block.timestamp <= deadline`.
    ///
    ///      All three gates run against `proposal.proposerBondLedger`, the ledger
    ///      PINNED at propose time (falling back to the live slot only for a
    ///      pre-pin proposal), so a factory re-point after this proposal settles
    ///      cannot detach them from a still-convictable challenge.
    ///
    ///      Skipped entirely when the ledger's `coverageFreezer` is unset: with no
    ///      freezer, neither `freezeCoverage` nor `forfeitBond` can fire, so no
    ///      conviction is reachable and an unwired freezer must not strand an
    ///      honest proposer's bond. A non-zero freezer that REVERTS or cannot be
    ///      read fails closed — recover by rotating `coverageFreezer` ON THE
    ///      PINNED LEDGER. Note the asymmetry: a freezer that ANSWERS zero passes
    ///      rather than failing closed, so fail-closed covers unreadability, not
    ///      every unhelpful answer.
    ///
    ///      Releases against `proposal.proposerBondEscrow` (bound at propose), NOT
    ///      the live slot: the escrow has no owner and no discretionary exit, and
    ///      its bond key is (governor, proposalId), so releasing against a
    ///      re-pointed slot would strand the WOOD forever.
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
            // live `_exposureLedger` slot after this proposal locked its bond
            // must not change which ledger these gates read. Zero pin means a
            // pre-upgrade proposal that recorded no ledger — fall back to the
            // live slot so it keeps its exact pre-pin behavior.
            address ledger = proposal.proposerBondLedger;
            if (ledger == address(0)) ledger = _exposureLedger;
            // Fails closed: fail-open would let the factory bypass this delay in
            // one transaction via `setExposureLedger(0)`. The freeze cannot
            // strand the bond permanently — rotating the pinned ledger's own
            // `coverageFreezer` makes it reclaimable again.
            if (ledger == address(0)) revert ExposureLedgerUnset();
            uint256 strategyDuration = proposal.strategyDuration;
            if (block.timestamp < executedAt + strategyDuration + IExposureLedger(ledger).challengeWindow()) {
                revert ChallengeWindowOpen();
            }
            if (IExposureLedger(ledger).isCoverageFrozen(address(this), proposalId)) {
                revert ChallengeWindowOpen();
            }
            // Gate 3: the game's LIVE filing deadline. See the natspec above
            // for why the two gates above are not sufficient on their own.
            address freezer = IExposureLedger(ledger).coverageFreezer();
            if (freezer != address(0)) {
                // Must reproduce `ChallengeGame.file`'s deadline EXACTLY —
                // `executedAt + p.strategyDuration + challengeWindow`, then
                // maxed against `challengeableUntil` — or this gate lifts
                // while `file` is still admitting.
                uint256 deadline = executedAt + strategyDuration + IChallengeGame(freezer).challengeWindow();
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
            if (proposal.reviewEnd > proposal.voteEnd) {
                IGuardianRegistry(_guardianRegistry).registerReview(proposalId, proposal.voteEnd, proposal.reviewEnd);
            }
            emit CollaborationTransitionedToPending(proposalId);
        }
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev Same Draft -> Cancelled transition, by the same actor, as
    ///      `cancelProposal`'s Draft branch — gated by the identical
    ///      `_requireNotNearQuorum` guard. Without it, a lead near quorum could
    ///      dodge `cancelProposal`'s guard by calling this entrypoint instead.
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

    /// @notice Permissionless: flushes a proposal's lazy terminal-state transition
    ///         (Rejected / Expired) so the `_openProposalCount` decrement commits.
    /// @dev `_commitState` decrements when it transitions a proposal into a
    ///      terminal state, but each mutating caller reverts if the resolved state
    ///      is not in its allow-list, rolling the decrement back. Without this
    ///      flush, a vote that pushes `votesAgainst` past the veto threshold, or
    ///      an approved-but-unexecuted proposal past `executeBy`, pins the counter
    ///      at 1 — bricking future `propose()` and owner `requestUnstakeOwner`.
    ///      Idempotent.
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
    /// @dev Two returns rather than the zero-value convention `getCapitalSnapshot`
    ///      uses, because zero is MEANINGFUL here: `pricePerShare()` floors to 0
    ///      on a live vault, so a single-value getter would reproduce off-chain
    ///      exactly the sentinel ambiguity the `+1` storage offset exists to
    ///      remove. `recorded == false` means no anchor (pre-upgrade proposal,
    ///      not yet executed, or already cleared at settlement) and therefore
    ///      "this gate will stand down"; only `recorded == true` makes
    ///      `ppsAtExecute` a number a monitor may derive the floor from.
    function getPpsSnapshot(uint256 proposalId) external view returns (uint256 ppsAtExecute, bool recorded) {
        uint256 anchor = _ppsSnapshots[proposalId];
        if (anchor == 0) return (0, false);
        return (anchor - 1, true);
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
    /// @dev The guardian registry no longer calls this, but `ExposureLedger` reads
    ///      `.vault` on the approve-vote path and `.executedAt` on every
    ///      post-execution coverage read, to anchor a guardian's slashable-stake
    ///      basis. Do not remove until those consumers migrate.
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
        // `reviewPeriod == 0` the window collapses and the registry would revert
        // `InvalidReviewWindow`.
        // LOAD-BEARING: this predicate must stay identical to the one `_afterVote`
        // tests, or a proposal can auto-approve with no guardian review.
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

    function _checkMaxCapitalCeiling(uint256 maxCapital) private view {
        if (maxCapital > _capitalCeiling()) revert MaxCapitalExceedsCeiling();
    }

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
        uint256 sandboxFunding = _sandboxFunding[p.id];
        if (sandboxFunding != 0) {
            tier_ = 2;
            coverage_ += sandboxFunding;
        }
        p.envelopeTier = tier_;
        p.requiredCoverage = coverage_;
        // Skipped when unwired — the pre-ledger safe default matches the
        // tierRegistry pattern.
        address ledger = _exposureLedger;
        if (ledger != address(0)) {
            address asset = IERC4626(GovernorParameters.vault).asset();
            IExposureLedger(ledger).requireWithinCoveredTvlCap(asset, coverage_);
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
                    if (IProposerBondEscrow(escrow).exposureLedger() != ledger) {
                        revert LedgerEscrowMismatch();
                    }
                    // Bind the bond to THIS escrow AND this ledger:
                    // `reclaimProposerBond` releases against the stored escrow and
                    // gates against the stored ledger, so re-pointing either slot
                    // later cannot strand the bond or detach its reclaim gates.
                    // All three writes precede the external call (CEI).
                    p.proposerBondWood = bondWood;
                    p.proposerBondEscrow = escrow;
                    p.proposerBondLedger = ledger;
                    // STATE-CHANGING external call: `lockBond` pulls WOOD via
                    // `transferFrom`, so a WOOD with a transfer hook can re-enter
                    // here. INVARIANT: every proposal-state field the lifecycle
                    // reads must ALREADY be written by this point. Do not move a
                    // state write below this call.
                    IProposerBondEscrow(escrow).lockBond(p.id, p.proposer, bondWood);
                }
            }
        }
    }

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
        (uint8 settleTier, uint256 settleCoverage) =
            _scanCalls(registry, settleCalls, settleCaps, checkCeiling, tier2Ceiling);
        // approve-quorum gate and `TierRegressed` both key off this tier; taking
        // execTier only let a proposer park an uncertified tier-2 extraction in
        // `settlementCalls` under a low-tier execute leg, so it skipped the
        // bond-encumbered quorum while coverage (already summed over both legs)
        // priced it. Coverage was always whole-proposal; now tier is too.
        tier = execTier >= settleTier ? execTier : settleTier;
        coverage = execCoverage + settleCoverage;
    }

    /// @dev Max tier and `sum(cap_i * boundBps_i) / 10_000` across `calls`,
    ///      resolved through the TierRegistry. When `checkCeiling` is set, also
    ///      enforces the per-call tier-2 ceiling in the SAME sweep (one registry
    ///      scan, not two): any call resolving to tier 2, uncertified included,
    ///      must declare `caps[i] <= tier2Ceiling`. The reported `i` is this
    ///      array's own index; exec and settle are scanned as two separate calls.
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
                // memory content, no writes. Annotated so the via-ir pipeline's
                // memory-safety proof is not blocked contract-wide, which would
                // cost memory-based stack spilling elsewhere.
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

    /// @dev Persist a sandbox payload verbatim under `proposalId`. WRITE-ONCE BY
    ///      CONSTRUCTION: the only caller is `proposeWithSandbox`, which runs it
    ///      against an id that does not exist yet, so there is never a stored
    ///      payload to append to or overwrite — no setter, no re-open path, and
    ///      what guardians read during the review period is what executes.
    function _storeSandbox(uint256 proposalId, SandboxPayload calldata sandbox) private {
        _sandboxFunding[proposalId] = sandbox.funding;
        ICallSandbox.Call[] storage dst = _sandboxCalls[proposalId];
        for (uint256 i = 0; i < sandbox.calls.length; i++) {
            dst.push(sandbox.calls[i]);
        }
        address[] storage tokens = _sandboxTokens[proposalId];
        for (uint256 i = 0; i < sandbox.declaredTokens.length; i++) {
            tokens.push(sandbox.declaredTokens[i]);
        }
    }

    /// @dev Copy a stored sandbox call set to memory for dispatch.
    function _loadSandboxCalls(uint256 proposalId) private view returns (ICallSandbox.Call[] memory result) {
        ICallSandbox.Call[] storage stored = _sandboxCalls[proposalId];
        result = new ICallSandbox.Call[](stored.length);
        for (uint256 i = 0; i < stored.length; i++) {
            result[i] = stored[i];
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
    ///      memory-argument counterpart to `_storeCaps`, which takes `calldata`,
    ///      the only location a propose-time param can have. Needed because the
    ///      scaled settlement caps are computed in memory at execute.
    function _storeCapsMemory(mapping(uint256 => uint256[]) storage target, uint256 proposalId, uint256[] memory caps)
        private
    {
        for (uint256 i = 0; i < caps.length; i++) {
            target[proposalId].push(caps[i]);
        }
    }

    function _deriveAndStoreEffectiveCapital(
        uint256 proposalId,
        StrategyProposal storage proposal,
        address ledger,
        address asset
    ) private returns (uint256[] memory scaledExecuteCaps) {
        uint256 maxCapital = proposal.maxCapital;
        uint256 coverageRaisedUsd;
        uint256 requiredCoverageUsd;
        // `requiredCoverage == 0` keeps optimistic passage: a proposal that can
        // extract nothing needs no covering signer. Reachable — an all-zero-cap
        // proposal legitimately prices to zero, and the per-call meter enforces
        // exactly that declaration.
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

    /// @dev Anti-front-run guard for the lead's Draft -> Cancelled abort, shared
    ///      by `cancelProposal`'s Draft branch and `rejectCollaboration`. Both are
    ///      the SAME actor performing the SAME transition on the SAME state, so
    ///      they must share one check or a lead near quorum could route around
    ///      whichever entrypoint enforces it. Blocks the lead once all-but-one
    ///      co-proposer has approved; a single co-proposer Draft stays cancellable.
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

        uint256 totalFee = _chargeManagementFee(proposalId, vault, asset, proposal.proposer);

        // No strategy self-report can exempt a proposal from the performance leg:
        // the self-reported opt-out was deleted because it let any registered
        // agent skip the fee by pointing a proposal at a contract that claimed to
        // self-manage. Every proposal is charged the same way.
        {
            uint256 perfFee;
            (agentFee, perfFee) = _chargePerformanceFee(proposalId, vault, asset, proposal.proposer);
            totalFee += perfFee;
        }

        // Stamp the frozen Lane B settle price for this proposal AFTER fees so
        // queued redeemers/depositors settle against the post-fee NAV. No-op if
        // the vault has no withdrawal queue.
        ISyndicateVault(vault).onProposalSettled(proposalId);

        _activeProposal = 0;
        _transition(proposal, ProposalState.Settled);
        delete _capitalSnapshots[proposalId];
        // Symmetric with the capital snapshot above: both are read only on the
        // way INTO settlement (the two floors), never after it, and `Settled`
        // is terminal — no path re-enters `_finishSettlement` for this id — so
        // clearing recovers the refund without weakening either gate.
        delete _ppsSnapshots[proposalId];
        _decOpen();

        emit ProposalSettled(proposalId, vault, pnl, totalFee, block.timestamp - proposal.executedAt);
    }

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

    function _chargePerformanceFee(uint256 proposalId, address vault, address asset, address proposer)
        internal
        returns (uint256 agentFee, uint256 perfFee)
    {
        StrategyProposal storage prop = _proposals[proposalId];

        // Profit measured against the fund's previous peak, not against this
        // proposal's own starting balance — a fund that fell and recovered has
        // already paid for this ground.
        uint256 base = ISyndicateVault(vault).aboveHighWaterMark();

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
            uint256 escrowAmount = amount;
            (bool okCap, bytes memory capRet) = vault.staticcall(abi.encodeCall(ISyndicateVault.spendableFee, (asset)));
            if (okCap && capRet.length == 32) {
                uint256 spendable = abi.decode(capRet, (uint256));
                if (spendable < escrowAmount) escrowAmount = spendable;
            }
            if (escrowAmount != amount) emit FeeEscrowCapped(recipient, asset, amount, escrowAmount);
            if (escrowAmount == 0) {
                emit FeeTransferFailed(recipient, asset, amount);
                return false;
            }
            amount = escrowAmount;
            _unclaimedFees[_unclaimedKey(vault, recipient, asset)] += amount;
            // Mirror into the per-(vault, token) aggregate so the vault can
            // net this liability out of `totalAssets()` — see `_escrowedFees`
            // one and the matching decrement in `claimUnclaimedFees` are the
            // only places either mapping moves on the escrow path.
            _escrowedFees[vault][asset] += amount;
            emit FeeTransferFailed(recipient, asset, amount);
            return false;
        }
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev `nonReentrant` here is uniformity with every other state-changing
    ///      governor entrypoint, not the closure of a live hole: CEI is respected
    ///      (the escrow slot is cleared before the external transfer), so a
    ///      reentrant call with the same key sees a zeroed slot and short-circuits.
    ///      Being the one unguarded entrypoint among guarded siblings is the
    ///      asymmetry that turns into a bug later.
    /// @dev CLOSED WHILE `vault` HAS AN ACTIVE PROPOSAL. This was the ONLY path
    ///      that could move `vault`'s asset out between `executeProposal` and
    ///      `settleProposal` without being the strategy: every other outflow is
    ///      either governor-driven (`executeGovernorBatch`, the settlement fee
    ///      transfers) or gated on `redemptionsLocked()` (instant redeem, queue
    ///      `claim`/`settleRedeem`, the `rescue*` helpers). An escrowed fee
    ///      leaving mid-strategy is indistinguishable from a strategy loss to
    ///      both asset-balance-differencing consumers: it understates
    ///      `_finishSettlement`'s `pnl`, and — since the drawdown floor —
    ///      it can revert an otherwise-profitable `settleProposal` outright,
    ///      which leaves `_activeProposal` set and therefore keeps redemptions,
    ///      queue claims and every future proposal locked until the owner
    ///      multisig runs `unstick`.
    ///
    ///      Costs the recipient nothing but a wait. The escrow only exists
    ///      because a transfer already failed once, it accrues no deadline, and
    ///      `_activeProposal` clears on every settlement path including the
    ///      emergency ones. Deliberately keyed on the CLAIMED vault, not on
    ///      `_activeProposal != 0`, so a proposal on one vault cannot freeze
    ///      escrow claims on another.
    function claimUnclaimedFees(address vault, address token) external nonReentrant {
        uint256 active = _activeProposal;
        if (active != 0 && _proposals[active].vault == vault) revert VaultProposalActive();
        bytes32 k = _unclaimedKey(vault, msg.sender, token);
        uint256 amt = _unclaimedFees[k];
        if (amt == 0) return;
        _unclaimedFees[k] = 0;
        // Released before the external call, alongside the per-recipient slot,
        // so the vault stops reserving it the instant it stops being owed —
        // and so CEI covers both writes identically.
        _escrowedFees[vault][token] -= amt;
        ISyndicateVault(vault).transferPerformanceFee(token, msg.sender, amt);
        emit FeeClaimed(msg.sender, token, amt);
    }

    /// @inheritdoc ISyndicateGovernor
    function unclaimedFees(address vault, address recipient, address token) external view returns (uint256) {
        return _unclaimedFees[_unclaimedKey(vault, recipient, token)];
    }

    /// @inheritdoc ISyndicateGovernor
    function outstandingEscrow(address vault, address token) external view returns (uint256) {
        return _escrowedFees[vault][token];
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
    function setTierRegistry(address newRegistry) external onlyFactory {
        if (newRegistry.code.length == 0) revert TierRegistryNotWired();
        emit TierRegistrySet(_tierRegistry, newRegistry);
        _tierRegistry = newRegistry;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev `address(0)` is legal: it un-wires the ledger and the covered-TVL cap
    ///      and proposer-bond gates are then skipped — the pre-ledger safe default.
    ///
    ///      WIRING ORDER (precondition): seed `setAssetFeed(vaultAsset, ...)` AND
    ///      `setCoveredTvlCapUsd(...)` on the ledger BEFORE wiring it here. The
    ///      gates are fail-closed by design, so a wired ledger with an unpriceable
    ///      vault asset or a zero cap halts ALL proposal creation for this vault.
    ///      Recover at the ledger, or point the factory at a fresh permissive
    ///      ledger and `pushWiring` this governor — the factory has no path that
    ///      passes zero here, since both callers skip unset slots.
    ///
    ///      Re-pointing this slot does NOT move a POST-UPGRADE bond's reclaim
    ///      gates: `reclaimProposerBond` pins the ledger onto the proposal at
    ///      propose time and reads that, not this live slot.
    ///
    ///      IT DOES MOVE A LEGACY BOND'S GATES. `proposerBondLedger` was appended
    ///      to `StrategyProposal` later, so any proposal that locked a bond under
    ///      a PRIOR implementation reads `address(0)` forever and the fallback
    ///      resolves to THIS live slot — reproducing, for that cohort, the exact
    ///      re-point bypass the pin exists to close. The `_openProposalCount`
    ///      guard stops blocking a re-point the moment a legacy proposal settles,
    ///      before its bond-hold window even starts, so an ORDINARY migration
    ///      silently detaches its protection. Accepted trade-off — bricking every
    ///      pre-upgrade bond was judged worse. Operational requirement: drain every
    ///      outstanding legacy bond before re-pointing this slot.
    function setExposureLedger(address newLedger) external onlyFactory {
        // Not while proposals are open: a proposal created before the ledger
        // existed carries no booked coverage, but `executeProposal` starts
        // demanding it the moment the ledger is wired, making those proposals
        // permanently unexecutable. Refusing the wiring here is the only point
        // where that failure is visible rather than silent at execute time.
        // Un-wiring is exempt: it can only relax the execute gate.
        if (newLedger != address(0) && _openProposalCount > 0) revert ParamsFrozenDuringProposal();
        emit ExposureLedgerSet(_exposureLedger, newLedger);
        _exposureLedger = newLedger;
    }

    /// @inheritdoc ISyndicateGovernor
    /// @dev `address(0)` is legal: it un-wires the escrow and no bond is locked at
    ///      propose. Unlike `setTierRegistry`, this slot has CUSTODIAL meaning —
    ///      the escrow holds real WOOD for already-created proposals — so re-point
    ///      it only at ZERO outstanding bonds. Bonds already locked are released
    ///      against the escrow stored per proposal, never this live slot, so a new
    ///      escrow applies only to proposals created after the change.
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
