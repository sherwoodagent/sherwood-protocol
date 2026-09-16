// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ProposerBondEscrow} from "../../src/ProposerBondEscrow.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice Shared protocol deployment plumbing. Suites choose only the components
/// they need; focused unit tests can still supply mocks and custom init parameters.
/// @dev No implicit setUp, funding, deposits, guardian maturation or time travel.
/// `_deployProtocol` is the complete default: real protocol contracts, a real
/// factory-created syndicate and owner bond. Only external tokens, identity and
/// price feeds are mocks. Individual helpers preserve custom suite economics.
abstract contract ProtocolFixture is Test {
    struct ProtocolDeployment {
        ERC20Mock asset;
        ERC20Mock wood;
        MockAgentRegistry agentRegistry;
        BatchExecutorLib executor;
        ProtocolConfig config;
        SyndicateFactory factory;
        GovernorBeacon beacon;
        StakedWood swood;
        GuardianRegistry registry;
        TierRegistry tiers;
        StrategyFactory strategies;
        ExposureLedger ledger;
        ProposerBondEscrow escrow;
        ChallengeGame game;
        TokenCourt court;
        SyndicateVault vault;
        SyndicateGovernor governor;
    }

    function _deployVault(ISyndicateVault.InitParams memory params) internal returns (SyndicateVault) {
        return SyndicateVault(
            payable(address(
                    new ERC1967Proxy(address(new SyndicateVault()), abi.encodeCall(SyndicateVault.initialize, (params)))
                ))
        );
    }

    function _deployStakedWood(StakedWood.InitParams memory params) internal returns (StakedWood) {
        return StakedWood(
            address(new ERC1967Proxy(address(new StakedWood()), abi.encodeCall(StakedWood.initialize, (params))))
        );
    }

    function _deployFactory(SyndicateFactory.InitParams memory params) internal returns (SyndicateFactory) {
        return SyndicateFactory(
            address(
                new ERC1967Proxy(address(new SyndicateFactory()), abi.encodeCall(SyndicateFactory.initialize, (params)))
            )
        );
    }

    /// @dev Calldata stays at the call site so suites retain their exact governor
    /// parameters and can choose real or mocked registry dependencies.
    function _deployGovernor(bytes memory initData) internal returns (SyndicateGovernor) {
        return SyndicateGovernor(address(new ERC1967Proxy(address(new SyndicateGovernor(24 hours, 1 hours)), initData)));
    }

    function _deployRegistry(bytes memory initData) internal returns (GuardianRegistry) {
        return GuardianRegistry(address(new ERC1967Proxy(address(new GuardianRegistry(6 hours)), initData)));
    }

    function _wireChallengeGame(
        address owner_,
        address ledgerOwner_,
        StakedWood swood_,
        ExposureLedger ledger_,
        TierRegistry tiers_,
        ChallengeGame game_
    ) internal {
        vm.prank(ledgerOwner_);
        ledger_.setCoverageFreezer(address(game_));
        vm.prank(tiers_.owner());
        tiers_.setAuthorizedDemoter(address(game_));
        vm.startPrank(owner_);
        swood_.setAuthorizedSlasher(address(game_));
        game_.setStakedWood(address(swood_));
        vm.stopPrank();
    }

    function _wireTokenCourt(address owner_, StakedWood swood_, ChallengeGame game_, TokenCourt court_) internal {
        vm.startPrank(owner_);
        court_.setChallengeGame(address(game_));
        court_.setStakedWood(address(swood_));
        game_.setCourt(address(court_));
        vm.stopPrank();
    }

    function _deployProtocol(address owner_) internal returns (ProtocolDeployment memory p) {
        p.asset = new ERC20Mock("USD Coin", "USDC", 6);
        p.wood = new ERC20Mock("Sherwood", "WOOD", 18);
        p.agentRegistry = new MockAgentRegistry();
        p.executor = new BatchExecutorLib();
        p.config = new ProtocolConfig(owner_);
        p.beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner_);
        p.tiers = new TierRegistry(owner_);
        // Resolve the factory/registry cycle before initializing either consumer.
        // All initialization happens atomically within this fixture invocation.
        p.factory = SyndicateFactory(address(new ERC1967Proxy(address(new SyndicateFactory()), "")));
        p.swood = _deployStakedWood(
            StakedWood.InitParams({
                owner: owner_,
                wood: address(p.wood),
                factory: address(p.factory),
                minGuardianStake: 10_000e18,
                coolDownPeriod: 45 days,
                minOwnerStake: 10_000e18,
                minSlashBps: 1000,
                maxSlashBps: 10_000,
                ageFloorBps: 2500,
                maturationPeriod: 30 days
            })
        );
        p.registry = _deployRegistry(
            abi.encodeCall(GuardianRegistry.initialize, (owner_, address(p.factory), address(p.swood), 24 hours, 3000))
        );
        p.factory
            .initialize(
                SyndicateFactory.InitParams({
                    owner: owner_,
                    executorImpl: address(p.executor),
                    vaultImpl: address(new SyndicateVault()),
                    ensRegistrar: address(0),
                    agentRegistry: address(p.agentRegistry),
                    beacon: address(p.beacon),
                    protocolConfig: address(p.config),
                    managementFeeBps: 0,
                    guardianRegistry: address(p.registry),
                    tierRegistry: address(p.tiers)
                })
            );
        p.strategies = new StrategyFactory(address(p.factory), owner_);
        p.ledger = new ExposureLedger(owner_, address(p.swood), 28 days);
        p.escrow = new ProposerBondEscrow(address(p.wood), address(p.registry), address(p.ledger));
        p.game = new ChallengeGame(owner_, address(p.wood), address(p.ledger), address(p.tiers));
        p.court = new TokenCourt(owner_);
        MockAggregatorV3 woodFeed = new MockAggregatorV3(8, 0.05e8);
        MockAggregatorV3 assetFeed = new MockAggregatorV3(8, 1e8);
        vm.startPrank(owner_);
        p.swood.setRegistry(address(p.registry));
        p.swood.setExposureLedger(address(p.ledger));
        p.tiers.setStrategyFactory(address(p.strategies));
        p.ledger.setWoodUsdPrice(0.1e8);
        p.ledger.setWoodFeed(address(woodFeed), 365 days);
        p.ledger.setAssetFeed(address(p.asset), address(assetFeed), 365 days);
        p.ledger.setCoveredTvlCapUsd(10_000_000e18);
        p.ledger.setGuardianRegistry(address(p.registry));
        p.registry.setExposureLedger(address(p.ledger));
        p.factory.setExposureLedger(address(p.ledger));
        p.factory.setBondEscrow(address(p.escrow));
        vm.stopPrank();
        _wireChallengeGame(owner_, owner_, p.swood, p.ledger, p.tiers, p.game);
        _wireTokenCourt(owner_, p.swood, p.game, p.court);

        uint256 agentId = p.agentRegistry.mint(owner_);
        uint256 ownerBond = p.swood.minOwnerStake();
        p.wood.mint(owner_, ownerBond);
        vm.startPrank(owner_);
        p.wood.approve(address(p.swood), ownerBond);
        p.swood.prepareOwnerStake(ownerBond);
        (, address vault_) = p.factory
            .createSyndicate(
                agentId,
                SyndicateFactory.SyndicateConfig({
                    metadataURI: "ipfs://protocol-fixture",
                    asset: p.asset,
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    openDeposits: true,
                    subdomain: "fixture"
                })
            );
        vm.stopPrank();
        p.vault = SyndicateVault(payable(vault_));
        p.governor = SyndicateGovernor(p.factory.governorOf(vault_));
    }
}
