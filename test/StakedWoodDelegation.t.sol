// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {StakedWoodDelegation} from "../src/StakedWoodDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";

/// @notice Share-based DPoS delegation tests for StakedWood (sWOOD).
///         Covers Task 4.1 — `delegateStake` mints ERC-4626-style shares.
contract StakedWoodDelegationTest is Test {
    StakedWood swood;
    ERC20Mock wood;
    MockGovernorMinimal gov;

    address owner = address(0xA11CE);
    address factory = address(0xFAC10);
    address alice = address(0xA11CE5);
    address bob = address(0xB0B); // active guardian / delegate
    address carol = address(0xCA401);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        gov = new MockGovernorMinimal();
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        // Bob is an active guardian so he can be a delegate.
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
    }

    // ── Helpers ──

    function _fundAndApprove(address who, uint256 amount) internal {
        wood.mint(who, amount);
        vm.prank(who);
        wood.approve(address(swood), type(uint256).max);
    }

    function _setup_aliceDelegates300ToBob() internal {
        _fundAndApprove(alice, 300e18);
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
    }

    // ── Tests ──

    function test_delegateStake_firstDelegationMints1to1() public {
        _fundAndApprove(alice, 300e18);
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        assertEq(swood.poolTokens(bob), 300e18);
        assertEq(swood.poolShares(bob), 300e18);
        assertEq(swood.delegationOf(alice, bob), 300e18); // token-equivalent
    }

    function test_delegateStake_secondDelegatorMintsAtRate() public {
        // alice 300 -> 300 shares; carol 100 at 1:1 rate -> 100 shares
        _setup_aliceDelegates300ToBob();
        _fundAndApprove(carol, 100e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);
        assertEq(swood.poolShares(bob), 400e18);
        assertEq(swood.delegationOf(carol, bob), 100e18);
    }

    function test_delegateStake_revertsWhenDisabled() public {
        _fundAndApprove(alice, 300e18);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.DelegationDisabled.selector);
        swood.delegateStake(bob, 300e18);
    }

    function test_delegateStake_revertsOnSelfDelegate() public {
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        _fundAndApprove(bob, 100e18);
        vm.prank(bob);
        vm.expectRevert(StakedWoodDelegation.CannotSelfDelegate.selector);
        swood.delegateStake(bob, 100e18);
    }

    function test_delegateStake_revertsOnInactiveDelegate() public {
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        _fundAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.InactiveDelegate.selector);
        swood.delegateStake(carol, 100e18); // carol never staked
    }

    function test_delegateStake_revertsOnZeroAmount() public {
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        _fundAndApprove(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.ZeroAmount.selector);
        swood.delegateStake(bob, 0);
    }

    function test_delegateStake_tracksTotalDelegatedStakeAndInbound() public {
        _setup_aliceDelegates300ToBob();
        assertEq(swood.totalDelegatedStake(), 300e18);
        assertEq(swood.delegatedInbound(bob), 300e18);
    }

    // ── Unbonding-escrow flow (I-1) ──

    /// @notice `requestUnstakeDelegation` stamps the timestamp AND moves the
    ///         delegator's entire live delegation into the unbonding pool.
    function test_requestUnstakeDelegation_stampsAndMovesToUnbondingPool() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        uint64 expectedAt = uint64(vm.getBlockTimestamp());
        swood.requestUnstakeDelegation(bob);

        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), expectedAt, "request timestamp stamped");
        // Live pool drained.
        assertEq(swood.poolTokens(bob), 0, "live poolTokens drained");
        assertEq(swood.poolShares(bob), 0, "live poolShares drained");
        assertEq(swood.delegationOf(alice, bob), 0, "live delegation zeroed");
        assertEq(swood.totalDelegatedStake(), 0, "totalDelegatedStake drops live amount");
        // Unbonding pool filled 1:1.
        assertEq(swood.unbondingPoolTokens(bob), 300e18, "unbonding pool tokens");
        assertEq(swood.unbondingPoolShares(bob), 300e18, "unbonding pool shares 1:1");
    }

    /// @notice `requestUnstakeDelegation` emits `UnbondingRequested` with the
    ///         redeemed amount and the stamped cooldown-start timestamp.
    function test_requestUnstakeDelegation_emitsUnbondingRequested() public {
        _setup_aliceDelegates300ToBob();
        uint64 expectedAt = uint64(vm.getBlockTimestamp());

        vm.expectEmit(true, true, false, true, address(swood));
        emit StakedWoodDelegation.UnbondingRequested(alice, bob, 300e18, expectedAt);
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
    }

    /// @notice A fresh `delegateStake` after a `requestUnstakeDelegation` is an
    ///         independent LIVE delegation — it does NOT clear the unbonding
    ///         entry (the unbonding shares are separate state).
    function test_delegateStake_doesNotClearUnbondingEntry() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertGt(swood.unstakeDelegationRequestedAt(alice, bob), 0, "unbonding entry pending");

        // Re-delegating builds a fresh live position; the unbonding entry stays.
        _fundAndApprove(alice, 50e18);
        vm.prank(alice);
        swood.delegateStake(bob, 50e18);

        assertGt(swood.unstakeDelegationRequestedAt(alice, bob), 0, "unbonding entry NOT cleared");
        assertEq(swood.delegationOf(alice, bob), 50e18, "fresh live delegation");
        assertEq(swood.unbondingPoolTokens(bob), 300e18, "unbonding pool intact");
    }

    function test_requestUnstakeDelegation_revertsNoActiveStake() public {
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.NoActiveStake.selector);
        swood.requestUnstakeDelegation(bob);
    }

    /// @notice After `requestUnstakeDelegation` the delegator has 0 LIVE shares
    ///         (their stake moved to the unbonding pool), so an immediate
    ///         repeat reverts `NoActiveStake`. The one-entry-per-pair guard
    ///         (`UnstakeAlreadyRequested`) is exercised separately in
    ///         `test_requestUnstakeDelegation_secondRequestWithEntryReverts`,
    ///         where a fresh live re-delegation supplies the live shares.
    function test_requestUnstakeDelegation_revertsIfNoLiveSharesAfterRequest() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.NoActiveStake.selector);
        swood.requestUnstakeDelegation(bob);
    }

    function test_cancelUnstakeDelegation_revertsIfNotRequested() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeNotRequested.selector);
        swood.cancelUnstakeDelegation(bob);
    }

    function test_cancelUnstakeDelegation_clearsRequest() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.prank(alice);
        swood.cancelUnstakeDelegation(bob);
        // Request cleared: a fresh request must succeed (no AlreadyRequested).
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
    }

    function test_claimUnstakeDelegation_revertsIfNotRequested() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeNotRequested.selector);
        swood.claimUnstakeDelegation(bob);
    }

    function test_claimUnstakeDelegation_revertsBeforeCooldown() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.CooldownNotElapsed.selector);
        swood.claimUnstakeDelegation(bob);
    }

    function test_claimUnstakeDelegation_redeemsAfterCooldown() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);

        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);

        assertEq(wood.balanceOf(alice) - balBefore, 300e18, "WOOD returned");
        assertEq(swood.delegationOf(alice, bob), 0, "shares burned");
        assertEq(swood.poolShares(bob), 0, "poolShares decremented");
        assertEq(swood.poolTokens(bob), 0, "poolTokens decremented");
        assertEq(swood.totalDelegatedStake(), 0, "totalDelegatedStake decremented");

        // Request cleared — a re-claim reverts UnstakeNotRequested.
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeNotRequested.selector);
        swood.claimUnstakeDelegation(bob);
    }

    function test_claimUnstakeDelegation_partialPoolRedeemsProRata() public {
        // alice 300 + carol 100 -> pool 400 tokens / 400 shares.
        _setup_aliceDelegates300ToBob();
        _fundAndApprove(carol, 100e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);

        assertEq(swood.poolShares(bob), 100e18, "carol's shares remain");
        assertEq(swood.poolTokens(bob), 100e18, "carol's tokens remain");
        assertEq(swood.totalDelegatedStake(), 100e18);
        assertEq(swood.delegationOf(carol, bob), 100e18, "carol unaffected");
    }

    function test_claimUnstakeDelegation_emitsDelegationClaimed() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.warp(vm.getBlockTimestamp() + 7 days);

        vm.expectEmit(true, true, false, true, address(swood));
        emit StakedWoodDelegation.DelegationClaimed(alice, bob, 300e18);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
    }

    /// @notice `cancelUnstakeDelegation` re-bonds the unbonding entry back into
    ///         the live pool at the (un-slashed) unbonding rate.
    function test_cancelUnstakeDelegation_reBondsIntoLivePool() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.poolTokens(bob), 0, "live drained on request");
        assertEq(swood.unbondingPoolTokens(bob), 300e18, "in unbonding pool");

        vm.prank(alice);
        swood.cancelUnstakeDelegation(bob);

        // Re-bonded into the live pool; unbonding entry cleared.
        assertEq(swood.unbondingPoolTokens(bob), 0, "unbonding pool drained");
        assertEq(swood.unbondingPoolShares(bob), 0, "unbonding shares drained");
        assertEq(swood.poolTokens(bob), 300e18, "live pool restored");
        assertEq(swood.delegationOf(alice, bob), 300e18, "live delegation restored");
        assertEq(swood.totalDelegatedStake(), 300e18, "totalDelegatedStake restored");
        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), 0, "stamp cleared");
    }

    /// @notice One unbonding entry per `(delegator, delegate)` pair — a second
    ///         `requestUnstakeDelegation` while an entry exists reverts. Even a
    ///         fresh live re-delegation does not lift the one-entry rule.
    function test_requestUnstakeDelegation_secondRequestWithEntryReverts() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);

        // A fresh live delegation builds a new position...
        _fundAndApprove(alice, 100e18);
        vm.prank(alice);
        swood.delegateStake(bob, 100e18);

        // ...but a second unbonding request still reverts: the prior entry is
        // unclaimed. Claim or cancel it first.
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeAlreadyRequested.selector);
        swood.requestUnstakeDelegation(bob);
    }

    // ── Fund-trap guard: exits MUST work when delegation is disabled ──

    function test_unstakeFlow_worksWhenDelegationDisabled() public {
        _setup_aliceDelegates300ToBob();

        // Owner disables the feature AFTER alice delegated.
        vm.prank(owner);
        swood.setDelegationEnabled(false);
        assertFalse(swood.delegationEnabled());

        // request -> warp -> claim still succeeds; funds are never trapped.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);

        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
        assertEq(wood.balanceOf(alice) - balBefore, 300e18, "exit works while disabled");
    }

    function test_cancelUnstakeDelegation_worksWhenDelegationDisabled() public {
        _setup_aliceDelegates300ToBob();
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.prank(owner);
        swood.setDelegationEnabled(false);
        // cancel must still work while disabled.
        vm.prank(alice);
        swood.cancelUnstakeDelegation(bob);
    }

    // ── Delegation checkpoints (Task 4.3) ──

    function test_getPastDelegation_readsTokenEquivalentAtT0() public {
        _setup_aliceDelegates300ToBob();
        uint256 t0 = vm.getBlockTimestamp();
        // Warp past t0 so the checkpoint at t0 is queryable.
        vm.warp(t0 + 1);
        assertEq(swood.getPastDelegation(alice, bob, t0), 300e18, "alice's delegation at t0");
    }

    function test_getPastDelegatedInbound_readsPoolTokensAtT0() public {
        _setup_aliceDelegates300ToBob();
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1);
        assertEq(swood.getPastDelegatedInbound(bob, t0), 300e18, "poolTokens[bob] at t0");
    }

    function test_getPastTotalDelegated_readsGlobalAtT0() public {
        _setup_aliceDelegates300ToBob();
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1);
        assertEq(swood.getPastTotalDelegated(t0), 300e18, "totalDelegatedStake at t0");
    }

    function test_getPastDelegation_laterStateChangeDoesNotMutatePast() public {
        _setup_aliceDelegates300ToBob();
        uint256 t0 = vm.getBlockTimestamp();

        // A later delegation by carol must not change the t0 reads.
        vm.warp(t0 + 100);
        _fundAndApprove(carol, 100e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        // Reads "as of t0" are unchanged.
        assertEq(swood.getPastDelegation(alice, bob, t0), 300e18, "alice t0 unchanged");
        assertEq(swood.getPastDelegatedInbound(bob, t0), 300e18, "inbound t0 unchanged");
        assertEq(swood.getPastTotalDelegated(t0), 300e18, "total t0 unchanged");

        // Reads at the later timestamp reflect carol's delegation.
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(t1 + 1);
        assertEq(swood.getPastDelegatedInbound(bob, t1), 400e18, "inbound at t1 includes carol");
        assertEq(swood.getPastTotalDelegated(t1), 400e18, "total at t1 includes carol");
        assertEq(swood.getPastDelegation(carol, bob, t1), 100e18, "carol delegation at t1");
        assertEq(swood.getPastDelegation(alice, bob, t1), 300e18, "alice still 300 at t1");
    }

    function test_getPastDelegation_zeroBeforeAnyDelegation() public {
        uint256 t0 = vm.getBlockTimestamp();
        vm.warp(t0 + 1);
        assertEq(swood.getPastDelegation(alice, bob, t0), 0, "no delegation -> 0");
        assertEq(swood.getPastDelegatedInbound(bob, t0), 0, "no inbound -> 0");
        assertEq(swood.getPastTotalDelegated(t0), 0, "no total -> 0");
    }

    // ── DPoS commission (Task 4.4 — relocated verbatim from
    //    GuardianRegistryCommission.t.sol) ──

    /// @notice First-ever set with no delegators is an uncapped announcement.
    function test_setCommission_firstSet_exemptFromRaiseCap() public {
        vm.prank(bob);
        swood.setCommission(3000); // 30% first-set with no delegators is fine.
        assertEq(swood.commissionOf(bob), 3000);
    }

    /// @notice A raise above MAX_COMMISSION_INCREASE_PER_EPOCH in one epoch reverts.
    function test_setCommission_raiseCap_sameEpochReverts() public {
        vm.prank(bob);
        swood.setCommission(1000);

        vm.expectRevert(StakedWoodDelegation.CommissionRaiseExceedsLimit.selector);
        vm.prank(bob);
        swood.setCommission(2000); // 1000 bps raise > 500 cap
    }

    /// @notice A raise within the per-epoch cap is accepted.
    function test_setCommission_raiseCap_smallRaiseAllowed() public {
        vm.prank(bob);
        swood.setCommission(1000);
        vm.prank(bob);
        swood.setCommission(1400); // 400 bps raise — below cap
        assertEq(swood.commissionOf(bob), 1400);
    }

    /// @notice A new epoch re-anchors the baseline so a fresh raise is allowed.
    function test_setCommission_raiseCap_nextEpochAllowed() public {
        vm.prank(bob);
        swood.setCommission(1000);

        vm.warp(vm.getBlockTimestamp() + swood.EPOCH_DURATION());
        vm.prank(bob);
        swood.setCommission(1500); // raise by 500 in new epoch — allowed
        assertEq(swood.commissionOf(bob), 1500);
    }

    /// @notice Decreases are unbounded — straight to 0 from the max.
    function test_setCommission_decreaseUnbounded() public {
        vm.prank(bob);
        swood.setCommission(5000); // max
        vm.prank(bob);
        swood.setCommission(0);
        assertEq(swood.commissionOf(bob), 0);
    }

    /// @notice setCommission reverts above MAX_COMMISSION_BPS (5000).
    function test_setCommission_exceedsMaxReverts() public {
        vm.expectRevert(StakedWoodDelegation.CommissionExceedsMax.selector);
        vm.prank(bob);
        swood.setCommission(6000);
    }

    /// @notice getPastCommission freezes the rate at a past timestamp — a
    ///         later raise does not retroactively change a historical read.
    function test_getPastCommission_freezesRateAtPastTimestamp() public {
        vm.prank(bob);
        swood.setCommission(1000);
        uint256 t0 = vm.getBlockTimestamp();

        // Move into a new epoch and raise the commission.
        vm.warp(t0 + swood.EPOCH_DURATION());
        vm.prank(bob);
        swood.setCommission(1500);
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(t1 + 1);

        // Past read at t0 still sees 1000; current read sees 1500.
        assertEq(swood.getPastCommission(bob, t0), 1000, "rate frozen at t0");
        assertEq(swood.getPastCommission(bob, t1), 1500, "rate at t1");
        assertEq(swood.commissionOf(bob), 1500, "current rate");
    }

    /// @notice CommissionSet event carries old + new bps.
    function test_setCommission_emitsCommissionSet() public {
        vm.expectEmit(true, false, false, true, address(swood));
        emit StakedWoodDelegation.CommissionSet(bob, 0, 1500);
        vm.prank(bob);
        swood.setCommission(1500);
    }

    /// @notice Cumulative same-epoch raises cannot compound past the cap.
    function test_setCommission_cumulativeRaiseLimitBlocksChaining() public {
        vm.prank(bob);
        swood.setCommission(300); // first-set, baseline 300

        vm.prank(bob);
        swood.setCommission(800); // 300 + 500 cap — OK

        // Baseline still 300; cap 800. 900 > 800 -> revert.
        vm.expectRevert(StakedWoodDelegation.CommissionRaiseExceedsLimit.selector);
        vm.prank(bob);
        swood.setCommission(900);

        // Next epoch re-anchors baseline to 800; cap 1300.
        vm.warp(vm.getBlockTimestamp() + swood.EPOCH_DURATION());
        vm.prank(bob);
        swood.setCommission(1300);
        assertEq(swood.commissionOf(bob), 1300);
    }

    /// @notice First-set with existing delegators enforces the cap (ToB C-2).
    function test_setCommission_firstSet_withExistingDelegators_enforcesCap() public {
        // alice delegates to bob BEFORE bob sets commission.
        _setup_aliceDelegates300ToBob();

        // First-ever setCommission at 4000 would rug alice — capped from 0.
        vm.expectRevert(StakedWoodDelegation.CommissionRaiseExceedsLimit.selector);
        vm.prank(bob);
        swood.setCommission(4000);

        // 500 (== cap) is accepted.
        vm.prank(bob);
        swood.setCommission(500);
        assertEq(swood.commissionOf(bob), 500);
    }
}
