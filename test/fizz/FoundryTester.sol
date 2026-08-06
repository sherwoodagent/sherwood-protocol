// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Handlers} from "./handlers/Handlers.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

/// @notice Contract to be used for quick testing with Foundry
contract FoundryTester is Test, Handlers {
    using stdStorage for StdStorage;

    modifier asActor() override {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    function setUp() public {
        setup();
    }

    // forge test --match-test test_sequence -vvv
    function test_sequence() public {
        // Add here call sequence to Handler's functions to reproduce failing property
    }

    /// @notice Debug probe for the lifecycle composite: cycle 2 showed the
    ///         handler registered but contributed zero new coverage, meaning
    ///         every invocation reverted. This walks it step by step.
    function test_lifecycleProbe() public {
        console.log("proposalCount before ", governor.proposalCount());
        console.log("openProposalCount    ", governor.openProposalCount());
        console.log("activeProposal       ", governor.getActiveProposal());
        console.log("vault totalAssets    ", vault.totalAssets());
        console.log("agent isAgent[3]     ", vault.isAgent(actors[3]) ? 1 : 0);

        syndicateGovernor_lifecycle_toExecuted(1 days, 1000e6, 0);

        uint256 pid = governor.proposalCount();
        console.log("proposalCount after  ", pid);
        if (pid > 0) {
            console.log("state                ", uint256(governor.getProposalState(pid)));
            console.log("activeProposal after ", governor.getActiveProposal());
        }
    }

    /// @notice Triage for the GL-16 campaign violation.
    /// @dev Hypothesis: `stateOf` is a TRUE VIEW that reports Expired as soon
    ///      as it is determinable, while `_openProposalCount` only decrements
    ///      when `_commitState` actually commits the transition. If so the
    ///      property is wrong (it compares a lazily-committed counter against
    ///      an eagerly-computed view), not the protocol.
    function test_triage_GL16() public {
        syndicateGovernor_propose_clamped(1 days, 1000e6);
        uint256 pid = governor.proposalCount();
        require(pid != 0, "no proposal created");

        console.log("state after propose ", uint256(governor.stateOf(pid)));
        console.log("openProposalCount   ", governor.openProposalCount());

        // Run past every deadline so the proposal is determinably terminal.
        skipTime(60 days);

        uint256 s = uint256(governor.stateOf(pid));
        uint256 open = governor.openProposalCount();
        console.log("state after 60d     ", s);
        console.log("openProposalCount   ", open);
        console.log("=> lazy-commit gap  ", (s == 6 || s == 5) && open > 0 ? 1 : 0);
    }

    /// @notice Triage for the GL-09 campaign violation.
    /// @dev Hypothesis: the UNCLAMPED handlers take a raw `receiver`/`to`
    ///      address, so the fuzzer can mint or transfer shares to an address
    ///      outside the `actors` set — which the property's sum never counts.
    ///      If so the property is under-specified, not the vault.
    function test_triage_GL09() public {
        address outsider = address(0xBEEF);
        uint256 supplyBefore = vault.totalSupply();

        // Exactly what the unclamped fuzz entry point permits.
        syndicateVault_deposit(1_000e6, outsider);

        console.log("outsider shares     ", vault.balanceOf(outsider));
        console.log("supply delta        ", vault.totalSupply() - supplyBefore);

        uint256 counted = vault.balanceOf(address(queue));
        for (uint256 i; i < actors.length; i++) {
            counted += vault.balanceOf(actors[i]);
        }
        console.log("property sum        ", counted);
        console.log("totalSupply         ", vault.totalSupply());
        console.log("=> uncounted shares ", vault.totalSupply() - counted);
    }

    /// @notice Setup sanity: proves `Base.setup()` produced a live, wired,
    ///         non-empty stack. A silently-empty harness fuzzes nothing while
    ///         still reporting green, so this asserts the preconditions every
    ///         handler depends on.
    function test_setupSanity() public view {
        console.log("vault totalAssets   ", vault.totalAssets());
        console.log("vault totalSupply   ", vault.totalSupply());
        console.log("swood totalGuardian ", swood.totalGuardianStake());
        console.log("guardian0 active    ", swood.isActiveGuardian(actors[0]) ? 1 : 0);
        console.log("ledger woodPriceX8  ", ledger.woodPriceX8());
        console.log("game challengeWindow", game.challengeWindow());
        console.log("court voteWindow    ", court.voteWindow());
        console.log("registry ledger set ", address(registry.exposureLedger()) == address(ledger) ? 1 : 0);
        console.log("gov ledger set      ", governor.exposureLedger() == address(ledger) ? 1 : 0);
        console.log("queue wired         ", vault.withdrawalQueue() == address(queue) ? 1 : 0);
        require(vault.totalAssets() > 0, "vault empty");
        require(swood.totalGuardianStake() > 0, "no guardian stake");
        require(swood.isActiveGuardian(actors[0]), "guardian0 inactive");
        require(ledger.woodPriceX8() > 0, "no wood price");
        require(governor.exposureLedger() == address(ledger), "gov ledger unwired");
        require(vault.withdrawalQueue() == address(queue), "queue unwired");
    }

    /// @notice Proves `challengeGame_lifecycle_toConviction` actually reaches a
    ///         conviction rather than silently no-opping.
    ///
    /// @dev This assertion is the whole point of the composite. Every step is
    ///      wrapped in try/catch so the handler never reverts a fuzzing
    ///      sequence — which means a broken composite fails SILENTLY, doing
    ///      nothing forever while coverage stays flat and the campaign looks
    ///      healthy. Without this test the only symptom would be adjudication
    ///      coverage that refuses to move, exactly the state this work exists
    ///      to fix. So: drive it end to end, then assert the terminal facts.
    function test_lifecycleProbe_toConviction() public {
        syndicateGovernor_lifecycle_toExecuted(7 days, 50_000e6, 0);
        uint256 pid = governor.proposalCount();
        require(governor.getProposal(pid).executedAt != 0, "setup: proposal not executed");

        uint256 challengesBefore = game.challengeCount();
        uint256 casesBefore = court.caseCount();

        challengeGame_lifecycle_toConviction(0, 0);

        uint256 challengeId = game.challengeCount();
        assertGt(challengeId, challengesBefore, "no challenge was filed");
        assertGt(court.caseCount(), casesBefore, "challenge never reached the court");

        IChallengeGame.Challenge memory c = game.challengeOf(challengeId);
        console.log("challenge status (1=Filed,2=Disputed,3=Failed,4=Settled,5=Inconclusive)", uint256(c.status));
        console.log("bondWood       ", c.bondWood);
        console.log("counterBondWood", c.counterBondWood);
        assertEq(c.counterBondWood, c.bondWood, "counter-bond pool never completed");

        // Settled is the conviction terminal: rule(Guilty) -> _settle.
        assertEq(uint256(c.status), uint256(IChallengeGame.Status.Settled), "challenge did not reach conviction");
    }

    /// @notice GL-14's ledger clause has teeth, in BOTH directions.
    ///
    /// @dev The clause this replaced compared `poolWood` against `raisedWood`,
    ///      and `counterBondPoolOf` derives both from the same `p.weight` slot
    ///      — `outcome == Open ? raisedWood : 0` alongside `raisedWood` itself.
    ///      Scoped to `Open`, that is unsatisfiable: the property could not fail
    ///      however wrong the pool accounting got, while its own comment claimed
    ///      strictness.
    ///
    ///      A replacement that is merely a DIFFERENT tautology would be no
    ///      better, and nothing in the suite would say so — the fizz runner
    ///      exercises no property directly. So this proves both halves: the
    ///      equality holds against a real live-bond-plus-open-pool state, and it
    ///      goes false when `bondedWood` alone moves off that state.
    function test_property_GL14_ledgerClauseHasTeeth() public {
        syndicateGovernor_lifecycle_toExecuted(7 days, 50_000e6, 0);
        uint256 pid = governor.proposalCount();
        require(governor.getProposal(pid).executedAt != 0, "setup: proposal not executed");

        challengeGame_file_clamped(pid, 0, "ipfs://gl14");
        uint256 challengeId = game.challengeCount();
        require(challengeId != 0, "setup: no challenge filed");

        // PART-funded deliberately. The pool has to stay `Open` so it is still
        // inside `bondedWood` and the sum has a second leg to get wrong; a
        // completed or closed pool would leave only the bond.
        (, uint256 target,,,) = game.counterBondPoolOf(challengeId);
        require(target != 0, "setup: pool priced at zero, the pool leg is untested");
        challengeGame_dispute_clamped(challengeId, target / 2);

        (uint256 poolWood,, uint256 raised,,) = game.counterBondPoolOf(challengeId);
        require(raised != 0, "setup: nothing contributed, the pool leg is untested");
        assertEq(poolWood, raised, "setup: the pool must still be Open here");

        uint256 bonded = game.bondedWood();
        assertEq(
            bonded,
            game.challengeOf(challengeId).bondWood + poolWood,
            "setup: one bond plus one open pool is the whole ledger"
        );
        assertTrue(property_GL14_counterBondPoolMatchesContributions(), "GL-14 must hold on honest state");

        // ...and it must be ABLE to fail. Only the counter moves; every position
        // the property sums is left exactly as it was.
        stdstore.target(address(game)).sig("bondedWood()").checked_write(bonded + 1);
        assertFalse(
            property_GL14_counterBondPoolMatchesContributions(), "GL-14 cannot see a bondedWood that lost its backing"
        );
    }

    /// @notice DECISION EVIDENCE for GL-49 / x-ray X-8: measures every candidate
    ///         basis for the claim, before and after a conviction, so the
    ///         restatement can be chosen from data rather than argued.
    ///
    /// @dev GL-49 as shipped compares LIVE booked exposure against the LIVE
    ///      bond, and it fires after a conviction. The question this answers is
    ///      whether that is a real economic gap or the wrong pairing, because
    ///      the protocol itself uses two different readings:
    ///
    ///        - `recordApproval` caps booking at `kNumerator *
    ///          _slashableBondUsd(g, price, 0)` — anchor 0, the LIVE stake
    ///          (`ExposureLedger.sol:1040`).
    ///        - `slashBpsFor` sizes the slash off `_slashableBondUsd(g, price,
    ///          anchor)` — a HISTORICAL stake (`:1700`, `:1749`).
    ///
    ///      A conviction moves the live stake and cannot move the anchored one,
    ///      so a live-vs-live claim is guaranteed to break on any slash while
    ///      saying nothing about solvency at the moment that mattered.
    function test_x8_basisTable() public {
        syndicateGovernor_lifecycle_toExecuted(7 days, 50_000e6, 0);
        uint256 pid = governor.proposalCount();
        uint256 executedAt = governor.getProposal(pid).executedAt;
        require(executedAt != 0, "not executed");
        uint256 anchor = executedAt - 1;

        console.log("--- BEFORE conviction (anchor = executedAt-1) ---");
        _logBases(pid, anchor);

        challengeGame_lifecycle_toConviction(0, 0);
        console.log("challenge status (4=Settled)", uint256(game.challengeOf(game.challengeCount()).status));

        console.log("--- AFTER conviction ---");
        _logBases(pid, anchor);

        // Does the stranded exposure ever clear? `openExposureUsd` sums buckets
        // over a WALL-CLOCK window, so expiry is the only thing that can
        // release it if the slash path does not. This decides whether a
        // convicted guardian is frozen permanently or only until the bucket
        // ages out — a very different finding.
        address g0 = actors[0]; // an approver: the composite approves actors[0..APPROVER_COUNT)
        console.log("--- unstake/re-approve reachability, post-slash ---");
        console.log("guardianStake      ", swood.guardianStake(g0));
        console.log("openExposureUsd    ", ledger.openExposureUsd(g0));
        console.log("hasFrozenCoverage  ", ledger.hasFrozenCoverage(g0) ? 1 : 0);

        skipTime(ledger.challengeWindow() + ledger.epochLength() * 2 + 1);
        console.log("--- after challengeWindow + 2 epochs ---");
        console.log("openExposureUsd    ", ledger.openExposureUsd(g0));
        console.log("hasFrozenCoverage  ", ledger.hasFrozenCoverage(g0) ? 1 : 0);
    }

    function _logBases(uint256 pid, uint256 anchor) internal view {
        uint256 k = ledger.kNumerator();
        (address[] memory approvers, uint256[] memory recorded) = ledger.approversOf(address(governor), pid);
        (, uint256[] memory pledged) = ledger.pledgedOf(address(governor), pid);
        for (uint256 i; i < approvers.length; i++) {
            address g = approvers[i];
            console.log("  guardian idx", i);
            console.log("    booking  (openExposureUsd)", ledger.openExposureUsd(g));
            console.log("    recorded (this proposal)  ", recorded[i]);
            console.log("    pledged  (this proposal)  ", pledged[i]);
            console.log("    k*bond   LIVE             ", k * ledger.slashableBondUsd(g));
            console.log(
                "    k*bond   ANCHORED         ", k * (swood.slashableStakeAt(g, anchor) * ledger.woodPriceX8()) / 1e8
            );
        }
    }

    // ── Violation Repros (auto-generated by Step 11) ──────────────────
    // Each test_repro_* function below replays a shrunk fuzzer call
    // sequence that violated a property. Run all with:
    //   forge test --match-contract FoundryTester -vvv
}
