// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TierRegistry} from "src/TierRegistry.sol";

/// @notice Split out of TierRegistry.t.sol (issue #174): authorized-demoter
///         role and adapter-allowlist auto-clear/self-heal behavior — no test
///         behavior change, same fixture pattern as the sibling
///         TierRegistryCertificationTimelock.t.sol split (own setUp/helpers,
///         no shared abstract base — Solidity inlines inherited code into
///         every concrete contract's deployed bytecode regardless, so a base
///         contract wouldn't shrink the compiled unit that hit the ICE).
contract TierRegistryAdapterAllowlistTest is Test {
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

    /// @notice Owner `demote` clears the target's allowlist entry atomically,
    ///         reusing the existing `AdapterAllowedSet` event.
    function test_demote_clearsAdapterAllowlist() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        vm.prank(owner);
        reg.setAdapterAllowed(target, true);
        assertTrue(reg.isAdapterAllowed(target));

        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice `demoteByChallenge` clears the allowlist identically to owner
    ///         `demote` — both converge on `_demote`.
    function test_demoteByChallenge_clearsAdapterAllowlist() public {
        address demoter = makeAddr("demoter");
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        vm.startPrank(owner);
        reg.setAdapterAllowed(target, true);
        reg.setAuthorizedDemoter(demoter);
        vm.stopPrank();
        assertTrue(reg.isAdapterAllowed(target));

        // hoist: any argument-position call would consume the one-shot prank
        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(demoter);
        reg.demoteByChallenge(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice Permissionless `poke` (on codehash drift) clears the allowlist
    ///         too — the third of the three `_demote`-converging paths.
    function test_poke_clearsAdapterAllowlist() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        vm.prank(owner);
        reg.setAdapterAllowed(target, true);
        vm.etch(target, hex"6001600101");
        // issue #137: isAdapterAllowed self-heals lazily on read, exactly like
        // tierOf, so it already reports false here even though `poke` has not
        // run yet and `_adapterAllowed[target]` storage is still `true`. This
        // assertion used to be `assertTrue` and was pinning the stale-`true`
        // window that let a metamorphic redeploy keep standing funds-path
        // rights until someone happened to poke.
        assertFalse(reg.isAdapterAllowed(target));

        vm.expectEmit(true, false, false, true);
        emit TierRegistry.AdapterAllowedSet(target, false);
        vm.prank(makeAddr("rando"));
        reg.poke(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target));
    }

    /// @notice Demoting a target that was never allowlisted must NOT emit a
    ///         phantom `AdapterAllowedSet` — the guarded emission keeps the
    ///         channel truthful and existing `vm.expectEmit` assertions in
    ///         this file (which never allowlist before demoting) unaffected.
    function test_demote_neverAllowlisted_noAllowedSetEvent() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        assertFalse(reg.isAdapterAllowed(target));

        bytes32 allowedSetSig = keccak256("AdapterAllowedSet(address,bool)");
        vm.recordLogs();
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != allowedSetSig, "no phantom AdapterAllowedSet");
        }
    }

    /// @notice DELIBERATE over-breadth (design.md Decision 3): certification
    ///         is keyed (target, selector), the allowlist by bare address, so
    ///         demoting ONE selector de-allowlists the WHOLE adapter even
    ///         though its other selectors remain certified. This pins the
    ///         over-broad clear as specified behavior, not a bug — do not
    ///         "fix" it back to per-selector.
    function test_demoteOneSelector_clearsWholeAdapter_intended() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        _certifyNow(target, bytes4(0x87654321), 0, 200, address(0));
        vm.prank(owner);
        reg.setAdapterAllowed(target, true);

        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));

        assertFalse(reg.isAdapterAllowed(target), "whole adapter de-allowlisted by one selector's demotion");
        (uint8 survivingTier, uint16 survivingBound) = reg.tierOf(target, bytes4(0x87654321));
        assertEq(survivingTier, 0, "other selector remains certified");
        assertEq(survivingBound, 200);
    }

    /// @notice Re-certifying a demoted (target, selector) must NOT restore
    ///         the allowlist — `certify` never sets or restores
    ///         `_adapterAllowed`; the coupling is one-way and fail-closed.
    function test_recertify_doesNotRestoreAllowlist() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        vm.prank(owner);
        reg.setAdapterAllowed(target, true);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678)); // auto-clears the allowlist
        assertFalse(reg.isAdapterAllowed(target));

        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));

        assertFalse(reg.isAdapterAllowed(target), "re-certification must not re-grant the allowlist");
    }

    /// @notice The recovery path: after a demotion-triggered clear, the owner
    ///         can always explicitly re-allowlist the adapter.
    function test_ownerReallowsAfterClear() public {
        _certifyNow(target, bytes4(0x12345678), 1, 500, address(0));
        vm.prank(owner);
        reg.setAdapterAllowed(target, true);
        vm.prank(owner);
        reg.demote(target, bytes4(0x12345678));
        assertFalse(reg.isAdapterAllowed(target));

        vm.prank(owner);
        reg.setAdapterAllowed(target, true);

        assertTrue(reg.isAdapterAllowed(target));
    }

    /// @notice issue #137, design.md D1/D2: a metamorphic same-address
    ///         bytecode swap on an allowlisted adapter self-heals to `false`
    ///         on the very next read — with NO demotion call of any kind
    ///         (no `poke`, no `demote`, no `demoteByChallenge`). The owner can
    ///         then re-attest the new code with a fresh grant, which refreshes
    ///         the snapshot and restores `true`.
    function test_metamorphicSwap_selfHealsWithoutPoke() public {
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(adapter), "self-heals without any demotion call");

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true); // re-attestation, not a demotion recovery
        assertTrue(reg.isAdapterAllowed(adapter), "re-grant refreshes the snapshot to the new code");
    }

    /// @notice design.md D2: for an allowlisted adapter that was NEVER
    ///         certified, `poke` is permanently unreachable (`NotCertified`),
    ///         so the lazy read-side self-heal is the ONLY automatic
    ///         protection — proving the fix cannot be "just call poke more".
    ///         Owner `setAdapterAllowed(adapter, false)` remains the manual
    ///         storage-cleanup path for this case.
    function test_uncertifiedAdapter_readSideGateIsOnlyProtection() public {
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(adapter), "read-side gate closes the funds path");

        vm.expectRevert(TierRegistry.NotCertified.selector);
        reg.poke(adapter, bytes4(0x12345678));

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, false);
        assertFalse(reg.isAdapterAllowed(adapter));
    }

    /// @notice design.md D3: normalization treats a non-existent account
    ///         (`bytes32(0)`) and an existing-but-codeless account
    ///         (`keccak256("")`) as one "no code" value. (a) a codeless
    ///         allowlisted payout address stays allowed after merely
    ///         receiving a native-balance donation — the anti-grief property
    ///         that `test/vault/SelectorGuard.t.sol`'s codeless adapter
    ///         fixture depends on; (b) code later appearing there fails
    ///         closed; (c) a contract whose code disappears (selfdestruct)
    ///         also fails closed.
    function test_zeroCodeNormalization() public {
        address payout = makeAddr("payout");
        vm.prank(owner);
        reg.setAdapterAllowed(payout, true);
        assertTrue(reg.isAdapterAllowed(payout), "codeless address allowlists cleanly");

        vm.deal(payout, 1 wei); // non-existent -> existing-codeless
        assertTrue(reg.isAdapterAllowed(payout), "a 1-wei donation must not grief the funds path closed");

        vm.etch(payout, hex"6001600101");
        assertFalse(reg.isAdapterAllowed(payout), "code appearing at a codeless allowlisted address fails closed");

        // Separate fixture: a contract that had code at grant time and later
        // has none (simulating a post-Dencun-rare but still possible
        // selfdestruct) also fails closed.
        address adapter = address(new TierRegistry(owner));
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true);
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, "");
        assertFalse(reg.isAdapterAllowed(adapter), "code disappearing (selfdestruct) fails closed");
    }

    /// @notice design.md D1: `setAdapterAllowed(adapter, false)` answers
    ///         false regardless of codehash state, and a stale snapshot left
    ///         behind under a cleared flag is inert — the next grant
    ///         overwrites it unconditionally with whatever code is live then.
    function test_revokeThenRegrant_snapshotOverwrittenByNextGrant() public {
        address adapter = address(new TierRegistry(owner));
        vm.startPrank(owner);
        reg.setAdapterAllowed(adapter, true);
        vm.stopPrank();
        assertTrue(reg.isAdapterAllowed(adapter));

        vm.etch(adapter, hex"6001600101"); // stale snapshot no longer matches
        vm.prank(owner);
        reg.setAdapterAllowed(adapter, false);
        assertFalse(reg.isAdapterAllowed(adapter), "revoke answers false regardless of codehash state");

        vm.prank(owner);
        reg.setAdapterAllowed(adapter, true); // re-grant snapshots the NEW code
        assertTrue(reg.isAdapterAllowed(adapter), "next grant overwrites the stale snapshot with current code");
    }
}
