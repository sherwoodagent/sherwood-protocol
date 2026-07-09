// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {WoodToken} from "../../src/WoodToken.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";
import {SynthraQuoterV2Shim} from "../../src/adapters/SynthraQuoterV2Shim.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {DeploySherwood} from "../Deploy.s.sol";

/// @notice Minimal LayerZero endpoint stub — only `setDelegate`, called by the
///         OApp constructor. Robinhood testnet has no LZ endpoint, and WOOD
///         there is a non-production fixture (see WoodToken natspec), so a stub
///         is sufficient to stand the token up for guardian staking.
contract StubLzEndpoint {
    function setDelegate(address) external {}
}

/**
 * @notice V2 Sherwood core + Portfolio-strategy ceremony for Robinhood L2
 *         testnet (chain 46630). Single-command deploy: core stack, zero-adapter
 *         PriceRouter, the SAME `UniswapSwapAdapter` wired to Synthra via
 *         `SynthraQuoterV2Shim`, the PortfolioStrategy template, and the keyless
 *         StrategyFactory with the template approved.
 *
 *         Supersedes the old V1 testnet deployment (the pre-sWOOD-split core
 *         keys + SYNTHRA_SWAP_ADAPTER / SYNTHRA_DIRECT_ADAPTER / PORTFOLIO_STRATEGY
 *         in chains/46630.json). The external Synthra keys (SYNTHRA_ROUTER,
 *         SYNTHRA_QUOTER, SYNTHRA_FACTORY, CHAINLINK_VERIFIER) are read + preserved.
 *
 *   Environment:
 *     WOOD_TOKEN            — Optional. If unset/zero, deploys a fixture WOOD
 *                             (StubLzEndpoint) and mints WOOD_MINT (default 100M)
 *                             to the deployer for guardian/owner staking.
 *     WOOD_MINT             — Optional fixture mint amount (default 100M).
 *     SKIP_MULTISIG_HANDOFF — "true"/"1" keeps the deployer as owner. Always true
 *                             on testnet (no multisig).
 *
 *   Usage (single command):
 *     SKIP_MULTISIG_HANDOFF=true \
 *       forge script script/robinhood-testnet/DeployV2.s.sol:DeployRobinhoodTestnetV2 \
 *       --rpc-url robinhood_testnet --account sherwood-deployer --broadcast --slow
 */
