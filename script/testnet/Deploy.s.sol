// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ScriptBase} from "../ScriptBase.sol";

/**
 * @notice Deploy Sherwood protocol infrastructure to Base Sepolia (testnet).
 *         Deploys shared infrastructure, validates on-chain state, and writes
 *         addresses to chains/{chainId}.json.
 *
 *   Usage:
 *     forge script script/testnet/Deploy.s.sol:DeployTestnet \
 *       --rpc-url base_sepolia \
 *       --account sherwood-agent \
 *       --broadcast
 */
contract DeployTestnet is ScriptBase {
    // ── Base Sepolia addresses ──

    // Durin L2 Registrar (ENS subnames for sherwoodagent.eth)
    address constant L2_REGISTRAR = 0x1fCbe9dFC25e3fa3F7C55b26c7992684A4758b47;

    // ERC-8004 Agent Identity Registry (Base Sepolia)
    address constant AGENT_REGISTRY = 0x8004A818BFB912233c491871b3d84c89A494BD9e;

    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Base Sepolia (testnet)");

        // 1. Deploy BatchExecutorLib (shared, stateless)
        BatchExecutorLib executorLib = new BatchExecutorLib();
        console.log("BatchExecutorLib:", address(executorLib));

        // 2. Deploy SyndicateVault implementation
        SyndicateVault vaultImpl = new SyndicateVault();
        console.log("Vault implementation:", address(vaultImpl));

        // 3. Deploy SyndicateGovernor (UUPS proxy). Governor init requires the
        //    registry address, but the registry init requires the governor, so
        //    we predict the registry proxy address via `vm.computeCreateAddress`:
        //    govImpl (+0), govProxy (+1), swoodImpl (+2), swoodProxy (+3),
        //    registryImpl (+4), registryProxy (+5), factoryImpl (+6),
        //    factoryProxy (+7). sWOOD is the sole WOOD custodian and is deployed
        //    before the registry; the registry↔sWOOD circular dependency is
        //    resolved by the set-once `setRegistry` call.
        uint256 baseNonce = vm.getNonce(deployer);
        // ProtocolConfig at +0, govImpl +1, govProxy +2, swoodImpl +3, swoodProxy +4,
        // registryImpl +5, registryProxy +6, factoryImpl +7, factoryProxy +8.
        address predictedSwoodProxy = vm.computeCreateAddress(deployer, baseNonce + 4);
        address predictedRegistryProxy = vm.computeCreateAddress(deployer, baseNonce + 6);
        address predictedFactoryProxy = vm.computeCreateAddress(deployer, baseNonce + 8);

        // Deploy ProtocolConfig (plain Ownable)
        ProtocolConfig protocolConfig = new ProtocolConfig(deployer);
        protocolConfig.setProtocolFeeRecipient(deployer);
        protocolConfig.setProtocolFeeBps(200);

        SyndicateGovernor govImpl = new SyndicateGovernor();
        // Per-vault governor: deploy a GovernorBeacon over the impl (keeps the
        // CREATE-nonce address predictions aligned). Governor proxies are cloned
        // per vault by the factory at createSyndicate.
        address beacon = address(new GovernorBeacon(address(govImpl), deployer));
        console.log("GovernorBeacon:", beacon);

        // 3b. Deploy StakedWood (sWOOD) — the sole WOOD custodian. Deployed
        //     before the registry so the registry init can take the sWOOD
        //     address. If WOOD isn't deployed yet on testnet, sWOOD is
        //     initialized with address(0x1) as a placeholder — override via
        //     `WOOD_TOKEN` env var when real WOOD exists.
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
                    maxSlashBps: 9999
                }))
        );
        address swoodProxy = address(new ERC1967Proxy(address(swoodImpl), swoodInitData));
        require(swoodProxy == predictedSwoodProxy, "swood addr mismatch");
        console.log("StakedWood:", swoodProxy);

        // 4. Deploy GuardianRegistry at the predicted address.
        GuardianRegistry registryImpl = new GuardianRegistry();
        bytes memory regInitData = abi.encodeCall(
            GuardianRegistry.initialize,
            (
                deployer,
                predictedFactoryProxy,
                swoodProxy,
                24 hours, // reviewPeriod
                3000 // blockQuorumBps (30%)
            )
        );
        address registryProxy = address(new ERC1967Proxy(address(registryImpl), regInitData));
        require(registryProxy == predictedRegistryProxy, "registry addr mismatch");
        console.log("GuardianRegistry:", registryProxy);

        // Wire the set-once registry reference on sWOOD.
        StakedWood(swoodProxy).setRegistry(registryProxy);

        // 5. Deploy SyndicateFactory (UUPS proxy). Must match predictedFactoryProxy.
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
                    guardianRegistry: registryProxy
                }))
        );
        SyndicateFactory factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInitData)));
        require(address(factory) == predictedFactoryProxy, "factory addr mismatch");
        console.log("SyndicateFactory:", address(factory));

        // 6. Wire governor → factory. Setters apply immediately.
        //    Guardian fee recipient pinned at init — no separate wiring.
        // factory set at governor initialize time (per-vault design)

        vm.stopBroadcast();

        // ── Validate on-chain state matches expected values ──
        _validate(deployer, beacon, address(factory), address(executorLib), address(vaultImpl));

        // ── Persist addresses to chains/{chainId}.json ──
        _writeAddresses(
            "Base Sepolia", deployer, address(factory), address(0), address(executorLib), address(vaultImpl)
        );
        _patchAddress("GOVERNOR_BEACON", beacon);
        _patchAddress("PROTOCOL_CONFIG", address(protocolConfig));
        _patchAddress("GUARDIAN_REGISTRY", registryProxy);
        _patchAddress("STAKED_WOOD", swoodProxy);

        console.log("\nNext steps:");
        console.log("  1. sherwood --testnet identity mint");
        console.log("  2. sherwood --testnet syndicate create --agent-id <id> --subdomain <name> --name <name>");
        console.log("Explorer: https://sepolia.basescan.org/address/%s", address(factory));
    }

    function _validate(
        address deployer,
        address governorAddr,
        address factoryAddr,
        address executorLibAddr,
        address vaultImplAddr
    ) internal view {
        console.log("\n=== Validating on-chain state ===");

        SyndicateGovernor governor = SyndicateGovernor(governorAddr);
        SyndicateFactory factory = SyndicateFactory(factoryAddr);

        // ── Governor ──
        ISyndicateGovernor.GovernorParams memory p = governor.getGovernorParams();

        _checkAddr("gov.owner", Ownable(governorAddr).owner(), deployer);
        _checkUint("gov.votingPeriod", p.votingPeriod, 1 hours);
        _checkUint("gov.executionWindow", p.executionWindow, 1 days);
        _checkUint("gov.vetoThresholdBps", p.vetoThresholdBps, 4000);
        _checkUint("gov.maxPerformanceFeeBps", p.maxPerformanceFeeBps, 3000);
        _checkUint("gov.cooldownPeriod", p.cooldownPeriod, 1 hours);
        _checkUint("gov.collaborationWindow", p.collaborationWindow, 48 hours);
        _checkUint("gov.maxCoProposers", p.maxCoProposers, 5);
        _checkUint("gov.minStrategyDuration", p.minStrategyDuration, 1 hours);
        _checkUint("gov.maxStrategyDuration", p.maxStrategyDuration, 30 days);
        // protocolFeeBps / protocolFeeRecipient moved to ProtocolConfig.

        // ── Factory ──
        _checkAddr("factory.owner", Ownable(factoryAddr).owner(), deployer);
        _checkAddr("factory.beacon", factory.beacon(), governorAddr);
        _checkAddr("factory.executorImpl", factory.executorImpl(), executorLibAddr);
        _checkAddr("factory.vaultImpl", factory.vaultImpl(), vaultImplAddr);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), L2_REGISTRAR);
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), AGENT_REGISTRY);
        _checkUint("factory.managementFeeBps", factory.managementFeeBps(), 50);

        console.log("=== All checks passed ===");
    }
}
