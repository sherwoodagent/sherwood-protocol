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

        lib.executeBatch(calls, address(token), new uint256[](0));

        assertEq(target.value(), 3, "last call wins; all calls executed in order");
        assertEq(target.callCount(), 3, "every call executed once");
    }

    function test_executeBatch_emptyBatchSucceeds() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](0);
        lib.executeBatch(calls, address(token), new uint256[](0));
        assertEq(target.callCount(), 0);
    }

    function test_executeBatch_revertsOnFirstFailure_andBubblesError() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.boom, ()), value: 0});

        vm.expectRevert(bytes("boom"));
        lib.executeBatch(calls, address(token), new uint256[](0));

        // Atomicity: revert undoes the first call's state change too.
        assertEq(target.value(), 0, "first call's state rolled back on revert");
    }

    function test_executeBatch_bubblesCustomErrorSelector() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.boomCustom, ()), value: 0});

        vm.expectRevert(Target.CustomError.selector);
        lib.executeBatch(calls, address(token), new uint256[](0));
    }

    function test_executeBatch_forwardsValue() public {
        vm.deal(address(lib), 5 ether);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.deposit, ()), value: 1 ether});
        calls[1] =
            BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.deposit, ()), value: 2 ether});

        lib.executeBatch(calls, address(token), new uint256[](0));

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

        lib.executeBatch(calls, address(token), new uint256[](0));
        assertEq(target.value(), 7);
    }

    function test_executeBatch_mixOfTargets() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(token), data: abi.encodeCall(token.mint, (address(0xBEEF), 100e18)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (42)), value: 0});

        lib.executeBatch(calls, address(token), new uint256[](0));

        assertEq(token.balanceOf(address(0xBEEF)), 100e18);
        assertEq(target.value(), 42);
    }

    // ──────────────────────── simulateBatch ────────────────────────

    function test_simulateBatch_returnsSuccessResults() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.echo, (5)), value: 0});

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls, address(token), new uint256[](0));
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

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls, address(token), new uint256[](0));
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

        BatchExecutorLib.CallResult[] memory results = lib.simulateBatch(calls, address(token), new uint256[](0));
        assertTrue(results[0].success);
        assertTrue(results[1].success);
        assertEq(abi.decode(results[1].returnData, (uint256)), 123, "second call read first's state");
    }

    // ──────────────────── per-call metering (issue #43) ────────────────────

    function _sink() internal pure returns (address) {
        return address(0xC0FFEE);
    }

    /// @notice Issue #43, obligation (b): a call exceeding its OWN declared
    ///         cap reverts `CallCapExceeded`, even though the batch's overall
    ///         outflow would be far under a hypothetical `maxCapital` — the
    ///         per-call meter is strictly tighter than any batch-level check.
    function test_executeBatch_callExceedingOwnCapReverts() public {
        token.mint(address(lib), 1_000e18);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 50e18)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 100e18)), value: 0
        });
        uint256[] memory caps = new uint256[](2);
        caps[0] = 50e18; // exactly covers call 0
        caps[1] = 60e18; // call 1 moves 100e18 > 60e18 cap

        vm.expectRevert(abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 1, 100e18, 60e18));
        lib.executeBatch(calls, address(token), caps);

        // Atomicity: the whole batch rolled back, including call 0's transfer.
        assertEq(token.balanceOf(_sink()), 0, "call 0's effect rolled back too");
        assertEq(token.balanceOf(address(lib)), 1_000e18, "lib's balance untouched");
    }

    /// @notice Issue #43, obligation (c): GROSS metering — an inflow in a
    ///         LATER call must not refill an EARLIER call's budget. Caps
    ///         `[100, 0]`: call 0 sends 100 out (exactly its cap), call 1
    ///         receives 150 back (its own cap of 0 is satisfied since it is a
    ///         pure inflow, outflow floored at 0).
    function test_executeBatch_grossRule_laterInflowDoesNotRefillEarlierBudget() public {
        token.mint(address(lib), 1_000e18);
        TokenMover mover = new TokenMover(token);
        token.mint(address(mover), 150e18);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 100e18)), value: 0});
        calls[1] =
            BatchExecutorLib.Call({target: address(mover), data: abi.encodeCall(TokenMover.refund, (150e18)), value: 0});
        uint256[] memory caps = new uint256[](2);
        caps[0] = 100e18;
        caps[1] = 0;

        lib.executeBatch(calls, address(token), caps);

        assertEq(token.balanceOf(_sink()), 100e18, "call 0 sent exactly its cap");
        // Net: -100 (call 0) + 150 (call 1) = +50 vs the starting 1_000e18.
        assertEq(token.balanceOf(address(lib)), 1_050e18, "net inflow across the batch");
    }

    /// @notice The other ordering of the same rule: an EARLIER inflow does
    ///         not let a LATER outflow overspend past its own cap either —
    ///         reordering the calls changes nothing about each call's own
    ///         gross measurement.
    function test_executeBatch_grossRule_earlierInflowDoesNotLicenseLaterOverspend() public {
        token.mint(address(lib), 1_000e18);
        TokenMover mover = new TokenMover(token);
        token.mint(address(mover), 150e18);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: address(mover), data: abi.encodeCall(TokenMover.refund, (150e18)), value: 0});
        calls[1] =
            BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 100e18)), value: 0});
        uint256[] memory caps = new uint256[](2);
        caps[0] = 0; // pure inflow, cap 0 is satisfied
        caps[1] = 50e18; // call 1's own outflow (100e18) exceeds ITS cap

        vm.expectRevert(abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 1, 100e18, 50e18));
        lib.executeBatch(calls, address(token), caps);
    }

    /// @notice A zero cap is a BINDING declaration, not an unmetered call —
    ///         moving even 1 wei against a zero-cap call reverts.
    function test_executeBatch_zeroCapEnforcesZeroOutflow() public {
        token.mint(address(lib), 1e18);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 1)), value: 0});
        uint256[] memory caps = new uint256[](1);
        caps[0] = 0;

        vm.expectRevert(abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 0, 1, 0));
        lib.executeBatch(calls, address(token), caps);
    }

    /// @notice Empty `caps` skips per-call metering entirely — a batch that
    ///         would breach any individual cap succeeds unmetered.
    function test_executeBatch_emptyCaps_skipsPerCallMetering() public {
        token.mint(address(lib), 1_000e18);

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](1);
        calls[0] =
            BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 1_000e18)), value: 0});

        lib.executeBatch(calls, address(token), new uint256[](0));
        assertEq(token.balanceOf(_sink()), 1_000e18);
    }

    /// @notice A non-empty `caps` array whose length differs from `calls`
    ///         reverts `CapsLengthMismatch` before any call executes.
    function test_executeBatch_capsLengthMismatch_revertsBeforeAnyCall() public {
        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](3);
        calls[0] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (1)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (2)), value: 0});
        calls[2] = BatchExecutorLib.Call({target: address(target), data: abi.encodeCall(Target.set, (3)), value: 0});
        uint256[] memory caps = new uint256[](2);

        vm.expectRevert(BatchExecutorLib.CapsLengthMismatch.selector);
        lib.executeBatch(calls, address(token), caps);
        assertEq(target.callCount(), 0, "no call ran before the length check fired");
    }

    /// @notice Issue #43, obligation (e)/design.md D3: `simulateBatch` reports
    ///         the SAME per-call outflow that `executeBatch` would enforce on
    ///         an identical batch — proposers size caps from the dry-run.
    ///         Simulated and executed against INDEPENDENT lib/mover instances
    ///         (both actually mutate state, being plain calls rather than
    ///         eth_call) so the simulate phase cannot spend down the balances
    ///         the execute phase needs.
    function test_simulateBatch_reportsOutflowMatchingExecute() public {
        BatchExecutorLib simLib = new BatchExecutorLib();
        token.mint(address(simLib), 1_000e18);
        TokenMover simMover = new TokenMover(token);
        token.mint(address(simMover), 30e18);

        BatchExecutorLib.Call[] memory simCalls = new BatchExecutorLib.Call[](2);
        simCalls[0] =
            BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 70e18)), value: 0});
        simCalls[1] = BatchExecutorLib.Call({
            target: address(simMover), data: abi.encodeCall(TokenMover.refund, (30e18)), value: 0
        });

        BatchExecutorLib.CallResult[] memory results = simLib.simulateBatch(simCalls, address(token), new uint256[](0));
        assertEq(results[0].outflow, 70e18, "call 0's measured outflow");
        assertEq(results[1].outflow, 0, "call 1 is a pure inflow, floored at 0");

        // Same shape, caps sized from the simulation, on a FRESH lib/mover —
        // succeeds identically, proving the two entrypoints measure the same way.
        token.mint(address(lib), 1_000e18);
        TokenMover execMover = new TokenMover(token);
        token.mint(address(execMover), 30e18);
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] =
            BatchExecutorLib.Call({target: address(token), data: abi.encodeCall(token.transfer, (_sink(), 70e18)), value: 0});
        execCalls[1] = BatchExecutorLib.Call({
            target: address(execMover), data: abi.encodeCall(TokenMover.refund, (30e18)), value: 0
        });
        uint256[] memory caps = new uint256[](2);
        caps[0] = results[0].outflow;
        caps[1] = results[1].outflow;
        uint256 sinkBefore = token.balanceOf(_sink());
        lib.executeBatch(execCalls, address(token), caps);
        assertEq(token.balanceOf(_sink()) - sinkBefore, 70e18, "the second batch moved exactly 70e18 more");
    }
}

/// @dev Refunds `amount` of `token` to whoever calls it — a stand-in for a
///      DeFi position returning capital (e.g. a redeem/repay), used to test
///      the GROSS metering rule (an inflow never refills another call's
///      budget).
contract TokenMover {
    ERC20Mock public immutable token;

    constructor(ERC20Mock token_) {
        token = token_;
    }

    function refund(uint256 amount) external {
        token.transfer(msg.sender, amount);
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
