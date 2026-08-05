// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SyndicateGovernorTest} from "../SyndicateGovernor.t.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title SyndicateGovernor — zero-priced execute batch
/// @notice `requiredCoverage` is the sum of `cap_i * extractableBoundBps_i /
///         10_000`, and zero is not an inert value — it is the point at which
///         three independent controls switch themselves off simultaneously:
///
///           1. `_deriveAndStoreEffectiveCapital`'s `gated` requires
///              `requiredCoverage != 0`, so the approve quorum never runs and
///              `effectiveMaxCapital` stays at the full declared `maxCapital`.
///           2. `proposerBondWood(asset, 0)` returns 0 at its `usd == 0`
///              short-circuit, BEFORE it reads a price — so no bond is locked.
///           3. `ExposureLedger.recordApproval` returns early on
///              `needUsd == 0`, leaving `_approversOf` empty, so
///              `ChallengeGame.file` reverts `NothingToFreeze` and the proposal
///              is unchallengeable for its whole life.
///
///         The declaration is not a lie — `BatchExecutorLib` meters
///         `balanceBefore - balanceAfter` of the vault asset, and a call whose
///         effect is an AUTHORIZATION rather than a transfer genuinely moves
///         zero balance in-batch. The metric is what cannot see it.
/// @dev Reports every target as tier 2 at the maximum extractable bound —
///      exactly what the real `TierRegistry.tierOf` returns for an UNCERTIFIED
///      target, which is the conservative default. Coverage is therefore
///      `cap_i * 10_000 / 10_000 == cap_i`, so a zero cap prices at zero: the
///      declaration under test, with no help from an exotic bound.
contract StubMaxBoundTierRegistry {
    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }
}

