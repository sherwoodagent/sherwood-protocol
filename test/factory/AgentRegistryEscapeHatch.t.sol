// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice `setAgentRegistry` re-points or disables ERC-8004 identity gating for creation and for
///         every vault's `registerAgent`, including vaults created before the change.
contract AgentRegistryEscapeHatchTest is Test {
    event AgentRegistryUpdated(address oldRegistry, address newRegistry);

    SyndicateFactory factory;
    SyndicateVault vault;
    MockAgentRegistry registryA;
    MockAgentRegistry registryB;
    ERC20Mock usdc;

    address owner = makeAddr("owner");
    address creator = makeAddr("creator");
    address agent = makeAddr("agent");
    address guardianRegistry = makeAddr("guardianRegistry");
    address swood = makeAddr("swood");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        registryA = new MockAgentRegistry();
        registryB = new MockAgentRegistry();
        GovernorBeacon beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner);
        bytes memory init = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    agentRegistry: address(registryA),
                    beacon: address(beacon),
                    protocolConfig: address(new ProtocolConfig(owner)),
                    managementFeeBps: 50,
                    guardianRegistry: guardianRegistry,
                    tierRegistry: address(new TierRegistry(owner))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(new SyndicateFactory()), init)));

        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swood));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");

        vault = SyndicateVault(payable(_create(creator, registryA.mint(creator), "first-vault")));
    }

    function _create(address who, uint256 agentId, string memory subdomain) internal returns (address v) {
        SyndicateFactory.SyndicateConfig memory cfg = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://QmTest",
            asset: usdc,
            name: "Vault",
            symbol: "V",
            openDeposits: true,
            subdomain: subdomain
        });
        vm.prank(who);
        (, v) = factory.createSyndicate(agentId, cfg);
    }

    function _setRegistry(address r) internal {
        vm.prank(owner);
        factory.setAgentRegistry(r);
    }

    /// @notice Only the factory owner re-points the registry, and each change is logged.
    function test_setAgentRegistry_onlyOwnerAndEmits() public {
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(OwnableUpgradeable.OwnableUnauthorizedAccount.selector, creator));
        factory.setAgentRegistry(address(0));
        assertEq(address(factory.agentRegistry()), address(registryA), "unchanged");

        vm.expectEmit(address(factory));
        emit AgentRegistryUpdated(address(registryA), address(registryB));
        _setRegistry(address(registryB));
        assertEq(address(factory.agentRegistry()), address(registryB), "set");
    }

    /// @notice With the registry zeroed, creation and registration skip the identity check entirely.
    function test_zeroRegistry_skipsIdentityOnCreateAndRegister() public {
        _setRegistry(address(0));
        address outsider = makeAddr("outsider");
        address v = _create(outsider, 999, "no-identity");
        assertEq(factory.governorOf(v) != address(0), true, "created without an identity");

        vm.prank(creator);
        vault.registerAgent(999, agent);
        assertTrue(vault.isAgent(agent), "registered without an identity");
    }

    /// @notice An existing vault's `registerAgent` follows the factory's current registry, not its init snapshot.
    function test_existingVault_registerAgentUsesCurrentRegistry() public {
        uint256 idInB = registryB.mint(agent);
        address other = makeAddr("other");
        uint256 otherId = registryA.mint(other); // owned by `other` in A only
        registryB.mintId(makeAddr("stranger"), otherId);
        _setRegistry(address(registryB));

        vm.prank(creator);
        vm.expectRevert(ISyndicateVault.NotAgentOwner.selector);
        vault.registerAgent(otherId, other);

        vm.prank(creator);
        vault.registerAgent(idInB, agent);
        assertTrue(vault.isAgent(agent), "registered against the new registry");
    }

    /// @notice A broken registry bricks creation and registration until the owner zeroes it; then both work.
    function test_brokenRegistry_bricksUntilZeroed() public {
        uint256 creatorId = registryA.mint(creator);
        vm.mockCallRevert(address(registryA), abi.encodeWithSelector(IERC721.ownerOf.selector), "broken");

        vm.expectRevert("broken");
        _create(creator, creatorId, "second-vault");
        vm.prank(creator);
        vm.expectRevert("broken");
        vault.registerAgent(creatorId, agent);

        _setRegistry(address(0));
        _create(creator, creatorId, "second-vault");
        vm.prank(creator);
        vault.registerAgent(creatorId, agent);
        assertTrue(vault.isAgent(agent), "registration works again");
    }
}
