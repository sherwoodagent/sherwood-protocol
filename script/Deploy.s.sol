// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {GovernorBeacon} from "../src/GovernorBeacon.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {DeploySalts} from "./DeploySalts.sol";
import {RobinhoodParams} from "./robinhood-mainnet/RobinhoodParams.sol";

/// @notice Core Sherwood stack, minted through CREATE3 so every address is
///         f(deployer, salt) and the registry↔factory cycle resolves by
///         prediction. An abstract mixin: `DeployAll` owns `run()`, the
///         broadcast brackets and the address book.
abstract contract DeploySherwood is ScriptBase {
    /// @notice Mirror of `SyndicateFactory.MAX_MANAGEMENT_FEE_BPS`; refused before the broadcast.
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 300;

    struct Config {
        address ensRegistrar;
        address agentRegistry;
        uint256 managementFeeBps;
        address woodToken;
    }

    struct Deployed {
        address deployer;
        address executorLib;
        address vaultImpl;
        address beacon; // GovernorBeacon — per-vault governor proxies read impl from here
        address protocolConfig; // global fee config; each governor snapshots from it
        address factoryProxy;
        address registryProxy;
        address swoodProxy;
        address tierRegistry; // adapter-selector tier certification (spec §3.2)
    }

    /// @notice Pre-flight: the management fee the deploy is about to seed must sit
    ///         under the factory's own ceiling, refused before anything is broadcast.
    function requireManagementFeeUnderCap(uint256 bps) public pure {
        require(bps <= MAX_MANAGEMENT_FEE_BPS, "PRE-FLIGHT: MANAGEMENT_FEE above MAX_MANAGEMENT_FEE_BPS (300)");
    }

    /// @notice Mints the core stack and wires the registry↔factory↔sWOOD triangle.
    /// @dev Wires NO exposure ledger and NO bond escrow — Plan B does that later, so a
    ///      core-only protocol reverts `NoBondToReclaim` (RobinhoodMainnetAdversarial.t.sol:289).
    ///      Idempotent: every mint skips when the salt's address already holds code.
    function deployCore(Config memory cfg) public returns (Deployed memory d) {
        d.deployer = msg.sender;

        Create3Factory c3 = _c3Factory(d.deployer);

        d.executorLib = _c3(c3, DeploySalts.EXECUTOR, type(BatchExecutorLib).creationCode);
        d.vaultImpl = _c3(c3, DeploySalts.VAULT_IMPL, type(SyndicateVault).creationCode);

        address registryAddr = _predict(c3, DeploySalts.REGISTRY_PROXY);
        address predictedFactoryProxy = _predict(c3, DeploySalts.FACTORY_PROXY);

        // ProtocolConfig: plain Ownable2Step, no proxy — fee params are re-settable, not upgrade state.
        d.protocolConfig = _c3(
            c3, DeploySalts.PROTOCOL_CONFIG, abi.encodePacked(type(ProtocolConfig).creationCode, abi.encode(d.deployer))
        );

        // Per-vault governor model: one implementation behind a GovernorBeacon. The factory clones a
        // BeaconProxy per vault at `createSyndicate`; an upgrade is one `beacon.upgradeTo`.
        address govImpl = _c3(
            c3,
            DeploySalts.GOVERNOR_IMPL,
            abi.encodePacked(
                type(SyndicateGovernor).creationCode,
                abi.encode(RobinhoodParams.MIN_VOTING_PERIOD, RobinhoodParams.MIN_COOLDOWN_PERIOD)
            )
        );
        d.beacon = _c3(
            c3,
            DeploySalts.GOVERNOR_BEACON,
            abi.encodePacked(type(GovernorBeacon).creationCode, abi.encode(govImpl, d.deployer))
        );
        // sWOOD is the sole WOOD custodian and the registry's `initialize` takes it, so it comes
        // first; the registry↔sWOOD cycle closes on the set-once `setRegistry` below.
        d.swoodProxy = _deploySwoodProxy(c3, d.deployer, predictedFactoryProxy, cfg);

        address registryImpl = _c3(
            c3,
            DeploySalts.REGISTRY_IMPL,
            abi.encodePacked(type(GuardianRegistry).creationCode, abi.encode(RobinhoodParams.MIN_REVIEW_PERIOD))
        );
        d.registryProxy = _deployRegistryProxy(c3, registryImpl, d.deployer, predictedFactoryProxy, d.swoodProxy);
        require(d.registryProxy == registryAddr, "registry addr mismatch");

        // Set-once on sWOOD; a resumed run finds it already wired.
        if (StakedWood(d.swoodProxy).registry() == address(0)) {
            StakedWood(d.swoodProxy).setRegistry(d.registryProxy);
        }

        // Adapter-selector tier registry (spec §3.2). Owned by the deployer at birth so the launch
        // set lands before the multisig accepts; passed into the factory's `InitParams` below.
        d.tierRegistry = _c3(
            c3, DeploySalts.TIER_REGISTRY, abi.encodePacked(type(TierRegistry).creationCode, abi.encode(d.deployer))
        );
        // Issue #40: the submitter bond has no slash path yet. This script never calls
        // `setSubmitterBondWood` — the assert pins that, it does not change behaviour.
        require(
            TierRegistry(d.tierRegistry).submitterBondWood() == 0,
            "submitter bond must stay 0 at launch - see issue #40"
        );

        address factoryImpl = _c3(c3, DeploySalts.FACTORY_IMPL, type(SyndicateFactory).creationCode);
        d.factoryProxy = _deployFactoryProxy(c3, factoryImpl, d, cfg);
        require(d.factoryProxy == predictedFactoryProxy, "factory addr mismatch");
    }

    /// @dev sWOOD initializes against the PREDICTED factory proxy — CREATE3 is address-stable,
    ///      so it can be minted before the factory exists.
    function _deploySwoodProxy(Create3Factory c3, address deployer, address predictedFactoryProxy, Config memory cfg)
        internal
        returns (address)
    {
        address swoodImpl = _c3(c3, DeploySalts.SWOOD_IMPL, type(StakedWood).creationCode);
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: cfg.woodToken,
                    factory: predictedFactoryProxy,
                    minGuardianStake: RobinhoodParams.MIN_GUARDIAN_STAKE,
                    coolDownPeriod: RobinhoodParams.COOLDOWN,
                    minOwnerStake: RobinhoodParams.MIN_OWNER_STAKE,
                    minSlashBps: RobinhoodParams.MIN_SLASH_BPS,
                    maxSlashBps: RobinhoodParams.MAX_SLASH_BPS,
                    ageFloorBps: RobinhoodParams.AGE_FLOOR_BPS,
                    maturationPeriod: RobinhoodParams.MATURATION
                }))
        );
        return _c3(
            c3,
            DeploySalts.SWOOD_PROXY,
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(swoodImpl, initData))
        );
    }

    function _deployFactoryProxy(Create3Factory c3, address factoryImpl, Deployed memory d, Config memory cfg)
        internal
        returns (address)
    {
        bytes memory initData = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: d.deployer,
                    executorImpl: d.executorLib,
                    vaultImpl: d.vaultImpl,
                    ensRegistrar: cfg.ensRegistrar,
                    agentRegistry: cfg.agentRegistry,
                    beacon: d.beacon,
                    protocolConfig: d.protocolConfig,
                    managementFeeBps: cfg.managementFeeBps,
                    guardianRegistry: d.registryProxy,
                    tierRegistry: d.tierRegistry
                }))
        );
        return _c3(
            c3,
            DeploySalts.FACTORY_PROXY,
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImpl, initData))
        );
    }

    function _deployRegistryProxy(
        Create3Factory c3,
        address registryImpl,
        address deployer,
        address predictedFactoryProxy,
        address swoodProxy
    ) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            GuardianRegistry.initialize,
            (
                deployer,
                predictedFactoryProxy,
                swoodProxy,
                RobinhoodParams.REVIEW_PERIOD,
                RobinhoodParams.BLOCK_QUORUM_BPS
            )
        );
        return _c3(
            c3,
            DeploySalts.REGISTRY_PROXY,
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(registryImpl, initData))
        );
    }

    /// @dev The chain-constant half of the TierRegistry launch set, applied while the deployer
    ///      still owns the registry.
    ///
    ///      WHY HERE. Every strategy template refuses to initialize against an unattested
    ///      dependency: `PortfolioStrategy` checks each Chainlink aggregator AND its pairing to the
    ///      slot's token, `MorphoSupplyStrategy` checks `isCounterpartyAllowed(morpho)`,
    ///      `ConcentratedLiquidityStrategy` checks the position manager, Morpho and the Uniswap v3
    ///      factory. A fresh registry answers false to all of them, so without this the first
    ///      proposal on a new chain reverts naming a role (`PriceSourceNotAllowed`) rather than the
    ///      missing deploy step.
    ///
    ///      WHY ONLY THIS HALF. Seeded here is what is already a constant of the chain — third-party
    ///      addresses read from the address book. Addresses this ceremony MINTS (the swap adapter,
    ///      the templates) do not exist yet; their phases seed themselves the same way, which the
    ///      two-step handoff leaves room for.
    ///
    ///      Every feed key is REQUIRED: a missing one used to narrow the attestation set silently.
    function _seedTierRegistry(address deployer, address tierRegistry) internal {
        console.log("\n=== Seeding TierRegistry launch set ===");
        // These writes are `onlyOwner` and have exactly one window. Refusing beats skipping: a
        // ceremony that seeds nothing looks clean and ships a registry no template can bind to.
        require(
            TierRegistry(tierRegistry).owner() == deployer,
            "PRE-FLIGHT: TIER_REGISTRY owner is not the deployer - seed the launch set before the Safe accepts"
        );

        // Counterparties: the venues a certified template may bind.
        _seedCounterparty(tierRegistry, "UNISWAP_V3_POSITION_MANAGER");
        _seedCounterparty(tierRegistry, "UNISWAP_V3_FACTORY");
        _seedCounterparty(tierRegistry, "MORPHO_BLUE");

        string[16] memory symbols = RobinhoodParams.launchSetSymbols();
        for (uint256 i; i < symbols.length; ++i) {
            _seedPriceSource(tierRegistry, symbols[i]);
        }
    }

    function _seedCounterparty(address tierRegistry, string memory key) internal {
        address target = _readAddress(key);
        require(target != address(0), string.concat("launch set: ", key, " is zero in the address book"));
        if (!TierRegistry(tierRegistry).isCounterpartyAllowed(target)) {
            TierRegistry(tierRegistry).setCounterpartyAllowed(target, true);
        }
        console.log("  counterparty allowed:", key, target);
    }

    /// @dev Allowlists the aggregator and pairs it to the token it prices. `priceSource` MUST be the
    ///      bare aggregator widened to bytes32 — the exact normalization
    ///      `PortfolioStrategy._initialize` applies before `_requirePairedPriceSource`. Any other
    ///      encoding produces an attestation that is never consulted.
    ///      The feed key is required; the TOKEN key is not, because a symbol whose feed exists but
    ///      whose token does not (USDC/BTC/LINK on Robinhood) has nothing to pair to. The pairing is
    ///      what gates a slot, so an unpaired allowlist entry stays inert until someone attests it.
    function _seedPriceSource(address tierRegistry, string memory symbol) internal {
        string memory feedKey = string.concat("CHAINLINK_", symbol, "_USD_FEED");
        address feed = _readAddress(feedKey);
        require(feed != address(0), string.concat("launch set: ", feedKey, " is zero in the address book"));
        if (!TierRegistry(tierRegistry).isCounterpartyAllowed(feed)) {
            TierRegistry(tierRegistry).setCounterpartyAllowed(feed, true);
        }

        // ETH's feed prices the wrapped token; every other symbol's token key is the symbol itself.
        address token = _optionalAddress(keccak256(bytes(symbol)) == keccak256("ETH") ? "WETH" : symbol);
        if (token == address(0)) {
            console.log("  feed allowlisted, NO token pairing (token not on this chain):", symbol, feed);
            return;
        }
        bytes32 priceSource = bytes32(uint256(uint160(feed)));
        if (!TierRegistry(tierRegistry).isPriceSourceForToken(token, priceSource)) {
            TierRegistry(tierRegistry).setPriceSourceForToken(token, priceSource, true);
        }
        console.log("  feed allowlisted + paired:", symbol, feed);
    }

    function _validateBeacon(address expectedOwner, address beaconAddr) internal view {
        console.log("\n=== Validating GovernorBeacon ===");
        // Per-vault governors are minted at `createSyndicate`, so the beacon is the only
        // governance handle that exists at deploy time.
        _checkAddr("beacon.owner", GovernorBeacon(beaconAddr).owner(), expectedOwner);
        require(GovernorBeacon(beaconAddr).implementation() != address(0), "beacon impl unset");
    }

    function _validateFactory(
        address expectedOwner,
        address beaconAddr,
        address protocolConfigAddr,
        address factoryAddr,
        address executorLibAddr,
        address vaultImplAddr,
        address ensRegistrar,
        address agentRegistry,
        uint256 mgmtFeeBps
    ) internal view {
        console.log("=== Validating Factory ===");
        SyndicateFactory factory = SyndicateFactory(factoryAddr);

        _checkAddr("factory.owner", Ownable(factoryAddr).owner(), expectedOwner);
        _checkAddr("factory.beacon", factory.beacon(), beaconAddr);
        _checkAddr("factory.protocolConfig", factory.protocolConfig(), protocolConfigAddr);
        _checkAddr("factory.executorImpl", factory.executorImpl(), executorLibAddr);
        _checkAddr("factory.vaultImpl", factory.vaultImpl(), vaultImplAddr);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), ensRegistrar);
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), agentRegistry);
        _checkUint("factory.managementFeeBps", factory.managementFeeBps(), mgmtFeeBps);

        console.log("=== All checks passed ===");
    }

    function _validateRegistry(address expectedOwner, address registryAddr, address factoryAddr, address wood)
        internal
        view
    {
        console.log("=== Validating GuardianRegistry ===");
        GuardianRegistry reg = GuardianRegistry(registryAddr);
        _checkAddr("registry.owner", Ownable(registryAddr).owner(), expectedOwner);
        // registry.governor removed — multi-governor set; governors added via addGovernor post-deploy.
        _checkAddr("registry.factory", reg.factory(), factoryAddr);
        // sWOOD is the sole WOOD custodian post-split — validate the registry's
        // sWOOD handle and that sWOOD itself custodies the right WOOD token.
        address swoodAddr = address(reg.swood());
        _checkAddr("swood.wood", address(StakedWood(swoodAddr).wood()), wood);
        _checkAddr("swood.registry", StakedWood(swoodAddr).registry(), registryAddr);
        _checkUint("registry.reviewPeriod", reg.reviewPeriod(), RobinhoodParams.REVIEW_PERIOD);
        _checkUint("registry.blockQuorumBps", reg.blockQuorumBps(), RobinhoodParams.BLOCK_QUORUM_BPS);
    }
}