contract DeployRobinhoodTestnetV2 is DeploySherwood {
    // Production governor / factory parameters (mirror the mainnet script).
    uint256 constant MANAGEMENT_FEE_BPS = 50;
    uint256 constant PROTOCOL_FEE_BPS = 100;
    uint256 constant MAX_STRATEGY_DAYS = 14;
    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant DEFAULT_WOOD_MINT = 100_000_000e18;

    function run() external override {
        require(block.chainid == 46630, "wrong chain: expected Robinhood testnet 46630");

        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        // Read Synthra externals before broadcasting (must already be in chains.json).
        address synthraRouter = _readAddress("SYNTHRA_ROUTER");
        address synthraQuoter = _readAddress("SYNTHRA_QUOTER");

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood L2 Testnet (chain ID 46630)");

        // ── WOOD (fixture if unset) ──
        address woodToken = vm.envOr("WOOD_TOKEN", address(0));
        if (woodToken == address(0)) {
            address stubEndpoint = address(new StubLzEndpoint());
            WoodToken wood = new WoodToken(stubEndpoint, deployer);
            wood.mint(deployer, vm.envOr("WOOD_MINT", DEFAULT_WOOD_MINT));
            woodToken = address(wood);
            console.log("WoodToken (FIXTURE):", woodToken);
        }

        Config memory cfg = Config({
            ensRegistrar: address(0),
            agentRegistry: address(0),
            managementFeeBps: MANAGEMENT_FEE_BPS,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            maxStrategyDays: MAX_STRATEGY_DAYS,
            votingPeriod: VOTING_PERIOD,
            woodToken: woodToken,
            slashAppealSeed: 0,
            epochZeroSeed: 0,
            betaMode: false
        });

        // Canonical core ceremony (CREATE3, order-independent + setFactory).
        Deployed memory d = deployCore(cfg);

        // Zero-adapter PriceRouter (PortfolioStrategy is Lane-B-only; router
        // fails closed to Lane B until governance registers an adapter).
        address priceRouter =
            address(new ERC1967Proxy(address(new PriceRouter()), abi.encodeCall(PriceRouter.initialize, (deployer))));
        SyndicateFactory(d.factoryProxy).setPriceRouter(priceRouter);

        // Synthra quoter shim → SAME UniswapSwapAdapter (no v4 on testnet) →
        // PortfolioStrategy template.
        SynthraQuoterV2Shim shim = new SynthraQuoterV2Shim(synthraQuoter);
        UniswapSwapAdapter adapter = new UniswapSwapAdapter(synthraRouter, address(shim), address(0), address(0));
        PortfolioStrategy template = new PortfolioStrategy();

        // Keyless-clone StrategyFactory + approve the Portfolio template.
        StrategyFactory strategyFactory = new StrategyFactory(d.factoryProxy, deployer);
        strategyFactory.setTemplateApproval(address(template), true);

        // Multisig handoff (skipped on testnet).
        address effectiveOwner = deployer;
        if (!skipHandoff) {
            Ownable(d.governorProxy).transferOwnership(ownerMultisig);
            Ownable(d.factoryProxy).transferOwnership(ownerMultisig);
            Ownable(d.registryProxy).transferOwnership(ownerMultisig);
            Ownable(d.swoodProxy).transferOwnership(ownerMultisig);
            Ownable(priceRouter).transferOwnership(ownerMultisig);
            strategyFactory.transferOwnership(ownerMultisig);
            effectiveOwner = ownerMultisig;
        }

        vm.stopBroadcast();

        _validateTestnet(effectiveOwner, d, woodToken, priceRouter);

        // Persist + log in a helper so the strategy-stack locals (shim / adapter
        // / template / strategyFactory) don't stay pinned in `run()`'s frame
        // alongside `cfg`/`d` (via_ir stack-depth).
        _persistAndLog(
            d,
            woodToken,
            priceRouter,
            Extras({
                shim: address(shim),
                adapter: address(adapter),
                template: address(template),
                strategyFactory: address(strategyFactory)
            })
        );
    }

    struct Extras {
        address shim;
        address adapter;
        address template;
        address strategyFactory;
    }

    function _persistAndLog(Deployed memory d, address wood, address priceRouter, Extras memory e) internal {
        // ── Persist (patch-mode preserves the Synthra externals) ──
        _writeAddresses("Robinhood L2 Testnet", d.deployer, d.factoryProxy, d.governorProxy, d.executorLib, d.vaultImpl);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        _patchAddress("STAKED_WOOD", d.swoodProxy);
        _patchAddress("WOOD_TOKEN", wood);
        _patchAddress("PRICE_ROUTER", priceRouter);
        _patchAddress("SYNTHRA_QUOTER_V2_SHIM", e.shim);
        _patchAddress("UNISWAP_SWAP_ADAPTER", e.adapter);
        _patchAddress("PORTFOLIO_TEMPLATE", e.template);
        _patchAddress("STRATEGY_FACTORY", e.strategyFactory);

        console.log("SyndicateFactory:", d.factoryProxy);
        console.log("SyndicateGovernor:", d.governorProxy);
        console.log("GuardianRegistry:", d.registryProxy);
        console.log("StakedWood:", d.swoodProxy);
        console.log("PriceRouter:", priceRouter);
        console.log("SynthraQuoterV2Shim:", e.shim);
        console.log("UniswapSwapAdapter:", e.adapter);
        console.log("PortfolioStrategy template:", e.template);
        console.log("StrategyFactory:", e.strategyFactory);
    }

    function _validateTestnet(address expectedOwner, Deployed memory d, address wood, address priceRouter)
        internal
        view
    {
        SyndicateGovernor governor = SyndicateGovernor(d.governorProxy);
        SyndicateFactory factory = SyndicateFactory(d.factoryProxy);

        _checkAddr("gov.owner", Ownable(d.governorProxy).owner(), expectedOwner);
        _checkAddr("gov.factory", governor.factory(), d.factoryProxy);
        _checkUint("gov.protocolFeeBps", governor.protocolFeeBps(), PROTOCOL_FEE_BPS);
        _checkAddr("gov.protocolFeeRecipient", governor.protocolFeeRecipient(), d.deployer);

        _checkAddr("factory.owner", Ownable(d.factoryProxy).owner(), expectedOwner);
        _checkAddr("factory.governor", factory.governor(), d.governorProxy);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));

        _checkAddr("swood.wood", address(StakedWood(d.swoodProxy).wood()), wood);
        _checkAddr("swood.registry", StakedWood(d.swoodProxy).registry(), d.registryProxy);

        _checkAddr("factory.priceRouter", factory.priceRouter(), priceRouter);
        _checkAddr("priceRouter.owner", Ownable(priceRouter).owner(), expectedOwner);
    }
}
