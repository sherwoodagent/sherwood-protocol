// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ChallengeEndToEndBase} from "../ChallengeEndToEnd.t.sol";

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {IExposureLedger} from "../../src/interfaces/IExposureLedger.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @title Upgrade_keepLedgerRotateGame
/// @notice Pins the guards `docs/upgrade-v1-to-v2-runbook.md` relies on: keep the ledger,
///         rotate the game in the forced order, and the hazards the runbook forbids (V2-01, V2-02).
///         The fixture's `game` stands in for the live v1 game; `game2` is the v2 game.
contract UpgradeKeepLedgerRotateGameTest is ChallengeEndToEndBase {
    uint256 constant SHIPPED_COOLDOWN = 7 days; // RobinhoodParams.COOLDOWN

    // ── Helpers ──

    /// @dev A second ledger configured like the fixture's. Used only by the hazard test.
    function _freshLedger() internal returns (ExposureLedger l2) {
        l2 = new ExposureLedger(ledgerOwner, address(swood), EPOCH_LENGTH);
        MockAggregatorV3 woodFeed2 = new MockAggregatorV3(8, 0.05e8);
        vm.startPrank(ledgerOwner);
        l2.setWoodUsdPrice(0.1e8);
        l2.setWoodFeed(address(woodFeed2), type(uint64).max);
        l2.setAssetFeed(address(usdg), address(feed), 365 days);
        l2.setCoveredTvlCapUsd(10_000_000e18);
        l2.setGuardianRegistry(address(registry));
        vm.stopPrank();
    }

    /// @dev Runbook step 5, in order: slasher -> setStakedWood -> demoter -> freezer LAST.
    function _rotateTo(ChallengeGame g, ExposureLedger l) internal {
        vm.prank(owner);
        swood.setAuthorizedSlasher(address(g));
        vm.prank(owner);
        g.setStakedWood(address(swood));
        tierRegistry.setAuthorizedDemoter(address(g));
        vm.prank(ledgerOwner);
        l.setCoverageFreezer(address(g));
        vm.prank(challenger);
        wood.approve(address(g), type(uint256).max);
    }

    function _fileOn(ChallengeGame g, uint256 pid) internal returns (uint256 cid) {
        vm.prank(challenger);
        cid = g.file(
            address(gov), pid, IChallengeGame.Predicate.OutOfAdapterOutflow, address(adapter), adapter.poke.selector, ""
        );
    }

    function _expectFileRevert(ChallengeGame g, uint256 pid, bytes4 sel) internal {
        vm.prank(challenger);
        vm.expectRevert(sel);
        g.file(
            address(gov), pid, IChallengeGame.Predicate.OutOfAdapterOutflow, address(adapter), adapter.poke.selector, ""
        );
    }

    function _newGame() internal returns (ChallengeGame) {
        return new ChallengeGame(owner, address(wood), address(ledger), address(tierRegistry));
    }

    function _filingDeadline(uint256 pid) internal view returns (uint256) {
        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
        return p.executedAt + p.strategyDuration + game.challengeWindow();
    }

    // ── Safe path ──

    /// @notice Keeping the ledger and rotating to a second game lets a proposal executed before the rotation be convicted on the new game.
    function test_keepLedger_rotateGame_convictsProposalExecutedBeforeRotation() public {
        uint256 pid = _proposeApproveExecute();
        ChallengeGame game2 = _newGame();
        _rotateTo(game2, ledger);

        assertEq(swood.authorizedSlasher(), address(game2));
        assertEq(address(game2.stakedWood()), address(swood));
        assertEq(tierRegistry.authorizedDemoter(), address(game2));
        assertEq(ledger.coverageFreezer(), address(game2));

        _expectFileRevert(game, pid, IExposureLedger.NotCoverageFreezer.selector);
        uint256 cid = _fileOn(game2, pid);
        assertTrue(ledger.isCoverageFrozen(address(gov), pid), "new game froze the kept ledger");

        uint256 swoodBefore = wood.balanceOf(address(swood));
        vm.prank(g2);
        game2.voteOnChallenge(cid, true);
        vm.prank(g3);
        game2.voteOnChallenge(cid, true);
        vm.warp(game2.challengeOf(cid).filedAt + game2.voteWindow());
        game2.resolve(cid);

        assertEq(uint256(game2.challengeOf(cid).status), uint256(IChallengeGame.Status.Settled), "convicted");
        assertEq(swood.guardianStake(g1), 0, "approver slashed");
        assertEq(swoodBefore - wood.balanceOf(address(swood)), G1_STAKE, "whole lock burned");
        assertEq(wood.balanceOf(address(bondEscrow)), 0, "proposer bond forfeited through the kept escrow");
    }

    // ── Forced order ──

    /// @notice `newGame.setStakedWood` before the slasher grant reverts `RoleNotGranted`.
    function test_rotation_setStakedWoodBeforeSlasherGrant_revertsRoleNotGranted() public {
        ChallengeGame game2 = _newGame();
        vm.prank(owner);
        vm.expectRevert(IChallengeGame.RoleNotGranted.selector);
        game2.setStakedWood(address(swood));
    }

    /// @notice `setCoverageFreezer` while an old-game challenge is live reverts `CoverageFrozen`.
    function test_rotation_setCoverageFreezerWhileOldChallengeLive_revertsCoverageFrozen() public {
        uint256 pid = _proposeApproveExecute();
        _file(challenger, pid, "ipfs://live");
        ChallengeGame game2 = _newGame();
        assertEq(ledger.frozenCoverageCount(), 1);
        vm.prank(ledgerOwner);
        vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
        ledger.setCoverageFreezer(address(game2));
    }

    /// @notice `pushWiring`'s ledger write reverts while the governor has any open proposal, even for an unchanged ledger.
    function test_pushWiring_ledgerWriteRefusedWhileProposalOpen() public {
        _proposeApproveExecute();
        assertEq(gov.openProposalCount(), 1);
        // The test contract is the governor's factory (fixture), i.e. pushWiring's caller.
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        gov.setExposureLedger(address(ledger));
    }

    // ── Why the ledger is kept (V2-01) ──

    /// @notice Re-pointing staking at a fresh ledger lets the approver of a still-challengeable proposal unstake, and `file` reverts `NothingToFreeze`.
    function test_whyLedgerIsKept_freshLedgerFreesApproverAndBlocksFiling() public {
        vm.prank(owner);
        swood.setCooldownPeriod(SHIPPED_COOLDOWN);
        uint256 pid = _proposeApproveExecute();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        vm.warp(executedAt + 1 hours + 1);
        vm.prank(agent);
        gov.settleProposal(pid);
        vm.prank(g1);
        swood.requestUnstakeGuardian();

        ExposureLedger l2 = _freshLedger();
        vm.prank(owner);
        registry.setExposureLedger(address(l2));
        vm.prank(owner);
        swood.setExposureLedger(address(l2));
        vm.prank(ledgerOwner);
        ledger.setCoverageFreezer(address(0));
        ChallengeGame game2 = new ChallengeGame(owner, address(wood), address(l2), address(tierRegistry));
        _rotateTo(game2, l2);

        assertEq(ledger.openExposure(g1), G1_STAKE, "the lock lives only in the old ledger");
        assertEq(l2.openExposure(g1), 0, "the fresh ledger has never heard of it");
        _expectFileRevert(game2, pid, IChallengeGame.NothingToFreeze.selector);

        vm.warp(vm.getBlockTimestamp() + SHIPPED_COOLDOWN + 1);
        assertLe(vm.getBlockTimestamp(), _filingDeadline(pid), "still inside the filing window");
        uint256 balBefore = wood.balanceOf(g1);
        vm.prank(g1);
        swood.claimUnstakeGuardian();
        assertEq(wood.balanceOf(g1) - balBefore, G1_STAKE, "the whole covering bond left");
    }

    // ── Re-armed window (V2-02) ──

    /// @notice Control: without rotation, a re-armed window admits a filing and holds the proposer bond.
    function test_control_rearmedWindow_noRotation_filingLandsAndBondHeld() public {
        (uint256 pid,) = _driveToFailedRearm();
        vm.warp(gov.getProposal(pid).executedAt + 30 days);
        assertGt(vm.getBlockTimestamp(), _filingDeadline(pid), "ordinary window closed");
        vm.expectRevert(ISyndicateGovernor.ChallengeWindowOpen.selector);
        gov.reclaimProposerBond(pid);
        assertGt(_file(challenger, pid, "ipfs://rearmed"), 0, "re-armed filing lands");
    }

    /// @notice `setCoverageFreezer` succeeds while a window is re-armed; afterwards filing reverts on both games and the bond is reclaimable early.
    function test_rearmedWindow_rotationPassesGuard_filingClosedAndBondReleasedEarly() public {
        (uint256 pid,) = _driveToFailedRearm();
        uint256 executedAt = gov.getProposal(pid).executedAt;
        uint256 rearmed = game.challengeableUntil(_reviewKey(pid));

        assertEq(ledger.frozenCoverageCount(), 0, "nothing frozen");
        assertGt(rearmed, vm.getBlockTimestamp(), "but the old game's window is re-armed");

        ChallengeGame game2 = _newGame();
        _rotateTo(game2, ledger); // the guard counts frozen keys only
        assertEq(game2.challengeableUntil(_reviewKey(pid)), 0, "the re-arm does not carry over");

        vm.warp(executedAt + 30 days);
        assertLt(vm.getBlockTimestamp(), rearmed, "inside the re-armed window");
        _expectFileRevert(game2, pid, IChallengeGame.WindowClosed.selector);
        _expectFileRevert(game, pid, IExposureLedger.NotCoverageFreezer.selector);

        uint256 agentBefore = wood.balanceOf(agent);
        gov.reclaimProposerBond(pid);
        assertEq(wood.balanceOf(agent) - agentBefore, PROPOSER_BOND, "bond reclaimed before the re-armed deadline");
    }
}
