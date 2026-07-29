// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../src/StakedWood.sol";
import {IStakedWood} from "../src/interfaces/IStakedWood.sol";
import {CompensationEscrow} from "../src/CompensationEscrow.sol";
import {ICompensationEscrow} from "../src/interfaces/ICompensationEscrow.sol";
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
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
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

        // N-4: `slashToEscrow` asserts `governorOf(vault) != 0`. The fixture
        // factory is codeless, so give it a byte of code and a wildcard mock —
        // membership itself is pinned by the dedicated rejection test, which
        // overrides this with an exact-calldata zero.
        vm.etch(factory, hex"00");
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)"), abi.encode(makeAddr("gov")));

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
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
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
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );

        assertEq(wood.allowance(address(swood), address(escrow)), 0, "allowance zeroed after the hand-off");
    }

    function test_slashToEscrow_onlySlasher() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.expectRevert(IStakedWood.NotAuthorizedSlasher.selector);
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
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
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
    }

    /// @notice N-4 (PR #24 round 4): the vault must be factory-deployed. The
    ///         escrow apportions against the vault's checkpoints, and every
    ///         claim about that population assumes OZ semantics — so a vault
    ///         the factory does not recognise is refused BEFORE any stake
    ///         moves, converting the F-A natspec's scoping sentence into code.
    function test_slashToEscrow_rejectsAFactoryUnknownVault() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        // Exact-calldata mock overrides the fixture's wildcard: this vault
        // resolves to no governor.
        address strangerVault = makeAddr("strangerVault");
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)", strangerVault), abi.encode(address(0)));

        address[] memory gs = new address[](1);
        gs[0] = g1;
        uint256 stakeBefore = swood.guardianStake(g1);

        uint256[] memory bps = _bpsArr(gs.length, 10_000);
        vm.prank(slasher);
        vm.expectRevert(StakedWood.VaultNotFactoryDeployed.selector);
        swood.slashToEscrow(bytes32("stranger"), openedAt, gs, bps, strangerVault, snapTs, address(0), 0);

        assertEq(swood.guardianStake(g1), stakeBefore, "nothing was slashed for an unknown vault");
        assertFalse(swood.verdictSlashed(bytes32("stranger"), g1), "and the verdict mark stays clean");
    }

    function test_slashToEscrow_routesProceedsToEscrowNotBurn() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        (uint256 total, uint256 caseId) = swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );

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
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
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
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), postVerdictTs, address(0), 0
        );
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
        (, uint256 caseId) = swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), openedAt, address(0), 0
        );
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
        (uint256 total,) = swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 1), address(vault), snapTs, address(0), 0
        );
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
        (uint256 total,) = swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
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
        (uint256 total,) = swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 2500), address(vault), snapTs, address(0), 0
        );
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
        (uint256 total, uint256 caseId) = swood.slashToEscrow(
            bytes32("c"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
        assertEq(total, 0);
        assertEq(caseId, 0, "no case id when nothing was recovered");
        assertEq(escrow.caseCount(), 0, "no empty case opened");
    }

    /// @notice PR #24 review F-C: a slash that recovers NOTHING must not
    ///         consume the verdict's one slash. Conviction A empties the
    ///         guardian; conviction B then lands on zero live stake and takes
    ///         nothing — if that no-op wrote `_verdictSlashed`, B would be
    ///         permanently foreclosed and a re-staked guardian could never be
    ///         held to it, even though B's at-open basis is intact and a retry
    ///         WOULD recover.
    function test_slashToEscrow_zeroRecoveryDoesNotConsumeTheVerdict() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        // Conviction A takes the whole bond.
        vm.prank(slasher);
        (uint256 totalA,) = swood.slashToEscrow(
            bytes32("A"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
        assertEq(totalA, 20_000e18, "A emptied the guardian");
        assertEq(swood.guardianStake(g1), 0);

        // Conviction B, independent verdict, same at-open basis: recovers
        // nothing — and must NOT be marked as slashed.
        vm.prank(slasher);
        (uint256 totalB, uint256 caseB) = swood.slashToEscrow(
            bytes32("B"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
        assertEq(totalB, 0);
        assertEq(caseB, 0);
        assertFalse(swood.verdictSlashed(bytes32("B"), g1), "a zero take must not consume the one slash");

        // The guardian re-stakes; retrying B now recovers against the intact
        // at-open basis instead of reverting ApproverAlreadySlashed.
        vm.prank(g1);
        swood.stakeAsGuardian(20_000e18, 1);
        vm.prank(slasher);
        (uint256 totalRetry, uint256 caseRetry) = swood.slashToEscrow(
            bytes32("B"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, address(0), 0
        );
        assertGt(totalRetry, 0, "the retried verdict recovers");
        assertGt(caseRetry, 0, "and funds a case");
        assertTrue(swood.verdictSlashed(bytes32("B"), g1), "the landed slash is what consumes the verdict");
    }

    /// @notice AN UNSTAKE REQUEST IS NOT A DISCHARGE. `requestUnstakeGuardian`
    ///         revokes VOTING POWER; it does not settle what the guardian
    ///         already underwrote, and the WOOD is still in this contract.
    ///
    ///         PR #25 review 🔴F1b. F1 moved the slash basis from `filedAt` to
    ///         `executedAt` so an accused approver could not zero its own basis
    ///         AFTER being accused. A deliberately malicious approver does not
    ///         need to react, though — it can pre-position before the drain it
    ///         voted for ever lands: approve while active, queue the exit, let
    ///         the proposal execute. Every basis at or after `executedAt` then
    ///         reads the request's zero checkpoint, and a 100% conviction
    ///         recovers nothing while the full bond sits in custody waiting for
    ///         the freeze to lift.
    ///
    ///         The divergence that makes it work: `ExposureLedger`'s coverage
    ///         gate prices the bond off live `guardianStake()`, which a request
    ///         does not touch, so quorum still passes at execution — while
    ///         `_slashOne` prices it off the checkpoint trace, which the request
    ///         zeroes. Liability and votability are two different questions and
    ///         must not share one trace.
    function test_slashToEscrow_unstakeRequestBeforeOpenDoesNotZeroTheBasis() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        // The approver queues its exit BEFORE the proposal it approved executes.
        vm.prank(g1);
        swood.requestUnstakeGuardian();

        // Voting power is gone, as intended — but the bond has not moved.
        assertEq(swood.guardianStake(g1), 20_000e18, "the WOOD is still in custody");

        // The drain executes AFTER the request, so `executedAt` sits on the far
        // side of the zero checkpoint.
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 drainOpenedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);

        uint256 drainSnapTs = drainOpenedAt - 1;
        vault.setTotal(drainSnapTs, 1_000e18);
        vault.setVotes(alice, drainSnapTs, 1_000e18);

        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(slasher);
        (uint256 slashed, uint256 caseId) = swood.slashToEscrow(
            bytes32("preExit"),
            drainOpenedAt,
            gs,
            _bpsArr(gs.length, 10_000),
            address(vault),
            drainSnapTs,
            address(0),
            0
        );

        assertEq(slashed, 20_000e18, "a 100% conviction takes the whole bond");
        assertEq(swood.guardianStake(g1), 0, "nothing left to walk out with");
        assertGt(caseId, 0, "and the victims get a funded case");
    }

    /// @notice The other half of the same invariant: a request must still stop
    ///         the stake from counting toward VOTING weight at `openedAt`. The
    ///         liability trace is additional to the votable trace, not a
    ///         replacement for it.
    function test_getPastStake_stillZeroAfterAnUnstakeRequest() public {
        vm.prank(g1);
        swood.requestUnstakeGuardian();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 1);

        assertEq(swood.getPastVotes(g1, t), 0, "unstake-requested stake is not votable");
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

    /// @notice Task 1 (spec 2026-07-29 §2): conviction bounty. A slice of a
    ///         verdict slash paid to the challenger who caused it, so a
    ///         correct-but-unanswered challenge does not just lose 20% of its
    ///         bond with nobody outside the drained vault having any reason to
    ///         watch. Reuses this file's exact slash fixture (g1's full
    ///         20,000e18 stake, 100% conviction) so the gross recovery is a
    ///         known constant and the bounty math is checkable independently
    ///         of what `slashToEscrow` returns.
    function test_slashToEscrow_paysBountyAndNetsTheEscrowCase() public {
        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);

        (uint256 total, uint256 caseId) = _slashWithBounty(challenger, 500);

        // 100% conviction against the 20,000e18 fixture stake is the GROSS
        // recovery; 500 bps of that is what the challenger is owed. `total`
        // is NET of the bounty (see IStakedWood.slashToEscrow) — it is the
        // figure `forceApprove`/`openCase` actually hand the escrow — so it is
        // gross minus the bounty, not the bounty's own denominator.
        uint256 gross = 20_000e18;
        uint256 expectedBounty = gross * 500 / 10_000;
        assertGt(expectedBounty, 0, "fixture must produce a non-trivial bounty");
        assertEq(wood.balanceOf(challenger) - before, expectedBounty, "challenger paid the bounty");
        assertEq(total, gross - expectedBounty, "returned total is NET of the bounty");
        assertEq(_caseProceeds(caseId), total, "case proceeds equal the net total routed to escrow");
    }

    function test_slashToEscrow_zeroBpsPaysNothing() public {
        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);
        (uint256 total, uint256 caseId) = _slashWithBounty(challenger, 0);
        assertEq(wood.balanceOf(challenger), before, "no bounty at 0 bps");
        assertEq(total, 20_000e18, "0 bps takes nothing: total is the full gross recovery");
        assertEq(_caseProceeds(caseId), total, "full proceeds to the escrow");
    }

    function test_slashToEscrow_zeroRecipientPaysNothing() public {
        (uint256 total, uint256 caseId) = _slashWithBounty(address(0), 500);
        assertEq(total, 20_000e18, "no recipient: total is the full gross recovery");
        assertEq(_caseProceeds(caseId), total, "full proceeds when there is no recipient");
    }

    /// @dev Thin wrapper around the file's slash fixture: sets up the
    ///      slasher role and forwards the two new bounty args against g1's
    ///      full 20,000e18 stake at 100% conviction. Does not invent a
    ///      parallel fixture — same `openedAt`/`snapTs`/`vault` every other
    ///      test in this file uses.
    function _slashWithBounty(address bountyTo, uint256 bountyBps) internal returns (uint256 total, uint256 caseId) {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.prank(slasher);
        (total, caseId) = swood.slashToEscrow(
            bytes32("bountyCase"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, bountyTo, bountyBps
        );
    }

    /// @dev The escrow test double has no `caseProceeds` getter — read the
    ///      case the way every existing assertion in this file does, via
    ///      `caseOf`'s tuple.
    function _caseProceeds(uint256 caseId) internal view returns (uint256 proceeds) {
        (,, proceeds,,,,) = escrow.caseOf(caseId);
    }

    /// @notice 2026-07-29 review: `bountyBps` must be bounded IN sWOOD, not
    ///         only in whatever calls it. Without this, a compromised or
    ///         merely buggy `authorizedSlasher` could pass `bountyBps = 9_999`
    ///         and route almost the entire slash to an address of its own
    ///         choosing — exactly the outcome `compensationEscrow`'s natspec
    ///         says sWOOD does not allow.
    function test_slashToEscrow_bountyBpsAboveMaxReverts() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        // Hoisted BEFORE the prank/expectRevert pair: a call in ARGUMENT
        // position (`swood.MAX_CONVICTION_BOUNTY_BPS()`, `makeAddr(...)`)
        // would otherwise be evaluated first and consume the one-shot
        // `vm.expectRevert`/`vm.prank`, so the actual `slashToEscrow` call
        // would run unpranked and unchecked.
        address challenger = makeAddr("challenger");
        uint256 tooHigh = swood.MAX_CONVICTION_BOUNTY_BPS() + 1;

        vm.prank(slasher);
        vm.expectRevert(StakedWood.InvalidParameter.selector);
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, challenger, tooHigh
        );
    }

    /// @notice The ceiling itself is a legal rate, not an off-by-one trap.
    function test_slashToEscrow_bountyBpsAtMaxSucceeds() public {
        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);
        uint256 maxBps = swood.MAX_CONVICTION_BOUNTY_BPS();

        (uint256 total, uint256 caseId) = _slashWithBounty(challenger, maxBps);

        uint256 gross = 20_000e18;
        uint256 expectedBounty = gross * maxBps / 10_000;
        assertGt(expectedBounty, 0, "fixture must produce a non-trivial bounty at the ceiling");
        assertEq(wood.balanceOf(challenger) - before, expectedBounty, "the ceiling rate is honoured in full");
        assertEq(total, gross - expectedBounty, "total nets the max bounty");
        assertEq(_caseProceeds(caseId), total, "escrow gets the rest");
    }

    /// @notice Mutation kill: `if (bounty != 0)` must survive. A `total` small
    ///         enough that `total * bountyBps / 10_000` floors to zero must
    ///         emit NO `ConvictionBountyPaid` and hand the escrow the whole
    ///         (unreduced) recovery — not a phantom zero-value transfer.
    ///
    ///         Getting a wei-scale `total` out of a 20,000e18 fixture stake
    ///         needs the stake itself driven down to a wei-scale remainder
    ///         first: repeatedly convict g1 at 99.99% under FRESH `caseKey`s
    ///         (the per-verdict dedup is keyed by caseKey, not by approver
    ///         alone, so re-convicting the same guardian under a new key is
    ///         legal) until what is left is small enough that ANY nonzero
    ///         `bountyBps` floors to a zero bounty by integer division.
    function test_slashToEscrow_tinyTotalFloorsBountyToZero() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;
        uint256[] memory drainBps = _bpsArr(gs.length, 9_999);

        uint256 round;
        while (swood.guardianStake(g1) >= 10_000) {
            vm.prank(slasher);
            swood.slashToEscrow(
                keccak256(abi.encodePacked("drain", round)),
                openedAt,
                gs,
                drainBps,
                address(vault),
                snapTs,
                address(0),
                0
            );
            round++;
        }

        uint256 remainder = swood.guardianStake(g1);
        assertGt(remainder, 0, "fixture sanity: some dust must remain to convict");
        assertLt(remainder * 1, 10_000, "fixture sanity: even the smallest nonzero bps must floor to 0 on this dust");

        address challenger = makeAddr("challenger");
        uint256 before = wood.balanceOf(challenger);

        vm.recordLogs();
        vm.prank(slasher);
        (uint256 total, uint256 caseId) = swood.slashToEscrow(
            bytes32("tiny"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), snapTs, challenger, 1
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(total, remainder, "the whole dust remainder is recovered");
        assertEq(wood.balanceOf(challenger), before, "bounty floored to 0: no transfer despite bountyBps != 0");
        assertEq(_caseProceeds(caseId), total, "escrow gets the WHOLE (un-bountied) recovery");
        // Balance-equality alone survives a mutation that drops the
        // `if (bounty != 0)` guard: a zero-value `safeTransfer` moves no WOOD
        // either way. The event is the only observable difference — a
        // floored-to-zero bounty must emit NOTHING, not `ConvictionBountyPaid`
        // with `amount == 0`.
        bytes32 bountyPaidTopic = keccak256("ConvictionBountyPaid(bytes32,address,uint256)");
        for (uint256 i = 0; i < entries.length; i++) {
            assertTrue(
                entries[i].topics.length == 0 || entries[i].topics[0] != bountyPaidTopic,
                "no ConvictionBountyPaid at all when the bounty floors to 0"
            );
        }
    }

    /// @notice Mutation kill + spec §2 burn-fallback decision, pinned:
    ///         `openCase` reverting must not claw back a bounty already paid.
    ///         Depositors recover 0% of `total` on this path EITHER WAY (no
    ///         case is ever opened to divide), so the bounty comes out of what
    ///         would otherwise simply burn — the prosecutor is still paid.
    function test_slashToEscrow_deadVaultBurnsNetButStillPaysTheBounty() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        address deadVault = makeAddr("deadVault"); // no code: escrow's votes read reverts
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)", deadVault), abi.encode(makeAddr("deadGov")));

        address challenger = makeAddr("challenger");
        uint256 challengerBefore = wood.balanceOf(challenger);
        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);

        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        (uint256 total, uint256 caseId) = swood.slashToEscrow(
            bytes32("deadCase"), openedAt, gs, _bpsArr(gs.length, 10_000), deadVault, snapTs, challenger, 500
        );

        uint256 gross = 20_000e18;
        uint256 expectedBounty = gross * 500 / 10_000;
        assertEq(caseId, 0, "no case: the vault is unpriceable");
        assertEq(total, gross - expectedBounty, "the burned figure is NET of the bounty");
        assertEq(
            wood.balanceOf(challenger) - challengerBefore,
            expectedBounty,
            "the bounty is still paid on the burn-fallback path (spec 2026-07-29 SS2 decision)"
        );
        assertEq(
            wood.balanceOf(BURN_ADDRESS) - burnBefore, total, "only the NET amount burns - the bounty already left"
        );
    }

    /// @notice Mutation kill: moving the bounty transfer to AFTER the
    ///         try/catch would let it survive a RECOVERABLE `openCase` revert
    ///         (a fixable caller/wiring mistake that must bubble whole, per
    ///         `_isRecoverableOpenCaseFailure`) instead of unwinding with the
    ///         rest of the transaction. `EmptySnapshot` is exactly that: the
    ///         vault's votes read succeeds and returns a real (non-zero)
    ///         supply at `openedAt`, but the earlier `snapshotTimestamp` this
    ///         call names was never given a supply in the fixture, so it
    ///         reads zero — a caller arithmetic error, not a vault-capability
    ///         one, so it bubbles rather than burning.
    function test_slashToEscrow_recoverableFailureBubblesAndUnwindsTheBounty() public {
        vault.setTotal(openedAt, 1_000e18);
        vault.setVotes(alice, openedAt, 1_000e18);

        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        uint256 emptySnapTs = snapTs - 1; // never given a supply on `vault`; reads 0
        assertLe(emptySnapTs, openedAt, "still satisfies slashToEscrow's own snapshot <= openedAt bound");

        address challenger = makeAddr("challenger");

        vm.prank(slasher);
        vm.expectRevert(ICompensationEscrow.EmptySnapshot.selector);
        swood.slashToEscrow(
            bytes32("case"), openedAt, gs, _bpsArr(gs.length, 10_000), address(vault), emptySnapTs, challenger, 500
        );

        assertEq(wood.balanceOf(challenger), 0, "the bounty transfer unwound with the whole reverted transaction");
        assertEq(swood.guardianStake(g1), 20_000e18, "the slash itself unwound too - nothing landed");
    }
}
