// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IZkLighter} from "../../src/lighter/IZkLighter.sol";

/// @notice THE DERIVATION behind `LighterForkBench.PENDING_BALANCES_BASE_SLOT`.
///         Which storage slot does ZkLighter read for `getPendingBalance(owner,
///         3)`? Run WITHOUT --broadcast:
///
///           forge script script/fork/LighterSlotProbe.s.sol:LighterSlotProbe \
///             --rpc-url robinhood_fork
///
///         `vm.record` RATHER THAN `debug_traceCall`, which this vnet answers
///         `-32002 not supported`. Forge runs the staticcall in its own EVM
///         against the forked state, so the SLOAD keys are the venue's real
///         ones. Two owners are probed on purpose: a REGISTERED account walks
///         `addressToAccountIndex -> pendingAssetBalances` and its third read is
///         the slot wanted; an unregistered one short-circuits and never reaches
///         it, which is what tells the two reads apart.
///
///         Solving `keccak(acct || keccak(asset || B)) == observed` over
///         `B in [0, 600)` yields B = 498, offset 0 — the figure
///         `LighterForkBench.maturitySlot` now recomputes per clone.
contract LighterSlotProbe is Script {
    IZkLighter constant ZKL = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);

    function run() external {
        address a = 0x25AF128f0Ca36941cC6aa833025eE72B38Dd854E;
        address b = 0x000000000000000000000000000000000000dEaD;
        _probe(a);
        _probe(b);
    }

    function _probe(address owner) internal {
        vm.record();
        uint128 v = ZKL.getPendingBalance(owner, 3);
        (bytes32[] memory reads,) = vm.accesses(address(ZKL));
        console.log("owner", owner, "pending", uint256(v));
        for (uint256 i; i < reads.length; i++) {
            console.logBytes32(reads[i]);
        }
    }
}
