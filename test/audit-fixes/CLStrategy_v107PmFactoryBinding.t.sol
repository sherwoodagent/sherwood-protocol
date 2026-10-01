// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CLFixture} from "../strategies/ConcentratedLiquidityStrategy.t.sol";
import {MockUniswapV3Factory} from "../mocks/MockUniswapV3Factory.sol";
import {MockUniswapV3Pool} from "../mocks/MockUniswapV3Pool.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {INonfungiblePositionManager} from "../../src/vendor/uniswap/INonfungiblePositionManager.sol";

interface IGetPool {
    function getPool(address, address, uint24) external view returns (address);
}

/// @notice Position manager that, like the real one, mints into the pool its OWN factory names.
contract FactoryBoundPositionManager {
    using SafeERC20 for IERC20;

    address public immutable factory;
    string public constant symbol = "UNI-V3-POS";
    uint256 public nextTokenId = 1;
    address public lastMintPool;

    error PoolDoesNotExist();

    constructor(address factory_) {
        factory = factory_;
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address dest = IGetPool(factory).getPool(p.token0, p.token1, p.fee);
        if (dest == address(0) || dest.code.length == 0) revert PoolDoesNotExist();
        amount0 = p.amount0Desired;
        amount1 = p.amount1Desired;
        if (amount0 != 0) IERC20(p.token0).safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 != 0) IERC20(p.token1).safeTransferFrom(msg.sender, address(this), amount1);
        liquidity = uint128(_sqrt(amount0 * amount1));
        tokenId = nextTokenId++;
        MockUniswapV3Pool(dest).setLiquidity(MockUniswapV3Pool(dest).liquidity() + liquidity);
        lastMintPool = dest;
    }

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

/// @notice A position manager with code and no `factory()` getter.
contract FactorylessPositionManager {}

/// @notice Audit 2026-10-01 V1-07: the CL pool's provenance factory must be the position
///         manager's own factory, so the venue measured is the venue minted into.
contract CLStrategy_v107PmFactoryBindingTest is CLFixture {
    TierRegistry realRegistry;

    MockUniswapV3Factory factoryA;
    MockUniswapV3Pool poolA;
    FactoryBoundPositionManager pmA;

    address factoryB;
    MockUniswapV3Pool poolB;
    FactoryBoundPositionManager pmB;

    function setUp() public override {
        super.setUp();

        // Venue B: the fixture's deep, calm pool and its factory.
        factoryB = factory;
        poolB = pool;
        pmB = new FactoryBoundPositionManager(factoryB);

        // Venue A: a second deployment for the same key, thin and 900 ticks off its TWAP.
        factoryA = new MockUniswapV3Factory();
        poolA = new MockUniswapV3Pool(address(usdg), address(nvda), POOL_FEE, TICK_SPACING, address(factoryA));
        poolA.setLiquidity(1e16);
        poolA.setSqrtPriceX96(FAIR_SQRT_PRICE_X96);
        poolA.setTicks(900, 0);
        factoryA.register(address(usdg), address(nvda), POOL_FEE, address(poolA));
        pmA = new FactoryBoundPositionManager(address(factoryA));

        realRegistry = new TierRegistry(address(this));
        realRegistry.setCounterpartyAllowed(address(pmA), true);
        realRegistry.setCounterpartyAllowed(address(factoryA), true);
        realRegistry.setCounterpartyAllowed(address(pmB), true);
        realRegistry.setCounterpartyAllowed(factoryB, true);
        realRegistry.setCounterpartyAllowed(address(morpho), true);
        realRegistry.setCounterpartyAllowed(address(oracle), true);
        realRegistry.setCounterpartyAllowed(address(adapter), true);
        realRegistry.setCounterpartyAllowed(address(nvda), true);
        realRegistry.setCounterpartyAllowed(address(spUsdg), true);
        status.setTierRegistry(address(realRegistry));
    }

    function _params(address pm, address uniFactory, address pool_)
        internal
        view
        returns (ConcentratedLiquidityStrategy.InitParams memory p)
    {
        p = _defaultParams();
        p.positionManager = pm;
        p.uniswapFactory = uniFactory;
        p.pool = pool_;
    }

    /// @notice PM_A with factoryB and poolB is refused at init: readings and mint would split venues.
    function test_init_pmFromAnotherFactoryReverts() public {
        _expectInitRevert(
            ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, _params(address(pmA), factoryB, address(poolB))
        );
    }

    /// @notice Refused even when only the second factory is allowlisted and its own PM is not.
    function test_init_secondFactoryAloneDoesNotArmIt() public {
        realRegistry.setCounterpartyAllowed(address(pmB), false);
        _expectInitRevert(
            ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, _params(address(pmA), factoryB, address(poolB))
        );
    }

    /// @notice A position manager that cannot name its factory vouches for nothing.
    function test_init_pmWithoutFactoryGetterReverts() public {
        FactorylessPositionManager blind = new FactorylessPositionManager();
        realRegistry.setCounterpartyAllowed(address(blind), true);
        _expectInitRevert(
            ConcentratedLiquidityStrategy.PoolNotFromFactory.selector, _params(address(blind), factoryB, address(poolB))
        );
    }

    /// @notice Control: matched venue B executes and the mint lands in the measured pool.
    function test_control_matchedVenueB_mintLandsInMeasuredPool() public {
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        s.initialize(address(vaultStub), proposer, abi.encode(_params(address(pmB), factoryB, address(poolB))));
        status.set(1, 1, address(s));
        vm.prank(address(vaultStub));
        usdg.approve(address(s), type(uint256).max);
        vm.prank(address(vaultStub));
        s.execute();
        assertEq(pmB.lastMintPool(), address(poolB), "honest config: mint == measured pool");
    }

    /// @notice Control: matched venue A is judged on its own pool, whose cap refuses the claim.
    function test_control_matchedVenueA_initCapRefusesClaim() public {
        _expectInitRevert(
            ConcentratedLiquidityStrategy.PositionExceedsPoolShareCap.selector,
            _params(address(pmA), address(factoryA), address(poolA))
        );
    }

    /// @notice Control: with factoryB not allowlisted the mismatched config is refused on the allowlist.
    function test_control_launchSeedOnly_secondFactoryRefused() public {
        realRegistry.setCounterpartyAllowed(factoryB, false);
        realRegistry.setCounterpartyAllowed(address(pmB), false);
        ConcentratedLiquidityStrategy s = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        bytes memory data = abi.encode(_params(address(pmA), factoryB, address(poolB)));
        address v = address(vaultStub);
        vm.expectRevert(
            abi.encodeWithSelector(
                ConcentratedLiquidityStrategy.CounterpartyNotAllowed.selector, factoryB, address(realRegistry)
            )
        );
        s.initialize(v, proposer, data);
    }
}
