// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TierRegistry} from "src/TierRegistry.sol";

/// @notice The authorized-demoter role and the counterparty axis: the one address
///         allowlist the registry keeps, read only by strategy templates.
contract TierRegistryCounterpartyAllowlistTest is Test {
    TierRegistry internal reg;
    address internal owner = makeAddr("owner");
    address internal target;

    function setUp() public {
        reg = new TierRegistry(owner);
        // separate deployed contract as certification target (etch-safe: never etch the registry under test)
        target = address(new TierRegistry(owner));
    }

    /// @dev Shared fixture helper (design.md / tasks.md 2.1): reaches the same
    ///      end state as the old instant `certify` via the new two-step flow
    ///      — propose as owner, warp past the pinned `readyAt`, execute. Uses
    ///      `vm.getBlockTimestamp()` (never a cached `block.timestamp` local)
    ///      because this repo's optimizer CSEs `block.timestamp` across
    ///      `vm.warp`. Pranks the final `certify` call as `submitter_` when
    ///      one is set (audit finding #3: execution is submitter-gated once a
    ///      bond is pinned) — every caller of this helper only ever pins a
    ///      bond when `submitter_ != address(0)`, so this exactly mirrors
    ///      each test's intent without changing any assertions.
    function _certifyNow(address target_, bytes4 selector_, uint8 tier_, uint16 bound_, address submitter_) internal {
        vm.prank(owner);
        reg.proposeCertification(target_, selector_, tier_, bound_, submitter_, target_.codehash);
        vm.warp(vm.getBlockTimestamp() + reg.certifyDelay());
        if (submitter_ != address(0)) {
            vm.prank(submitter_);
        }
        reg.certify(target_, selector_);
    }

    function test_setAuthorizedDemoter_onlyOwner() public {
        vm.expectRevert();
        reg.setAuthorizedDemoter(makeAddr("rogue"));
    }

    function test_demoteByChallenge_onlyDemoter() public {
        _certifyNow(target, bytes4(0x77777777), 1, 500, address(0));
        vm.expectRevert(TierRegistry.NotAuthorizedDemoter.selector);
        reg.demoteByChallenge(target, bytes4(0x77777777));
    }

    /// @notice A passed challenge demotes the offending adapter back to the
    ///         tier-2 default without needing registry ownership (§3.4).
    function test_demoteByChallenge_demotes() public {
        address demoter = makeAddr("demoter");
        _certifyNow(target, bytes4(0x77777777), 1, 500, address(0));
        vm.prank(owner);
        reg.setAuthorizedDemoter(demoter);

        (uint8 tierBefore,) = reg.tierOf(target, bytes4(0x77777777));
        assertEq(tierBefore, 1);

        vm.prank(demoter);
        reg.demoteByChallenge(target, bytes4(0x77777777));

        (uint8 tierAfter, uint16 boundAfter) = reg.tierOf(target, bytes4(0x77777777));
        assertEq(tierAfter, 2, "back to the arbitrary-calldata default");
        assertEq(boundAfter, 10_000);
    }

    /// @notice The demoter can only REVOKE. It must not be able to certify — that
    ///         is why this is a role rather than registry ownership.
    function test_demoter_cannotProposeCertification() public {
        address demoter = makeAddr("demoter");
        vm.prank(owner);
        reg.setAuthorizedDemoter(demoter);
        vm.prank(demoter);
        vm.expectRevert();
        reg.proposeCertification(target, bytes4(0x88888888), 1, 500, address(0), target.codehash);
    }

    // ── Issue #77: demotion auto-clears the adapter allowlist ──

    // ── The counterparty axis ──

    /// @dev A grant is against the code the owner was looking at. Bytecode swapped
    ///      at the address invalidates it without anyone having to notice.
    function test_counterpartyStandingDiesOnBytecodeSwap() public {
        address cp = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setCounterpartyAllowed(cp, true);
        assertTrue(reg.isCounterpartyAllowed(cp));

        vm.etch(cp, hex"6001600101");
        assertFalse(reg.isCounterpartyAllowed(cp), "a swapped codehash must invalidate the grant");
    }

    /// @dev A grant against a codeless address snapshots no-code, so the binding
    ///      closes the instant code appears (the counterfactual-address adversary).
    function test_counterpartyGrantAgainstCodelessAddressClosesWhenCodeAppears() public {
        address cp = makeAddr("counterfactual");
        vm.prank(owner);
        reg.setCounterpartyAllowed(cp, true);
        assertTrue(reg.isCounterpartyAllowed(cp), "granted against no code");

        vm.etch(cp, hex"6001600101");
        assertFalse(reg.isCounterpartyAllowed(cp), "code appearing at the address must close the grant");
    }

    function test_setCounterpartyAllowed_onlyOwner() public {
        vm.expectRevert();
        reg.setCounterpartyAllowed(makeAddr("rogue"), true);
    }

    /// @dev Demotion clears the counterparty entry: a convicted venue is not bindable.
    function test_demotionClearsCounterpartyStanding() public {
        bytes4 sel = bytes4(0x12345678);
        _certifyNow(target, sel, 1, 500, address(0));
        vm.prank(owner);
        reg.setCounterpartyAllowed(target, true);
        assertTrue(reg.isCounterpartyAllowed(target), "precondition: counterparty standing");

        address demoter = makeAddr("demoter");
        vm.prank(owner);
        reg.setAuthorizedDemoter(demoter);
        vm.prank(demoter);
        reg.demoteByChallenge(target, sel);

        assertFalse(reg.isCounterpartyAllowed(target), "counterparty standing cleared");
    }
}
