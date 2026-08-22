// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with VaultWithdrawalQueue
abstract contract VaultWithdrawalQueueHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    /// @dev Request 0 is a sentinel slot pushed in the constructor, so valid
    ///      ids run `[1, nextRequestId)`. `claim` and `cancel` are the two
    ///      halves of I-3's conservation: every escrowed share leaves through
    ///      exactly one of them.
    function vaultWithdrawalQueue_cancel_clamped(uint256 requestId) public {
        uint256 next = queue.nextRequestId();
        if (next <= 1) return;
        requestId = clampBetween(requestId, 1, next - 1);
        vaultWithdrawalQueue_cancel(requestId);
    }

    function vaultWithdrawalQueue_claim_clamped(uint256 requestId) public {
        uint256 next = queue.nextRequestId();
        if (next <= 1) return;
        requestId = clampBetween(requestId, 1, next - 1);
        vaultWithdrawalQueue_claim(requestId);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function vaultWithdrawalQueue_cancel(uint256 requestId) public asActor {
        queue.cancel(requestId);
    }

    function vaultWithdrawalQueue_claim(uint256 requestId) public asActor {
        queue.claim(requestId);
    }
}
