// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {DeploySherwood} from "../Deploy.s.sol";

/**
 * @notice Deploy the Sherwood core stack to Robinhood Chain mainnet (chain 4663).
 *
 *         Robinhood Chain is an Arbitrum Orbit L2 with no ENS/Durin registrar
 *         and no ERC-8004 agent-identity registry, so the factory is deployed
 *         with address(0) for both (identity + subname registration disabled).
 *
 *         Inherits the canonical `DeploySherwood` and delegates the core
 *         ceremony to its `deployCore` (CREATE3-salted, insertion-order-
 *         independent) — no hand-maintained linear-nonce offsets. This override
 *         layers the Robinhood-specific bits on top: a zero-adapter PriceRouter
 *         wired to the factory, the multisig handoff, post-deploy validation,
 *         and address persistence.
 *
 *         PortfolioStrategy is Lane-B-only so the PriceRouter carries zero
 *         adapters — it always fails closed to Lane B until governance registers
 *         an adapter post-audit.
 *
 *   Environment:
 *     WOOD_TOKEN            — REQUIRED. Guardian-layer WOOD custody token.
 *     OWNER_MULTISIG        — Multisig receiving ownership of the proxies as the
 *                             final step. Required unless SKIP_MULTISIG_HANDOFF.
 *     SKIP_MULTISIG_HANDOFF — "true"/"1" to keep the deployer as owner (fork/dry
 *                             runs only — never on the real mainnet ceremony).
 *
 *   Usage:
 *     WOOD_TOKEN=0x.. OWNER_MULTISIG=0xSafe.. \
 *       forge script script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 */
contract DeployRobinhoodMainnet is DeploySherwood {
    // No ENS or ERC-8004 on Robinhood Chain.
    address constant L2_REGISTRAR = address(0);
    address constant AGENT_REGISTRY = address(0);

    // Production governor / factory parameters (mirror script/Deploy.s.sol prod).
    uint256 constant MANAGEMENT_FEE_BPS = 50;
    uint256 constant PROTOCOL_FEE_BPS = 100;
    uint256 constant MAX_STRATEGY_DAYS = 14;
    uint256 constant VOTING_PERIOD = 1 days;

    function run() external override {
        // Accept Robinhood mainnet (4663) OR a Tenderly-fork chain id passed via
        // ROBINHOOD_FORK_CHAIN_ID (e.g. 9994663) so the byte-same ceremony runs
        // against a mainnet fork. The fork writes chains/{forkChainId}.json.
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address woodToken = vm.envAddress("WOOD_TOKEN");
        require(woodToken != address(0), "WOOD_TOKEN required");

        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        Config memory cfg = Config({
            ensRegistrar: L2_REGISTRAR,
            agentRegistry: AGENT_REGISTRY,
            managementFeeBps: MANAGEMENT_FEE_BPS,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            maxStrategyDays: MAX_STRATEGY_DAYS,
            votingPeriod: VOTING_PERIOD,
            woodToken: woodToken,
            slashAppealSeed: 0,
            epochZeroSeed: 0,
            betaMode: false
        });

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        // Canonical core ceremony (CREATE3, order-independent + setFactory).
        // Called on `this` so `msg.sender` inside deployCore is the broadcaster.
        Deployed memory d = deployCore(cfg);

        // PriceRouter with zero adapters. PortfolioStrategy is Lane-B-only so no
        // price adapters are needed; the router always fails closed to Lane B
        // until governance registers an adapter post-audit. Wired to the factory
        // so vaults read it live via `factory.priceRouter()`.
        PriceRouter priceRouterImpl = new PriceRouter();
        PriceRouter priceRouter = PriceRouter(
            address(new ERC1967Proxy(address(priceRouterImpl), abi.encodeCall(PriceRouter.initialize, (deployer))))
        );
        SyndicateFactory(d.factoryProxy).setPriceRouter(address(priceRouter));

        // Multisig handoff (final action inside the broadcast).
        address effectiveOwner = deployer;
        if (!skipHandoff) {
            Ownable(d.governorProxy).transferOwnership(ownerMultisig);
            Ownable(d.factoryProxy).transferOwnership(ownerMultisig);
            Ownable(d.registryProxy).transferOwnership(ownerMultisig);
            Ownable(d.swoodProxy).transferOwnership(ownerMultisig);
            Ownable(address(priceRouter)).transferOwnership(ownerMultisig);
            effectiveOwner = ownerMultisig;
        }

        vm.stopBroadcast();

        _validateMainnet(
            effectiveOwner,
            deployer,
            d.governorProxy,
            d.factoryProxy,
            d.registryProxy,
            d.swoodProxy,
            woodToken,
            address(priceRouter)
        );

        // Persist. `_writeAddresses` patches the core keys in place, so the
        // external addresses (WETH / USDG / Uniswap / Chainlink feeds) that were
        // committed into chains/4663.json survive.
        _writeAddresses("Robinhood Chain", deployer, d.factoryProxy, d.governorProxy, d.executorLib, d.vaultImpl);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        _patchAddress("STAKED_WOOD", d.swoodProxy);
        _patchAddress("WOOD_TOKEN", woodToken);
        _patchAddress("PRICE_ROUTER", address(priceRouter));

        console.log("SyndicateFactory:", d.factoryProxy);
        console.log("SyndicateGovernor:", d.governorProxy);
        console.log("GuardianRegistry:", d.registryProxy);
        console.log("StakedWood:", d.swoodProxy);
        console.log("PriceRouter:", address(priceRouter));
        console.log(
            "\nNext: forge script script/robinhood-mainnet/DeployPortfolioStrategy.s.sol --rpc-url robinhood --broadcast"
        );
    }

    function _validateMainnet(
        address expectedOwner,
        address deployer,
        address governorAddr,
        address factoryAddr,
        address registryAddr,
        address swoodAddr,
        address wood,
        address priceRouter
    ) internal view {
        SyndicateGovernor governor = SyndicateGovernor(governorAddr);
        SyndicateFactory factory = SyndicateFactory(factoryAddr);
        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();

        _checkAddr("gov.owner", Ownable(governorAddr).owner(), expectedOwner);
        _checkUint("gov.votingPeriod", p.votingPeriod, VOTING_PERIOD);
        _checkUint("gov.maxStrategyDuration", p.maxStrategyDuration, MAX_STRATEGY_DAYS * 1 days);
        _checkUint("gov.protocolFeeBps", governor.protocolFeeBps(), PROTOCOL_FEE_BPS);
        _checkAddr("gov.protocolFeeRecipient", governor.protocolFeeRecipient(), deployer);
        _checkAddr("gov.factory", governor.factory(), factoryAddr);

        _checkAddr("factory.owner", Ownable(factoryAddr).owner(), expectedOwner);
        _checkAddr("factory.governor", factory.governor(), governorAddr);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));

        _checkAddr("registry.owner", Ownable(registryAddr).owner(), expectedOwner);
        _checkAddr("swood.wood", address(StakedWood(swoodAddr).wood()), wood);
        _checkAddr("swood.registry", StakedWood(swoodAddr).registry(), registryAddr);

        _checkAddr("factory.priceRouter", factory.priceRouter(), priceRouter);
        _checkAddr("priceRouter.owner", Ownable(priceRouter).owner(), expectedOwner);
    }
}
