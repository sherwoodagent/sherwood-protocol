// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Regression tests for audit-181 Finding #21: SynthraDirectAdapter.synthraV3SwapCallback
// trusted the pool's self-reported amount0Delta/amount1Delta with no upper bound and no
// sign check, letting a pool (or a rogue token/pool combination resolved from the factory)
// pull an arbitrary amount from whatever balance the adapter happened to hold, and letting
// a non-positive delta wrap into an astronomic uint256 via unchecked cast.
//
// These tests reproduce both defects against a hostile pool mock, plus the unspent-tokenIn
// refund the same fix adds. Each test is written to FAIL against the pre-fix adapter and
// PASS against the fix in src/adapters/SynthraDirectAdapter.sol:
//   - test_callback_revertsWhenAmountOwedExceedsStagedAmount: pre-fix, the adapter happily
//     transfers the inflated amount (silently draining any stranded balance it holds);
//     post-fix it reverts with CallbackAmountExceeded before any transfer occurs.
//   - test_callback_revertsOnNonPositiveDelta: pre-fix, uint256(-1) wraps to
//     type(uint256).max and the transfer reverts on the ERC20's own insufficient-balance
//     check (an uncontrolled revert reason); post-fix it reverts with the named SwapFailed
//     error before the cast even happens.
//   - test_swap_refundsUnspentTokenIn: pre-fix, unspent tokenIn is stranded permanently in
//     the stateless, permissionless adapter; post-fix it is swept back to the caller.

import {Test} from "forge-std/Test.sol";
import {SynthraDirectAdapter, ISynthraFactory, ISynthraPool} from "../../src/adapters/SynthraDirectAdapter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @notice Hostile pool that reports arbitrary, caller-controlled deltas in its callback,
///         ignoring amountSpecified entirely -- models a pool self-reporting more than the
///         adapter staged, or a non-positive delta on both legs.
contract MaliciousDeltaSynthraPool {
    address public token0;
    address public token1;
    int256 public reportedAmount0;
    int256 public reportedAmount1;

    constructor(address _token0, address _token1) {
        token0 = _token0;
        token1 = _token1;
    }

    function setReportedDeltas(int256 amount0Delta, int256 amount1Delta) external {
        reportedAmount0 = amount0Delta;
        reportedAmount1 = amount1Delta;
    }

    function swap(address, bool, int256, uint160, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        amount0 = reportedAmount0;
        amount1 = reportedAmount1;
        SynthraDirectAdapter(msg.sender).synthraV3SwapCallback(amount0, amount1, "");
    }
}

/// @notice Pool that only pulls part of the specified input -- models a real V3 pool that
///         hits its sqrtPriceLimitX96 bound before consuming the full amountSpecified.
contract PartialFillSynthraPool {
    address public token0;
    address public token1;
    uint256 public requestAmount;
    uint256 public payOutAmount;

    constructor(address _token0, address _token1, uint256 _requestAmount, uint256 _payOutAmount) {
        token0 = _token0;
        token1 = _token1;
        requestAmount = _requestAmount;
        payOutAmount = _payOutAmount;
    }

    function swap(address recipient, bool zeroForOne, int256, uint160, bytes calldata)
        external
        returns (int256 amount0, int256 amount1)
    {
        if (zeroForOne) {
            amount0 = int256(requestAmount);
            amount1 = -int256(payOutAmount);
            ERC20Mock(token1).mint(recipient, payOutAmount);
        } else {
            amount0 = -int256(payOutAmount);
            amount1 = int256(requestAmount);
            ERC20Mock(token0).mint(recipient, payOutAmount);
        }
        SynthraDirectAdapter(msg.sender).synthraV3SwapCallback(amount0, amount1, "");
    }
}

contract MockSynthraFactory is ISynthraFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, uint24 fee, address pool) external {
        pools[_key(tokenA, tokenB, fee)] = pool;
        pools[_key(tokenB, tokenA, fee)] = pool;
    }

    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address) {
        return pools[_key(tokenA, tokenB, fee)];
    }

    function _key(address tokenA, address tokenB, uint24 fee) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, fee));
    }
}

