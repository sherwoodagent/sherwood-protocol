// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @title BatchExecutorLib unit tests
/// @notice The library is delegatecall-only in production. This suite exercises
///         it directly (without delegatecall) to verify call construction, error
///         bubbling, value forwarding, and simulate-vs-execute semantics. The
///         delegatecall surface is tested indirectly through every governor
///         lifecycle test that drives `executeGovernorBatch`.
contract BatchExecutorLibTest is Test {
    BatchExecutorLib lib;
    Target target;
    ERC20Mock token;

    function setUp() public {
        lib = new BatchExecutorLib();
        target = new Target();
        token = new ERC20Mock("Test", "TST", 18);
    }

    // ──────────────────────── executeBatch ────────────────────────

    function test_executeBatch_runsCallsInOrder() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (2)), value: 0});
        calls[2] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (3)), value: 0});

        lib.executeBatch(calls);

        assertEq(target.value(), 3, "last call wins; all calls executed in order");
        assertEq(target.callCount(), 3, "every call executed once");
    }

    function test_executeBatch_emptyBatchSucceeds() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](0);
        lib.executeBatch(calls);
        assertEq(target.callCount(), 0);
    }

    function test_executeBatch_revertsOnFirstFailure_andBubblesError() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.boom, ()), value: 0});

        vm.expectRevert(bytes("boom"));
        lib.executeBatch(calls);

        // Atomicity: revert undoes the first call's state change too.
        assertEq(target.value(), 0, "first call's state rolled back on revert");
    }

    function test_executeBatch_bubblesCustomErrorSelector() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.boomCustom, ()), value: 0});

        vm.expectRevert(Target.CustomError.selector);
        lib.executeBatch(calls);
    }

    function test_executeBatch_forwardsValue() public {
        vm.deal(address(lib), 5 ether);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.deposit, ()), value: 1 ether});
        calls[1] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.deposit, ()), value: 2 ether});

        lib.executeBatch(calls);

        assertEq(address(target).balance, 3 ether, "value forwarded to target");
        assertEq(target.totalReceived(), 3 ether, "target's bookkeeping matches");
    }

    function test_executeBatch_laterCallsSeeEarlierStateChanges() public {
        // First call sets value to 7. Second call asserts value == 7 inside the target.
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (7)), value: 0});
        calls[1] = BatchExecutorLib.Call({
            target: address(target), data: abi.encodeCall(Target.requireValueEquals, (7)), value: 0
        });

        lib.executeBatch(calls);
        assertEq(target.value(), 7);
    }

    function test_executeBatch_mixOfTargets() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(token), data: abi.encodeCall(token.mint, (address(0xBEEF), 100e18)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (42)), value: 0});

        lib.executeBatch(calls);

        assertEq(token.balanceOf(address(0xBEEF)), 100e18);
        assertEq(target.value(), 42);
    }

    // ──────────────────────── simulateBatch ────────────────────────

    function test_simulateBatch_returnsSuccessResults() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.echo, (5)), value: 0});

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls);
        assertEq(results.length, 2);
        assertTrue(results[0].success);
        assertTrue(results[1].success);
        assertEq(abi.decode(results[1].returnData, (uint256)), 5, "echo returned its argument");
    }

    function test_simulateBatch_doesNotRevertOnFailure() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.boom, ()), value: 0});
        calls[2] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (2)), value: 0});

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls);
        assertEq(results.length, 3);
        assertTrue(results[0].success);
        assertFalse(results[1].success, "second call failed");
        assertTrue(results[2].success, "third call still ran despite second's failure");
        // Returndata of the failing call contains the revert string.
        assertGt(results[1].returnData.length, 0, "revert reason captured");
    }

    function test_simulateBatch_laterCallsObserveEarlierEffects() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (123)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.read, ()), value: 0});

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls);
        assertTrue(results[0].success);
        assertTrue(results[1].success);
        assertEq(abi.decode(results[1].returnData, (uint256)), 123, "second call read first's state");
    }
}

/// @dev Helper target with side effects, custom errors, value receiver, and
///      a state-readback function. Single-purpose lookalike of the protocols
///      the vault calls in production.
contract Target {
    error CustomError();

    uint256 public value;
    uint256 public callCount;
    uint256 public totalReceived;

    function set(uint256 v) external {
        value = v;
        callCount++;
    }

    function read() external view returns (uint256) {
        return value;
    }

    function echo(uint256 v) external pure returns (uint256) {
        return v;
    }

    function boom() external pure {
        revert("boom");
    }

    function boomCustom() external pure {
        revert CustomError();
    }

    function deposit() external payable {
        totalReceived += msg.value;
    }

    function requireValueEquals(uint256 expected) external view {
        require(value == expected, "value mismatch");
    }

    receive() external payable {
        totalReceived += msg.value;
    }
}
