// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {DeploySalts} from "../DeploySalts.sol";
import {Create3Factory} from "../utils/Create3Factory.sol";
import {DeploySherwood} from "../Deploy.s.sol";
import {DeployRobinhoodMainnet} from "./Deploy.s.sol";
import {DeployPortfolioStrategy} from "./DeployPortfolioStrategy.s.sol";
import {DeployMorphoStrategy} from "./DeployMorphoStrategy.s.sol";
import {DeployConcentratedLiquidityStrategy} from "./DeployConcentratedLiquidityStrategy.s.sol";
import {DeployStrategyFactory} from "../DeployStrategyFactory.s.sol";
import {DeployWoodPoolFeed} from "../DeployWoodPoolFeed.s.sol";
import {DeployPlanB} from "../DeployPlanB.s.sol";
import {DeployPlanD} from "../DeployPlanD.s.sol";
import {DeployTokenCourt} from "../DeployTokenCourt.s.sol";
import {ForkWoodFeedFixture} from "./ForkWoodFeedFixture.sol";
import {RobinhoodParams} from "./RobinhoodParams.sol";
import {Posture, Inputs, Stack} from "./DeployTypes.sol";

import {ExposureLedger} from "../../src/ExposureLedger.sol";
import {ChallengeGame} from "../../src/ChallengeGame.sol";
import {TokenCourt} from "../../src/TokenCourt.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";

/// @notice How far a run got. A Mainnet ceremony is TWO runs: the first mints the
///         `WoodPoolFeed` and stops here, the second (after a keeper has primed it) completes.
enum Checkpoint {
    Complete,
    AwaitingWoodFeed
}

/// @notice The phase a chain still has to run, read back from chain state alone.
enum Stage {
    None,
    Create3Factory,
    Core,
    Templates,
    StrategyFactory,
    WoodFeed,
    WaitingForFeed,
    PlanB,
    PlanD,
    TokenCourt,
    Handoff,
    Done
}

/**
 * @title  DeployAll
 * @notice The one entry point of the Robinhood v1 ceremony. Every phase is an abstract
 *         mixin; this contract orders them, owns `run()`, the single broadcast, the
 *         post-broadcast validation and the address book.
 *
 *         Zero environment variables: posture comes from `block.chainid`, every address
 *         from `chains/{chainid}.json`, every number from `RobinhoodParams`.
 *
 *         Usage (mainnet):
 *           forge script script/robinhood-mainnet/DeployAll.s.sol:DeployAll \
 *             --rpc-url robinhood --account sherwood-deployer \
 *             --broadcast --slow --gas-estimate-multiplier 200
 *
 * @dev IDEMPOTENT END TO END. Every mint is `_c3` (adopt-if-present) and every write is
 *      guarded on the value already there, so a re-run after a mid-broadcast RPC failure
 *      sends only the calls that are still missing. A pointer or role slot holding a
 *      FOREIGN address is refused, never repointed.
 * @dev MAINNET IS TWO RUNS. `WoodPoolFeed` answers only a full TWAP window after its
 *      baseline, so run 1 stops at `Checkpoint.AwaitingWoodFeed` — before Plan B mints
 *      anything and before any handoff. The deployer keeps ownership in between.
 */
