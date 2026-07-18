// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {StakedWoodDelegation} from "../src/StakedWoodDelegation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";
import {RegistryTestHarness} from "./helpers/RegistryTestHarness.sol";

/// @notice Guardian-stake relocation tests for StakedWood (sWOOD).
///         Ported verbatim from `GuardianRegistryStakeTest` — the source of
///         truth for the relocated `stakeAsGuardian` logic.
contract StakedWoodTest is Test {
    StakedWood swood;
    ERC20Mock wood;
    MockGovernorMinimal gov;
    address owner = address(0xA11CE);
    address factory = address(0xFAC10);
    address alice = address(0xA11CE5);
    address bob = address(0xB0B);

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        gov = new MockGovernorMinimal();
        // StakedWood resolves the per-vault governor via factory.governorOf(vault);
        // route the codeless mock factory to the mock governor.
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)"), abi.encode(address(gov)));
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
                    maxSlashBps: 9999
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        wood.mint(alice, 100_000e18);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    function test_stakeAsGuardian_firstStake_setsStakeAndTotal() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.GuardianStaked(alice, 10_000e18, 42);
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        assertEq(swood.guardianStake(alice), 10_000e18);
        assertEq(swood.totalGuardianStake(), 10_000e18);
    }

    function test_stakeAsGuardian_topUp_accumulates_ignoresAgentIdChange() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        vm.prank(alice);
        swood.stakeAsGuardian(5_000e18, 99); // different agentId should be ignored
        assertEq(swood.guardianStake(alice), 15_000e18);
        assertEq(swood.totalGuardianStake(), 15_000e18);
    }

    function test_stakeAsGuardian_revertsIfBelowMinOnFirstStake() public {
        vm.prank(alice);
        vm.expectRevert(StakedWood.InsufficientStake.selector);
        swood.stakeAsGuardian(1, 42);
    }

    function test_stakeAsGuardian_transfersWoodFromCaller() public {
        uint256 balBefore = wood.balanceOf(alice);
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        assertEq(wood.balanceOf(alice), balBefore - 10_000e18);
        assertEq(wood.balanceOf(address(swood)), 10_000e18);
    }

    function test_stakeAsGuardian_checkpointsPastVotes() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        uint256 stakedAt = vm.getBlockTimestamp();

        // Checkpoints at t-1 are 0; warp forward so the stake checkpoint is in
        // the past relative to the read site.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastVotes(alice, stakedAt), 10_000e18);
    }

    // ── Guardian unstake cooldown (relocated from GuardianRegistry) ──

    function test_requestUnstakeGuardian_revokesVotingPowerImmediately() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();
        uint256 requestedAt = vm.getBlockTimestamp();

        assertEq(swood.totalGuardianStake(), 0);

        // Checkpoints at t-1 are 0; warp forward so the 0-checkpoint is in the
        // past relative to the read site.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastVotes(alice, requestedAt), 0);
    }

    function test_cancelUnstakeGuardian_restoresVotingPower() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.cancelUnstakeGuardian();
        uint256 cancelledAt = vm.getBlockTimestamp();

        assertEq(swood.totalGuardianStake(), 10_000e18);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastVotes(alice, cancelledAt), 10_000e18);
    }

    function test_claimUnstakeGuardian_afterCooldown_returnsWood() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        uint256 balAfterStake = wood.balanceOf(alice);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        vm.warp(vm.getBlockTimestamp() + swood.coolDownPeriod());
        vm.prank(alice);
        swood.claimUnstakeGuardian();

        assertEq(wood.balanceOf(alice), balAfterStake + 10_000e18);
        assertEq(swood.guardianStake(alice), 0);
    }

    function test_claimUnstakeGuardian_beforeCooldown_reverts() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.CooldownNotElapsed.selector);
        swood.claimUnstakeGuardian();
    }

    /// @dev Slashing isn't relocated yet (Task 5.x). Without a slash function
    ///      there is no clean way to drive a guardian to `stakedAmount == 0`
    ///      while `unstakeRequestedAt != 0` (`claimUnstakeGuardian` deletes the
    ///      struct entirely; `requestUnstakeGuardian` requires `stakedAmount`).
    ///      Port the test but skip it until slashing lands.
    function test_cancelUnstakeGuardian_afterSlash_revertsNoActiveStake() public {
        // TODO(Task 5.x): unskip once slashing is relocated into StakedWood.
        vm.skip(true);
    }

    // ── Guardian read views (relocated from GuardianRegistry, Task 2.3) ──

    function test_isActiveGuardian_trueWhenStakedAndNoPendingUnstake() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        assertTrue(swood.isActiveGuardian(alice));
    }

    function test_isActiveGuardian_falseWhenNeverStaked() public view {
        assertFalse(swood.isActiveGuardian(alice));
    }

    function test_isActiveGuardian_falseMidUnstake() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        // Stake still held in the contract, but a pending unstake request
        // makes the guardian inactive.
        assertFalse(swood.isActiveGuardian(alice));
    }

    function test_isActiveGuardian_trueAgainAfterCancelUnstake() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.cancelUnstakeGuardian();

        assertTrue(swood.isActiveGuardian(alice));
    }

    function test_getPastTotalVotes_tracksTotalGuardianStake() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        uint256 stakedAt = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalVotes(stakedAt), 10_000e18);
    }

    function test_getPastTotalVotes_zeroAfterUnstakeRequest() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeGuardian();
        uint256 requestedAt = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalVotes(requestedAt), 0);
    }

    // ── Admin setters (relocated from GuardianRegistry, Task 2.3) ──

    function test_setMinGuardianStake_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.ParameterChangeFinalized(swood.PARAM_MIN_GUARDIAN_STAKE(), 10_000e18, 20_000e18);
        vm.prank(owner);
        swood.setMinGuardianStake(20_000e18);
        assertEq(swood.minGuardianStake(), 20_000e18);
    }

    function test_setMinGuardianStake_revertsBelowFloor() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMinGuardianStake(1e18 - 1);
    }

    function test_setMinGuardianStake_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        swood.setMinGuardianStake(20_000e18);
    }

    function test_setCooldownPeriod_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.ParameterChangeFinalized(swood.PARAM_COOLDOWN(), 7 days, 10 days);
        vm.prank(owner);
        swood.setCooldownPeriod(10 days);
        assertEq(swood.coolDownPeriod(), 10 days);
    }

    function test_setCooldownPeriod_revertsOutOfBounds() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setCooldownPeriod(1 days - 1);

        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setCooldownPeriod(30 days + 1);
    }

    function test_setCooldownPeriod_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        swood.setCooldownPeriod(10 days);
    }

    /// @notice Pre-wiring guard (Sherlock #16): on a fresh sWOOD with no
    ///         `setRegistry` called, `setCooldownPeriod` enforces only the
    ///         absolute `[1 days, 30 days]` bounds — the cross-contract
    ///         `reviewPeriod` read is skipped while `registry == address(0)`.
    function test_setCooldownPeriod_worksWhenRegistryUnset() public {
        assertEq(swood.registry(), address(0));
        vm.prank(owner);
        swood.setCooldownPeriod(2 days);
        assertEq(swood.coolDownPeriod(), 2 days);
    }

    // ── Slash-bound params (Task 6.2) ──

    function test_initialize_setsSlashBounds() public view {
        assertEq(swood.minSlashBps(), 1000);
        assertEq(swood.maxSlashBps(), 9999);
    }

    function test_setMinSlashBps_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.ParameterChangeFinalized(swood.PARAM_MIN_SLASH_BPS(), 1000, 2000);
        vm.prank(owner);
        swood.setMinSlashBps(2000);
        assertEq(swood.minSlashBps(), 2000);
    }

    function test_setMinSlashBps_revertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMinSlashBps(10000); // > maxSlashBps (9999) — C-2 strict cap
    }

    function test_setMinSlashBps_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        swood.setMinSlashBps(2000);
    }

    function test_setMaxSlashBps_updatesAndEmits() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.ParameterChangeFinalized(swood.PARAM_MAX_SLASH_BPS(), 9999, 8000);
        vm.prank(owner);
        swood.setMaxSlashBps(8000);
        assertEq(swood.maxSlashBps(), 8000);
    }

    function test_setMaxSlashBps_revertsBelowMin() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMaxSlashBps(999); // < minSlashBps (1000)
    }

    function test_setMaxSlashBps_revertsAbove10000() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMaxSlashBps(10001);
    }

    /// @notice C-2: the strict cap rejects `10_000` exactly — a 100% slash
    ///         would zero `poolTokens` and brick subsequent `delegateStake`.
    function test_setMaxSlashBps_revertsAt10000() public {
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMaxSlashBps(10000);
    }

    function test_setMaxSlashBps_revertsIfNotOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        swood.setMaxSlashBps(8000);
    }

    function test_initialize_revertsIfMinSlashAboveMax() public {
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
                    minSlashBps: 6000,
                    maxSlashBps: 5000
                }))
        );
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), bad);
    }

    function test_initialize_revertsIfMaxSlashAbove10000() public {
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
                    maxSlashBps: 10001
                }))
        );
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), bad);
    }

    /// @notice C-2: strict cap rejects `maxSlashBps == 10_000` at init.
    function test_initialize_revertsIfMaxSlashEquals10000() public {
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
                    maxSlashBps: 10000
                }))
        );
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        new ERC1967Proxy(address(impl), bad);
    }

    // ── Owner-bond prepare/bind (relocated from GuardianRegistry, Task 3.1) ──

    function test_prepareOwnerStake_escrowsWood() public {
        uint256 balBefore = wood.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit StakedWood.OwnerStakePrepared(alice, 1_000e18);
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        assertEq(swood.preparedStakeOf(alice), 1_000e18);
        assertEq(wood.balanceOf(alice), balBefore - 1_000e18);
        assertEq(wood.balanceOf(address(swood)), 1_000e18);
        assertTrue(swood.canCreateVault(alice));
    }

    function test_prepareOwnerStake_revertsBelowMinOwnerStake() public {
        vm.prank(alice);
        vm.expectRevert(StakedWood.InsufficientStake.selector);
        swood.prepareOwnerStake(1_000e18 - 1);
    }

    function test_prepareOwnerStake_revertsIfAlreadyPrepared() public {
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        vm.prank(alice);
        vm.expectRevert(StakedWood.PreparedStakeAlreadyExists.selector);
        swood.prepareOwnerStake(1_000e18);
    }

    function test_cancelPreparedStake_refunds() public {
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);
        uint256 balAfterPrepare = wood.balanceOf(alice);

        vm.expectEmit(true, false, false, true);
        emit StakedWood.PreparedStakeCancelled(alice, 1_000e18);
        vm.prank(alice);
        swood.cancelPreparedStake();

        assertEq(swood.preparedStakeOf(alice), 0);
        assertEq(wood.balanceOf(alice), balAfterPrepare + 1_000e18);
    }

    function test_bindOwnerStake_consumesPreparedStake() public {
        address vault = address(0xBEEF);

        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerStakeBound(alice, vault, 1_000e18);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);

        assertEq(swood.ownerStake(vault), 1_000e18);
        // Prepared slot consumed (bound) — re-prepare now allowed.
        assertFalse(swood.canCreateVault(alice));
    }

    function test_cancelPreparedStake_revertsIfNoPreparedStake() public {
        // Empty slot — caller never prepared anything.
        vm.prank(alice);
        vm.expectRevert(StakedWood.PreparedStakeNotFound.selector);
        swood.cancelPreparedStake();
    }

    function test_bindOwnerStake_revertsIfBelowRaisedMinOwnerStake() public {
        address vault = address(0xBEEF);

        // Prepare at the current floor (1_000e18).
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        // Owner raises the floor above the prepared amount before the bind.
        vm.prank(owner);
        swood.setMinOwnerStake(2_000e18);

        vm.prank(factory);
        vm.expectRevert(StakedWood.OwnerBondInsufficient.selector);
        swood.bindOwnerStake(alice, vault);
    }

    function test_bindOwnerStake_revertsIfNotFactory() public {
        address vault = address(0xBEEF);

        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        // Access control: only the factory may write owner bonds.
        vm.prank(alice);
        vm.expectRevert(StakedWood.NotFactory.selector);
        swood.bindOwnerStake(alice, vault);
    }

    // ── Owner-bond unstake / transfer / requiredOwnerBond (Task 3.2) ──

    /// @dev Helper: prepare alice's stake and bind it to `vault`.
    function _bindAliceTo(address vault) internal {
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);
    }

    function test_requestUnstakeOwner_stampsUnstakeRequest() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.expectEmit(true, false, false, true);
        emit StakedWood.OwnerUnstakeRequested(vault, vm.getBlockTimestamp());
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
    }

    function test_requestUnstakeOwner_revertsWhenOpenProposalCount() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        gov.setOpenProposalCount(vault, 1);

        vm.prank(alice);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(vault);
    }

    function test_requestUnstakeOwner_revertsWhenActiveProposal() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        gov.setActiveProposal(vault, 7);

        vm.prank(alice);
        vm.expectRevert(StakedWood.VaultHasActiveProposal.selector);
        swood.requestUnstakeOwner(vault);
    }

    function test_requestUnstakeOwner_revertsIfNotOwner() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.prank(address(0xBAD));
        vm.expectRevert(StakedWoodDelegation.NoActiveStake.selector);
        swood.requestUnstakeOwner(vault);
    }

    function test_requestUnstakeOwner_revertsIfAlreadyRequested() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeAlreadyRequested.selector);
        swood.requestUnstakeOwner(vault);
    }

    function test_claimUnstakeOwner_afterCooldown_returnsWoodAndClearsSlot() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);
        uint256 balAfterBind = wood.balanceOf(alice);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        vm.warp(vm.getBlockTimestamp() + swood.coolDownPeriod());

        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerUnstakeClaimed(vault, alice, 1_000e18);
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);

        assertEq(wood.balanceOf(alice), balAfterBind + 1_000e18);
        assertEq(swood.ownerStake(vault), 0);
    }

    function test_claimUnstakeOwner_beforeCooldown_reverts() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.CooldownNotElapsed.selector);
        swood.claimUnstakeOwner(vault);
    }

    function test_claimUnstakeOwner_revertsIfNoUnstakeRequested() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWoodDelegation.UnstakeNotRequested.selector);
        swood.claimUnstakeOwner(vault);
    }

    function test_transferOwnerStakeSlot_revertsWhenPriorStakeNotCleared() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        address newOwner = address(0xC0FFEE);
        wood.mint(newOwner, 10_000e18);
        vm.prank(newOwner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(newOwner);
        swood.prepareOwnerStake(1_000e18);

        vm.prank(factory);
        vm.expectRevert(StakedWood.PriorStakeNotCleared.selector);
        swood.transferOwnerStakeSlot(vault, newOwner);
    }

    function test_transferOwnerStakeSlot_succeedsWhenStakeCleared() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        // Old owner fully exits the slot.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.warp(vm.getBlockTimestamp() + swood.coolDownPeriod());
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);
        assertEq(swood.ownerStake(vault), 0);

        // New owner prepares a fresh bond and the factory re-points the slot.
        address newOwner = address(0xC0FFEE);
        wood.mint(newOwner, 10_000e18);
        vm.prank(newOwner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(newOwner);
        swood.prepareOwnerStake(1_000e18);

        // `claimUnstakeOwner` deleted `_ownerStakes[vault]`, so `existing.owner`
        // is zero by the time the slot is re-pointed — `oldOwner` is address(0).
        vm.expectEmit(true, true, true, false);
        emit StakedWood.OwnerStakeSlotTransferred(vault, address(0), newOwner);
        vm.prank(factory);
        swood.transferOwnerStakeSlot(vault, newOwner);

        assertEq(swood.ownerStake(vault), 1_000e18);
        assertFalse(swood.canCreateVault(newOwner));
    }

    function test_transferOwnerStakeSlot_revertsIfNotFactory() public {
        address vault = address(0xBEEF);
        _bindAliceTo(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWood.NotFactory.selector);
        swood.transferOwnerStakeSlot(vault, address(0xC0FFEE));
    }

    function test_requiredOwnerBond_returnsMinOwnerStakeFloor() public {
        address vault = address(0xBEEF);
        assertEq(swood.requiredOwnerBond(vault), swood.minOwnerStake());

        vm.prank(owner);
        swood.setMinOwnerStake(2_000e18);
        assertEq(swood.requiredOwnerBond(vault), 2_000e18);
    }

    // ── getPastVotes: own stake + delegated inbound (Task 4.5) ──

    function test_getPastVotes_includesDelegatedInbound() public {
        // Bob self-stakes 10k as an active guardian (so he can be a delegate).
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 to bob.
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        uint256 ts = vm.getBlockTimestamp();

        // Warp forward so the checkpoints are in the past relative to the read.
        vm.warp(vm.getBlockTimestamp() + 1);

        // Votes = own stake (10k) + delegated inbound (300).
        assertEq(swood.getPastDelegatedInbound(bob, ts), 300e18);
        assertEq(swood.getPastVotes(bob, ts), 10_000e18 + 300e18);
    }

    function test_getPastVotes_ownStakeOnlyWhenNoInboundDelegation() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        uint256 ts = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1);

        // No inbound delegation — votes equal own stake exactly.
        assertEq(swood.getPastDelegatedInbound(alice, ts), 0);
        assertEq(swood.getPastVotes(alice, ts), 10_000e18);
    }

    function test_getPastVotes_afterUnstakeRequest_returnsDelegatedOnly() public {
        // Bob self-stakes 10k as an active guardian (so he can be a delegate).
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 to bob.
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);

        // Bob requests to unstake — zeroes his own-stake checkpoint.
        vm.prank(bob);
        swood.requestUnstakeGuardian();

        // Warp forward so the unstake-request checkpoint is in the past.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 ts = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Own-stake term is 0 after the unstake request; delegated inbound
        // (300) is independent and survives.
        assertEq(swood.getPastVotes(bob, ts), 300e18);
    }

    // ── getVotes: current vote weight (Snapshot-compatible read surface) ──

    function test_getVotes_returnsOwnPlusDelegatedAtCurrentMoment() public {
        // Bob self-stakes 10k as an active guardian (so he can be a delegate).
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 to bob.
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);

        // Current votes = own stake (10k) + delegated inbound (300).
        assertEq(swood.getVotes(bob), 10_000e18 + 300e18);

        // After a warp, the live read equals the historical read at that ts.
        uint256 ts = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getVotes(bob), swood.getPastVotes(bob, ts));
    }

    function test_getVotes_ownTermZeroAfterUnstakeRequest() public {
        // Bob self-stakes 10k as an active guardian (so he can be a delegate).
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice delegates 300 to bob.
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);

        // Bob requests to unstake — own votable stake drops to 0.
        vm.prank(bob);
        swood.requestUnstakeGuardian();
        uint256 ts = vm.getBlockTimestamp();

        // Own term is 0; delegated inbound (300) is independent and survives.
        assertEq(swood.getVotes(bob), 300e18);

        // Consistent with the historical read at the same instant.
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getVotes(bob), swood.getPastVotes(bob, ts));
    }

    // ── getPastTotalSupply: system-wide vote denominator ──

    function test_getPastTotalSupply_equalsTotalVotesPlusTotalDelegated() public {
        // Bob self-stakes 10k as an active guardian (so he can be a delegate).
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Alice stakes her own 10k and delegates 300 to bob.
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        vm.prank(owner);
        swood.setDelegationEnabled(true);
        vm.prank(alice);
        swood.delegateStake(bob, 300e18);
        uint256 ts = vm.getBlockTimestamp();

        vm.warp(vm.getBlockTimestamp() + 1);

        // Total supply = own-stake total + delegated total.
        assertEq(swood.getPastTotalSupply(ts), swood.getPastTotalVotes(ts) + swood.getPastTotalDelegated(ts));
        assertEq(swood.getPastTotalSupply(ts), 20_000e18 + 300e18);
    }

    function test_getPastTotalSupply_readsHistoricalValue() public {
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);
        uint256 t0 = vm.getBlockTimestamp();

        // A later stake must not change the read at t0.
        vm.warp(vm.getBlockTimestamp() + 100);
        wood.mint(bob, 100_000e18);
        vm.prank(bob);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(bob);
        swood.stakeAsGuardian(20_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalSupply(t0), 10_000e18, "t0 read unaffected by later stake");
        assertEq(swood.getPastTotalSupply(vm.getBlockTimestamp() - 1), 30_000e18, "current read includes both");
    }

    // ── boundary cases: zero delegation / empty history ──

    function test_getVotes_ownStakeOnlyWhenNoInboundDelegation() public {
        // Alice self-stakes 10k with no inbound delegation.
        vm.prank(alice);
        swood.stakeAsGuardian(10_000e18, 42);

        // Votes = own stake only; the delegated term is 0 (not a revert).
        assertEq(swood.getVotes(alice), 10_000e18);
    }

    function test_getVotes_zeroWhenNoStakeOrDelegation() public {
        // Bob has neither own stake nor inbound delegation.
        assertEq(swood.getVotes(bob), 0);
    }

    function test_getPastTotalSupply_zeroBeforeAnyStakeOrDelegation() public {
        // Read at a timestamp before any stake/delegation occurred.
        uint256 ts = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalSupply(ts), 0);
    }

    // ── Zero owner-bond onboarding (minOwnerStake == 0) ──

    /// @notice `setMinOwnerStake(0)` is the deliberate open-onboarding sentinel
    ///         and must be settable on a live proxy; any NONZERO value below the
    ///         1_000 WOOD floor is still rejected.
    function test_setMinOwnerStake_permitsZeroButFloorsNonzero() public {
        vm.expectEmit(true, false, false, true);
        emit StakedWood.ParameterChangeFinalized(swood.PARAM_MIN_OWNER_STAKE(), 1_000e18, 0);
        vm.prank(owner);
        swood.setMinOwnerStake(0);
        assertEq(swood.minOwnerStake(), 0);

        // A nonzero dust value below the floor is still rejected.
        vm.prank(owner);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.setMinOwnerStake(999e18);
    }

    /// @notice Test 1: with `minOwnerStake == 0`, a creator holding 0 WOOD who
    ///         never prepared can be bound to a vault. `canCreateVault` (the
    ///         factory's gate) passes and `bindOwnerStake` records a zero bond
    ///         with the creator as owner — the sole blocker was `bindOwnerStake`.
    function test_bindOwnerStake_zeroBond_neverPreparedCreator() public {
        address vault = address(0xBEEF);
        address poorCreator = address(0xDEAD0);

        vm.prank(owner);
        swood.setMinOwnerStake(0);

        // Never prepared, holds no WOOD — the factory gate still passes at floor 0.
        assertEq(swood.preparedStakeOf(poorCreator), 0);
        assertTrue(swood.canCreateVault(poorCreator));

        // Bind via the factory-authorized path; owner topic proves the creator
        // was recorded as the vault owner.
        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerStakeBound(poorCreator, vault, 0);
        vm.prank(factory);
        swood.bindOwnerStake(poorCreator, vault);

        assertEq(swood.ownerStake(vault), 0);
    }

    /// @notice Test 1 (cont.): one 0-WOOD creator can open MULTIPLE zero-bond
    ///         vaults — the prepared slot stays {0, unbound}, so `canCreateVault`
    ///         remains true. Accepted / expected behavior at floor 0.
    function test_bindOwnerStake_zeroBond_creatorCanOpenMultipleVaults() public {
        vm.prank(owner);
        swood.setMinOwnerStake(0);

        vm.prank(factory);
        swood.bindOwnerStake(alice, address(0xBEE1));
        vm.prank(factory);
        swood.bindOwnerStake(alice, address(0xBEE2));

        assertEq(swood.ownerStake(address(0xBEE1)), 0);
        assertEq(swood.ownerStake(address(0xBEE2)), 0);
        assertTrue(swood.canCreateVault(alice));
    }

    /// @notice Test 2: at a zero bond the emergency-settle bond re-check in
    ///         `GovernorEmergency.emergencySettleWithCalls` — `ownerStake(vault)
    ///         < requiredOwnerBond(vault)` (GovernorEmergency.sol:78) — evaluates
    ///         `0 < 0`, i.e. FALSE, so the guard passes (does not revert).
    function test_zeroBond_emergencySettleBondRecheckPasses() public {
        address vault = address(0xBEEF);

        vm.prank(owner);
        swood.setMinOwnerStake(0);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);

        assertEq(swood.ownerStake(vault), 0);
        assertEq(swood.requiredOwnerBond(vault), 0);
        // The exact boolean the guard evaluates — must be false at zero bond.
        assertFalse(swood.ownerStake(vault) < swood.requiredOwnerBond(vault));
    }

    /// @notice Test 3: `slashOwnerBond` on a zero-bond vault is a no-op — early
    ///         return on `amount == 0`, no revert, nothing burned.
    function test_zeroBond_slashOwnerBondIsNoop() public {
        address vault = address(0xBEEF);
        address regMock = address(0x9E515);

        vm.prank(owner);
        swood.setMinOwnerStake(0);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);

        // Wire a registry so the onlyRegistry gate resolves, then slash as it.
        vm.prank(owner);
        swood.setRegistry(regMock);

        uint256 swoodBalBefore = wood.balanceOf(address(swood));
        vm.prank(regMock);
        swood.slashOwnerBond(vault); // must not revert

        assertEq(swood.ownerStake(vault), 0);
        assertEq(swood.pendingBurn(), 0, "nothing queued for burn");
        assertEq(wood.balanceOf(address(swood)), swoodBalBefore, "no WOOD moved");
    }

    /// @notice Test 4: with `minOwnerStake == 0` a creator who DID prepare a
    ///         nonzero stake binds that exact amount and consumes the slot —
    ///         the nonzero path is preserved even at floor 0.
    function test_bindOwnerStake_zeroFloor_honorsNonzeroPreparedStake() public {
        address vault = address(0xBEEF);

        // Alice prepares 1_000 WOOD at the current (nonzero) floor.
        vm.prank(alice);
        swood.prepareOwnerStake(1_000e18);

        // Owner then drops the floor to 0 (open onboarding) BEFORE the bind.
        vm.prank(owner);
        swood.setMinOwnerStake(0);

        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerStakeBound(alice, vault, 1_000e18);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);

        // Prepared amount honored; slot marked bound (canCreateVault false).
        assertEq(swood.ownerStake(vault), 1_000e18);
        assertFalse(swood.canCreateVault(alice));

        // Owner field recorded correctly: alice (not a stranger) can start the
        // owner-unstake flow on her nonzero bond.
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
    }
}

