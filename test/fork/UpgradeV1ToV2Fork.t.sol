// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UpgradeV1ToV2, IV1Live} from "script/robinhood-mainnet/UpgradeV1ToV2.s.sol";
import {SyndicateFactory} from "src/SyndicateFactory.sol";
import {SyndicateVault} from "src/SyndicateVault.sol";
import {GovernorBeacon} from "src/GovernorBeacon.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";

interface IV1Court {
    function refer(uint256 challengeId) external returns (uint256);
}

interface IV1GameDrain {
    function resolve(uint256 challengeId) external;
    function challengeCount() external view returns (uint256);
}

/// @title UpgradeV1ToV2ForkTest
/// @notice Runs `UpgradeV1ToV2` phases 1-3 as the deployer against live 4663 state, and attacks every gap
///         between the four phase-3 transactions. Needs ROBINHOOD_RPC_URL on an archive node (the block is pinned).
contract UpgradeV1ToV2ForkTest is Test {
    uint256 internal constant PINNED_BLOCK = 107_570_000;
    address internal constant DEPLOYER = 0x5A00afAecE9CF61A768E2AE2713084C8d354DF94;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    UpgradeV1ToV2 internal up;
    UpgradeV1ToV2.Book internal b;
    address internal attacker = makeAddr("attacker");

    // Executed proposals still inside their filing window at the pinned block: the gap attacks' targets.
    address[] internal openGovs;
    uint256[] internal openPids;

    // ── Fixture ──

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc, vm.envOr("UPGRADE_FORK_BLOCK", PINNED_BLOCK));
        console2.log("fork block:", block.number);

        // The script runs AT the deployer address, so every call it makes comes from the live owner.
        UpgradeV1ToV2 impl = new UpgradeV1ToV2();
        vm.etch(DEPLOYER, address(impl).code);
        vm.allowCheatcodes(DEPLOYER);
        up = UpgradeV1ToV2(DEPLOYER);
        b = up.book();

        // Non-vacuity: the live deployment, not a fixture.
        assertEq(SyndicateFactory(b.factory).syndicateCount(), 3, "live syndicate count");
        assertEq(IV1Live(b.beacon).owner(), DEPLOYER, "live beacon owner");
        assertEq(IV1Live(b.ledger).coverageFreezer(), b.oldGame, "live freezer is the v1 game");

        _collectOpenProposals();
        assertGt(openPids.length, 0, "no executed proposal inside its window: the gap attacks would be vacuous");
        console2.log("executed proposals inside their filing window:", openPids.length);

        deal(b.wood, attacker, 1e30);
        vm.startPrank(attacker);
        IERC20(b.wood).approve(b.oldGame, type(uint256).max);
        IERC20(b.wood).approve(up.newGameAddress(b), type(uint256).max);
        vm.stopPrank();
        return true;
    }

    function _collectOpenProposals() internal {
        SyndicateFactory f = SyndicateFactory(b.factory);
        for (uint256 s = 1; s <= f.syndicateCount(); s++) {
            (, address vault,,,,,) = f.syndicates(s);
            ISyndicateGovernor gov = ISyndicateGovernor(f.governorOf(vault));
            for (uint256 pid = 1; pid <= gov.proposalCount(); pid++) {
                ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
                if (p.executedAt == 0) continue;
                if (p.executedAt + p.strategyDuration + 14 days < vm.getBlockTimestamp()) continue;
                openGovs.push(address(gov));
                openPids.push(pid);
            }
        }
    }

    function _states() internal view returns (uint8[] memory out) {
        SyndicateFactory f = SyndicateFactory(b.factory);
        out = new uint8[](64);
        uint256 k;
        for (uint256 s = 1; s <= f.syndicateCount(); s++) {
            (, address vault,,,,,) = f.syndicates(s);
            ISyndicateGovernor gov = ISyndicateGovernor(f.governorOf(vault));
            for (uint256 pid = 1; pid <= gov.proposalCount(); pid++) {
                out[k++] = uint8(gov.getProposalState(pid));
            }
        }
        assertGt(k, 0, "no proposals read");
    }

    function _fileOld(uint256 j) internal returns (bool ok, bytes memory err) {
        vm.prank(attacker);
        try IChallengeGame(b.oldGame)
            .file(
                openGovs[j], openPids[j], IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "gap"
            ) returns (
            uint256
        ) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _fileNew(uint256 j) internal returns (bool ok, bytes memory err) {
        address game = up.newGameAddress(b);
        vm.prank(attacker);
        try IChallengeGame(game)
            .file(
                openGovs[j], openPids[j], IChallengeGame.Predicate.OutOfAdapterOutflow, address(0), bytes4(0), "gap"
            ) returns (
            uint256
        ) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _assertSelector(bytes memory err, bytes4 expected, string memory label) internal pure {
        require(err.length >= 4, string.concat(label, ": revert without a selector"));
        assertEq(bytes4(err), expected, label);
    }

    // ── Full run ──

    /// @notice Phases 1-3 land the v2 stack and every existing proposal keeps its state.
    function test_fork_fullUpgrade_endState() public {
        if (!_fork()) return;
        uint8[] memory before = _states();

        UpgradeV1ToV2.Deployed memory d = up.phase1(b, DEPLOYER);
        up.phase2(b, DEPLOYER);
        address game = up.phase3(b, DEPLOYER);

        assertEq(game, d.newGame, "phase 3 rotated to the phase-1 game");
        assertEq(GovernorBeacon(b.beacon).implementation(), d.govImpl, "beacon impl");
        assertEq(address(uint160(uint256(vm.load(b.registry, IMPL_SLOT)))), d.regImpl, "registry impl");
        assertEq(IV1Live(b.swood).authorizedSlasher(), game, "slasher");
        assertEq(IV1Live(b.tierRegistry).authorizedDemoter(), game, "demoter");
        assertEq(IV1Live(b.ledger).coverageFreezer(), game, "freezer");
        assertEq(address(ChallengeGame(game).stakedWood()), b.swood, "stakedWood");
        assertEq(SyndicateFactory(b.factory).vaultImpl(), d.vaultImpl, "factory vault impl");
        assertTrue(SyndicateFactory(b.factory).upgradesEnabled(), "upgrades enabled");
        assertEq(keccak256(abi.encode(_states())), keccak256(abi.encode(before)), "proposal states moved");
    }

    /// @notice After phase 1 a creator can upgrade its vault, and the v2 impl still admits a later upgrade.
    function test_fork_creatorUpgradesVault_andCanUpgradeAgain() public {
        if (!_fork()) return;
        UpgradeV1ToV2.Deployed memory d = up.phase1(b, DEPLOYER);

        SyndicateFactory f = SyndicateFactory(b.factory);
        (, address vault, address creator,,,,) = f.syndicates(1);
        assertTrue(creator != DEPLOYER, "creator is not the deployer");
        uint256 supply = IERC20(vault).totalSupply();
        uint256 assets = IERC4626(vault).totalAssets();

        vm.prank(creator);
        f.upgradeVault(vault, d.vaultImpl);
        assertEq(address(uint160(uint256(vm.load(vault, IMPL_SLOT)))), d.vaultImpl, "vault on the v2 impl");
        assertEq(IERC20(vault).totalSupply(), supply, "supply moved");
        assertEq(IERC4626(vault).totalAssets(), assets, "assets moved");

        address later = address(new SyndicateVault());
        vm.prank(DEPLOYER);
        f.setVaultImpl(later);
        vm.prank(creator);
        f.upgradeVault(vault, later);
        assertEq(address(uint160(uint256(vm.load(vault, IMPL_SLOT)))), later, "v2 impl authorised the next upgrade");
    }

    /// @notice After the rotation the v2 game freezes and releases coverage on the kept v1 ledger.
    function test_fork_newGameFreezesAndReleasesKeptLedger() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        up.phase2(b, DEPLOYER);
        address game = up.phase3(b, DEPLOYER);
        vm.prank(DEPLOYER);
        ChallengeGame(game).setFilingsPaused(false);

        (bool ok, bytes memory err) = _fileNew(0);
        if (!ok) console2.logBytes(err);
        assertTrue(ok, "filing on the new game");
        assertTrue(IExposureLedger(b.ledger).isCoverageFrozen(openGovs[0], openPids[0]), "kept ledger frozen");

        vm.warp(vm.getBlockTimestamp() + ChallengeGame(game).voteWindow());
        ChallengeGame(game).resolve(1);
        assertEq(IV1Live(b.ledger).frozenCoverageCount(), 0, "released on the kept ledger");
    }

    // ── Phase 3: the four-transaction gaps ──

    /// @notice With old filings paused, no filing lands on either game between any two rotation transactions,
    ///         and nothing freezes a key or re-arms a window. The new game is UNPAUSED here (worst case).
    function test_fork_gap_noFilingLandsBetweenRotationSteps() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        // Live filings are already paused; open them so phase 2 is what closes them here.
        vm.prank(DEPLOYER);
        IV1Live(b.oldGame).setFilingsPaused(false);
        up.phase2(b, DEPLOYER);
        address game = up.newGameAddress(b);
        vm.prank(DEPLOYER);
        ChallengeGame(game).setFilingsPaused(false);
        up.phase3Preflight(b, DEPLOYER);

        // Index g = number of rotation steps already applied; g == 0 is the moment before the first one.
        bytes4[3] memory newGameRefusal = [
            IChallengeGame.ZeroAddress.selector,
            IExposureLedger.NotCoverageFreezer.selector,
            IExposureLedger.NotCoverageFreezer.selector
        ];
        for (uint256 g = 0; g < 4; g++) {
            if (g > 0) up.rotateStep(b, game, g - 1);
            for (uint256 j = 0; j < openPids.length; j++) {
                (bool okOld, bytes memory errOld) = _fileOld(j);
                assertFalse(okOld, "old-game filing landed in a gap");
                _assertSelector(errOld, IChallengeGame.FilingsPaused.selector, "old game");

                (bool okNew, bytes memory errNew) = _fileNew(j);
                assertFalse(okNew, "new-game filing landed in a gap");
                _assertSelector(errNew, newGameRefusal[g == 0 ? 0 : g - 1], "new game");
            }
            // The rest of the permissionless surface that could freeze or re-arm: none of it has a challenge to act on.
            assertEq(IV1GameDrain(b.oldGame).challengeCount(), 0, "old game holds a challenge");
            vm.expectRevert();
            IV1GameDrain(b.oldGame).resolve(1);
            vm.expectRevert();
            IV1Court(b.court).refer(1);
            assertEq(ChallengeGame(game).challengeCount(), 0, "new game holds a challenge");

            assertEq(IV1Live(b.ledger).frozenCoverageCount(), 0, "a key froze in a gap");
            for (uint256 j = 0; j < openPids.length; j++) {
                bytes32 key = keccak256(abi.encode(openGovs[j], openPids[j]));
                assertEq(IV1Live(b.oldGame).challengeableUntil(key), 0, "old-game window re-armed");
                assertEq(ChallengeGame(game).challengeableUntil(key), 0, "new-game window re-armed");
            }
        }
        up.rotateStep(b, game, 3);
        up.postPhase3(b, game, DEPLOYER);
    }

    /// @notice Phase 3 refuses to start while old-game filings are open.
    function test_fork_gap_phase3RefusesWhileOldFilingsOpen() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        vm.prank(DEPLOYER);
        IV1Live(b.oldGame).setFilingsPaused(false);
        vm.expectRevert(bytes("PHASE3: old game filings open (run phase 2)"));
        up.phase3(b, DEPLOYER);
    }

    /// @notice Each of runbook 5(a)-(c) alone stops phase 3; the live old game is v1 bytecode, so the states are mocked.
    function test_fork_phase3RefusesEachRunbookPrecondition() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        up.phase2(b, DEPLOYER);
        uint256 snap = vm.snapshotState();

        vm.mockCall(b.ledger, abi.encodeCall(IV1Live.frozenCoverageCount, ()), abi.encode(uint256(1)));
        vm.expectRevert(bytes("PHASE3: 5(a) a coverage key is frozen"));
        up.phase3(b, DEPLOYER);
        vm.revertToState(snap);
        vm.clearMockedCalls();

        vm.mockCall(
            b.oldGame, abi.encodeCall(IV1Live.liveChallengeCountOf, (openGovs[0], openPids[0])), abi.encode(uint256(1))
        );
        vm.expectRevert(bytes("PHASE3: 5(b) live old-game challenge"));
        up.phase3(b, DEPLOYER);
        vm.revertToState(snap);
        vm.clearMockedCalls();

        bytes32 key = keccak256(abi.encode(openGovs[0], openPids[0]));
        uint256 rearmed = vm.getBlockTimestamp();
        vm.mockCall(b.oldGame, abi.encodeCall(IV1Live.challengeableUntil, (key)), abi.encode(rearmed));
        vm.expectRevert(bytes("PHASE3: 5(c) re-armed old-game window"));
        up.phase3(b, DEPLOYER);
        vm.revertToState(snap);
        vm.clearMockedCalls();

        // Control: the same state unmocked passes.
        up.phase3(b, DEPLOYER);
    }

    /// @notice Why the pause is required: with old filings open, a filing mid-rotation wedges the freezer step.
    function test_fork_gap_openOldFilingsWedgeFreezerRotation() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        vm.prank(DEPLOYER);
        IV1Live(b.oldGame).setFilingsPaused(false);
        address game = up.newGameAddress(b);

        up.rotateStep(b, game, 0);
        up.rotateStep(b, game, 1);
        up.rotateStep(b, game, 2);
        (bool ok, bytes memory err) = _fileOld(0);
        if (!ok) console2.logBytes(err);
        assertTrue(ok, "control: the old-game filing lands when not paused");
        assertEq(IV1Live(b.ledger).frozenCoverageCount(), 1, "the filing froze a key");

        vm.expectRevert(IExposureLedger.CoverageFrozen.selector);
        up.rotateStep(b, game, 3);
    }

    /// @notice A filing on the new game before phase 3 is refused even with the new game unpaused.
    function test_fork_gap_newGameRefusesBeforeRotation() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        address game = up.newGameAddress(b);
        assertTrue(ChallengeGame(game).filingsPaused(), "phase 1 mirrors the live paused posture");
        vm.prank(DEPLOYER);
        ChallengeGame(game).setFilingsPaused(false);
        (bool ok, bytes memory err) = _fileNew(0);
        assertFalse(ok, "new-game filing landed before rotation");
        _assertSelector(err, IChallengeGame.ZeroAddress.selector, "new game before rotation");
    }
}
