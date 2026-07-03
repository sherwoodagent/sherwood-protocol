// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {MoonwellSupplyStrategy} from "../src/strategies/MoonwellSupplyStrategy.sol";
import {BaseStrategy} from "../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockMToken} from "./mocks/MockMToken.sol";

/// @dev Minimal SyndicateFactory stand-in that returns a non-zero
///      `vaultToSyndicate(vault)` so legacy unit tests can exercise the
///      happy-path clone fns through the post-MS-C2 auth gate.
contract _MockSyndicateRegistry {
    function vaultToSyndicate(address) external pure returns (uint256) {
        return 1;
    }
}

/// @dev Minimal vault stand-in that exposes IVaultMembership (`owner`,
///      `isAgent`). Strategies are pre-deployed by the vault owner, so the
///      tests prank as the owner.
contract _MockVault {
    address public owner;
    mapping(address => bool) public agents;

    constructor(address owner_) {
        owner = owner_;
    }

    function isAgent(address a) external view returns (bool) {
        return agents[a];
    }
}

contract StrategyFactoryTest is Test {
    StrategyFactory factory;
    MoonwellSupplyStrategy template;
    ERC20Mock usdc;
    MockMToken mUsdc;
    _MockSyndicateRegistry registry;
    _MockVault vault;

    address vaultOwner = makeAddr("vaultOwner");
    address proposer = makeAddr("proposer");
    address attacker = makeAddr("attacker");

    function setUp() public {
        registry = new _MockSyndicateRegistry();
        factory = new StrategyFactory(address(registry), address(this));
        template = new MoonwellSupplyStrategy();
        // Sherlock #34: allowlist template.
        factory.setTemplateApproval(address(template), true);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        mUsdc = new MockMToken(address(usdc), "Moonwell USDC", "mUsdc");
        vault = new _MockVault(vaultOwner);
    }

    function test_cloneAndInit_atomic() public {
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
        vm.prank(vaultOwner);
        address clone = factory.cloneAndInit(address(template), address(vault), vaultOwner, initData);

        MoonwellSupplyStrategy strategy = MoonwellSupplyStrategy(payable(clone));
        assertEq(strategy.vault(), address(vault));
        // Sherlock run #2 #9 partial: proposer == msg.sender (the prank).
        assertEq(strategy.proposer(), vaultOwner);
        assertEq(strategy.supplyAmount(), 1_000e6);
    }

    function test_cloneAndInit_initializeAgain_reverts() public {
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
        vm.prank(vaultOwner);
        address clone = factory.cloneAndInit(address(template), address(vault), vaultOwner, initData);

        // Anyone trying to re-initialize the clone (front-run attack post-init)
        // is rejected by the existing _initialized flag.
        vm.prank(attacker);
        vm.expectRevert(BaseStrategy.AlreadyInitialized.selector);
        MoonwellSupplyStrategy(payable(clone)).initialize(attacker, attacker, initData);
    }

    function test_cloneAndInitDeterministic_predictableAddress() public {
        bytes32 salt = keccak256("strategy.salt.1");
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
        // #387 — the factory binds the salt to the vault; the predictor must fold
        // the same way (keccak256(abi.encode(vault, salt))).
        bytes32 effSalt = keccak256(abi.encode(address(vault), salt));
        address predicted = Clones.predictDeterministicAddress(address(template), effSalt, address(factory));
        vm.prank(vaultOwner);
        address clone = factory.cloneAndInitDeterministic(address(template), address(vault), vaultOwner, initData, salt);
        assertEq(clone, predicted);
    }

    /// @dev #387 front-running defense — the SAME raw salt + template on two
    ///      different vaults yields two DIFFERENT clone addresses (the salt is
    ///      folded with the vault). Without the fold the second deploy would
    ///      collide and revert; with it, an attacker can't precompute (or, via
    ///      `_authClone`, even deploy at) a victim vault's address from a shared
    ///      salt observed in the mempool.
    function test_cloneAndInitDeterministic_saltBoundToVault() public {
        bytes32 salt = keccak256("shared.salt");
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);

        _MockVault vaultB = new _MockVault(vaultOwner);

        vm.prank(vaultOwner);
        address cloneA =
            factory.cloneAndInitDeterministic(address(template), address(vault), vaultOwner, initData, salt);
        vm.prank(vaultOwner);
        address cloneB =
            factory.cloneAndInitDeterministic(address(template), address(vaultB), vaultOwner, initData, salt);

        assertTrue(cloneA != cloneB, "same salt must map to distinct addresses per vault");
        assertEq(
            cloneA,
            Clones.predictDeterministicAddress(
                address(template), keccak256(abi.encode(address(vault), salt)), address(factory)
            )
        );
        assertEq(
            cloneB,
            Clones.predictDeterministicAddress(
                address(template), keccak256(abi.encode(address(vaultB), salt)), address(factory)
            )
        );
    }
}
