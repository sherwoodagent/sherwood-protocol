// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title BatchExecutorLib
 * @notice Stateless batch execution logic. Called via delegatecall from vaults.
 *
 *   When a vault delegatecalls into this contract:
 *     - `address(this)` = vault address (positions live on the vault)
 *     - `msg.sender` = original caller (the agent wallet)
 *     - All calls to DeFi protocols happen FROM the vault
 *
 *   This contract has NO state and NO access control. The calling vault must
 *   enforce allowlists and caps BEFORE delegatecalling here.
 *
 *   Deploy once, share across all syndicate vaults.
 */
contract BatchExecutorLib {
    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    struct CallResult {
        bool success;
        bytes returnData;
        /// @notice Gross outflow of `asset` measured around this call
        ///         (balanceBefore - balanceAfter, floored at 0). `simulateBatch`
        ///         always measures this (never enforces); it is never gated by
        ///         the `caps` argument.
        uint256 outflow;
    }

    /// @notice `executeBatch`/`simulateBatch` received a non-empty `caps`
    ///         array whose length differs from `calls`. Empty `caps` is the
    ///         deliberate unmetered escape valve (see the metered
    ///         `executeBatch` overload); any other length mismatch is a
    ///         caller bug and fails fast, before any call executes.
    error CapsLengthMismatch();

    /// @notice A call's gross outflow of `asset` exceeded its declared cap.
    ///         Reverts the WHOLE batch — fail-closed on money, matching the
    ///         vault's `MaxNetOutflowExceeded` idiom.
    /// @param index Index of the offending call.
    /// @param outflow Measured gross outflow (balanceBefore - balanceAfter).
    /// @param cap The declared cap that was exceeded.
    error CallCapExceeded(uint256 index, uint256 outflow, uint256 cap);

    /**
     * @notice Execute a batch of calls atomically, metering each call's gross
     *         outflow of `asset` against its declared cap (issue #43).
     * @dev Called via delegatecall from vault, so `address(this)` == vault and
     *      the balance read below is the vault's own balance of `asset`. The
     *      SAME asset the vault's own batch-level meter uses — passed in by
     *      the caller, never re-derived here.
     *
     *      `caps.length == 0` skips per-call metering entirely (the emergency-
     *      path escape valve: owner-supplied rescue calls have no propose-time
     *      declaration to enforce). A non-empty `caps` whose length differs
     *      from `calls` reverts `CapsLengthMismatch` before any call runs.
     *
     *      When metered, one `balanceOf` staticcall runs before the loop and
     *      one after EACH call; the *after* of call i is reused as the
     *      *before* of call i+1 (safe — no code runs between iterations).
     *      `outflow_i = max(0, before_i - after_i)`, compared only against
     *      `caps[i]` — GROSS per call, never netted across calls (a refund in
     *      a later call does not refill an earlier call's budget). A breach
     *      reverts the entire batch with `CallCapExceeded`.
     * @param calls Array of (target, data, value) to execute in order
     * @param asset The vault's underlying ERC20 asset (balance-metered)
     * @param caps Per-call gross-outflow cap, one per `calls` entry, or empty
     *             to skip per-call metering
     */
    function executeBatch(Call[] calldata calls, address asset, uint256[] calldata caps) external {
        bool metered = caps.length != 0;
        if (metered && caps.length != calls.length) revert CapsLengthMismatch();
        uint256 beforeBal = metered ? IERC20Balance(asset).balanceOf(address(this)) : 0;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            if (!success) {
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            if (metered) {
                uint256 afterBal = IERC20Balance(asset).balanceOf(address(this));
                uint256 outflow = beforeBal > afterBal ? beforeBal - afterBal : 0;
                if (outflow > caps[i]) revert CallCapExceeded(i, outflow, caps[i]);
                beforeBal = afterBal;
            }
        }
    }

    /**
     * @notice Simulate a batch, reporting per-call gross outflow of `asset`
     *         alongside success/returnData — never enforces (eth_call
     *         dry-run only), matching `executeBatch`'s metering measurement
     *         exactly so proposers can size caps from observed behavior.
     * @param calls Array of calls to simulate
     * @param asset The vault's underlying ERC20 asset (balance-measured)
     * @param caps Unused for enforcement; accepted only so a caller passes
     *             the same shape it will later execute with. A length
     *             mismatch (non-empty caps) still reverts `CapsLengthMismatch`
     *             so a mis-sized dry-run cannot report against the wrong call
     *             count.
     * @return results Array of (success, returnData, outflow) per call
     */
    function simulateBatch(Call[] calldata calls, address asset, uint256[] calldata caps)
        external
        returns (CallResult[] memory results)
    {
        if (caps.length != 0 && caps.length != calls.length) revert CapsLengthMismatch();
        results = new CallResult[](calls.length);
        uint256 beforeBal = IERC20Balance(asset).balanceOf(address(this));
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory returnData) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            uint256 afterBal = IERC20Balance(asset).balanceOf(address(this));
            uint256 outflow = beforeBal > afterBal ? beforeBal - afterBal : 0;
            results[i] = CallResult({success: success, returnData: returnData, outflow: outflow});
            beforeBal = afterBal;
        }
    }
}

/// @dev Minimal balanceOf-only interface so this file has no external import
///      dependency — the lib stays a single self-contained file, matching its
///      "no state, no access control" design.
interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}
