// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {RobinhoodParams} from "./RobinhoodParams.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice The surface this script touches on contracts that stay on v1 bytecode (every selector exists in v1).
interface IV1Live {
    function owner() external view returns (address);
    // StakedWood
    function authorizedSlasher() external view returns (address);
    function setAuthorizedSlasher(address) external;
    function exposureLedger() external view returns (address);
    // TierRegistry
    function authorizedDemoter() external view returns (address);
    function setAuthorizedDemoter(address) external;
    // ExposureLedger
    function coverageFreezer() external view returns (address);
    function setCoverageFreezer(address) external;
    function frozenCoverageCount() external view returns (uint256);
    function challengeWindow() external view returns (uint256);
    // Old ChallengeGame
    function filingsPaused() external view returns (bool);
    function setFilingsPaused(bool) external;
    function liveChallengeCountOf(address governor, uint256 proposalId) external view returns (uint256);
    function challengeableUntil(bytes32 key) external view returns (uint256);
}

/**
 * @title  UpgradeV1ToV2
 * @notice Live 4663 upgrade `v1-deploy` -> `post-audit-v2`, per `docs/upgrade-v1-to-v2-runbook.md`, run by
 *         the deployer EOA that owns every contract. Three entry points, days apart:
 *         `runPhase1` (impls, new game, upgrades), `runPhase2` (pause old filings), `runPhase3` (rotate roles).
 *         Each phase resumes after a partial broadcast; `verifyPhase1` re-checks phase 1 against the chain.
 * @dev    Phase 3 is four EOA transactions, not one Safe batch; see the runbook's "Running it with the
 *         deployer key" for why the gaps are closed with old filings paused.
 */
