// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {DeployAll, Checkpoint, Stage} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {DeploySalts} from "../../script/DeploySalts.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";
import {Create3} from "../../script/utils/Create3.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

/// @notice `DeployAll` is concrete; this only reaches the pre-flight `run()` would.
contract DeployAllForkHarness is DeployAll {
    function exposed_preflight(Inputs memory i) external view {
        _preflight(i);
    }
}

/**
 * @notice The whole ceremony against a fork of Robinhood Chain mainnet: the CREATE2
 *         deployer, the Uniswap position manager, Morpho and the Chainlink feeds are the
 *         LIVE contracts, not mocks. Those identity pre-flights are exercised nowhere else.
 *
 * @dev    Fork posture at chain id 9994663 (the Tenderly-vnet id the fork book uses), for
 *         two reasons: the pools stop trading at the fork point, so the mainnet WoodPoolFeed
 *         would refuse its own idle-pair pre-flight, and `ForkWoodFeedFixture` refuses 4663
 *         outright. The fixture's price is still DERIVED from the fork's own reserves.
 * @dev    Skips without ROBINHOOD_RPC_URL (shared fork-test convention). UNPINNED BY NECESSITY:
 *         the public RPC serves roughly the last thousand blocks (measured 2026-09-16), so a pinned
 *         constant would go stale within the hour; ROBINHOOD_FORK_BLOCK pins it on an archive node.
 *         The run therefore PRINTS its fork block, and every assertion below is price-independent.
 */
