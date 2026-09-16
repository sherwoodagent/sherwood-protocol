// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "../../../src/interfaces/IGuardianRegistry.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";

/// @notice Handles the interaction with SyndicateGovernor
///
/// @dev `propose` is deliberately NOT exposed with its raw 10-argument ABI
///      shape. Two of those arguments are struct arrays and one is a risk
///      envelope whose `maxCapital` must land under a ceiling derived from
///      live vault TVL — a fuzzer handed raw calldata would revert at the
///      first guard essentially every time and the proposal lifecycle would
///      never open. Instead the handler builds a well-formed proposal from
///      current state and fuzzes only the fields that carry signal
///      (duration, envelope size, co-proposer presence).
///
///      The whole lifecycle — propose → vote → review → execute → settle →
///      reclaim — has to be reachable for the coverage and adjudication
///      invariants downstream to mean anything, since a challenge can only be
///      filed against an EXECUTED proposal.
abstract contract SyndicateGovernorHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev `propose` rejects an empty execute batch (`EmptyExecuteCalls`), so
    ///      every proposal carries one fund-neutral call to the certified,
    ///      allowlisted `FizzAdapter`.
    /// @dev `cap` is the per-call capital DECLARATION, and it is what prices the
    ///      proposal's coverage: `requiredCoverage` is derived from the caps and
    ///      the target's `extractableBoundBps`, NOT from `envelope.maxCapital`.
    ///
    ///      A zero cap therefore prices the proposal to zero coverage, and the
    ///      governor treats that as "can extract nothing, needs no covering
    ///      signer" (`SyndicateGovernor.sol:1494`) — so no guardian approval
    ///      ever books, `ExposureLedger` records nothing, and
    ///      `ChallengeGame.file` reverts `NothingToFreeze` because there is no
    ///      coverage to freeze. That is a legitimate protocol path, but it was
    ///      the ONLY path this harness proposed, which is why the whole
    ///      adjudication chain sat unreachable behind it.
    ///
    ///      `FizzAdapter.poke` is fund-neutral, so a non-zero cap is a
    ///      declaration the call never uses; the per-call meter enforces the
    ///      declaration is not exceeded, and under-spending it is fine.
    function _benignBatch(uint256 cap)
        internal
        view
        returns (BatchExecutorLib.Call[] memory calls, uint256[] memory caps)
    {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(adapter), data: abi.encodeCall(FizzAdapter.poke, ()), value: 0});
        caps = new uint256[](1);
        caps[0] = cap;
    }

    /// @dev Largest asset-denominated capital the guardian cohort can back,
    ///      derived from live bonds rather than hardcoded: sum each guardian's
    ///      slashable bond (scaled by `kNumerator`, the ledger's leverage on
    ///      bond-to-coverage), then convert that USD figure back into asset
    ///      units through the ledger's own `coverageUsd` so the asset's decimals
    ///      and feed price are respected. Conservative: `requiredCoverage` is at
    ///      most the declared capital, so staying under this keeps the cohort
    ///      able to cover it.
    function _coverableCapital() internal view returns (uint256) {
        uint256 capacityUsd;
        for (uint256 i; i < APPROVER_COUNT; i++) {
            capacityUsd += ledger.slashableBondUsd(actors[i]);
        }
        capacityUsd *= ledger.kNumerator();
        if (capacityUsd == 0) return 0;

        // USD18 produced by one whole asset unit, used as the inverse rate.
        uint256 unit = 10 ** ASSET_DECIMALS;
        uint256 usdPerUnit = ledger.coverageUsd(address(asset), unit);
        if (usdPerUnit == 0) return 0;
        return (capacityUsd * unit) / usdPerUnit;
    }

    /// @dev Only registered agents may propose. Coverage cycle 1 showed the
    ///      governor stuck at 12.4% because the rotating actor was an agent
    ///      barely a third of the time and every other attempt died on identity
    ///      before reaching a single lifecycle guard.
    function _toAgent(uint256 seed) internal view returns (address) {
        return actors[GUARDIAN_COUNT + (seed % 2)];
    }

    /// @dev Strategy is `address(0)` — the governor accepts an unset strategy
    ///      label, which keeps this independent of the (out-of-scope) strategy
    ///      clones. The batch itself is the benign certified adapter call.
    function syndicateGovernor_propose_clamped(uint256 strategyDuration, uint256 capitalSeed) public {
        actor = _toAgent(capitalSeed);
        // Hoisted: a call in argument position would consume a pending
        // one-shot cheatcode before the propose itself.
        uint256 ceiling = vault.totalAssets();
        if (ceiling == 0) return;

        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();
        uint256 duration = clampBetween(strategyDuration, p.minStrategyDuration, p.maxStrategyDuration);

        ISyndicateGovernor.RiskEnvelope memory env = ISyndicateGovernor.RiskEnvelope({
            maxCapital: clampBetween(capitalSeed, 1, ceiling), maxDrawdownBps: 10_000
        });

        // Cap = the full envelope, so the proposal prices to real coverage.
        (BatchExecutorLib.Call[] memory ecalls, uint256[] memory ecaps) = _benignBatch(env.maxCapital);
        syndicateGovernor_propose(
            address(vault),
            address(0),
            "fizz",
            duration,
            env,
            ecalls,
            ecaps,
            ecalls,
            ecaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev Collaborative variant: opens in `Draft` and needs
    ///      `approveCollaboration` from every co-proposer to reach `Pending`.
    ///      The lead must retain >= 10% (G-11), so the split is clamped to 9000.
    function syndicateGovernor_propose_collaborative(uint256 strategyDuration, uint256 splitBps, uint256 agentSeed)
        public
    {
        actor = _toAgent(agentSeed);
        uint256 ceiling = vault.totalAssets();
        if (ceiling == 0) return;

        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();
        ISyndicateGovernor.CoProposer[] memory co = new ISyndicateGovernor.CoProposer[](1);
        co[0] = ISyndicateGovernor.CoProposer({
            agent: actors[GUARDIAN_COUNT + (agentSeed % 2)], splitBps: clampBetween(splitBps, 1, 9_000)
        });

        (BatchExecutorLib.Call[] memory ecalls, uint256[] memory ecaps) = _benignBatch(ceiling);
        syndicateGovernor_propose(
            address(vault),
            address(0),
            "fizz-collab",
            clampBetween(strategyDuration, p.minStrategyDuration, p.maxStrategyDuration),
            ISyndicateGovernor.RiskEnvelope({maxCapital: ceiling, maxDrawdownBps: 10_000}),
            ecalls,
            ecaps,
            ecalls,
            ecaps,
            co
        );
    }

    /// @dev Composite: drives one proposal from nothing to `Executed` in a
    ///      single fuzzer call.
    ///
    ///      Coverage cycle 1 showed every contract gated behind an executed
    ///      proposal flatlining — ChallengeGame 20.3%, ExposureLedger 19.3%,
    ///      ProposerBondEscrow 8.5%, VaultWithdrawalQueue 14.0% — because
    ///      reaching `Executed` needs propose → votingPeriod → openReview →
    ///      reviewPeriod → resolveReview → execute in that order, and random
    ///      call ordering essentially never assembles it. A challenge can only
    ///      be filed against an EXECUTED proposal, so without this the entire
    ///      adjudication subsystem is unreachable.
    ///
    ///      Individual steps remain exposed separately, so the fuzzer can still
    ///      interleave them adversarially and hit the partial-progress states
    ///      this composite skips over.
    function syndicateGovernor_lifecycle_toExecuted(uint256 strategyDuration, uint256 capitalSeed, uint256 guardianSeed)
        public
    {
        if (governor.openProposalCount() != 0 || governor.getActiveProposal() != 0) return;

        uint256 ceiling = vault.totalAssets();
        if (ceiling == 0) return;

        // Cap the envelope at what the guardian cohort's bonds can actually
        // cover. Sizing purely off vault TVL prices `requiredCoverage` above
        // the whole cohort's slashable stake, and execute dies on
        // `InsufficientApproveCoverage` — an executed proposal is the gate for
        // everything downstream, so it is worth staying under it.
        uint256 coverable = _coverableCapital();
        if (coverable == 0) return;
        if (coverable < ceiling) ceiling = coverable;

        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();
        uint256 duration = clampBetween(strategyDuration, p.minStrategyDuration, p.maxStrategyDuration);

        actor = _toAgent(capitalSeed);
        // Hoisted so the declared cap and the envelope cannot drift apart:
        // `sum(caps) <= maxCapital` is a propose-time guard.
        // Floored at half the ceiling, NOT at 1. `clampBetween` wraps by
        // modulo, so a seed that happens to be an exact multiple of the range
        // lands on the low bound — a capital of 1 prices `requiredCoverage` to
        // effectively zero, no guardian books anything, and this composite
        // silently degrades into the zero-coverage path it exists to avoid.
        // Small-capital proposals stay reachable through the plain propose
        // handlers; this one is specifically the material-coverage path.
        uint256 capital = clampBetween(capitalSeed, (ceiling / 2) + 1, ceiling);
        (BatchExecutorLib.Call[] memory ecalls, uint256[] memory ecaps) = _benignBatch(capital);
        syndicateGovernor_propose(
            address(vault),
            address(0),
            "fizz-lifecycle",
            duration,
            ISyndicateGovernor.RiskEnvelope({maxCapital: capital, maxDrawdownBps: 10_000}),
            ecalls,
            ecaps,
            ecalls,
            ecaps,
            new ISyndicateGovernor.CoProposer[](0)
        );

        uint256 pid = governor.proposalCount();

        // Snapshot timestamps are taken at propose time; step past them before
        // any ballot is cast.
        skipTime(1);

        // ORDER IS LOAD-BEARING: guardian review opens only AFTER `voteEnd`,
        // so an approve vote cast here — before `openReview` — reverts
        // `ReviewNotOpen`. This originally voted first, the revert was
        // swallowed by the try/catch, and the result was that NO proposal this
        // harness ever executed carried booked coverage. `requiredCoverage`
        // stayed unbacked, `approversOf` came back empty, and
        // `ChallengeGame.file` reverted `NothingToFreeze` on every attempt —
        // which is why ExposureLedger, ChallengeGame, TokenCourt and
        // ProposerBondEscrow all flatlined around 30%.
        skipTime(p.votingPeriod + 1);
        try registry.openReview(address(governor), pid) {} catch {}

        // Approve with every guardian EXCEPT the reserved court voter. A single
        // bond rarely covers `requiredCoverage` (`requireApproveQuorum` reverts
        // `InsufficientApproveCoverage` when the cohort raises nothing), but
        // approving with ALL of them makes every guardian `isAccused` and
        // therefore barred from the TokenCourt vote — which leaves a filed
        // challenge stranded in `Disputed`, unable to reach a verdict. The
        // cohort has to be split: approvers back the proposal, the reserve
        // adjudicates it.
        // Called directly rather than through GuardianRegistryHandler — the two
        // handlers are sibling branches off `Properties`, so neither sees the
        // other's functions.
        for (uint256 i; i < APPROVER_COUNT; i++) {
            vm.prank(actors[i]);
            try registry.voteOnProposal(
                address(governor), pid, IGuardianRegistry.GuardianVoteType.Approve, type(uint256).max
            ) {}
                catch {}
        }

        skipTime(registry.reviewPeriod() + 1);
        try registry.resolveReview(address(governor), pid) {} catch {}

        syndicateGovernor_executeProposal(pid);
    }

    /// @dev Composite: carry the live proposal past its duration and settle it.
    ///      Settlement is what stamps the queue's single frozen price
    ///      (I-16) — without it `VaultWithdrawalQueue.claim` is unreachable and
    ///      every queued request sits pending forever, which is why cycle 1 left
    ///      the queue at 14%.
    function syndicateGovernor_lifecycle_toSettled() public {
        uint256 pid = governor.getActiveProposal();
        if (pid == 0) return;

        ISyndicateGovernor.StrategyProposal memory sp = governor.getProposal(pid);
        if (sp.executedAt == 0) return;

        // `executedAt` is contract-stored, which is the safe anchor to compute
        // from. Both `block.timestamp` reads below happen BEFORE the warp, so
        // the optimizer's CSE-across-`vm.warp` hazard (caching a timestamp and
        // reusing it AFTER a warp) does not apply here.
        uint256 settleAt = sp.executedAt + sp.strategyDuration + 1;
        if (block.timestamp < settleAt) skipTime(settleAt - block.timestamp);

        syndicateGovernor_settleProposal(pid);
    }

    function syndicateGovernor_vote_clamped(uint256 proposalId, uint8 support) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_vote(clampBetween(proposalId, 1, count), uint8(support % 3));
    }

    function syndicateGovernor_executeProposal_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_executeProposal(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_settleProposal_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_settleProposal(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_reclaimProposerBond_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_reclaimProposerBond(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_cancelProposal_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_cancelProposal(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_vetoProposal_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_vetoProposal(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_approveCollaboration_clamped(uint256 proposalId, uint256 agentSeed) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        actor = actors[GUARDIAN_COUNT + (agentSeed % 2)];
        syndicateGovernor_approveCollaboration(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_rejectCollaboration_clamped(uint256 proposalId) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        syndicateGovernor_rejectCollaboration(clampBetween(proposalId, 1, count));
    }

    function syndicateGovernor_secondary(uint8 selector, uint256 arg0, address arg1) public {
        uint256 count = governor.proposalCount();
        uint256 proposalId = count == 0 ? 0 : clampBetween(arg0, 1, count);

        selector = uint8(selector % 14);
        if (selector == 0) {
            if (count == 0) return;
            _syndicateGovernor_cancelEmergencySettle(proposalId);
        } else if (selector == 1) {
            _syndicateGovernor_claimUnclaimedFees(address(vault), toActor(arg1));
        } else if (selector == 2) {
            if (count == 0) return;
            _syndicateGovernor_emergencyCancel(proposalId);
        } else if (selector == 3) {
            if (count == 0) return;
            // Empty call batch: the emergency path's own guards are the target,
            // not arbitrary calldata.
            _syndicateGovernor_emergencySettleWithCalls(proposalId, new BatchExecutorLib.Call[](0));
        } else if (selector == 4) {
            if (count == 0) return;
            _syndicateGovernor_finalizeEmergencySettle(proposalId);
        } else if (selector == 5) {
            if (count == 0) return;
            _syndicateGovernor_resolveProposalState(proposalId);
        } else if (selector == 6) {
            _syndicateGovernor_setCooldownPeriod(clampBetween(arg0, 1 hours, 30 days));
        } else if (selector == 7) {
            _syndicateGovernor_setExecutionWindow(clampBetween(arg0, 1 hours, 7 days));
        } else if (selector == 8) {
            _syndicateGovernor_setMaxCapitalBps(clampBetween(arg0, 1, 10_000));
        } else if (selector == 9) {
            _syndicateGovernor_setMaxPerformanceFeeBps(clampBetween(arg0, 0, 3_000));
        } else if (selector == 10) {
            _syndicateGovernor_setTier2CallCapBps(clampBetween(arg0, 1, 10_000));
        } else if (selector == 11) {
            _syndicateGovernor_setVetoThresholdBps(clampBetween(arg0, 1, 10_000));
        } else if (selector == 12) {
            _syndicateGovernor_setVotingPeriod(clampBetween(arg0, 1 hours, 30 days));
        } else {
            if (count == 0) return;
            _syndicateGovernor_unstick(proposalId);
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function syndicateGovernor_propose(
        address vault_,
        address strategy,
        string memory metadataURI,
        uint256 strategyDuration,
        ISyndicateGovernor.RiskEnvelope memory envelope,
        BatchExecutorLib.Call[] memory executeCalls,
        uint256[] memory executeCallCaps,
        BatchExecutorLib.Call[] memory settlementCalls,
        uint256[] memory settlementCallCaps,
        ISyndicateGovernor.CoProposer[] memory coProposers
    ) public asActor {
        governor.propose(
            vault_,
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

    function syndicateGovernor_vote(uint256 proposalId, uint8 support) public asActor {
        governor.vote(proposalId, ISyndicateGovernor.VoteType(support));
    }

    function syndicateGovernor_executeProposal(uint256 proposalId) public asActor {
        governor.executeProposal(proposalId);
    }

    function syndicateGovernor_settleProposal(uint256 proposalId) public asActor {
        governor.settleProposal(proposalId);
    }

    function syndicateGovernor_reclaimProposerBond(uint256 proposalId) public asActor {
        governor.reclaimProposerBond(proposalId);
    }

    function syndicateGovernor_cancelProposal(uint256 proposalId) public asActor {
        governor.cancelProposal(proposalId);
    }

    function syndicateGovernor_approveCollaboration(uint256 proposalId) public asActor {
        governor.approveCollaboration(proposalId);
    }

    function syndicateGovernor_rejectCollaboration(uint256 proposalId) public asActor {
        governor.rejectCollaboration(proposalId);
    }

    /// @dev Vault-owner-gated, and this harness owns the vault.
    function syndicateGovernor_vetoProposal(uint256 proposalId) public asAdmin {
        governor.vetoProposal(proposalId);
    }

    // ── Secondary ──

    function _syndicateGovernor_cancelEmergencySettle(uint256 proposalId) internal asAdmin {
        governor.cancelEmergencySettle(proposalId);
    }

    /// @dev Permissionless: the escrow key is `msg.sender`-scoped.
    function _syndicateGovernor_claimUnclaimedFees(address vault_, address token) internal asActor {
        governor.claimUnclaimedFees(vault_, token);
    }

    function _syndicateGovernor_emergencyCancel(uint256 proposalId) internal asAdmin {
        governor.emergencyCancel(proposalId);
    }

    function _syndicateGovernor_emergencySettleWithCalls(uint256 proposalId, BatchExecutorLib.Call[] memory calls)
        internal
        asAdmin
    {
        governor.emergencySettleWithCalls(proposalId, calls);
    }

    function _syndicateGovernor_finalizeEmergencySettle(uint256 proposalId) internal asAdmin {
        governor.finalizeEmergencySettle(proposalId);
    }

    /// @dev Permissionless lazy state commit.
    function _syndicateGovernor_resolveProposalState(uint256 proposalId) internal asActor {
        governor.resolveProposalState(proposalId);
    }

    function _syndicateGovernor_unstick(uint256 proposalId) internal asAdmin {
        governor.unstick(proposalId);
    }

    // ── Secondary: vault-owner-gated params (frozen while a proposal is open) ──

    function _syndicateGovernor_setCooldownPeriod(uint256 newValue) internal asAdmin {
        governor.setCooldownPeriod(newValue);
    }

    function _syndicateGovernor_setExecutionWindow(uint256 newValue) internal asAdmin {
        governor.setExecutionWindow(newValue);
    }

    function _syndicateGovernor_setMaxCapitalBps(uint256 newValue) internal asAdmin {
        governor.setMaxCapitalBps(newValue);
    }

    function _syndicateGovernor_setMaxPerformanceFeeBps(uint256 newValue) internal asAdmin {
        governor.setMaxPerformanceFeeBps(newValue);
    }

    function _syndicateGovernor_setTier2CallCapBps(uint256 newValue) internal asAdmin {
        governor.setTier2CallCapBps(newValue);
    }

    function _syndicateGovernor_setVetoThresholdBps(uint256 newValue) internal asAdmin {
        governor.setVetoThresholdBps(newValue);
    }

    function _syndicateGovernor_setVotingPeriod(uint256 newValue) internal asAdmin {
        governor.setVotingPeriod(newValue);
    }
}
