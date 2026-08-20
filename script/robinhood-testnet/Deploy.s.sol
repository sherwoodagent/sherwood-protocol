// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {CallSandbox} from "../../src/CallSandbox.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ScriptBase} from "../ScriptBase.sol";

/**
 * @notice Deploy Sherwood protocol infrastructure to Robinhood L2 testnet.
 *
 *         STATUS: SUPERSEDED for new deployments by
 *         `script/robinhood-testnet/DeployV2.s.sol:DeployRobinhoodTestnetV2`,
 *         which deploys the same chain (46630) through the canonical
 *         `DeploySherwood.deployCore` (CREATE3-salted, no hand-maintained nonce
 *         offsets) plus the Synthra adapter / PortfolioStrategy phases. Its
 *         header records that it supersedes the V1 keys in chains/46630.json.
 *         It remains runnable for the bare-core case (SHE-132 fixed the nonce
 *         ledger and the beacon validation that used to abort it), so it carries
 *         the same sandbox binding V2 inherits — a header alone would not stop
 *         `forge script` from bricking every vault it creates.
 *
 *         Robinhood L2 is Arbitrum Orbit — no ENS/Durin or ERC-8004 agent
 *         identity registry. The factory is deployed with address(0) for both,
 *         which disables identity verification and ENS subname registration.
 *
 *   Usage:
 *     forge script script/robinhood-testnet/Deploy.s.sol:DeployRobinhoodTestnet \
 *       --rpc-url robinhood_testnet \
 *       --account sherwood-agent \
 *       --broadcast
 */
