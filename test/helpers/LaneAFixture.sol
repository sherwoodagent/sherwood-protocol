// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceRouter} from "../../src/pricing/PriceRouter.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";

/// @notice Shared fixture for Lane A adapter/strategy suites: a proxied
///         PriceRouter owned by `routerOwner`, plus helpers to mint tokens,
///         feeds, and router registrations without repeating proxy/prank
///         boilerplate in every suite.
abstract contract LaneAFixture is Test {
    PriceRouter internal router;
    address internal routerOwner = makeAddr("routerOwner");

    function _deployRouter() internal {
        PriceRouter impl = new PriceRouter();
        router = PriceRouter(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(PriceRouter.initialize, (routerOwner))))
        );
    }

    function _registerKind(bytes32 kind, address adapter, bool laneAEnabled) internal {
        vm.startPrank(routerOwner);
        router.registerAdapter(kind, adapter);
        if (laneAEnabled) router.setLaneAEnabled(kind, true);
        vm.stopPrank();
    }

    function _newToken(string memory symbol, uint8 decimals_) internal returns (ERC20Mock) {
        return new ERC20Mock(symbol, symbol, decimals_);
    }

    /// @dev Feed answering `answer` at `decimals_`, fresh as of now.
    function _newFeed(uint8 decimals_, int256 answer) internal returns (MockAggregatorV3) {
        return new MockAggregatorV3(decimals_, answer);
    }
}
