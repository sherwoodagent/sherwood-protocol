// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";

/**
 * @notice Deploy Sherwood infrastructure to Base:
 *         1. BatchExecutorLib (shared, stateless)
 *         2. SyndicateVault implementation
 *         3. SyndicateFactory (registers both)
 *         4. First syndicate via factory
 *
 *   Usage:
 *     forge script script/Deploy.s.sol:Deploy \
 *       --rpc-url base \
 *       --account sherwood-agent \
 *       --broadcast \
 *       --verify
 */
contract Deploy is Script {
    // Base mainnet USDC
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Moonwell (Base)
    address constant MOONWELL_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    address constant MOONWELL_MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;

    // Uniswap V3 SwapRouter02 (Base)
    address constant UNISWAP_SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    // Tokens to allowlist (for swaps)
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CB_ETH = 0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22;
    address constant WST_ETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant CB_BTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // Durin L2 Registrar (ENS subnames for sherwoodagent.eth)
    address constant L2_REGISTRAR = 0x866996c808E6244216a3d0df15464FCF5d495394;

    // ERC-8004 Agent Identity Registry
    // Base Mainnet: 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432
    // Base Sepolia: 0x8004A818BFB912233c491871b3d84c89A494BD9e
    address constant AGENT_REGISTRY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;

    function run() external {
        address deployer = msg.sender;

        console.log("Deployer:", deployer);

        vm.startBroadcast();

        // 1. Deploy BatchExecutorLib (shared, stateless — deploy once)
        BatchExecutorLib executorLib = new BatchExecutorLib();
        console.log("BatchExecutorLib:", address(executorLib));

        // 2. Deploy SyndicateVault implementation
        SyndicateVault vaultImpl = new SyndicateVault();
        console.log("Vault implementation:", address(vaultImpl));

        // 3. Deploy SyndicateGovernor (UUPS proxy)
        SyndicateGovernor govImpl = new SyndicateGovernor();
        bytes memory govInitData = abi.encodeCall(
            SyndicateGovernor.initialize,
            (ISyndicateGovernor.InitParams({
                    owner: deployer,
                    votingPeriod: 1 days,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 3000,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days,
                    parameterChangeDelay: 1 days,
                    protocolFeeBps: 200,
                    protocolFeeRecipient: deployer
                }))
        );
        address governorProxy = address(new ERC1967Proxy(address(govImpl), govInitData));
        console.log("SyndicateGovernor:", governorProxy);

        // 4. Deploy SyndicateFactory (UUPS proxy)
        SyndicateFactory factoryImpl = new SyndicateFactory();
        bytes memory factoryInitData = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: deployer,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: L2_REGISTRAR,
                    agentRegistry: AGENT_REGISTRY,
                    governor: governorProxy,
                    managementFeeBps: 50
                }))
        );
        SyndicateFactory factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInitData)));
        console.log("SyndicateFactory:", address(factory));

        console.log("\n=== Base Mainnet Deployment Summary ===");
        console.log("FACTORY_ADDRESS=%s", address(factory));
        console.log("GOVERNOR_ADDRESS=%s", governorProxy);
        console.log("EXECUTOR_LIB_ADDRESS=%s", address(executorLib));

        vm.stopBroadcast();
    }
}
