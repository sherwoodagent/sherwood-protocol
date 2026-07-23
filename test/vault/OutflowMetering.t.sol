// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @notice Sink that can hold vault assets and push them back inside a batch
///         (stands in for a strategy returning funds on settle).
contract MockAssetSink {
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

/// @notice Task 4 (spec 2026-07-22 §3.1): `executeGovernorBatch` enforces the
///         proposal's `maxCapital` as a per-batch NET-OUTFLOW cap. Outflow
///         beyond the cap reverts with `MaxNetOutflowExceeded`; inflow
///         (settle) batches compute a zero net outflow and pass any cap.
contract OutflowMeteringTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    MockProposalStatus governor;
    MockAssetSink sink;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");

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
        sink = new MockAssetSink(usdc, address(vault));

        governor = new MockProposalStatus();
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        usdc.mint(alice, 1_000_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
    }

    /// @dev Single-call batch that sends `amount` of vault float to the sink
    ///      (stands in for a strategy deployment pulling capital).
    function _outflowBatch(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (address(sink), amount)), value: 0
        });
    }

    function test_batchWithinCapExecutes() public {
        vm.prank(alice);
        vault.deposit(2_000e6, alice);

        vm.prank(address(governor));
        vault.executeGovernorBatch(_outflowBatch(500e6), 1_000e6);
        assertEq(usdc.balanceOf(address(sink)), 500e6, "capital deployed");
    }

    function test_batchAtExactCapExecutes() public {
        vm.prank(alice);
        vault.deposit(2_000e6, alice);

        // Boundary: netOutflow == cap must pass (comparison is strict >).
        vm.prank(address(governor));
        vault.executeGovernorBatch(_outflowBatch(1_000e6), 1_000e6);
        assertEq(usdc.balanceOf(address(sink)), 1_000e6, "exact-cap deploy executes");
    }

    function test_batchExceedingCapReverts() public {
        vm.prank(alice);
        vault.deposit(2_000e6, alice);

        vm.prank(address(governor));
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, 1_500e6, 1_000e6));
        vault.executeGovernorBatch(_outflowBatch(1_500e6), 1_000e6);
    }

    function test_inflowBatchPassesTrivially() public {
        // Fund the sink directly — the batch returns funds to the vault, so
        // netOutflow floors at 0 (no underflow) and even a zero cap passes.
        usdc.mint(address(sink), 500e6);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(sink), data: abi.encodeCall(sink.pushBack, (500e6)), value: 0});

        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, 0);
        assertEq(usdc.balanceOf(address(vault)), 500e6, "funds returned");
    }
}
