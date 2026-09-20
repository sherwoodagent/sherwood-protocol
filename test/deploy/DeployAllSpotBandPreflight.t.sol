// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeployAllFixture} from "./DeployAll.t.sol";
import {Checkpoint} from "../../script/robinhood-mainnet/DeployAll.s.sol";
import {Posture, Inputs, Stack} from "../../script/robinhood-mainnet/DeployTypes.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";

/// @notice The WOOD price cap is sized off instantaneous V2 spot; these pin that run 2 now
///         refuses a spot the feed's own TWAP disagrees with by more than 2x (v1 audit F4).
contract DeployAllSpotBandPreflightTest is DeployAllFixture {
    bytes internal constant DIVERGED = bytes("PRE-FLIGHT: WOOD spot diverges more than 2x from the feed TWAP");

    function setUp() public {
        _stageCeremony();
    }

    /// @notice A pump held across run 2's block used to seat a cap 10x the honest one with
    ///         every gate green, because `wethReserve` RISES and passes the depth floor.
    function test_pumpedPairIsRefusedOnRunTwo() public {
        vm.chainId(MAINNET_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Mainnet);
        _primeWoodFeed(first.woodUsdFeed);

        uniPair.setReserves(WOOD_RESERVE / 3162 * 1000, uint112(uint256(WETH_RESERVE) * 3162 / 1000));

        Inputs memory i = _inputs(Posture.Mainnet);
        vm.prank(deployer);
        vm.expectRevert(DIVERGED);
        script.deployAll(i);
    }

    /// @notice Draining to the depth floor used to seat a cap 66x UNDER market, which then
    ///         BINDS on every read because `woodPriceX8 = haircut(min(cap, feed))`.
    function test_drainedPairIsRefusedOnRunTwo() public {
        vm.chainId(MAINNET_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Mainnet);
        _primeWoodFeed(first.woodUsdFeed);

        uint112 drainedWeth = uint112(RobinhoodParams.MIN_WETH_RESERVE);
        uniPair.setReserves(
            uint112((uint256(WOOD_RESERVE) * uint256(WETH_RESERVE)) / uint256(drainedWeth)), drainedWeth
        );

        Inputs memory i = _inputs(Posture.Mainnet);
        vm.prank(deployer);
        vm.expectRevert(DIVERGED);
        script.deployAll(i);
    }

    /// @notice The band is not over-tight: an untouched pair still finishes run 2.
    function test_honestRunTwoStillCompletes() public {
        vm.chainId(MAINNET_CHAIN_ID);
        (Stack memory first,) = _runCeremony(Posture.Mainnet);
        _primeWoodFeed(first.woodUsdFeed);

        (, Checkpoint cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.Complete, "honest run 2 completes");
    }

    /// @notice Run 1's cap is discarded at the stage gate, so a feed that cannot answer yet
    ///         is a no-op here rather than a refusal the operator cannot act on.
    function test_runOneIsUncheckedBecauseItsCapIsDiscarded() public {
        vm.chainId(MAINNET_CHAIN_ID);
        uniPair.setReserves(WOOD_RESERVE / 3162 * 1000, uint112(uint256(WETH_RESERVE) * 3162 / 1000));

        (, Checkpoint cp) = _runCeremony(Posture.Mainnet);
        assertTrue(cp == Checkpoint.AwaitingWoodFeed, "run 1 stops at the gate, unchecked");
    }
}