contract DeployRobinhoodTestnet is ScriptBase {
    // No ENS or ERC-8004 on Robinhood L2
    address constant L2_REGISTRAR = address(0);
    address constant AGENT_REGISTRY = address(0);

    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood L2 Testnet (chain ID 46630)");

        // 1. Deploy BatchExecutorLib (shared, stateless)
        BatchExecutorLib executorLib = new BatchExecutorLib();
        console.log("BatchExecutorLib:", address(executorLib));

        // 2. Deploy SyndicateVault implementation
        SyndicateVault vaultImpl = new SyndicateVault();
        console.log("Vault implementation:", address(vaultImpl));

        // 2b. Deploy the CallSandbox implementation every vault clones for a
        //     `proposeWithSandbox` payload. Deployed BEFORE the factory (and
        //     before the `vm.getNonce` baseline below, so none of the linear
        //     nonce offsets move) because the vault's binding is set-once and
        //     is stamped at `createSyndicate`: a factory that goes live with an
        //     unbound `sandboxImpl` produces vaults whose `runSandbox` reverts
        //     `SandboxNotConfigured` forever, and `setSandboxImplementation` is
        //     factory-only and one-shot, so those vaults can never be repaired.
        //     Mirrors `script/Deploy.s.sol` (`SALT_SANDBOX_IMPL`).
        CallSandbox sandboxImpl = new CallSandbox();
        console.log("CallSandbox implementation:", address(sandboxImpl));

        // 3. Deploy SyndicateGovernor. Governor init requires the registry
        //    address; registry init requires the governor — resolved by
        //    predicting proxy addresses from the deployer nonce, see the exact
        //    ledger below. sWOOD is the sole WOOD custodian, deployed before
        //    the registry; the registry↔sWOOD circular dependency is resolved
        //    by the set-once `setRegistry` call.
        uint256 baseNonce = vm.getNonce(deployer);
        // EVERY BROADCAST TRANSACTION CONSUMES A NONCE, not just the CREATEs.
        // An earlier version of this comment enumerated only `new` statements
        // and the offsets were short by the two setter CALLs below, so all
        // three `require`s failed and this script could not run at all.
        //
        //   +0  ProtocolConfig                  (CREATE)
        //   +1  protocolConfig.setProtocolFeeRecipient   (CALL)
        //   +2  SyndicateGovernor impl          (CREATE)
        //   +3  GovernorBeacon over that impl   (CREATE) - a BEACON, not a
        //       governor proxy; per-vault governor proxies are minted later by
        //       the factory at `createSyndicate`.
        //   +4  StakedWood impl                 (CREATE)
        //   +5  StakedWood proxy                (CREATE)  <- predicted
        //   +6  GuardianRegistry impl           (CREATE)
        //   +7  GuardianRegistry proxy          (CREATE)  <- predicted
        //   +8  swood.setRegistry               (CALL)
        //   +9  TierRegistry                    (CREATE)
        //   +10 SyndicateFactory impl           (CREATE)
        //   +11 SyndicateFactory proxy          (CREATE)  <- predicted
        //
        // The `require`s below catch a wrong offset before it mis-wires sWOOD /
        // the guardian registry.
        address predictedSwoodProxy = vm.computeCreateAddress(deployer, baseNonce + 5);
        address predictedRegistryProxy = vm.computeCreateAddress(deployer, baseNonce + 7);
        address predictedFactoryProxy = vm.computeCreateAddress(deployer, baseNonce + 11);

        // 3a. Deploy ProtocolConfig (plain Ownable)
        ProtocolConfig protocolConfig = new ProtocolConfig(deployer);
        protocolConfig.setProtocolFeeRecipient(deployer);

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        // Per-vault governor: deploy a GovernorBeacon over the impl (nonce+2,
        // preserving the CREATE-nonce address predictions below). Per-vault
        // governor proxies are cloned by the factory at createSyndicate.
        address beacon = address(new GovernorBeacon(address(govImpl), deployer));
        console.log("GovernorBeacon:", beacon);

        // 3b. Deploy StakedWood (sWOOD) — the sole WOOD custodian.
        address woodToken = vm.envOr("WOOD_TOKEN", address(0x1));
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInitData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: woodToken,
                    factory: predictedFactoryProxy,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        address swoodProxy = address(new ERC1967Proxy(address(swoodImpl), swoodInitData));
        require(swoodProxy == predictedSwoodProxy, "swood addr mismatch");
        console.log("StakedWood:", swoodProxy);

        // 4. Deploy GuardianRegistry at the predicted address.
        GuardianRegistry registryImpl = new GuardianRegistry(6 hours);
        bytes memory regInitData =
            abi.encodeCall(GuardianRegistry.initialize, (deployer, predictedFactoryProxy, swoodProxy, 24 hours, 3000));
        address registryProxy = address(new ERC1967Proxy(address(registryImpl), regInitData));
        require(registryProxy == predictedRegistryProxy, "registry addr mismatch");
        console.log("GuardianRegistry:", registryProxy);

        // Wire the set-once registry reference on sWOOD.
        StakedWood(swoodProxy).setRegistry(registryProxy);

        // 5. Tier registry — mandatory `InitParams` field (pashov finding #1),
        //    so it precedes the factory. Mirrors `script/Deploy.s.sol`.
        TierRegistry tierRegistry = new TierRegistry(deployer);
        console.log("TierRegistry:", address(tierRegistry));

        // 6. Deploy SyndicateFactory (UUPS proxy, no ENS registrar, no agent registry)
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInitData = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: deployer,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: L2_REGISTRAR,
                    agentRegistry: AGENT_REGISTRY,
                    beacon: beacon,
                    protocolConfig: address(protocolConfig),
                    managementFeeBps: 50,
                    guardianRegistry: registryProxy,
                    tierRegistry: address(tierRegistry)
                }))
        );
        SyndicateFactory factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInitData)));
        require(address(factory) == predictedFactoryProxy, "factory addr mismatch");
        console.log("SyndicateFactory:", address(factory));

        // 6b. Bind the sandbox implementation, in the same broadcast that
        //     created the factory and before it can create a single vault. The
        //     deployer is still the factory owner here (`InitParams.owner`), and
        //     `setSandboxImpl` is `onlyOwner`. The `require` is not decoration:
        //     `SyndicateFactory.createSyndicate` SKIPS the binding when
        //     `sandboxImpl == address(0)` rather than reverting, so an unbound
        //     factory fails silently at deploy time and only surfaces as a dead
        //     tier-2 path per vault, unrepairably.
        factory.setSandboxImpl(address(sandboxImpl));
        require(
            factory.sandboxImpl() == address(sandboxImpl), "sandbox impl must be bound before the factory goes live"
        );

        //    Per-vault governors are deployed by the factory at createSyndicate
        //    and authorized on the registry via addGovernor — no singleton wiring.

        vm.stopBroadcast();

        // ── Validate on-chain state matches expected values ──
        _validate(deployer, beacon, address(factory), address(executorLib), address(vaultImpl), address(sandboxImpl));

        // ── Persist addresses to chains/{chainId}.json ──
        _writeAddresses(
            "Robinhood L2 Testnet", deployer, address(factory), address(0), address(executorLib), address(vaultImpl)
        );
        _patchAddress("GOVERNOR_BEACON", beacon);
        _patchAddress("PROTOCOL_CONFIG", address(protocolConfig));
        _patchAddress("GUARDIAN_REGISTRY", registryProxy);
        _patchAddress("STAKED_WOOD", swoodProxy);

        console.log("\nNote: No ENS or ERC-8004 on this chain.");
        console.log("Identity and attestations remain on Base.");
        console.log("\nNext steps:");
        console.log("  1. sherwood --chain robinhood-testnet syndicate create --subdomain <name> --name <name>");
        console.log("Explorer: https://explorer.testnet.chain.robinhood.com/address/%s", address(factory));
    }

    function _validate(
        address deployer,
        address governorAddr,
        address factoryAddr,
        address executorLibAddr,
        address vaultImplAddr,
        address sandboxImplAddr
    ) internal view {
        console.log("\n=== Validating on-chain state ===");

        SyndicateFactory factory = SyndicateFactory(factoryAddr);

        // ── Governor beacon ──
        // NO GOVERNOR INSTANCE EXISTS AT DEPLOY TIME, and that is by design:
        // every syndicate gets its OWN governor, minted by the factory as a
        // BeaconProxy at `createSyndicate` and recorded in `_governorOf` in the
        // same call, which is what makes "a syndicate always has a governor
        // attached" structural rather than a convention.
        //
        // So the invariant this ceremony can actually assert is the one that
        // makes that guarantee hold: the beacon resolves to a real governor
        // implementation, because that implementation is the code every future
        // per-vault governor proxy will run. A beacon pointing at nothing would
        // mint syndicates whose governors are inert.
        //
        // `_params` is deliberately NOT read here. It is per-proxy STORAGE,
        // written by each governor's own `initialize`, so on the uninitialized
        // implementation it reads back all zeros - asserting it would either
        // fail or, worse, pass against zeros. The constructor floors below are
        // immutable, live in bytecode rather than storage, and therefore read
        // correctly off the implementation (and through every proxy over it).
        address governorImpl = GovernorBeacon(governorAddr).implementation();
        require(governorImpl != address(0), "beacon implementation unset");
        require(governorImpl.code.length != 0, "beacon implementation has no code");
        console.log("beacon.implementation:", governorImpl);
        _checkAddr("beacon.owner", Ownable(governorAddr).owner(), deployer);
        _checkUint("govImpl.MIN_VOTING_PERIOD", SyndicateGovernor(governorImpl).MIN_VOTING_PERIOD(), 24 hours);
        _checkUint("govImpl.MIN_COOLDOWN_PERIOD", SyndicateGovernor(governorImpl).MIN_COOLDOWN_PERIOD(), 1 hours);

        // ── Factory ──
        _checkAddr("factory.owner", Ownable(factoryAddr).owner(), deployer);
        _checkAddr("factory.beacon", factory.beacon(), governorAddr);
        _checkAddr("factory.executorImpl", factory.executorImpl(), executorLibAddr);
        _checkAddr("factory.vaultImpl", factory.vaultImpl(), vaultImplAddr);
        // No ENS or agent registry on Robinhood L2 — expect address(0)
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));
        _checkUint("factory.managementFeeBps", factory.managementFeeBps(), 50);
        // Without this the permissionless tier-2 path is dead on arrival for
        // every vault this factory ever creates (see 6b above).
        _checkAddr("factory.sandboxImpl", factory.sandboxImpl(), sandboxImplAddr);

        console.log("=== All checks passed ===");
    }
}