contract DeployAllForkTest is Test {
    uint256 internal constant FORK_CHAIN_ID = 9_994_663;

    DeployAllForkHarness internal script;
    address internal deployer;
    string internal book;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        // Two runs of this file at the same commit read different live prices; without this line
        // the reading they disagreed on cannot be traced back to the state it came from.
        console2.log("fork block:", block.number);

        book = vm.readFile(string.concat(vm.projectRoot(), "/chains/", vm.toString(FORK_CHAIN_ID), ".json"));
        // The fork carries 4663's state under the fork book's chain id.
        vm.chainId(FORK_CHAIN_ID);

        script = new DeployAllForkHarness();
        // `_c3Factory` bootstraps the CREATE3 factory at `msg.sender` and `c3.deploy` is
        // `onlyOwner`, called by the script itself — so the deployer must BE the script.
        deployer = address(script);
    }

    /// @notice One Fork-posture run mints the whole stack at its predicted addresses.
    function test_fork_deployAllAgainstLiveRobinhoodState() public {
        Inputs memory i = _inputs();

        // The live half: CREATE2 deployer present, the position manager is really Uniswap's
        // and names the book's factory, Morpho holds code.
        script.exposed_preflight(i);

        vm.prank(deployer);
        (Stack memory s, Checkpoint cp) = script.deployAll(i);

        assertTrue(cp == Checkpoint.Complete, "one run completes a fork ceremony");
        _assertAddressTable(s);
        _assertCoreWiring(s, i);
        _assertLaunchSet(s, i);
        _assertStrategyFactory(s);
        _assertCoverageStack(s);
        _assertVerdictPath(s);

        // A fork owns itself: the handoff runs and is a no-op.
        assertEq(Ownable(s.core.beacon).owner(), deployer, "beacon.owner");
        assertEq(Ownable(s.core.factoryProxy).owner(), deployer, "factory.owner");
        assertEq(Ownable(s.core.registryProxy).owner(), deployer, "registry.owner");
        assertEq(Ownable(s.core.swoodProxy).owner(), deployer, "swood.owner");
        assertEq(Ownable(s.strategyFactory).owner(), deployer, "strategyFactory.owner");
        assertEq(Ownable2Step(s.exposureLedger).pendingOwner(), address(0), "ledger.pendingOwner");
        assertTrue(script.stageOf(s, deployer) == Stage.Done, "stageOf == Done");
    }

    // ── Inputs, all from the committed fork book ──

    function _inputs() internal view returns (Inputs memory i) {
        i.posture = Posture.Fork;
        i.deployer = deployer;
        i.ownerMultisig = deployer;
        i.wood = _bookAddr("WOOD_TOKEN");
        i.weth = _bookAddr("WETH");
        i.usdg = _bookAddr("USDG");
        i.usdgFeed = _bookAddr("CHAINLINK_USDG_USD_FEED");
        i.ethUsdFeed = _bookAddr("CHAINLINK_ETH_USD_FEED");
        i.uniswapV3Factory = _bookAddr("UNISWAP_V3_FACTORY");
        i.uniswapV3PositionManager = _bookAddr("UNISWAP_V3_POSITION_MANAGER");
        i.uniswapSwapRouter = _bookAddr("UNISWAP_SWAP_ROUTER");
        i.uniswapQuoterV2 = _bookAddr("UNISWAP_QUOTER_V2");
        i.uniswapV4PoolManager = _bookAddr("UNISWAP_V4_POOL_MANAGER");
        i.uniswapV4Quoter = _bookAddr("UNISWAP_V4_QUOTER");
        i.morphoBlue = _bookAddr("MORPHO_BLUE");
        i.woodWethV2Pair = _bookAddr("WOOD_WETH_V2_PAIR");
        // Only the mainnet WoodPoolFeed reads a second pair; the fork fixture prices off
        // `woodWethV2Pair` alone, and 4663 has no second WOOD/WETH pair to name.
        i.woodWethSushiV2Pair = i.woodWethV2Pair;
    }

    function _bookAddr(string memory key) internal view returns (address) {
        return vm.parseJsonAddress(book, string.concat(".", key));
    }

    // ── Read set ──

    /// @dev Every address is `f(create3Factory, salt)` and every one of them holds code.
    function _assertAddressTable(Stack memory s) internal view {
        address c3 = s.create3Factory;
        _pin(Create3.addressOf(c3, DeploySalts.EXECUTOR), s.core.executorLib, "executorLib");
        _pin(Create3.addressOf(c3, DeploySalts.VAULT_IMPL), s.core.vaultImpl, "vaultImpl");
        _pin(Create3.addressOf(c3, DeploySalts.PROTOCOL_CONFIG), s.core.protocolConfig, "protocolConfig");
        _pin(Create3.addressOf(c3, DeploySalts.GOVERNOR_BEACON), s.core.beacon, "beacon");
        _pin(Create3.addressOf(c3, DeploySalts.SWOOD_PROXY), s.core.swoodProxy, "swoodProxy");
        _pin(Create3.addressOf(c3, DeploySalts.REGISTRY_PROXY), s.core.registryProxy, "registryProxy");
        _pin(Create3.addressOf(c3, DeploySalts.TIER_REGISTRY), s.core.tierRegistry, "tierRegistry");
        _pin(Create3.addressOf(c3, DeploySalts.FACTORY_PROXY), s.core.factoryProxy, "factoryProxy");
        _pin(Create3.addressOf(c3, DeploySalts.UNISWAP_SWAP_ADAPTER), s.uniswapSwapAdapter, "swap adapter");
        _pin(Create3.addressOf(c3, DeploySalts.PORTFOLIO_TEMPLATE), s.portfolioTemplate, "portfolio template");
        _pin(Create3.addressOf(c3, DeploySalts.MORPHO_SUPPLY_TEMPLATE), s.morphoSupplyTemplate, "morpho template");
        _pin(Create3.addressOf(c3, DeploySalts.CL_TEMPLATE), s.concentratedLiquidityTemplate, "CL template");
        _pin(Create3.addressOf(c3, DeploySalts.STRATEGY_FACTORY), s.strategyFactory, "strategy factory");
        // The FORK salt, never the mainnet one: a fork book cannot carry a mainnet feed.
        _pin(Create3.addressOf(c3, DeploySalts.FORK_WOOD_FEED), s.woodUsdFeed, "fork wood feed");
        _pin(Create3.addressOf(c3, DeploySalts.EXPOSURE_LEDGER), s.exposureLedger, "ledger");
        _pin(Create3.addressOf(c3, DeploySalts.PROPOSER_BOND_ESCROW), s.proposerBondEscrow, "escrow");
        _pin(Create3.addressOf(c3, DeploySalts.CHALLENGE_GAME), s.challengeGame, "game");
        _pin(Create3.addressOf(c3, DeploySalts.TOKEN_COURT), s.tokenCourt, "court");
    }

    function _pin(address predicted, address deployed, string memory what) internal view {
        assertEq(deployed, predicted, what);
        assertGt(deployed.code.length, 0, string.concat(what, " holds code"));
    }

    function _assertCoreWiring(Stack memory s, Inputs memory i) internal view {
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertEq(address(factory.tierRegistry()), s.core.tierRegistry, "factory.tierRegistry");
        assertEq(address(factory.guardianRegistry()), s.core.registryProxy, "factory.guardianRegistry");
        assertEq(factory.beacon(), s.core.beacon, "factory.beacon");
        assertEq(factory.protocolConfig(), s.core.protocolConfig, "factory.protocolConfig");
        // v1 ships with identity gating off, so both registrars are deliberately zero.
        assertEq(address(factory.ensRegistrar()), address(0), "factory.ensRegistrar");
        assertEq(address(factory.agentRegistry()), address(0), "factory.agentRegistry");
        assertEq(StakedWood(s.core.swoodProxy).registry(), s.core.registryProxy, "swood.registry");
        assertEq(address(StakedWood(s.core.swoodProxy).wood()), i.wood, "swood.wood is the live WOOD");
    }

    /// @dev The live counterparties every strategy binds through.
    function _assertLaunchSet(Stack memory s, Inputs memory i) internal view {
        TierRegistry tr = TierRegistry(s.core.tierRegistry);
        assertTrue(tr.isCounterpartyAllowed(i.uniswapV3Factory), "uniswap v3 factory attested");
        assertTrue(tr.isCounterpartyAllowed(i.uniswapV3PositionManager), "position manager attested");
        assertTrue(tr.isCounterpartyAllowed(i.morphoBlue), "morpho attested");
        assertTrue(tr.isCounterpartyAllowed(s.uniswapSwapAdapter), "swap adapter attested");

        address tslaFeed = _bookAddr("CHAINLINK_TSLA_USD_FEED");
        assertTrue(tr.isCounterpartyAllowed(tslaFeed), "TSLA feed allowlisted");
        assertTrue(
            tr.isPriceSourceForToken(_bookAddr("TSLA"), bytes32(uint256(uint160(tslaFeed)))), "TSLA paired bare-bytes32"
        );
    }

    function _assertStrategyFactory(Stack memory s) internal view {
        StrategyFactory sf = StrategyFactory(s.strategyFactory);
        assertTrue(sf.approvedTemplate(s.portfolioTemplate), "portfolio approved");
        assertTrue(sf.approvedTemplate(s.morphoSupplyTemplate), "morpho approved");
        assertTrue(sf.approvedTemplate(s.concentratedLiquidityTemplate), "CL approved");
        assertEq(TierRegistry(s.core.tierRegistry).strategyFactory(), s.strategyFactory, "tierRegistry wiring");
    }

    function _assertCoverageStack(Stack memory s) internal view {
        ExposureLedger ledger = ExposureLedger(s.exposureLedger);
        assertEq(StakedWood(s.core.swoodProxy).exposureLedger(), s.exposureLedger, "swood exit gate");
        assertEq(
            address(IGuardianRegistry(s.core.registryProxy).exposureLedger()), s.exposureLedger, "registry books here"
        );
        assertEq(SyndicateFactory(s.core.factoryProxy).exposureLedger(), s.exposureLedger, "factory issues here");
        assertEq(SyndicateFactory(s.core.factoryProxy).bondEscrow(), s.proposerBondEscrow, "bond escrow");
        assertEq(ledger.woodHaircutBps(), RobinhoodParams.WOOD_HAIRCUT_BPS, "haircut");
        // Priced off the FORK's own reserves x the live ETH/USD feed — never an invented number.
        assertGt(ledger.woodPriceX8(), 0, "WOOD is priceable");
        console2.log("fork WOOD/USD x8 (haircut applied):", ledger.woodPriceX8());
        // The cap a fork seats is derived from its OWN spot, so it clears the same [1.25x, 2x]
        // band Mainnet is pre-flighted against instead of shipping a cap Mainnet would refuse.
        assertEq(ledger.woodUsdPriceX8(), s.woodPriceCapX8, "the seated cap is the derived one");
        assertGt(s.woodPriceCapX8, 0, "a fork must derive a cap, not leave it zero");
        assertEq(
            ProtocolConfig(s.core.protocolConfig).maxStrategyDuration(),
            RobinhoodParams.MAX_STRATEGY_DURATION,
            "strategy-duration ceiling"
        );
    }

    function _assertVerdictPath(Stack memory s) internal view {
        assertEq(ExposureLedger(s.exposureLedger).coverageFreezer(), s.challengeGame, "coverageFreezer");
        assertEq(TierRegistry(s.core.tierRegistry).authorizedDemoter(), s.challengeGame, "authorizedDemoter");
        assertEq(StakedWood(s.core.swoodProxy).authorizedSlasher(), s.challengeGame, "authorizedSlasher");
        assertEq(ChallengeGame(s.challengeGame).court(), s.tokenCourt, "game.court");
        assertEq(TokenCourt(s.tokenCourt).challengeGame(), s.challengeGame, "court.challengeGame");
        assertEq(TokenCourt(s.tokenCourt).stakedWood(), s.core.swoodProxy, "court.stakedWood");
    }
}
