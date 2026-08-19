// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "./utils/Create3Factory.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {CallSandbox} from "../src/CallSandbox.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {ProtocolConfig} from "../src/ProtocolConfig.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GovernorBeacon} from "../src/GovernorBeacon.sol";
import {ScriptBase} from "./ScriptBase.sol";

/**
 * @notice Generic Sherwood protocol deployment via CREATE3.
 *
 *         Deploys a Create3Factory first (regular CREATE), then uses it for
 *         all subsequent deploys. Each deploy is a single CALL transaction,
 *         avoiding the 2-tx problem where Foundry splits create2 into
 *         CREATE2+CALL broadcast pairs that desync on some RPCs.
 *
 *         Deterministic addresses based on (factory, salt). Same factory
 *         address + same salts = same protocol addresses on any chain.
 *
 *   Environment variables:
 *     OWNER_MULTISIG    — REQUIRED. Multisig contract that receives ownership of
 *                         Governor + Factory + GuardianRegistry as the final step
 *                         of the deploy ceremony. MUST be a contract (Safe etc.) —
 *                         deploy reverts on EOA / address(0).
 *     SKIP_MULTISIG_HANDOFF — Optional escape hatch for ephemeral testnet / fork
 *                         deploys ("true"/"1" to skip). Defaults to false. Never
 *                         use on mainnet.
 *     ENS_REGISTRAR     — L2 Registrar address (default: 0x0 = no ENS)
 *     AGENT_REGISTRY    — ERC-8004 Identity Registry (default: 0x0 = no identity)
 *     MANAGEMENT_FEE    — Management fee in bps (default: 50 = 0.5%)
 *     PROTOCOL_FEE      — Protocol fee in bps (default: 100 = 1%, max 1%)
 *     MAX_STRATEGY_DAYS — Max strategy duration in days (default: 14). NOTE (#421):
 *                         per-vault governors initialize from the factory's
 *                         `_defaultGovernorParams()` (votingPeriod 24h, maxStrategyDuration
 *                         30d); this env and VOTING_PERIOD no longer reach them — the vault
 *                         owner raises limits post-create via `setMaxStrategyDuration` etc.
 *
 *   Usage:
 *     forge script script/Deploy.s.sol:DeploySherwood \
 *       --rpc-url <chain> --account <acct> --sender <addr> --broadcast --slow
 */
