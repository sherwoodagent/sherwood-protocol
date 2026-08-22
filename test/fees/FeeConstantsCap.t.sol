// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FeeConstants} from "../../src/FeeConstants.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";

/// @notice Pins the fee ceilings to their intended values and proves both
///         consumers still read through to `FeeConstants` rather than to a
///         hand-edited literal (the L1 finding `FeeConstants` exists to
///         prevent). Reads the consumers off deployed instances because a
///         `public constant` on a contract is not reachable through the
///         contract type — only a library's is.
contract FeeConstantsCapTest is Test {
    SyndicateVault internal vault;
    SyndicateGovernor internal governor;

    function setUp() public {
        // Constants live in code, not storage, so an uninitialized
        // implementation reads them correctly. No proxy needed.
        vault = new SyndicateVault();
        governor = new SyndicateGovernor(1 days, 1 hours);
    }

    // ── The ceiling itself ──

    function test_performanceFeeCeilingIsThirtyPercent() public pure {
        assertEq(FeeConstants.MAX_PERFORMANCE_FEE_BPS, 3000, "protocol ceiling should be 30%");
    }

    function test_ceilingPropagatesToVaultAgentFeeCap() public view {
        assertEq(
            vault.MAX_AGENT_FEE_BPS(),
            FeeConstants.MAX_PERFORMANCE_FEE_BPS,
            "vault agent-fee cap must read through to FeeConstants"
        );
    }

    function test_ceilingPropagatesToGovernorPerformanceFeeCap() public view {
        assertEq(
            governor.MAX_PERFORMANCE_FEE_CAP(),
            FeeConstants.MAX_PERFORMANCE_FEE_BPS,
            "governor performance-fee cap must read through to FeeConstants"
        );
    }

    /// @dev The two consumers are capped at the same ceiling on purpose: a
    ///      vault must not advertise an `agentFeeBps` the governor could never
    ///      realize (PR #384 review C4).
    function test_bothConsumersAgreeOnTheCeiling() public view {
        assertEq(vault.MAX_AGENT_FEE_BPS(), governor.MAX_PERFORMANCE_FEE_CAP(), "consumers must not diverge");
    }

    /// @dev The headline rate of the two-number model is 20%. If the ceiling
    ///      ever falls back to or below it, every vault charging the headline
    ///      would be silently clamped at settlement.
    function test_ceilingLeavesRoomForTheTwentyPercentHeadline() public pure {
        assertGe(FeeConstants.MAX_PERFORMANCE_FEE_BPS, 2000, "ceiling must reach the 20% headline");
    }

    // ── The per-vault default ──

    function test_defaultPerVaultCeilingIsTheHeadline() public pure {
        assertEq(FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS, 2000, "factory default should be the 20% headline");
    }

    /// @dev Fail-closed: the settle-time clamp resolves an over-ceiling rate
    ///      silently, so a new vault must start below the protocol ceiling.
    ///      Equality here would let an owner charge 30% on day one unopposed.
    function test_defaultPerVaultCeilingSitsStrictlyBelowTheProtocolCeiling() public pure {
        assertLt(
            FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS,
            FeeConstants.MAX_PERFORMANCE_FEE_BPS,
            "default must not equal the protocol ceiling"
        );
    }

    // ── The default agent rate ──

    function test_defaultAgentFeeIsTheHeadline() public pure {
        assertEq(FeeConstants.DEFAULT_AGENT_FEE_BPS, 2000, "a vault that never sets a rate charges the 20% headline");
    }

    /// @dev The default is deliberately AT the per-vault ceiling, never above
    ///      it: an unset vault charges the headline exactly, and only an
    ///      explicit governor param change can go past it.
    function test_defaultAgentFeeDoesNotExceedThePerVaultCeiling() public pure {
        assertLe(
            FeeConstants.DEFAULT_AGENT_FEE_BPS,
            FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS,
            "default rate must not start above the default ceiling"
        );
    }

    function test_aVaultThatNeverSetsARateChargesTheDefault() public view {
        assertEq(vault.agentFeeBps(), FeeConstants.DEFAULT_AGENT_FEE_BPS, "unset vaults must charge the default rate");
    }

    // ── The shared denominator ──

    function test_bpsDenominatorIsFullBasisPoints() public pure {
        assertEq(FeeConstants.BPS_DENOMINATOR, 10_000, "100% in basis points");
    }

    /// @dev Every rate in this library is expressed against that denominator,
    ///      so none of them may exceed it.
    function test_everyRateFitsWithinTheDenominator() public pure {
        assertLe(FeeConstants.MAX_PERFORMANCE_FEE_BPS, FeeConstants.BPS_DENOMINATOR);
        assertLe(FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS, FeeConstants.BPS_DENOMINATOR);
        assertLe(FeeConstants.DEFAULT_AGENT_FEE_BPS, FeeConstants.BPS_DENOMINATOR);
    }
}
