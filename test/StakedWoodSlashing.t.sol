// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockBrokenWood} from "./mocks/MockBrokenWood.sol";
import {MockGovernorMinimal} from "./mocks/MockGovernorMinimal.sol";

/// @notice Slashing tests for StakedWood (sWOOD): registry-gated
///         `slashGuardians` — a SINGLE own-stake leg sized off the raw
///         own-stake checkpoint at `openedAt`, clamped to live stake.
///         DPoS delegation was removed/postponed: there are no delegated
///         pool legs and `GuardianSlashed.delegatedSlash` is always 0.
contract StakedWoodSlashingTest is Test {
    /// @dev Mirror of `StakedWood.GuardianSlashed` for `vm.expectEmit`.
    ///      `delegatedSlash` is retained in the ABI but always 0.
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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        // Registry wired so `onlyRegistry` entrypoints can be exercised.
        vm.prank(owner);
        swood.setRegistry(registry);

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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
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

    // ── maxSlashBps ceiling params ──

    /// @notice `setMaxSlashBps(10_000)` is ACCEPTED — the own-stake ceiling is
    ///         a plain integer subtraction with no share math to brick (the
    ///         C-2 pool-bricking guard left with the DPoS-delegation removal).
    function test_setMaxSlashBps_accepts_at10000() public {
        vm.prank(owner);
        swood.setMaxSlashBps(10_000);
        assertEq(swood.maxSlashBps(), 10_000, "full own-stake ceiling accepted");
    }

    /// @notice `initialize` with `maxSlashBps = 10_000` SUCCEEDS — a full-100%
    ///         own-stake ceiling is legal.
    function test_initialize_accepts_maxSlashAt10000() public {
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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        StakedWood s = StakedWood(address(new ERC1967Proxy(address(impl), initData)));
        assertEq(s.maxSlashBps(), 10_000, "full own-stake ceiling accepted at init");
    }

    // ── Sherlock run #3 #6: at-open own-stake slash basis ──

    /// @notice Sherlock run #3 #6 regression, retained under the raw-checkpoint
    ///         basis. The own slash is sized off the raw own-stake checkpoint
    ///         at `openedAt` (spec 2026-07-19 §5), so a guardian who tops up
    ///         between open and slash is NOT debited for the top-up tranche.
    ///         own=10k at open, live own (post top-up)=20k, 10% slash — own
    ///         loses 1k (not live-based 2k); the top-up tranche is untouched.
    function test_slashGuardians_snapshotAwareOwnSlash() public {
        // Bob is the active guardian. Self-stakes the minimum (10k).
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);

        // Warp 1 so the at-open reads return the state at the snap time.
        // Mirrors registry's openReview `t-1` semantics.
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 openedAt = vm.getBlockTimestamp() - 1;

        // Bob tops up own stake 10k -> 20k between open and slash.
        vm.prank(bob);
        swood.stakeAsGuardian(10_000e18, 1);
        assertEq(swood.guardianStake(bob), 20_000e18, "own stake topped up");

        // Slash 10% (1000 bps).
        address[] memory approvers = new address[](1);
        approvers[0] = bob;
        vm.prank(registry);
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), openedAt, approvers, 1000);

        // ownSlash = mulDiv(min(snap 10k, live 20k), 1000, 10_000) = 1k.
        // Live-based sizing would have given 2k (over-slash by 1k).
        assertEq(total, 1_000e18, "total = ownSlash(1k)");
        assertEq(swood.guardianStake(bob), 19_000e18, "own stake = 20k - 1k (NOT 20k - 2k)");
    }

    /// @notice Degenerate snapshot: when openedAt is 0 (no review-open
    ///         timestamp), the raw own-stake checkpoint lookup at 0 returns 0
    ///         — there is NO own-stake basis, so no own base slash and the
    ///         slash is a complete no-op. The production registry always
    ///         passes `r.openedAt` (set in `openReview`), and voters must have
    ///         weight at that instant.
    function test_slashGuardians_openedAtZero_uninformativeSnapshot() public {
        vm.prank(alice);
        swood.stakeAsGuardian(20_000e18, 1);

        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory approvers = new address[](1);
        approvers[0] = alice;
        vm.prank(registry);
        // openedAt = 0: no checkpoint at/before 0 → own basis 0 → no-op.
        uint256 total = swood.slashGuardians(bytes32(uint256(1)), 0, approvers, 2500);

        assertEq(total, 0, "no own basis at openedAt=0 -> no-op");
        assertEq(swood.guardianStake(alice), 20_000e18, "own stake untouched");
    }

    // ── Slash basis vs. age-weighted voting ──

    /// @dev Registry-pranked single-approver slash at `bps` with review-open
    ///      snapshot `openedAt`. Same-second `openedAt` lookups are
    ///      intentional: `upperLookupRecent` has no future-lookup guard, and a
    ///      checkpoint keyed `now` is visible at `now`.
    function _slash(address guardian, uint256 openedAt, uint256 bps) internal returns (uint256 total) {
        address[] memory approvers = new address[](1);
        approvers[0] = guardian;
        vm.prank(registry);
        total = swood.slashGuardians(bytes32(uint256(0x5EED)), openedAt, approvers, bps);
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

    // ── Conviction bounty cap ──────────────────────────────────────────────

    /// @dev Stakes `n` guardians of `amount` each and matures them, returning
    ///      the cohort in vote order with a full-ceiling rate apiece.
    function _cohortAt(uint256 n, uint256 amount)
        internal
        returns (address[] memory approvers, uint256[] memory bps, uint256 openedAt)
    {
        approvers = new address[](n);
        bps = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            address g = address(uint160(0x7000 + i));
            approvers[i] = g;
            bps[i] = 10_000;
            wood.mint(g, amount);
            vm.prank(g);
            wood.approve(address(swood), type(uint256).max);
            vm.prank(g);
            swood.stakeAsGuardian(amount, i + 1);
        }
        skip(30 days);
        openedAt = vm.getBlockTimestamp();
        vm.warp(openedAt + 1);
    }

    /// @notice THE SYBIL-CONTEST TRADE MUST NOT PAY. The bounty is only owed
    ///         when an APPROVER funded the counter-bond — a rule meant to price
    ///         a staged contest by forcing the stager into the cohort its own
    ///         conviction slashes. The punitive rate broke that pricing: the
    ///         bounty is a share of the WHOLE cohort's bonds while the stager
    ///         still risks only its own, so a minimum-stake attacker profited.
    ///         Capping at the contestors' summed slash restores it.
    function test_slashVerdict_bountyCappedAtContestorsOwnSlash() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(address(this));

        (address[] memory approvers, uint256[] memory bps,) = _cohortAt(5, 100_000e18);

        address sybil = address(uint160(0x7FFF));
        wood.mint(sybil, 100_000e18);
        vm.prank(sybil);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(sybil);
        swood.stakeAsGuardian(10_000e18, 99); // the minimum this fixture allows
        skip(30 days);
        uint256 anchor = vm.getBlockTimestamp();
        vm.warp(anchor + 1);

        address[] memory all = new address[](6);
        uint256[] memory allBps = new uint256[](6);
        bool[] memory contestors = new bool[](6);
        for (uint256 i = 0; i < 5; i++) {
            all[i] = approvers[i];
            allBps[i] = bps[i];
        }
        all[5] = sybil;
        allBps[5] = 10_000;
        contestors[5] = true; // ONLY the sybil funded the counter-bond

        address challenger = makeAddr("bountyChallenger");
        uint256 before = wood.balanceOf(challenger);

        // This fixture's ceiling is 9,999 bps, so every bond is taken at
        // 99.99% — derived rather than hardcoded so the numbers stay honest if
        // the envelope moves.
        uint256 ceil = swood.maxSlashBps();
        uint256 sybilSlash = 10_000e18 * ceil / 10_000;
        uint256 gross = (5 * 100_000e18 * ceil / 10_000) + sybilSlash;

        uint256 total = swood.slashVerdict(bytes32("sybil"), anchor, all, allBps, contestors, challenger, 500);

        uint256 paid = wood.balanceOf(challenger) - before;
        // Uncapped this would have paid 500 bps of the WHOLE cohort — about
        // 25,497 WOOD for the ~9,999 the sybil risked, a ~15,500 profit.
        assertGt(gross * 500 / 10_000, sybilSlash, "fixture really does expose the amplification");
        assertEq(paid, sybilSlash, "bounty capped at exactly what the lone contestor forfeited");
        assertEq(total, gross - paid, "remainder burned, net of the capped bounty");
    }

    /// @notice ...AND THE CAP MUST NOT PUNISH A GENUINE DEFENCE. When real
    ///         approvers with real bonds fund the counter-bond, their summed
    ///         slash sits far above the fee, so the cap never binds and the
    ///         honest challenger is paid in full. Summing — rather than taking
    ///         the first contestor found — is what makes this hold.
    function test_slashVerdict_bountyUncappedWhenTheDefenceIsGenuine() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(address(this));

        (address[] memory approvers, uint256[] memory bps, uint256 openedAt) = _cohortAt(5, 100_000e18);
        bool[] memory contestors = new bool[](5);
        contestors[3] = true; // two real approvers defended, and NOT the first
        contestors[4] = true;

        address challenger = makeAddr("genuineChallenger");
        uint256 before = wood.balanceOf(challenger);

        uint256 ceil = swood.maxSlashBps();
        uint256 each = 100_000e18 * ceil / 10_000;
        uint256 gross = 5 * each;
        uint256 expected = gross * 500 / 10_000;

        uint256 total = swood.slashVerdict(bytes32("genuine"), openedAt, approvers, bps, contestors, challenger, 500);

        // Two real approvers forfeited `2 * each` between them, far above the
        // fee, so the cap is nowhere near binding.
        assertGt(2 * each, expected, "fixture: a genuine defence out-stakes the fee");
        assertEq(wood.balanceOf(challenger) - before, expected, "full bounty: the cap did not bind");
        assertEq(total, gross - expected, "remainder burned");
    }
}