contract UpgradeV1ToV2 is ScriptBase {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 public constant GAME_SALT = keccak256("sherwood.robinhood.v2.challenge-game");
    bytes32 public constant GOVERNOR_IMPL_SALT = keccak256("sherwood.robinhood.v2.governor-impl");
    bytes32 public constant REGISTRY_IMPL_SALT = keccak256("sherwood.robinhood.v2.guardian-registry-impl");
    bytes32 public constant VAULT_IMPL_SALT = keccak256("sherwood.robinhood.v2.vault-impl");
    uint256 public constant ROTATION_STEPS = 4;

    struct Book {
        address factory;
        address beacon;
        address registry;
        address tierRegistry;
        address swood;
        address ledger;
        address escrow;
        address oldGame;
        address court;
        address strategyFactory;
        address create3;
        address wood;
    }

    struct Deployed {
        address govImpl;
        address regImpl;
        address vaultImpl;
        address newGame;
    }

    struct RegistrySnapshot {
        address owner;
        address factory;
        address swood;
        address ledger;
        uint256 reviewPeriod;
        uint256 blockQuorumBps;
    }

    // ── Entry points ──

    function runPhase1() external {
        Book memory b = book();
        vm.startBroadcast();
        Deployed memory d = phase1(b, msg.sender);
        vm.stopBroadcast();
        console.log("governor impl v2: %s", d.govImpl);
        console.log("registry impl v2: %s", d.regImpl);
        console.log("vault impl v2:    %s", d.vaultImpl);
        console.log("challenge game v2 (CHALLENGE_GAME after phase 3): %s", d.newGame);
    }

    /// @notice Read-only: the post-phase-1 state, read from the chain. Run after the phase-1 broadcast.
    function verifyPhase1() external view {
        Book memory b = book();
        _requireOwners(b, msg.sender);
        postPhase1(b, deployedAddresses(b), msg.sender);
    }

    function runPhase2() external {
        Book memory b = book();
        vm.startBroadcast();
        phase2(b, msg.sender);
        vm.stopBroadcast();
        console.log("old game filings paused: %s", b.oldGame);
    }

    function runPhase3() external {
        Book memory b = book();
        vm.startBroadcast();
        address newGame = phase3(b, msg.sender);
        vm.stopBroadcast();
        console.log("roles rotated to %s; update CHALLENGE_GAME in the book by hand", newGame);
    }

    function runOpenProtocol() external {
        Book memory b = book();
        vm.startBroadcast();
        openProtocol(b, msg.sender);
        vm.stopBroadcast();
        console.log("protocol open: free vault creation, any registered agent proposes, deposits per vault");
    }

    /// @notice Read-only: the post-open state, read from the chain.
    function verifyOpenProtocol() external view {
        Book memory b = book();
        _requireOwners(b, msg.sender);
        postOpenProtocol(b);
    }

    // ── Phases (public so the fork test drives them) ──

    /// @notice Runbook steps 1a, 1b, 1c, 2, 3, plus the v2 vault impl for new syndicates and opt-in upgrades.
    /// @dev    Every deploy is CREATE3 and every call is skipped once applied, so a re-run resumes a partial broadcast.
    function phase1(Book memory b, address owner) public returns (Deployed memory d) {
        _requireOwners(b, owner);
        _requireBookNamesOldGame(b);
        d = deployedAddresses(b);

        // §2.4: constructor arguments come from the live implementations, never from constants.
        SyndicateGovernor liveGov = SyndicateGovernor(GovernorBeacon(b.beacon).implementation());
        uint256 minVoting = liveGov.MIN_VOTING_PERIOD();
        uint256 minCooldown = liveGov.MIN_COOLDOWN_PERIOD();
        uint256 minReview = GuardianRegistry(_registryImpl(b.registry)).minReviewPeriod();
        RegistrySnapshot memory before = _registrySnapshot(b.registry);

        _deployOnce(
            b,
            GOVERNOR_IMPL_SALT,
            abi.encodePacked(type(SyndicateGovernor).creationCode, abi.encode(minVoting, minCooldown))
        );
        _deployOnce(b, REGISTRY_IMPL_SALT, abi.encodePacked(type(GuardianRegistry).creationCode, abi.encode(minReview)));
        _deployOnce(b, VAULT_IMPL_SALT, type(SyndicateVault).creationCode);
        // 1b: the v2 game on the EXISTING ledger and tier registry, owned by the deployer.
        _deployOnce(
            b,
            GAME_SALT,
            abi.encodePacked(type(ChallengeGame).creationCode, abi.encode(owner, b.wood, b.ledger, b.tierRegistry))
        );
        // Also covers an impl left by an earlier, partial run.
        require(
            SyndicateGovernor(d.govImpl).MIN_VOTING_PERIOD() == minVoting
                && SyndicateGovernor(d.govImpl).MIN_COOLDOWN_PERIOD() == minCooldown,
            "PHASE1: governor impl floors differ from live"
        );
        require(GuardianRegistry(d.regImpl).minReviewPeriod() == minReview, "PHASE1: registry floor differs from live");
        _requireNewGame(b, d.newGame, owner);

        // 1c: the reviewed values are the v2 constructor defaults; only the window and the filing posture are pinned.
        ChallengeGame game = ChallengeGame(d.newGame);
        bool oldPaused = IV1Live(b.oldGame).filingsPaused();
        if (game.filingsPaused() != oldPaused) game.setFilingsPaused(oldPaused);

        if (GovernorBeacon(b.beacon).implementation() != d.govImpl) GovernorBeacon(b.beacon).upgradeTo(d.govImpl);
        if (_registryImpl(b.registry) != d.regImpl) UUPSUpgradeable(b.registry).upgradeToAndCall(d.regImpl, "");

        // v1 and v2 vault layouts are identical (PR body); creators opt in through `upgradeVault`.
        SyndicateFactory f = SyndicateFactory(b.factory);
        if (f.vaultImpl() != d.vaultImpl) f.setVaultImpl(d.vaultImpl);
        if (!f.upgradesEnabled()) f.setUpgradesEnabled(true);

        postPhase1(b, d, owner);
        require(
            keccak256(abi.encode(before)) == keccak256(abi.encode(_registrySnapshot(b.registry))),
            "POST1: registry storage moved"
        );
    }

    /// @notice Runbook §4 option A: stop new old-game filings so the drain is bounded.
    function phase2(Book memory b, address owner) public {
        _requireOwners(b, owner);
        _requireBookNamesOldGame(b);
        if (!IV1Live(b.oldGame).filingsPaused()) IV1Live(b.oldGame).setFilingsPaused(true);
        require(IV1Live(b.oldGame).filingsPaused(), "POST2: old game filings open");
    }

    /// @notice Runbook step 5, as four transactions in the runbook order.
    function phase3(Book memory b, address owner) public returns (address newGame) {
        newGame = phase3Preflight(b, owner);
        for (uint256 i = 0; i < ROTATION_STEPS; i++) {
            rotateStep(b, newGame, i);
        }
        postPhase3(b, newGame, owner);
    }

    /// @notice Runbook 5(a)-(c), plus old-game filings paused: what makes the four-transaction rotation safe.
    function phase3Preflight(Book memory b, address owner) public view returns (address newGame) {
        _requireOwners(b, owner);
        _requireBookNamesOldGame(b);
        newGame = newGameAddress(b);
        require(newGame.code.length != 0, "PHASE3: run phase 1 first");
        require(ChallengeGame(newGame).owner() == owner, "PHASE3: new game owner");
        require(IV1Live(b.oldGame).filingsPaused(), "PHASE3: old game filings open (run phase 2)");
        require(IV1Live(b.ledger).frozenCoverageCount() == 0, "PHASE3: 5(a) a coverage key is frozen");

        SyndicateFactory f = SyndicateFactory(b.factory);
        uint256 n = f.syndicateCount();
        for (uint256 s = 1; s <= n; s++) {
            (, address vault,,,,,) = f.syndicates(s);
            ISyndicateGovernor gov = ISyndicateGovernor(f.governorOf(vault));
            uint256 pids = gov.proposalCount();
            for (uint256 pid = 1; pid <= pids; pid++) {
                if (gov.getProposal(pid).executedAt == 0) continue;
                require(
                    IV1Live(b.oldGame).liveChallengeCountOf(address(gov), pid) == 0,
                    "PHASE3: 5(b) live old-game challenge"
                );
                bytes32 key = keccak256(abi.encode(address(gov), pid));
                require(
                    IV1Live(b.oldGame).challengeableUntil(key) < block.timestamp,
                    "PHASE3: 5(c) re-armed old-game window"
                );
            }
        }
    }

    /// @notice One rotation call; skipped when already applied, so a re-run resumes after a failed transaction.
    /// @dev    Order is forced: `setStakedWood` needs the slasher grant; the freezer goes last (runbook step 5).
    function rotateStep(Book memory b, address newGame, uint256 i) public {
        if (i == 0) {
            if (IV1Live(b.swood).authorizedSlasher() != newGame) IV1Live(b.swood).setAuthorizedSlasher(newGame);
        } else if (i == 1) {
            if (address(ChallengeGame(newGame).stakedWood()) != b.swood) ChallengeGame(newGame).setStakedWood(b.swood);
        } else if (i == 2) {
            if (IV1Live(b.tierRegistry).authorizedDemoter() != newGame) {
                IV1Live(b.tierRegistry).setAuthorizedDemoter(newGame);
            }
        } else if (i == 3) {
            if (IV1Live(b.ledger).coverageFreezer() != newGame) IV1Live(b.ledger).setCoverageFreezer(newGame);
        } else {
            revert("rotateStep: no such step");
        }
    }

    /// @notice After phase 3: vault creation is free (ERC-8004 identity still required), any registered agent
    ///         proposes and co-proposes, and each vault's own `openDeposits` decides who deposits.
    function openProtocol(Book memory b, address owner) public {
        _requireOwners(b, owner);
        require(IV1Live(b.ledger).coverageFreezer() == newGameAddress(b), "OPEN: run phase 3 first");
        SyndicateFactory f = SyndicateFactory(b.factory);
        if (f.creationFee() != 0) f.setCreationFee(address(f.creationFeeToken()), 0, f.creationFeeRecipient());
        if (f.ownerOnlyProposals()) f.setOwnerOnlyProposals(false);
        if (f.depositsRestricted()) f.setDepositsRestricted(false);
        postOpenProtocol(b);
    }

    // ── Post-checks (runbook §7) ──

    function postOpenProtocol(Book memory b) public view {
        SyndicateFactory f = SyndicateFactory(b.factory);
        require(f.creationFee() == 0, "OPEN: creation fee still charged");
        require(!f.ownerOnlyProposals(), "OPEN: proposals still owner-only");
        require(!f.depositsRestricted(), "OPEN: deposits still restricted");
        require(address(f.agentRegistry()) != address(0), "OPEN: ERC-8004 identity gating off");
        _requireRolesHeldBy(b, newGameAddress(b));
    }

    function postPhase1(Book memory b, Deployed memory d, address owner) public view {
        _requireImpls(b, d);
        _requireNewGame(b, d.newGame, owner);
        require(address(ChallengeGame(d.newGame).stakedWood()) == address(0), "POST1: new game sWOOD set early");
        require(
            ChallengeGame(d.newGame).filingsPaused() == IV1Live(b.oldGame).filingsPaused(),
            "POST1: filing posture differs"
        );

        // Until phase 3 every role stays with the old game.
        _requireRolesHeldBy(b, b.oldGame);
        require(SyndicateFactory(b.factory).vaultImpl() == d.vaultImpl, "POST1: factory vault impl");
        require(SyndicateFactory(b.factory).upgradesEnabled(), "POST1: vault upgrades disabled");
        _requireWiringKept(b);
    }

    function postPhase3(Book memory b, address newGame, address owner) public view {
        Deployed memory d = deployedAddresses(b);
        require(newGame == d.newGame, "POST3: not the phase-1 game");
        _requireImpls(b, d);
        _requireNewGame(b, newGame, owner);
        _requireRolesHeldBy(b, newGame);
        require(address(ChallengeGame(newGame).stakedWood()) == b.swood, "POST3: new game sWOOD");
        require(IV1Live(b.ledger).frozenCoverageCount() == 0, "POST3: a key is frozen");
        _requireWiringKept(b);
    }

    /// @dev §7 rows 1-2: the beacon and the registry proxy serve the v2 impls.
    function _requireImpls(Book memory b, Deployed memory d) internal view {
        require(GovernorBeacon(b.beacon).implementation() == d.govImpl, "POST: beacon impl");
        require(_registryImpl(b.registry) == d.regImpl, "POST: registry impl");
    }

    function _requireNewGame(Book memory b, address game, address owner) internal view {
        ChallengeGame g = ChallengeGame(game);
        require(g.owner() == owner, "new game: owner");
        require(address(g.wood()) == b.wood, "new game: WOOD");
        require(address(g.exposureLedger()) == b.ledger, "new game: ledger");
        require(address(g.tierRegistry()) == b.tierRegistry, "new game: tier registry");
        require(g.challengeWindow() == IV1Live(b.oldGame).challengeWindow(), "new game: window != old game");
        require(g.challengeWindow() == IV1Live(b.ledger).challengeWindow(), "new game: window != ledger");
    }

    function _requireRolesHeldBy(Book memory b, address game) internal view {
        require(IV1Live(b.swood).authorizedSlasher() == game, "roles: sWOOD slasher");
        require(IV1Live(b.tierRegistry).authorizedDemoter() == game, "roles: tier demoter");
        require(IV1Live(b.ledger).coverageFreezer() == game, "roles: ledger freezer");
    }

    /// @dev §6/§7: the ledger and escrow are kept everywhere, and every governor points at the factory's wiring.
    function _requireWiringKept(Book memory b) internal view {
        SyndicateFactory f = SyndicateFactory(b.factory);
        require(f.exposureLedger() == b.ledger && f.bondEscrow() == b.escrow, "wiring: factory ledger/escrow");
        require(IV1Live(b.swood).exposureLedger() == b.ledger, "wiring: sWOOD ledger");
        require(address(GuardianRegistry(b.registry).exposureLedger()) == b.ledger, "wiring: registry ledger");
        uint256 n = f.syndicateCount();
        for (uint256 s = 1; s <= n; s++) {
            (, address vault,,,,,) = f.syndicates(s);
            ISyndicateGovernor gov = ISyndicateGovernor(f.governorOf(vault));
            require(
                gov.exposureLedger() == b.ledger && gov.bondEscrow() == b.escrow
                    && gov.tierRegistry() == f.tierRegistry(),
                "wiring: governor"
            );
        }
    }

    // ── Inputs ──

    /// @notice Every address from `chains/4663.json`; the chain id is checked before any read.
    function book() public view returns (Book memory b) {
        require(block.chainid == RobinhoodParams.MAINNET_CHAIN_ID, "not Robinhood mainnet (4663)");
        b.factory = _readAddress("SYNDICATE_FACTORY");
        b.beacon = _readAddress("GOVERNOR_BEACON");
        b.registry = _readAddress("GUARDIAN_REGISTRY");
        b.tierRegistry = _readAddress("TIER_REGISTRY");
        b.swood = _readAddress("STAKED_WOOD");
        b.ledger = _readAddress("EXPOSURE_LEDGER");
        b.escrow = _readAddress("PROPOSER_BOND_ESCROW");
        b.oldGame = _readAddress("CHALLENGE_GAME");
        b.court = _readAddress("TOKEN_COURT");
        b.strategyFactory = _readAddress("STRATEGY_FACTORY");
        b.create3 = _readAddress("CREATE3_FACTORY");
        b.wood = _readAddress("WOOD_TOKEN");
    }

    function newGameAddress(Book memory b) public view returns (address) {
        return Create3Factory(b.create3).addressOf(GAME_SALT);
    }

    /// @notice Every phase-1 address is CREATE3, so it is known before, during and after the broadcast.
    function deployedAddresses(Book memory b) public view returns (Deployed memory d) {
        Create3Factory c3 = Create3Factory(b.create3);
        d.govImpl = c3.addressOf(GOVERNOR_IMPL_SALT);
        d.regImpl = c3.addressOf(REGISTRY_IMPL_SALT);
        d.vaultImpl = c3.addressOf(VAULT_IMPL_SALT);
        d.newGame = c3.addressOf(GAME_SALT);
    }

    function _deployOnce(Book memory b, bytes32 salt, bytes memory initcode) internal {
        address target = Create3Factory(b.create3).addressOf(salt);
        if (target.code.length != 0) return;
        require(Create3Factory(b.create3).deploy(salt, initcode) == target, "PHASE1: CREATE3 address drift");
    }

    /// @dev Global precondition of runbook §3: `owner()` (not `pendingOwner()`) is the caller everywhere.
    function _requireOwners(Book memory b, address owner) internal view {
        require(owner != address(0), "owner unset");
        _requireOwner("SyndicateFactory", b.factory, owner);
        _requireOwner("GovernorBeacon", b.beacon, owner);
        _requireOwner("GuardianRegistry", b.registry, owner);
        _requireOwner("TierRegistry", b.tierRegistry, owner);
        _requireOwner("StakedWood", b.swood, owner);
        _requireOwner("ExposureLedger", b.ledger, owner);
        _requireOwner("ChallengeGame (old)", b.oldGame, owner);
        _requireOwner("TokenCourt", b.court, owner);
        _requireOwner("StrategyFactory", b.strategyFactory, owner);
        _requireOwner("Create3Factory", b.create3, owner);
    }

    /// @dev A book already edited to the v2 game would make every old-game check read the new game.
    function _requireBookNamesOldGame(Book memory b) internal view {
        require(b.oldGame != newGameAddress(b), "book CHALLENGE_GAME already points at the v2 game");
    }

    function _requireOwner(string memory label, address target, address owner) internal view {
        require(IV1Live(target).owner() == owner, string.concat("PREFLIGHT: ", label, " owner is not the caller"));
    }

    function _registryImpl(address registry) internal view returns (address) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(vm.load(registry, IMPL_SLOT))));
    }

    function _registrySnapshot(address registry) internal view returns (RegistrySnapshot memory) {
        GuardianRegistry r = GuardianRegistry(registry);
        return RegistrySnapshot({
            owner: r.owner(),
            factory: r.factory(),
            swood: address(r.swood()),
            ledger: address(r.exposureLedger()),
            reviewPeriod: r.reviewPeriod(),
            blockQuorumBps: r.blockQuorumBps()
        });
    }
}
