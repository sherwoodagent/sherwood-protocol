// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockGovernorForStrategyHooks} from "./mocks/MockGovernorForStrategyHooks.sol";

/// @title VaultStrategyHooksTest
/// @notice TDD tests for the `strategyMint` / `strategyBurn` vault hooks added
///         in Phase 2 of the Leveraged Aerodrome CL strategy implementation.
///
///         The vault's `_activeStrategy()` reads through the governor:
///           `ISyndicateFactory(_factory).governor()` → `getActiveProposal(vault)` → `getProposal(pid).strategy`
///         We control it by deploying a real MockGovernorForStrategyHooks and
///         wiring it via `vm.mockCall` on the test-contract-as-factory.
contract VaultStrategyHooksTest is Test {
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockGovernorForStrategyHooks public mockGov;

    address public owner = makeAddr("owner");
    address public alice = makeAddr("alice");
    address public activeStrategy = makeAddr("activeStrategy");

    uint256 constant PID = 1;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        // Deploy real MockGovernorForStrategyHooks.
        mockGov = new MockGovernorForStrategyHooks();

        // Deploy vault via UUPS proxy; test contract acts as the factory.
        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = SyndicateVault(payable(address(proxy)));

        // Test contract is the factory; wire governor() and priceRouter() via mockCall.
        vm.mockCall(address(this), abi.encodeWithSignature("governor()"), abi.encode(address(mockGov)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        // Default: no active proposal (unlocked), to satisfy the deposit/withdraw gates.
        vm.mockCall(address(mockGov), abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(0)));
        vm.mockCall(address(mockGov), abi.encodeWithSignature("openProposalCount(address)"), abi.encode(uint256(0)));

        // Now wire an active proposal so _activeStrategy() returns activeStrategy.
        mockGov.setActiveProposal(address(vault), PID);
        mockGov.setStrategy(PID, activeStrategy);

        // Override the blanket mockCall for getActiveProposal to return PID for this vault.
        vm.mockCall(
            address(mockGov), abi.encodeWithSignature("getActiveProposal(address)", address(vault)), abi.encode(PID)
        );
    }

    // ── Test 1: strategyMint reverts for a non-strategy caller ──

    function test_strategyMint_revertsForStranger() public {
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotActiveStrategy.selector);
        vault.strategyMint(alice, 5e18);
    }

    // ── Test 2: strategyBurn reverts for a non-strategy caller ──

    function test_strategyBurn_revertsForStranger() public {
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotActiveStrategy.selector);
        vault.strategyBurn(2e18);
    }

    // ── Test 3: strategyMint mints shares to `to` and auto-delegates ──

    function test_strategyMint_mintsAndAutoDelegates() public {
        vm.prank(activeStrategy);
        vault.strategyMint(alice, 5e18);

        assertEq(vault.balanceOf(alice), 5e18, "balance mismatch");
        assertEq(vault.delegates(alice), alice, "auto-delegate not set");
    }

    // ── Test 4: strategyBurn burns from msg.sender (the strategy) ──

    function test_strategyBurn_burnsFromStrategy() public {
        // First give the strategy 5e18 shares.
        vm.prank(activeStrategy);
        vault.strategyMint(address(activeStrategy), 5e18);

        // Burn 2e18.
        vm.prank(activeStrategy);
        vault.strategyBurn(2e18);

        assertEq(vault.balanceOf(address(activeStrategy)), 3e18, "balance after burn");
        assertEq(vault.totalSupply(), 3e18, "totalSupply after burn");
    }

    // ── Test 5: strategyMint reverts when vault is paused ──

    function test_strategyMint_revertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(activeStrategy);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.strategyMint(alice, 1e18);
    }
}
