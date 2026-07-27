// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";

/// @dev Vault stand-in exposing the ERC20Votes reads the escrow apportions
///      against. Mirrors SyndicateVault's auto-delegated behaviour, where
///      `getPastVotes(h, t)` equals that holder's share balance at `t`.
///      Copied from `test/CompensationEscrow.t.sol` so the two suites stay
///      independently editable.
contract MockVotesVault {
    mapping(address => mapping(uint256 => uint256)) public votesAt;
    mapping(uint256 => uint256) public totalAt;

    function setVotes(address holder, uint256 ts, uint256 v) external {
        votesAt[holder][ts] = v;
    }

    function setTotal(uint256 ts, uint256 v) external {
        totalAt[ts] = v;
    }

    function getPastVotes(address holder, uint256 ts) external view returns (uint256) {
        return votesAt[holder][ts];
    }

    function getPastTotalSupply(uint256 ts) external view returns (uint256) {
        return totalAt[ts];
    }
}

/// @notice Task 4 (spec 2026-07-22 §3.8 + §4): the authorized-slasher entrypoint
///         on sWOOD. `slashToEscrow` reuses the same per-approver legs as the
///         registry-gated review slash but routes the proceeds into a
///         `CompensationEscrow` case instead of burning them.
///
///         The two slash paths stay deliberately distinct (decision D4): the
///         registry's appeal reserve is bound to the block-quorum REVIEW slash
///         only, so it can never refund a proven-malice VERDICT.
contract StakedWoodSlashToEscrowTest is Test {
    StakedWood internal swood;
    ERC20Mock internal wood;
    CompensationEscrow internal escrow;
    MockVotesVault internal vault;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFAC10);
    address internal registry = address(0x9E915);
    address internal slasher = makeAddr("slasher");
    address internal backstop = makeAddr("backstop");
    address internal g1 = makeAddr("g1");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    address internal constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @dev The verdict/review open timestamp the slash legs are sized against.
    uint256 internal openedAt;
    /// @dev The pre-drain snapshot the escrow apportions the case against.
    uint256 internal snapTs;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);

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
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(owner);
        swood.setRegistry(registry);

        // The escrow accepts case funding from sWOOD only, and sWOOD only ever
        // funds the escrow its OWNER wired — the sink is state, not an argument.
        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
        swood.setCompensationEscrow(address(escrow));
        vm.stopPrank();

        vault = new MockVotesVault();

        // A staked, matured guardian to slash.
        wood.mint(g1, 1_000_000e18);
        vm.startPrank(g1);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(20_000e18, 1);
        vm.stopPrank();

        skip(30 days);
        openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);

        // Pre-drain snapshot: alice 70%, bob 30% of a 1,000-share supply.
        snapTs = vm.getBlockTimestamp() - 1 days;
        vault.setTotal(snapTs, 1_000e18);
        vault.setVotes(alice, snapTs, 700e18);
        vault.setVotes(bob, snapTs, 300e18);
    }

    function test_setAuthorizedSlasher_onlyOwner() public {
        vm.expectRevert(); // Ownable: caller is not the owner
        swood.setAuthorizedSlasher(makeAddr("rogue"));
    }

    function test_setAuthorizedSlasher_setsRole() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        assertEq(swood.authorizedSlasher(), slasher);
    }

    function test_setCompensationEscrow_onlyOwner() public {
        vm.expectRevert(); // Ownable: caller is not the owner
        swood.setCompensationEscrow(makeAddr("rogueEscrow"));
    }

    function test_setCompensationEscrow_setsSink() public {
        address newEscrow = makeAddr("newEscrow");
        vm.prank(owner);
        swood.setCompensationEscrow(newEscrow);
        assertEq(swood.compensationEscrow(), newEscrow);
    }

    /// @notice The escrow is OWNER-SET STATE, not a caller argument. sWOOD
    ///         custodies every WOOD bond in the protocol, so a caller-named sink
    ///         would carry an allowance against that whole balance. With the
    ///         sink unset the verdict path is simply closed.
    function test_slashToEscrow_revertsWhenEscrowUnset() public {
        vm.startPrank(owner);
        swood.setAuthorizedSlasher(slasher);
        swood.setCompensationEscrow(address(0));
        vm.stopPrank();

        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(slasher);
        vm.expectRevert(IStakedWood.CompensationEscrowNotSet.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
    }

    /// @notice sWOOD must not leave a standing allowance behind: the escrow's
    ///         claim on the protocol's WOOD custody exists only for the duration
    ///         of the `openCase` call.
    function test_slashToEscrow_leavesNoStandingAllowance() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);

        assertEq(wood.allowance(address(swood), address(escrow)), 0, "allowance zeroed after the hand-off");
    }

    function test_slashToEscrow_onlySlasher() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.expectRevert(IStakedWood.NotAuthorizedSlasher.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
    }

    /// @notice The registry cannot drive the verdict path either — the roles are
    ///         separate so `refundSlash` can never reach a verdict (D4).
    function test_slashToEscrow_registryIsNotTheSlasher() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(registry);
        vm.expectRevert(IStakedWood.NotAuthorizedSlasher.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
    }

    function test_slashToEscrow_routesProceedsToEscrowNotBurn() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        (uint256 total, uint256 caseId) =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);

        assertGt(total, 0, "something was actually slashed");
        assertEq(caseId, 1, "the funded case id is returned, not scraped");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore, "verdict slash must NOT burn");
        assertEq(wood.balanceOf(address(escrow)), total, "proceeds land in the escrow");
        (address v, uint256 ts, uint256 proceeds,,,, bool swept) = escrow.caseOf(caseId);
        assertEq(v, address(vault));
        assertEq(ts, snapTs);
        assertEq(proceeds, total, "the whole slash funds the case");
        assertFalse(swept, "a fresh case is not swept");
    }

    /// @notice Plan D and indexers correlate the verdict with the case it funded
    ///         off this event, rather than scraping the escrow's own log and
    ///         guessing which slash produced it.
    function test_slashToEscrow_emitsVerdictSlashRouted() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.expectEmit(true, true, false, true, address(swood));
        emit IStakedWood.VerdictSlashRouted(bytes32("case"), address(vault), 20_000e18, 1);
        vm.prank(slasher);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
    }

    /// @notice FIX 5 / spec §3.8: the compensation snapshot must be at or before
    ///         the verdict's own open timestamp. Any legitimate PRE-drain
    ///         snapshot precedes the verdict, so this costs honest callers
    ///         nothing — but it stops a compromised `authorizedSlasher` pinning a
    ///         case to a POST-drain instant where the coalition holds the supply
    ///         and paying the attacker back its own slash.
    function test_slashToEscrow_rejectsSnapshotAfterTheVerdict() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        skip(1 hours); // so the post-verdict instant is itself safely in the past
        uint256 postVerdictTs = openedAt + 1;
        assertLt(postVerdictTs, vm.getBlockTimestamp(), "still a PAST snapshot; only the verdict bound rejects it");

        vm.prank(slasher);
        vm.expectRevert(IStakedWood.SnapshotAfterVerdict.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), postVerdictTs);
    }

    /// @notice A snapshot exactly AT the verdict open is allowed — the bound is
    ///         `<=`, not `<`.
    function test_slashToEscrow_acceptsSnapshotAtTheVerdictOpen() public {
        vault.setTotal(openedAt, 1_000e18);
        vault.setVotes(alice, openedAt, 1_000e18);

        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        (, uint256 caseId) =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), openedAt);
        (, uint256 ts,,,,,) = escrow.caseOf(caseId);
        assertEq(ts, openedAt);
    }

    /// @notice FIX 2: the verdict path enforces the SAME severity envelope as
    ///         the review path. `GuardianRegistry._severityBps` clamps to
    ///         `[minSlashBps, maxSlashBps]` before it ever reaches sWOOD;
    ///         `slashToEscrow` takes bps straight from its caller, so it clamps
    ///         here instead. Fixture: min 1000 bps, max 10_000 bps, 20k stake.
    function test_slashToEscrow_clampsSeverityToTheFloor() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        (uint256 total,) =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 1), address(vault), snapTs);
        assertEq(total, 2_000e18, "1 bps floored to minSlashBps (1000) = 10% of 20k");
    }

    function test_slashToEscrow_clampsSeverityToTheCeiling() public {
        // Lower the ceiling so a caller asking for 10_000 must be cut down.
        vm.startPrank(owner);
        swood.setMaxSlashBps(5000);
        swood.setAuthorizedSlasher(slasher);
        vm.stopPrank();

        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(slasher);
        (uint256 total,) =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
        assertEq(total, 10_000e18, "10_000 bps capped to maxSlashBps (5000) = 50% of 20k");
        assertEq(swood.guardianStake(g1), 10_000e18, "the guardian kept the half the ceiling protects");
    }

    /// @notice The verdict slash runs the SAME legs as the review path: the
    ///         guardian's own stake and the aggregate total both drop, and the
    ///         post-slash total checkpoint is re-pushed.
    function test_slashToEscrow_reusesTheReviewSlashLegs() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(slasher);
        (uint256 total,) =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, _bpsArr(gs.length, 2500), address(vault), snapTs);
        uint256 slashedAt = vm.getBlockTimestamp();

        assertEq(total, 5_000e18, "25% of the 20k own stake");
        assertEq(swood.guardianStake(g1), 15_000e18, "own stake reduced");
        assertEq(swood.totalGuardianStake(), 15_000e18, "totalGuardianStake reduced");

        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(swood.getPastTotalVotes(slashedAt), 15_000e18, "total checkpoint re-pushed");
    }

    /// @notice The review path is untouched: it still burns and still runs through
    ///         `onlyRegistry`. The two slash paths stay distinct so the registry's
    ///         refund reserve can never refund a verdict (spec §4, decision D4).
    function test_reviewPathStillBurns() public {
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(address(registry));
        uint256 total = swood.slashGuardians(bytes32("review"), openedAt, gs, 10_000);
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore + total, "review slash still burns");
        assertEq(wood.balanceOf(address(escrow)), 0, "review proceeds never reach the escrow");
        assertEq(escrow.caseCount(), 0, "review slash opens no compensation case");
    }

    /// @notice A verdict against approvers with nothing left to slash is a no-op,
    ///         not a zero-proceeds case the escrow would reject.
    function test_slashToEscrow_zeroTotalOpensNoCase() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = makeAddr("neverStaked");
        vm.prank(slasher);
        (uint256 total, uint256 caseId) =
            swood.slashToEscrow(bytes32("c"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs);
        assertEq(total, 0);
        assertEq(caseId, 0, "no case id when nothing was recovered");
        assertEq(escrow.caseCount(), 0, "no empty case opened");
    }

    /// @dev `slashToEscrow` now takes one rate per approver. These suites all
    ///      exercise the uniform case, so this fills an aligned array with a
    ///      single rate — the per-approver spread is covered in
    ///      `SlashToEscrowProportional.t.sol`.
    function _bpsArr(uint256 n, uint256 bps) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            a[i] = bps;
        }
    }
}
