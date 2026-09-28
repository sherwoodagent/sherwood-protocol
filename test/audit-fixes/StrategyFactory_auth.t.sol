// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockMToken} from "../mocks/MockMToken.sol";

/// @dev Stand-in for `SyndicateFactory.vaultToSyndicate(address)`. We do not
///      pull in the real factory because that would force a UUPS proxy +
///      governor + registry stand-up just to test a single auth gate.
contract MockSyndicateRegistry {
    mapping(address => uint256) public vaultToSyndicate;

    function register(address vault, uint256 id) external {
        vaultToSyndicate[vault] = id;
    }
}

/// @dev Minimal vault stand-in.
contract MockVault {
    address public owner;
    mapping(address => bool) public agents;

    constructor(address owner_) {
        owner = owner_;
    }

    function setAgent(address a, bool active) external {
        agents[a] = active;
    }

    function isAgent(address a) external view returns (bool) {
        return agents[a];
    }
}

/// @title StrategyFactory_auth
/// @notice `cloneAndInit` / `cloneAndInitDeterministic` are permissionless: anyone may
///         mint a clone of an approved template bound to a registered vault, naming
///         themselves as proposer. The vault-registered check and the template allowlist
///         are the only gates.
contract StrategyFactoryAuthTest is Test {
    StrategyFactory public factory;
    MockSyndicateRegistry public registry;
    MockStrategy public template;
    ERC20Mock public usdc;
    MockMToken public mUsdc;

    MockVault public registeredVault;
    MockVault public unregisteredVault;
    address public vaultOwner = makeAddr("vaultOwner");
    address public agentAddr = makeAddr("agent");
    address public attacker = makeAddr("attacker");
    address public proposer = makeAddr("proposer");

    function setUp() public {
        registry = new MockSyndicateRegistry();

        registeredVault = new MockVault(vaultOwner);
        registeredVault.setAgent(agentAddr, true);
        unregisteredVault = new MockVault(vaultOwner);

        registry.register(address(registeredVault), 1);

        factory = new StrategyFactory(address(registry), address(this));
        template = new MockStrategy();
        // Sherlock #34: allowlist template for cloneAndInit happy path.
        factory.setTemplateApproval(address(template), true);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        mUsdc = new MockMToken(address(usdc), "Moonwell USDC", "mUsdc");
    }

    function _initData() internal view returns (bytes memory) {
        return abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
    }

    // ── Constructor guards ──

    function test_constructor_zeroSyndicateFactory_reverts() public {
        vm.expectRevert(StrategyFactory.InvalidSyndicateFactory.selector);
        new StrategyFactory(address(0), address(this));
    }

    /// @notice Sherlock run #1 finding #34 — clone reverts for a template
    ///         not on the allowlist.
    function test_cloneAndInit_revertsForUnapprovedTemplate() public {
        MockStrategy bad = new MockStrategy();
        vm.prank(vaultOwner);
        vm.expectRevert(abi.encodeWithSelector(StrategyFactory.TemplateNotApproved.selector, address(bad)));
        factory.cloneAndInit(address(bad), address(registeredVault), proposer, _initData());
    }

    function test_setTemplateApproval_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.setTemplateApproval(address(template), false);
    }

    // ── cloneAndInit ──

    /// @notice MS-C2: an unregistered vault always fails — even when the caller
    ///         IS that vault (no spoofing the membership view).
    function test_cloneAndInit_revertsForUnregisteredVault() public {
        vm.prank(address(unregisteredVault));
        vm.expectRevert(StrategyFactory.VaultNotRegistered.selector);
        factory.cloneAndInit(address(template), address(unregisteredVault), proposer, _initData());
    }

    /// @notice Happy path: the vault owner (creator pre-deploy).
    /// @dev Sherlock run #2 #9 partial: `proposer == msg.sender` constraint
    ///      means the caller is the proposer.
    function test_cloneAndInit_succeedsForVaultOwner() public {
        vm.prank(vaultOwner);
        address clone = factory.cloneAndInit(address(template), address(registeredVault), vaultOwner, _initData());
        assertTrue(clone != address(0));
    }

    /// @notice Sherlock run #2 #9 partial: an authorized caller (vault
    ///         owner) passing a DIFFERENT address as `proposer` reverts.
    ///         Closes the audit's external-X attack vector at the factory:
    ///         the strategy clone's `_proposer` is guaranteed to be the
    ///         deployer (the authorized caller), so post-execution
    ///         `onlyProposer` mutation rights can't land on an arbitrary
    ///         external address. (Cross-agent mismatch — A deploys, B
    ///         proposes via governor — is NOT closed here; that needs the
    ///         deferred governor-side check.)
    function test_cloneAndInit_revertsWhenProposerIsNotSender() public {
        vm.prank(vaultOwner);
        vm.expectRevert(StrategyFactory.ProposerMustBeSender.selector);
        factory.cloneAndInit(address(template), address(registeredVault), attacker, _initData());
    }

    function test_cloneAndInitDeterministic_revertsWhenProposerIsNotSender() public {
        vm.prank(vaultOwner);
        vm.expectRevert(StrategyFactory.ProposerMustBeSender.selector);
        factory.cloneAndInitDeterministic(
            address(template), address(registeredVault), attacker, _initData(), bytes32("salt")
        );
    }

    /// @notice Happy path: a registered agent (agent pre-deploy).
    /// @dev Sherlock run #2 #9 partial: `proposer == msg.sender` constraint.
    function test_cloneAndInit_succeedsForRegisteredAgent() public {
        vm.prank(agentAddr);
        address clone = factory.cloneAndInit(address(template), address(registeredVault), agentAddr, _initData());
        assertTrue(clone != address(0));
    }

    /// @notice Anyone may clone: a random EOA with no relation to the vault succeeds.
    function test_cloneAndInit_succeedsForRandomEoa() public {
        vm.prank(attacker);
        address clone = factory.cloneAndInit(address(template), address(registeredVault), attacker, _initData());
        assertEq(MockStrategy(payable(clone)).vault(), address(registeredVault));
        assertEq(factory.cloneTemplate(clone), address(template), "provenance recorded for every clone");
    }

    function testFuzz_cloneAndInit_succeedsForAnyCaller(address caller) public {
        vm.assume(caller != address(0));
        vm.assume(uint160(caller) > 0xff);
        vm.assume(caller.code.length == 0);
        vm.prank(caller);
        address clone = factory.cloneAndInit(address(template), address(registeredVault), caller, _initData());
        assertTrue(clone != address(0));
    }

    // ── cloneAndInitDeterministic ──

    function test_cloneAndInitDeterministic_revertsForUnregisteredVault() public {
        vm.prank(address(unregisteredVault));
        vm.expectRevert(StrategyFactory.VaultNotRegistered.selector);
        factory.cloneAndInitDeterministic(
            address(template), address(unregisteredVault), proposer, _initData(), bytes32("salt")
        );
    }

    function test_cloneAndInitDeterministic_succeedsForRegisteredAgent() public {
        bytes32 salt = keccak256("strategy.salt.1");
        vm.prank(agentAddr);
        // Sherlock run #2 #9 partial: `proposer == msg.sender`.
        address clone = factory.cloneAndInitDeterministic(
            address(template), address(registeredVault), agentAddr, _initData(), salt
        );
        assertTrue(clone != address(0));
        assertEq(MockStrategy(payable(clone)).vault(), address(registeredVault));
    }

    // ── Fuzz: no random caller can clone (must be vault/owner/agent) ──
}
