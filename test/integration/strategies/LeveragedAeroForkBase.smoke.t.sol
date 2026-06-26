// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {LeveragedAeroValuation} from "../../../src/strategies/LeveragedAeroValuation.sol";
import {ICLPool} from "../../../src/interfaces/ISlipstream.sol";
import {IMoonwellMarket} from "../../../src/interfaces/IMoonwellMarket.sol";

/// @title  LeveragedAeroForkBaseSmoke
/// @notice Smoke test proving the Tenderly-vnet harness stands up a real leveraged CL position.
///         Run: forge test --match-path '*LeveragedAeroForkBase.smoke.t.sol' -vvv
contract LeveragedAeroForkBaseSmoke is LeveragedAeroForkBase {
    uint256 constant PRINCIPAL = 50_000e6; // 50k USDC

    function setUp() public override {
        super.setUp();
    }

    function test_openRealBook_and_shoveTick() public {
        if (_skip) return;

        address alice = makeAddr("alice");
        (, int24 startTick,,,,) = ICLPool(POOL).slot0();

        // ── open the real levered book ──
        (uint256 tokenId, int24 tickLower, int24 tickUpper, uint128 liquidity) = _openRealBook(alice, PRINCIPAL);

        // Basic position assertions
        assertGt(tokenId, 0, "tokenId must be > 0");
        assertGt(liquidity, 0, "liquidity must be > 0");
        assertLt(tickLower, tickUpper, "tickLower < tickUpper");

        // Borrows were actually recorded
        assertGt(IMoonwellMarket(MCBBTC).borrowBalanceStored(alice), 0, "cbBTC borrow balance must be > 0");
        assertGt(IMoonwellMarket(MWETH).borrowBalanceStored(alice), 0, "WETH borrow balance must be > 0");

        // ── oracle NAV is in a plausible range ──
        LeveragedAeroValuation.Config memory cfg = _cfg();
        uint256 nav = LeveragedAeroValuation.netEquityUsdc(cfg, alice, tickLower, tickUpper, liquidity);
        // Expect NAV within [10%, 190%] of principal (wide to tolerate price moves + borrow sizing)
        assertGt(nav, PRINCIPAL / 10, "NAV implausibly low");
        assertLt(nav, PRINCIPAL * 19 / 10, "NAV implausibly high");

        // ── tick-shove moves the pool tick ──
        // Sell 5 WETH (worth ~$17k-ish) to move the tick downward
        int24 newTick = _shoveTick(5e18, true);
        assertFalse(newTick == startTick, "tick did not move after shove");
    }

    /// @dev [PR #388 review-4] `_shoveTick(_, false)` (selling token1=cbBTC for token0=WETH) must
    ///      work — it previously funded WETH but set `tokenIn = cbBTC`, reverting on an empty
    ///      cbBTC balance. Confirms the reverse direction now funds/approves cbBTC and moves the tick.
    function test_shoveTick_reverseDirection() public {
        if (_skip) return;
        (, int24 startTick,,,,) = ICLPool(POOL).slot0();
        int24 afterTick = _shoveTick(1e8, false); // sell 1 cbBTC (8dp) for WETH
        assertFalse(afterTick == startTick, "reverse-direction shove must move the tick");
    }
}