contract DeploySherwood is ScriptBase {
    // ── CREATE3 salts ──
    // V1.5 beta redeploy (PR #282): bumped governor/vault/factory/executor
    // .2 → .3, guardian-registry .1 → .2. Required because storage layout
    // AND runtime bytecode changed materially:
    //   - StrategyProposal struct now carries `address strategy` (drops
    //     bindProposalAdapter)
    //   - SyndicateGovernor: cancelProposal extends to GuardianReview/Approved
    //     + drives registry.cancelReview; getProposalCalls dropped
    //   - SyndicateVault: liveAdapterWithdrawn mapping, _pullFromLiveAdapter,
    //     NAV-aware max{Redeem,Withdraw}, _lpFlowGate adapterValue tuple
    //   - GuardianRegistry: cancelReview added; _slashApprovers extracted
    //   - PortfolioStrategy: rebalanceDelta refactored into snapshot/sell/buy
    //     helpers
    // Old .2/.1 proxies remain at their addresses for historical / settle-
    // out access. New addresses get written to chains/{chainId}.json.
    bytes32 constant SALT_EXECUTOR = keccak256("sherwood.deploy.executor.3");
    bytes32 constant SALT_VAULT_IMPL = keccak256("sherwood.deploy.vault-impl.3");
    bytes32 constant SALT_GOVERNOR_IMPL = keccak256("sherwood.deploy.governor-impl.3");
    bytes32 constant SALT_GOVERNOR_PROXY = keccak256("sherwood.deploy.governor-proxy.3");
    bytes32 constant SALT_FACTORY_IMPL = keccak256("sherwood.deploy.factory-impl.3");
    bytes32 constant SALT_FACTORY_PROXY = keccak256("sherwood.deploy.factory-proxy.3");
    bytes32 constant SALT_REGISTRY_IMPL = keccak256("sherwood.deploy.guardian-registry-impl.2");
    bytes32 constant SALT_REGISTRY_PROXY = keccak256("sherwood.deploy.guardian-registry-proxy.2");
    bytes32 constant SALT_SWOOD_IMPL = keccak256("sherwood.deploy.staked-wood-impl.1");
    bytes32 constant SALT_SWOOD_PROXY = keccak256("sherwood.deploy.staked-wood-proxy.1");
    bytes32 constant SALT_SANDBOX_IMPL = keccak256("sherwood.deploy.call-sandbox-impl.1");

    // ── Registry default parameters (spec §3.1; overridable via env) ──
    uint256 constant DEFAULT_MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant DEFAULT_MIN_OWNER_STAKE = 10_000e18;
    uint256 constant DEFAULT_COOLDOWN = 7 days;
    uint256 constant DEFAULT_REVIEW_PERIOD = 24 hours;
    // ── Per-deployment governance timing floors (constructor immutables) ──
    // Mainnet/default impls bake in the historical hard floors. A testnet
    // acceleration deploy overrides these via a dedicated upgrade script
    // (see script/robinhood-testnet/UpgradeGovernorFloors.s.sol).
    uint256 constant DEFAULT_MIN_VOTING_PERIOD = 24 hours;
    uint256 constant DEFAULT_MIN_COOLDOWN_PERIOD = 1 hours;
    uint256 constant DEFAULT_MIN_REVIEW_PERIOD = 6 hours;
    uint256 constant DEFAULT_BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 constant DEFAULT_SLASH_APPEAL_SEED = 1_000_000e18;
    uint256 constant DEFAULT_EPOCH_ZERO_SEED = 10_000e18;
    uint256 constant DEFAULT_MIN_SLASH_BPS = 1000; // 10%
    // The own-stake severity ceiling may be a full 100% — own stake is a
    // plain integer with no share math to brick.
    uint256 constant DEFAULT_MAX_SLASH_BPS = 10_000; // 100%
    uint256 constant DEFAULT_AGE_FLOOR_BPS = 2500; // 25% weight at age 0
    uint256 constant DEFAULT_MATURATION_PERIOD = 30 days;

    struct Config {
        address ensRegistrar;
        address agentRegistry;
        uint256 managementFeeBps;
        uint256 maxStrategyDays;
        uint256 votingPeriod;
        address woodToken;
        uint256 slashAppealSeed;
        uint256 epochZeroSeed;
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
        address sandboxImpl; // CallSandbox implementation every new vault clones
    }

    function run() external virtual {
        Config memory cfg = Config({
            ensRegistrar: vm.envOr("ENS_REGISTRAR", address(0)),
            agentRegistry: vm.envOr("AGENT_REGISTRY", address(0)),
            // 200 = the 2%-management headline of the two-number fee model.
            // The prior 50 bps default starved the guardian pool 3.7× below
            // the ROE math (tier-1 guardian ROE 2.2% vs the intended 17.5%).
            managementFeeBps: vm.envOr("MANAGEMENT_FEE", uint256(200)),
            maxStrategyDays: vm.envOr("MAX_STRATEGY_DAYS", uint256(14)),
            votingPeriod: vm.envOr("VOTING_PERIOD", uint256(1 days)),
            // WOOD_TOKEN is required — the full GuardianRegistry stakes it.
            woodToken: vm.envOr("WOOD_TOKEN", _tryReadAddress("WOOD_TOKEN")),
            slashAppealSeed: vm.envOr("SLASH_APPEAL_SEED", DEFAULT_SLASH_APPEAL_SEED),
            epochZeroSeed: vm.envOr("EPOCH_ZERO_SEED", DEFAULT_EPOCH_ZERO_SEED)
        });
        require(cfg.woodToken != address(0), "WOOD_TOKEN not set (env or chains.json)");

        // Multisig handoff is mandatory in prod.
        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        vm.startBroadcast();
        Deployed memory d = deployCore(cfg);
        console.log("\nDeployer:", d.deployer);
        console.log("Chain ID:", block.chainid);
        console.log("BatchExecutorLib:", d.executorLib);
        console.log("VaultImpl:", d.vaultImpl);
        console.log("GovernorBeacon:", d.beacon);
        console.log("GuardianRegistryProxy:", d.registryProxy);
        console.log("FactoryProxy:", d.factoryProxy);
        console.log("TierRegistry:", d.tierRegistry);

        // Seed slash appeal reserve + epoch 0 rewards. Best-effort: skipped
        // on zero amounts. MUST run before the multisig handoff while the
        // deployer is still the owner.
        _seedRegistry(d.deployer, d.registryProxy, cfg);

        // Same constraint as the registry seed above, for the TierRegistry:
        // these are `onlyOwner` writes, so they MUST precede the handoff.
        // Without them no strategy template can initialize (see the function's
        // own natspec for the full dependency list).
        _seedTierRegistry(d.deployer, d.tierRegistry);

        // Multisig handoff: prod hands all proxies to the multisig.
        address effectiveOwner = d.deployer;
        if (!skipHandoff) {
            _handoffOwnership(d.beacon, d.factoryProxy, d.registryProxy, d.swoodProxy, d.protocolConfig, ownerMultisig);
            // TierRegistry is Ownable2Step (like ProtocolConfig): transferOwnership
            // starts a two-step transfer — the multisig MUST call acceptOwnership()
            // to complete it. Kept out of `_handoffOwnership` so that helper's
            // signature (asserted by Deploy_multisigHandoff.t.sol) stays fixed.
            Ownable2Step(d.tierRegistry).transferOwnership(ownerMultisig);
            console.log("TierRegistry pending -> multisig; RUNBOOK: multisig must call acceptOwnership()");
            effectiveOwner = ownerMultisig;
        }

        vm.stopBroadcast();

        // ── Validate ──
        _validateBeacon(effectiveOwner, d.beacon);
        // C1: after handoff, ProtocolConfig ownership is PENDING the multisig
        // (Ownable2Step) — assert the two-step transfer was initiated so a
        // deployer that forgot the acceptOwnership runbook step is caught.
        if (!skipHandoff) {
            _checkAddr("protocolConfig.pendingOwner", Ownable2Step(d.protocolConfig).pendingOwner(), ownerMultisig);
        }
        _validateFactory(
            effectiveOwner,
            d.beacon,
            d.protocolConfig,
            d.factoryProxy,
            d.executorLib,
            d.vaultImpl,
            cfg.ensRegistrar,
            cfg.agentRegistry,
            cfg.managementFeeBps
        );
        _validateRegistry(effectiveOwner, d.registryProxy, d.factoryProxy, cfg.woodToken);

        // ── Persist ──
        // Per-vault governor: there is NO singleton governor — zero the
        // SYNDICATE_GOVERNOR slot (a beacon address there would make admin
        // scripts revert calling governor ABIs on it) and persist the beacon +
        // ProtocolConfig under explicit keys.
        _writeAddresses(_chainName(), d.deployer, d.factoryProxy, address(0), d.executorLib, d.vaultImpl);
        _patchAddress("GOVERNOR_BEACON", d.beacon);
        _patchAddress("PROTOCOL_CONFIG", d.protocolConfig);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        _patchAddress("TIER_REGISTRY", d.tierRegistry);
        // sWOOD is the sole WOOD custodian — persist it for the CLI / admin
        // scripts.
        _patchAddress("STAKED_WOOD", d.swoodProxy);
        // Persist WOOD — Deploy only reads it as an input, so without this it
        // never lands in chains.json (audit gap).
        _patchAddress("WOOD_TOKEN", cfg.woodToken);

        console.log("\nDeployment complete on %s (chain %s)", _chainName(), block.chainid);
        console.log("Next: forge script script/DeployTemplates.s.sol --rpc-url <chain> --broadcast");
    }

    /// @notice Deployment helper extracted from `run()` for use in fork tests.
    ///         Performs all CREATE3 deploys + governor.setFactory() but does NOT:
    ///           - call `vm.startBroadcast()` / `vm.stopBroadcast()` (caller's responsibility)
    ///           - persist addresses to chains/{chainId}.json
    ///           - validate (callers can if they want)
    /// @dev Used by fork integration tests to deploy without writing to disk.
    ///      Production deploys keep using `run()`.
    function deployCore(Config memory cfg) public returns (Deployed memory d) {
        d.deployer = msg.sender;

        Create3Factory c3 = new Create3Factory(d.deployer);

        d.executorLib = c3.deploy(SALT_EXECUTOR, abi.encodePacked(type(BatchExecutorLib).creationCode));
        d.vaultImpl = c3.deploy(SALT_VAULT_IMPL, abi.encodePacked(type(SyndicateVault).creationCode));

        address registryAddr = c3.addressOf(SALT_REGISTRY_PROXY);

        address predictedFactoryProxy = c3.addressOf(SALT_FACTORY_PROXY);

        // Deploy ProtocolConfig (plain Ownable — no proxy needed).
        ProtocolConfig protocolConfig = new ProtocolConfig(d.deployer);
        d.protocolConfig = address(protocolConfig);

        // Per-vault governor model: deploy the governor implementation once and
        // wrap it in a GovernorBeacon. The factory clones a BeaconProxy per vault
        // at `createSyndicate`; a protocol-wide governor upgrade is a single
        // `beacon.upgradeTo(newImpl)`. No singleton governor proxy is deployed.
        address govImpl = c3.deploy(
            SALT_GOVERNOR_IMPL,
            abi.encodePacked(
                type(SyndicateGovernor).creationCode, abi.encode(DEFAULT_MIN_VOTING_PERIOD, DEFAULT_MIN_COOLDOWN_PERIOD)
            )
        );
        d.beacon = address(new GovernorBeacon(govImpl, d.deployer));
        // sWOOD is the sole WOOD custodian: deploy it before the registry
        // so the registry's `initialize` can take the sWOOD address. The
        // registry↔sWOOD circular dependency is resolved by the set-once
        // `setRegistry` call below (deploy order: sWOOD → registry → wire).
        d.swoodProxy = _deploySwoodProxy(c3, d.deployer, predictedFactoryProxy, cfg);

        address registryImpl = c3.deploy(
            SALT_REGISTRY_IMPL,
            abi.encodePacked(type(GuardianRegistry).creationCode, abi.encode(DEFAULT_MIN_REVIEW_PERIOD))
        );
        d.registryProxy = _deployRegistryProxy(c3, registryImpl, d.deployer, predictedFactoryProxy, d.swoodProxy);
        require(d.registryProxy == registryAddr, "registry addr mismatch");

        // Wire the set-once registry reference on sWOOD.
        StakedWood(d.swoodProxy).setRegistry(d.registryProxy);

        // Adapter-selector tier registry (spec §3.2). Owned by the deployer at
        // birth so `demote`/`poke` and the launch-set announcement can run
        // before the multisig handoff; passed into the factory's `InitParams`
        // below so every governor `createSyndicate` stamps out picks it up via
        // the factory-only `setTierRegistry`. A plain Ownable2Step contract —
        // no proxy needed (certifications are re-issuable, not upgrade-state).
        //
        // Deployed BEFORE the factory: mandatory `InitParams` field since pashov
        // finding #1. Free of ordering cost — the factory proxy is CREATE3, so
        // an extra nonce ahead of it does not move `predictedFactoryProxy`.
        //
        // Granting is two-step (issue #45): `proposeCertification` is
        // owner-only and now takes the reviewed codehash as
        // `expectedCodehash` (PR #156 audit remediation, finding #6) so the
        // pinned snapshot matches what was actually reviewed off-chain, not
        // whatever is live when the transaction happens to mine. `certify`
        // is permissionless once `certifyDelay` has elapsed EXCEPT when a
        // submitter bond is pinned (submitterBondWood != 0 at proposal
        // time), in which case only that pinned submitter may trigger it
        // (finding #3) — the launch set below carries no bond, so it stays
        // fully permissionless in practice. RUNBOOK for the launch adapter
        // set: propose the whole set HERE, while the deployer still owns the
        // registry (this call is not in this function — see the deploy
        // runbook), hand off ownership to the multisig immediately after
        // (below), and let anyone (deployer, multisig, a bot) execute each
        // certification once its delay has passed and before
        // `MAX_CERTIFY_WINDOW` (finding #5) lapses. Announcement and
        // ownership handoff overlap instead of serializing; demotion
        // (`demote`/`poke`) stays instant throughout.
        d.tierRegistry = address(new TierRegistry(d.deployer));
        // Issue #40: the submitter bond has no slash path yet, so it must
        // stay disabled until the launch gate documented on
        // `TierRegistry.submitterBondWood` is met. This script never calls
        // `setSubmitterBondWood` — the assertion pins that fact rather than
        // changing behavior.
        require(
            TierRegistry(d.tierRegistry).submitterBondWood() == 0,
            "submitter bond must stay 0 at launch - see issue #40"
        );

        // The CallSandbox implementation every vault clones for a
        // `proposeWithSandbox` payload. Deployed BEFORE the factory so the
        // wiring below cannot be deferred to a follow-up transaction — a
        // factory live without it creates vaults that can never run a payload,
        // and the vault's binding is set-once, so those vaults could never be
        // fixed.
        d.sandboxImpl = c3.deploy(SALT_SANDBOX_IMPL, abi.encodePacked(type(CallSandbox).creationCode));

        address factoryImpl = c3.deploy(SALT_FACTORY_IMPL, abi.encodePacked(type(SyndicateFactory).creationCode));
        d.factoryProxy = _deployFactoryProxy(c3, factoryImpl, d, cfg);
        require(d.factoryProxy == predictedFactoryProxy, "factory addr mismatch");

        // Bound here, in the same transaction batch that created the factory,
        // for the reason above. The deployer still owns the factory at this
        // point; the ownership handoff happens later.
        SyndicateFactory(d.factoryProxy).setSandboxImpl(d.sandboxImpl);
        require(
            SyndicateFactory(d.factoryProxy).sandboxImpl() == d.sandboxImpl,
            "sandbox impl must be bound before the factory goes live"
        );
    }

    /// @dev Deploys the StakedWood (sWOOD) proxy via CREATE3. The governor +
    ///      factory proxy addresses are predicted (CREATE3 is address-stable),
    ///      so sWOOD can be initialized before either is deployed.
    function _deploySwoodProxy(Create3Factory c3, address deployer, address predictedFactoryProxy, Config memory cfg)
        internal
        returns (address)
    {
        address swoodImpl = c3.deploy(SALT_SWOOD_IMPL, abi.encodePacked(type(StakedWood).creationCode));
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: cfg.woodToken,
                    factory: predictedFactoryProxy,
                    minGuardianStake: DEFAULT_MIN_GUARDIAN_STAKE,
                    coolDownPeriod: DEFAULT_COOLDOWN,
                    minOwnerStake: DEFAULT_MIN_OWNER_STAKE,
                    minSlashBps: DEFAULT_MIN_SLASH_BPS,
                    maxSlashBps: DEFAULT_MAX_SLASH_BPS,
                    ageFloorBps: DEFAULT_AGE_FLOOR_BPS,
                    maturationPeriod: DEFAULT_MATURATION_PERIOD
                }))
        );
        return
            c3.deploy(
                SALT_SWOOD_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(swoodImpl, initData))
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
        return c3.deploy(
            SALT_FACTORY_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImpl, initData))
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
            (deployer, predictedFactoryProxy, swoodProxy, DEFAULT_REVIEW_PERIOD, DEFAULT_BLOCK_QUORUM_BPS)
        );
        return c3.deploy(
            SALT_REGISTRY_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(registryImpl, initData))
        );
    }

    /// @dev Seeds the slash-appeal reserve and epoch-0 rewards when the
    ///      deployer holds WOOD. Skipped silently if either seed is 0 or the
    ///      balance is insufficient — testnet deploys without a WOOD balance
    ///      can top up post-deploy.
    /// @dev The chain-constant half of the TierRegistry launch set, applied
    ///      while the deployer still owns the registry.
    ///
    ///      WHY HERE. Every strategy template refuses to initialize against an
    ///      unattested dependency: `PortfolioStrategy` checks each Chainlink
    ///      aggregator (`_requireAllowedPriceSource`) AND its pairing to the
    ///      slot's token (`_requirePairedPriceSource`), `MorphoSupplyStrategy`
    ///      checks `isAdapterAllowed(morpho)`, `ConcentratedLiquidityStrategy`
    ///      checks `isCounterpartyAllowed` on the position manager, Morpho and
    ///      the Uniswap v3 factory. A fresh registry answers false to all of
    ///      them, so a just-deployed protocol cannot run a single strategy
    ///      until these land. Leaving them to a runbook means the first
    ///      proposal on a new chain reverts, and the revert names a role
    ///      (`PriceSourceNotAllowed`) rather than the missing step.
    ///
    ///      WHY ONLY THIS HALF. Seeded here is exactly what is already a
    ///      constant of the chain — third-party addresses read from the
    ///      address book, reviewable in the same diff as the deploy. Addresses
    ///      this deploy MINTS (the swap adapter, strategy templates) do not
    ///      exist yet: their scripts run later and seed themselves the same
    ///      way, which the two-step `Ownable2Step` handoff below deliberately
    ///      leaves room for — `transferOwnership` only sets `pendingOwner`, so
    ///      the deployer stays owner until the multisig calls
    ///      `acceptOwnership()`. THE RUNBOOK ORDER IS THEREFORE: core deploy →
    ///      strategy deploys → multisig accepts. Accepting early is safe but
    ///      costs a multisig transaction per dependency.
    ///
    ///      Per-clone `setAdapterAllowed` stays manual by construction — a
    ///      clone's address is not known until an agent creates it.
    ///
    ///      Best-effort per key: a chain whose address book lacks an entry
    ///      simply does not get that attestation. Silence is logged, never
    ///      assumed.
    function _seedTierRegistry(address deployer, address tierRegistry) internal {
        console.log("\n=== Seeding TierRegistry launch set ===");
        if (TierRegistry(tierRegistry).owner() != deployer) {
            console.log("RUNBOOK: deployer no longer owns TierRegistry - seeding SKIPPED.");
            console.log("RUNBOOK: the owner must apply the launch set manually before any proposal.");
            return;
        }

        // Counterparties: addresses a certified template may BIND to (pools,
        // position managers, lending singletons) as distinct from addresses
        // that may RECEIVE vault funds. Morpho needs both axes — CL binds it
        // as a counterparty, MorphoSupplyStrategy spends into it as an adapter.
        _seedCounterparty(tierRegistry, "UNISWAP_V3_POSITION_MANAGER");
        _seedCounterparty(tierRegistry, "UNISWAP_V3_FACTORY");
        if (_seedCounterparty(tierRegistry, "MORPHO_BLUE")) {
            _seedAdapter(tierRegistry, "MORPHO_BLUE");
        }

        // Push-feed price sources. `symbols` drives BOTH lookups: the feed key
        // is CHAINLINK_<SYM>_USD_FEED and the token key is <SYM>, except ETH,
        // whose token is wrapped. A symbol whose feed exists but whose token
        // does not (BTC/LINK/USDC on Robinhood) is allowlisted without a
        // pairing — harmless, because the pairing check is what actually gates
        // a slot, and it stays unsatisfiable until someone attests it.
        string[13] memory symbols =
            ["ETH", "USDG", "USDC", "BTC", "LINK", "AAPL", "AMD", "AMZN", "GOOGL", "META", "MSFT", "NVDA", "TSLA"];
        for (uint256 i; i < symbols.length; ++i) {
            _seedPriceSource(tierRegistry, symbols[i]);
        }
        // Index/commodity trackers whose token key matches the symbol.
        string[3] memory funds = ["QQQ", "SPY", "SLV"];
        for (uint256 i; i < funds.length; ++i) {
            _seedPriceSource(tierRegistry, funds[i]);
        }
    }

    function _seedCounterparty(address tierRegistry, string memory key) internal returns (bool) {
        address target = _tryReadAddress(key);
        if (target == address(0)) {
            console.log("  counterparty skipped (not in address book):", key);
            return false;
        }
        TierRegistry(tierRegistry).setCounterpartyAllowed(target, true);
        console.log("  counterparty allowed:", key, target);
        return true;
    }

    function _seedAdapter(address tierRegistry, string memory key) internal returns (bool) {
        address target = _tryReadAddress(key);
        if (target == address(0)) {
            console.log("  adapter skipped (not in address book):", key);
            return false;
        }
        TierRegistry(tierRegistry).setAdapterAllowed(target, true);
        console.log("  adapter allowed:", key, target);
        return true;
    }

    /// @dev Allowlists the aggregator and pairs it to the token it prices.
    ///      `priceSource` MUST be the bare aggregator address widened to
    ///      bytes32 with no packed max-age — that is the exact normalization
    ///      `PortfolioStrategy._initialize` applies before calling
    ///      `_requirePairedPriceSource`, so one attestation covers every
    ///      staleness variant of the same feed. Encoding it any other way
    ///      produces an attestation that is never consulted.
    function _seedPriceSource(address tierRegistry, string memory symbol) internal {
        address feed = _tryReadAddress(string.concat("CHAINLINK_", symbol, "_USD_FEED"));
        if (feed == address(0)) {
            console.log("  feed skipped (not in address book):", symbol);
            return;
        }
        TierRegistry(tierRegistry).setAdapterAllowed(feed, true);

        // ETH's feed prices the wrapped token — every other symbol's token key
        // is the symbol itself.
        address token = _tryReadAddress(keccak256(bytes(symbol)) == keccak256("ETH") ? "WETH" : symbol);
        if (token == address(0)) {
            console.log("  feed allowlisted, NO token pairing (token not on this chain):", symbol, feed);
            return;
        }
        TierRegistry(tierRegistry).setPriceSourceForToken(token, bytes32(uint256(uint160(feed))), true);
        console.log("  feed allowlisted + paired:", symbol, feed);
    }

    function _seedRegistry(address deployer, address registryProxy, Config memory cfg) internal {
        IERC20 wood = IERC20(cfg.woodToken);
        uint256 bal = wood.balanceOf(deployer);
        uint256 total = cfg.slashAppealSeed + cfg.epochZeroSeed;
        if (bal < total) {
            console.log("Registry seed skipped: deployer WOOD balance %s < required %s", bal, total);
            return;
        }
        wood.approve(registryProxy, total);
        if (cfg.slashAppealSeed > 0) {
            GuardianRegistry(registryProxy).fundSlashAppealReserve(cfg.slashAppealSeed);
            console.log("SlashAppealReserve seeded:", cfg.slashAppealSeed);
        }
        // WOOD epoch block-rewards distributed via Merkl off-chain. Protocol
        // owner funds Merkl campaign directly (transfer WOOD to merkl
        // distributor). Not scripted into Deploy to keep deployment scope
        // disjoint from off-chain reward infra.
        if (cfg.epochZeroSeed > 0) {
            console.log("Note: epochZeroSeed ignored (moved to Merkl):", cfg.epochZeroSeed);
        }
    }

    /// @dev Best-effort read of a chains/{chainId}.json key. Returns address(0)
    ///      when the file or key is missing — callers treat that as "use env".
    function _tryReadAddress(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");
        try vm.readFile(path) returns (string memory json) {
            try vm.parseJsonAddress(json, string.concat(".", key)) returns (address a) {
                return a;
            } catch {}
        } catch {}
        return address(0);
    }

    /// @notice Hand off ownership of all protocol proxies to the configured
    ///         multisig as the final on-chain action. Called inside the same
    ///         broadcast as the deploys so a single tx-bundle delivers a
    ///         fully-multisig-controlled protocol — there is no window where
    ///         a single deployer key controls a live deployment.
    /// @dev    Vault is intentionally not transferred here: vaults are owned by
    ///         the syndicate creator (set in `SyndicateFactory.createSyndicate`)
    ///         not by the protocol deployer. The deploy script only stamps out
    ///         the singleton implementation, not a live vault instance.
    ///         `swoodProxy` may be `address(0)` in beta mode (sWOOD is not
    ///         deployed there); the transfer is skipped in that case.
    function _handoffOwnership(
        address governorAddr,
        address factoryAddr,
        address registryAddr,
        address swoodProxy,
        address protocolConfig,
        address ownerMultisig
    ) internal {
        console.log("\n=== Multisig handoff ===");
        console.log("Transferring ownership to:", ownerMultisig);
        Ownable(governorAddr).transferOwnership(ownerMultisig);
        Ownable(factoryAddr).transferOwnership(ownerMultisig);
        Ownable(registryAddr).transferOwnership(ownerMultisig);
        if (swoodProxy != address(0)) {
            Ownable(swoodProxy).transferOwnership(ownerMultisig);
        }
        // C1 (review): ProtocolConfig owns protocol-wide fee bps + recipients
        // (up to 10%/5% of every vault's gross profit). It is Ownable2Step, so
        // this starts a two-step transfer — the multisig MUST call
        // `ProtocolConfig.acceptOwnership()` to complete it. Until then the
        // deployer retains control; the validation below asserts pendingOwner.
        Ownable2Step(protocolConfig).transferOwnership(ownerMultisig);
        console.log("Governor / Factory / Registry / sWOOD -> multisig (single-step)");
        console.log("ProtocolConfig pending -> multisig; RUNBOOK: multisig must call acceptOwnership()");
    }

    function _validateBeacon(address expectedOwner, address beaconAddr) internal view {
        console.log("\n=== Validating GovernorBeacon ===");
        // Beacon owner must be the multisig post-handoff (or deployer when
        // handoff was skipped). Per-vault governors are deployed lazily at
        // `createSyndicate`, so there is no singleton governor to validate here.
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

        // Post-handoff factory owner must be the multisig.
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
        // Post-handoff registry owner must be the multisig.
        _checkAddr("registry.owner", Ownable(registryAddr).owner(), expectedOwner);
        // registry.governor removed — multi-governor set; governors added via addGovernor post-deploy.
        _checkAddr("registry.factory", reg.factory(), factoryAddr);
        // sWOOD is the sole WOOD custodian post-split — validate the registry's
        // sWOOD handle and that sWOOD itself custodies the right WOOD token.
        address swoodAddr = address(reg.swood());
        _checkAddr("swood.wood", address(StakedWood(swoodAddr).wood()), wood);
        _checkAddr("swood.registry", StakedWood(swoodAddr).registry(), registryAddr);
        _checkUint("registry.reviewPeriod", reg.reviewPeriod(), DEFAULT_REVIEW_PERIOD);
        _checkUint("registry.blockQuorumBps", reg.blockQuorumBps(), DEFAULT_BLOCK_QUORUM_BPS);
        // Per-vault governors are deployed at createSyndicate and authorized on
        // the registry via addGovernor; there is no singleton governor to check
        // registry linkage against at deploy time.
    }

    function _chainName() internal view returns (string memory) {
        if (block.chainid == 8453) return "Base";
        if (block.chainid == 84532) return "Base Sepolia";
        if (block.chainid == 46630) return "Robinhood L2 Testnet";
        if (block.chainid == 42161) return "Arbitrum";
        return "Unknown";
    }
}
