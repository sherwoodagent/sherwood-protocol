// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {DeployAll, Checkpoint, Stage} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {DeploySalts} from "../../script/DeploySalts.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";
import {Create3} from "../../script/utils/Create3.sol";
import {Create3Factory} from "../../script/utils/Create3Factory.sol";
import {WoodPoolFeed} from "../../src/pricing/WoodPoolFeed.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {MockUniswapV2Pair} from "../mocks/MockUniswapV2Pair.sol";
import {MockPositionManager} from "../mocks/MockPositionManager.sol";

/// @notice `DeployAll` is concrete; this only reaches the internals `run()` would.
contract DeployAllHarness is DeployAll {
    function exposed_c3Factory(address deployer) external returns (address) {
        return address(_c3Factory(deployer));
    }

    function exposed_predictAll(address c3, Posture posture) external pure returns (Stack memory) {
        return _predictAll(Create3Factory(c3), posture);
    }

    function exposed_preflight(Inputs memory i) external view {
        _preflight(i);
    }

    function exposed_validateAll(Stack memory s, Inputs memory i, Checkpoint cp) external view {
        _validateAll(s, i, cp);
    }

    function exposed_handoffAll(Stack memory s, address ownerMultisig) external {
        _handoffAll(s, ownerMultisig);
    }
}

/// @notice A Safe stand-in: `OWNER_MULTISIG` must hold code, and the two-step half of the
///         handoff needs something that can call `acceptOwnership`.
contract CeremonySafe {
    function accept(address target) external {
        Ownable2Step(target).acceptOwnership();
    }
}

/**
 * @notice The ceremony fixture every DeployAll-driven suite shares: mock externals, an
 *         `Inputs` for either posture, and the market chores a second run needs.
 *
 * @dev    NO ADDRESS BOOK IS WRITTEN. `deployAll` reads none — only `_seedTierRegistry`
 *         does, off the COMMITTED book for the chain id under test (4663 for Mainnet,
 *         9994663 for Fork). The one external that must be the book's own address is
 *         `UNISWAP_V3_FACTORY`: the launch set allowlists the book's value and the CL
 *         phase vouches `Inputs.uniswapV3Factory` against that allowlist.
 *
 * @dev    Every ceremony call is `vm.prank(deployer)` with `deployer == address(script)`:
 *         `_c3Factory` bootstraps the CREATE3 factory at `msg.sender` and `c3.deploy` is
 *         `onlyOwner`, called by the script contract itself.
 */