/// @notice Sherlock #16 — `coolDownPeriod >= reviewPeriod` cross-contract
///         invariant on `StakedWood.setCooldownPeriod`. Uses the wired
///         harness (sWOOD ↔ registry) so the cross-call to
///         `registry.reviewPeriod()` resolves.
contract StakedWoodCooldownInvariantTest is RegistryTestHarness {
    function setUp() public {
        // Harness wires sWOOD (cooldown = 7 days) and registry. Set an
        // explicit review period within the [6h, 7d] absolute bound.
        _deployRegistryAndSwood(2 days, 3000);
    }

    /// @notice `setCooldownPeriod` reverts when `v < reviewPeriod` — a cooldown
    ///         shorter than the review window would let an approver unstake
    ///         and escape the slash before `resolveReview`.
    function test_setCooldownPeriod_revertsBelowReviewPeriod() public {
        assertEq(registry.reviewPeriod(), 2 days);
        vm.prank(regOwner);
        vm.expectRevert(StakedWood.CooldownBelowReviewPeriod.selector);
        swood.setCooldownPeriod(1 days);
    }

    /// @notice `setCooldownPeriod` succeeds when `v >= reviewPeriod`.
    function test_setCooldownPeriod_succeedsAtOrAboveReviewPeriod() public {
        vm.startPrank(regOwner);
        swood.setCooldownPeriod(2 days);
        assertEq(swood.coolDownPeriod(), 2 days);
        swood.setCooldownPeriod(10 days);
        assertEq(swood.coolDownPeriod(), 10 days);
        vm.stopPrank();
    }
}
