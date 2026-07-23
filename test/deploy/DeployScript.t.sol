// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create3Factory} from "../../src/Create3Factory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @notice Simulates the Deploy.s.sol sequence (without `forge script`) to
///         confirm the circular dep between GuardianRegistry + SyndicateFactory
///         is resolved via CREATE3 address prediction. This is the CI-friendly
///         version of "did the deploy script run" — no fork needed.
///
///         The production script broadcasts the same sequence; running it with
///         a live fork requires `BASE_RPC_URL`/etc. which we don't assume is
///         set in CI.
contract DeployScriptTest is Test {
    bytes32 constant SALT_EXECUTOR = keccak256("sherwood.deploy.executor.2");
    bytes32 constant SALT_VAULT_IMPL = keccak256("sherwood.deploy.vault-impl.2");
    bytes32 constant SALT_GOVERNOR_IMPL = keccak256("sherwood.deploy.governor-impl.2");
    bytes32 constant SALT_GOVERNOR_PROXY = keccak256("sherwood.deploy.governor-proxy.2");
    bytes32 constant SALT_FACTORY_IMPL = keccak256("sherwood.deploy.factory-impl.2");
    bytes32 constant SALT_FACTORY_PROXY = keccak256("sherwood.deploy.factory-proxy.2");
    bytes32 constant SALT_REGISTRY_IMPL = keccak256("sherwood.deploy.guardian-registry-impl.1");
    bytes32 constant SALT_REGISTRY_PROXY = keccak256("sherwood.deploy.guardian-registry-proxy.1");

    function test_predictedFactoryAddressMatchesRealDeploy() public {
        address deployer = address(this);
        ERC20Mock wood = new ERC20Mock("WOOD", "WOOD", 18);

        Create3Factory c3 = new Create3Factory(deployer);

        // Irrelevant pre-steps (executor, vault impl) for this test — skip to
        // the governor+registry+factory triangle.
        //
        // The governor init needs the registry address; the registry init needs
        // the governor address. Resolve via CREATE3 `addressOf` prediction.
        address predictedRegistryProxy = c3.addressOf(SALT_REGISTRY_PROXY);
        assertTrue(predictedRegistryProxy != address(0));
        address predictedFactoryProxy = c3.addressOf(SALT_FACTORY_PROXY);
        assertTrue(predictedFactoryProxy != address(0));

        // Per-vault design mirror of Deploy.s.sol: governor impl via CREATE3,
        // wrapped in a GovernorBeacon. No singleton governor proxy exists —
        // the factory clones per-vault BeaconProxies at createSyndicate.
        address govImpl = c3.deploy(
            SALT_GOVERNOR_IMPL,
            abi.encodePacked(type(SyndicateGovernor).creationCode, abi.encode(uint256(24 hours), uint256(1 hours)))
        );
        address beacon = address(new GovernorBeacon(govImpl, deployer));
        ProtocolConfig protocolConfig = new ProtocolConfig(deployer);

        // sWOOD — sole WOOD custodian post-split. Plain deploy (CREATE3
        // prediction not exercised for sWOOD here); the registry's slimmed
        // 6-arg `initialize` takes its address.
        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: deployer,
                    wood: address(wood),
                    factory: predictedFactoryProxy,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 10_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        address swood = address(new ERC1967Proxy(address(swoodImpl), swoodInit));

        // Deploy registry at the predicted address. If CREATE3 prediction is
        // off, the factory-bound invariants (e.g. `bindOwnerStake` onlyFactory)
        // would silently point at the wrong address.
        address registryImpl = c3.deploy(
            SALT_REGISTRY_IMPL, abi.encodePacked(type(GuardianRegistry).creationCode, abi.encode(uint256(6 hours)))
        );
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (deployer, predictedFactoryProxy, swood, 24 hours, 3000));
        address registryProxy = c3.deploy(
            SALT_REGISTRY_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(registryImpl, regInit))
        );
        assertEq(registryProxy, predictedRegistryProxy, "CREATE3 registry prediction mismatch");

        // Wire the set-once registry reference on sWOOD (mirrors the deploy
        // script's post-registry `setRegistry` call).
        StakedWood(swood).setRegistry(registryProxy);

        // sWOOD ↔ registry are mutually wired: the registry custodies WOOD via
        // sWOOD, and sWOOD only accepts registry-gated calls from this address.
        assertEq(address(GuardianRegistry(registryProxy).swood()), swood, "registry.swood mismatch");
        assertEq(StakedWood(swood).registry(), registryProxy, "swood.registry mismatch");
        assertEq(address(StakedWood(swood).wood()), address(wood), "swood.wood mismatch");

        // Now deploy the factory and assert its proxy address matches the
        // prediction. Use a tiny vault impl / executor stub — not validated here.
        address executorLib = c3.deploy(SALT_EXECUTOR, abi.encodePacked(type(BatchExecutorLib).creationCode));
        address vaultImpl = c3.deploy(SALT_VAULT_IMPL, abi.encodePacked(type(SyndicateVault).creationCode));
        address factoryImpl = c3.deploy(SALT_FACTORY_IMPL, abi.encodePacked(type(SyndicateFactory).creationCode));
        bytes memory facInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: deployer,
                    executorImpl: executorLib,
                    vaultImpl: vaultImpl,
                    ensRegistrar: address(0),
                    agentRegistry: address(0),
                    beacon: beacon,
                    protocolConfig: address(protocolConfig),
                    managementFeeBps: 50,
                    guardianRegistry: registryProxy
                }))
        );
        address factoryProxy = c3.deploy(
            SALT_FACTORY_PROXY, abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(factoryImpl, facInit))
        );

        assertEq(factoryProxy, predictedFactoryProxy, "CREATE3 factory prediction mismatch");

        // Factory wired to the beacon + config; the beacon points at the impl.
        assertEq(SyndicateFactory(factoryProxy).beacon(), beacon, "factory.beacon mismatch");
        assertEq(SyndicateFactory(factoryProxy).protocolConfig(), address(protocolConfig), "factory.pc mismatch");
        assertEq(GovernorBeacon(beacon).implementation(), govImpl, "beacon impl mismatch");

        // Registry sees the real factory (not deployer placeholder). Per-vault
        // governors are authorized lazily via addGovernor at createSyndicate.
        assertEq(GuardianRegistry(registryProxy).factory(), factoryProxy);
    }
}
