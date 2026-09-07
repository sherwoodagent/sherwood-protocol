// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IStrategyDelivery} from "../../src/interfaces/IStrategyDelivery.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";

/// @notice Settlement is all-or-revert, so no strategy template carries the residue
///         views any more. The vault's low-level probes find no function and record
///         nothing, which is the safe reading until the vault side is deleted too.
contract StrategyDeliverySurfaceTest is Test {
    function test_noStrategyReportsUndeliveredValue() public {
        address[] memory templates = new address[](3);
        templates[0] = address(new MorphoSupplyStrategy());
        templates[1] = address(new ConcentratedLiquidityStrategy());
        templates[2] = address(new PortfolioStrategy());

        bytes[] memory probes = new bytes[](3);
        probes[0] = abi.encodeCall(IStrategyDelivery.hasUndeliveredValue, ());
        probes[1] = abi.encodeCall(IStrategyDelivery.undeliveredValue, ());
        probes[2] = abi.encodeCall(IStrategyDelivery.hasUnvaluedResidue, ());

        for (uint256 t = 0; t < templates.length; t++) {
            // Control: a real selector answers, so `ok == false` below means "no such function".
            (bool ctrl, bytes memory ret) = templates[t].staticcall(abi.encodeCall(IStrategy.name, ()));
            assertTrue(ctrl, "control selector must answer");
            assertGt(bytes(abi.decode(ret, (string))).length, 0, "control returned no name");

            for (uint256 i = 0; i < probes.length; i++) {
                (bool ok,) = templates[t].staticcall(probes[i]);
                assertFalse(ok, "a strategy template still answers a residue probe");
            }
        }
    }
}