contract SynthraDirectAdapter_callbackBoundTest is Test {
    SynthraDirectAdapter adapter;
    MockSynthraFactory factory;
    ERC20Mock tokenA;
    ERC20Mock tokenB;
    address token0;
    address token1;
    address user = makeAddr("user");

    uint24 constant FEE = 3000;

    function setUp() public {
        tokenA = new ERC20Mock("A", "A", 18);
        tokenB = new ERC20Mock("B", "B", 18);
        (token0, token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));

        factory = new MockSynthraFactory();
        adapter = new SynthraDirectAdapter(address(factory));

        tokenA.mint(user, 1000e18);
        vm.prank(user);
        tokenA.approve(address(adapter), type(uint256).max);
    }

    /// @notice tokenA is the swap input; token0/token1 come from address ordering, so
    ///         zeroForOne (and therefore which reported delta is the "owed" leg) depends on
    ///         whether tokenA sorts first. Compute it once so both malicious-pool tests stay
    ///         correct regardless of the fuzzed mock addresses.
    function _tokenAIsToken0() internal view returns (bool) {
        return address(tokenA) == token0;
    }

    /// @dev Pre-fix: the adapter has no bound on amountOwed, so it happily transfers the
    ///      inflated amount out of whatever balance it holds (here, 100e18 of stranded
    ///      tokenA simulating a prior partial-fill leftover) -- silently draining it. This
    ///      assertion would FAIL pre-fix (no revert occurs; the exploit just succeeds).
    ///      Post-fix: synthraV3SwapCallback reverts with CallbackAmountExceeded before any
    ///      transfer, because the pool-reported delta (100e18) exceeds the amountIn staged
    ///      by swap() (50e18).
    function test_callback_revertsWhenAmountOwedExceedsStagedAmount() public {
        MaliciousDeltaSynthraPool pool = new MaliciousDeltaSynthraPool(token0, token1);
        factory.setPool(address(tokenA), address(tokenB), FEE, address(pool));

        // Simulate stranded tokenA balance in the adapter (e.g. from a prior partial fill)
        // so an unbounded callback has something extra to steal.
        tokenA.mint(address(adapter), 100e18);

        bool zeroForOne = _tokenAIsToken0();
        int256 inflatedOwed = 100e18; // double the staged 50e18 amountIn
        if (zeroForOne) {
            pool.setReportedDeltas(inflatedOwed, -1e18);
        } else {
            pool.setReportedDeltas(-1e18, inflatedOwed);
        }

        uint256 adapterBalanceBefore = tokenA.balanceOf(address(adapter));

        vm.prank(user);
        vm.expectRevert(SynthraDirectAdapter.CallbackAmountExceeded.selector);
        adapter.swap(address(tokenA), address(tokenB), 50e18, 0, abi.encode(FEE));

        // Nothing should have moved: a revert anywhere inside adapter.swap()
        // (the callback fires synchronously from within pool.swap(), itself
        // called from swap()) unwinds the ENTIRE external call, including the
        // safeTransferFrom that pulled 50e18 from `user` into the adapter
        // earlier in the same call. So the adapter's balance must be back to
        // exactly what it was before adapter.swap() was ever invoked -- the
        // 100e18 stranded balance minted above -- not that plus the reverted
        // 50e18 pull.
        assertEq(
            tokenA.balanceOf(address(adapter)),
            adapterBalanceBefore,
            "adapter balance must be untouched by the rejected callback"
        );
    }

    /// @dev Pre-fix: neither delta is positive, so the else branch casts a negative
    ///      int256 to uint256, wrapping to an astronomic value; the resulting safeTransfer
    ///      reverts, but on the ERC20's own insufficient-balance check rather than a named
    ///      adapter error -- this assertion (expecting SwapFailed specifically) would FAIL
    ///      pre-fix because the revert reason does not match.
    ///      Post-fix: the sign is checked before any cast, and it reverts with SwapFailed.
    function test_callback_revertsOnNonPositiveDelta() public {
        MaliciousDeltaSynthraPool pool = new MaliciousDeltaSynthraPool(token0, token1);
        factory.setPool(address(tokenA), address(tokenB), FEE, address(pool));

        pool.setReportedDeltas(-1, -1);

        vm.prank(user);
        vm.expectRevert(SynthraDirectAdapter.SwapFailed.selector);
        adapter.swap(address(tokenA), address(tokenB), 50e18, 0, abi.encode(FEE));
    }

    /// @dev A pool that only pulls part of the specified input (e.g. it hit its
    ///      sqrtPriceLimitX96 bound early) leaves the remainder sitting in the adapter.
    ///      Pre-fix there is no sweep, so it is stranded forever in this stateless,
    ///      ownerless contract -- this assertion would FAIL pre-fix (leftover balance stays
    ///      in the adapter and the user is never made whole for it).
    ///      Post-fix: swap() refunds the unspent tokenIn to the caller before returning.
    function test_swap_refundsUnspentTokenIn() public {
        bool zeroForOne = _tokenAIsToken0();
        uint256 requestAmount = 30e18; // pool only pulls 30e18 of the 50e18 offered
        uint256 payOutAmount = 100e18;

        PartialFillSynthraPool pool = new PartialFillSynthraPool(token0, token1, requestAmount, payOutAmount);
        factory.setPool(address(tokenA), address(tokenB), FEE, address(pool));

        uint256 userTokenABefore = tokenA.balanceOf(user);

        vm.prank(user);
        uint256 out = adapter.swap(address(tokenA), address(tokenB), 50e18, 0, abi.encode(FEE));

        assertEq(out, payOutAmount, "output amount");
        // User paid only what the pool actually took (30e18), not the full 50e18 offered.
        assertEq(userTokenABefore - tokenA.balanceOf(user), requestAmount, "user should be refunded the unspent 20e18");
        assertEq(tokenA.balanceOf(address(adapter)), 0, "adapter must not strand unspent tokenIn");
    }
}
