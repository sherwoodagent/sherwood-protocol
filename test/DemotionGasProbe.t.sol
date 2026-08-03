// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SlashGasCeilingTest} from "./SlashGasCeiling.t.sol";
import {TokenCourt} from "../src/TokenCourt.sol";
import {IChallengeGame} from "../src/interfaces/IChallengeGame.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Probe: binary-search the MINIMUM `finalize` gas that lets a
///         full-cap conviction land (ok == true, no InsufficientSlashGas
///         revert), then check whether the demotion actually succeeded at
///         that minimum, or silently failed (AdapterDemotionFailed).
///
/// @dev    Issue #51 / openspec settle-demotion-gas-floor, empirical form.
///         `SlashGasCeilingTest`'s other tests prove the floor fits inside
///         32M and that a full-cap conviction executes; this one closes the
///         remaining question directly rather than by arithmetic — at the
///         SMALLEST gas stipend for which `finalize` succeeds at all
///         (found by search, not assumed), does the demotion land or
///         silently miss? With `DEMOTION_GAS` in the floor, it lands: there
///         is no gas value where the conviction settles but the adapter
///         keeps its certification.
contract DemotionGasProbeTest is SlashGasCeilingTest {
    function test_probe_minimalGasDemotionOutcome() public {
        _deployStack(100);
        uint256 pid = _proposeApproveExecute();
        (uint256 cid, uint256 caseId) = _fileDisputeRefer(pid);
        _convictAndCloseTheWindow(caseId);

        uint256 snapshotId = vm.snapshotState();

        uint256 lo = 0;
        uint256 hi = MAX_TX_GAS - INTRINSIC_TX_GAS;

        (bool okHi,) = address(court).call{gas: hi}(abi.encodeCall(TokenCourt.finalize, (caseId)));
        require(okHi, "sanity: full budget must succeed");
        vm.revertToState(snapshotId);

        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 innerSnap = vm.snapshotState();
            (bool ok,) = address(court).call{gas: mid}(abi.encodeCall(TokenCourt.finalize, (caseId)));
            vm.revertToState(innerSnap);
            if (ok) {
                hi = mid;
            } else {
                lo = mid;
            }
        }

        emit log_named_uint("minimal succeeding finalize gas stipend", hi);

        vm.recordLogs();
        (bool okFinal,) = address(court).call{gas: hi}(abi.encodeCall(TokenCourt.finalize, (caseId)));
        assertTrue(okFinal, "must still succeed at the minimal stipend");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool sawFailed;
        bool sawDemoted;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("AdapterDemotionFailed(uint256,address,bytes4)")) sawFailed = true;
            if (logs[i].topics[0] == keccak256("TierDemoted(address,bytes4)")) sawDemoted = true;
        }

        emit log_named_uint("sawFailed", sawFailed ? 1 : 0);
        emit log_named_uint("sawDemoted", sawDemoted ? 1 : 0);

        assertEq(
            uint256(game.challengeOf(cid).status),
            uint256(IChallengeGame.Status.Settled),
            "conviction must still have landed"
        );
        assertTrue(sawDemoted, "demotion should have succeeded, not silently failed, at the minimal gas");
        assertFalse(sawFailed, "AdapterDemotionFailed must not fire at the minimal succeeding gas");
    }
}
