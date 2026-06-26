// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseAddresses} from "./BaseAddresses.sol";
import {ICLPool, ICLGauge, ICLSwapRouter, INonfungiblePositionManager} from "../../../src/interfaces/ISlipstream.sol";
import {IMoonwellMarket, IComptroller, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";
import {LiquidityAmounts} from "../../../src/libraries/LiquidityAmounts.sol";

// IAggregatorV3 minimal — for feed staleness check
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

// IWETH9 minimal — Moonwell's WETH market sends native ETH on borrow; wrap it back.
interface IWETH9 {
    function deposit() external payable;
}

/// @title  LeveragedAeroForkBase
/// @notice Abstract Tenderly-vnet fork harness for the leveraged Aerodrome CL strategy tests.
///         Provides: setUp (fork+skip), funding helpers, _openRealBook, _shoveTick, _naiveSlot0Nav.
/// @dev    Fork URL: vm.rpcUrl("tenderly") from foundry.toml. Tests skip if the env var is unset.
abstract contract LeveragedAeroForkBase is Test {
    // ── constants from BaseAddresses ──
    address internal constant USDC = BaseAddresses.USDC;
    address internal constant WETH = BaseAddresses.WETH;
    address internal constant CBBTC = BaseAddresses.CBBTC;
    address internal constant MUSDC = BaseAddresses.MOONWELL_MUSDC;
    address internal constant MWETH = BaseAddresses.MOONWELL_MWETH;
    address internal constant MCBBTC = BaseAddresses.MOONWELL_MCBBTC;
    address internal constant COMPTROLLER = BaseAddresses.MOONWELL_COMPTROLLER;
    address internal constant POOL = BaseAddresses.CBBTC_WETH_POOL;
    address internal constant GAUGE = BaseAddresses.CBBTC_WETH_GAUGE;
    address internal constant NPM = BaseAddresses.SLIPSTREAM_NPM;
    address internal constant CL_ROUTER = BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER;
    int24 internal constant TICK_SPACING = BaseAddresses.CBBTC_WETH_TICK_SPACING; // 100

    // ── fork skip flag ──
    bool internal _skip;

    // ─────────────────────────────────────────────────────────────
    // setUp — fork-or-skip
    // ─────────────────────────────────────────────────────────────

    function setUp() public virtual {
        string memory rpc = vm.envOr("TENDERLY_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            _skip = true;
            return;
        }
        // Try pinned block first; Tenderly vnets may reject a specific block number
        // if the vnet doesn't have history before that point — fall back to latest.
        try vm.createSelectFork(rpc, 47_246_489) {
        // pinned succeeded
        }
        catch {
            vm.createSelectFork(rpc);
        }
        // NOTE: vnet chainId = 9998453 (virtual), NOT 8453 — do not assert block.chainid == 8453
        // [9] Sanity: the fixed relative-tolerance assertions (2% / 0.5%) assume the cbBTC/WETH
        // pool is live at the forked block. If the pinned fork was rejected and the fallback
        // landed on a wrong/empty state, FAIL LOUDLY here instead of silently producing
        // nondeterministic comparisons that mask regressions.
        (uint160 sqrtP,,,,,) = ICLPool(POOL).slot0();
        require(POOL.code.length != 0 && sqrtP != 0, "fork: cbBTC/WETH pool not live at this block");
    }

    // ─────────────────────────────────────────────────────────────
    // Config builder
    // ─────────────────────────────────────────────────────────────

    /// @notice Build the valuation Config.
    /// @dev token0 = WETH (18dp), token1 = cbBTC (8dp) for tickSpacing=100 pool.
    ///      maxDelay is set to 48 hours to tolerate Tenderly vnet's frozen block.timestamp
    ///      (feeds update every ~1h on mainnet but the vnet clock may lag).
    function _cfg() internal pure returns (LeveragedAeroValuation.Config memory c) {
        c = LeveragedAeroValuation.Config({
            usdc: USDC,
            vault: address(0), // no vault in harness — float term = 0
            mUsdc: MUSDC,
            cbBTCMarket: MCBBTC,
            wethMarket: MWETH,
            cbBTC: CBBTC,
            weth: WETH,
            cbBTCDecimals: 8,
            wethDecimals: 18,
            pool: POOL,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            maxDelay: 48 hours, // generous: vnet block.timestamp may lag real time
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Funding helpers
    // ─────────────────────────────────────────────────────────────

    /// @notice Fund `addr` with `amt` USDC. Tries deal() first; falls back to
    ///         tenderly_setErc20Balance RPC if the balance assertion fails.
    function _fundUSDC(address addr, uint256 amt) internal {
        deal(USDC, addr, amt);
        if (IERC20(USDC).balanceOf(addr) != amt) {
            // Tenderly vnet extension: set ERC-20 balance via JSON-RPC
            string memory hexAmt = _toHex(amt);
            string memory params =
                string.concat("[\"", vm.toString(USDC), "\",\"", vm.toString(addr), "\",\"", hexAmt, "\"]");
            vm.rpc("tenderly_setErc20Balance", params);
            assertEq(IERC20(USDC).balanceOf(addr), amt, "USDC fund: both paths failed");
        }
    }

    /// @notice Fund `addr` with `amt` WETH. Tries deal(); falls back to tenderly RPC.
    function _fundWETH(address addr, uint256 amt) internal {
        deal(WETH, addr, amt);
        if (IERC20(WETH).balanceOf(addr) != amt) {
            string memory hexAmt = _toHex(amt);
            string memory params =
                string.concat("[\"", vm.toString(WETH), "\",\"", vm.toString(addr), "\",\"", hexAmt, "\"]");
            vm.rpc("tenderly_setErc20Balance", params);
            assertGe(IERC20(WETH).balanceOf(addr), amt, "WETH fund: both paths failed");
        }
    }

    /// @notice Fund `addr` with `amt` cbBTC (8dp). Tries deal(); falls back to tenderly RPC.
    ///         Needed for the `_shoveTick(_, false)` (cbBTC→WETH) direction.
    function _fundCbBTC(address addr, uint256 amt) internal {
        deal(CBBTC, addr, amt);
        if (IERC20(CBBTC).balanceOf(addr) != amt) {
            string memory hexAmt = _toHex(amt);
            string memory params =
                string.concat("[\"", vm.toString(CBBTC), "\",\"", vm.toString(addr), "\",\"", hexAmt, "\"]");
            vm.rpc("tenderly_setErc20Balance", params);
            assertGe(IERC20(CBBTC).balanceOf(addr), amt, "cbBTC fund: both paths failed");
        }
    }

    // ─────────────────────────────────────────────────────────────
    // _openRealBook
    // ─────────────────────────────────────────────────────────────

    /// @notice Opens a real leveraged CL book for `who`:
    ///   1. Fund USDC, supply to Moonwell (mUSDC), enterMarkets.
    ///   2. Borrow cbBTC + WETH (~25% of collateral value each, capped to avoid revert).
    ///   3. Mint a CL position via NPM straddling the current tick.
    ///   4. Stake the NFT in the gauge.
    /// @return tokenId    The NPM token ID (> 0 on success).
    /// @return tickLower  The actual lower tick of the minted position.
    /// @return tickUpper  The actual upper tick.
    /// @return liquidity  The actual liquidity minted.
    function _openRealBook(address who, uint256 principalUsdc)
        internal
        returns (uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        // Read live prices to size borrows
        (, int256 btcAns,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_BTC_USD).latestRoundData();
        (, int256 ethAns,,,) = IAggregatorV3(BaseAddresses.CHAINLINK_ETH_USD).latestRoundData();
        uint256 pBTC = uint256(btcAns); // 8dp
        uint256 pETH = uint256(ethAns); // 8dp

        // Target ~25% of principalUsdc in each borrowed token (conservative vs 30% to
        // stay under collateral factor + borrow caps). principalUsdc is 6dp.
        // USD value at 8dp = principalUsdc * 1e2 * 0.25 (scale from 6dp to 8dp)
        uint256 targetUsd8 = (principalUsdc * 1e2 * 25) / 100; // 25% in 8dp USD terms

        // cbBTC amount (8dp): USD / price
        uint256 cbAmt = targetUsd8 * 1e8 / pBTC; // result in cbBTC 8dp units
        // WETH amount (18dp): targetUsd8 (8dp USD) / pETH (8dp) * 1e18 = targetUsd8 * 1e18 / pETH
        uint256 wethAmt = targetUsd8 * 1e18 / pETH;

        vm.startPrank(who);

        // 1. Fund + supply USDC as collateral
        _fundUSDC(who, principalUsdc);
        IERC20(USDC).approve(MUSDC, principalUsdc);
        uint256 mintErr = ICToken(MUSDC).mint(principalUsdc);
        require(mintErr == 0, "mUSDC mint failed");

        // 2. enterMarkets for mUSDC collateral
        address[] memory markets = new address[](1);
        markets[0] = MUSDC;
        IComptroller(COMPTROLLER).enterMarkets(markets);

        // 3. Borrow cbBTC — try, halve on failure
        uint256 cbBorrowErr = IMoonwellMarket(MCBBTC).borrow(cbAmt);
        if (cbBorrowErr != 0) {
            cbAmt = cbAmt / 2;
            cbBorrowErr = IMoonwellMarket(MCBBTC).borrow(cbAmt);
            require(cbBorrowErr == 0, "cbBTC borrow failed even at half");
        }
        console2.log("cbBTC borrowed (8dp units):", cbAmt);

        // 4. Borrow WETH — try, halve on failure
        uint256 wethBorrowErr = IMoonwellMarket(MWETH).borrow(wethAmt);
        if (wethBorrowErr != 0) {
            wethAmt = wethAmt / 2;
            wethBorrowErr = IMoonwellMarket(MWETH).borrow(wethAmt);
            require(wethBorrowErr == 0, "WETH borrow failed even at half");
        }
        console2.log("WETH borrowed (18dp units):", wethAmt);

        // 4b. Moonwell's WETH market delivers native ETH on borrow — wrap it to WETH ERC-20
        //     so the NPM mint callback (WETH.transferFrom) can pull it.
        //     vm.deal ensures alice has sufficient native ETH even if the market router
        //     forwarded it in a way that doesn't reflect in Forge's prank balance tracking.
        vm.deal(who, wethAmt);
        IWETH9(WETH).deposit{value: wethAmt}();

        // 5. Get current tick and set bounds straddling it (±20 tickSpacings)
        (, int24 currentTick,,,,) = ICLPool(POOL).slot0();
        int24 span = 20 * TICK_SPACING;
        tickLower = _alignTick(currentTick - span, TICK_SPACING);
        tickUpper = _alignTick(currentTick + span, TICK_SPACING);
        // ensure tickUpper > tickLower after alignment
        if (tickUpper <= tickLower) tickUpper = tickLower + TICK_SPACING;

        // token0 = WETH, token1 = cbBTC (confirmed for ts=100 pool)
        IERC20(WETH).approve(NPM, wethAmt);
        IERC20(CBBTC).approve(NPM, cbAmt);

        INonfungiblePositionManager.MintParams memory mp = INonfungiblePositionManager.MintParams({
            token0: WETH,
            token1: CBBTC,
            tickSpacing: TICK_SPACING,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: wethAmt,
            amount1Desired: cbAmt,
            amount0Min: 0,
            amount1Min: 0,
            recipient: who,
            deadline: block.timestamp + 600,
            sqrtPriceX96: 0
        });
        uint128 mintedLiquidity;
        (tokenId, mintedLiquidity,,) = INonfungiblePositionManager(NPM).mint(mp);
        require(tokenId > 0, "NPM mint returned tokenId=0");

        // 6. Stake in gauge — ERC-721 approve via low-level call (not ERC-20 approve)
        (bool ok,) = NPM.call(abi.encodeWithSignature("approve(address,uint256)", GAUGE, tokenId));
        require(ok, "NPM ERC-721 approve failed");
        ICLGauge(GAUGE).deposit(tokenId);

        vm.stopPrank();

        // Read back actual position from NPM (gauge holds the NFT now)
        (,,,,, int24 posTickLower, int24 posTickUpper, uint128 posLiquidity,,,,) =
            INonfungiblePositionManager(NPM).positions(tokenId);

        tickLower = posTickLower;
        tickUpper = posTickUpper;
        liquidity = posLiquidity;
    }

    // ─────────────────────────────────────────────────────────────
    // _shoveTick
    // ─────────────────────────────────────────────────────────────

    /// @notice Move the pool tick by swapping a large WETH amount.
    /// @param amountIn   Amount of the input token to sell (WETH 18dp if zeroForOne, else cbBTC 8dp).
    /// @param zeroForOne True = sell token0 (WETH) for token1 (cbBTC), moving tick down.
    /// @return newTick   The pool tick after the swap.
    function _shoveTick(uint256 amountIn, bool zeroForOne) internal returns (int24 newTick) {
        address swapper = makeAddr("tick_swapper");

        // [4] Fund + approve the token actually being SOLD. zeroForOne=true sells token0=WETH;
        //     false sells token1=cbBTC. Previously this always funded/approved WETH, so the
        //     `false` direction tried to pull cbBTC from an empty balance and reverted.
        address tokenIn = zeroForOne ? WETH : CBBTC;
        address tokenOut = zeroForOne ? CBBTC : WETH;
        if (zeroForOne) _fundWETH(swapper, amountIn);
        else _fundCbBTC(swapper, amountIn);

        vm.startPrank(swapper);
        IERC20(tokenIn).approve(CL_ROUTER, amountIn);

        ICLSwapRouter.ExactInputSingleParams memory sp = ICLSwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            tickSpacing: TICK_SPACING,
            recipient: swapper,
            deadline: block.timestamp + 600,
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });
        ICLSwapRouter(CL_ROUTER).exactInputSingle(sp);
        vm.stopPrank();

        (, newTick,,,,) = ICLPool(POOL).slot0();
    }

    // ─────────────────────────────────────────────────────────────
    // _naiveSlot0Nav — TEST-ONLY contrast baseline
    // ─────────────────────────────────────────────────────────────

    /// @notice Returns the pool-slot0-based NAV (manipulable by tick-shove).
    ///         Same term structure as `LeveragedAeroValuation.netEquityUsdc` but feeds
    ///         `pool.slot0().sqrtPriceX96` instead of the oracle-implied sqrtP, and
    ///         skips the calm-gate. Used as the contrast baseline in manipulation-proof tests.
    function _naiveSlot0Nav(
        LeveragedAeroValuation.Config memory c,
        address strategy,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256 navUsdc) {
        // Read live prices for debt + collateral terms (same as the real impl)
        (, int256 btcAns,, uint256 btcUpdatedAt,) = IAggregatorV3(c.cbBTCFeed).latestRoundData();
        (, int256 ethAns,, uint256 ethUpdatedAt,) = IAggregatorV3(c.wethFeed).latestRoundData();
        (, int256 usdcAns,,,) = IAggregatorV3(c.usdcFeed).latestRoundData();
        require(btcAns > 0 && ethAns > 0 && usdcAns > 0, "naiveSlot0Nav: feed answer <= 0");
        require(block.timestamp - btcUpdatedAt <= c.maxDelay, "naiveSlot0Nav: BTC feed stale");
        require(block.timestamp - ethUpdatedAt <= c.maxDelay, "naiveSlot0Nav: ETH feed stale");

        uint256 pBTC = uint256(btcAns);
        uint256 pETH = uint256(ethAns);
        uint256 pUsdc = uint256(usdcAns);

        // float + idle (0 for harness since vault=address(0))
        uint256 assets;
        if (c.vault != address(0)) assets += IERC20(c.usdc).balanceOf(c.vault);
        assets += IERC20(c.usdc).balanceOf(strategy);

        // collateral (mUSDC)
        uint256 cBal = ICToken(c.mUsdc).balanceOf(strategy);
        if (cBal > 0) {
            uint256 rate = ICToken(c.mUsdc).exchangeRateStored();
            assets += (cBal * rate) / 1e18;
        }

        // CL legs — use SLOT0 sqrtP (the manipulable price)
        if (liquidity > 0) {
            (uint160 slot0SqrtP,,,,,) = ICLPool(c.pool).slot0();
            // Map token0/token1 prices to the pool ordering
            address t0 = ICLPool(c.pool).token0();
            uint256 p0;
            uint8 d0;
            uint256 p1;
            uint8 d1;
            if (t0 == c.cbBTC) {
                (p0, d0, p1, d1) = (pBTC, 8, pETH, 18);
            } else {
                (p0, d0, p1, d1) = (pETH, 18, pBTC, 8);
            }
            (uint256 amt0, uint256 amt1) = LiquidityAmounts.getAmountsForLiquidity(
                slot0SqrtP, TickMath.getSqrtRatioAtTick(tickLower), TickMath.getSqrtRatioAtTick(tickUpper), liquidity
            );
            // price both legs to USDC
            assets += _usdcValueNaive(amt0, d0, p0, pUsdc);
            assets += _usdcValueNaive(amt1, d1, p1, pUsdc);
        }

        // debt
        uint256 cbDebt = IMoonwellMarket(c.cbBTCMarket).borrowBalanceStored(strategy);
        uint256 wethDebt = IMoonwellMarket(c.wethMarket).borrowBalanceStored(strategy);
        uint256 debt;
        debt += _usdcValueNaive(cbDebt, 8, pBTC, pUsdc);
        debt += _usdcValueNaive(wethDebt, 18, pETH, pUsdc);

        require(assets > debt, "naiveSlot0Nav: non-positive equity");
        navUsdc = assets - debt;
    }

    // ─────────────────────────────────────────────────────────────
    // Internal utilities
    // ─────────────────────────────────────────────────────────────

    function _usdcValueNaive(uint256 amount, uint8 tokenDecimals, uint256 pToken, uint256 pUsdc)
        private
        pure
        returns (uint256)
    {
        if (amount == 0 || pToken == 0 || pUsdc == 0) return 0;
        // usdValue at 8dp: amount * pToken / 10^tokenDecimals
        // → USDC face (6dp): * 1e6 / pUsdc
        uint256 usdValue = (amount * pToken) / (10 ** uint256(tokenDecimals));
        return (usdValue * 1e6) / pUsdc;
    }

    /// @dev Align tick down to the nearest multiple of tickSpacing.
    function _alignTick(int24 tick, int24 spacing) private pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return tick - rem;
    }

    /// @dev Convert uint256 to "0x..." hex string for RPC params.
    ///      Uses correct nibble extraction: shift right by 4*(63-i) bits and mask low nibble.
    function _toHex(uint256 v) private pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(66);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 32; i++) {
            str[2 + i * 2] = alphabet[(v >> (4 * (63 - 2 * i))) & 0xf];
            str[2 + i * 2 + 1] = alphabet[(v >> (4 * (63 - 2 * i - 1))) & 0xf];
        }
        return string(str);
    }
}
