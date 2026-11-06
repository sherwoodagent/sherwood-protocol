// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {UpgradeV1ToV2, IV1Live} from "script/robinhood-mainnet/UpgradeV1ToV2.s.sol";
import {SyndicateFactory} from "src/SyndicateFactory.sol";
import {SyndicateVault} from "src/SyndicateVault.sol";
import {GovernorBeacon} from "src/GovernorBeacon.sol";
import {SyndicateGovernor} from "src/SyndicateGovernor.sol";
import {Create3Factory} from "script/utils/Create3Factory.sol";
import {ChallengeGame} from "src/ChallengeGame.sol";
import {IChallengeGame} from "src/interfaces/IChallengeGame.sol";
import {IExposureLedger} from "src/interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "src/interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "src/BatchExecutorLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IV1Court {
    function refer(uint256 challengeId) external returns (uint256);
}

/// @notice The canonical ERC-8004 IdentityRegistry on 4663; `register()` is permissionless.
interface IIdentityRegistry8004 {
    function register() external returns (uint256 agentId);
}

interface IV1GameDrain {
    function resolve(uint256 challengeId) external;
    function challengeCount() external view returns (uint256);
}

/// @title UpgradeV1ToV2ForkTest
/// @notice Runs `UpgradeV1ToV2` phases 1-3 as the deployer against live 4663 state, and attacks every gap
///         between the four phase-3 transactions. Needs ROBINHOOD_RPC_URL on an archive node and UPGRADE_FORK_ARCHIVE=true.
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
        // The block is pinned, so the endpoint must be an archive node; the public RPC prunes history.
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0 || !vm.envOr("UPGRADE_FORK_ARCHIVE", false)) {
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

        // §7 rows 1-2 are re-read at the end of phase 3: a beacon moved off the v2 impl fails it.
        address stray = address(new SyndicateGovernor(1 hours, 1 hours));
        vm.prank(DEPLOYER);
        GovernorBeacon(b.beacon).upgradeTo(stray);
        vm.expectRevert(bytes("POST: beacon impl"));
        up.postPhase3(b, game, DEPLOYER);
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

    // ── Resumption and refusals ──

    /// @notice Phase 1 resumes after the game and the governor upgrade landed alone, then a re-run changes nothing.
    function test_fork_phase1_resumesAfterPartialBroadcast() public {
        if (!_fork()) return;
        UpgradeV1ToV2.Deployed memory d = up.deployedAddresses(b);
        vm.prank(DEPLOYER);
        vm.expectRevert(bytes("POST: beacon impl"));
        up.verifyPhase1();

        // A broadcast that stopped after the game deploy and the beacon upgrade (txs 1 and 5 of phase 1).
        SyndicateGovernor live = SyndicateGovernor(GovernorBeacon(b.beacon).implementation());
        bytes memory govInit = abi.encodePacked(
            type(SyndicateGovernor).creationCode, abi.encode(live.MIN_VOTING_PERIOD(), live.MIN_COOLDOWN_PERIOD())
        );
        bytes memory gameInit =
            abi.encodePacked(type(ChallengeGame).creationCode, abi.encode(DEPLOYER, b.wood, b.ledger, b.tierRegistry));
        vm.startPrank(DEPLOYER);
        Create3Factory(b.create3).deploy(up.GOVERNOR_IMPL_SALT(), govInit);
        Create3Factory(b.create3).deploy(up.GAME_SALT(), gameInit);
        GovernorBeacon(b.beacon).upgradeTo(d.govImpl);
        vm.stopPrank();

        vm.expectCall(b.beacon, abi.encodeWithSignature("upgradeTo(address)", d.govImpl), 0);
        UpgradeV1ToV2.Deployed memory got = up.phase1(b, DEPLOYER);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(d)), "addresses are the salt-derived ones");
        vm.prank(DEPLOYER);
        up.verifyPhase1();

        // Fully applied: a third run sends no deploy and no owner call.
        vm.expectCall(b.create3, abi.encodeWithSelector(Create3Factory.deploy.selector), 0);
        vm.expectCall(b.factory, abi.encodeWithSelector(SyndicateFactory.setVaultImpl.selector), 0);
        vm.expectCall(b.factory, abi.encodeWithSelector(SyndicateFactory.setUpgradesEnabled.selector), 0);
        vm.expectCall(d.newGame, abi.encodeWithSelector(ChallengeGame.setFilingsPaused.selector), 0);
        up.phase1(b, DEPLOYER);
    }

    /// @notice Each phase, run from a key that does not own the contracts, stops at the owner preflight.
    function test_fork_eachPhaseRefusesNonOwner() public {
        if (!_fork()) return;
        address outsider = makeAddr("outsider");
        vm.etch(outsider, address(up).code);
        vm.allowCheatcodes(outsider);
        UpgradeV1ToV2 asOutsider = UpgradeV1ToV2(outsider);
        bytes memory refusal = bytes("PREFLIGHT: SyndicateFactory owner is not the caller");

        vm.expectRevert(refusal);
        asOutsider.phase1(b, outsider);
        up.phase1(b, DEPLOYER);
        vm.expectRevert(refusal);
        asOutsider.phase2(b, outsider);
        up.phase2(b, DEPLOYER);
        vm.expectRevert(refusal);
        asOutsider.phase3(b, outsider);
        // Control: the owner passes the same preflight.
        up.phase3(b, DEPLOYER);
    }

    /// @notice A book already pointing CHALLENGE_GAME at the v2 game is refused by phases 2 and 3.
    function test_fork_bookPointingAtNewGameRefused() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        UpgradeV1ToV2.Book memory edited = b;
        edited.oldGame = up.newGameAddress(b);
        bytes memory refusal = bytes("book CHALLENGE_GAME already points at the v2 game");

        vm.expectRevert(refusal);
        up.phase2(edited, DEPLOYER);
        vm.expectRevert(refusal);
        up.phase3(edited, DEPLOYER);
        vm.expectRevert(refusal);
        up.phase1(edited, DEPLOYER);
    }

    // ── Opening the protocol (after phase 3) ──

    function _upgradeAll() internal {
        up.phase1(b, DEPLOYER);
        up.phase2(b, DEPLOYER);
        up.phase3(b, DEPLOYER);
    }

    function _identity(address who) internal returns (uint256 agentId) {
        IIdentityRegistry8004 registry = IIdentityRegistry8004(address(SyndicateFactory(b.factory).agentRegistry()));
        vm.prank(who);
        agentId = registry.register();
    }

    function _createAs(address who, uint256 agentId) internal returns (bool ok, bytes memory err) {
        SyndicateFactory.SyndicateConfig memory cfg = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://open",
            asset: IERC20(vm.parseJsonAddress(vm.readFile("chains/4663.json"), ".USDG")),
            name: "Open Vault",
            symbol: "OPEN",
            openDeposits: true,
            subdomain: "open-protocol-test"
        });
        vm.prank(who);
        try SyndicateFactory(b.factory).createSyndicate(agentId, cfg) returns (uint256, address) {
            return (true, "");
        } catch (bytes memory e) {
            return (false, e);
        }
    }

    function _proposeAs(address agent, address vault, address coProposer) internal returns (bytes memory err) {
        ISyndicateGovernor gov = ISyndicateGovernor(SyndicateFactory(b.factory).governorOf(vault));
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        uint256[] memory caps = new uint256[](1);
        ISyndicateGovernor.CoProposer[] memory co = new ISyndicateGovernor.CoProposer[](1);
        co[0] = ISyndicateGovernor.CoProposer({agent: coProposer, splitBps: 1000});
        vm.prank(agent);
        try gov.propose(
            vault,
            address(0xdead),
            "ipfs://p",
            1 days,
            ISyndicateGovernor.RiskEnvelope(0, 0),
            calls,
            caps,
            calls,
            caps,
            co
        ) returns (
            uint256
        ) {
            return "";
        } catch (bytes memory e) {
            return e;
        }
    }

    /// @notice A fresh address with only an ERC-8004 identity creates a vault once the protocol is open.
    function test_fork_open_anyoneWithIdentityCreatesVault() public {
        if (!_fork()) return;
        _upgradeAll();
        address founder = makeAddr("founder");
        uint256 agentId = _identity(founder);

        (bool okBefore,) = _createAs(founder, agentId);
        assertFalse(okBefore, "control: creation charged the 1e24 WOOD fee before opening");

        up.openProtocol(b, DEPLOYER);
        (bool ok, bytes memory err) = _createAs(founder, agentId);
        if (!ok) console2.logBytes(err);
        assertTrue(ok, "free creation with an identity");
        assertEq(SyndicateFactory(b.factory).syndicateCount(), 4, "fourth syndicate");

        (bool okNoId, bytes memory errNoId) = _createAs(makeAddr("no-identity"), agentId);
        assertFalse(okNoId, "identity still required");
        _assertSelector(errNoId, SyndicateFactory.NotAgentOwner.selector, "identity gate");
    }

    /// @notice A registered non-owner agent passes the launch gate (propose and co-propose) once the protocol is open.
    function test_fork_open_registeredAgentProposes() public {
        if (!_fork()) return;
        _upgradeAll();
        (, address vault,,,,,) = SyndicateFactory(b.factory).syndicates(1);
        address agent = makeAddr("agent");
        address co = makeAddr("co-agent");
        uint256 agentId = _identity(agent);
        uint256 coId = _identity(co);
        address vaultOwner = ISyndicateVault(vault).owner();
        vm.startPrank(vaultOwner);
        ISyndicateVault(vault).registerAgent(agentId, agent);
        ISyndicateVault(vault).registerAgent(coId, co);
        vm.stopPrank();
        assertTrue(agent != vaultOwner, "agent is not the vault owner");

        _assertSelector(_proposeAs(agent, vault, co), ISyndicateGovernor.ProposerNotOwner.selector, "before opening");

        up.openProtocol(b, DEPLOYER);
        // Past the agent, launch, owner-bond, open-proposal and cooldown gates: only the placeholder strategy stops it.
        assertEq(
            _proposeAs(agent, vault, co),
            abi.encodeWithSelector(ISyndicateGovernor.StrategyNotRegistered.selector, address(0xdead)),
            "after opening"
        );
    }

    /// @notice Open deposits need both the factory flag off and the vault's own `openDeposits` on.
    function test_fork_open_unapprovedDepositsOnOpenedVault() public {
        if (!_fork()) return;
        _upgradeAll();
        SyndicateFactory f = SyndicateFactory(b.factory);
        address vault;
        for (uint256 s = 1; s <= f.syndicateCount(); s++) {
            (, address v,,,,,) = f.syndicates(s);
            if (!ISyndicateVault(v).depositsLocked()) {
                vault = v;
                break;
            }
        }
        assertTrue(vault != address(0), "no live vault accepts deposits at the pinned block");
        address asset = IERC4626(vault).asset();
        uint256 amount = 100 * 10 ** IERC20Metadata(asset).decimals();
        address lp = makeAddr("unapproved-lp");
        deal(asset, lp, 3 * amount);
        vm.prank(lp);
        IERC20(asset).approve(vault, type(uint256).max);

        vm.prank(ISyndicateVault(vault).owner());
        ISyndicateVault(vault).setOpenDeposits(true);
        vm.prank(lp);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        IERC4626(vault).deposit(amount, lp);

        up.openProtocol(b, DEPLOYER);
        vm.prank(lp);
        assertGt(IERC4626(vault).deposit(amount, lp), 0, "unapproved deposit on an opened vault");

        // The creator's own flag still gates: closed again, the same depositor is refused.
        vm.prank(ISyndicateVault(vault).owner());
        ISyndicateVault(vault).setOpenDeposits(false);
        vm.prank(lp);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        IERC4626(vault).deposit(amount, lp);
    }

    /// @notice Open-protocol runs only after phase 3, from the owner, and a re-run sends nothing.
    function test_fork_open_preflightAndIdempotence() public {
        if (!_fork()) return;
        up.phase1(b, DEPLOYER);
        vm.expectRevert(bytes("OPEN: run phase 3 first"));
        up.openProtocol(b, DEPLOYER);
        up.phase2(b, DEPLOYER);
        up.phase3(b, DEPLOYER);

        address outsider = makeAddr("outsider");
        vm.etch(outsider, address(up).code);
        vm.allowCheatcodes(outsider);
        vm.expectRevert(bytes("PREFLIGHT: SyndicateFactory owner is not the caller"));
        UpgradeV1ToV2(outsider).openProtocol(b, outsider);

        vm.prank(DEPLOYER);
        vm.expectRevert(bytes("OPEN: creation fee still charged"));
        up.verifyOpenProtocol();

        // The book may already name the new game (§9 edits it after phase 3); opening still runs.
        UpgradeV1ToV2.Book memory edited = b;
        edited.oldGame = up.newGameAddress(b);
        up.openProtocol(edited, DEPLOYER);
        vm.prank(DEPLOYER);
        up.verifyOpenProtocol();

        vm.expectCall(b.factory, abi.encodeWithSelector(SyndicateFactory.setCreationFee.selector), 0);
        vm.expectCall(b.factory, abi.encodeWithSelector(SyndicateFactory.setOwnerOnlyProposals.selector), 0);
        vm.expectCall(b.factory, abi.encodeWithSelector(SyndicateFactory.setDepositsRestricted.selector), 0);
        up.openProtocol(b, DEPLOYER);
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
