// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3Factory} from "../src/Create3Factory.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {GuardianRegistry} from "../src/GuardianRegistry.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {MinimalGuardianRegistry} from "../src/MinimalGuardianRegistry.sol";
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
    // The own-stake severity ceiling may now be a full 100% — own stake is a
    // plain integer with no share math to brick. The C-2 pool-bricking guard
    // (a 100% slash zeroes `poolTokens` while `poolShares` stay nonzero,
    // bricking `delegateStake` in `Math.mulDiv`) lives on
    // `maxDelegatedSlashBps` (< 10_000) below.
    uint256 constant DEFAULT_MAX_SLASH_BPS = 10_000; // 100%
    uint256 constant DEFAULT_MAX_DELEGATED_SLASH_BPS = 2000; // 20%
    uint256 constant DEFAULT_AGE_FLOOR_BPS = 2500; // 25% weight at age 0
    uint256 constant DEFAULT_MATURATION_PERIOD = 30 days;
    uint256 constant DEFAULT_DELEGATED_WEIGHT_CAP_X = 4; // 4x aged own weight

    struct Config {
        address ensRegistrar;
        address agentRegistry;
        uint256 managementFeeBps;
        uint256 protocolFeeBps;
        uint256 maxStrategyDays;
        uint256 votingPeriod;
        address woodToken;
        uint256 slashAppealSeed;
        uint256 epochZeroSeed;
        // Beta mode: stub guardian registry, no WOOD, no multisig handoff,
        // 1h votingPeriod default. Toggled via the BETA_MODE env.
        bool betaMode;
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
    }

    function run() external virtual {
        bool betaMode = vm.envOr("BETA_MODE", false);
        Config memory cfg = Config({
            ensRegistrar: vm.envOr("ENS_REGISTRAR", address(0)),
            agentRegistry: vm.envOr("AGENT_REGISTRY", address(0)),
            managementFeeBps: vm.envOr("MANAGEMENT_FEE", uint256(50)),
            protocolFeeBps: vm.envOr("PROTOCOL_FEE", uint256(100)),
            maxStrategyDays: vm.envOr("MAX_STRATEGY_DAYS", uint256(14)),
            votingPeriod: vm.envOr("VOTING_PERIOD", betaMode ? uint256(1 hours) : uint256(1 days)),
            // WOOD_TOKEN is required for prod (full GuardianRegistry).
            // Beta mode uses a stub registry (no WOOD), so WOOD_TOKEN is ignored.
            woodToken: vm.envOr("WOOD_TOKEN", _tryReadAddress("WOOD_TOKEN")),
            slashAppealSeed: vm.envOr("SLASH_APPEAL_SEED", DEFAULT_SLASH_APPEAL_SEED),
            epochZeroSeed: vm.envOr("EPOCH_ZERO_SEED", DEFAULT_EPOCH_ZERO_SEED),
            betaMode: betaMode
        });
        if (!cfg.betaMode) {
            require(cfg.woodToken != address(0), "WOOD_TOKEN not set (env or chains.json)");
        }

        // Multisig handoff is mandatory in prod. Beta mode keeps the deployer
        // as protocol owner because the multisig is not yet stood up.
        bool skipHandoff = cfg.betaMode || vm.envOr("SKIP_MULTISIG_HANDOFF", false);
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

        // Seed slash appeal reserve + epoch 0 rewards (prod only — beta uses a
        // stub registry with no `fundSlashAppealReserve`). Best-effort: skipped
        // on zero amounts. MUST run before the multisig handoff while the
        // deployer is still the owner.
        if (!cfg.betaMode) {
            _seedRegistry(d.deployer, d.registryProxy, cfg);
        }

        // Multisig handoff: prod hands all proxies to the multisig.
        // Beta keeps the deployer as protocol owner (no multisig yet).
        address effectiveOwner = d.deployer;
        if (!skipHandoff) {
            _handoffOwnership(d.beacon, d.factoryProxy, d.registryProxy, d.swoodProxy, d.protocolConfig, ownerMultisig);
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
        if (!cfg.betaMode) {
            _validateRegistry(effectiveOwner, d.registryProxy, d.factoryProxy, cfg.woodToken);
        }

        // ── Persist ──
        // Per-vault governor: there is NO singleton governor — zero the
        // SYNDICATE_GOVERNOR slot (a beacon address there would make admin
        // scripts revert calling governor ABIs on it) and persist the beacon +
        // ProtocolConfig under explicit keys.
        _writeAddresses(_chainName(), d.deployer, d.factoryProxy, address(0), d.executorLib, d.vaultImpl);
        _patchAddress("GOVERNOR_BEACON", d.beacon);
        _patchAddress("PROTOCOL_CONFIG", d.protocolConfig);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        // sWOOD is the sole WOOD custodian — persist it for the CLI / admin
        // scripts. Beta mode uses a stub registry and never deploys sWOOD, so
        // the proxy stays address(0) there.
        if (d.swoodProxy != address(0)) {
            _patchAddress("STAKED_WOOD", d.swoodProxy);
        }
        // Persist WOOD — Deploy only reads it as an input, so without this it
        // never lands in chains.json (audit gap). Beta mode has no WOOD.
        if (cfg.woodToken != address(0)) {
            _patchAddress("WOOD_TOKEN", cfg.woodToken);
        }

        console.log("\nDeployment complete on %s (chain %s)", _chainName(), block.chainid);
        console.log("Next: forge script script/DeployTemplates.s.sol --rpc-url <chain> --broadcast");
    }

    /// @notice Deployment helper extracted from `run()` for use in fork tests.
    ///         Performs all CREATE3 deploys + governor.setFactory() but does NOT:
    ///           - call `vm.startBroadcast()` / `vm.stopBroadcast()` (caller's responsibility)
    ///           - persist addresses to chains/{chainId}.json
    ///           - validate (callers can if they want)
    /// @dev Used by `HyperEVMIntegrationTest.setUp()` to deploy on a fork without
    ///      writing to disk. Production deploys keep using `run()`.
    function deployCore(Config memory cfg) public returns (Deployed memory d) {
        d.deployer = msg.sender;

        Create3Factory c3 = new Create3Factory(d.deployer);

        d.executorLib = c3.deploy(SALT_EXECUTOR, abi.encodePacked(type(BatchExecutorLib).creationCode));
        d.vaultImpl = c3.deploy(SALT_VAULT_IMPL, abi.encodePacked(type(SyndicateVault).creationCode));

        address registryAddr;
        if (cfg.betaMode) {
            // Beta: stub registry, no proxy, no WOOD. Deployed BEFORE governor
            // so we can pass it directly into governor init.
            registryAddr = address(new MinimalGuardianRegistry());
        } else {
            registryAddr = c3.addressOf(SALT_REGISTRY_PROXY);
        }

        address predictedFactoryProxy = c3.addressOf(SALT_FACTORY_PROXY);

        // Deploy ProtocolConfig (plain Ownable — no proxy needed).
        ProtocolConfig protocolConfig = new ProtocolConfig(d.deployer);
        if (cfg.protocolFeeBps > 0) {
            protocolConfig.setProtocolFeeRecipient(d.deployer);
            protocolConfig.setProtocolFeeBps(cfg.protocolFeeBps);
        }
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
        if (!cfg.betaMode) {
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
        } else {
            d.registryProxy = registryAddr;
        }

        address factoryImpl = c3.deploy(SALT_FACTORY_IMPL, abi.encodePacked(type(SyndicateFactory).creationCode));
        d.factoryProxy = _deployFactoryProxy(c3, factoryImpl, d, cfg);
        require(d.factoryProxy == predictedFactoryProxy, "factory addr mismatch");
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
                    maxDelegatedSlashBps: DEFAULT_MAX_DELEGATED_SLASH_BPS,
                    ageFloorBps: DEFAULT_AGE_FLOOR_BPS,
                    maturationPeriod: DEFAULT_MATURATION_PERIOD,
                    delegatedWeightCapX: DEFAULT_DELEGATED_WEIGHT_CAP_X
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
                    guardianRegistry: d.registryProxy
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
        if (block.chainid == 999) return "HyperEVM";
        if (block.chainid == 998) return "HyperEVM Testnet";
        if (block.chainid == 46630) return "Robinhood L2 Testnet";
        if (block.chainid == 42161) return "Arbitrum";
        return "Unknown";
    }
}
