// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {StakedWoodDelegation} from "../src/StakedWoodDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockBrokenWood} from "./mocks/MockBrokenWood.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";

/// @notice Slashing tests for StakedWood (sWOOD): registry-gated
///         `recordVoteStake` + share-factor `slashGuardians` (own stake +
///         delegated-pool pro-rata dilution).
contract StakedWoodSlashingTest is Test {
    /// @dev Mirror of `StakedWood.GuardianSlashed` for `vm.expectEmit`.
    event GuardianSlashed(
        uint256 indexed proposalId, address indexed approver, uint256 ownSlash, uint256 delegatedSlash
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
                    governor: address(gov),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999
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

    // ── recordVoteStake ──

    function test_recordVoteStake_onlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(StakedWood.NotRegistry.selector);
        swood.recordVoteStake(1, alice, 100e18);
    }

    function test_recordVoteStake_storesSnapshot() public {
        vm.prank(registry);
        swood.recordVoteStake(1, alice, 123e18);
        assertEq(swood.voteStake(1, alice), 123e18);
    }

    // ── slashGuardians: own stake ──

    function test_slashGuardians_onlyRegistry() public {
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(alice);
        vm.expectRevert(StakedWood.NotRegistry.selector);
        swood.slashGuardians(1, 0, approvers, 5000);
    }

    function test_slashGuardians_ownStake() public {
        // Alice stakes 20k as a guardian.
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);
        uint256 stakedAt = vm.getBlockTimestamp();

        // Registry snapshots alice's vote stake at 20k for proposal 1.
        vm.prank(registry);
        swood.recordVoteStake(1, alice, 20_000e18);

        vm.warp(vm.getBlockTimestamp() + 1);

        // Slash 25% (2500 bps) → 20k * 2500 / 10000 = 5k burned.
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        // GuardianSlashed fires with own slash 5k, delegated slash 0.
        vm.expectEmit(true, true, true, true, address(swood));
        emit GuardianSlashed(1, alice, 5_000e18, 0);
        vm.prank(registry);
        // openedAt=0 collapses snapDelegated lookup to 0 → snapOwn = snapTotal
        // (preserves pre-#6 behavior for tests that don't combine own + delegated).
        uint256 total = swood.slashGuardians(1, 0, approvers, 2500);
        uint256 slashedAt = vm.getBlockTimestamp();

        assertEq(total, 5_000e18, "returned total");
        assertEq(swood.guardianStake(alice), 15_000e18, "own stake reduced");
        assertEq(swood.totalGuardianStake(), 15_000e18, "totalGuardianStake reduced");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_000e18, "burned to dead address");

        // getPastVotes re-checkpointed: pre-slash 20k, post-slash 15k.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastVotes(alice, stakedAt), 20_000e18, "pre-slash checkpoint");
        assertEq(swood.getPastVotes(alice, slashedAt), 15_000e18, "post-slash checkpoint");
        assertEq(swood.getPastTotalVotes(slashedAt), 15_000e18, "total checkpoint re-pushed");
    }

    // ── slashGuardians: delegated pool pro-rata (share-factor) ──

    function test_slashGuardians_delegatedPoolProRata() public {
        // Bob self-stakes 10k as an active guardian so he can be a delegate.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Registry snapshots bob's own vote stake at 10k for proposal 2 — so
        // the own-stake portion of the slash is exercised alongside the pool.
        vm.prank(registry);
        swood.recordVoteStake(2, bob, 10_000e18);

        // alice delegates 300, carol delegates 100 → pool: 400 tok / 400 sh.
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        assertEq(swood.poolTokens(bob), 400e18);
        assertEq(swood.delegationOf(alice, bob), 300e18);
        assertEq(swood.delegationOf(carol, bob), 100e18);

        // Slash bob at 50% — ONE write halves poolTokens, every delegator
        // diluted pro-rata (no loop over delegators).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(2, 0, approvers, 5000);

        // bob's own stake (10k) also slashed 50% → 5k; pool 400 → 200.
        assertEq(total, 5_000e18 + 200e18, "own + delegated slash");
        assertEq(swood.poolTokens(bob), 200e18, "pool halved");
        assertEq(swood.totalDelegatedStake(), 200e18, "totalDelegatedStake halved");
        assertEq(swood.delegationOf(alice, bob), 150e18, "alice diluted pro-rata");
        assertEq(swood.delegationOf(carol, bob), 50e18, "carol diluted pro-rata");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_000e18 + 200e18, "burned");
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

        // Slash bob 50% → pool now 50 tok / 100 sh (rate < 1:1).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(3, 0, approvers, 5000);
        assertEq(swood.poolTokens(bob), 50e18, "pool tokens halved");
        assertEq(swood.poolShares(bob), 100e18, "pool shares unchanged by slash");

        // carol delegates 50 → minted = mulDiv(50, 100, 50) = 100 shares
        // (MORE than `amount` — proves rate conversion, not 1:1).
        uint256 sharesBefore = swood.poolShares(bob);
        vm.prank(carol);
        swood.delegateStake(bob, 50e18);

        assertEq(swood.poolShares(bob) - sharesBefore, 100e18, "minted at rate (>amount)");
        assertEq(swood.poolTokens(bob), 100e18, "pool tokens grew by amount");
        // carol holds 100 shares of a 100tok/200sh pool → 50 token-equivalent.
        assertEq(swood.delegationOf(carol, bob), 50e18, "carol token-equivalent");
    }

    // ── I-1: unbonding-escrow slash evasion + liveness ──

    /// @notice Evasion CLOSED: a delegator who `requestUnstakeDelegation`s
    ///         after their stake backed a delegate's review vote still eats the
    ///         slash. Their WOOD sits in the slashable unbonding pool through
    ///         the cooldown; `resolveReview` (modelled here as the registry's
    ///         `slashGuardians`) lands the slash on the unbonding pool BEFORE
    ///         the delegator can `claim`. The claim returns the SLASHED amount.
    function test_unbonding_evasionClosed_claimReturnsSlashedAmount() public {
        // Bob self-stakes 10k so he can be a delegate.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 400 to bob — this stake backs bob's vote weight.
        vm.prank(alice);
        swood.delegateStake(bob, 400e18);

        // A review opens (bob voted Approve while alice's stake backed him).
        // Alice tries to dodge the slash: request-unstake moves her 400 into
        // the unbonding pool, but it stays slashable for the cooldown.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.unbondingPoolTokens(bob), 400e18, "alice's stake in unbonding pool");

        // resolveReview blocks the proposal -> registry slashes bob 50%.
        // The unbonding pool is hit pro-rata: 400 -> 200.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(7, 0, approvers, 5000);
        assertEq(swood.unbondingPoolTokens(bob), 200e18, "unbonding pool slashed 50%");

        // Cooldown elapses; alice claims — she receives the SLASHED 200, not
        // the un-slashed 400. Evasion is closed.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
        assertEq(wood.balanceOf(alice) - balBefore, 200e18, "claim returns SLASHED amount");
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
        swood.slashGuardians(8, 0, approvers, 1000);

        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob); // succeeds — no revert
        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), 0, "claimed");
    }

    /// @notice A single slash hits BOTH pools pro-rata in one resolution —
    ///         live and unbonding delegators are both diluted.
    function test_unbonding_slashHitsBothPoolsProRata() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Registry snapshots bob's own vote stake so the own-stake portion of
        // the slash is exercised alongside both delegation pools.
        vm.prank(registry);
        swood.recordVoteStake(9, bob, 10_000e18);

        // Alice delegates 300 (will unbond), carol delegates 100 (stays live).
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        vm.prank(carol);
        swood.delegateStake(bob, 100e18);

        // Alice unbonds — 300 moves to the unbonding pool, 100 stays live.
        vm.prank(alice);
        swood.requestUnstakeDelegation(bob);
        assertEq(swood.poolTokens(bob), 100e18, "live pool = carol's 100");
        assertEq(swood.unbondingPoolTokens(bob), 300e18, "unbonding pool = alice's 300");

        // One slash at 50% hits both pools.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.expectEmit(true, true, true, true, address(swood));
        // ownSlash 5k (bob's 10k @ 50%); delegatedSlash = live 50 + unbonding 150 = 200.
        emit GuardianSlashed(9, bob, 5_000e18, 200e18);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(9, 0, approvers, 5000);

        assertEq(swood.poolTokens(bob), 50e18, "live pool halved");
        assertEq(swood.unbondingPoolTokens(bob), 150e18, "unbonding pool halved");
        // totalDelegatedStake only tracks the LIVE pool: 100 -> 50.
        assertEq(swood.totalDelegatedStake(), 50e18, "totalDelegatedStake = live only");
        assertEq(total, 5_000e18 + 50e18 + 150e18, "burn total = own + live + unbonding");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 5_000e18 + 200e18, "combined burn");

        // carol (live) diluted; alice (unbonding) diluted.
        assertEq(swood.delegationOf(carol, bob), 50e18, "live delegator diluted");
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.claimUnstakeDelegation(bob);
        assertEq(wood.balanceOf(alice) - balBefore, 150e18, "unbonding delegator diluted");
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

        // Registry mirrors bob's combined vote weight at open (own 10k + del 300).
        vm.prank(registry);
        swood.recordVoteStake(11, bob, 10_300e18);

        // Slash 10% with the REAL openedAt.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        uint256 total = swood.slashGuardians(11, openedAt, approvers, 1000);

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

        // Unbonding pool slashed 50%: 400 -> 200.
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(10, 0, approvers, 5000);
        assertEq(swood.unbondingPoolTokens(bob), 200e18, "unbonding slashed");

        // Cancel re-bonds the SLASHED 200 into the live pool, not 400.
        vm.prank(alice);
        swood.cancelUnstakeDelegation(bob);
        assertEq(swood.delegationOf(alice, bob), 200e18, "re-bonded at slashed rate");
        assertEq(swood.poolTokens(bob), 200e18, "live pool = slashed amount");
        assertEq(swood.totalDelegatedStake(), 200e18, "totalDelegatedStake = slashed amount");
        assertEq(swood.unbondingPoolTokens(bob), 0, "unbonding pool cleared");
    }

    /// @notice Unbonding stake is invisible to vote weight / quorum: after a
    ///         `requestUnstakeDelegation`, the delegate's `getPastVotes`,
    ///         `getPastDelegatedInbound`, and `totalDelegatedStake` all drop
    ///         the unbonded amount.
    function test_unbonding_excludedFromVotesAndQuorum() public {
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
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
        uint256 total = swood.slashGuardians(1, 0, approvers, 5000);

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

    /// @notice Clamp branch: a `voteStake` snapshot exceeding live stake must
    ///         size the slash from live stake, not the inflated snapshot.
    function test_slashGuardians_clampSnapshotAboveLiveStake() public {
        // Alice stakes only 12k as a guardian (her live stake).
        vm.prank(alice);
        swood.stakeAsGuardian(12_000e18, 1);

        // Registry records an INFLATED snapshot of 50k for proposal 1 —
        // larger than alice's 12k live stake (simulates a concurrent slash
        // having reduced live stake below the recorded vote weight).
        vm.prank(registry);
        swood.recordVoteStake(1, alice, 50_000e18);

        vm.warp(vm.getBlockTimestamp() + 1);

        // Slash 25% (2500 bps). Clamp → uses live 12k, NOT snapshot 50k.
        // Expected = mulDiv(12_000e18, 2500, 10000) = 3_000e18.
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        vm.expectEmit(true, true, true, true, address(swood));
        emit GuardianSlashed(1, alice, 3_000e18, 0);
        vm.prank(registry);
        uint256 total = swood.slashGuardians(1, 0, approvers, 2500);

        // 50k * 2500 / 10000 = 12.5k would over-slash; clamp caps at 3k.
        assertEq(total, 3_000e18, "slash sized from live stake, not snapshot");
        assertEq(swood.guardianStake(alice), 9_000e18, "live 12k - 3k clamp slash");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + 3_000e18, "burned clamped amount");
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
                    governor: address(gov),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999
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
        vm.prank(registry);
        s.recordVoteStake(1, alice, 20_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Burn transfer to BURN_ADDRESS returns false (no revert).
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.ReturnFalse);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;

        // PendingBurnRecorded(5k) fires; slashGuardians does NOT revert.
        vm.expectEmit(false, false, false, true, address(s));
        emit PendingBurnRecorded(5_000e18);
        vm.prank(registry);
        uint256 total = s.slashGuardians(1, 0, approvers, 2500);

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
        vm.prank(registry);
        s.recordVoteStake(1, alice, 20_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Burn transfer to BURN_ADDRESS reverts.
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.Revert);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;

        vm.expectEmit(false, false, false, true, address(s));
        emit PendingBurnRecorded(5_000e18);
        vm.prank(registry);
        uint256 total = s.slashGuardians(1, 0, approvers, 2500);

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
        vm.prank(registry);
        s.recordVoteStake(1, alice, 20_000e18);
        vm.warp(vm.getBlockTimestamp() + 1);

        // Burn fails → queued.
        bw.setBrokenMode(BURN_ADDRESS, MockBrokenWood.BrokenMode.Revert);
        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(registry);
        s.slashGuardians(1, 0, approvers, 2500);
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

    // ── C-2: maxSlashBps < 10_000 prevents pool-bricking on full slash ──

    /// @dev Deploys a fresh sWOOD proxy with `maxSlashBps = 9_999` (the new
    ///      strict cap) so the regression tests don't depend on the setUp
    ///      defaults. Returns the proxy fully wired (registry + delegation on).
    function _deploySwoodWithMaxSlash9999() internal returns (StakedWood s) {
        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    governor: address(gov),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 9999
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
        s.slashGuardians(1, 0, approvers, 9_999);

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
        s.slashGuardians(1, 0, approvers, 9_999);

        assertGt(s.unbondingPoolTokens(bob), 0, "unbondingPoolTokens > 0 after 9999 slash");
        assertGt(s.poolTokens(bob), 0, "poolTokens > 0 after 9999 slash");

        // The unbonding pool is NOT bricked: carol can still requestUnstake.
        // (Without the C-2 fix, a 100% slash would zero unbondingPoolTokens
        // and the next mulDiv(amount, uShares, unbondingPoolTokens=0) would
        // panic in requestUnstakeDelegation.)
        vm.prank(carol);
        s.requestUnstakeDelegation(bob);
    }

    /// @notice C-2: `setMaxSlashBps(10_000)` must revert with
    ///         `InvalidParameter` under the new strict cap (was accepted
    ///         previously when the check was `v > 10_000`).
    function test_C2_setMaxSlashBps_reverts_at10000() public {
        StakedWood s = _deploySwoodWithMaxSlash9999();
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        s.setMaxSlashBps(10_000);
    }

    /// @notice C-2: `initialize` with `maxSlashBps = 10_000` must revert with
    ///         `InvalidParameter` under the new strict cap.
    function test_C2_initialize_reverts_maxSlashAt10000() public {
        StakedWood impl = new StakedWood();
        bytes memory bad = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    governor: address(gov),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: 1_000e18,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000
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

        // Registry snapshots vote stake then slashes bob 99.99% (maxSlashBps).
        // Live pool: 1000 → 1000 - 999 = 1 token; shares unchanged (slash
        // dilutes via poolTokens write only).
        vm.prank(registry);
        swood.recordVoteStake(99, bob, 10_000e18);
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        swood.slashGuardians(99, 0, approvers, 9999);

        assertEq(swood.poolTokens(bob), 1, "pool tokens post-slash = 1 (dust)");
        assertEq(swood.poolShares(bob), 1000, "pool shares unchanged");

        // Alice's redeem would compute mulDiv(1, 1, 1000) = 0. Must revert.
        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeAmountZero.selector);
        swood.requestUnstakeDelegation(bob);

        // Alice's shares MUST still be live (not burned). Cancel/claim are
        // never set into the bricked state because the request reverted.
        assertEq(swood.poolShares(bob), 1000, "shares not burned by reverted request");
        assertEq(swood.unstakeDelegationRequestedAt(alice, bob), 0, "no stale request stamp");
    }

    // ── Sherlock run #3 #6: snapshot-aware own-stake slash ──

    /// @notice Pre-fix, `_slashOne` read `voteStake[pid][approver]` as
    ///         pure own stake. But the registry stores
    ///         `getPastVotes(approver, openedAt)` there (own + delegated
    ///         inbound at the openedAt snapshot). If a guardian topped up
    ///         own stake between open and slash, the clamp
    ///         `min(snapOwn, live)` picked the combined snapshot - own
    ///         stake debited for the delegated portion (effective
    ///         double-slash on the delegated contribution, since
    ///         `delSlash` also fires on `oldPool`).
    ///
    ///         Post-fix: `_slashOne` subtracts `getPastDelegatedInbound`
    ///         at openedAt from the combined snapshot so the own slash
    ///         is sized off pure own stake at open. Asserts the numerical
    ///         decomposition: own=200 at open, delegated=1000 at open,
    ///         live own (post top-up)=2000, 10% slash - own loses 20
    ///         (not 120), pool loses 100.
    function test_slashGuardians_snapshotAwareOwnSlash() public {
        // Bob is the active guardian and the delegate. Self-stakes the
        // minimum (10k) so he qualifies. Pool starts empty.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 50k to bob -> pool: 50k tok / 50k sh.
        vm.prank(alice);
        swood.delegateStake(bob, 50_000e18);

        // Snapshot the openedAt timestamp BEFORE recording vote weight.
        // Warp 1 so getPastDelegatedInbound(bob, openedAt) returns the
        // delegated state at the snap time. Mirrors registry's openReview
        // `t-1` semantics.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 openedAt = vm.getBlockTimestamp() - 1;
        uint256 delegatedAtOpen = swood.getPastDelegatedInbound(bob, openedAt);
        assertEq(delegatedAtOpen, 50_000e18, "delegated inbound snapshot");

        // Registry mirrors getPastVotes (own 10k + delegated 50k = 60k) to
        // sWOOD as the combined `voteStake` snapshot for proposal 1.
        vm.prank(registry);
        swood.recordVoteStake(1, bob, 60_000e18);

        // Bob tops up own stake 10k -> 20k between open and slash.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
        assertEq(swood.guardianStake(bob), 20_000e18, "own stake topped up");

        // Slash 10% (1000 bps).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        uint256 total = swood.slashGuardians(1, openedAt, approvers, 1000);

        // Post-fix decomposition:
        //   snapTotal = 60k, snapDelegated = 50k -> snapOwn = 10k.
        //   ownSlash = mulDiv(min(10k, 20k), 1000, 10000) = 1k.
        //   delSlash = mulDiv(oldPool=50k, 1000, 10000) = 5k.
        //   total = 6k.
        // Pre-fix: snapOwn = 60k -> ownSlash = mulDiv(min(60k, 20k), 1000, 10000) = 2k.
        //   total = 7k (over-slash on bob's own stake by 1k).
        assertEq(total, 6_000e18, "total = ownSlash(1k) + delSlash(5k)");
        assertEq(swood.guardianStake(bob), 19_000e18, "own stake = 20k - 1k (NOT 20k - 2k)");
        assertEq(swood.poolTokens(bob), 45_000e18, "pool tokens = 50k - 5k (correct)");
    }

    /// @notice Backward-compatibility: when openedAt is 0 (e.g., a synthetic
    ///         vote where `recordVoteStake` was called without a registry
    ///         `openReview` flow), `getPastDelegatedInbound(approver, 0) = 0`
    ///         and `snapOwn == snapTotal` — slash math collapses to pre-#6
    ///         behavior. This is the path most existing slashing tests take.
    function test_slashGuardians_openedAtZero_preservesPreFixBehavior() public {
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);

        vm.prank(registry);
        swood.recordVoteStake(1, alice, 20_000e18);

        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(registry);
        // openedAt = 0: snapDelegated lookup returns 0 → snapOwn = snapTotal.
        uint256 total = swood.slashGuardians(1, 0, approvers, 2500);

        assertEq(total, 5_000e18, "ownSlash = 20k * 25% = 5k (matches pre-#6)");
        assertEq(swood.guardianStake(alice), 15_000e18, "own stake reduced");
    }
}
