// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ConcentratedLiquidityStrategy} from "../../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {UniswapSwapAdapter} from "../../../src/adapters/UniswapSwapAdapter.sol";
import {MockProposalStatus} from "../../mocks/MockProposalStatus.sol";
import {IMorpho, Id, MarketParams, Market} from "../../../src/vendor/morpho/IMorpho.sol";
import {IUniswapV3Pool} from "../../../src/vendor/uniswap/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "../../../src/vendor/uniswap/INonfungiblePositionManager.sol";

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @notice Vault stand-in for the fork lifecycle — see the unit suite's
///         `VaultStub`. Exposes `asset()` and `governor()` and is pranked for
///         lifecycle calls.
contract ForkVaultStub {
    address internal immutable _assetToken;
    address public governor;

    constructor(address assetToken_, address governor_) {
        _assetToken = assetToken_;
        governor = governor_;
    }

    function asset() external view returns (address) {
        return _assetToken;
    }
}

/**
 * @title ConcentratedLiquidityMainnetForkTest
 * @notice Full-lifecycle fork test against the LIVE Uniswap V3 deployment and
 *         Morpho Blue singleton on Robinhood Chain mainnet (4663). This is
 *         where the vendored Uniswap interfaces earn their keep: the real
 *         position manager's `mint`/`decreaseLiquidity`/`collect`/`burn` and
 *         the real pool's `observe` run against this contract's decodes, and
 *         the real liquidity curve replaces the unit suite's linear stand-in.
 *
 *         Addresses were resolved ON-CHAIN, not taken from a vendor address
 *         list — see `addresses/4663.json`. The canonical Uniswap mainnet
 *         addresses are NOT this chain's deployment and hold unrelated code, so
 *         `symbol()`/`factory()` identity is asserted below rather than mere
 *         code presence.
 *
 * @dev Skips when ROBINHOOD_RPC_URL is unset (shared fork-test convention);
 *      excluded from default CI via the `test/integration/**` path filter —
 *      NOT `test/fork/**`, which CI does not exclude.
 *      Run explicitly:
 *        forge test --match-path "test/integration/strategies/ConcentratedLiquidityMainnetFork.t.sol" -vv
 */
