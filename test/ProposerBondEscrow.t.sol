// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProposerBondEscrow} from "src/ProposerBondEscrow.sol";
import {IProposerBondEscrow} from "src/interfaces/IProposerBondEscrow.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockRegistryAuth {
    mapping(address => bool) public isAuthorizedGovernor;

    function set(address gov, bool ok) external {
        isAuthorizedGovernor[gov] = ok;
    }
}

/// @dev The one thing the escrow reads off the ledger: who the challenge game
///      is. Settable so the rotation the real `setCoverageFreezer` performs can
///      be exercised here without standing up the whole ledger.
contract MockLedgerFreezer {
    address public coverageFreezer;

    function setCoverageFreezer(address freezer) external {
        coverageFreezer = freezer;
    }
}

contract ProposerBondEscrowTest is Test {
    ProposerBondEscrow internal escrow;
    ERC20Mock internal wood;
    MockRegistryAuth internal reg;
    MockLedgerFreezer internal ledger;
    address internal governor = makeAddr("governor");
    address internal proposer = makeAddr("proposer");
    address internal game = makeAddr("challengeGame");

    function setUp() public {
        wood = new ERC20Mock();
        reg = new MockRegistryAuth();
        reg.set(governor, true);
        ledger = new MockLedgerFreezer();
        ledger.setCoverageFreezer(game);
        escrow = new ProposerBondEscrow(address(wood), address(reg), address(ledger));
        wood.mint(proposer, 1_000e18);
        vm.prank(proposer);
        wood.approve(address(escrow), type(uint256).max);
    }

    function test_lockBond_pullsWoodAndRecords() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        assertEq(wood.balanceOf(address(escrow)), 100e18);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 100e18);
    }

    function test_lockBond_unauthorizedGovernorReverts() public {
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedGovernor.selector);
        escrow.lockBond(1, proposer, 100e18);
    }

    function test_lockBond_duplicateReverts() public {
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.expectRevert(IProposerBondEscrow.BondAlreadyLocked.selector);
        escrow.lockBond(1, proposer, 100e18);
        vm.stopPrank();
    }

    function test_lockBond_amountOverUint96Reverts() public {
        // Guard fires BEFORE safeTransferFrom, so no mint/approve of 2^96 WOOD
        // is needed and no funds move.
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.AmountTooLarge.selector);
        escrow.lockBond(1, proposer, uint256(type(uint96).max) + 1);
        assertEq(wood.balanceOf(address(escrow)), 0);
        (address p,) = escrow.bondOf(governor, 1);
        assertEq(p, address(0));
    }

    function test_releaseBond_returnsToProposer() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    function test_releaseBond_keyBoundToLockerAndOnce() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        // releaseBond has no live auth check: a non-locker caller's key is
        // key(caller, 1), which holds no bond — NoBond, not an auth error.
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
        vm.prank(governor);
        escrow.releaseBond(1);
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
    }

    function test_releaseBond_crossGovernorIsolation() public {
        address governorB = makeAddr("governorB");
        reg.set(governorB, true);
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governorB);
        escrow.lockBond(1, proposer, 200e18);
        // A's release touches only A's bond; B's stays locked.
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(address(escrow)), 200e18);
        (address pA,) = escrow.bondOf(governor, 1);
        assertEq(pA, address(0));
        (address pB, uint256 amtB) = escrow.bondOf(governorB, 1);
        assertEq(pB, proposer);
        assertEq(amtB, 200e18);
        // An unauthorized address hits NoBond (its own empty key), not an
        // auth error — and cannot touch B's bond.
        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        new ProposerBondEscrow(address(0), address(reg), address(ledger));
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        new ProposerBondEscrow(address(wood), address(0), address(ledger));
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        new ProposerBondEscrow(address(wood), address(reg), address(0));
    }

    function test_lockBond_zeroProposerReverts() public {
        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.ZeroAddress.selector);
        escrow.lockBond(1, address(0), 100e18);
    }

    /// Pins intended semantics: a zero-amount bond is accepted and releasable.
    function test_lockBond_zeroAmountAcceptedAndReleasable() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 0);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 0);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        (address pAfter,) = escrow.bondOf(governor, 1);
        assertEq(pAfter, address(0));
    }

    /// A governor deauthorized AFTER locking can still release its open
    /// bonds — funds are never stranded by registry deauthorization.
    function test_releaseBond_afterGovernorDeauthorized() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        reg.set(governor, false);
        vm.prank(governor);
        escrow.releaseBond(1);
        assertEq(wood.balanceOf(proposer), 1_000e18);
        assertEq(wood.balanceOf(address(escrow)), 0);
    }

    // ── Forfeiture ────────────────────────────────────────────────────────

    /// The bond's downside branch: a conviction destroys it rather than paying
    /// it anywhere. Every reachable payee is a round trip back to the proposer
    /// (it can be its own challenger, and it can hold vault shares), so the
    /// only sink with no beneficiary to be is the burn address.
    function test_forfeitBond_burnsTheBondAndClearsTheRecord() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);

        vm.prank(game);
        (address who, uint256 amount) = escrow.forfeitBond(governor, 1, address(0), 0);
        assertEq(who, proposer, "the loss is attributed to the proposer");
        assertEq(amount, 100e18);

        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 100e18, "the WOOD left the system");
        assertEq(wood.balanceOf(address(escrow)), 0, "and the escrow no longer holds it");
        assertEq(wood.balanceOf(proposer), 900e18, "the proposer never got it back");
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, address(0), "the record is gone");
        assertEq(amt, 0);
    }

    /// Confiscation is a verdict, so only the contract that reaches verdicts
    /// may trigger it. Notably the GOVERNOR that locked the bond cannot — it
    /// gates WHEN a bond is released, never whether it is destroyed.
    function test_forfeitBond_onlyTheCoverageFreezer() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);

        vm.prank(makeAddr("rogue"));
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedConvictor.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);

        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedConvictor.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);

        vm.prank(proposer);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedConvictor.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);

        // Nothing moved on any of the three.
        assertEq(wood.balanceOf(address(escrow)), 100e18);
        (address p, uint256 amt) = escrow.bondOf(governor, 1);
        assertEq(p, proposer);
        assertEq(amt, 100e18);
    }

    /// The role is READ LIVE off the ledger rather than mirrored here, so
    /// replacing the challenge game moves the privilege with it — the old game
    /// loses it in the same transaction, with no second pointer to update.
    function test_forfeitBond_followsTheFreezerRotation() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);

        address newGame = makeAddr("replacementGame");
        ledger.setCoverageFreezer(newGame);

        vm.prank(game);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedConvictor.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);

        vm.prank(newGame);
        escrow.forfeitBond(governor, 1, address(0), 0);
        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 100e18);
    }

    /// FAILS CLOSED with no freezer wired: `msg.sender` can never be the zero
    /// address, so an unwired protocol confiscates nothing rather than letting
    /// anyone confiscate.
    function test_forfeitBond_unwiredFreezerAuthorizesNobody() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        ledger.setCoverageFreezer(address(0));

        vm.prank(game);
        vm.expectRevert(IProposerBondEscrow.NotAuthorizedConvictor.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);
        assertEq(wood.balanceOf(address(escrow)), 100e18, "the bond is merely un-confiscatable, not lost");
    }

    /// Effects before interaction, so the two exits are mutually exclusive and
    /// each is once-only: a forfeited bond cannot then be released, a released
    /// bond cannot then be forfeited, and concurrent challenges convicting the
    /// same proposal cannot double-burn.
    function test_forfeitBond_andReleaseAreMutuallyExclusive() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(game);
        escrow.forfeitBond(governor, 1, address(0), 0);

        vm.prank(game);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.forfeitBond(governor, 1, address(0), 0);

        vm.prank(governor);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.releaseBond(1);

        // ...and the other order.
        vm.prank(governor);
        escrow.lockBond(2, proposer, 50e18);
        vm.prank(governor);
        escrow.releaseBond(2);
        vm.prank(game);
        vm.expectRevert(IProposerBondEscrow.NoBond.selector);
        escrow.forfeitBond(governor, 2, address(0), 0);
    }

    /// The bond key is (governor, proposalId) on the forfeit path too, so a
    /// conviction against one governor's proposal cannot reach another's.
    function test_forfeitBond_crossGovernorIsolation() public {
        address governorB = makeAddr("governorB");
        reg.set(governorB, true);
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(governorB);
        escrow.lockBond(1, proposer, 200e18);

        vm.prank(game);
        escrow.forfeitBond(governor, 1, address(0), 0);

        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 100e18);
        (address pB, uint256 amtB) = escrow.bondOf(governorB, 1);
        assertEq(pB, proposer, "governorB's bond is untouched");
        assertEq(amtB, 200e18);
    }

    /// Fuzz the conservation invariant: balance == sum of locked-unreleased.
    function testFuzz_balanceMatchesOpenBonds(uint96 a1, uint96 a2, bool release1) public {
        uint256 b1 = uint256(a1) % 500e18 + 1;
        uint256 b2 = uint256(a2) % 500e18 + 1;
        vm.startPrank(governor);
        escrow.lockBond(1, proposer, b1);
        escrow.lockBond(2, proposer, b2);
        if (release1) escrow.releaseBond(1);
        vm.stopPrank();
        uint256 expected = release1 ? b2 : b1 + b2;
        assertEq(wood.balanceOf(address(escrow)), expected);
    }

    // ── Prosecutor fee ─────────────────────────────────────────────────────

    /// @notice The fee leg and the burn leg together are the whole bond.
    function test_forfeitBond_paysTheProsecutorFeeAndBurnsTheRest() public {
        address prosecutor = makeAddr("prosecutor");
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);

        vm.prank(game);
        (, uint256 amount) = escrow.forfeitBond(governor, 1, prosecutor, 500);

        assertEq(amount, 100e18, "the return value is the GROSS forfeited bond");
        assertEq(wood.balanceOf(prosecutor), 5e18, "5% to the prosecutor");
        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 95e18, "the remainder burned");
        assertEq(wood.balanceOf(address(escrow)), 0, "nothing stranded");
    }

    /// @notice THE PROPERTY THE WHOLE DESIGN RESTS ON. This is the one pot a
    ///         prosecutor cannot fund for itself: to self-deal you must BE the
    ///         proposer, and then you are paying yourself a fraction of a bond
    ///         you forfeit in full. Always a net loss, for any rate under
    ///         10_000 — no role predicate to game, no cap to tune.
    ///
    ///         Contrast the guardians' slash, which a prosecutor CAN fund for
    ///         itself by staking and approving the proposal it is about to
    ///         accuse. That is why a slash-funded fee needed an approver-role
    ///         predicate to stay priced, and why the accused could switch the
    ///         fee off by defending from an unrelated address.
    function test_forfeitBond_selfDealingProposerAlwaysLoses() public {
        // The proposer prosecutes its own proposal, naming itself as payee.
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        uint256 before = wood.balanceOf(proposer);

        // Hoisted: a call in ARGUMENT position is evaluated first and would
        // consume the pending `vm.prank`, leaving `forfeitBond` unpranked.
        uint256 cap = escrow.MAX_PROSECUTOR_FEE_BPS();
        vm.prank(game);
        escrow.forfeitBond(governor, 1, proposer, cap);

        // Even at the ceiling it recovers a fraction of what it forfeited.
        uint256 recovered = wood.balanceOf(proposer) - before;
        assertEq(recovered, 20e18, "the maximum it can pay itself");
        assertLt(recovered, 100e18, "strictly less than the bond it lost");
        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 80e18, "the rest is destroyed");
    }

    /// @notice The rate is bounded by the escrow, not trusted from the
    ///         convictor — the same posture sWOOD takes toward the rates it is
    ///         handed. It reverts rather than clamping, so a caller-chosen
    ///         payee is never laundered into a smaller caller-chosen one.
    function test_forfeitBond_rejectsAFeeAboveTheCeiling() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);

        // Hoisted for the same reason as above — both the ceiling read and
        // `makeAddr` would otherwise eat the prank.
        uint256 tooHigh = escrow.MAX_PROSECUTOR_FEE_BPS() + 1;
        address greedy = makeAddr("greedy");
        vm.prank(game);
        vm.expectRevert(IProposerBondEscrow.FeeBpsTooHigh.selector);
        escrow.forfeitBond(governor, 1, greedy, tooHigh);
    }

    /// @notice A zero payee or a zero rate burns the whole bond, which is the
    ///         behaviour every pre-fee caller relied on.
    function test_forfeitBond_zeroPayeeOrRateBurnsEverything() public {
        vm.prank(governor);
        escrow.lockBond(1, proposer, 100e18);
        vm.prank(game);
        escrow.forfeitBond(governor, 1, address(0), 2_000);
        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 100e18, "zero payee burns all");

        vm.prank(governor);
        escrow.lockBond(2, proposer, 50e18);
        vm.prank(game);
        escrow.forfeitBond(governor, 2, makeAddr("p2"), 0);
        assertEq(wood.balanceOf(escrow.BURN_ADDRESS()), 150e18, "zero rate burns all");
    }
}
