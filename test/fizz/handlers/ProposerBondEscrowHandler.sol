// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with ProposerBondEscrow
///
/// @dev Both entry points are role-gated and normally driven only by the
///      governor (`releaseBond`) and the ledger's coverage freezer, i.e. the
///      challenge game (`forfeitBond`). They are exposed here because I-24 —
///      "a bond has exactly two exits and can take only one" — cannot be
///      pressured from outside: the fuzzer has to be able to attempt both
///      exits against the same bond key. The dispatcher pranks the authorised
///      caller so the attempts reach the real guards instead of dying on
///      `NotAuthorizedGovernor` / `NotAuthorizedConvictor`.
abstract contract ProposerBondEscrowHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function proposerBondEscrow_secondary(uint8 selector, uint256 arg0, uint256 arg1, address arg2) public {
        uint256 count = governor.proposalCount();
        if (count == 0) return;
        uint256 proposalId = clampBetween(arg0, 1, count);

        selector = uint8(selector % 2);
        if (selector == 0) {
            _proposerBondEscrow_releaseBond(proposalId);
        } else {
            // `feeBps` is capped at MAX_PROSECUTOR_FEE_BPS (2000) on-chain;
            // clamping here keeps the call inside the reachable space.
            _proposerBondEscrow_forfeitBond(address(governor), proposalId, toActor(arg2), clampBetween(arg1, 0, 2_000));
        }
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    /// @dev Bond keys are `(governor, proposalId)`, so this must be pranked as
    ///      the governor to address a real bond.
    function _proposerBondEscrow_releaseBond(uint256 proposalId) internal {
        vm.prank(address(governor));
        bondEscrow.releaseBond(proposalId);
    }

    /// @dev Only the ledger's live `coverageFreezer` may convict (X-5); that
    ///      is the challenge game in this harness.
    function _proposerBondEscrow_forfeitBond(address governor_, uint256 proposalId, address feeTo, uint256 feeBps)
        internal
    {
        vm.prank(address(game));
        bondEscrow.forfeitBond(governor_, proposalId, feeTo, feeBps);
    }
}
