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
 *     PROTOCOL_FEE      — Protocol fee in bps (default: 200 = 2%)
 *     MAX_STRATEGY_DAYS — Max strategy duration in days (default: 14)
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
    uint256 constant DEFAULT_BLOCK_QUORUM_BPS = 3000; // 30%
    uint256 constant DEFAULT_SLASH_APPEAL_SEED = 1_000_000e18;
    uint256 constant DEFAULT_EPOCH_ZERO_SEED = 10_000e18;
    uint256 constant DEFAULT_MIN_SLASH_BPS = 1000; // 10%
    // C-2: strict `< 10_000` cap on `maxSlashBps`. A 100% slash zeroes
    // `poolTokens` while `poolShares` stay nonzero, bricking the delegation
    // pool (subsequent `delegateStake` reverts in `Math.mulDiv`). 9_999 is
    // the highest value that keeps at least 1 wei in the pool.
    uint256 constant DEFAULT_MAX_SLASH_BPS = 9999; // 99.99%

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
        address governorProxy;
        address factoryProxy;
        address registryProxy;
        address swoodProxy;
    }

    function run() external {
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
        console.log("GovernorProxy:", d.governorProxy);
        console.log("GuardianRegistryProxy:", d.registryProxy);
        console.log("FactoryProxy:", d.factoryProxy);
        console.log("Governor.setFactory applied");

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
            _handoffOwnership(d.governorProxy, d.factoryProxy, d.registryProxy, d.swoodProxy, ownerMultisig);
            effectiveOwner = ownerMultisig;
        }

        vm.stopBroadcast();

        // ── Validate ──
        _validateGovernor(effectiveOwner, d.deployer, d.governorProxy, d.factoryProxy, cfg);
        _validateFactory(
            effectiveOwner,
            d.governorProxy,
            d.factoryProxy,
            d.executorLib,
            d.vaultImpl,
            cfg.ensRegistrar,
            cfg.agentRegistry,
            cfg.managementFeeBps
        );
        if (!cfg.betaMode) {
            _validateRegistry(effectiveOwner, d.registryProxy, d.governorProxy, d.factoryProxy, cfg.woodToken);
        }

        // ── Persist ──
        _writeAddresses(_chainName(), d.deployer, d.factoryProxy, d.governorProxy, d.executorLib, d.vaultImpl);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        // sWOOD is the sole WOOD custodian — persist it for the CLI / admin
        // scripts. Beta mode uses a stub registry and never deploys sWOOD, so
        // the proxy stays address(0) there.
        if (d.swoodProxy != address(0)) {
            _patchAddress("STAKED_WOOD", d.swoodProxy);
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

        address govImpl = c3.deploy(SALT_GOVERNOR_IMPL, abi.encodePacked(type(SyndicateGovernor).creationCode));
        d.governorProxy = _deployGovernorProxy(c3, govImpl, d.deployer, registryAddr, cfg);

        address predictedFactoryProxy = c3.addressOf(SALT_FACTORY_PROXY);
        if (!cfg.betaMode) {
            // sWOOD is the sole WOOD custodian: deploy it before the registry
            // so the registry's `initialize` can take the sWOOD address. The
            // registry↔sWOOD circular dependency is resolved by the set-once
            // `setRegistry` call below (deploy order: sWOOD → registry → wire).
            d.swoodProxy = _deploySwoodProxy(c3, d.deployer, d.governorProxy, predictedFactoryProxy, cfg);

            address registryImpl = c3.deploy(SALT_REGISTRY_IMPL, abi.encodePacked(type(GuardianRegistry).creationCode));
            d.registryProxy = _deployRegistryProxy(
                c3, registryImpl, d.deployer, d.governorProxy, predictedFactoryProxy, d.swoodProxy
            );
            require(d.registryProxy == registryAddr, "registry addr mismatch");

            // Wire the set-once registry reference on sWOOD.
            StakedWood(d.swoodProxy).setRegistry(d.registryProxy);
        } else {
            d.registryProxy = registryAddr;
        }

        address factoryImpl = c3.deploy(SALT_FACTORY_IMPL, abi.encodePacked(type(SyndicateFactory).creationCode));
        d.factoryProxy = _deployFactoryProxy(c3, factoryImpl, d, cfg);
        require(d.factoryProxy == predictedFactoryProxy, "factory addr mismatch");

        SyndicateGovernor(d.governorProxy).setFactory(d.factoryProxy);
    }

    /// @dev Deploys the StakedWood (sWOOD) proxy via CREATE3. The governor +
    ///      factory proxy addresses are predicted (CREATE3 is address-stable),
    ///      so sWOOD can be initialized before either is deployed.
    function _deploySwoodProxy(
        Create3Factory c3,
        address deployer,
        address governorProxy,
        address predictedFactoryProxy,
        Config memory cfg
    ) internal returns (address) {
        address swoodImpl = c3.deploy(SALT_SWOOD_IMPL, abi.encodePacked(type(StakedWood).creationCode));
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: cfg.woodToken,
                    governor: governorProxy,
                    factory: predictedFactoryProxy,
                    minGuardianStake: DEFAULT_MIN_GUARDIAN_STAKE,
                    coolDownPeriod: DEFAULT_COOLDOWN,
                    minOwnerStake: DEFAULT_MIN_OWNER_STAKE,
                    minSlashBps: DEFAULT_MIN_SLASH_BPS,
                    maxSlashBps: DEFAULT_MAX_SLASH_BPS
                }))
        );
        return
            c3.deploy(
                SALT_SWOOD_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(swoodImpl, initData))
            );
    }

    function _deployGovernorProxy(
        Create3Factory c3,
        address govImpl,
        address deployer,
        address registryProxy,
        Config memory cfg
    ) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                ISyndicateGovernor.InitParams({
                    owner: deployer,
                    votingPeriod: cfg.votingPeriod,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1000,
                    cooldownPeriod: cfg.betaMode ? 1 hours : 1 days,
                    collaborationWindow: cfg.betaMode ? 24 hours : 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: cfg.maxStrategyDays * 1 days,
                    protocolFeeBps: cfg.protocolFeeBps,
                    protocolFeeRecipient: deployer,
                    guardianFeeBps: 0
                }),
                registryProxy
            )
        );
        return c3.deploy(
            SALT_GOVERNOR_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(govImpl, initData))
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
                    governor: d.governorProxy,
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
        address governorProxy,
        address predictedFactoryProxy,
        address swoodProxy
    ) internal returns (address) {
        bytes memory initData = abi.encodeCall(
            GuardianRegistry.initialize,
            (
                deployer,
                governorProxy,
                predictedFactoryProxy,
                swoodProxy,
                DEFAULT_REVIEW_PERIOD,
                DEFAULT_BLOCK_QUORUM_BPS
            )
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
        console.log("Governor / Factory / Registry / sWOOD now owned by multisig");
    }

    function _validateGovernor(
        address expectedOwner,
        address deployer,
        address governorAddr,
        address factoryAddr,
        Config memory cfg
    ) internal view {
        console.log("\n=== Validating Governor ===");
        SyndicateGovernor governor = SyndicateGovernor(governorAddr);
        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();

        // Post-handoff `owner()` must match the multisig (or deployer
        // when handoff was skipped via SKIP_MULTISIG_HANDOFF).
        _checkAddr("gov.owner", Ownable(governorAddr).owner(), expectedOwner);
        _checkUint("gov.votingPeriod", p.votingPeriod, cfg.votingPeriod);
        _checkUint("gov.executionWindow", p.executionWindow, 1 days);
        _checkUint("gov.vetoThresholdBps", p.vetoThresholdBps, 4000);
        _checkUint("gov.maxPerformanceFeeBps", p.maxPerformanceFeeBps, 1000);
        _checkUint("gov.cooldownPeriod", p.cooldownPeriod, cfg.betaMode ? 1 hours : 1 days);
        _checkUint("gov.collaborationWindow", p.collaborationWindow, cfg.betaMode ? 24 hours : 48 hours);
        _checkUint("gov.maxCoProposers", p.maxCoProposers, 5);
        _checkUint("gov.minStrategyDuration", p.minStrategyDuration, 1 hours);
        _checkUint("gov.maxStrategyDuration", p.maxStrategyDuration, cfg.maxStrategyDays * 1 days);
        _checkUint("gov.protocolFeeBps", governor.protocolFeeBps(), cfg.protocolFeeBps);
        // protocolFeeRecipient stays at deployer at init time. Out of scope
        // for the multisig handoff (owner-only); the new multisig owner can rotate
        // it post-handoff via `setProtocolFeeRecipient`.
        _checkAddr("gov.protocolFeeRecipient", governor.protocolFeeRecipient(), deployer);
        // Factory + guardian-fee recipient are set directly in step 6.
        // Validate the live values.
        _checkAddr("gov.factory", governor.factory(), factoryAddr);
        // guardianFeeBps defaults to 0 at init (fee stream disabled until the
        // multisig is ready); recipient is wired to the registry immediately
        // so we can flip bps > 0 later with a single set call.
        _checkUint("gov.guardianFeeBps", governor.guardianFeeBps(), 0);
        // Recipient is pinned to `_guardianRegistry` — no separate field to
        // validate (registry validation below asserts the pointer).
    }

    function _validateFactory(
        address expectedOwner,
        address governorAddr,
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
        _checkAddr("factory.governor", factory.governor(), governorAddr);
        _checkAddr("factory.executorImpl", factory.executorImpl(), executorLibAddr);
        _checkAddr("factory.vaultImpl", factory.vaultImpl(), vaultImplAddr);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), ensRegistrar);
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), agentRegistry);
        _checkUint("factory.managementFeeBps", factory.managementFeeBps(), mgmtFeeBps);

        console.log("=== All checks passed ===");
    }

    function _validateRegistry(
        address expectedOwner,
        address registryAddr,
        address governorAddr,
        address factoryAddr,
        address wood
    ) internal view {
        console.log("=== Validating GuardianRegistry ===");
        GuardianRegistry reg = GuardianRegistry(registryAddr);
        // Post-handoff registry owner must be the multisig.
        _checkAddr("registry.owner", Ownable(registryAddr).owner(), expectedOwner);
        _checkAddr("registry.governor", reg.governor(), governorAddr);
        _checkAddr("registry.factory", reg.factory(), factoryAddr);
        // sWOOD is the sole WOOD custodian post-split — validate the registry's
        // sWOOD handle and that sWOOD itself custodies the right WOOD token.
        address swoodAddr = address(reg.swood());
        _checkAddr("swood.wood", address(StakedWood(swoodAddr).wood()), wood);
        _checkAddr("swood.registry", StakedWood(swoodAddr).registry(), registryAddr);
        _checkUint("registry.reviewPeriod", reg.reviewPeriod(), DEFAULT_REVIEW_PERIOD);
        _checkUint("registry.blockQuorumBps", reg.blockQuorumBps(), DEFAULT_BLOCK_QUORUM_BPS);
        // Governor knows about the registry (set at init-time).
        // P1-1: recipient is pinned to this same pointer — fees route here.
        _checkAddr("gov.guardianRegistry", SyndicateGovernor(governorAddr).guardianRegistry(), registryAddr);
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
