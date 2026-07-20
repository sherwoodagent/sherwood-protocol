// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {StakedWoodDelegation} from "../src/StakedWoodDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockBrokenWood} from "./mocks/MockBrokenWood.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";

/// @notice Slashing tests for StakedWood (sWOOD): registry-gated share-factor
///         `slashGuardians` — own stake sized off the raw own-stake checkpoint
///         at `openedAt`, delegated pools diluted pro-rata at
///         `min(slashBps, maxDelegatedSlashBps)`, first-loss spill onto the
///         guardian's own remaining stake (spec 2026-07-19 Part A).
contract StakedWoodSlashingTest is Test {
    /// @dev Mirror of `StakedWood.GuardianSlashed` for `vm.expectEmit`.
    event GuardianSlashed(
        bytes32 indexed reviewKey, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
    );

    StakedWood swood;
    ERC20Mock wood;
    MockGovernorMinimal gov;

    address owner = address(0xA11CE);
    address factory = address(0xFAC10);
    address registry = address(0x9E915);
    address alice = address(0xA11CE5);
    address bob = address(0xB0B);
    address carol = address(0xCA401);

    address constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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

        // Registry wired so `onlyRegistry` entrypoints can be exercised.
        vm.prank(owner);
        swood.setRegistry(registry);

        // Delegation enabled for the pool-slash tests.
        vm.prank(owner);
        swood.setDelegationEnabled(true);

        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            address a = actors[i];
            wood.mint(a, 1_000_000e18);
            vm.prank(a);
            wood.approve(address(swood), type(uint256).max);
        }
    }

    // ── slashGuardians: own stake ──

    function test_slashGuardians_onlyRegistry() public {
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(alice);
        vm.expectRevert(StakedWood.NotRegistry.selector);
        swood.slashGuardians(bytes32(uint256(1)), 0, approvers, 5000);
    }

    function test_slashGuardians_ownStake() public {
        // Alice stakes 20k as a guardian.
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);

        // Age-weighted voting: mature to par so the pre-slash vote read
        // below returns raw stake. The slash basis is age-independent (raw
        // checkpoint) either way.
        skip(30 days);
        uint256 maturedAt = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1);

        // Slash 25% (2500 bps) → 20k * 2500 / 10000 = 5k burned. The own
        // basis is the raw own-stake checkpoint at `openedAt` (= maturedAt).
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        // GuardianSlashed fires with own slash 5k, delegated slash 0.
        vm.expectEmit(true, true, true, true, address(swood));
        emit GuardianSlashed(bytes32(uint256(1)), alice, 5_000e18, 0);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), maturedAt, approvers, 2500);
        uint256 slashedAt = vm.getBlockTimestamp();

        assertEq(total, 5_000e18, "returned total");
        assertEq(swood.guardianStake(alice), 15_000e18, "own stake reduced");
        assertEq(swood.totalGuardianStake(), 15_000e18, "totalGuardianStake reduced");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_000e18, "burned to dead address");

        // getPastVotes re-checkpointed: pre-slash 20k, post-slash 15k.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastVotes(alice, maturedAt), 20_000e18, "pre-slash checkpoint");
        assertEq(swood.getPastVotes(alice, slashedAt), 15_000e18, "post-slash checkpoint");
        assertEq(swood.getPastTotalVotes(slashedAt), 15_000e18, "total checkpoint re-pushed");
    }

    // ── slashGuardians: delegated pool pro-rata (share-factor) ──

    function test_slashGuardians_delegatedPoolProRata() public {
        // Bob self-stakes 10k as an active guardian so he can be a delegate.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // alice delegates 300, carol delegates 100 → pool: 400 tok / 400 sh.
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        assertEq(swood.poolTokens(bob), 400e18);
        assertEq(swood.delegationOf(alice, bob), 300e18);
        assertEq(swood.delegationOf(carol, bob), 100e18);

        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Slash bob at 50% — ONE write dilutes poolTokens, every delegator
        // diluted pro-rata (no loop over delegators). The pool leg pays
        // min(S, C) = 2000 bps; the absorbed 3000 bps of the delegated
        // exposure (400) spills onto bob's own remaining stake.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(2)), openedAt, approvers, 5000);

        // own base 5k + spill 400*30% = 120; pool 400 → 400 - 400*20% = 320.
        assertEq(total, 5_120e18 + 80e18, "own(base+spill) + capped delegated slash");
        assertEq(swood.guardianStake(bob), 4_880e18, "own = 10k - 5k base - 120 spill");
        assertEq(swood.poolTokens(bob), 320e18, "pool pays C = 20%");
        assertEq(swood.totalDelegatedStake(), 320e18, "totalDelegatedStake at capped rate");
        assertEq(swood.delegationOf(alice, bob), 240e18, "alice diluted pro-rata");
        assertEq(swood.delegationOf(carol, bob), 80e18, "carol diluted pro-rata");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_120e18 + 80e18, "burned");
    }

    // ── Rate-conversion: post-slash, delegateStake mints MORE shares than `amount` ──

    function test_slashGuardians_postSlashDelegateMintsAtRate() public {
        // Bob self-stakes 10k so he can be a delegate.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // alice delegates 100 into an empty pool → 100 tok / 100 sh (1:1).
        vm.prank(alice);
        swood.delegateStake(bob, 100e18);
        assertEq(swood.poolTokens(bob), 100e18);
        assertEq(swood.poolShares(bob), 100e18);

        // Slash bob 50% → pool leg pays min(S, C) = 20%: 80 tok / 100 sh
        // (rate < 1:1).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(3)), 0, approvers, 5000);
        assertEq(swood.poolTokens(bob), 80e18, "pool tokens at capped rate");
        assertEq(swood.poolShares(bob), 100e18, "pool shares unchanged by slash");

        // carol delegates 80 → minted = mulDiv(80, 100, 80) = 100 shares
        // (MORE than `amount` — proves rate conversion, not 1:1).
        uint256 sharesBefore = swood.poolShares(bob);
        vm.prank(carol);
        swood.delegateStake(bob, 80e18);

        assertEq(swood.poolShares(bob) - sharesBefore, 100e18, "minted at rate (>amount)");
        assertEq(swood.poolTokens(bob), 160e18, "pool tokens grew by amount");
        // carol holds 100 shares of a 160tok/200sh pool → 80 token-equivalent.
        assertEq(swood.delegationOf(carol, bob), 80e18, "carol token-equivalent");
    }

    // ── I-1: unbonding-escrow slash evasion + liveness ──

    /// @notice Evasion CLOSED: a delegator who `requestUnstakeDelegation`s
    ///         after their stake backed a delegate's review vote still eats the
    ///         slash. Their WOOD sits in the slashable unbonding pool through
    ///         the cooldown; `resolveReview` (modelled here as the registry's
    ///         `slashGuardians`) lands the slash on the unbonding pool BEFORE
    ///         the delegator can `claim`. The claim returns the SLASHED amount
    ///         (at the capped rate min(S, C) — spec 2026-07-19 Part A).
    function test_unbonding_evasionClosed_claimReturnsSlashedAmount() public {
        // Bob self-stakes 10k so he can be a delegate.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 400 to bob — this stake backs bob's vote weight.
        vm.prank(alice);
        swood.delegateStake(bob, 400e18);

        // A review opens (bob voted Approve while alice's stake backed him).
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Alice tries to dodge the slash: request-unstake moves her 400 into
        // the unbonding pool, but it stays slashable for the cooldown.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.unbondingPoolTokens(bob), 400e18, "alice's stake in unbonding pool");

        // resolveReview blocks the proposal -> registry slashes bob at 50%.
        // The unbonding pool is hit pro-rata at min(S, C) = 20%: 400 -> 320.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(7)), openedAt, approvers, 5000);
        assertEq(swood.unbondingPoolTokens(bob), 320e18, "unbonding pool slashed at C");

        // Cooldown elapses; alice claims — she receives the SLASHED 320, not
        // the un-slashed 400. Evasion is closed.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
        assertEq(wood.balanceOf(alice) - balBefore, 320e18, "claim returns SLASHED amount");
    }

    /// @notice Liveness: `claimUnstakeDelegation` always succeeds once the
    ///         cooldown has elapsed, regardless of how many open reviews the
    ///         delegate has — no fund-trap. There is no review-activity gate.
    function test_unbonding_liveness_claimSucceedsAfterCooldown() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
        vm.prank(alice);
        swood.delegateStake(bob, 400e18);

        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);

        // Even with the delegate repeatedly slashed (a perpetually-active
        // guardian), the cooldown is the ONLY gate — no perpetual trap.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(8)), 0, approvers, 1000);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob); // succeeds — no revert
        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), 0, "claimed");
    }

    /// @notice A single slash hits BOTH pools pro-rata in one resolution —
    ///         live and unbonding delegators are both diluted (at the capped
    ///         rate); the absorbed excess spills onto the guardian's own stake.
    function test_unbonding_slashHitsBothPoolsProRata() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 (will unbond), carol delegates 100 (stays live).
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        // Review opens while both delegations are live (exposure = 400).
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Alice unbonds — 300 moves to the unbonding pool, 100 stays live.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.poolTokens(bob), 100e18, "live pool = carol's 100");
        assertEq(swood.unbondingPoolTokens(bob), 300e18, "unbonding pool = alice's 300");

        // One slash at 50% hits both pools at min(S, C) = 20%; the absorbed
        // 30% of the at-open exposure (400) spills onto bob's own stake.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.expectEmit(true, true, true, true, address(swood));
        // ownSlash 5k base + 120 spill; delegatedSlash = live 20 + unbonding 60 = 80.
        emit GuardianSlashed(bytes32(uint256(9)), bob, 5_120e18, 80e18);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(9)), openedAt, approvers, 5000);

        assertEq(swood.guardianStake(bob), 4_880e18, "own = 10k - 5k base - 120 spill");
        assertEq(swood.poolTokens(bob), 80e18, "live pool pays C");
        assertEq(swood.unbondingPoolTokens(bob), 240e18, "unbonding pool pays C");
        // totalDelegatedStake only tracks the LIVE pool: 100 -> 80.
        assertEq(swood.totalDelegatedStake(), 80e18, "totalDelegatedStake = live only");
        assertEq(total, 5_120e18 + 20e18 + 60e18, "burn total = own(base+spill) + live + unbonding");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_120e18 + 80e18, "combined burn");

        // carol (live) diluted; alice (unbonding) diluted.
        assertEq(swood.delegationOf(carol, bob), 80e18, "live delegator diluted");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
        assertEq(wood.balanceOf(alice) - balBefore, 240e18, "unbonding delegator diluted");
    }

    /// @notice PR #359 review #2 — the unbonding-pool slash is capped by the
    ///         OPENED-AT delegated budget, not the full live unbonding pool.
    ///         A delegator who joins AFTER `openedAt` and then unbonds is
    ///         excluded from `snapDelegated`, so the combined delegated slash
    ///         (live + unbonding) never exceeds `mulDiv(snapDelegated, slashBps)`.
    ///         Pre-fix the live pool was snapshot-capped but the unbonding
    ///         burn was the full pool — the asymmetry this closes.
    function test_unbonding_postOpenDelegator_cappedBySnapshot() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 BEFORE open — the at-open delegated exposure.
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);

        // Advance a block, then snapshot the open timestamp (only alice counts).
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 openedAt = vm.getBlockTimestamp();

        // Carol delegates 200 AFTER open — excluded from `snapDelegated`.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        swood.delegateStake(bob, 200e18);
        assertEq(swood.getPastDelegatedInbound(bob, openedAt), 300e18, "snapDelegated = alice only");

        // Both delegators unbond — live pool empties, unbonding pool = 500.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        vm.prank(carol);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.poolTokens(bob), 0, "live pool empty");
        assertEq(swood.unbondingPoolTokens(bob), 500e18, "unbonding = alice 300 + carol 200");

        // Slash 10% with the REAL openedAt (S = 1000 < C = 2000, so the
        // delegated legs pay the full severity — no cap, no spill).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(11)), openedAt, approvers, 1000);

        // Budget = 10% of the at-open delegated exposure (300) = 30. Live pool
        // is empty so the whole budget spills to the unbonding pool. Pre-fix
        // the unbonding slash was 10% of the FULL 500 = 50 (over by 20).
        uint256 budget = (300e18 * 1000) / 10_000; // 30e18
        assertEq(swood.unbondingPoolTokens(bob), 500e18 - budget, "unbonding slashed by at-open budget only");

        // own 10% of 10k = 1k; delegated total = budget (0 live + 30 unbonding).
        assertEq(total, 1_000e18 + budget, "own 1k + capped delegated budget");
        assertLe(total - 1_000e18, budget, "combined delegated slash <= snapshot budget (PR #359 #2)");
    }

    /// @notice `cancelUnstakeDelegation` after the unbonding pool was slashed
    ///         re-bonds at the SLASHED unbonding rate — the leaver eats the hit
    ///         even on the re-entry path.
    function test_unbonding_cancelReBondsAtSlashedRate() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
        vm.prank(alice);
        swood.delegateStake(bob, 400e18);

        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);

        // Unbonding pool slashed at min(5000, C=2000) = 20%: 400 -> 320.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(10)), 0, approvers, 5000);
        assertEq(swood.unbondingPoolTokens(bob), 320e18, "unbonding slashed at C");

        // Cancel re-bonds the SLASHED 320 into the live pool, not 400.
        vm.prank(alice);
        swood.cancelUnstakeDelegation(bob);
        assertEq(swood.delegationOf(alice, bob), 320e18, "re-bonded at slashed rate");
        assertEq(swood.poolTokens(bob), 320e18, "live pool = slashed amount");
        assertEq(swood.totalDelegatedStake(), 320e18, "totalDelegatedStake = slashed amount");
        assertEq(swood.unbondingPoolTokens(bob), 0, "unbonding pool cleared");
    }

    /// @notice Unbonding stake is invisible to vote weight / quorum: after a
    ///         `requestUnstakeDelegation`, the delegate's `getPastVotes`,
    ///         `getPastDelegatedInbound`, and `totalDelegatedStake` all drop
    ///         the unbonded amount.
    function test_unbonding_excludedFromVotesAndQuorum() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Age-weighted voting: mature bob's own stake to par.
        skip(30 days);

        vm.prank(alice);
        swood.delegateStake(bob, 400e18);

        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        uint256 tReq = vm.getBlockTimestamp();
        vm.warp(tReq + 1);

        // Vote weight = own 10k + delegated-inbound 0 (alice's 400 unbonded).
        assertEq(swood.getPastDelegatedInbound(bob, tReq), 0, "inbound excludes unbonding");
        assertEq(swood.getPastVotes(bob, tReq), 10_000e18, "votes = own only");
        assertEq(swood.getPastTotalDelegated(tReq), 0, "quorum denominator excludes unbonding");
        assertEq(swood.totalDelegatedStake(), 0, "live totalDelegatedStake excludes unbonding");
    }

    // ── Edge cases ──

    /// @notice Empty approvers array: returns 0, no revert, no checkpoint push.
    function test_slashGuardians_emptyApprovers() public {
        // A guardian stakes so a total-stake checkpoint exists to compare against.
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);
        uint256 stakedAt = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 100);
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);

        address[] memory approvers = new address[](0);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), 0, approvers, 5000);

        assertEq(total, 0, "empty array returns 0");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore, "nothing burned");

        // No checkpoint pushed: the latest total-stake value is still the one
        // recorded at `stakedAt`, readable at any later timestamp.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalVotes(stakedAt), 20_000e18, "checkpoint at stake time");
        assertEq(
            swood.getPastTotalVotes(vm.getBlockTimestamp() - 1), 20_000e18, "no new checkpoint pushed after empty slash"
        );
    }

    /// @notice Clamp branch: an at-open own-stake checkpoint exceeding live
    ///         stake must size the slash from live stake, not the stale
    ///         snapshot. Exercised for real: a concurrent slash (same
    ///         `openedAt`, different review) reduces live stake below the
    ///         at-open checkpoint before the second slash lands.
    function test_slashGuardians_clampSnapshotAboveLiveStake() public {
        // Alice stakes 12k as a guardian; both reviews open at this instant.
        vm.prank(alice);
        swood.stakeAsGuardian(12_000e18, 1);
        uint256 openedAt = vm.getBlockTimestamp();

        vm.warp(openedAt + 1);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;

        // First slash at 25%: 12k * 2500 / 10000 = 3k → live drops to 9k.
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 2500);
        assertEq(swood.guardianStake(alice), 9_000e18, "live after first slash");

        // Second slash, same openedAt: checkpoint reads 12k but live is 9k.
        // Clamp → sized from live 9k: mulDiv(9k, 2500, 10000) = 2_250e18.
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.expectEmit(true, true, true, true, address(swood));
        emit GuardianSlashed(bytes32(uint256(2)), alice, 2_250e18, 0);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(2)), openedAt, approvers, 2500);

        // 12k * 2500 / 10000 = 3k would over-slash; clamp caps at 2.25k.
        assertEq(total, 2_250e18, "slash sized from live stake, not snapshot");
        assertEq(swood.guardianStake(alice), 6_750e18, "live 9k - 2.25k clamp slash");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 2_250e18, "burned clamped amount");
    }

    // ── Fail-soft burn: _pendingBurn fallback + flushBurn (Task 5.2) ──

    /// @dev Mirrors of the fail-soft burn events for `vm.expectEmit`.
    event PendingBurnRecorded(uint256 amount);
    event BurnFlushed(uint256 amount);
    event OwnerBondSlashed(address indexed vault, uint256 amount);

    /// @notice Deploy a fresh sWOOD proxy backed by `brokenWood` so the burn
    ///         path can be exercised against a WOOD whose `transfer` to
    ///         `BURN_ADDRESS` is toggleable. Returns the proxy.
    function _deploySwoodWithBrokenWood(MockBrokenWood brokenWood) internal returns (StakedWood s) {
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(brokenWood),
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
        s = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(owner);
        s.setRegistry(registry);
    }

    /// @notice A WOOD whose burn `transfer` returns `false` must NOT brick
    ///         `slashGuardians`: the slash accounting still applies and the
    ///         amount queues in `_pendingBurn` (`!ok` branch).
    function test_slashGuardians_burnReturnsFalse_queuesPendingBurn() public {
        MockBrokenWood bw = new MockBrokenWood("WOOD", "WOOD", 18);
        StakedWood s = _deploySwoodWithBrokenWood(bw);

        bw.mint(alice, 1_000_000e18);
        vm.prank(alice);
        bw.approve(address(s), type(uint256).max);

        vm.prank(alice);
        s.stakeAsGuardian(20_000e18, 1);
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Burn transfer to BURN_ADDRESS returns false (no revert).
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.ReturnFalse);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;

        // PendingBurnRecorded(5k) fires; slashGuardians does NOT revert.
        vm.expectEmit(false, false, false, true, address(s));
        emit PendingBurnRecorded(5_000e18);
        vm.prank(registry);
        uint256 total = s.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 2500);

        assertEq(total, 5_000e18, "slash accounting still applied");
        assertEq(s.guardianStake(alice), 15_000e18, "own stake reduced despite failed burn");
        assertEq(s.pendingBurn(), 5_000e18, "amount queued in _pendingBurn");
        assertEq(bw.balanceOf(BURN_ADDRESS), 0, "nothing burned (transfer returned false)");
    }

    /// @notice A WOOD whose burn `transfer` reverts must NOT brick
    ///         `slashGuardians`: try/catch queues the amount (`catch` branch).
    function test_slashGuardians_burnReverts_queuesPendingBurn() public {
        MockBrokenWood bw = new MockBrokenWood("WOOD", "WOOD", 18);
        StakedWood s = _deploySwoodWithBrokenWood(bw);

        bw.mint(alice, 1_000_000e18);
        vm.prank(alice);
        bw.approve(address(s), type(uint256).max);

        vm.prank(alice);
        s.stakeAsGuardian(20_000e18, 1);
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Burn transfer to BURN_ADDRESS reverts.
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.Revert);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;

        vm.expectEmit(false, false, false, true, address(s));
        emit PendingBurnRecorded(5_000e18);
        vm.prank(registry);
        uint256 total = s.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 2500);

        assertEq(total, 5_000e18, "slash accounting still applied");
        assertEq(s.guardianStake(alice), 15_000e18, "own stake reduced despite reverting burn");
        assertEq(s.pendingBurn(), 5_000e18, "amount queued in _pendingBurn");
        assertEq(bw.balanceOf(BURN_ADDRESS), 0, "nothing burned (transfer reverted)");
    }

    /// @notice After the WOOD token recovers, `flushBurn` drains `_pendingBurn`
    ///         to `BURN_ADDRESS`. A second call is a no-op.
    function test_flushBurn_drainsPendingBurnAfterRecovery() public {
        MockBrokenWood bw = new MockBrokenWood("WOOD", "WOOD", 18);
        StakedWood s = _deploySwoodWithBrokenWood(bw);

        bw.mint(alice, 1_000_000e18);
        vm.prank(alice);
        bw.approve(address(s), type(uint256).max);

        vm.prank(alice);
        s.stakeAsGuardian(20_000e18, 1);
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);

        // Burn fails → queued.
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.Revert);
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(registry);
        s.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 2500);
        assertEq(s.pendingBurn(), 5_000e18, "queued before recovery");

        // Token recovers; flushBurn is permissionless.
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.None);
        vm.expectEmit(false, false, false, true, address(s));
        emit BurnFlushed(5_000e18);
        vm.prank(alice);
        s.flushBurn();

        assertEq(s.pendingBurn(), 0, "_pendingBurn drained");
        assertEq(bw.balanceOf(BURN_ADDRESS), 5_000e18, "burned to dead address");

        // Second call is a no-op (queue empty).
        vm.prank(bob);
        s.flushBurn();
        assertEq(bw.balanceOf(BURN_ADDRESS), 5_000e18, "no double burn");
    }

    // ── slashOwnerBond (Task 5.2) ──

    /// @notice Bind an owner bond for `vault` via the factory-only prepare/bind
    ///         flow, using the default `swood` instance.
    function _bindOwnerBond(address vault, address ownerAddr, uint256 amount) internal {
        vm.prank(ownerAddr);
        swood.prepareOwnerStake(amount);
        vm.prank(factory);
        swood.bindOwnerStake(ownerAddr, vault);
    }

    function test_slashOwnerBond_onlyRegistry() public {
        address vault = address(0x7A017);
        _bindOwnerBond(vault, alice, 5_000e18);

        vm.prank(alice);
        vm.expectRevert(StakedWood.NotRegistry.selector);
        swood.slashOwnerBond(vault);
    }

    function test_slashOwnerBond_burnsBondAndClearsSlot() public {
        address vault = address(0x7A017);
        _bindOwnerBond(vault, alice, 5_000e18);
        assertEq(swood.ownerStake(vault), 5_000e18, "bond bound");

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.expectEmit(true, false, false, true, address(swood));
        emit OwnerBondSlashed(vault, 5_000e18);
        vm.prank(registry);
        swood.slashOwnerBond(vault);

        assertEq(swood.ownerStake(vault), 0, "bond slot zeroed");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_000e18, "bond burned");
    }

    /// @notice Slashing a vault with no bond is a no-op (no burn, no revert).
    function test_slashOwnerBond_noBond_noOp() public {
        address vault = address(0xDEAD01);
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.prank(registry);
        swood.slashOwnerBond(vault);
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore, "nothing burned");
        assertEq(swood.ownerStake(vault), 0, "still zero");
    }

    /// @notice Owner-bond slash against a broken WOOD queues in `_pendingBurn`
    ///         and clears the slot — slashing must not be brickable.
    function test_slashOwnerBond_brokenWood_queuesPendingBurn() public {
        MockBrokenWood bw = new MockBrokenWood("WOOD", "WOOD", 18);
        StakedWood s = _deploySwoodWithBrokenWood(bw);

        bw.mint(alice, 1_000_000e18);
        vm.prank(alice);
        bw.approve(address(s), type(uint256).max);

        address vault = address(0x7A017);
        vm.prank(alice);
        s.prepareOwnerStake(5_000e18);
        vm.prank(factory);
        s.bindOwnerStake(alice, vault);

        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.Revert);
        vm.prank(registry);
        s.slashOwnerBond(vault);

        assertEq(s.ownerStake(vault), 0, "slot cleared despite failed burn");
        assertEq(s.pendingBurn(), 5_000e18, "bond queued for retry");
    }

    // ── C-2: a sub-10_000 pool slash prevents pool-bricking on full slash.
    //    The param-level guard has RELOCATED: `maxSlashBps` (own-stake
    //    ceiling) may now be a full 10_000; the strict `< 10_000` cap lives
    //    on `maxDelegatedSlashBps`, which sizes the pool legs of `_slashOne`
    //    (spec 2026-07-19). ──

    /// @dev Deploys a fresh sWOOD proxy with `maxSlashBps =
    ///      maxDelegatedSlashBps = 9_999` — the highest pool-safe rate the
    ///      relocated C-2 guard admits — so the pool-residue regressions
    ///      exercise the true boundary (the pool legs are sized by
    ///      `min(slashBps, maxDelegatedSlashBps)`). Returns the proxy fully
    ///      wired (registry + delegation on).
    function _deploySwoodWithMaxSlash9999() internal returns (StakedWood s) {
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
                    maxDelegatedSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        s = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        vm.prank(owner);
        s.setRegistry(registry);
        vm.prank(owner);
        s.setDelegationEnabled(true);

        // Re-approve actors on the fresh proxy.
        address[3] memory actors = [alice, bob, carol];
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(actors[i]);
            wood.approve(address(s), type(uint256).max);
        }
    }

    /// @notice C-2: a 9_999-bps slash (the new cap) leaves the delegate's
    ///         pool with ≥ 1 wei of `poolTokens`, so a subsequent
    ///         `delegateStake` to the same delegate SUCCEEDS rather than
    ///         reverting with `Math.mulDiv` divide-by-zero.
    function test_C2_maxSlash9999_leavesPoolUsable_delegateStakeSucceeds() public {
        StakedWood s = _deploySwoodWithMaxSlash9999();

        // Bob self-stakes 10k so he can be a delegate.
        vm.prank(bob);
        s.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 400 to bob — pool: 400 tok / 400 sh.
        vm.prank(alice);
        s.delegateStake(bob, 400e18);
        assertEq(s.poolTokens(bob), 400e18, "pool seeded");
        assertEq(s.poolShares(bob), 400e18, "shares 1:1");

        // Slash bob at the cap (9_999 bps). poolTokens drops to ≥ 1 wei.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        s.slashGuardians(bytes32(uint256(1)), 0, approvers, 9_999);

        uint256 ptAfter = s.poolTokens(bob);
        uint256 psAfter = s.poolShares(bob);
        assertGt(ptAfter, 0, "poolTokens must stay > 0 after a 9999-bps slash");
        assertGt(psAfter, 0, "poolShares unchanged by slash");

        // The pool is NOT bricked: carol can still delegate.
        // (Without the C-2 fix, a 100% slash would zero poolTokens and the
        // next mulDiv(amount, sh, ts=0) would panic.)
        vm.prank(carol);
        s.delegateStake(bob, 1_000e18);

        // carol's token-equivalent ≈ 1_000e18 (modulo share-rate dust from
        // the 9_999-bps slash leaving sub-wei residue in the pool).
        uint256 carolStake = s.delegationOf(carol, bob);
        assertApproxEqAbs(carolStake, 1_000e18, 1, "carol's delegationOf ~ amount");
    }

    /// @notice C-2 (unbonding-pool symmetry): a 9_999-bps slash that hits the
    ///         unbonding pool too leaves it with ≥ 1 wei of
    ///         `unbondingPoolTokens`, so a subsequent `requestUnstakeDelegation`
    ///         succeeds rather than reverting with `mulDiv` divide-by-zero in
    ///         the unbonding-share mint.
    function test_C2_maxSlash9999_unbondingPoolUsable_requestUnstakeSucceeds() public {
        StakedWood s = _deploySwoodWithMaxSlash9999();

        // Bob self-stakes 10k so he can be a delegate.
        vm.prank(bob);
        s.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 400 then requests unstake — moves into unbonding pool.
        vm.prank(alice);
        s.delegateStake(bob, 400e18);
        vm.prank(alice);
        s.requestUnstakeDelegation(bob);
        assertEq(s.unbondingPoolTokens(bob), 400e18, "alice in unbonding pool");

        // Carol delegates 400 LIVE so the live pool also has size — the
        // 9_999-bps slash hits both pools per _slashOne.
        vm.prank(carol);
        s.delegateStake(bob, 400e18);

        // Slash bob at the cap. Both pools drop by 9_999 / 10_000.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        s.slashGuardians(bytes32(uint256(1)), 0, approvers, 9_999);

        assertGt(s.unbondingPoolTokens(bob), 0, "unbondingPoolTokens > 0 after 9999 slash");
        assertGt(s.poolTokens(bob), 0, "poolTokens > 0 after 9999 slash");

        // The unbonding pool is NOT bricked: carol can still requestUnstake.
        // (Without the C-2 fix, a 100% slash would zero unbondingPoolTokens
        // and the next mulDiv(amount, uShares, unbondingPoolTokens=0) would
        // panic in requestUnstakeDelegation.)
        vm.prank(carol);
        s.requestUnstakeDelegation(bob);
    }

    /// @notice C-2 (relocated): `setMaxSlashBps(10_000)` is now ACCEPTED —
    ///         the own-stake ceiling has no share math to brick. The strict
    ///         `< 10_000` guard moved to `setMaxDelegatedSlashBps`.
    function test_C2_setMaxSlashBps_accepts_at10000() public {
        StakedWood s = _deploySwoodWithMaxSlash9999();
        vm.prank(owner);
        s.setMaxSlashBps(10_000);
        assertEq(s.maxSlashBps(), 10_000, "full own-stake ceiling accepted");

        // The relocated guard: the delegated (pool) ceiling still rejects
        // 10_000 — a 100% pool slash would zero `poolTokens` and brick
        // `delegateStake` in `Math.mulDiv`.
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        s.setMaxDelegatedSlashBps(10_000);
    }

    /// @notice C-2 (relocated): `initialize` with `maxSlashBps = 10_000` now
    ///         SUCCEEDS — the pool-bricking guard lives on
    ///         `maxDelegatedSlashBps` instead.
    function test_C2_initialize_accepts_maxSlashAt10000() public {
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
                    maxSlashBps: 10_000,
                    maxDelegatedSlashBps: 2000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        StakedWood s = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        assertEq(s.maxSlashBps(), 10_000, "full own-stake ceiling accepted at init");
    }

    /// @notice C-2 (relocated): `initialize` with `maxDelegatedSlashBps =
    ///         10_000` must revert with `InvalidParameter` — the strict cap
    ///         now guards the pool legs.
    function test_C2_initialize_reverts_delegatedCapAt10000() public {
        StakedWood impl = new StakedWood();
        bytes memory bad = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
                    maxDelegatedSlashBps: 10_000,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days,
                    delegatedWeightCapX: 4
                }))
        );
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), bad);
    }

    // ── Sherlock run #3 #1: zero-amount requestUnstakeDelegation ──

    /// @notice After extreme slashing the live pool can hold dust where a
    ///         delegator's `liveShares × poolTokens / poolShares` rounds to 0.
    ///         `requestUnstakeDelegation` MUST revert with `UnstakeAmountZero`
    ///         instead of burning the delegator's live shares with no
    ///         compensating unbonding-pool credit (which would strand them
    ///         permanently — both cancel and claim become unreachable).
    function test_requestUnstakeDelegation_revertsOnZeroAmount() public {
        // Bob is already an active guardian via setUp's `_fundAndApprove`
        // pattern? Slashing fixture doesn't auto-stake him — do it here.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 1 wei → 1 share; carol delegates 999 wei → 999
        // shares. Live pool: 1000 tok / 1000 sh. Alice owns 1 share.
        vm.prank(alice);
        swood.delegateStake(bob, 1);
        vm.prank(carol);
        swood.delegateStake(bob, 999);

        assertEq(swood.poolTokens(bob), 1000, "pool tokens before slash");
        assertEq(swood.poolShares(bob), 1000, "pool shares before slash");

        // Registry slashes bob at 99.99%. The pool leg pays min(9999, C=2000)
        // = 20%: 1000 → 800 tokens; shares unchanged (slash dilutes via the
        // poolTokens write only). Alice's 1 share still redeems to 0.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(bytes32(uint256(99)), 0, approvers, 9999);

        assertEq(swood.poolTokens(bob), 800, "pool tokens post-slash (capped rate)");
        assertEq(swood.poolShares(bob), 1000, "pool shares unchanged");

        // Alice's redeem would compute mulDiv(1, 800, 1000) = 0. Must revert.
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeAmountZero.selector);
        swood.requestUnstakeDelegation(bob);

        // Alice's shares MUST still be live (not burned). Cancel/claim are
        // never set into the bricked state because the request reverted.
        assertEq(swood.poolShares(bob), 1000, "shares not burned by reverted request");
        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), 0, "no stale request stamp");
    }

    // ── Sherlock run #3 #6: at-open own-stake slash basis ──

    /// @notice Sherlock run #3 #6 regression, retained under the raw-checkpoint
    ///         basis. Originally `_slashOne` sized the own slash off the
    ///         registry's combined (own + delegated) `voteStake` snapshot —
    ///         a guardian who topped up between open and slash was debited
    ///         for the delegated portion too, while `delSlash` separately hit
    ///         the pool (effective double-slash). The own basis is now read
    ///         DIRECTLY from the raw own-stake checkpoint at `openedAt`
    ///         (spec 2026-07-19 §5) so the own and delegated legs are sized
    ///         off disjoint snapshots and the #6 double-slash is structurally
    ///         impossible. Asserts the decomposition: own=10k at open,
    ///         delegated=50k at open, live own (post top-up)=20k, 10% slash —
    ///         own loses 1k (not 6k-combined-based 2k), pool loses 5k, and
    ///         the top-up tranche is untouched.
    function test_slashGuardians_snapshotAwareOwnSlash() public {
        // Bob is the active guardian and the delegate. Self-stakes the
        // minimum (10k) so he qualifies. Pool starts empty.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 50k to bob -> pool: 50k tok / 50k sh.
        vm.prank(alice);
        swood.delegateStake(bob, 50_000e18);

        // Warp 1 so the at-open reads return the state at the snap time.
        // Mirrors registry's openReview `t-1` semantics.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 openedAt = vm.getBlockTimestamp() - 1;
        uint256 delegatedAtOpen = swood.getPastDelegatedInbound(bob, openedAt);
        assertEq(delegatedAtOpen, 50_000e18, "delegated inbound snapshot");

        // Bob tops up own stake 10k -> 20k between open and slash.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
        assertEq(swood.guardianStake(bob), 20_000e18, "own stake topped up");

        // Slash 10% (1000 bps) — below C = 2000, so no cap and no spill.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 1000);

        // Decomposition:
        //   snapOwnRaw (checkpoint at openedAt) = 10k, snapDelegated = 50k.
        //   ownSlash = mulDiv(min(10k, live 20k), 1000, 10000) = 1k.
        //   delSlash = mulDiv(min(50k, oldPool 50k), 1000, 10000) = 5k.
        //   spill = 50k * (1000 - min(1000, C)) / 10000 = 0. total = 6k.
        // Combined-snapshot sizing would have given ownSlash =
        // mulDiv(min(60k, 20k), 1000, 10000) = 2k (over-slash by 1k).
        assertEq(total, 6_000e18, "total = ownSlash(1k) + delSlash(5k)");
        assertEq(swood.guardianStake(bob), 19_000e18, "own stake = 20k - 1k (NOT 20k - 2k)");
        assertEq(swood.poolTokens(bob), 45_000e18, "pool tokens = 50k - 5k (correct)");
    }

    /// @notice Degenerate snapshot: when openedAt is 0 (no review-open
    ///         timestamp), the raw own-stake checkpoint lookup at 0 returns 0
    ///         — there is NO own-stake basis, so no own base slash. With no
    ///         delegations either, the slash is a complete no-op. The
    ///         production registry always passes `r.openedAt` (set in
    ///         `openReview`), and voters must have weight at that instant.
    function test_slashGuardians_openedAtZero_uninformativeSnapshot() public {
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(registry);
        // openedAt = 0: no checkpoint at/before 0 → own basis 0; pools empty.
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), 0, approvers, 2500);

        assertEq(total, 0, "no own basis at openedAt=0 and no pools -> no-op");
        assertEq(swood.guardianStake(alice), 20_000e18, "own stake untouched");
    }

    // ── Delegated-slash cap C + first-loss spill (spec 2026-07-19 Part A) ──
    //    C = maxDelegatedSlashBps = 2000 (20%) in the setUp fixture. The
    //    delegated legs (live + unbonding pools) are slashed at min(S, C);
    //    the uncovered delegated remainder spills onto the approver's own
    //    remaining stake (first-loss guardian bond, Rocket Pool pattern).

    /// @dev Stake `guardian` and back them with `delAmt` from `delegator`,
    ///      both at the current timestamp.
    function _stakeAndDelegate(address guardian, uint256 ownAmt, address delegator, uint256 delAmt) internal {
        vm.prank(guardian);
        swood.stakeAsGuardian(ownAmt, 1);
        vm.prank(delegator);
        swood.delegateStake(guardian, delAmt);
    }

    /// @dev Registry-pranked single-approver slash at `bps` with review-open
    ///      snapshot `openedAt`.
    function _slash(address guardian, uint256 openedAt, uint256 bps) internal returns (uint256 total) {
        address[] memory approvers = new address[](1);
        approvers[0] = guardian;
        vm.prank(registry);
        total = swood.slashGuardians(bytes32(uint256(0x5EED)), openedAt, approvers, bps);
    }

    /// @notice S below C: pool pays the full severity, cap idle, no spill.
    function test_slash_belowCap_noSpill() public {
        // alice: 10k own; bob delegates 10k. S = 1500 < C = 2000.
        _stakeAndDelegate(alice, 10_000e18, bob, 10_000e18);
        uint256 openedAt = vm.getBlockTimestamp();
        _slash(alice, openedAt, 1500);
        assertEq(swood.guardianStake(alice), 8_500e18, "15% own"); // 10k - 1.5k
        assertEq(swood.poolTokens(alice), 8_500e18, "15% pool - cap idle"); // 10k - 1.5k
    }

    /// @notice S above C: the pool pays only C; the delegated damage the cap
    ///         absorbed spills onto the guardian's own remaining stake.
    function test_slash_aboveCap_spillCoveredByOwnStake() public {
        // alice: 10k own; bob delegates 10k. S = 5000, C = 2000.
        _stakeAndDelegate(alice, 10_000e18, bob, 10_000e18);
        uint256 openedAt = vm.getBlockTimestamp();
        _slash(alice, openedAt, 5000);
        // own base = 5k; pool pays min(S,C) = 20% -> 2k;
        // excess = (5000-2000) bps of 10k = 3k -> spills to own.
        assertEq(swood.poolTokens(alice), 8_000e18, "pool pays C only");
        assertEq(swood.guardianStake(alice), 10_000e18 - 5_000e18 - 3_000e18, "own = base + spill"); // 2k
    }

    /// @notice Sybil shape (tiny own bond, huge delegated book): the spill is
    ///         clamped at the remaining own stake — the guardian is wiped, the
    ///         delegators never lose more than C.
    function test_slash_spillClampedAtRemainingOwnStake() public {
        // alice: 10k own (fixture minimum); bob delegates 1M. S = 9000.
        _stakeAndDelegate(alice, 10_000e18, bob, 1_000_000e18);
        uint256 openedAt = vm.getBlockTimestamp();
        _slash(alice, openedAt, 9000);
        // own base = 9k, remaining 1k; excess = 70% of 1M = 700k
        // -> clamped to 1k. Own stake fully wiped; pool pays 20%.
        assertEq(swood.guardianStake(alice), 0, "own wiped by clamped spill");
        assertEq(swood.poolTokens(alice), 800_000e18, "pool pays C only");
    }

    /// @notice slashBps = 10_000 end-to-end: own wiped, pools clamped at C,
    ///         share math stays alive (the C-2 regression moved to the C bound).
    function test_slash_fullSeverity_poolsSurvive() public {
        _stakeAndDelegate(alice, 10_000e18, bob, 10_000e18);
        uint256 openedAt = vm.getBlockTimestamp();
        _slash(alice, openedAt, 10_000);
        assertEq(swood.guardianStake(alice), 0, "own fully wiped");
        assertEq(swood.poolTokens(alice), 8_000e18, "pool clamped at C");
        assertGt(swood.poolShares(alice), 0, "shares intact");
        // Share path stays functional: bob can still request-unstake — the
        // redeem math must not divide by zero.
        vm.prank(bob);
        swood.requestUnstakeDelegation(alice);
    }

    /// @notice Slash liability is the RAW own-stake checkpoint at openedAt,
    ///         NOT the aged vote weight: age discounts voting power, not
    ///         capital at risk (spec 2026-07-19 section 5).
    function test_slash_ownBasisIsRawCheckpointNotAgedWeight() public {
        // Young guardian: aged weight 25% (age-0 floor) but raw stake 10k.
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 1); // age 0
        uint256 openedAt = vm.getBlockTimestamp();
        assertEq(swood.getPastVotes(alice, openedAt), 2_500e18, "aged vote weight = 25% floor");
        _slash(alice, openedAt, 5000);
        assertEq(swood.guardianStake(alice), 5_000e18, "50% of RAW 10k, not of aged 2.5k");
    }
}
