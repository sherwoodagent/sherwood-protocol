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

        // The escrow accepts case funding from sWOOD only.
        escrow = new CompensationEscrow(owner, address(wood));
        vm.startPrank(owner);
        escrow.setAuthorizedFunder(address(swood));
        escrow.setBackstop(backstop);
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

    function test_slashToEscrow_onlySlasher() public {
        address[] memory gs = new address[](1);
        gs[0] = g1;
        vm.expectRevert(IStakedWood.NotAuthorizedSlasher.selector);
        swood.slashToEscrow(bytes32("case"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);
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
        swood.slashToEscrow(bytes32("case"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);
    }

    function test_slashToEscrow_routesProceedsToEscrowNotBurn() public {
        vm.prank(owner);
        swood.setAuthorizedSlasher(slasher);

        uint256 burnBefore = wood.balanceOf(BURN_ADDRESS);
        address[] memory gs = new address[](1);
        gs[0] = g1;

        vm.prank(slasher);
        uint256 total =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);

        assertGt(total, 0, "something was actually slashed");
        assertEq(wood.balanceOf(BURN_ADDRESS), burnBefore, "verdict slash must NOT burn");
        assertEq(wood.balanceOf(address(escrow)), total, "proceeds land in the escrow");
        (address v, uint256 ts, uint256 proceeds,,) = escrow.caseOf(1);
        assertEq(v, address(vault));
        assertEq(ts, snapTs);
        assertEq(proceeds, total, "the whole slash funds the case");
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
        uint256 total =
            swood.slashToEscrow(bytes32("case"), openedAt, gs, 2500, address(escrow), address(vault), snapTs);
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
        uint256 total = swood.slashToEscrow(bytes32("c"), openedAt, gs, 10_000, address(escrow), address(vault), snapTs);
        assertEq(total, 0);
        assertEq(escrow.caseCount(), 0, "no empty case opened");
    }
}