contract ConcentratedLiquidityMainnetForkTest is Test {
    // Pinned Robinhood mainnet block. NOTE: the public RPC serves state only for
    // a sliding window of recent blocks — an older pin needs an archive
    // endpoint (the Tenderly fork RPC wired in foundry.toml as `robinhood_fork`).
    uint256 constant FORK_BLOCK = 27_800_000;

    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    /// @dev "NVIDIA • Robinhood Token" — identity asserted on-chain in the
    ///      unlevered test, not assumed from this constant.
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    address constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant POSITION_MANAGER = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address constant UNISWAP_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant UNISWAP_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    /// @dev The deepest USDG loan market on 4663 (`spUSDG` collateral, 91.5%
    ///      LLTV) — the same market `MorphoSupplyMainnetFork` exercises.
    bytes32 constant MARKET_ID = 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114;

    uint24 constant POOL_FEE = 100;
    uint32 constant TWAP_WINDOW = 1800;

    ConcentratedLiquidityStrategy template;
    ConcentratedLiquidityStrategy strategy;
    UniswapSwapAdapter adapter;
    MockProposalStatus status;
    ForkVaultStub vaultStub;

    IUniswapV3Pool pool;
    MarketParams mp;

    address proposer = makeAddr("proposer");
    address keeper = makeAddr("keeper");

    uint256 collateralAmount;
    uint256 borrowAmount;

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        // PIN FROM THE ENVIRONMENT, like RobinhoodMainnetIntegrationTest. The
        // hardcoded pin this replaced is unreachable: the public RPC prunes to
        // a ~5k-block window and returns -32000 for it. 0 = fork at latest.
        uint256 pin = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (pin == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, pin);
        }

        // ── Identity, not code presence ──
        assertEq(
            keccak256(bytes(INonfungiblePositionManager(POSITION_MANAGER).symbol())),
            keccak256(bytes("UNI-V3-POS")),
            "position manager is not a Uniswap V3 NFT manager"
        );
        assertEq(
            INonfungiblePositionManager(POSITION_MANAGER).factory(),
            UNISWAP_V3_FACTORY,
            "position manager points at a different factory"
        );

        address poolAddr = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(USDG, WETH, POOL_FEE);
        if (poolAddr == address(0)) return;
        pool = IUniswapV3Pool(poolAddr);
        assertEq(pool.factory(), UNISWAP_V3_FACTORY, "pool disowns the factory");

        mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
        assertEq(mp.loanToken, USDG, "market does not lend the vault asset");

        adapter = new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER);

        status = new MockProposalStatus();
        vaultStub = new ForkVaultStub(USDG, address(status));

        collateralAmount = 10_000e6;
        borrowAmount = 2_000e6;
        deal(USDG, address(vaultStub), collateralAmount * 2);

        template = new ConcentratedLiquidityStrategy();
    }

    function _skipIfNoFork() internal {
        // `vm.skip` is called from the TEST BODY, never from `setUp` — the
        // setUp form is forge-version-dependent and reports `[FAIL: skipped]`
        // on the version CI runs.
        if (address(pool) == address(0)) vm.skip(true);
    }

    function _initStrategy() internal {
        int24 spacing = pool.tickSpacing();
        (, int24 spot,,,,,) = pool.slot0();

        // A wide band around spot, snapped to spacing — this test is pinning the
        // integration, not a trading thesis.
        int24 lower = ((spot - 5000) / spacing) * spacing;
        int24 upper = ((spot + 5000) / spacing) * spacing;

        ConcentratedLiquidityStrategy.InitParams memory p = ConcentratedLiquidityStrategy.InitParams({
            pool: address(pool),
            positionManager: POSITION_MANAGER,
            uniswapFactory: UNISWAP_V3_FACTORY,
            swapAdapter: address(adapter),
            morpho: MORPHO,
            marketParams: mp,
            collateralAmount: collateralAmount,
            borrowAmount: borrowAmount,
            lpAmount: 0,
            tickLower: lower,
            tickUpper: upper,
            expectedLiquidity: uint128(pool.liquidity() / 100),
            swapFractionBps: 5_000,
            twapWindow: TWAP_WINDOW,
            maxTwapDeviationBps: 1_000,
            mintSlippageBps: 1_000,
            rerange: ConcentratedLiquidityStrategy.RerangePolicy({
                halfWidthTicks: 5000,
                triggerBps: 1,
                minInterval: 0,
                maxReranges: 2,
                slippageBps: 1_000,
                swapFractionBps: 5_000
            }),
            settleSlippageBps: 1_000,
            settleDeadline: 0,
            // Mode 0 = Uniswap v3 single hop, fee tier appended.
            swapExtraData: abi.encodePacked(bytes1(0x00), abi.encode(POOL_FEE))
        });

        strategy = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vaultStub), proposer, abi.encode(p));
        status.set(1, 1, address(strategy));

        vm.prank(address(vaultStub));
        IERC20(USDG).approve(address(strategy), type(uint256).max);
    }

    /// @notice Full cycle: mint → accrue → rerange → settle, against live venues.
    function test_fork_fullLifecycle() public {
        _skipIfNoFork();

        // The pool must be able to serve the TWAP window at all. Raising
        // cardinality is permissionless and is the same remediation an operator
        // would apply, so doing it here is honest rather than a fixture cheat.
        (,,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality < 2) {
            pool.increaseObservationCardinalityNext(4);
            vm.warp(block.timestamp + TWAP_WINDOW + 1);
            vm.roll(block.number + 1);
        }

        _initStrategy();
        _repairNextIdIfForkStateCorrupt();

        vm.prank(address(vaultStub));
        strategy.execute();

        uint256 tokenId = strategy.tokenId();
        assertGt(tokenId, 0, "no position minted");
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        assertGt(liquidity, 0, "position holds no liquidity");
        assertGt(IMorpho(MORPHO).position(Id.wrap(MARKET_ID), address(strategy)).borrowShares, 0, "no debt booked");
        console2.log("minted liquidity", uint256(liquidity));

        // ── Rerange against the live pool ──
        _repairNextIdIfForkStateCorrupt();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        strategy.rerange();

        uint256 newTokenId = strategy.tokenId();
        assertTrue(newTokenId != tokenId, "rerange did not replace the position");
        (,,,,,,, uint128 newLiquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(newTokenId);
        assertGt(newLiquidity, 0, "re-minted position is empty");
        console2.log("re-minted liquidity", uint256(newLiquidity));

        // The borrow is untouched by a rerange.
        assertGt(IMorpho(MORPHO).position(Id.wrap(MARKET_ID), address(strategy)).borrowShares, 0, "debt vanished");

        // ── Settle ──
        vm.prank(address(vaultStub));
        strategy.settle();

        assertEq(uint256(strategy.state()), 2, "not settled");
        assertEq(IERC20(USDG).balanceOf(address(strategy)), 0, "vault asset stranded in the clone");
        console2.log("vault USDG after settle", IERC20(USDG).balanceOf(address(vaultStub)));
    }

    /// @notice UNLEVERED lifecycle against the live NVDA/USDG 0.05% pool — the
    ///         venue the strategy family actually targets ($33M/day when
    ///         measured 2026-08-31) and the mode that exists because 4663 has
    ///         no borrow market this template can fund (spUSDG drained to $3;
    ///         syrupUSDG fails the wrapper rule, correctly).
    ///
    ///         No Morpho address is configured AT ALL, so this doubles as the
    ///         fork-grade "never touches Morpho" pin: a stray reach for the
    ///         surface is a typed call to address(0) and fails the test
    ///         undecodably rather than passing against a mock.
    function test_fork_unleveredLifecycle() public {
        _skipIfNoFork();

        address poolAddr = IUniswapV3Factory(UNISWAP_V3_FACTORY).getPool(USDG, NVDA, 500);
        if (poolAddr == address(0)) vm.skip(true);
        IUniswapV3Pool nvdaPool = IUniswapV3Pool(poolAddr);

        (,,, uint16 cardinality,,,) = nvdaPool.slot0();
        if (cardinality < 2) {
            nvdaPool.increaseObservationCardinalityNext(4);
            vm.warp(block.timestamp + TWAP_WINDOW + 1);
            vm.roll(block.number + 1);
        }

        int24 spacing = nvdaPool.tickSpacing();
        (, int24 spot,,,,,) = nvdaPool.slot0();
        // The momentum pod's band: ±3% ≈ ±300 ticks, snapped to spacing.
        int24 lower = ((spot - 300) / spacing) * spacing;
        int24 upper = ((spot + 300) / spacing) * spacing;

        ConcentratedLiquidityStrategy.InitParams memory p = ConcentratedLiquidityStrategy.InitParams({
            pool: poolAddr,
            positionManager: POSITION_MANAGER,
            uniswapFactory: UNISWAP_V3_FACTORY,
            swapAdapter: address(adapter),
            morpho: address(0),
            marketParams: MarketParams({
                loanToken: address(0),
                collateralToken: address(0),
                oracle: address(0),
                irm: address(0),
                lltv: 0
            }),
            collateralAmount: 0,
            borrowAmount: 0,
            lpAmount: 10_000e6,
            tickLower: lower,
            tickUpper: upper,
            expectedLiquidity: uint128(nvdaPool.liquidity() / 100),
            swapFractionBps: 5_000,
            twapWindow: TWAP_WINDOW,
            maxTwapDeviationBps: 1_000,
            mintSlippageBps: 1_000,
            rerange: ConcentratedLiquidityStrategy.RerangePolicy({
                halfWidthTicks: 300,
                triggerBps: 1,
                minInterval: 0,
                maxReranges: 2,
                slippageBps: 1_000,
                swapFractionBps: 5_000
            }),
            settleSlippageBps: 1_000,
            settleDeadline: 0,
            swapExtraData: abi.encodePacked(bytes1(0x00), abi.encode(uint24(500)))
        });

        strategy = ConcentratedLiquidityStrategy(Clones.clone(address(template)));
        strategy.initialize(address(vaultStub), proposer, abi.encode(p));
        status.set(1, 1, address(strategy));
        vm.prank(address(vaultStub));
        IERC20(USDG).approve(address(strategy), type(uint256).max);

        _repairNextIdIfForkStateCorrupt();

        uint256 vaultBefore = IERC20(USDG).balanceOf(address(vaultStub));

        vm.prank(address(vaultStub));
        strategy.execute();
        assertEq(strategy.levered(), false, "mode misread");
        uint256 tokenId = strategy.tokenId();
        assertGt(tokenId, 0, "no position minted");
        assertEq(
            vaultBefore - IERC20(USDG).balanceOf(address(vaultStub)), 10_000e6, "pulled something other than lpAmount"
        );
        (,,,,,,, uint128 liquidity,,,,) = INonfungiblePositionManager(POSITION_MANAGER).positions(tokenId);
        assertGt(liquidity, 0, "position holds no liquidity");
        console2.log("unlevered minted liquidity", uint256(liquidity));

        // ── Rerange against the live pool, permissionless caller ──
        // Re-arm the repair: the rerange consumes another token id, and the
        // orphan range may begin past the id execute just took.
        _repairNextIdIfForkStateCorrupt();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        strategy.rerange();
        assertTrue(strategy.tokenId() != tokenId, "rerange did not replace the position");

        // ── Settle: everything the venue returns goes home ──
        vm.prank(address(vaultStub));
        strategy.settle();
        assertEq(uint256(strategy.state()), 2, "not settled");
        assertEq(IERC20(USDG).balanceOf(address(strategy)), 0, "vault asset stranded in the clone");
        assertEq(strategy.hasUndeliveredValue(), false, "phantom residue");
        assertEq(strategy.hasUnvaluedResidue(), false, "phantom unvalued residue");

        uint256 delivered = IERC20(USDG).balanceOf(address(vaultStub));
        // Round trip through a real 5bps pool with two swap legs: bounded loss,
        // not exact return. 3% of funding is a generous ceiling; the assert is
        // that value came HOME, not that the trade was free.
        assertGt(delivered + uint256(10_000e6) / 33, vaultBefore, "settlement lost more than ~3%");
        console2.log("vault USDG delta after unlevered cycle", vaultBefore - delivered);
    }

    /// @dev TEST-ENVIRONMENT REPAIR, guarded so it is inert against healthy
    ///      state. Measured on the shared Tenderly vnet (2026-09-01): the
    ///      position manager's `_nextId` read 934278 while tokens
    ///      934278..934289 already had owners — someone state-injected mints
    ///      without bumping the counter, so every genuine `mint` reverts
    ///      `ERC721: token already minted`. That is fork corruption, not
    ///      protocol behavior; on a healthy chain the probe below finds the
    ///      first id unowned immediately and this writes nothing.
    ///
    ///      Slot 13 packs `_nextId` (uint176, low bits) with `_nextPoolId`
    ///      (uint80, high bits); the write preserves the pool-id half.
    function _repairNextIdIfForkStateCorrupt() internal {
        bytes32 raw = vm.load(POSITION_MANAGER, bytes32(uint256(13)));
        uint256 nextId = uint256(raw) & ((1 << 176) - 1);
        uint256 poolIdBits = uint256(raw) >> 176;
        // The injected ids are not merely owned — some are POISONED at the
        // EVM level: `ownerOf` on them executes an invalid opcode (observed
        // ids 934599/934604+ on the vnet, 2026-09-01), and an invalid opcode
        // consumes ALL forwarded gas, so an uncapped probe loop drains the
        // whole test on four bad ids. Hence three defenses:
        //   - every probe is GAS-CAPPED, so a poisoned id costs 30k, not 63/64
        //     of everything;
        //   - ids are classified by RETURNDATA, not just success: a cleanly
        //     nonexistent token reverts WITH a reason string, a poisoned one
        //     dies with EMPTY returndata — and only the clean kind is a safe
        //     landing zone for `_nextId`, since minting a poisoned id would
        //     detonate the same slots;
        //   - the repair settles only after 16 consecutive clean ids, because
        //     the orphan block has gaps that fooled break-at-first-unowned.
        uint256 id = nextId;
        uint256 probe = nextId;
        uint256 cleanRun = 0;
        while (cleanRun < 16 && probe < nextId + 512) {
            (bool ok, bytes memory ret) =
                POSITION_MANAGER.staticcall{gas: 30_000}(abi.encodeWithSignature("ownerOf(uint256)", probe));
            if (!ok && ret.length > 0) {
                cleanRun++; // clean "nonexistent token" revert
            } else {
                id = probe + 1; // owned or poisoned: land above it
                cleanRun = 0;
            }
            probe++;
        }
        if (id != nextId) {
            emit log_named_uint("repairing corrupt fork _nextId, skipping owned ids", id - nextId);
            vm.store(POSITION_MANAGER, bytes32(uint256(13)), bytes32((poolIdBits << 176) | id));
        }
    }

    /// @notice The TWAP guard reads the REAL observation ring, not a stand-in.
    function test_fork_twapGuardReadsLiveObservations() public {
        _skipIfNoFork();
        (,,, uint16 cardinality,,,) = pool.slot0();
        if (cardinality < 2) vm.skip(true);

        _initStrategy();
        _repairNextIdIfForkStateCorrupt();

        uint32[] memory ago = new uint32[](2);
        ago[0] = TWAP_WINDOW;
        ago[1] = 0;
        (int56[] memory cumulatives,) = pool.observe(ago);
        int24 twap = int24((cumulatives[1] - cumulatives[0]) / int56(uint56(TWAP_WINDOW)));
        (, int24 spot,,,,,) = pool.slot0();
        console2.log("live spot tick", int256(spot));
        console2.log("live twap tick", int256(twap));

        // Execute succeeds only if the live pair is inside the configured bound,
        // which is the guard doing its job against real data.
        vm.prank(address(vaultStub));
        strategy.execute();
        assertGt(strategy.tokenId(), 0);
    }
}
