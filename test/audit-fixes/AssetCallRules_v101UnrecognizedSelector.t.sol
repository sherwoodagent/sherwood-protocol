// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StructuralBatchRulesTest, CustomStrategy} from "../vault/StructuralBatchRules.t.sol";
import {GlobalDollarMock} from "../mocks/GlobalDollarMock.sol";
import {AssetCallRules} from "../../src/AssetCallRules.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";

/// @notice The launch asset's surface plus Paxos's `transferFromBatch`, which spends
///         `msg.sender`'s allowance from each `from[i]`.
contract PaxosBatchMock is GlobalDollarMock {
    function transferFromBatch(address[] calldata from, address[] calldata to, uint256[] calldata value)
        external
        returns (bool)
    {
        require(from.length == to.length && to.length == value.length, "length");
        for (uint256 i = 0; i < from.length; i++) {
            _spendAllowance(from[i], msg.sender, value[i]);
            _transfer(from[i], to[i], value[i]);
        }
        return true;
    }
}

/// @notice Exposes the asset-leg predicate to calldata built in a test.
contract AssetCallRulesHarness {
    function spenderOf(address vault, bytes calldata data) external pure returns (address) {
        return AssetCallRules.spenderOf(vault, data);
    }
}

/// @notice Audit 2026-10-01 V1-01: an asset selector outside transfer, transferFrom and the
///         approve family is refused, so no batch can spend a depositor's allowance to the vault.
contract AssetCallRules_v101UnrecognizedSelectorTest is StructuralBatchRulesTest {
    uint256 constant LP_WALLET = 80_000_000e6;

    function _batchPull(address from, address to, uint256 amount) internal pure returns (bytes memory) {
        address[] memory froms = new address[](1);
        froms[0] = from;
        address[] memory tos = new address[](1);
        tos[0] = to;
        uint256[] memory values = new uint256[](1);
        values[0] = amount;
        return abi.encodeCall(PaxosBatchMock.transferFromBatch, (froms, tos, values));
    }

    function _assertLpUntouched() internal view {
        assertEq(usdc.balanceOf(lp1), LP_WALLET, "the LP's wallet is untouched");
        assertEq(usdc.allowance(lp1, address(vault)), type(uint256).max, "the LP's allowance is untouched");
        assertEq(usdc.balanceOf(attacker), 0, "the attacker got nothing");
    }

    function _proposeExpectingRefusal(BatchExecutorLib.Call[] memory execCalls, BatchExecutorLib.Call[] memory settle)
        internal
    {
        CustomStrategy venue = _custom();
        uint256[] memory execCaps = new uint256[](execCalls.length);
        uint256[] memory settleCaps = new uint256[](settle.length);
        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000});
        ISyndicateGovernor.CoProposer[] memory cos = new ISyndicateGovernor.CoProposer[](0);
        vm.prank(agent);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.UnrecognizedAssetSelector.selector, PaxosBatchMock.transferFromBatch.selector
            )
        );
        governor.propose(
            address(vault), address(venue), "ipfs://v101", 7 days, env, execCalls, execCaps, settle, settleCaps, cos
        );
    }

    /// @notice The vault guard refuses `transferFromBatch` naming an LP before the token sees it.
    function test_vaultGuardRefusesBatchPullOfLpAllowance() public {
        _deployStack(new PaxosBatchMock());
        BatchExecutorLib.Call[] memory calls = _one(address(usdc), _batchPull(lp1, attacker, LP_WALLET));
        vm.prank(address(governor));
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.UnrecognizedAssetSelector.selector, PaxosBatchMock.transferFromBatch.selector
            )
        );
        vault.executeGovernorBatch(calls, new uint256[](1), 0);
        _assertLpUntouched();
    }

    /// @notice The propose-time mirror refuses the same leg in the execute batch.
    function test_proposeRefusesBatchPullInExecuteLeg() public {
        _deployStack(new PaxosBatchMock());
        _proposeExpectingRefusal(
            _one(address(usdc), _batchPull(lp1, attacker, LP_WALLET)),
            _one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 0)))
        );
        _assertLpUntouched();
    }

    /// @notice The propose-time mirror refuses the same leg in the settlement batch.
    function test_proposeRefusesBatchPullInSettlementLeg() public {
        _deployStack(new PaxosBatchMock());
        _proposeExpectingRefusal(
            _one(address(usdc), abi.encodeCall(usdc.approve, (attacker, 0))),
            _one(address(usdc), _batchPull(lp1, attacker, LP_WALLET))
        );
        _assertLpUntouched();
    }

    /// @notice The predicate admits exactly transfer, transferFrom from the vault and the five
    ///         approve-family selectors, and refuses reads and every other selector.
    function test_predicateAdmitsOnlyTransfersAndTheApproveFamily() public {
        AssetCallRulesHarness h = new AssetCallRulesHarness();
        address v = address(vault);
        assertEq(h.spenderOf(v, abi.encodeWithSignature("transfer(address,uint256)", attacker, 1)), address(0));
        assertEq(
            h.spenderOf(v, abi.encodeWithSignature("transferFrom(address,address,uint256)", v, attacker, 1)), address(0)
        );
        string[5] memory grants = [
            "approve(address,uint256)",
            "increaseAllowance(address,uint256)",
            "increaseApproval(address,uint256)",
            "decreaseAllowance(address,uint256)",
            "decreaseApproval(address,uint256)"
        ];
        for (uint256 i = 0; i < grants.length; i++) {
            assertEq(h.spenderOf(v, abi.encodeWithSignature(grants[i], attacker, 1)), attacker, grants[i]);
        }

        bytes[] memory refused = new bytes[](6);
        refused[0] = abi.encodeWithSignature("balanceOf(address)", v);
        refused[1] = abi.encodeWithSignature("allowance(address,address)", lp1, v);
        refused[2] = _batchPull(lp1, attacker, 1);
        refused[3] = abi.encodeWithSignature("transferAndCall(address,uint256)", attacker, 1);
        refused[4] = abi.encodeWithSignature("authorizeOperator(address)", attacker);
        refused[5] = abi.encodeWithSignature("grantSpend(address,uint256)", attacker, 1);
        for (uint256 i = 0; i < refused.length; i++) {
            vm.expectRevert(
                abi.encodeWithSelector(ISyndicateVault.UnrecognizedAssetSelector.selector, bytes4(refused[i]))
            );
            h.spenderOf(v, refused[i]);
        }
    }

    /// @notice Control: the single-transfer shape of the same theft is refused by the guard and at propose.
    function test_control_plainTransferFromOfLpIsRefused() public {
        _deployStack(new PaxosBatchMock());
        bytes memory data = abi.encodeCall(usdc.transferFrom, (lp1, attacker, LP_WALLET));
        _expectTransferFromRefused(data, lp1);

        CustomStrategy venue = _custom();
        BatchExecutorLib.Call[] memory execCalls = _one(address(usdc), data);
        BatchExecutorLib.Call[] memory settleCalls =
            _one(address(venue), abi.encodeCall(CustomStrategy.frobnicate, (address(usdc), 0)));
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.TransferFromNotVault.selector, lp1));
        governor.propose(
            address(vault),
            address(venue),
            "ipfs://structural",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: 1, maxDrawdownBps: 10_000}),
            execCalls,
            new uint256[](1),
            settleCalls,
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(usdc.balanceOf(lp1), LP_WALLET, "the LP is untouched");
    }

    /// @notice Control: an LP with no standing allowance loses nothing either way.
    function test_control_noAllowanceNoLoss() public {
        _deployStack(new PaxosBatchMock());
        vm.prank(lp1);
        usdc.approve(address(vault), 0);
        BatchExecutorLib.Call[] memory calls = _one(address(usdc), _batchPull(lp1, attacker, LP_WALLET));
        vm.prank(address(governor));
        vm.expectRevert();
        vault.executeGovernorBatch(calls, new uint256[](1), 0);
        assertEq(usdc.balanceOf(lp1), LP_WALLET, "the LP is untouched");
    }
}
