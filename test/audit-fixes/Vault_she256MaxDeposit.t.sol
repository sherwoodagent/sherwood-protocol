// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @notice SHE-256: `maxDeposit` / `maxMint` report 0 on every gate `deposit`
///         enforces (pause, `depositsLocked`, closed-mode whitelist), and the
///         refused deposit keeps its named error.
contract Vault_she256MaxDepositTest is Test {
    SyndicateVault vault;
    ERC20Mock usdc;
    MockProposalStatus governor;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        MockAgentRegistry agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: false,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        governor = new MockProposalStatus();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        vm.prank(owner);
        vault.approveDepositor(alice);
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    function test_maxDepositIsZeroWhileAProposalIsOpenOrTheCallerIsNotWhitelisted() public {
        // Open, whitelisted: unbounded, and a deposit lands.
        assertEq(vault.maxDeposit(alice), type(uint256).max, "whitelisted receiver, no proposal");
        assertEq(vault.maxMint(alice), type(uint256).max);
        vm.prank(alice);
        vault.deposit(100e6, alice);

        // Receiver not whitelisted (closed mode): 0, and the named error survives.
        assertEq(vault.maxDeposit(bob), 0, "non-whitelisted receiver");
        assertEq(vault.maxMint(bob), 0);
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        vault.deposit(100e6, bob);

        // Open proposal: 0 for everyone, `DepositsLocked` on the call.
        governor.set(1, 1, address(0));
        assertTrue(vault.depositsLocked(), "precondition: locked");
        assertEq(vault.maxDeposit(alice), 0, "open proposal");
        assertEq(vault.maxMint(alice), 0);
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(100e6, alice);
        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.mint(1, alice);
        governor.set(0, 0, address(0));
        assertEq(vault.maxDeposit(alice), type(uint256).max, "unlocked again");

        // Open-deposit mode lifts the whitelist leg only.
        vm.prank(owner);
        vault.setOpenDeposits(true);
        assertEq(vault.maxDeposit(bob), type(uint256).max, "open deposits");

        // Paused: 0.
        vm.prank(owner);
        vault.pause();
        assertEq(vault.maxDeposit(alice), 0, "paused");
        assertEq(vault.maxMint(alice), 0);
    }
}
