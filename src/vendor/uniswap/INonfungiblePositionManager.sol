// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title  Vendored Uniswap V3 NonfungiblePositionManager interface
/// @notice Provenance: Uniswap/v3-periphery
///         `contracts/interfaces/INonfungiblePositionManager.sol`
///         (GPL-2.0-or-later), reduced to the surface Sherwood consumes:
///         mint / decreaseLiquidity / collect / burn for the position
///         lifecycle, `positions` to read a position back, and the two
///         identity views the deploy guard asserts on.
///
///         Upstream declares these under `pragma solidity >=0.7.5` with
///         `abicoder v2`; this file is pinned to 0.8.28 to match the rest of
///         `src/` (0.8.x has ABI coder v2 always on, so the directive is
///         dropped, not lost). Interfaces carry no code, so the pragma change
///         cannot alter behaviour — the signatures, and therefore the
///         selectors, are byte-identical to the live deployment on Robinhood
///         Chain 4663 at `0x73991a25c818bf1f1128deaab1492d45638de0d3`
///         (`name() == "Uniswap V3 Positions NFT-V1"`, verified in
///         `ConcentratedLiquidityStrategyFork.t.sol`).
///
/// @dev    IDENTITY, NOT CODE PRESENCE. On chain 4663 the canonical mainnet
///         addresses `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` (position
///         manager) and `0x1F98431c8aD98523631AE4a59f267346ea31F984` (factory)
///         each hold ~2110 bytes of an unrelated contract that answers none of
///         these selectors. A `code.length != 0` assertion PASSES on both.
///         Any guard that wires one of these addresses must therefore assert
///         identity — `symbol()` and `factory()` — and not merely that
///         something is deployed there. See `addresses/4663.json`.
interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Creates a new position wrapped in an NFT.
    /// @dev    `amount0Min`/`amount1Min` are the slippage floor: upstream
    ///         reverts `Price slippage check` when the minted amounts fall
    ///         short. This is the only protection the mint itself carries, so
    ///         the strategy must pass real floors rather than zeros.
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Decreases the amount of liquidity in a position.
    /// @dev    Moves the freed principal into the position's *owed* balances —
    ///         it does NOT transfer tokens. `collect` is what actually pays
    ///         out, which is why settlement must call both, in that order.
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Collects up to a maximum amount of fees owed to a position.
    /// @dev    Pass `type(uint128).max` for both maxima to sweep principal and
    ///         fees together; upstream clamps to what is actually owed.
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a token ID, which deletes it from the NFT contract.
    /// @dev    Upstream requires liquidity, tokensOwed0 and tokensOwed1 all be
    ///         zero — so burn is only reachable after decreaseLiquidity AND
    ///         collect. A burn that reverts therefore means the unwind was
    ///         incomplete, not that the burn itself failed.
    function burn(uint256 tokenId) external payable;

    /// @notice Returns the position information associated with a token ID.
    /// @dev    Field order and widths are load-bearing: this tuple is decoded
    ///         positionally. `liquidity` at index 7 is what settlement passes
    ///         to `decreaseLiquidity`; `tickLower`/`tickUpper` at 5/6 are what
    ///         the rerange path compares against the derived range.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice The Uniswap V3 factory this position manager was deployed
    ///         against. Asserted at deploy time to prove identity.
    function factory() external view returns (address);

    /// @notice ERC-721 symbol; `"UNI-V3-POS"` for a genuine deployment.
    ///         Asserted at deploy time to prove identity.
    function symbol() external view returns (string memory);
}
