// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockUniswapV2Pair
/// @notice The accumulator half of `UniswapV2Pair`, reproduced exactly.
///
/// @dev    `_update` IS COPIED VERBATIM, and that is the point of this mock
///         rather than a stub returning a canned TWAP. `WoodTwapOracle`'s
///         correctness is entirely a claim about this arithmetic — UQ112x112
///         encoding, accumulation at the OLD reserves for the elapsed span,
///         wrapping `uint32` timestamps, unchecked `uint256` accumulators — so a
///         mock that shortcut any of it would test nothing. The live pair was
///         proven byte-identical to canonical `UniswapV2Pair` by CREATE2
///         derivation, which is what makes copying it here the faithful thing to
///         do.
contract MockUniswapV2Pair {
    address public token0;
    address public token1;

    uint112 private _reserve0;
    uint112 private _reserve1;
    uint32 private _blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address token0_, address token1_, uint112 reserve0_, uint112 reserve1_) {
        token0 = token0_;
        token1 = token1_;
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
        _blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, _blockTimestampLast);
    }

    /// @dev `UniswapV2Pair._update`. Accumulates the price that was standing for
    ///      the elapsed span BEFORE writing the new reserves, which is why a
    ///      swap in the same block as a read cannot move the accumulator.
    function sync(uint112 reserve0_, uint112 reserve1_) public {
        uint32 nowTs = uint32(block.timestamp);
        uint32 elapsed;
        unchecked {
            elapsed = nowTs - _blockTimestampLast;
        }
        if (elapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            unchecked {
                price0CumulativeLast += ((uint256(_reserve1) << 112) / _reserve0) * elapsed;
                price1CumulativeLast += ((uint256(_reserve0) << 112) / _reserve1) * elapsed;
            }
        }
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
        _blockTimestampLast = nowTs;
    }

    /// @dev A no-op interaction — what any swap, mint or burn does to the
    ///      accumulator when the reserves happen not to change.
    function touch() external {
        sync(_reserve0, _reserve1);
    }

    /// @dev Re-point the tokens WITHOUT touching reserves, so a test can prove
    ///      `validatePair()` catches a pair that stopped being the pair it was
    ///      wired as.
    function setTokens(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }
}
