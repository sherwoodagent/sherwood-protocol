// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Test, StdStorage, stdStorage} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {Handlers} from "./handlers/Handlers.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice Contract to be used for quick testing with Foundry
contract FoundryTester is Test, Handlers {
    using stdStorage for StdStorage;

    modifier asActor() override {
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    /// @notice `vm.stopPrank()`, called from a frame one level down.
    ///
    /// @dev Only ever needed after a handler carrying `asActor` REVERTS: the
    ///      modifier's trailing `stopPrank` is skipped, and the cheatcode state
    ///      does not unwind with the EVM frame, so the prank outlives the call.
    ///      A plain `vm.stopPrank()` from the test body does not clear it —
    ///      the prank was registered one call deep (inside the self-call that
    ///      reverted) and the cheatcode is depth-scoped, so the shallower stop
    ///      is a silent no-op. Verified the hard way: without the extra frame
    ///      the leftover prank re-targets every later call and the recovery
    ///      assertions fail as `NoActiveStake`, from an actor that was never
    ///      the vault owner.
    function clearLeakedPrank() external {
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

    /// @notice The predictor stops returning a proposal once `file` would
    ///         refuse it, and the conviction composite is what creates that
    ///         state.
    ///
    /// @dev `_challengeableProposal` predicts `file`'s gates. Modelling only
    ///      the coverage one left it too LOOSE against `AlreadyConvicted`:
    ///      nothing clears the pledge on conviction, so a convicted proposal
    ///      keeps passing executed/window/coverage forever, and the predictor
    ///      would keep returning it while `file` rejected it — the composite
    ///      quietly no-opping for every seed that lands there first.
    ///
    ///      That decay is self-inflicted, which is what makes it worth a test
    ///      rather than a comment: the composite mints one poisoned proposal
    ///      per success, so its own hit rate falls as it works.
    ///
    ///      Asserts BOTH sides of the transition — found before, skipped after
    ///      — with the pledge proven still standing in between, so the test
    ///      cannot pass because the fixture stopped qualifying for some other
    ///      reason. The `file` probe pins that the predictor's new answer is
    ///      the same one the contract gives.
    function test_challengeableProposal_skipsAConvictedProposal() public {
        syndicateGovernor_lifecycle_toExecuted(7 days, 50_000e6, 0);
        uint256 pid = governor.proposalCount();
        require(governor.getProposal(pid).executedAt != 0, "setup: proposal not executed");

        address challenger = _nonGuardian(0);
        assertEq(_challengeableProposal(0, challenger), pid, "setup: the predictor must find it BEFORE the conviction");

        challengeGame_lifecycle_toConviction(0, 0);
        uint256 challengeId = game.challengeCount();
        require(
            game.challengeOf(challengeId).status == IChallengeGame.Status.Settled,
            "setup: the composite did not reach a conviction"
        );

        // The pledge SURVIVES the conviction, so every check the predictor made
        // before still passes. Without this the test could go green because the
        // fixture stopped qualifying rather than because the gate is modelled.
        (, uint256[] memory pledged) = ledger.pledgedOf(address(governor), pid);
        uint256 stillPledged;
        for (uint256 i; i < pledged.length; i++) {
            stillPledged += pledged[i];
        }
        assertGt(stillPledged, 0, "conviction cleared the pledge; this fixture no longer covers the gap");

        assertEq(_challengeableProposal(0, challenger), 0, "predictor still offers a proposal file() would reject");

        // And that is the contract's own answer, not just the predictor's.
        vm.prank(challenger);
        vm.expectRevert(IChallengeGame.AlreadyConvicted.selector);
        game.file(address(governor), pid, IChallengeGame.Predicate(0), address(0), bytes4(0), "probe");
    }

    /// @notice The other gate the composite manufactures: one live challenge
    ///         per CHALLENGER, so the predictor's answer depends on who is
    ///         about to file.
    ///
    /// @dev Separate from the conviction test because that one cannot reach
    ///      this clause — `file` checks `_convicted` first, so a convicted
    ///      proposal would exercise the earlier gate and leave this one
    ///      unproven. This files WITHOUT convicting, so `AlreadyChallenged` is
    ///      the only reason the pid becomes unavailable.
    ///
    ///      Asserts the gate is per challenger and not per proposal: the filer
    ///      is blocked, a second challenger is still offered the same pid. A
    ///      predictor that skipped the proposal outright would pass the first
    ///      assertion and fail the second — which is the point of having both.
    function test_challengeableProposal_skipsAProposalThisChallengerAlreadyFiled() public {
        syndicateGovernor_lifecycle_toExecuted(7 days, 50_000e6, 0);
        uint256 pid = governor.proposalCount();
        require(governor.getProposal(pid).executedAt != 0, "setup: proposal not executed");

        address filer = _nonGuardian(0);
        address other = _nonGuardian(1);
        require(filer != other, "setup: the two challengers must differ");
        assertEq(_challengeableProposal(0, filer), pid, "setup: found before anyone filed");

        vm.prank(filer);
        game.file(address(governor), pid, IChallengeGame.Predicate(0), address(0), bytes4(0), "fizz-already");
        require(game.challengeCount() != 0, "setup: nothing was filed");

        assertEq(_challengeableProposal(0, filer), 0, "predictor still offers a proposal this challenger cannot file");
        assertEq(_challengeableProposal(0, other), pid, "the gate is per CHALLENGER; another one may still file");

        // Again, the contract's own answer rather than only the predictor's.
        vm.prank(filer);
        vm.expectRevert(IChallengeGame.AlreadyChallenged.selector);
        game.file(address(governor), pid, IChallengeGame.Predicate(0), address(0), bytes4(0), "probe");
    }

    /// @notice `slashOwnerBond` closes the proposal lane, and the harness can
    ///         open it again — so no sequence that draws the slash selector
    ///         costs the campaign the rest of the lifecycle.
    ///
    /// @dev SHE-215 made `propose` and `executeProposal` read `ownerBondLive`.
    ///      `Base.setup()` binds the owner slot exactly once, to `address(this)`,
    ///      and `stakedWood_requestUnstakeOwner_clamped` /
    ///      `stakedWood_claimUnstakeOwner_clamped` run `asActor` — no actor is
    ///      that owner, so both revert always. The only owner-slot mutation the
    ///      fuzzer could land was `_stakedWood_slashOwnerBond`, which `delete`s
    ///      the record. One draw of it removed propose → vote → execute →
    ///      settle from the explored surface FOR THE REST OF THE RUN, and
    ///      nothing said so: no property fails, the campaign just stops covering
    ///      its largest lane.
    ///
    ///      This is the assertion that would have caught that, and the one that
    ///      keeps catching it — a silently-unreachable lifecycle is invisible in
    ///      a green campaign, so it has to be pinned by a test that drives the
    ///      transition. Every step goes through a HANDLER, not through
    ///      `swood` / `governor` directly: the claim under test is about the
    ///      EXPLORED SURFACE, so exercising anything the fuzzer cannot itself
    ///      reach would prove nothing.
    ///
    ///      Asserts both directions. A test that only checked the recovery
    ///      would pass just as well if the slash had quietly become a no-op, so
    ///      the closed state is pinned too — and pinned by revert REASON, since
    ///      "propose reverted" on its own is satisfied by the open-proposal
    ///      lock, the agent gate, and half a dozen other things.
    function test_fizz_proposalLaneRecoversAfterSlashOwnerBond() public {
        assertTrue(swood.ownerBondLive(address(vault)), "setup: the harness must start with a live owner bond");

        // 1. The slash really does close the lane — reached through the
        //    fuzzer's own selector, `stakedWood_secondary`'s `else` branch.
        stakedWood_secondary(15, 0, 0);
        assertFalse(swood.ownerBondLive(address(vault)), "slashOwnerBond left the bond live");
        assertEq(swood.ownerStake(address(vault)), 0, "slashOwnerBond left the record standing");

        uint256 countSlashed = governor.proposalCount();
        _assertProposeRefusedForOwnerBond();
        assertEq(governor.proposalCount(), countSlashed, "a refused propose must not have minted an id");

        // 2. ...and the harness can climb back out.
        stakedWood_restoreOwnerBond();
        assertTrue(swood.ownerBondLive(address(vault)), "the re-bind route did not restore the bond");
        assertGt(swood.ownerStake(address(vault)), 0, "the slot was restored empty");

        syndicateGovernor_propose_clamped(1 days, 1_000e6);
        assertGt(governor.proposalCount(), countSlashed, "the proposal lane never came back");
    }

    /// @notice The other half of the same reachability claim: the EXITING state
    ///         (`unstakeRequestedAt != 0`) is reachable at all, and reversible.
    ///
    /// @dev Distinct from the slash: that one empties the record, this one
    ///      leaves it funded and merely flags it. So it exercises the SECOND
    ///      clause of `ownerBondLive` and the `cancelUnstakeOwner` branch of
    ///      `stakedWood_restoreOwnerBond`, rather than the re-bind branch.
    ///      Before the owner-acting selectors this state had no producer in the
    ///      harness at all — the clause SHE-215 added was dead surface for the
    ///      fuzzer, which is the quieter half of the same defect.
    function test_fizz_proposalLaneRecoversAfterOwnerRequestsUnstake() public {
        require(swood.ownerBondLive(address(vault)), "setup: bond not live");
        require(governor.openProposalCount() == 0, "setup: the request is barred while a proposal is open");

        // `stakedWood_secondary`'s owner-acting request selector.
        stakedWood_secondary(12, 0, 0);
        assertFalse(swood.ownerBondLive(address(vault)), "requestUnstakeOwner should close the lane");
        assertGt(swood.ownerStake(address(vault)), 0, "the record must stay FUNDED - this is not the slash path");

        uint256 countExiting = governor.proposalCount();
        _assertProposeRefusedForOwnerBond();

        stakedWood_restoreOwnerBond();
        assertTrue(swood.ownerBondLive(address(vault)), "cancelUnstakeOwner did not reopen the lane");
        assertGt(swood.ownerStake(address(vault)), 0, "the cancel path must not have moved the bond");

        syndicateGovernor_propose_clamped(1 days, 1_000e6);
        assertGt(governor.proposalCount(), countExiting, "the proposal lane never came back");
    }

    /// @dev Drives the fuzzer's own propose handler and asserts it is refused
    ///      for the OWNER-BOND reason specifically.
    ///
    ///      Routed through a low-level self-call rather than `vm.expectRevert`
    ///      so the revert DATA is available to check — "propose reverted" on
    ///      its own is satisfied by the open-proposal lock, the agent gate and
    ///      half a dozen other things, none of which is the claim here.
    ///
    ///      The trailing `clearLeakedPrank` is not tidiness: `asActor`'s
    ///      `vm.stopPrank()` is skipped when the body reverts, and the prank
    ///      does not unwind with the EVM frame, so it would re-target every
    ///      later call — including `stakedWood_restoreOwnerBond`, whose whole
    ///      point is acting as the bound owner. See that helper for why the
    ///      stop has to happen one frame down.
    function _assertProposeRefusedForOwnerBond() internal {
        (bool ok, bytes memory ret) =
            address(this).call(abi.encodeCall(this.syndicateGovernor_propose_clamped, (1 days, 1_000e6)));
        assertFalse(ok, "propose must be refused while the owner bond is not live");
        assertEq(
            bytes4(ret),
            ISyndicateGovernor.OwnerBondNotLive.selector,
            "propose was refused, but not by the owner-bond gate"
        );

        this.clearLeakedPrank();
    }

    // ── Violation Repros (auto-generated by Step 11) ──────────────────
    // Each test_repro_* function below replays a shrunk fuzzer call
    // sequence that violated a property. Run all with:
    //   forge test --match-contract FoundryTester -vvv
}
