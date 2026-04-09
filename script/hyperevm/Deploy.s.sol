// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Create3} from "../../src/Create3.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ScriptBase} from "../ScriptBase.sol";

/**
 * @notice Deploy Sherwood protocol to HyperEVM via CREATE3.
 *
 *         Uses the same CREATE3 pattern as DeployTokenomics.s.sol — addresses
 *         are deterministic based on (deployer, salt), independent of chain.
 *
 *   Prerequisites:
 *     Enable big blocks: PRIVATE_KEY=0x... python scripts/enable-big-blocks.py
 *
 *   Usage:
 *     forge script script/hyperevm/Deploy.s.sol:DeployHyperEVM \
 *       --rpc-url hyperevm --account <acct> --sender <addr> --broadcast
 */
contract DeployHyperEVM is ScriptBase {
    // ── CREATE3 salts ──
    bytes32 constant SALT_EXECUTOR = keccak256("sherwood.executor.mainnet");
    bytes32 constant SALT_VAULT_IMPL = keccak256("sherwood.vault-impl.mainnet");
    bytes32 constant SALT_GOVERNOR_IMPL = keccak256("sherwood.governor-impl.mainnet");
    bytes32 constant SALT_GOVERNOR_PROXY = keccak256("sherwood.governor-proxy.mainnet");
    bytes32 constant SALT_FACTORY_IMPL = keccak256("sherwood.factory-impl.mainnet");
    bytes32 constant SALT_FACTORY_PROXY = keccak256("sherwood.factory-proxy.mainnet");

    function run() external {
        vm.startBroadcast();

        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // Predict governor proxy address upfront (needed by factory init)
        address predictedGovernorProxy = Create3.addressOf(deployer, SALT_GOVERNOR_PROXY);
        console.log("Predicted GovernorProxy:", predictedGovernorProxy);

        // 1. BatchExecutorLib
        address executorLib = Create3.deploy(SALT_EXECUTOR, abi.encodePacked(type(BatchExecutorLib).creationCode));
        console.log("BatchExecutorLib:", executorLib);

        // 2. SyndicateVault implementation
        address vaultImpl = Create3.deploy(SALT_VAULT_IMPL, abi.encodePacked(type(SyndicateVault).creationCode));
        console.log("VaultImpl:", vaultImpl);

        // 3. SyndicateGovernor implementation
        address govImpl =
            Create3.deploy(SALT_GOVERNOR_IMPL, abi.encodePacked(type(SyndicateGovernor).creationCode));
        console.log("GovernorImpl:", govImpl);

        // 4. SyndicateGovernor proxy
        bytes memory govInitData = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                ISyndicateGovernor.InitParams({
                    owner: deployer,
                    votingPeriod: 1 hours,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 3000,
                    cooldownPeriod: 1 hours,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days,
                    parameterChangeDelay: 1 days,
                    protocolFeeBps: 200,
                    protocolFeeRecipient: deployer
                })
            )
        );
        address governorProxy = Create3.deploy(
            SALT_GOVERNOR_PROXY,
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(govImpl, govInitData))
        );
        console.log("GovernorProxy:", governorProxy);

        // 5. SyndicateFactory implementation
        address factoryImpl =
            Create3.deploy(SALT_FACTORY_IMPL, abi.encodePacked(type(SyndicateFactory).creationCode));
        console.log("FactoryImpl:", factoryImpl);

        // 6. SyndicateFactory proxy
        bytes memory factoryInitData = abi.encodeCall(
            SyndicateFactory.initialize,
            (
                SyndicateFactory.InitParams({
                    owner: deployer,
                    executorImpl: executorLib,
                    vaultImpl: vaultImpl,
                    ensRegistrar: address(0),
                    agentRegistry: address(0),
                    governor: governorProxy,
                    managementFeeBps: 50
                })
            )
        );
        address factoryProxy = Create3.deploy(
            SALT_FACTORY_PROXY,
            abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImpl, factoryInitData))
        );
        console.log("FactoryProxy:", factoryProxy);

        // 7. Register factory on governor
        SyndicateGovernor(governorProxy).setFactory(factoryProxy);
        console.log("Governor.setFactory done");

        vm.stopBroadcast();

        // ── Validate ──
        _validate(deployer, governorProxy, factoryProxy, executorLib, vaultImpl);

        // ── Persist ──
        _writeAddresses("HyperEVM", deployer, factoryProxy, governorProxy, executorLib, vaultImpl);

        console.log("\nNext: forge script script/DeployTemplates.s.sol --rpc-url hyperevm --broadcast");
    }

    function _validate(
        address deployer,
        address governorAddr,
        address factoryAddr,
        address executorLibAddr,
        address vaultImplAddr
    ) internal view {
        console.log("\n=== Validating ===");
        SyndicateFactory factory = SyndicateFactory(factoryAddr);

        _checkAddr("gov.owner", Ownable(governorAddr).owner(), deployer);
        _checkAddr("factory.owner", Ownable(factoryAddr).owner(), deployer);
        _checkAddr("factory.governor", factory.governor(), governorAddr);
        _checkAddr("factory.executorImpl", factory.executorImpl(), executorLibAddr);
        _checkAddr("factory.vaultImpl", factory.vaultImpl(), vaultImplAddr);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));
        _checkUint("factory.managementFeeBps", factory.managementFeeBps(), 50);
        console.log("=== All checks passed ===");
    }
}