abstract contract DeployAllFixture is Test {
    /// @dev Arachnid deterministic-deployment-proxy runtime; etched only when the EVM lacks it.
    bytes internal constant CREATE2_DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    uint256 internal constant FORK_CHAIN_ID = 9_994_663;
    uint256 internal constant MAINNET_CHAIN_ID = RobinhoodParams.MAINNET_CHAIN_ID;

    // WOOD/WETH = 1e-4 against ETH at $3,000 puts spot at 3e7 x8 ($0.30), so the shipped
    // WOOD_PRICE_CAP_X8 (5e7) lands at 1.67x spot — inside the pre-flight's [1.25x, 2x] band.
    uint112 internal constant WETH_RESERVE = 100e18;
    uint112 internal constant WOOD_RESERVE = 1_000_000e18;
    int256 internal constant ETH_USD_X8 = 3000e8;

    DeployAllHarness internal script;
    address internal deployer;
    CeremonySafe internal safe;

    ERC20Mock internal wood;
    ERC20Mock internal weth;
    ERC20Mock internal usdg;
    MockUniswapV2Pair internal uniPair;
    MockUniswapV2Pair internal sushiPair;
    MockAggregatorV3 internal ethUsdFeed;
    MockAggregatorV3 internal usdgFeed;
    MockPositionManager internal positionManager;

    /// @dev The book's own Uniswap V3 factory — see the contract-level note.
    address internal uniswapV3Factory;
    address internal morphoBlue;

    function _stageCeremony() internal {
        vm.warp(1_700_000_000);
        if (RobinhoodParams.CREATE2_DEPLOYER.code.length == 0) {
            vm.etch(RobinhoodParams.CREATE2_DEPLOYER, CREATE2_DEPLOYER_RUNTIME);
        }

        script = new DeployAllHarness();
        deployer = address(script);
        safe = new CeremonySafe();

        wood = new ERC20Mock("WOOD", "WOOD", 18);
        weth = new ERC20Mock("WETH", "WETH", 18);
        usdg = new ERC20Mock("USDG", "USDG", 6);
        uniPair = new MockUniswapV2Pair(address(wood), address(weth), WOOD_RESERVE, WETH_RESERVE);
        sushiPair = new MockUniswapV2Pair(address(weth), address(wood), WETH_RESERVE, WOOD_RESERVE);
        ethUsdFeed = new MockAggregatorV3(8, ETH_USD_X8);
        usdgFeed = new MockAggregatorV3(8, 1e8);

        uniswapV3Factory = _bookAddr("UNISWAP_V3_FACTORY");
        morphoBlue = _bookAddr("MORPHO_BLUE");
        // Identity, not behaviour: both are only probed for code, and the position manager
        // must name this exact factory.
        vm.etch(uniswapV3Factory, hex"600160005260206000f3");
        vm.etch(morphoBlue, hex"600160005260206000f3");
        positionManager = new MockPositionManager(uniswapV3Factory);
    }

    function _inputs(Posture posture) internal view returns (Inputs memory i) {
        i.posture = posture;
        i.deployer = deployer;
        i.ownerMultisig = posture == Posture.Mainnet ? address(safe) : address(0);
        i.wood = address(wood);
        i.weth = address(weth);
        i.usdg = address(usdg);
        i.usdgFeed = address(usdgFeed);
        i.ethUsdFeed = address(ethUsdFeed);
        i.uniswapV3Factory = uniswapV3Factory;
        i.uniswapV3PositionManager = address(positionManager);
        i.uniswapSwapRouter = _bookAddr("UNISWAP_SWAP_ROUTER");
        i.uniswapQuoterV2 = _bookAddr("UNISWAP_QUOTER_V2");
        i.uniswapV4PoolManager = _bookAddr("UNISWAP_V4_POOL_MANAGER");
        i.uniswapV4Quoter = _bookAddr("UNISWAP_V4_QUOTER");
        i.morphoBlue = morphoBlue;
        i.woodWethV2Pair = address(uniPair);
        i.woodWethSushiV2Pair = address(sushiPair);
    }

    function _runCeremony(Posture posture) internal returns (Stack memory s, Checkpoint cp) {
        Inputs memory i = _inputs(posture);
        vm.prank(deployer);
        (s, cp) = script.deployAll(i);
    }

    /// @dev What a keeper and a live market supply between two runs: both pools trading and
    ///      both Chainlink legs re-published.
    function _refreshMarkets() internal {
        uniPair.sync();
        sushiPair.sync();
        ethUsdFeed.setUpdatedAt(vm.getBlockTimestamp());
        usdgFeed.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @dev The keeper's whole job: one `update()` a full window after the baseline.
    function _primeWoodFeed(address feed) internal {
        vm.warp(vm.getBlockTimestamp() + RobinhoodParams.TWAP_WINDOW + 1);
        _refreshMarkets();
        WoodPoolFeed(feed).update();
    }

    function _bookAddr(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/chains/4663.json");
        return vm.parseJsonAddress(vm.readFile(path), string.concat(".", key));
    }

    function _create3FactoryAddress(address deployer_) internal pure returns (address) {
        bytes memory initcode = abi.encodePacked(type(Create3Factory).creationCode, abi.encode(deployer_));
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            RobinhoodParams.CREATE2_DEPLOYER,
                            DeploySalts.CREATE3_FACTORY,
                            keccak256(initcode)
                        )
                    )
                )
            )
        );
    }

    // ── Shared read-set assertions ──

    /// @dev Every address the ceremony reports is `f(create3Factory, salt)` and nothing else.
    function _assertAddressTable(Stack memory s, Posture posture) internal view {
        address c3 = s.create3Factory;
        assertEq(c3, _create3FactoryAddress(deployer), "create3 factory at its CREATE2 address");
        assertEq(s.core.executorLib, Create3.addressOf(c3, DeploySalts.EXECUTOR), "executorLib");
        assertEq(s.core.vaultImpl, Create3.addressOf(c3, DeploySalts.VAULT_IMPL), "vaultImpl");
        assertEq(s.core.protocolConfig, Create3.addressOf(c3, DeploySalts.PROTOCOL_CONFIG), "protocolConfig");
        assertEq(s.core.beacon, Create3.addressOf(c3, DeploySalts.GOVERNOR_BEACON), "beacon");
        assertEq(s.core.swoodProxy, Create3.addressOf(c3, DeploySalts.SWOOD_PROXY), "swoodProxy");
        assertEq(s.core.registryProxy, Create3.addressOf(c3, DeploySalts.REGISTRY_PROXY), "registryProxy");
        assertEq(s.core.tierRegistry, Create3.addressOf(c3, DeploySalts.TIER_REGISTRY), "tierRegistry");
        assertEq(s.core.factoryProxy, Create3.addressOf(c3, DeploySalts.FACTORY_PROXY), "factoryProxy");
        assertEq(s.uniswapSwapAdapter, Create3.addressOf(c3, DeploySalts.UNISWAP_SWAP_ADAPTER), "swap adapter");
        assertEq(s.portfolioTemplate, Create3.addressOf(c3, DeploySalts.PORTFOLIO_TEMPLATE), "portfolio template");
        assertEq(s.morphoSupplyTemplate, Create3.addressOf(c3, DeploySalts.MORPHO_SUPPLY_TEMPLATE), "morpho template");
        assertEq(s.concentratedLiquidityTemplate, Create3.addressOf(c3, DeploySalts.CL_TEMPLATE), "CL template");
        assertEq(s.strategyFactory, Create3.addressOf(c3, DeploySalts.STRATEGY_FACTORY), "strategy factory");
        bytes32 feedSalt = posture == Posture.Mainnet ? DeploySalts.WOOD_USD_FEED : DeploySalts.FORK_WOOD_FEED;
        assertEq(s.woodUsdFeed, Create3.addressOf(c3, feedSalt), "wood feed");
        assertEq(s.exposureLedger, Create3.addressOf(c3, DeploySalts.EXPOSURE_LEDGER), "ledger");
        assertEq(s.proposerBondEscrow, Create3.addressOf(c3, DeploySalts.PROPOSER_BOND_ESCROW), "escrow");
        assertEq(s.challengeGame, Create3.addressOf(c3, DeploySalts.CHALLENGE_GAME), "game");
        assertEq(s.tokenCourt, Create3.addressOf(c3, DeploySalts.TOKEN_COURT), "court");
    }

    function _assertCoreWiring(Stack memory s) internal view {
        SyndicateFactory factory = SyndicateFactory(s.core.factoryProxy);
        assertEq(address(factory.tierRegistry()), s.core.tierRegistry, "factory.tierRegistry");
        assertEq(address(factory.guardianRegistry()), s.core.registryProxy, "factory.guardianRegistry");
        assertEq(factory.beacon(), s.core.beacon, "factory.beacon");
        assertEq(factory.protocolConfig(), s.core.protocolConfig, "factory.protocolConfig");
        assertEq(factory.managementFeeBps(), RobinhoodParams.MANAGEMENT_FEE_BPS, "factory.managementFeeBps");
        // v1 ships with identity gating off, so both registrars are deliberately zero.
        assertEq(address(factory.ensRegistrar()), address(0), "factory.ensRegistrar");
        assertEq(address(factory.agentRegistry()), address(0), "factory.agentRegistry");
        assertEq(StakedWood(s.core.swoodProxy).registry(), s.core.registryProxy, "swood.registry");
        assertEq(address(StakedWood(s.core.swoodProxy).wood()), address(wood), "swood.wood");
    }

    /// @dev The launch set is seeded from the BOOK, so both pins read the book's own values.
    ///      `priceSource` is the bare aggregator widened to bytes32 — any other encoding
    ///      produces an attestation `PortfolioStrategy._initialize` never consults.
    function _assertLaunchSet(Stack memory s) internal view {
        TierRegistry tr = TierRegistry(s.core.tierRegistry);
        assertTrue(tr.isCounterpartyAllowed(uniswapV3Factory), "uniswap v3 factory attested");
        assertTrue(tr.isCounterpartyAllowed(morphoBlue), "morpho attested");
        assertTrue(tr.isCounterpartyAllowed(s.uniswapSwapAdapter), "swap adapter attested");

        address tslaFeed = _bookAddr("CHAINLINK_TSLA_USD_FEED");
        assertTrue(tr.isCounterpartyAllowed(tslaFeed), "TSLA feed allowlisted");
        assertTrue(
            tr.isPriceSourceForToken(_bookAddr("TSLA"), bytes32(uint256(uint160(tslaFeed)))), "TSLA paired bare-bytes32"
        );
        // ETH's feed prices the WRAPPED token; the pairing key is WETH, not a bare "ETH".
        address ethFeed = _bookAddr("CHAINLINK_ETH_USD_FEED");
        assertTrue(
            tr.isPriceSourceForToken(_bookAddr("WETH"), bytes32(uint256(uint160(ethFeed)))), "ETH paired to WETH"
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
        assertEq(ledger.woodUsdPriceX8(), RobinhoodParams.WOOD_PRICE_CAP_X8, "price cap");
        assertEq(ledger.coveredTvlCapUsd(), RobinhoodParams.COVERED_TVL_CAP_USD18, "covered TVL cap");
        // The composed price is min(cap, market) haircut — non-zero is what makes a bond priceable.
        assertGt(ledger.woodPriceX8(), 0, "WOOD is priceable");
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
        assertEq(address(ChallengeGame(s.challengeGame).stakedWood()), s.core.swoodProxy, "game.stakedWood");
        assertEq(ChallengeGame(s.challengeGame).court(), s.tokenCourt, "game.court");
        assertEq(TokenCourt(s.tokenCourt).challengeGame(), s.challengeGame, "court.challengeGame");
        assertEq(TokenCourt(s.tokenCourt).stakedWood(), s.core.swoodProxy, "court.stakedWood");
    }

    /// @dev Fee recipients are SEEDED to the deployer on purpose: a zero recipient folds the
    ///      leg into the agent's remainder silently.
    function _assertFeeRecipients(Stack memory s) internal view {
        ProtocolConfig config = ProtocolConfig(s.core.protocolConfig);
        assertEq(config.protocolFeeRecipient(), deployer, "protocol fee recipient");
        assertEq(config.guardiansFeeRecipient(), deployer, "guardians fee recipient");
    }

    function _assertOneStepOwners(Stack memory s, address expected) internal view {
        assertEq(Ownable(s.core.beacon).owner(), expected, "beacon.owner");
        assertEq(Ownable(s.core.factoryProxy).owner(), expected, "factory.owner");
        assertEq(Ownable(s.core.registryProxy).owner(), expected, "registry.owner");
        assertEq(Ownable(s.core.swoodProxy).owner(), expected, "swood.owner");
        assertEq(Ownable(s.strategyFactory).owner(), expected, "strategyFactory.owner");
    }

    /// @dev A two-step transfer never moves `owner()`; only `pendingOwner()`.
    function _assertTwoStepPending(Stack memory s, address expected) internal view {
        assertEq(Ownable2Step(s.core.protocolConfig).pendingOwner(), expected, "protocolConfig.pendingOwner");
        assertEq(Ownable2Step(s.core.tierRegistry).pendingOwner(), expected, "tierRegistry.pendingOwner");
        assertEq(Ownable2Step(s.exposureLedger).pendingOwner(), expected, "ledger.pendingOwner");
        assertEq(Ownable2Step(s.challengeGame).pendingOwner(), expected, "game.pendingOwner");
        assertEq(Ownable2Step(s.tokenCourt).pendingOwner(), expected, "court.pendingOwner");
    }

    function _codehashes(Stack memory s) internal view returns (bytes32[19] memory h) {
        h[0] = s.create3Factory.codehash;
        h[1] = s.core.executorLib.codehash;
        h[2] = s.core.vaultImpl.codehash;
        h[3] = s.core.protocolConfig.codehash;
        h[4] = s.core.beacon.codehash;
        h[5] = s.core.swoodProxy.codehash;
        h[6] = s.core.registryProxy.codehash;
        h[7] = s.core.tierRegistry.codehash;
        h[8] = s.core.factoryProxy.codehash;
        h[9] = s.uniswapSwapAdapter.codehash;
        h[10] = s.portfolioTemplate.codehash;
        h[11] = s.morphoSupplyTemplate.codehash;
        h[12] = s.concentratedLiquidityTemplate.codehash;
        h[13] = s.strategyFactory.codehash;
        h[14] = s.woodUsdFeed.codehash;
        h[15] = s.exposureLedger.codehash;
        h[16] = s.proposerBondEscrow.codehash;
        h[17] = s.challengeGame.codehash;
        h[18] = s.tokenCourt.codehash;
    }
}

