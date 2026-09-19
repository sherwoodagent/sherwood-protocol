// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {MAX_GROW_PER_TX} from "./DeployWoodPoolFeed.s.sol";
import {IUniswapV3Pool} from "../src/vendor/uniswap/IUniswapV3Pool.sol";

/**
 * @title  GrowV3Cardinality
 * @notice Grows the WOOD/WETH V3 pool's observation ring so it can serve
 *         `TWAP_WINDOW`. A NAMED CEREMONY STEP, run BEFORE `DeployWoodPoolFeed`,
 *         because that script's cardinality pre-flight refuses a pool whose ring
 *         cannot serve the window — and because the call is permissionless and
 *         monotonic, so it can be run early and repeated harmlessly.
 *
 *         THE CALLER PAYS FOR THE SLOTS, UP FRONT. `increaseObservationCardinalityNext`
 *         initialises every new slot inside the call, at ~22.4k gas each, so N is
 *         bounded by what one transaction can carry rather than by the ring's
 *         uint16 index. A longer ring is reached by repeating this step.
 *
 *   Address book / environment:
 *     WOOD_WETH_UNISWAP_V3_POOL — the pool (env override first, book second)
 *     V3_CARDINALITY            — REQUIRED. The N to ask for; size it from the
 *                                 `required for a <window> s window` line
 *                                 `DeployWoodPoolFeed` prints.
 *
 *   Usage:
 *     V3_CARDINALITY=200 forge script \
 *       script/DeployWoodPoolFeed.s.sol:GrowV3Cardinality \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 *
 *     For a target above 1400, grow in steps: repeat the call with a higher
 *     V3_CARDINALITY each time.
 *
 * @dev THE GROWTH IS NOT INSTANT. `increaseObservationCardinalityNext` raises a
 *      TARGET; the ring reaches it one slot at a time, as the pool is traded.
 *      `observationCardinality` is what `observe` can actually serve.
 */
contract GrowV3Cardinality is ScriptBase {
    function run() external {
        grow(
            vm.envOr("WOOD_WETH_UNISWAP_V3_POOL", _optionalAddress("WOOD_WETH_UNISWAP_V3_POOL")),
            vm.envOr("V3_CARDINALITY", uint256(0))
        );
    }

    /// @notice Pre-flights and broadcasts the growth. Public so the tests can
    ///         drive the real thing without the process environment.
    function grow(address pool, uint256 target) public {
        require(pool != address(0), "PRE-FLIGHT: WOOD_WETH_UNISWAP_V3_POOL unset");
        require(pool.code.length != 0, "PRE-FLIGHT: V3 pool has no code");
        require(target != 0, "PRE-FLIGHT: V3_CARDINALITY unset");
        require(target <= type(uint16).max, "PRE-FLIGHT: V3_CARDINALITY above the uint16 ceiling (65535)");
        require(
            target <= MAX_GROW_PER_TX,
            "PRE-FLIGHT: V3_CARDINALITY above what one transaction can initialise (1400); grow in steps"
        );

        (,,, uint16 cardinality, uint16 cardinalityNext,,) = IUniswapV3Pool(pool).slot0();
        console.log("v3 pool:                    %s", pool);
        console.log("observationCardinality:     %s", cardinality);
        console.log("observationCardinalityNext: %s", cardinalityNext);

        if (cardinality >= target || cardinalityNext >= target) {
            console.log("already at or above V3_CARDINALITY (%s) - nothing broadcast", target);
            console.log(
                "the ring is %s of a %s target: `next` is a target the pool fills one", cardinality, cardinalityNext
            );
            console.log("observation at a time, as it is traded. Until the gap closes,");
            console.log("observe(window) still reverts and DeployWoodPoolFeed's cardinality");
            console.log("pre-flight still refuses - which is the honest signal that the window");
            console.log("is not yet spannable, not a script bug.");
            return;
        }

        vm.startBroadcast();
        // Bounded against the uint16 ceiling above; the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(uint16(target));
        vm.stopBroadcast();

        (,,, uint16 grown, uint16 grownNext,,) = IUniswapV3Pool(pool).slot0();
        console.log("-> observationCardinality:     %s", grown);
        console.log("-> observationCardinalityNext: %s", grownNext);
        console.log("\nTHE RING IS NOT YET THAT LONG. `next` is a target the pool fills one");
        console.log("observation at a time, as it is traded; `observationCardinality` rises");
        console.log("behind it. Until it does, observe(window) still reverts and");
        console.log("DeployWoodPoolFeed's cardinality pre-flight still refuses - which is the");
        console.log("honest signal that the window is not yet spannable, not a script bug.");
    }
}