contract PashovFinalUnpricedCapabilityTest is SyndicateGovernorTest {
    /// @dev A WIRED REGISTRY IS THE PRECONDITION. With `_tierRegistry` unset,
    ///      `_resolveTierAndCoverage` short-circuits to `(2, maxCapital)` — the
    ///      pre-registry safe default — so coverage is never zero and the floor
    ///      is unreachable. The base fixture leaves it unset; production wires
    ///      it, so that is the configuration this finding lives in. The test
    ///      contract is the governor's own factory, which is what authorises
    ///      `setTierRegistry`.
    function _wireTierRegistry() internal {
        governor.setTierRegistry(address(new StubMaxBoundTierRegistry()));
    }

    /// @notice A batch carrying execute calls whose caps are all zero is refused
    ///         at propose, where the invariant is cheap to state, rather than
    ///         patched at each of the three consumers downstream.
    function test_propose_rejectsAZeroPricedExecuteBatch() public {
        _wireTierRegistry();
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory execCalls = _simpleExecuteCalls();
        uint256[] memory zeroCaps = new uint256[](execCalls.length);
        // BOTH ARRAYS ZEROED. `_resolveTierAndCoverage` sums over execute AND
        // settlement calls, so pricing either side above zero keeps
        // `requiredCoverage` non-zero and the three controls switched ON — which
        // is the correct outcome, not the bug. The defect only exists when the
        // WHOLE declaration prices at zero, so that is what this must build.
        BatchExecutorLib.Call[] memory settleCalls = _simpleSettlementCalls();
        uint256[] memory settleCaps = new uint256[](settleCalls.length);
        // Every argument hoisted above the cheatcodes: a call in ARGUMENT
        // position evaluates first and would consume the pending one-shot
        // `prank`/`expectRevert`, so the propose would run unpranked.
        ISyndicateGovernor.CoProposer[] memory noCoProposers = _emptyCoProposers();

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.UnpricedCapability.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://zero-cap",
            7 days,
            permissiveEnv,
            execCalls,
            zeroCaps,
            settleCalls,
            settleCaps,
            noCoProposers
        );
    }

    /// @notice The ordinary path is untouched: a batch with real caps prices
    ///         above zero and proposes normally. Without this the test above
    ///         could pass against a governor that rejected every proposal.
    function test_propose_normallyPricedBatchStillSucceeds() public {
        _wireTierRegistry();
        uint256 pid = _createSimpleProposal(1_000, 7 days);
        assertGt(governor.getRequiredCoverage(pid), 0, "a normally-capped batch must price above zero");
    }

    /// @notice WITH NO REGISTRY WIRED THE FLOOR IS UNREACHABLE, by design.
    ///         `_resolveTierAndCoverage` short-circuits to `(2, maxCapital)`
    ///         before it ever reads a cap, so an all-zero declaration still
    ///         prices at the full envelope and the guard cannot fire.
    ///
    ///         Pinned because it is the precondition the finding depends on, and
    ///         because it is the reason a zero-cap proposal is NOT a hole in the
    ///         pre-registry configuration — the safe default already assumes the
    ///         worst rather than trusting the declaration.
    function test_propose_zeroCapsPriceAtMaxCapitalWhenRegistryUnwired() public {
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory execCalls = _simpleExecuteCalls();
        uint256[] memory zeroCaps = new uint256[](execCalls.length);
        BatchExecutorLib.Call[] memory settleCalls = _simpleSettlementCalls();
        uint256[] memory zeroSettleCaps = new uint256[](settleCalls.length);
        ISyndicateGovernor.CoProposer[] memory noCoProposers = _emptyCoProposers();

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://no-registry",
            7 days,
            permissiveEnv,
            execCalls,
            zeroCaps,
            settleCalls,
            zeroSettleCaps,
            noCoProposers
        );
        assertEq(
            governor.getRequiredCoverage(pid),
            permissiveEnv.maxCapital,
            "unwired registry prices the whole envelope, never zero"
        );
    }

    /// @notice The `execCalls.length != 0` half of the guard is defence in
    ///         depth, not a reachable branch: `propose` already refuses an empty
    ///         execute array outright with `EmptyExecuteCalls`, so there is no
    ///         legal execute-less shape for the coverage floor to mis-classify.
    ///
    ///         Pinned because it documents WHY the length test is there — if
    ///         that earlier guard were ever relaxed, an execute-less proposal
    ///         would legitimately price at zero and must not be caught by
    ///         `UnpricedCapability`, which is a statement about unpriced
    ///         CAPABILITY rather than about zero coverage as such.
    function test_propose_emptyExecuteBatchIsRejectedEarlier() public {
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory noCalls = new BatchExecutorLib.Call[](0);
        uint256[] memory noCaps = new uint256[](0);
        BatchExecutorLib.Call[] memory settleCalls = _simpleSettlementCalls();
        uint256[] memory settleCaps = GovEnvelope.defaultCaps(permissiveEnv.maxCapital, settleCalls.length);
        ISyndicateGovernor.CoProposer[] memory noCoProposers = _emptyCoProposers();

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.EmptyExecuteCalls.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://no-exec",
            7 days,
            permissiveEnv,
            noCalls,
            noCaps,
            settleCalls,
            settleCaps,
            noCoProposers
        );
    }

    /// @notice A SINGLE non-zero cap is enough to price the batch — the guard is
    ///         a floor at zero, not a demand that every call be capped. Pins the
    ///         boundary so a later tightening to "every cap non-zero" has to be
    ///         a deliberate change rather than a drift.
    function test_propose_oneNonZeroCapIsEnoughToPrice() public {
        _wireTierRegistry();
        permissiveEnv = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory execCalls = _simpleExecuteCalls();
        uint256[] memory caps = new uint256[](execCalls.length);
        caps[0] = permissiveEnv.maxCapital;
        // Settlement side zeroed, so the ONLY thing lifting this proposal over
        // the floor is that single execute cap — otherwise the test would pass
        // on the settlement caps alone and prove nothing about the boundary.
        BatchExecutorLib.Call[] memory settleCalls = _simpleSettlementCalls();
        uint256[] memory settleCaps = new uint256[](settleCalls.length);
        ISyndicateGovernor.CoProposer[] memory noCoProposers = _emptyCoProposers();

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://one-cap",
            7 days,
            permissiveEnv,
            execCalls,
            caps,
            settleCalls,
            settleCaps,
            noCoProposers
        );
        assertGt(governor.getRequiredCoverage(pid), 0, "one priced call carries the whole batch over the floor");
    }
}