contract DeployAll is
    DeployPortfolioStrategy,
    DeployMorphoStrategy,
    DeployConcentratedLiquidityStrategy,
    DeployStrategyFactory,
    DeployWoodPoolFeed,
    DeployPlanB,
    DeployPlanD,
    DeployTokenCourt,
    DeployRobinhoodMainnet
{
    function run() external {
        Inputs memory inputs = _readInputs();
        _preflight(inputs);

        vm.startBroadcast();
        require(msg.sender == inputs.deployer, "broadcaster != DEPLOYER in the address book");
        (Stack memory s, Checkpoint cp) = deployAll(inputs);
        vm.stopBroadcast();

        _validateAll(s, inputs, cp);
        _persist(s, inputs, cp);
    }

    // ── The ceremony ──

    /// @notice Every phase, in order. Env-free and broadcast-free: this is what the tests drive.
    /// @dev The caller must be the `Create3Factory` owner — the phases bootstrap it at
    ///      `msg.sender`, so under `vm.startBroadcast` that is the broadcaster.
    function deployAll(Inputs memory i) public returns (Stack memory s, Checkpoint cp) {
        Create3Factory c3 = _c3Factory(msg.sender);
        s = _predictAll(c3, i.posture);

        DeploySherwood.Deployed memory core = deployCore(
            Config({
                ensRegistrar: RobinhoodParams.ENS_REGISTRAR,
                agentRegistry: RobinhoodParams.AGENT_REGISTRY,
                managementFeeBps: RobinhoodParams.MANAGEMENT_FEE_BPS,
                woodToken: i.wood
            })
        );
        // The prediction table and the phases must name the same salts, or `stageOf` reads
        // the wrong slots and `_persist` writes addresses nothing was minted at.
        require(
            core.executorLib == s.core.executorLib && core.vaultImpl == s.core.vaultImpl
                && core.protocolConfig == s.core.protocolConfig && core.beacon == s.core.beacon
                && core.factoryProxy == s.core.factoryProxy && core.registryProxy == s.core.registryProxy
                && core.swoodProxy == s.core.swoodProxy && core.tierRegistry == s.core.tierRegistry,
            "CREATE3 prediction table drift"
        );
        s.core = core;

        _seatOwnerWrites(s.core, s.core.deployer);
        _deployPortfolio(s, i);
        _deployMorpho(s);
        _deployCL(s, i);
        _deployStrategyFactory(s);

        if (i.posture == Posture.Mainnet) {
            // DERIVED from the live pool, like the fork's: a committed constant is only inside
            // the [1.25x, 2x] band on the day it was measured, and the band moves with the price.
            Params memory fp = _feedParams(i);
            uint256 spotX8 = _spotWoodUsdX8(fp, fp.uniPair);
            s.woodPriceCapX8 = (spotX8 * RobinhoodParams.CAP_OVER_SPOT_BPS) / 10_000;
            _requireCapAboveSpot(s.woodPriceCapX8, spotX8);
            s.woodUsdFeed = address(deploy(fp));
        } else {
            _deployForkFeed(s, i);
        }

        _requireNoPredictionDrift(c3, s, i.posture);

        // ── STAGE GATE. Plan B's ledger is unusable while WOOD cannot be priced, so the
        //    ceremony stops BEFORE minting it rather than after wiring a dead feed.
        if (!_feedAnswers(s.woodUsdFeed)) {
            console.log(
                "RUNBOOK: call WoodPoolFeed.update() once per window + %s s", RobinhoodParams.KEEPER_CADENCE_SLACK
            );
            console.log("RUNBOOK: then, once latestRoundData() answers, re-run this script to finish.");
            return (s, Checkpoint.AwaitingWoodFeed);
        }

        (s.exposureLedger, s.proposerBondEscrow) = deploy(_planBBook(s, i));
        s.challengeGame = deploy(_planDBook(s, i));
        _deployCourt(s);
        _wireCourt(s);

        _requireNoPredictionDrift(c3, s, i.posture);

        // LAST: every phase above is `onlyOwner` on something. On Fork the owner IS the
        // deployer, so this is a no-op rather than a skipped step.
        _handoffAll(s, i.ownerMultisig);
        cp = Checkpoint.Complete;
    }

    /// @dev Each phase re-derives its own address, and only the eight core fields are checked
    ///      against the prediction table above. Without this the other eleven are pinned by
    ///      nothing, and `stageOf`/`_persist` would read slots nothing was minted at.
    function _requireNoPredictionDrift(Create3Factory c3, Stack memory s, Posture posture) internal pure {
        _checkAddr("swapAdapter", s.uniswapSwapAdapter, _predict(c3, DeploySalts.UNISWAP_SWAP_ADAPTER));
        _checkAddr("portfolioTemplate", s.portfolioTemplate, _predict(c3, DeploySalts.PORTFOLIO_TEMPLATE));
        _checkAddr("morphoTemplate", s.morphoSupplyTemplate, _predict(c3, DeploySalts.MORPHO_SUPPLY_TEMPLATE));
        _checkAddr("clTemplate", s.concentratedLiquidityTemplate, _predict(c3, DeploySalts.CL_TEMPLATE));
        _checkAddr("strategyFactory", s.strategyFactory, _predict(c3, DeploySalts.STRATEGY_FACTORY));
        _checkAddr(
            "woodUsdFeed",
            s.woodUsdFeed,
            _predict(c3, posture == Posture.Mainnet ? DeploySalts.WOOD_USD_FEED : DeploySalts.FORK_WOOD_FEED)
        );
        _checkAddr("exposureLedger", s.exposureLedger, _predict(c3, DeploySalts.EXPOSURE_LEDGER));
        _checkAddr("bondEscrow", s.proposerBondEscrow, _predict(c3, DeploySalts.PROPOSER_BOND_ESCROW));
        _checkAddr("challengeGame", s.challengeGame, _predict(c3, DeploySalts.CHALLENGE_GAME));
        _checkAddr("tokenCourt", s.tokenCourt, _predict(c3, DeploySalts.TOKEN_COURT));
    }

    /// @notice Every address this ceremony will mint, before a single transaction.
    /// @dev Address = f(create3Factory, salt) only, so the whole table is knowable up front —
    ///      which is what lets a pointer slot be refused BEFORE its contract exists.
    function _predictAll(Create3Factory c3, Posture posture) internal pure returns (Stack memory s) {
        s.create3Factory = address(c3);
        s.core.executorLib = _predict(c3, DeploySalts.EXECUTOR);
        s.core.vaultImpl = _predict(c3, DeploySalts.VAULT_IMPL);
        s.core.protocolConfig = _predict(c3, DeploySalts.PROTOCOL_CONFIG);
        s.core.beacon = _predict(c3, DeploySalts.GOVERNOR_BEACON);
        s.core.swoodProxy = _predict(c3, DeploySalts.SWOOD_PROXY);
        s.core.registryProxy = _predict(c3, DeploySalts.REGISTRY_PROXY);
        s.core.tierRegistry = _predict(c3, DeploySalts.TIER_REGISTRY);
        s.core.factoryProxy = _predict(c3, DeploySalts.FACTORY_PROXY);

        s.uniswapSwapAdapter = _predict(c3, DeploySalts.UNISWAP_SWAP_ADAPTER);
        s.portfolioTemplate = _predict(c3, DeploySalts.PORTFOLIO_TEMPLATE);
        s.morphoSupplyTemplate = _predict(c3, DeploySalts.MORPHO_SUPPLY_TEMPLATE);
        s.concentratedLiquidityTemplate = _predict(c3, DeploySalts.CL_TEMPLATE);
        s.strategyFactory = _predict(c3, DeploySalts.STRATEGY_FACTORY);

        // Distinct salts: a fork fixture can never be adopted as the mainnet feed.
        s.woodUsdFeed =
            _predict(c3, posture == Posture.Mainnet ? DeploySalts.WOOD_USD_FEED : DeploySalts.FORK_WOOD_FEED);

        s.exposureLedger = _predict(c3, DeploySalts.EXPOSURE_LEDGER);
        s.proposerBondEscrow = _predict(c3, DeploySalts.PROPOSER_BOND_ESCROW);
        s.challengeGame = _predict(c3, DeploySalts.CHALLENGE_GAME);
        s.tokenCourt = _predict(c3, DeploySalts.TOKEN_COURT);
    }

    /// @notice The phase this chain still has to run; `Done` when none does.
    /// @param finalOwner the Safe on Mainnet, the deployer on Fork — the handoff has no
    ///        target to compare against otherwise.
    function stageOf(Stack memory s, address finalOwner) public view returns (Stage) {
        if (s.create3Factory == address(0)) return Stage.None;
        if (s.create3Factory.code.length == 0) return Stage.Create3Factory;
        if (
            s.core.executorLib.code.length == 0 || s.core.vaultImpl.code.length == 0
                || s.core.protocolConfig.code.length == 0 || s.core.beacon.code.length == 0
                || s.core.swoodProxy.code.length == 0 || s.core.registryProxy.code.length == 0
                || s.core.tierRegistry.code.length == 0 || s.core.factoryProxy.code.length == 0
        ) return Stage.Core;
        if (
            s.uniswapSwapAdapter.code.length == 0 || s.portfolioTemplate.code.length == 0
                || s.morphoSupplyTemplate.code.length == 0 || s.concentratedLiquidityTemplate.code.length == 0
        ) return Stage.Templates;
        if (s.strategyFactory.code.length == 0) return Stage.StrategyFactory;
        if (s.woodUsdFeed.code.length == 0) return Stage.WoodFeed;
        if (!_feedAnswers(s.woodUsdFeed)) return Stage.WaitingForFeed;
        if (s.exposureLedger.code.length == 0 || s.proposerBondEscrow.code.length == 0) return Stage.PlanB;
        if (s.challengeGame.code.length == 0) return Stage.PlanD;
        if (s.tokenCourt.code.length == 0 || ChallengeGame(s.challengeGame).court() != s.tokenCourt) {
            return Stage.TokenCourt;
        }
        if (!_ownersAreFinal(s, finalOwner)) return Stage.Handoff;
        return Stage.Done;
    }

    /// @dev The fork's WOOD/USD feed. The price is DERIVED from the fork's own pair reserves
    ///      x ETH/USD, never invented, and the fixture itself refuses chain 4663.
    ///      `_spotWoodUsdX8` is called directly: on a fork the pools stop trading, so the
    ///      mainnet feed's idle pre-flight would refuse the very chain this exists for.
    function _deployForkFeed(Stack memory s, Inputs memory i) internal {
        uint256 spotX8 = _spotWoodUsdX8(_feedParams(i), i.woodWethV2Pair);
        // The cap is DERIVED here, not taken from the constant: a fork that seeded a cap Mainnet
        // would refuse is a ceremony rehearsal that never exercised the band.
        s.woodPriceCapX8 = (spotX8 * RobinhoodParams.CAP_OVER_SPOT_BPS) / 10_000;
        _requireCapAboveSpot(s.woodPriceCapX8, spotX8);
        s.woodUsdFeed = _c3(
            Create3Factory(s.create3Factory),
            DeploySalts.FORK_WOOD_FEED,
            abi.encodePacked(type(ForkWoodFeedFixture).creationCode, abi.encode(spotX8))
        );
        console.log("ForkWoodFeedFixture: %s (WOOD/USD x8 %s)", s.woodUsdFeed, spotX8);
    }

    /// @notice The last in-broadcast act: move every admin role to the Safe.
    /// @dev THE TWO OWNERSHIP MODELS ARE NOT UNIFORM. Beacon / factory / registry / sWOOD /
    ///      StrategyFactory are one-step `Ownable`; ProtocolConfig, TierRegistry, the ledger,
    ///      the game and the court are `Ownable2Step`, where this call only ARMS the transfer
    ///      and the Safe must `acceptOwnership()`. Each leg is skipped when already done, so a
    ///      resumed run is a no-op.
    function _handoffAll(Stack memory s, address ownerMultisig) internal {
        // Handing the protocol to address(0) is unrecoverable, and every caller that skips
        // `_readInputs` (tests, a future phase) can reach here with an unset field.
        require(ownerMultisig != address(0), "handoff target unset");
        _giveOneStep(s.core.beacon, ownerMultisig);
        _giveOneStep(s.core.factoryProxy, ownerMultisig);
        _giveOneStep(s.core.registryProxy, ownerMultisig);
        _giveOneStep(s.core.swoodProxy, ownerMultisig);
        _giveOneStep(s.strategyFactory, ownerMultisig);

        _giveTwoStep(s.core.protocolConfig, ownerMultisig);
        _giveTwoStep(s.core.tierRegistry, ownerMultisig);
        _giveTwoStep(s.exposureLedger, ownerMultisig);
        _giveTwoStep(s.challengeGame, ownerMultisig);
        _giveTwoStep(s.tokenCourt, ownerMultisig);

        console.log("RUNBOOK: the multisig MUST call acceptOwnership() on ProtocolConfig, TierRegistry,");
        console.log("RUNBOOK: ExposureLedger, ChallengeGame AND TokenCourt.");
        // BOTH FEE LEGS PAY THE DEPLOYER KEY until the Safe re-points them: a zero recipient
        // is worse (it folds the leg into the agent's remainder silently), so they are seeded.
        console.log("RUNBOOK: then, from the Safe, setProtocolFeeRecipient(treasury) and");
        console.log("RUNBOOK: setGuardiansFeeRecipient(guardian payout address).");
        // NOT handed off: `Create3Factory.deploy` is `onlyOwner`, so the deployer key keeps the
        // right to mint at any UNUSED salt in this namespace. Used salts already hold code.
        console.log("RUNBOOK: the deployer key KEEPS Create3Factory ownership: %s", s.create3Factory);
    }

    /// @dev A typed `owner()` into an address with no code reverts with empty returndata, which
    ///      reports an ordering slip in this function as a bare revert naming no slot.
    function _giveOneStep(address target, address ownerMultisig) private {
        require(target.code.length != 0, "handoff: one-step target holds no code");
        if (Ownable(target).owner() != ownerMultisig) Ownable(target).transferOwnership(ownerMultisig);
    }

    function _giveTwoStep(address target, address ownerMultisig) private {
        require(target.code.length != 0, "handoff: two-step target holds no code");
        if (Ownable(target).owner() == ownerMultisig) return;
        if (Ownable2Step(target).pendingOwner() != ownerMultisig) {
            Ownable2Step(target).transferOwnership(ownerMultisig);
        }
    }

    // ── Inputs ──

    /// @dev Posture from the chain id alone: 4663 is Mainnet, any other chain with a
    ///      committed book carrying DEPLOYER is a Fork. Who ends up owning the protocol is a
    ///      POSTURE, never a flag: the Safe on Mainnet, the deployer itself on a fork or vnet.
    function _readInputs() internal view returns (Inputs memory i) {
        require(_fileExists(_chainsPath()), "wrong chain: no chains/<chainid>.json for this chain");
        i.posture = block.chainid == RobinhoodParams.MAINNET_CHAIN_ID ? Posture.Mainnet : Posture.Fork;

        i.deployer = _required("DEPLOYER", "wrong chain: chains/<chainid>.json carries no DEPLOYER");
        if (i.posture == Posture.Mainnet) {
            i.ownerMultisig = _required("OWNER_MULTISIG", "OWNER_MULTISIG missing from the address book");
        } else {
            // A fork owns itself. A book key is allowed only when it says exactly that, so a
            // mainnet Safe copied into a fork book cannot silently become the handoff target.
            address booked = _optionalAddress("OWNER_MULTISIG");
            require(
                booked == address(0) || booked == i.deployer,
                "Fork posture hands off to the deployer: OWNER_MULTISIG must be absent or equal DEPLOYER"
            );
            i.ownerMultisig = i.deployer;
        }

        i.wood = _required("WOOD_TOKEN", "WOOD_TOKEN missing from the address book");
        i.weth = _required("WETH", "WETH missing from the address book");
        i.usdg = _required("USDG", "USDG missing from the address book");
        i.usdgFeed = _required("CHAINLINK_USDG_USD_FEED", "CHAINLINK_USDG_USD_FEED missing from the address book");
        i.ethUsdFeed = _required("CHAINLINK_ETH_USD_FEED", "CHAINLINK_ETH_USD_FEED missing from the address book");
        i.uniswapV3Factory = _required("UNISWAP_V3_FACTORY", "UNISWAP_V3_FACTORY missing from the address book");
        i.uniswapV3PositionManager =
            _required("UNISWAP_V3_POSITION_MANAGER", "UNISWAP_V3_POSITION_MANAGER missing from the address book");
        i.uniswapSwapRouter = _required("UNISWAP_SWAP_ROUTER", "UNISWAP_SWAP_ROUTER missing from the address book");
        i.uniswapQuoterV2 = _required("UNISWAP_QUOTER_V2", "UNISWAP_QUOTER_V2 missing from the address book");
        i.uniswapV4PoolManager =
            _required("UNISWAP_V4_POOL_MANAGER", "UNISWAP_V4_POOL_MANAGER missing from the address book");
        i.uniswapV4Quoter = _required("UNISWAP_V4_QUOTER", "UNISWAP_V4_QUOTER missing from the address book");
        i.morphoBlue = _required("MORPHO_BLUE", "MORPHO_BLUE missing from the address book");
        i.woodWethV2Pair = _required("WOOD_WETH_V2_PAIR", "WOOD_WETH_V2_PAIR missing from the address book");
        // The feed's second leg is a V3 pool, not a second V2 pair. 4663 carries two V3
        // deployments and the booked pool belongs to the non-canonical one, so the factory
        // is booked alongside it and the pre-flight checks provenance both ways.
        i.woodWethUniswapV3Pool = _required(
            "WOOD_WETH_UNISWAP_V3_POOL",
            "WOOD_WETH_UNISWAP_V3_POOL missing from the address book: WoodPoolFeed needs a second WOOD/WETH venue"
        );
        i.woodWethUniswapV3Factory =
            _required("WOOD_WETH_UNISWAP_V3_FACTORY", "WOOD_WETH_UNISWAP_V3_FACTORY missing from the address book");
    }

    function _required(string memory key, string memory why) internal view returns (address a) {
        a = _optionalAddress(key);
        require(a != address(0), why);
    }

    function _feedParams(Inputs memory i) internal pure returns (Params memory) {
        return Params({
            uniPair: i.woodWethV2Pair,
            v3Pool: i.woodWethUniswapV3Pool,
            v3Factory: i.woodWethUniswapV3Factory,
            wood: i.wood,
            weth: i.weth,
            ethUsdFeed: i.ethUsdFeed,
            window: RobinhoodParams.TWAP_WINDOW,
            ethUsdMaxAge: RobinhoodParams.ETH_USD_MAX_AGE,
            minWethReserve: RobinhoodParams.MIN_WETH_RESERVE,
            minV3Liquidity: toMinV3Liquidity(RobinhoodParams.MIN_V3_LIQUIDITY)
        });
    }

    function _planBBook(Stack memory s, Inputs memory i) internal pure returns (PlanBBook memory) {
        return PlanBBook({
            swood: s.core.swoodProxy,
            factory: s.core.factoryProxy,
            registry: s.core.registryProxy,
            wood: i.wood,
            usdg: i.usdg,
            usdgFeed: i.usdgFeed,
            feedMaxDelay: RobinhoodParams.ASSET_FEED_MAX_DELAY,
            woodPriceCapX8: s.woodPriceCapX8,
            woodHaircutBps: RobinhoodParams.WOOD_HAIRCUT_BPS,
            coveredTvlCapUsd: RobinhoodParams.COVERED_TVL_CAP_USD18,
            protocolConfig: s.core.protocolConfig,
            maxStrategyDuration: RobinhoodParams.MAX_STRATEGY_DURATION,
            woodUsdFeed: s.woodUsdFeed,
            woodFeedMaxDelay: RobinhoodParams.WOOD_FEED_MAX_DELAY
        });
    }

    function _planDBook(Stack memory s, Inputs memory i) internal pure returns (PlanDBook memory) {
        return PlanDBook({
            swood: s.core.swoodProxy, wood: i.wood, ledger: s.exposureLedger, tierRegistry: s.core.tierRegistry
        });
    }

    // ── Pre-broadcast pre-flight ──

    /// @dev Everything refusable before a transaction exists. The identity checks are the
    ///      load-bearing half: the canonical Uniswap mainnet addresses each hold unrelated
    ///      code on 4663, so a code-length check passes and wires the wrong contract.
    function _preflight(Inputs memory i) internal view {
        if (i.posture == Posture.Mainnet) {
            require(i.ownerMultisig.code.length != 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }
        require(CREATE2_DEPLOYER.code.length != 0, "CREATE2 deployer not on this chain");
        require(
            keccak256(type(Create3Factory).creationCode) == DeploySalts.CREATE3_FACTORY_INITCODE_HASH,
            "Create3Factory initcode hash drift"
        );
        requireManagementFeeUnderCap(RobinhoodParams.MANAGEMENT_FEE_BPS);
        _assertIsPositionManager(i.uniswapV3PositionManager, i.uniswapV3Factory);
        require(i.morphoBlue.code.length != 0, "MORPHO_BLUE holds no code");

        // The WOOD feed is the only phase that reads live market state, so its pre-flights
        // run here too: refusing after the core is minted costs a whole ceremony.
        if (i.posture == Posture.Mainnet) {
            Params memory p = _feedParams(i);
            _preflight(p);
        }
    }

    // ── Post-broadcast validation ──

    /// @dev Stage-aware, because run 1 of a Mainnet ceremony legitimately ends with no
    ///      ledger, no game and no handoff — asserting the finished table there would fail
    ///      a correct run AFTER the broadcast, with the transactions already sent.
    function _validateAll(Stack memory s, Inputs memory i, Checkpoint cp) internal view {
        address deployer = s.core.deployer;
        bool handedOff = cp == Checkpoint.Complete && i.posture == Posture.Mainnet;
        address finalOwner = handedOff ? i.ownerMultisig : deployer;

        _validateMainnet(s.core, deployer, handedOff ? i.ownerMultisig : address(0), i.wood);
        _checkAddr("strategyFactory.owner", Ownable(s.strategyFactory).owner(), finalOwner);
        require(StrategyFactory(s.strategyFactory).approvedTemplate(s.portfolioTemplate), "template: portfolio");
        require(StrategyFactory(s.strategyFactory).approvedTemplate(s.morphoSupplyTemplate), "template: morpho");
        require(StrategyFactory(s.strategyFactory).approvedTemplate(s.concentratedLiquidityTemplate), "template: CL");

        if (cp == Checkpoint.AwaitingWoodFeed) {
            require(s.woodUsdFeed.code.length != 0, "the WOOD feed was not minted");
            // Nothing may be armed yet: the deployer has to keep every key until run 2.
            require(Ownable2Step(s.core.protocolConfig).pendingOwner() == address(0), "handoff started too early");
            return;
        }

        _postflight(_planBBook(s, i), ExposureLedger(s.exposureLedger));
        _postflight(_planDBook(s, i), ChallengeGame(s.challengeGame));
        require(TokenCourt(s.tokenCourt).challengeGame() == s.challengeGame, "wiring: court.challengeGame");
        require(TokenCourt(s.tokenCourt).stakedWood() == s.core.swoodProxy, "wiring: court.stakedWood");
        require(ChallengeGame(s.challengeGame).court() == s.tokenCourt, "wiring: game.court");

        // Plan B pre-flight 10 in its new home. The ledger's owner is the slashing and
        // freeze authority; on Mainnet it must end up at a CONTRACT (the Safe), and a
        // two-step transfer leaves that in `pendingOwner` until the Safe accepts.
        if (handedOff) {
            _checkAddr("ledger.pendingOwner", Ownable2Step(s.exposureLedger).pendingOwner(), i.ownerMultisig);
            require(i.ownerMultisig.code.length != 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
            _checkAddr("game.pendingOwner", Ownable2Step(s.challengeGame).pendingOwner(), i.ownerMultisig);
            _checkAddr("court.pendingOwner", Ownable2Step(s.tokenCourt).pendingOwner(), i.ownerMultisig);
        }
        require(stageOf(s, finalOwner) == Stage.Done, "ceremony did not reach Stage.Done");
    }

    /// @dev Every admin role this ceremony can move already names `finalOwner` — armed
    ///      counts for the two-step half, since accepting is the Safe's call, not ours.
    function _ownersAreFinal(Stack memory s, address finalOwner) private view returns (bool) {
        if (Ownable(s.core.beacon).owner() != finalOwner) return false;
        if (Ownable(s.core.factoryProxy).owner() != finalOwner) return false;
        if (Ownable(s.core.registryProxy).owner() != finalOwner) return false;
        if (Ownable(s.core.swoodProxy).owner() != finalOwner) return false;
        if (Ownable(s.strategyFactory).owner() != finalOwner) return false;
        return _twoStepIsFinal(s.core.protocolConfig, finalOwner) && _twoStepIsFinal(s.core.tierRegistry, finalOwner)
            && _twoStepIsFinal(s.exposureLedger, finalOwner) && _twoStepIsFinal(s.challengeGame, finalOwner)
            && _twoStepIsFinal(s.tokenCourt, finalOwner);
    }

    function _twoStepIsFinal(address target, address finalOwner) private view returns (bool) {
        return Ownable(target).owner() == finalOwner || Ownable2Step(target).pendingOwner() == finalOwner;
    }

    // ── Persistence ──

    /// @dev Patches only what this run reached, into a book that must already exist: the
    ///      external addresses are committed, and a script that can CREATE a book can also
    ///      write a complete-looking one for a chain nobody reviewed.
    function _persist(Stack memory s, Inputs memory i, Checkpoint cp) internal {
        string memory path = _chainsPath();
        require(_fileExists(path), "no address book to persist into");

        _patchAddress("DEPLOYER", s.core.deployer);
        _patchAddress("CREATE3_FACTORY", s.create3Factory);
        _patchAddress("BATCH_EXECUTOR_LIB", s.core.executorLib);
        _patchAddress("SYNDICATE_VAULT_IMPL", s.core.vaultImpl);
        _patchAddress("SYNDICATE_FACTORY", s.core.factoryProxy);
        // Governors are per-vault (resolved through `factory.governorOf`), so there is no
        // singleton to record; the key stays zero rather than absent.
        _patchAddress("SYNDICATE_GOVERNOR", address(0));
        _patchAddress("GOVERNOR_BEACON", s.core.beacon);
        _patchAddress("PROTOCOL_CONFIG", s.core.protocolConfig);
        _patchAddress("GUARDIAN_REGISTRY", s.core.registryProxy);
        _patchAddress("TIER_REGISTRY", s.core.tierRegistry);
        _patchAddress("STAKED_WOOD", s.core.swoodProxy);
        _patchAddress("UNISWAP_SWAP_ADAPTER", s.uniswapSwapAdapter);

        string[] memory templateKeys = _templateKeys();
        _patchAddress(templateKeys[0], s.portfolioTemplate);
        _patchAddress(templateKeys[1], s.morphoSupplyTemplate);
        _patchAddress(templateKeys[2], s.concentratedLiquidityTemplate);
        _patchAddress("STRATEGY_FACTORY", s.strategyFactory);
        _patchAddress("WOOD_USD_FEED", s.woodUsdFeed);

        if (cp == Checkpoint.Complete) {
            _patchAddress("EXPOSURE_LEDGER", s.exposureLedger);
            _patchAddress("PROPOSER_BOND_ESCROW", s.proposerBondEscrow);
            _patchAddress("CHALLENGE_GAME", s.challengeGame);
            _patchAddress("TOKEN_COURT", s.tokenCourt);
        }

        vm.writeJson(vm.toString(block.chainid), path, ".chainId");
        vm.writeJson(i.posture == Posture.Mainnet ? "\"Robinhood Chain\"" : "\"Robinhood Chain (fork)\"", path, ".name");
        console.log("Addresses written to %s", path);
        console.log("Checkpoint: %s", cp == Checkpoint.Complete ? "Complete" : "AwaitingWoodFeed");
    }
}
