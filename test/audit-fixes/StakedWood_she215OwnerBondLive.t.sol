// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockGovernorMinimal} from "../mocks/MockGovernorMinimal.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";

/// @title StakedWood_she215OwnerBondLive
/// @notice SHE-215 (audit High), sWOOD half — the predicate the governor's new
///         propose/execute gate reads.
///
///         `claimUnstakeOwner`'s natspec has always promised that after a claim
///         "the vault then enters grace-period state and new proposals cannot
///         be created until the slot is re-funded". Nothing enforced it and no
///         `gracePeriod` state, timer or gate existed anywhere in `src/` — the
///         string was the only occurrence. `ownerBondLive` is that state, made
///         real and readable; `SyndicateGovernor` is where it now bites (see
///         `Governor_she215OwnerBondGate.t.sol`).
///
/// @dev    The predicate is `owner != address(0) && unstakeRequestedAt == 0`.
///         Both clauses are pinned below, as is the ONE state that must stay
///         permissive: a vault created under the documented
///         `minOwnerStake == 0` open-onboarding sentinel holds a bound slot
///         with a real owner and a zero amount, and must keep its proposal
///         lane. Keying the predicate on `stakedAmount` instead would have
///         bricked every such vault at birth.
contract StakedWoodShe215OwnerBondLiveTest is Test {
    StakedWood internal swood;
    ERC20Mock internal wood;
    MockGovernorMinimal internal gov;
    /// @dev A real registry, deployed only to read the passthrough the governor
    ///      actually calls — the governor holds a registry handle, not an sWOOD
    ///      one. `registry` (the pranked slasher below) stays a plain address so
    ///      `slashOwnerBond` can be driven directly.
    GuardianRegistry internal guardianRegistry;

    address internal owner = address(0xA11CE);
    address internal factory = address(0xFAC10);
    address internal alice = address(0xA11CE5);
    address internal bob = address(0xB0B);
    address internal registry = address(0x5EC0);
    address internal vault = address(0xBEEF);

    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant COOLDOWN = 7 days;

    function setUp() public {
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        gov = new MockGovernorMinimal();
        vm.mockCall(factory, abi.encodeWithSignature("governorOf(address)"), abi.encode(address(gov)));

        StakedWood impl = new StakedWood();
        bytes memory initData = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factory,
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: COOLDOWN,
                    minOwnerStake: BOND,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(impl), initData)));

        vm.prank(owner);
        swood.setRegistry(registry);

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        guardianRegistry = GuardianRegistry(
            address(
                new ERC1967Proxy(
                    address(regImpl),
                    abi.encodeCall(GuardianRegistry.initialize, (owner, factory, address(swood), 1 days, 5_000))
                )
            )
        );

        wood.mint(alice, 100_000e18);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    /// @notice THE ROUTE THE GOVERNOR ACTUALLY TAKES. `SyndicateGovernor` holds
    ///         a `IGuardianRegistry` handle, not an sWOOD one, so the gate reads
    ///         this passthrough — the same route `GovernorEmergency` uses for
    ///         `ownerStake`. Asserted across a state CHANGE, not once: a
    ///         passthrough hard-wired to `true` would satisfy a single
    ///         assertion and quietly disable the gate everywhere.
    function test_registryPassthrough_tracksTheSwoodPredicate() public {
        assertFalse(guardianRegistry.ownerBondLive(vault), "unbound");
        _bind();
        assertTrue(guardianRegistry.ownerBondLive(vault), "bound");
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        assertFalse(guardianRegistry.ownerBondLive(vault), "exiting");
        assertEq(
            guardianRegistry.ownerBondLive(vault), swood.ownerBondLive(vault), "the passthrough is not its own opinion"
        );
    }

    /// @dev Alice prepares and the factory binds her bond to `vault`.
    function _bind() internal {
        vm.prank(alice);
        swood.prepareOwnerStake(BOND);
        vm.prank(factory);
        swood.bindOwnerStake(alice, vault);
    }

    // =====================================================================
    // The predicate
    // =====================================================================

    /// @notice A freshly bound slot is live. The baseline every other case
    ///         below moves away from.
    function test_ownerBondLive_trueForAFreshlyBoundSlot() public {
        assertFalse(swood.ownerBondLive(vault), "unbound: no slot, no lane");
        _bind();
        assertTrue(swood.ownerBondLive(vault), "bound and not exiting");
    }

    /// @notice CLAUSE TWO. The lane closes at the REQUEST, not at the claim.
    ///         A bond inside its exit cooldown is already committed to leaving
    ///         and is not collateral behind anything; leaving the whole
    ///         cooldown open was what let the exploit be staged at leisure.
    ///
    /// @dev    MUTATION-CHECKED: dropping the `unstakeRequestedAt == 0` clause
    ///         leaves this assertion failing and hands the owner the entire
    ///         cooldown as a window in which to propose against a bond they
    ///         have already declared they are withdrawing.
    function test_ownerBondLive_falseWhileTheUnstakeRequestIsPending() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        assertFalse(swood.ownerBondLive(vault), "an exit in flight is not a live bond");
        assertEq(swood.ownerStake(vault), BOND, "the WOOD is still escrowed; amount alone cannot see this");
    }

    /// @notice CLAUSE ONE, THE FINDING ITSELF. `claimUnstakeOwner` deletes the
    ///         record, so the promised grace period is now a state the governor
    ///         can read rather than a sentence in a comment.
    function test_ownerBondLive_falseAfterTheBondIsClaimed() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN + 1);
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);

        assertEq(swood.ownerStake(vault), 0, "sanity: the slot is emptied");
        assertFalse(swood.ownerBondLive(vault), "the grace period the natspec promised");
    }

    /// @notice CLAUSE ONE, THE OTHER EMPTYING ROUTE. `slashOwnerBond` also
    ///         `delete`s the record, so a slashed vault sits in the same
    ///         grace-period state — which is the right answer: the deterrent
    ///         behind the lane has been burned.
    function test_ownerBondLive_falseAfterTheBondIsSlashed() public {
        _bind();

        vm.prank(registry);
        swood.slashOwnerBond(vault);

        assertFalse(swood.ownerBondLive(vault), "a burned bond is not a live bond");
    }

    /// @notice THE STATE THAT MUST STAY PERMISSIVE. Under the documented
    ///         `minOwnerStake == 0` open-onboarding sentinel, `bindOwnerStake`
    ///         records a real owner against a ZERO amount. That vault never
    ///         posted a bond and was never asked to, so its proposal lane must
    ///         stay open — this is why the predicate tests `owner`, not
    ///         `stakedAmount`.
    ///
    /// @dev    MUTATION-CHECKED: rewriting the first clause as
    ///         `s.stakedAmount != 0` fails here, and would brick the proposal
    ///         lane of every zero-bond vault from the moment it is created.
    function test_ownerBondLive_trueForAZeroBondOnboardingVault() public {
        address poorCreator = address(0xDEAD0);

        vm.prank(owner);
        swood.setMinOwnerStake(0);

        vm.prank(factory);
        swood.bindOwnerStake(poorCreator, vault);

        assertEq(swood.ownerStake(vault), 0, "sanity: zero bond, by design");
        assertTrue(swood.ownerBondLive(vault), "open onboarding keeps its lane");
    }

    // =====================================================================
    // cancelUnstakeOwner — the way back
    // =====================================================================

    /// @notice THE REVERSIBILITY THE GATE NEEDS. Without a cancel, a single
    ///         exploratory `requestUnstakeOwner` would shut a live vault's
    ///         proposal lane for the whole cooldown with no way back short of
    ///         claiming the bond and running a two-transaction `rotateOwner`.
    ///         Mirrors `cancelUnstakeGuardian`.
    function test_cancelUnstakeOwner_restoresTheLiveBond() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));

        vm.expectEmit(true, true, false, true);
        emit StakedWood.OwnerUnstakeCancelled(vault, alice);
        vm.prank(alice);
        swood.cancelUnstakeOwner(vault);

        assertTrue(swood.ownerBondLive(vault), "the lane reopens");
        assertEq(swood.ownerStake(vault), BOND, "and the bond never moved");
    }

    /// @notice A CANCEL RESTARTS THE COOLDOWN, it does not preserve credit for
    ///         time already served. Pins that `cooldownAtRequest` is cleared
    ///         alongside the stamp: a cancel-and-re-request must buy the full
    ///         wait again, or the owner could park a request, cancel it to
    ///         reopen the lane, and re-request with the cooldown nearly spent.
    function test_cancelUnstakeOwner_thenRequestAgainRestartsTheCooldown() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN - 1);

        vm.prank(alice);
        swood.cancelUnstakeOwner(vault);
        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        // `vm.getBlockTimestamp()`, not `block.timestamp`: the executing frame
        // caches the latter, so a second warp built on it would land back where
        // the first one did. One second short of a FULL fresh cooldown, not of
        // the original one.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN - 1);
        vm.prank(alice);
        vm.expectRevert(StakedWood.CooldownNotElapsed.selector);
        swood.claimUnstakeOwner(vault);

        vm.warp(vm.getBlockTimestamp() + 2);
        vm.prank(alice);
        swood.claimUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));
    }

    /// @notice Only the recorded owner may cancel, and only against a request
    ///         that exists. Same two gates `requestUnstakeOwner` applies, in
    ///         the same order.
    function test_cancelUnstakeOwner_revertsForAStrangerAndForNoRequest() public {
        _bind();

        vm.prank(alice);
        vm.expectRevert(StakedWood.UnstakeNotRequested.selector);
        swood.cancelUnstakeOwner(vault);

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);

        vm.prank(bob);
        vm.expectRevert(StakedWood.NoActiveStake.selector);
        swood.cancelUnstakeOwner(vault);
    }

    /// @notice A SLASHED SLOT CANNOT BE CANCELLED BACK TO LIFE. `slashOwnerBond`
    ///         deletes the record, so there is no owner to match and nothing to
    ///         restore — the owner-path analogue of `cancelUnstakeGuardian`'s
    ///         ghost-guardian refusal, reached one field earlier.
    function test_cancelUnstakeOwner_cannotResurrectASlashedSlot() public {
        _bind();

        vm.prank(alice);
        swood.requestUnstakeOwner(vault);
        vm.prank(registry);
        swood.slashOwnerBond(vault);

        vm.prank(alice);
        vm.expectRevert(StakedWood.NoActiveStake.selector);
        swood.cancelUnstakeOwner(vault);
        assertFalse(swood.ownerBondLive(vault));
    }
}