/// @notice The end-to-end ceremony: one `deployAll` per posture, against real contracts and
///         the committed launch set, with no environment variable and no address book write.
contract DeployAllTest is DeployAllFixture {
    function setUp() public {
        _stageCeremony();
    }

    // ── Case 1: fork posture, one run ──

    /// @notice A Fork-posture ceremony completes in ONE run and leaves every key with the deployer.
    function test_fork_oneRunMintsTheWholeStackAtItsPredictedAddresses() public {
        vm.chainId(FORK_CHAIN_ID);

        address c3 = script.exposed_c3Factory(deployer);
        Stack memory predicted = script.exposed_predictAll(c3, Posture.Fork);

        (Stack memory s, Checkpoint cp) = _runCeremony(Posture.Fork);

        assertTrue(cp == Checkpoint.Complete, "one run completes a fork ceremony");
        _assertAddressTable(s, Posture.Fork);
        // The prediction table is what lets a pointer slot be refused before its contract
        // exists, so a salt that drifts between prediction and phase has to be caught here.
        // `core.deployer` is the one field a prediction cannot carry: it is the broadcaster.
        predicted.core.deployer = deployer;
        assertEq(abi.encode(predicted), abi.encode(s), "predicted table == minted table");

        _assertCoreWiring(s);
        _assertLaunchSet(s);
        _assertStrategyFactory(s);
        _assertCoverageStack(s);
        _assertVerdictPath(s);
        _assertFeeRecipients(s);

        // Fork posture never hands off.
        _assertOneStepOwners(s, deployer);
        _assertTwoStepPending(s, address(0));
        assertEq(Ownable(s.core.protocolConfig).owner(), deployer, "protocolConfig.owner");
        assertEq(Ownable(s.exposureLedger).owner(), deployer, "ledger.owner");
        assertTrue(script.stageOf(s, deployer) == Stage.Done, "stageOf == Done");
    }

    // ── Case 2: mainnet posture, two runs across the feed gate ──

    /// @notice A Mainnet ceremony stops at the WOOD-feed gate, then completes and hands off.
    function test_mainnet_stopsAtTheFeedGateThenCompletesAndHandsOff() public {
        vm.chainId(MAINNET_CHAIN_ID);

        (Stack memory first, Checkpoint cp1) = _runCeremony(Posture.Mainnet);
        assertTrue(cp1 == Checkpoint.AwaitingWoodFeed, "run 1 stops at the gate");
        assertGt(first.woodUsdFeed.code.length, 0, "the feed was minted");
        assertEq(first.exposureLedger.code.length, 0, "no ledger before WOOD can be priced");
        assertEq(first.challengeGame.code.length, 0, "no game either");
        assertEq(first.tokenCourt.code.length, 0, "no court either");
        // The deployer must keep every key until run 2: nothing may be armed yet.
        assertEq(Ownable2Step(first.core.protocolConfig).pendingOwner(), address(0), "config not armed");
        assertEq(Ownable2Step(first.core.tierRegistry).pendingOwner(), address(0), "registry not armed");
        _assertOneStepOwners(first, deployer);
        Inputs memory i = _inputs(Posture.Mainnet);
        script.exposed_validateAll(first, i, Checkpoint.AwaitingWoodFeed);

        _primeWoodFeed(first.woodUsdFeed);

        (Stack memory s, Checkpoint cp2) = _runCeremony(Posture.Mainnet);
        assertTrue(cp2 == Checkpoint.Complete, "run 2 completes");
        assertEq(s.core.factoryProxy, first.core.factoryProxy, "run 2 adopts run 1's core");
        _assertAddressTable(s, Posture.Mainnet);
        _assertCoverageStack(s);
        _assertVerdictPath(s);

        _assertOneStepOwners(s, address(safe));
        _assertTwoStepPending(s, address(safe));
        script.exposed_validateAll(s, i, Checkpoint.Complete);
        assertTrue(script.stageOf(s, address(safe)) == Stage.Done, "stageOf == Done");
    }

    // ── Case 3: idempotency ──

    /// @notice A resumed run mints nothing, writes nothing and returns the same table.
    function test_fork_resumedRunMintsNothingAndSendsNoStateChangingCall() public {
        vm.chainId(FORK_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Fork);
        bytes32[19] memory before = _codehashes(first);

        vm.recordLogs();
        (Stack memory second, Checkpoint cp) = _runCeremony(Posture.Fork);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(cp == Checkpoint.Complete, "the resumed run still reports Complete");
        assertEq(abi.encode(second), abi.encode(first), "the same table");
        bytes32[19] memory later = _codehashes(second);
        for (uint256 n; n < before.length; ++n) {
            assertEq(later[n], before[n], "nothing was re-minted");
        }
        // Every mint is skip-if-code and every write is guarded on the value already there,
        // so a second run emits no event at all.
        assertEq(logs.length, 0, "a resumed run sends no state-changing call");
    }

    // ── Case 4: resume, stage by stage ──

    /// @notice `stageOf` names the next phase at every boundary a resumed ceremony can land on.
    function test_mainnet_stageOfNamesTheNextPhaseAtEveryBoundary() public {
        vm.chainId(MAINNET_CHAIN_ID);

        address c3 = script.exposed_c3Factory(deployer);
        Stack memory predicted = script.exposed_predictAll(c3, Posture.Mainnet);
        assertTrue(script.stageOf(predicted, deployer) == Stage.Core, "nothing minted yet");

        uint256 snap = vm.snapshotState();

        (Stack memory s,) = _runCeremony(Posture.Mainnet);
        assertTrue(script.stageOf(s, deployer) == Stage.WaitingForFeed, "minted but unprimed");
        _primeWoodFeed(s.woodUsdFeed);
        assertTrue(script.stageOf(s, deployer) == Stage.PlanB, "primed, coverage still missing");

        (Stack memory done,) = _runCeremony(Posture.Mainnet);
        assertTrue(script.stageOf(done, address(safe)) == Stage.Done, "finished");

        // Reverting to before run 1 puts the chain back at Core, so the table a resumed
        // ceremony recomputes is the same one.
        vm.revertToState(snap);
        assertTrue(script.stageOf(predicted, deployer) == Stage.Core, "back to an empty chain");
    }

    // ── Case 5: a foreign pointer holder ──

    /// @notice A pointer slot naming a FOREIGN ledger is refused by name, never repointed.
    function test_mainnet_foreignLedgerPointerIsRefusedNamingTheSlot() public {
        vm.chainId(MAINNET_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Mainnet);
        _primeWoodFeed(first.woodUsdFeed);

        // Between the two runs someone points the registry at ANOTHER deployment's ledger.
        // A real one: the registry's setter reads `challengeWindow()` off it.
        ExposureLedger foreign = new ExposureLedger(deployer, first.core.swoodProxy, RobinhoodParams.EPOCH_LENGTH);
        vm.prank(deployer);
        IGuardianRegistry(first.core.registryProxy).setExposureLedger(address(foreign));

        Inputs memory i = _inputs(Posture.Mainnet);
        vm.prank(deployer);
        try script.deployAll(i) {
            revert("the foreign pointer was not refused");
        } catch Error(string memory reason) {
            assertEq(
                reason,
                "WIRING: GuardianRegistry.exposureLedger already names a foreign address -- this "
                "ceremony never repoints a live slot. Clear it, or bump the CREATE3 salt namespace " "and redeploy.",
                reason
            );
        }
    }

    // ── Case 6: the pre-flight refusals a mutation would slip past ──

    /// @notice An EOA `OWNER_MULTISIG` is refused before anything is broadcast.
    function test_preflight_refusesAnEoaOwnerMultisig() public {
        vm.chainId(MAINNET_CHAIN_ID);
        Inputs memory i = _inputs(Posture.Mainnet);
        i.ownerMultisig = address(0xA11CE);
        vm.expectRevert(bytes("OWNER_MULTISIG must be a contract (Safe), not an EOA"));
        script.exposed_preflight(i);
    }

    /// @notice The cap the ledger bounds the governance WOOD price with is sized off live spot.
    function test_preflight_boundsThePriceCapAgainstLiveSpot() public {
        vm.chainId(MAINNET_CHAIN_ID);
        Inputs memory i = _inputs(Posture.Mainnet);
        script.exposed_preflight(i);

        // Ten times the depth makes spot 3e6, so the shipped 5e7 cap is far above 2x.
        uniPair.setReserves(WOOD_RESERVE * 10, WETH_RESERVE);
        sushiPair.setReserves(WETH_RESERVE, WOOD_RESERVE * 10);
        vm.expectRevert(bytes("PRE-FLIGHT: WOOD_PRICE_CAP_X8 is above 2x spot"));
        script.exposed_preflight(i);
    }

    // ── Case 7: source hygiene ──

    /// @notice Zero environment reads anywhere in the ceremony: the whole point of the rewrite.
    function test_noCeremonyScriptReadsTheProcessEnvironment() public view {
        string[9] memory files = [
            "script/robinhood-mainnet/DeployAll.s.sol",
            "script/robinhood-mainnet/Deploy.s.sol",
            "script/robinhood-mainnet/DeployPortfolioStrategy.s.sol",
            "script/robinhood-mainnet/DeployConcentratedLiquidityStrategy.s.sol",
            "script/robinhood-mainnet/DeployMorphoStrategy.s.sol",
            "script/Deploy.s.sol",
            "script/DeployStrategyFactory.s.sol",
            "script/DeployWoodPoolFeed.s.sol",
            "script/DeployPlanB.s.sol"
        ];
        for (uint256 n; n < files.length; ++n) {
            _assertNoEnvRead(files[n]);
        }
        _assertNoEnvRead("script/DeployPlanD.s.sol");
        _assertNoEnvRead("script/DeployTokenCourt.s.sol");
        _assertNoEnvRead("script/ScriptBase.sol");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _assertNoEnvRead(string memory relPath) internal view {
        string memory source = vm.readFile(string.concat(vm.projectRoot(), "/", relPath));
        assertFalse(vm.contains(source, "vm.env"), string.concat(relPath, " reads the environment"));
    }
}
