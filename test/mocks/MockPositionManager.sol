// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManager} from "../../src/vendor/uniswap/INonfungiblePositionManager.sol";

/// @notice Uniswap V3 `NonfungiblePositionManager` stand-in with real custody
///         and real principal/fee accounting.
/// @dev    Deliberately NOT an ERC-721: the strategy never transfers a position,
///         it only mints, decreases, collects and burns its own. Adding token
///         plumbing would be surface with no caller.
///
///         Liquidity here is the GEOMETRIC MEAN of the two consumed amounts,
///         `sqrt(amount0 * amount1)`. Not Uniswap's real formula, and not trying
///         to be — but deliberately not the arithmetic sum either, because the
///         two sides carry different decimals (a 6-decimal stable against an
///         18-decimal equity leg) and adding them produces a number dominated
///         entirely by whichever token has more decimals. That is not a scaling
///         nuisance, it is dimensional nonsense: it would make the pool-share
///         cap fire or not fire based on the token's decimals rather than the
///         position's size. The geometric mean is scale-correct in both, which
///         is the property the cap assertions actually depend on. The FORK test
///         is what pins the real curve.
contract MockPositionManager {
    using SafeERC20 for IERC20;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint128 owed0;
        uint128 owed1;
        bool burned;
    }

    mapping(uint256 => Position) internal _positions;
    uint256 public nextTokenId = 1;

    address public factory;
    string public symbol = "UNI-V3-POS";
    string public name = "Uniswap V3 Positions NFT-V1";

    /// @notice Fraction of `amount1Desired` the mint actually consumes, in bps.
    /// @dev    Models a range that is not centred on spot: a real mint takes the
    ///         two sides in whatever ratio the range implies, not everything
    ///         offered. Lowering this is how a test drives the mint below its
    ///         `amount1Min` floor.
    uint256 public consume1Bps = 10_000;
    uint256 public consume0Bps = 10_000;

    error PriceSlippageCheck();
    error NotCleared();

    constructor(address factory_) {
        factory = factory_;
    }

    function setConsumption(uint256 c0Bps, uint256 c1Bps) external {
        consume0Bps = c0Bps;
        consume1Bps = c1Bps;
    }

    /// @notice Credit a position with fees owed, in both tokens.
    /// @dev    The mock must be pre-funded with the fee tokens.
    function accrueFees(uint256 tokenId, uint128 fee0, uint128 fee1) external {
        _positions[tokenId].owed0 += fee0;
        _positions[tokenId].owed1 += fee1;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        amount0 = (p.amount0Desired * consume0Bps) / 10_000;
        amount1 = (p.amount1Desired * consume1Bps) / 10_000;
        if (amount0 < p.amount0Min || amount1 < p.amount1Min) revert PriceSlippageCheck();

        if (amount0 != 0) IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);

        liquidity = uint128(_sqrt(amount0 * amount1));
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({
            token0: p.token0,
            token1: p.token1,
            fee: p.fee,
            tickLower: p.tickLower,
            tickUpper: p.tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1,
            owed0: 0,
            owed1: 0,
            burned: false
        });
    }

    /// @dev Moves principal into the OWED balances rather than paying out —
    ///      upstream's actual behaviour, and the reason settlement has to call
    ///      `collect` afterwards. A stand-in that paid out here would let a
    ///      wrong settlement order pass.
    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[p.tokenId];
        require(pos.liquidity >= p.liquidity, "insufficient liquidity");

        amount0 = (pos.amount0 * p.liquidity) / pos.liquidity;
        amount1 = (pos.amount1 * p.liquidity) / pos.liquidity;

        pos.amount0 -= amount0;
        pos.amount1 -= amount1;
        pos.liquidity -= p.liquidity;
        pos.owed0 += uint128(amount0);
        pos.owed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[p.tokenId];
        amount0 = pos.owed0 < p.amount0Max ? pos.owed0 : p.amount0Max;
        amount1 = pos.owed1 < p.amount1Max ? pos.owed1 : p.amount1Max;
        pos.owed0 -= uint128(amount0);
        pos.owed1 -= uint128(amount1);

        if (amount0 != 0) IERC20(pos.token0).safeTransfer(p.recipient, amount0);
        if (amount1 != 0) IERC20(pos.token1).safeTransfer(p.recipient, amount1);
    }

    /// @dev Upstream requires liquidity and both owed balances to be zero, so a
    ///      burn that reverts means the unwind was incomplete. Mirrored, because
    ///      "at most one position at a time" is only meaningful if a stale one
    ///      cannot be silently abandoned.
    function burn(uint256 tokenId) external {
        Position storage pos = _positions[tokenId];
        if (pos.liquidity != 0 || pos.owed0 != 0 || pos.owed1 != 0) revert NotCleared();
        pos.burned = true;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128)
    {
        Position storage p = _positions[tokenId];
        return (0, address(0), p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    function isBurned(uint256 tokenId) external view returns (bool) {
        return _positions[tokenId].burned;
    }

    /// @dev Babylonian method. Local rather than imported so this mock stays
    ///      dependency-free.
    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
