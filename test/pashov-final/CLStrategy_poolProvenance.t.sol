// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";

/// @notice A contract that answers every `IUniswapV3Pool` selector with values
///         its deployer picked, including `factory()`.
/// @dev    Every field is chosen to make a downstream guard evaluate to nothing,
///         which is the point: the provenance check is the only thing standing
///         between a proposer and a position whose entire risk surface it
///         authored.
///
///         - `sqrtPriceX96 == 1` drives `_poolAnchoredMinOut` to
///           `mulDiv(amountIn, 1, 2**96) == 0`, so the venue-independent swap
///           floor — added specifically so the floor does not come from the
///           traded venue — bounds nothing.
///         - `observe` synthesises a cumulative pair from `spotTick`, so the
///           TWAP the strategy derives always equals the spot it is compared
///           against and `_requireSpotNearTwap` measures a deviation of zero.
///         - `liquidity() == type(uint128).max` makes any position's share of
///           the pool round to nothing against `_requireWithinPoolShare`.
contract ImpostorPool {
    address public token0;
    address public token1;
    uint24 public fee;
    int24 public tickSpacing;
    /// @notice The lie under test: an impostor names the GENUINE factory.
    address public factory;

    uint128 public liquidity = type(uint128).max;
    uint160 public sqrtPriceX96 = 1;
    int24 public spotTick;

    constructor(address token0_, address token1_, uint24 fee_, int24 tickSpacing_, address factory_) {
        token0 = token0_;
        token1 = token1_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        factory = factory_;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, spotTick, 0, type(uint16).max, 0, 0, true);
    }

    function increaseObservationCardinalityNext(uint16) external {}

    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        tickCumulatives = new int56[](2);
        secondsPerLiquidityCumulativeX128s = new uint160[](2);
        tickCumulatives[1] = int56(spotTick) * int56(uint56(secondsAgos[0]));
    }
}

/// @title ConcentratedLiquidityStrategy — pool provenance (2026-08 audit, finding #4)
/// @notice The check that was supposed to establish a pool is a real Uniswap
///         pool asked the pool itself:
///
///             if (pool_.factory() != p.uniswapFactory) revert PoolNotFromFactory();
///
///         Both operands came from the same proposer, and `p.uniswapFactory`
///         appeared nowhere else — neither operand was bound to anything the
///         protocol had vouched for. A proposer supplied a contract answering
///         the whole `IUniswapV3Pool` surface with chosen values and a matching
///         `uniswapFactory`, and the two agreed by construction.
///
///         Binding `p.uniswapFactory` to the registry does not close it on its
///         own, which is why the direction had to change rather than just the
///         inputs: an impostor is free to name the real factory in its own
///         `factory()` answer. Only the factory can say which pool is canonical
///         for a key, so the factory is now the one asked.
contract PashovFinalCLPoolProvenanceTest is CLFixture {
    /// @notice THE FINDING. An impostor that names the genuine, allowlisted
    ///         factory passes a self-attestation check and must not pass a
    ///         factory-attested one.
    /// @dev    Nothing here is denied and nothing is misconfigured: the registry
    ///         is permissive, `p.uniswapFactory` is the same factory every other
    ///         test uses, and the impostor reports the vault asset as `token0`
    ///         so the asset check clears. The only thing separating it from the
    ///         genuine pool is that the factory never created it.
    function test_init_impostorNamingTheGenuineFactoryIsRejected() public {
        ImpostorPool impostor = new ImpostorPool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, factory);
        assertEq(impostor.factory(), factory, "precondition: the impostor self-attests the genuine factory");

        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(impostor);

        _expectInitRevert(ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, p);
    }

    /// @notice The factory is an authority only if the protocol chose it. A
    ///         proposer-authored factory vouching for a proposer-authored pool
    ///         is the same self-attestation one hop out, so `uniswapFactory` is
    ///         bound to the registry like every other counterparty.
    function test_init_proposerSuppliedFactoryIsRefusedByTheRegistry() public {
        MockUniswapV3Factory rogueFactory = new MockUniswapV3Factory();
        ImpostorPool impostor =
            new ImpostorPool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, address(rogueFactory));
        rogueFactory.register(address(usdg), address(nvda), POOL_FEE, address(impostor));
        tierRegistry.setDenied(address(rogueFactory), true);

        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.pool = address(impostor);
        p.uniswapFactory = address(rogueFactory);

        // Not `_expectInitRevert`: this error carries arguments, and a 4-byte
        // `expectRevert` only matches returndata that is exactly the selector.
        // Naming both operands is worth the extra lines here — it pins WHICH
        // address was refused, which is the whole content of the assertion.
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(p);
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector,
                address(rogueFactory),
                address(tierRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }

    /// @notice A codeless `uniswapFactory` vouches for nothing and must fail
    ///         CLOSED with this contract's own error rather than reverting
    ///         undecodably inside a typed call to an address with no code.
    function test_init_codelessFactoryFailsClosedDecodably() public {
        ConcentratedLiquidityStrategy.InitParams memory p = _defaultParams();
        p.uniswapFactory = makeAddr("eoaFactory");

        _expectInitRevert(ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, p);
    }

    /// @notice The genuine configuration still initializes — the guard above
    ///         must not be passing for the trivial reason that it refuses
    ///         everything.
    function test_init_factoryRegisteredPoolStillInitializes() public {
        ConcentratedLiquidityStrategy s = _newStrategy(_defaultParams());
        assertEq(address(s.pool()), address(pool), "the factory-vouched pool binds");
    }
}
