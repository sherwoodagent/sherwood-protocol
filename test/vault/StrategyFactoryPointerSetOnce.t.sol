// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StructuralBatchRulesTest} from "./StructuralBatchRules.t.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";

/// @notice A `StrategyFactory`-shaped stub that answers `setStrategyFactory`'s probe and then
///         vouches for nothing — the shape that would strand every live position.
contract DeadFactory {
    function cloneTemplate(address) external pure returns (address) {
        return address(0);
    }

    function isRegisteredStrategy(address) external pure returns (bool) {
        return false;
    }
}

/// @notice `TierRegistry.strategyFactory` is read live by `SyndicateVault._guardBatchCalls` on
///         every execute and settle, so the pointer is set once: the owner cannot re-point it
///         under a live position and leave that position unsettleable (v1 audit F7 / NM 6.26).
contract StrategyFactoryPointerSetOnceTest is StructuralBatchRulesTest {
    /// @notice The re-point is refused at the setter and the live executed position settles.
    function test_pointerCannotBeRepointedUnderALiveExecutedPosition() public {
        MorphoSupplyStrategy template = _morphoVenue();
        _certifyClassNow(address(template), BaseStrategy.execute.selector, 1, uint16(CLASS_BOUND));
        uint256 cap = 1_000_000e6;
        address clone = _morphoClone(address(template), agent, cap);

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (clone, cap)));
        execCalls[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = cap;
        uint256 pid = _propose(
            clone, execCalls, execCaps, _one(clone, abi.encodeCall(BaseStrategy.settle, ())), new uint256[](1), cap
        );
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        assertEq(uint256(BaseStrategy(clone).state()), uint256(BaseStrategy.State.Executed), "capital is deployed");

        address dead = address(new DeadFactory());
        vm.expectRevert(TierRegistry.StrategyFactoryAlreadySet.selector);
        tierRegistry.setStrategyFactory(dead);
        assertEq(tierRegistry.strategyFactory(), address(strategyFactory), "the pointer did not move");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertEq(uint256(BaseStrategy(clone).state()), uint256(BaseStrategy.State.Settled), "and it settled");
    }
}
