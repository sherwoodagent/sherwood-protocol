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
    ///         floor (pashov finding #2). Not a bound on the strategy's declared
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

    /// @notice Tier registry. MANDATORY at `initialize` (pashov finding #1) —
    ///         a governor cannot be born unwired. Re-pointed post-init via
    ///         `setTierRegistry` (factory-only, like `setProtocolConfig`),
    ///         which also refuses zero and codeless.
    /// @dev Governors deployed BEFORE this became an init param can still read
    ///      zero here; `SyndicateVault._guardBatchCalls` fails closed on that,
    ///      and `SyndicateFactory.pushWiring` is the rescue.
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
    ///         and persisted at execute so `settleProposal` reads byte-identical
    ///         caps however much later it runs. Populated on EVERY execute path,
    ///         so it is never empty for an `Executed` proposal.
    mapping(uint256 => uint256[]) private _effectiveSettlementCallCaps;

    /// @notice Outstanding escrowed fee liability per `(vault, token)` — the
    ///         aggregate `_unclaimedFees` never had (pashov review finding #3).
    /// @dev `_unclaimedFees` is keyed per RECIPIENT with no total, so the vault
    ///      holding the escrowed assets could not see that it owed them and
    ///      `totalAssets()` counted them as LP equity. Appended before `__gap`,
    ///      which shrinks 28 -> 27; every pre-existing variable keeps its slot.
    mapping(address vault => mapping(address token => uint256)) private _escrowedFees;

    /// @notice Proposal ID -> the vault's price per share at EXECUTE, captured
    ///         before the batch deploys any capital (pashov finding #2).
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

    /// @dev Reserved storage for future upgrades. Carved by 3 slots (from 31)
    ///      for the three mappings above, then 1 more for `_escrowedFees`, then
    ///      1 more for `_ppsSnapshots`, then 3 more for the sandbox payload
    ///      (26 -> 23) — append-only. See
    ///      `script/syndicate-governor-layout.golden.json`.
    uint256[23] private __gap;

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

    /// @param tierRegistry_ MANDATORY (pashov finding #1). Wiring the registry
    ///        here rather than in a follow-up `setTierRegistry` is what makes
    ///        the registry-less governor unreachable: `_guardBatchCalls` drops
    ///        the whole callee/spender allowlist when it resolves none, so a
    ///        governor that could exist unwired for even one block could hand a
    ///        vault `asset.approve(attacker, max)` past every meter. Codeless
    ///        subsumes zero — an EOA would pass a zero-check and then revert the
    ///        guard's typed `isCallableTarget` call, bricking the vault instead.
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

    /// @dev The COVERAGE-SCALED settlement caps — what `settleProposal` and
    ///      `unstick` both meter against. Populated on EVERY execute path, so it
    ///      is never empty for a proposal in `Executed`, the only state `unstick`
    ///      accepts. Split from `_getSettlementCallCaps` rather than replacing it:
    ///      the raw propose-time array is still the record of what was voted on,
    ///      and conflating the two let the sizing be enforced on one replay path
    ///      and not the other.
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
        // MIRRORS `CallSandbox.init`'S ZERO-TARGET REFUSAL, for the same reason
        // the declared-token dedup below mirrors its duplicate check: a rule
        // enforced only at execute kills a proposal that already cleared the
        // vote and the review period, with the bond locked and no way to amend.
        //
        // AND THIS ONE ALSO PROPS UP A SENTINEL. `CallSandbox._denyIfNamed`
        // treats `address(0)` as "the probe did not resolve" and returns
        // early, so a zero target would be an entry the accounting denylist
        // cannot screen. Its natspec argues that is safe BECAUSE `init` rejects
        // zero targets — an invariant better held at both ends than at one.
        for (uint256 i = 0; i < sandbox.calls.length; i++) {
            if (sandbox.calls[i].target == address(0)) revert ZeroSandboxTarget(i);
        }
        // MIRRORS `CallSandbox.init`'S OWN REFUSAL, and must. Every rule `init`
        // enforces has to be enforced HERE too, or the payload that breaks it
        // clears the vote and the whole review period and then reverts at
        // execute with the proposer's bond locked and no way to amend — the
        // same reason the call-count bound is checked against the sandbox's
        // figure rather than the batch's. Pinned by
        // `test_propose_duplicateDeclaredTokenRejectedAtProposeNotExecute`.
        for (uint256 i = 0; i < sandbox.declaredTokens.length; i++) {
            for (uint256 j = 0; j < i; j++) {
                if (sandbox.declaredTokens[i] == sandbox.declaredTokens[j]) {
                    revert DuplicateSandboxToken(sandbox.declaredTokens[i]);
                }
            }
        }
        if (sandbox.funding == 0) revert ZeroSandboxFunding();
        // REFUSE HERE, NOT AT EXECUTE. A vault created before its factory had a
        // sandbox implementation has none and can never be given one — the
        // vault's setter is factory-only and set-once. Without this check such a
        // proposal would pass the vote, spend the whole review period, lock the
        // proposer's bond, and only then revert `SandboxNotConfigured` at
        // execute, with no way to fix it and the bond reclaimable only after the
        // proposal expires. Read live off the vault rather than mirrored here:
        // the vault is the only authority on what it will actually clone.
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

        // WRITTEN BEFORE THE PROPOSAL EXISTS, AGAINST THE ID IT IS ABOUT TO MINT.
        // `_snapshotTierAndGate` — which runs deep inside `_propose`, prices
        // required coverage and locks the proposer bond — reads the funding back
        // out of storage by proposal id. Writing the payload afterwards would
        // price it at zero: a state read that some later call in the same
        // transaction establishes reads as unset, and a helper that degrades to
        // zero makes that silent. Nothing can interleave between this write and
        // the mint (`_propose` starts with view checks and a call to the vault's
        // own `isAgent`), and if the ids ever diverge the whole transaction
        // reverts rather than leaving a payload attached to the wrong proposal.
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
        // Blocks new proposals when the vault still has a non-terminal
        // lifecycle bound to it (Pending / GuardianReview / Approved / Executed).
        // Draft co-proposals do not count toward openProposalCount and are
        // independently gated at their Draft -> Pending transition.
        if (_openProposalCount != 0) revert VaultHasOpenProposal();
        // BIND THE DECLARED STRATEGY TO ITS CALLER (pashov review finding #8).
        // `StrategyFactory.cloneAndInit` enforces `proposer == msg.sender` so
        // `_proposer` is "a known authorized address", and
        // `BaseStrategy.execute()` treats `strategyOf(activePid) ==
        // address(this)` as the security boundary — issue #150's fix, "this
        // check IS the security boundary here". But the governor never
        // preserved the binding those two ends assume: `p.strategy` was
        // written verbatim from calldata, so the equality held BY
        // CONSTRUCTION for whoever declared the clone, not for whoever owns
        // it. `IStrategy.proposer()` had zero call sites in `src/`, and
        // `StrategyFactory` records the governor-side check as "deferred".
        //
        // Unbound, any registered agent could name a rival's pre-deployed,
        // governance-allowlisted clone as its own proposal's strategy and
        // drive it Pending -> Executed. The ratchet is one-way, so the rightful
        // proposer's own later proposal then reverts `AlreadyExecuted` forever:
        // recovery needs a redeploy plus a fresh `setAdapterAllowed` and, if
        // tier-certified, a new `proposeCertification` + `certifyDelay`.
        // `address(0)` stays legal — a proposal need not name a strategy.
        // Only a CONTRACT can be bricked, so only a contract is checked. A
        // codeless `strategy` is a label and nothing more — `BaseStrategy`'s
        // ratchet needs code to flip, `executeCalls` needs code to call — and
        // `propose` has always accepted one (see
        // `test_propose_eoaStrategySucceedsAtPropose`). Raw staticcall rather
        // than a typed call for the same reason as everywhere else in this
        // repo: a contract that does not answer `proposer()` would otherwise
        // revert here with no data. It fails CLOSED — something with code that
        // cannot identify its own proposer must not be declared as one.
        // ENFORCED ONLY WHERE THERE IS SOMETHING TO PROTECT. The attack this
        // closes needs a `BaseStrategy` clone: `execute()`'s guard is
        // `strategyOf(activePid) == address(this)`, and what gets stolen is
        // that clone's one-way Pending -> Executed ratchet. An address that
        // does not answer `proposer()` has no such ratchet — it is a plain
        // adapter pointer or an EOA label, both long-standing legitimate uses
        // of this field (`test_propose_eoaStrategySucceedsAtPropose`,
        // `test_vault_activeStrategyAdapter_*`) — so there is nothing for this
        // guard to defend and refusing it would break callers for no gain.
        //
        // When the address DOES answer, the binding is mandatory: that is
        // exactly the clone case, and `StrategyFactory.cloneAndInit` already
        // pinned `_proposer` to whoever cloned it. Raw staticcall throughout,
        // so "does not answer" is a decodable state rather than an
        // uncatchable revert in this frame.
        if (strategy != address(0) && strategy.code.length != 0) {
            (bool okP, bytes memory pRet) = strategy.staticcall(abi.encodeCall(IStrategy.proposer, ()));
            address declaredProposer = (okP && pRet.length == 32) ? abi.decode(pRet, (address)) : address(0);
            if (declaredProposer != address(0)) {
                // A ZERO PROPOSER IS NOT A VICTIM. `StrategyFactory.cloneAndInit`
                // always writes `_proposer = msg.sender`, so every live clone
                // carries a non-zero one; zero means the strategy was never
                // initialized and therefore has no ratchet anyone could steal
                // and no owner anyone could grief. Templates read zero too, and
                // they set `_initialized` in their constructor so they can never
                // become live.
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

        // Per-call capital declarations: validate AND store in ONE early call so
        // the caps calldata refs die immediately after, instead of staying live
        // across the rest of this function (Yul stack-too-deep mitigation). A
        // revert here rolls back the `_proposalCount` increment alongside
        // everything else. Never folded into `_rejectPrivilegedTargets`'
        // staticcall-probe loop: different subject, different failure mode — this
        // never degrades open.
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
        // Anchor for the settle-price floor (pashov finding #2). MUST be read
        // HERE, before the execute batch deploys capital: `totalAssets()` counts
        // only the vault's idle balance, so a reading taken after deployment
        // would be ~0 and the floor derived from it would be vacuous — the exact
        // failure being fixed. Typed call: `pricePerShare()` is on
        // `ISyndicateVault` and every governor path already calls this vault.
        // STORED OFFSET BY ONE so `0` unambiguously means "no anchor recorded"
        // and can never mean "recorded as zero". `pricePerShare()` floors to 0
        // whenever `totalAssets()` reads 0 against a large supply — a state
        // `SyndicateVault` itself documents as reachable ("an escrow exceeding
        // the float pins `totalAssets()` to 0") — and without the offset that
        // would silently and totally disable this gate for the proposal.
        _ppsSnapshots[proposalId] = ISyndicateVault(vault).pricePerShare() + 1;

        // Update state BEFORE external call (CEI pattern)
        _activeProposal = proposalId;
        _transition(proposal, ProposalState.Executed);
        // INVARIANT: THIS STAMP MUST PRECEDE THE `requireApproveQuorum` GATE
        // BELOW, IN THE SAME TRANSACTION. The gate reads each approver's LIVE
        // `slashableBondUsd`, which is sound ONLY because every sWOOD stake
        // mutation checkpoints at `block.timestamp`, so the checkpoint at
        // `executedAt` equals the live stake the gate just read — the gate and
        // the eventual verdict slash (anchored at this same `executedAt`) then
        // provably value the same WOOD. Move the gate out of this transaction, or
        // ahead of this line, and that equality becomes an accident of ordering.
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

        // Fail-safe on stale certification. A proposal priced at tier 0/1 whose
        // adapter demoted since propose is under-covered — block execution rather
        // than run a possibly-unbounded batch against a bounded-tier coverage
        // price. Tier alone misses a same-tier re-certification with a higher
        // `extractableBoundBps`, so also revert when the re-resolved coverage
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

        // Fail-safe sibling to the two regression checks above. The propose-time
        // ceiling check alone is NOT sufficient: it prices `maxCapital` against
        // `totalAssets()` at PROPOSE, and nothing stops the proposer inflating
        // that denominator with its own deposit right before proposing, then
        // withdrawing it during the vote. The two capital locks read different
        // counters — `depositsLocked()` rises at PROPOSE, `redemptionsLocked()`
        // only at EXECUTE — so the proposer's own capital is free to leave in the
        // gap, shrinking the float the ceiling was computed against while
        // `maxCapital` stays pinned at its inflated value. Re-running the
        // identical ratio against LIVE totals immediately before dispatch closes
        // the window. Distinct revert so the two are never conflated off-chain.
        if (proposal.maxCapital > _capitalCeiling()) revert MaxCapitalCeilingRegressed();

        // A coverage-consuming proposal at or above the tier threshold cannot
        // execute without a bond-encumbered approve quorum: silence alone does
        // not pass it, so an identified, stake-backed approver is always on the
        // hook. A revert here leaves the proposal Approved — it expires at
        // `executeBy` unless covering approvals arrive, so suppressing the cohort
        // blocks execution without forcing cancellation.
        //
        // RUNS AFTER `proposal.executedAt = block.timestamp`, IN THE SAME
        // TRANSACTION — load-bearing (see the stamp's own note). This gate's live
        // read is what makes it sound to leave every OTHER post-execution ledger
        // read anchored at `executedAt` instead: the two are provably equal at
        // this one instant. Hoisted into `_deriveAndStoreEffectiveCapital` (an
        // INTERNAL call, so the same-transaction reach is unaffected) purely for
        // this function's Yul stack budget.
        //
        // That helper also derives `effectiveMaxCapital` from the gate's
        // raised-vs-required figures — `maxCapital` unchanged when the gate does
        // not run — and scales the stored per-call caps by the same factor,
        // persisting the scaled settlement caps for `settleProposal`.
        uint256[] memory scaledExecuteCaps =
            _deriveAndStoreEffectiveCapital(proposalId, proposal, _exposureLedger, asset);

        // Execute the opening calls via the vault. The effective capital caps the
        // batch's net asset outflow (batch-level); the coverage-scaled per-call
        // caps additionally bound each call's own gross outflow
        // (BatchExecutorLib-level) — two distinct accounting layers, both
        // mandatory on this path.
        // Dispatch the sandbox BEFORE the execute batch, and hand the batch what
        // is left of the envelope.
        //
        // ORDER IS LOAD-BEARING, NOT STYLISTIC. The vault prices its tier-2
        // ceiling off `totalAssets()`, which during the Executed window counts
        // only idle float — after the batch has deployed capital that reads near
        // zero, so a sandbox dispatched afterwards would be measured against a
        // ceiling of ~0 and revert for every non-trivial funding. Run here, the
        // ceiling is measured against the same float the proposal was priced
        // against.
        //
        // SUBTRACTING THE FUNDING IS WHAT STOPS THE ENVELOPE BEING SPENT TWICE.
        // `effectiveMaxCapital` is the vault's net-outflow meter for the batch;
        // without the subtraction a proposal could fund a sandbox to its full
        // envelope and then deploy that same envelope again through the batch.
        // The subtraction cannot underflow: `proposeWithSandbox` bounds funding
        // by `maxCapital`, and the scaling below is monotone in it.
        uint256 batchCapital = proposal.effectiveMaxCapital;
        uint256 sandboxFunding = _sandboxFunding[proposalId];
        if (sandboxFunding != 0) {
            // Scaled by the SAME raised-over-required ratio the effective
            // capital and the per-call caps already carry, expressed as
            // `effective/max` rather than re-reading the quorum figures: the two
            // are the same ratio by construction (`effective = max *
            // raised / required`), and taking it this way keeps the quorum reads
            // in one place. The extra floor can only round the funding DOWN,
            // which under-funds rather than over-funds — the safe direction.
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

        // Run the pre-committed settlement calls under the SAME effective capital
        // cap execution ran under — reused from storage, NEVER recomputed, so a
        // coverage drop between execute and settle cannot cap the unwind below
        // the size legitimately deployed at execution. An honest unwind is
        // net-INFLOW, so any finite cap passes it trivially; the cap only binds a
        // malicious proposer who parked extraction in `settlementCalls` to
        // self-settle and drain uncapped. The persisted per-call caps
        // additionally bound each settlement call's own gross outflow.
        ISyndicateVault(proposal.vault)
            .executeGovernorBatch(
                _loadCalls(_settlementCalls, proposalId),
                _loadCaps(_effectiveSettlementCallCaps, proposalId),
                proposal.effectiveMaxCapital
            );

        // THE SETTLE PRICE MAY NOT BE STAMPED AGAINST AN UNREALIZED UNWIND.
        // `_finishSettlement` calls `vault.onProposalSettled`, which freezes
        // `num = totalAssets() + 1` as the price EVERY queued deposit and redeem
        // for this proposal is later paid at — and settlement is
        // deliverable-maximum at the strategy layer, not all-or-revert
        // (`MorphoSupplyStrategy` and `ConcentratedLiquidityStrategy` both emit
        // `SettlementIncomplete` and continue). `MorphoSupplyStrategy` further
        // caps delivery at Morpho's own idle balance, which is exactly what a
        // fee-free `flashLoan` removes for one callback frame.
        //
        // So without this gate an unprivileged caller settles from inside a
        // flash-loan callback, the strategy delivers ~0, and the stamp becomes
        // `num == 1`: queued depositors mint against a near-zero price (traced:
        // 1e29 shares against a 1e18 supply) and queued redeemers burn for zero
        // assets, with `cancel` already closed by `AlreadySettled`.
        //
        // `maxDrawdownBps` is the envelope voters and guardians actually
        // approved, and until now it was validated at propose and never read
        // again. Enforcing it here is what makes it load-bearing.
        //
        // MEASURED AS AN ABSOLUTE DROP AGAINST THE CAPITAL THE ENVELOPE COVERS,
        // not as a percentage of the whole fund. `maxDrawdownBps` is declared —
        // and validated at propose, and documented on `InvalidDrawdown` — as a
        // share of COMMITTED capital, so the allowance is
        // `effectiveMaxCapital * bps` (the coverage-scaled figure `execute` and
        // the settlement batch above are both bounded by), never
        // `vaultBalance * bps`. Scaling off the vault balance would let a
        // proposal committing 10% of the fund lose ten times its own declared
        // envelope before this trips.
        //
        // Both sides are the vault's RAW asset balance, `_capitalSnapshots`'
        // own unit (the same measure `_finishSettlement` computes `pnl` in), so
        // the comparison reduces to `balanceBefore - balanceNow <= allowance`.
        // Any balance component that is constant across the window — the queue
        // reserve, an untouched fee escrow — therefore cancels exactly instead
        // of scaling the bar. The one component that is NOT constant is the fee
        // escrow, and `claimUnclaimedFees` is gated on the active proposal for
        // precisely that reason; see the note there.
        //
        // SCOPED TO THIS PATH ON PURPOSE. `unstick` and `finalizeEmergencySettle`
        // route through `_finishSettlementHook` and stay ungated: they are the
        // owner-multisig escape hatch for a genuine loss that exceeds the
        // envelope, and gating them would wedge exactly the position that most
        // needs to exit. A proposal that trips this gate is not stuck — it is
        // redirected to the path where a human looks at it.
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

        // SECOND, INDEPENDENT GATE — the settle PRICE (pashov finding #2).
        //
        // The capital floor above is identically true when a proposal declares
        // `maxDrawdownBps == 10_000`: `allowance` then equals `basis`, so
        // `basis > allowance` is false and the whole branch is SKIPPED. That is
        // defensible for the strategy's own P&L — voters may accept a total
        // loss — but the waiver reaches a party the envelope never spoke for.
        // `_finishSettlement` -> `onProposalSettled` freezes
        // `num = totalAssets() + 1` as the price EVERY queued deposit and redeem
        // is paid at, and a permissionless caller picks the block.
        //
        // Proven on a live Robinhood fork: settle from inside a `flashLoan` that
        // empties Morpho's idle balance so `_deliverableNow` returns 0, and the
        // stamp lands at `num == 1` — a queued 1 USDG deposit minted 99.99% of a
        // 20,000 USDG vault's supply.
        //
        // So the stamp gets its OWN bound, and the declared drawdown is CAPPED
        // on the way in. A proposal may still declare a total loss; the price it
        // may freeze is bounded regardless. A settlement under this floor is not
        // stuck — it is redirected to `finalizeEmergencySettle`, where an owner
        // bond and guardian review stand behind it.
        _requireSettlePriceAboveFloorHook(proposalId, proposal, false);

        _finishSettlement(proposalId, proposal);
    }

    /// @dev Shared by `settleProposal` and `unstick` (pashov findings #2, #12).
    ///      `unstick` replays the SAME stored batch under the SAME caps, so
    ///      leaving it ungated closed the front door and left the side door
    ///      open — the attack there needs no 100% declaration at all.
    ///
    ///      DELIBERATELY LOOSER THAN THE CAPITAL FLOOR. Capping the declared
    ///      drawdown at `MAX_STAMP_DRAWDOWN_BPS` leaves a 100% proposal a floor
    ///      of 10% of the execute-time price, so ordinary and even severe losses
    ///      still settle and `unstick` remains the escape hatch it was added to
    ///      be. Only a near-zero stamp — the shape a flash-loaned settle
    ///      manufactures, and the shape that mints unbounded shares to a queued
    ///      depositor — is refused.
    ///
    ///      `finalizeEmergencySettle` stays exempt, and the accurate statement
    ///      of what that costs is: AN ATTACKING VAULT OWNER MUST NOW WAIT OUT A
    ///      GUARDIAN REVIEW, not "the stamp is bounded on every path". The bond
    ///      is slashed only if guardians actively BLOCK (`finalizeEmergency` ->
    ///      `GuardianRegistry._resolveEmergency`), and guardians review the
    ///      submitted CALLDATA, not the block the owner later finalizes in — so
    ///      an owner may post a bond, submit the honest replay calls, let the
    ///      review lapse unblocked, and finalize from inside a flash-loan frame
    ///      with no slash. The exemption is still the right call: gating it
    ///      would leave a genuinely illiquid position with NO exit at all, and
    ///      the vault stays frozen meanwhile. What the exemption buys the
    ///      protocol is time and visibility, not arithmetic.
    ///
    ///      MEASURES A SLIGHTLY DIFFERENT NUMBER THAN THE ONE STAMPED. This
    ///      runs before `_finishSettlement`, which charges the management fee
    ///      and then the performance fee — both of which leave the vault (or
    ///      land in `_escrowedFees`, which `totalAssets()` also subtracts)
    ///      BEFORE `onProposalSettled` freezes `num = totalAssets() + 1`. So
    ///      the stamped price is strictly at or below the price approved here,
    ///      by the size of the fees. The gap is bounded and cannot be inflated
    ///      into a near-zero stamp: the management base is ~0 for the deployed
    ///      window and the performance leg is zero on a loss, which is the only
    ///      case where this floor binds at all. Checked pre-fee deliberately —
    ///      moving it after `_chargePerformanceFee` would make a fee charge
    ///      able to REVERT an otherwise-valid settlement, converting a fee
    ///      rounding edge into a stuck vault.
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

        // TWO BARS, because the two callers mean different things.
        //
        // `settleProposal` (rescuePath == false) is the ordinary, permissionless
        // exit, so it is held to the DECLARED envelope — capped, so a 100%
        // declaration cannot waive it to nothing.
        //
        // `unstick` (rescuePath == true) exists precisely to settle a proposal
        // the declared envelope refused. Holding it to that same envelope would
        // delete its purpose, so it gets only the absolute backstop: refuse a
        // near-zero stamp, allow everything above it. A genuine loss past the
        // backstop is not stuck either — it routes to `finalizeEmergencySettle`,
        // which carries an owner bond and a guardian review.
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
        // Forfeiture acknowledge: the governor still records a bond, but a
        // conviction already made `forfeitBond` delete the escrow's record for
        // this key. `amount == 0` here is exact — the only two record-deleting
        // exits are this reclaim's own release (which zeroes `proposerBondWood`
        // in the same transaction) and forfeiture. Handled before the window
        // gates: a forfeited bond has nothing left to wait out, and gate 3 could
        // otherwise revert for a bond that no longer exists.
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
            // Fails closed: fail-open would let the factory bypass this delay in
            // one transaction via `setExposureLedger(0)`. The freeze cannot
            // strand the bond permanently — rotating the pinned ledger's own
            // `coverageFreezer` makes it reclaimable again.
            if (ledger == address(0)) revert ExposureLedgerUnset();
            // `+ strategyDuration`. Risk does not end when the strategy executes;
            // it ends when its term is over AND the window on top of it has run
            // out. Anchoring at `executedAt + challengeWindow` alone released the
            // bond up to 30 days BEFORE `ChallengeGame.file` stops admitting —
            // and the proposer bond is precisely what a successful challenge is
            // paid out of. Read off `proposal` in the same load as `executedAt`,
            // matching how `file` pins it off its own snapshot.
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

        // Best-effort `settleCoverage` self-trigger: this is the backstop that IS
        // provably past `executeBy` for every executed proposal, so it collapses
        // the reservations an early settlement-time trigger had to skip.
        // Successful-release path only — never on the forfeiture-acknowledge
        // early return, whose conviction already reprices the cohort.
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
            // The Draft already incremented `_openProposalCount` at propose time —
            // do NOT re-increment here. Push the review window to the registry so
            // it can resolve the guardian review without calling back. Guarded on
            // `reviewEnd > voteEnd`: with `reviewPeriod == 0` the window collapses
            // and the registry would revert `InvalidReviewWindow`.
            // LOAD-BEARING: this predicate must stay identical to the one
            // `_afterVote` tests. A proposal that gets past it there without
            // having been registered here auto-approves with no guardian review.
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

    /// @dev Propose-time half of the maxCapital ceiling. Without it, a proposer
    ///      declares `maxCapital = uint256.max` and the net-outflow cap never
    ///      binds. Hoisted out of `propose` to stay under Yul's stack budget, and
    ///      reads the vault from storage for the same reason.
    ///
    ///      NOT sufficient on its own: this prices `maxCapital` against
    ///      `totalAssets()` at PROPOSE, and the vault's two capital locks read
    ///      different counters — deposits blocked from `openProposalCount() != 0`
    ///      (set here), redemptions only from `getActiveProposal() != 0` (set at
    ///      execute). A proposer can inflate `totalAssets()` with its own deposit
    ///      immediately before proposing, pass this gate, then withdraw during the
    ///      vote. `executeProposal` re-runs the same ratio against live totals
    ///      immediately before dispatch to close that window.
    function _checkMaxCapitalCeiling(uint256 maxCapital) private view {
        if (maxCapital > _capitalCeiling()) revert MaxCapitalExceedsCeiling();
    }

    /// @dev Propose-time half of the privileged-target fix: rejects any target in
    ///      EITHER call array that the vault's own privileged-batch-target
    ///      predicate flags (the vault itself, or its bound withdrawal queue) —
    ///      the SAME predicate `_guardBatchCalls` enforces at execute/settle time,
    ///      single-sourced on the vault so this cannot drift from it. Denylist
    ///      half ONLY: the registry-gated selector half depends on mutable, even
    ///      codehash-sensitive state and would prove nothing about settle time.
    ///
    ///      Consumed via staticcall as a capability probe: a failed or malformed
    ///      call (a vault that predates this view) degrades OPEN — propose must
    ///      never brick on a fail-early check. `executeGovernorBatch`'s guard
    ///      remains the authoritative enforcement on every batch path regardless.
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

    /// @dev Propose-time cap-array validation AND storage of BOTH the calls and
    ///      the caps, combined into ONE call. Combined deliberately: `propose`'s
    ///      Yul stack budget is at the edge, and folding `_storeCalls` in here
    ///      means all four array params are referenced only within this one early
    ///      call instead of staying live across the rest of `propose`'s body.
    ///      Checks, in order:
    ///        1. Each cap array's length equals its call array's length — every
    ///           call must declare exactly one cap.
    ///        2. `sum(executeCallCaps) <= maxCapital` AND
    ///           `sum(settlementCallCaps) <= maxCapital`, evaluated PER BATCH and
    ///           never combined — the two batches run in separate transactions,
    ///           each independently bounded by the vault's net-outflow meter, so
    ///           requiring the combined sum under `maxCapital` would halve every
    ///           proposal's settlement budget for no safety gain.
    ///      Overflow is a non-issue: `cap_i <= maxCapital <= totalAssets()` and
    ///      each array is bounded by `MAX_CALLS_PER_PROPOSAL`. A revert here still
    ///      rolls back the `_proposalCount` bump, so validating after storing
    ///      nothing yet is safe.
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

    /// @dev Resolves and stores the proposal's tier and required coverage, then
    ///      runs the propose-time gates: the maxCapital ceiling, the ledger's
    ///      covered-TVL cap, and the risk-scaled proposer bond (which PULLS WOOD
    ///      from the proposer — a state-changing external call, see the CEI note
    ///      at the `lockBond` site). Hoisted out of `propose` for Yul's stack
    ///      budget; reads `p.maxCapital`/`p.id` from storage rather than taking
    ///      them as arguments, since the call site must stay exactly
    ///      `(p, _loadCalls(...))`-shaped.
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
        // A SANDBOX IS PRICED AT FULL NOTIONAL AND IS ALWAYS TIER 2. Read from
        // storage, written by `proposeWithSandbox` before this call — see the
        // ordering note at that write.
        //
        // The funding is the payload's structural maximum loss, and unlike a
        // batch call there is no certified bound that could reduce it: the
        // targets are uncertified by design, which is the whole point of the
        // mechanism. So the charge is the entire funded amount, added to
        // whatever the batches already cost. Forcing tier 2 is not cosmetic —
        // `_deriveAndStoreEffectiveCapital` only demands the bond-encumbered
        // approve quorum at or above `quorumTierThreshold`, so a payload that
        // rode along at tier 0 would be arbitrary calldata reaching an
        // arbitrary target with no identified underwriter on the hook.
        uint256 sandboxFunding = _sandboxFunding[p.id];
        if (sandboxFunding != 0) {
            tier_ = 2;
            coverage_ += sandboxFunding;
        }
        p.envelopeTier = tier_;
        // ZERO COVERAGE IS SPECIFIED, NOT A HOLE — see design.md D2, pinned by
        // `PerCallCapitalDeclarations.test_allZeroCaps_pricesZeroCoverage_meterStillBlocksOutflow`
        // and `GovernorCoverageGates.test_execute_zeroRequiredCoverage_passesOptimistically`.
        // An all-zero-cap batch prices to zero coverage regardless of tier, and
        // the protection is the PER-CALL METER at execute time, not a coverage
        // floor: `cap_i == 0` makes `BatchExecutorLib` revert `CallCapExceeded`
        // on any outflow at all, which is strictly stronger than any coverage
        // requirement. A floor here would refuse the declaration that buys the
        // tightest possible spend limit.
        //
        // A guard was briefly added here on the reading that zero coverage also
        // switches off the approve quorum, the proposer bond and the challenge
        // freeze. It does — but the residual that argument is really about is
        // that `BatchExecutorLib` meters only vault-asset BALANCE, so a call
        // whose capability is an AUTHORIZATION rather than a transfer moves zero
        // and meters zero honestly. That is a metering-SCOPE question about what
        // the meter can see, and it belongs where the meter is defined; pricing
        // is the wrong lever for it and refusing at propose broke three
        // specified behaviours.
        p.requiredCoverage = coverage_;
        // Skipped when unwired — the pre-ledger safe default matches the
        // tierRegistry pattern.
        address ledger = _exposureLedger;
        if (ledger != address(0)) {
            address asset = IERC4626(GovernorParameters.vault).asset();
            IExposureLedger(ledger).requireWithinCoveredTvlCap(asset, coverage_);
            // Fails on the PROPOSER, not on the cohort: a duration whose
            // settlement outruns the ledger's booking horizon would leave every
            // approve vote unable to book, turning the review block-only.
            //
            // `p.executeBy` is still zero on the collaborative path, so compute
            // the worst-case deadline instead: a Draft may idle for
            // `collaborationWindow` before activating, then run voting, review
            // and execution.
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
                    // FAIL CLOSED ON A MISMATCHED PAIR, before any state write.
                    // `_bondEscrow` and `_exposureLedger` are independently
                    // factory-settable with no on-chain pairing guarantee, and
                    // ledger rotation routinely outpaces escrow rotation in
                    // ordinary operation. Locking a bond into an escrow whose own
                    // immutable `exposureLedger` differs from `ledger` would pin
                    // it against a ledger whose live game the escrow never
                    // recognises as the authorized convictor — `forfeitBond`
                    // would revert forever and a convicted proposer would keep
                    // the bond.
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

    /// @dev Proposal tier = max tier across EXECUTE and SETTLEMENT calls
    ///      (batch-wide: every consumer of the aggregate tier wants the
    ///      fail-closed max). Coverage is
    ///      the SUM of per-call contributions across BOTH execute and settlement
    ///      calls: `coverage = sum(cap_i * boundBps_i) / 10_000`, where
    ///      `boundBps_i` is the certified bound for tier-0/1 calls and 10_000
    ///      (full notional) for tier-2 or uncertified ones. Monotonic in every cap
    ///      and every bound — the property the regression guard and the
    ///      proportional scaling both lean on.
    ///
    ///      With no registry wired every proposal is tier 2 / full notional, so
    ///      the pre-registry safe default is not made cheaper by per-call caps.
    ///      `memory` params (not calldata) so this can be reused on
    ///      storage-loaded calls at execute time. `checkCeiling` gates the
    ///      per-call tier-2 ceiling — true at propose, false at execute, where
    ///      post-propose tier drift is the regression guards' job.
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
        // Tier is the MAX across BOTH legs, not execute alone (SHE-210). The
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

    /// @dev Derives, stores and emits the coverage-proportional effective capital
    ///      at execute, and scales the stored per-call caps by the same factor,
    ///      persisting the scaled settlement caps for `settleProposal` to reuse
    ///      verbatim. Hoisted out of `executeProposal` for Yul's stack budget. An
    ///      INTERNAL call, so the same-transaction invariant on the
    ///      `requireApproveQuorum` gate is unaffected by the function boundary.
    ///
    ///      `effectiveMaxCapital = maxCapital` when the gate does not run (no
    ///      ledger wired, zero `requiredCoverage`, or tier below the quorum
    ///      threshold) or when raised coverage is at or above required; otherwise
    ///      `floor(maxCapital * coverageRaisedUsd / requiredCoverageUsd)`, which
    ///      can floor to zero on dust coverage — a zero net-outflow cap,
    ///      fail-closed and accepted. `requireApproveQuorum` already reverts on a
    ///      raised aggregate of exactly zero, so the division never sees a zero
    ///      denominator on the scaling branch.
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

    /// @dev Scales each cap by `raised/required` (floor, matching `coverageUsd`'s
    ///      own discipline) and defensively re-asserts the scaled sum against
    ///      `bound`. Term-wise floors cannot mathematically exceed `bound` given
    ///      the propose-time invariant `sum(caps) <= maxCapital`, so the re-assert
    ///      is belt-and-braces: on a hypothetical violation the LARGEST scaled cap
    ///      absorbs the dust-sized excess deterministically. A cap that floors to
    ///      zero stays zero (fail-closed).
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

    /// @dev Finalize a settled proposal: compute P&L, distribute fees, clear
    ///      counters. Invoked by both happy-path `settleProposal` and the
    ///      emergency settle lifecycle.
    ///
    ///      PnL is measured purely against `IERC20(asset).balanceOf(vault)`. Any
    ///      non-asset balance the strategy still holds at settlement (mTokens, LP
    ///      NFTs, reward tokens, perp margin) counts as a LOSS of the
    ///      corresponding asset balance it started with. Strategies MUST fully
    ///      unwind non-asset positions before this runs; if one cannot, wait past
    ///      `strategyDuration` and drive the emergency-settle path.
    /// @dev  Best-effort `settleCoverage` self-trigger. Settlement is NOT reliably
    ///       past a proposal's `executeBy`, so `_settleCoverageBestEffort` guards
    ///       on it and skips silently otherwise — the `reclaimProposerBond`
    ///       trigger is the backstop that IS provably past it.
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

        // Two-number fee model. Ordering is load-bearing: management fee first (it
        // lowers assets and therefore price per share), then the high-water-mark
        // comparison, then performance. Reversing any pair would charge
        // performance on assets the management fee already took, or ratchet the
        // mark past value the fund never banked.
        //
        // The management fee is charged on EVERY settlement — profit, flat or
        // loss. It funds the parties doing continuous work in months when there is
        // no profit to share.
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

        // Release the locks LAST, after every external call above (CEI).
        // `_activeProposal` backs the vault's `redemptionsLocked()` and
        // `_openProposalCount` backs `depositsLocked()` — clearing either before
        // the fee transfers or the `onProposalSettled` stamp would open a window
        // where a callback-bearing fee recipient could deposit or redeem against a
        // NAV that is pre-fee and pre-stamp, shifting `totalSupply()` before the
        // settle price lands and diluting this proposal's queued redeemers.
        // `nonReentrant` does NOT cover this: it guards re-entry into this
        // governor, not calls into the vault or its withdrawal queue. Open
        // emergency reviews are NOT auto-cancelled here — they resolve naturally
        // at `reviewEnd`, so an owner who opened an adversarial emergency cannot
        // dodge slash by racing a settle.
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

        // LAST operation of finalization (design D1): a gas-starved child
        // here leaves no meaningful work unfunded behind it. Covers
        // `settleProposal`, `unstick`, and `finalizeEmergencySettle` in one
        // place (all three route through `_finishSettlement`).
        _settleCoverageBestEffort(proposalId, proposal);
    }

    /// @notice Best-effort self-trigger of the exposure ledger's
    ///         `settleCoverage(address(this), proposalId)` so cohort capacity
    ///         relief does not depend on an external keeper. Never reverts.
    /// @dev    Guard first: `settleCoverage` itself reverts `ReviewNotClosed`
    ///         unless `pv.executeBy != 0 && block.timestamp > pv.executeBy`,
    ///         mirrored here exactly including the `== 0` disjunct.
    ///         `proposal.executeBy` stays zero for a collaborative Draft that
    ///         never reaches Pending, and without that check the guard would not
    ///         skip — the ledger call would run only to revert on the same zero,
    ///         producing a spurious `CoverageSettleFailed` for a proposal that was
    ///         never capable of a real failure. Settlement is also not reliably
    ///         past `executeBy`, so an early call is a statically-knowable no-op:
    ///         skipping silently keeps `CoverageSettleFailed` meaning the call
    ///         reverted, not that it ran too early.
    /// @dev    Ledger resolution mirrors the reclaim gates' pinned-first rule: the
    ///         ledger pinned at bond-lock time, falling back to the live slot only
    ///         for a proposal that recorded none, skipping when both are zero.
    /// @dev    Bare catch, deliberately: everything reaching it is either
    ///         ledger-side (e.g. `NoWoodPrice` during a feed outage) or gas
    ///         starvation, and revert data cannot reliably distinguish them. No
    ///         gas floor: a gas-starved trigger degrades to the exact pre-change
    ///         status quo — over-reserved, the conservative direction — surfaced
    ///         by `CoverageSettleFailed` and permissionlessly repairable.
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

    /// @dev Snapshot every fee rate, recipient and split in force at propose time
    ///      so settlement pays what voters actually approved rather than a
    ///      post-vote governance change. Extracted from `propose` rather than
    ///      inlined: `propose` sits at the Yul stack-depth limit and the reads
    ///      below need more slots than remain.
    ///
    ///      The splits are deliberately NOT validated here. `ProtocolConfig` is
    ///      born valid and rejects an invalid write, so a zero-sum split is
    ///      unreachable for a real config; reverting would only ever fire against
    ///      a mock, and would turn a fee-accounting problem into a
    ///      settlement-liveness one. The charge functions skip a zero-sum split.
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
    ///      THE FEE MAP — two depositor-facing numbers, everyone else paid out of
    ///      internal splits. The two fees are independent and each is ONE division
    ///      of ONE base; no recipient's share is reduced by another's.
    ///
    ///        1. managementFee = assetSeconds * managementFeeBps / (10_000 * 365d)
    ///             base: fund assets integrated over the proposal's life, from the
    ///             vault's accrual accumulator
    ///             charged: on EVERY settlement — profit, flat, or loss
    ///             source: vault.managementFeeBps(), read LIVE and safely so —
    ///             written only at vault `initialize`, with no setter
    ///             split: prop.snapshotMgmtSplit -> agent / protocol / guardian
    ///
    ///        2. performanceFee = aboveHighWaterMark * perfFeeBps
    ///             base: value above the fund's previous PEAK price per share,
    ///             read AFTER the management fee, which lowers it
    ///             charged: only when the fund is above its mark
    ///             source: vault.agentFeeBps() (offset-by-one sentinel)
    ///             caps: vault-side `MAX_PERFORMANCE_FEE_BPS` at set, clamped
    ///             AGAIN here to the governor's live `maxPerformanceFeeBps`
    ///             snapshot: propose time -> prop.performanceFeeBps
    ///             split: prop.snapshotPerfSplit -> agent / protocol / guardian /
    ///             owner, then the high-water mark ratchets to the post-fee price
    ///
    ///      The agent's slice of BOTH fees flows through `_distributeAgentFee`, so
    ///      co-proposer splits apply to management as well as carry. Guardian
    ///      delivery is a WOOD airdrop via Merkl, attributed by the
    ///      `GuardianFeeAccrued` event. Any recipient transfer that reverts
    ///      escrows in `_unclaimedFees` so settlement never bricks.
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
    ///      divide it four ways in ONE split. Each recipient's share is computed
    ///      from the full fee, never from what another recipient left behind.
    ///
    ///      Must run AFTER the management fee: that fee lowers the vault's assets
    ///      and therefore its price per share, so reading the above-mark base
    ///      first would charge performance on assets already taken.
    /// @return agentFee The agent's slice, reported for the settle event.
    /// @return perfFee  The whole fee charged.
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

    /// @dev Distribute the agent fee to co-proposers (if any) and the lead
    ///      proposer. Extracted to avoid stack-too-deep.
    /// @dev Assumes a non-fee-on-transfer asset: `distributed += share` is booked
    ///      at the requested amount, not the received amount, so the lead's
    ///      rounding remainder is computed against the requested total. An FOT
    ///      asset would double-count the burn.
    /// @dev The split is agreed and validated at PROPOSE time, against each
    ///      co-proposer's THEN-live agent status, and settle honours that recorded
    ///      split rather than re-resolving against a possibly-mutated LIVE status.
    ///      A co-proposer removed after propose still does not get paid, but its
    ///      earned share is FORFEITED back to the vault rather than folded into
    ///      the lead's remainder: folding it in would let an owner who has seated
    ///      itself as lead strip co-proposers right before settle to redirect
    ///      their entitlement to itself. The lead's own share is therefore always
    ///      exactly its propose-time split, independent of which co-proposers are
    ///      still active at settle.
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
            // ESCROW ONLY WHAT THE VAULT CAN BACK. The catch cannot see WHY the
            // transfer failed, and the two reasons want opposite treatment. A
            // blacklisted recipient means the money IS here and the full amount
            // must be held for them. `AmountExceedsBalance` means the vault does
            // NOT have it — and escrowing the full amount then books a liability
            // that is unbacked by construction, with three compounding effects:
            // `_escrowedFees` feeds the vault's `_escrowedFeeLiability()`, which
            // `totalAssets()` subtracts, so an oversized escrow pins
            // `totalAssets()` to 0 — zeroing every LP's conversion AND stamping
            // the settle price at `num == 1` for this proposal's whole queued
            // flow, with `cancel` already closed by `AlreadySettled`; and
            // `claimUnclaimedFees` re-requests the SAME full amount, so it fails
            // the same comparison permanently, while `rescueERC20` refuses the
            // vault asset. Traced: a 1,000,000 USDC float at the 500bps cap over
            // 30d charges 4,109 USDC of management fee; if the strategy returns
            // 1,000 USDC the escrow books 3,288 against a real balance of 179.
            //
            // A fee is charged against assets under management and cannot exceed
            // them. Capping here forfeits the unbacked remainder — bounded, and
            // computed off a base that no longer exists — instead of minting a
            // permanent claim on money that was never there.
            //
            // RAW STATICCALL, DEGRADING TO THE FULL AMOUNT. Same doctrine as the
            // vault's own `_escrowedFeeLiability()`: a vault that cannot answer
            // reproduces exactly the pre-existing behaviour rather than getting a
            // stricter one invented for it, so this cannot regress an integration
            // that works today.
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
            // (pashov review finding #3). Both writes stay in lockstep: this
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
    /// @dev ZERO AND CODELESS BOTH REFUSED (pashov finding #1). This slot used
    ///      to accept zero on the premise that un-wiring "resolves everything at
    ///      tier 2 / full notional — the safe default". That is a PRICING
    ///      default; what a missing registry removes is a CAPABILITY gate:
    ///      `SyndicateVault._guardBatchCalls` resolves through this slot and,
    ///      finding none, RETURNS — dropping the callee allowlist, the
    ///      spender/recipient gate and the `UnrecognizedAssetSelector` branch,
    ///      after which `asset.approve(attacker, max)` moves zero balance past
    ///      every meter and licenses an unbounded pull later. A codeless address
    ///      instead reverts the guard's typed call and bricks the vault. Only
    ///      removal is refused — re-pointing to a different registry is legal.
    ///
    ///      The factory's own `setTierRegistry` still accepts zero: there it is
    ///      a kill switch on NEW syndicates and cannot reach an existing
    ///      governor. A pre-fix governor that IS registry-less is recovered with
    ///      `SyndicateFactory.pushWiring(governor)`.
    ///
    ///      This is a RE-POINT, not the wiring point: `initialize` now takes the
    ///      registry, so every governor this factory deploys is born wired.
    ///
    ///      Now-unreachable consequence, kept as rationale: zeroing this would
    ///      dead-end `PortfolioStrategy._initialize`'s
    ///      `vault() → governor() → tierRegistry()` walk, reverting
    ///      `TierRegistryUnresolved` for every new clone while existing clones
    ///      kept running — rebalance/settle degrade open by design so an
    ///      un-wiring can never strand capital in a live strategy.
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
