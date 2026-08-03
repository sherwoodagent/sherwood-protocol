// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "./mocks/MockProposalStatus.sol";

/// @notice Strategy mock used as a governor-batch deploy target.
contract MockLiquidStrategy {
    ERC20Mock immutable usdc;
    address immutable vaultAddr;

    constructor(ERC20Mock usdc_, address vault_) {
        usdc = usdc_;
        vaultAddr = vault_;
    }

    function pushBack(uint256 amt) external {
        usdc.transfer(vaultAddr, amt);
    }
}

contract VaultInstantLiquidityTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockLiquidStrategy strat;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    /// @dev The canonical seam adapter (IProposalStatus) — replaces the old
    ///      per-selector vm.mockCall wiring of a phantom governor address.
    MockProposalStatus governor;
    uint256 constant PID = 1;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        strat = new MockLiquidStrategy(usdc, address(vault));

        governor = new MockProposalStatus();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        _setLocked(false);

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(bob, 1_000_000e6);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
    }

    function _setLocked(bool locked) internal {
        // One adapter call replaces 3 per-selector mockCalls (IProposalStatus seam).
        governor.set(locked ? PID : 0, locked ? 1 : 0, locked ? address(strat) : address(0));
    }

    // ── Task 1: minBufferBps setter ──

    function test_minBufferBps_defaultZero() public view {
        assertEq(vault.minBufferBps(), 0, "buffer off by default");
    }

    function test_setMinBufferBps_ownerOnly() public {
        vm.prank(alice);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        vault.setMinBufferBps(1_000);
    }

    function test_setMinBufferBps_setsAndEmits() public {
        vm.prank(owner);
        vm.expectEmit();
        emit ISyndicateVault.MinBufferUpdated(1_000);
        vault.setMinBufferBps(1_000);
        assertEq(vault.minBufferBps(), 1_000);
    }

    function test_setMinBufferBps_revertsAboveCap() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.BufferTooHigh.selector);
        vault.setMinBufferBps(5_001);
    }

    function test_setMinBufferBps_acceptsExactCap() public {
        vm.prank(owner);
        vault.setMinBufferBps(5_000);
        assertEq(vault.minBufferBps(), 5_000);
    }

    function test_setMinBufferBps_resetToZero() public {
        vm.prank(owner);
        vault.setMinBufferBps(1_000);
        vm.prank(owner);
        vault.setMinBufferBps(0);
        assertEq(vault.minBufferBps(), 0);
    }

    /// @dev Build a single-call batch that sends `amount` of vault float to `to`
    ///      (stands in for a strategy deployment pulling capital).
    function _deployBatch(address to, uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.transfer, (to, amount)), value: 0});
    }

    // ── Task 2: buffer enforcement ──

    function test_governorBatch_respectsBuffer() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000); // 10% of 1_000e6 = 100e6 must stay

        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6), new uint256[](0), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
    }

    function test_governorBatch_revertsOnBufferBreach() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);

        vm.prank(address(governor));
        vm.expectRevert(ISyndicateVault.BufferBreached.selector);
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6 + 1), new uint256[](0), type(uint256).max);
    }

    function test_governorBatch_bufferOff_allowsFullDeploy() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 1_000e6), new uint256[](0), type(uint256).max);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_governorBatch_settleBatch_passesTrivially() public {
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(owner);
        vault.setMinBufferBps(1_000);
        vm.prank(address(governor));
        vault.executeGovernorBatch(_deployBatch(address(strat), 900e6), new uint256[](0), type(uint256).max);

        strat.pushBack(900e6);
        vm.prank(address(governor));
        vault.executeGovernorBatch(new BatchExecutorLib.Call[](0), new uint256[](0), type(uint256).max);
    }














}
