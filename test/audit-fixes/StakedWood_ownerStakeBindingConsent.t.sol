// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockL2Registrar} from "../mocks/MockL2Registrar.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @title StakedWood_ownerStakeBindingConsent — issue #98 regression
/// @notice `SyndicateFactory.rotateOwner(vault, newOwner)` authorizes only
///         `msg.sender` (the outgoing owner or original creator) while
///         `newOwner` is a bare parameter checked solely against `address(0)`.
///         The call is not a title assignment: it reaches
///         `StakedWood.transferOwnerStakeSlot`, which SPENDS `newOwner`'s
///         escrowed prepared stake.
///
///         Attack the fix removes: Mallory owns a vault whose bond slot is
///         empty (`ownerStake(V) == 0`, reachable by her own unstake cycle) and
///         which has no open proposals. Alice escrows a prepared stake meaning
///         to open her OWN vault. Mallory calls `rotateOwner(V, alice)` — every
///         pre-fix guard passes — and Alice's stake binds to a vault she never
///         chose: `cancelPreparedStake` starts reverting, her own
///         `createSyndicate` is blocked, and recovering the WOOD costs a full
///         `requestUnstakeOwner` → 1–30 day cooldown → `claimUnstakeOwner`
///         cycle during which the bond is exposed to `slashOwnerBond`.
///
///         Fix (remedy (a) in the issue): consent lives at the SPEND SITE.
///         `newOwner` must have recorded `approveOwnerStakeBinding(vault)` on
///         sWOOD themselves, else `BindingNotApproved`. The approval is
///         single-use and scoped to one escrow lifetime — consumed on bind and
///         cleared by `cancelPreparedStake` / a fresh `prepareOwnerStake`, so
///         an abandoned approval can never be replayed against a later escrow.
contract StakedWood_ownerStakeBindingConsent is Test {
    SyndicateFactory public factory;
    SyndicateVault public vaultImpl;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;
    MockL2Registrar public ensRegistrar;

    address public owner = makeAddr("factoryOwner");
    /// @dev The attacker: owns a vault with an empty bond slot.
    address public mallory = makeAddr("mallory");
    /// @dev The victim: holds an escrowed prepared stake for her own vault.
    address public alice = makeAddr("alice");

    uint256 public malloryAgentId;
    uint256 public aliceAgentId;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant COOLDOWN = 7 days;

    /// @dev The issue's trace amount.
    uint256 constant ALICE_STAKE = 50_000e18;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        vaultImpl = new SyndicateVault();
        agentRegistry = new MockAgentRegistry();
        ensRegistrar = new MockL2Registrar();

        malloryAgentId = agentRegistry.mint(mallory);
        aliceAgentId = agentRegistry.mint(alice);

        // Circular init deps resolved by predicting proxy addresses. From
        // `baseNonce`: swoodImpl(+0), swoodProxy(+1), govImpl(+2), beacon(+3),
        // factoryImpl(+4), regImpl(+5), regProxy(+6), factoryProxy(+7).
        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 6);
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), baseNonce + 7);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: predictedFactoryProxy,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: COOLDOWN,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);

        SyndicateFactory factoryImpl = new SyndicateFactory();
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, predictedFactoryProxy, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry address prediction mismatch");

        vm.prank(owner);
        swood.setRegistry(address(registry));

        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    ensRegistrar: address(ensRegistrar),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(_hoistedPC),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        require(address(factory) == predictedFactoryProxy, "factory address prediction mismatch");

        wood.mint(mallory, 200_000e18);
        wood.mint(alice, 200_000e18);

        vm.prank(mallory);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(alice);
        wood.approve(address(swood), type(uint256).max);
    }

    // ──────────────────────────────────────────────────────────────
    // Helpers
    // ──────────────────────────────────────────────────────────────

    function _cfg(string memory sub) internal view returns (SyndicateFactory.SyndicateConfig memory) {
        return SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://test",
            asset: usdc,
            name: "Test Vault",
            symbol: "tVault",
            openDeposits: false,
            subdomain: sub
        });
    }

    function _prepare(address who, uint256 amount) internal {
        vm.prank(who);
        swood.prepareOwnerStake(amount);
    }

    function _create(address who, uint256 agentId, string memory sub) internal returns (address vault) {
        SyndicateFactory.SyndicateConfig memory cfg = _cfg(sub);
        vm.prank(who);
        (, vault) = factory.createSyndicate(agentId, cfg);
    }

    /// @dev Drains a vault's bond slot the legitimate way: the recorded owner
    ///      requests, waits out the cooldown, and claims. Leaves them still the
    ///      vault owner with `ownerStake(vault) == 0` — exactly the state
    ///      `rotateOwner` requires, and the state Mallory operates from.
    function _drainBondSlot(address who, address vault) internal {
        vm.prank(who);
        swood.requestUnstakeOwner(vault);
        // No pre-warp timestamp is captured — the optimizer CSEs
        // `block.timestamp` across `vm.warp`, so anchors must come from the
        // contract or from `vm.getBlockTimestamp()`.
        vm.warp(vm.getBlockTimestamp() + COOLDOWN + 1);
        vm.prank(who);
        swood.claimUnstakeOwner(vault);
        assertEq(swood.ownerStake(vault), 0, "bond slot drained");
    }

    /// @dev Mallory's starting position: a vault she owns whose bond slot is
    ///      empty and which has no open proposals.
    function _malloryEmptySlotVault(string memory sub) internal returns (address vault) {
        _prepare(mallory, MIN_OWNER_STAKE);
        vault = _create(mallory, malloryAgentId, sub);
        _drainBondSlot(mallory, vault);
    }

    // ──────────────────────────────────────────────────────────────
    // The issue's 4-step trace
    // ──────────────────────────────────────────────────────────────

    /// @notice Issue #98, step by step. Pre-fix this rotation SUCCEEDED and
    ///         spent Alice's escrow; it must now revert `BindingNotApproved`
    ///         and leave every piece of state untouched.
    function test_rotateOwner_withoutConsent_cannotSpendThirdPartyEscrow() public {
        // (2) Mallory holds a vault with an empty bond slot and no proposals.
        address v = _malloryEmptySlotVault("mallory-fund");
        SyndicateGovernor gov = SyndicateGovernor(factory.governorOf(v));
        assertEq(gov.getActiveProposal(), 0, "no active proposal");
        assertEq(gov.openProposalCount(), 0, "no open proposals");

        // (1) Alice escrows a prepared stake, meaning to open her OWN vault.
        _prepare(alice, ALICE_STAKE);
        assertTrue(swood.canCreateVault(alice), "alice can open her own vault");
        assertEq(swood.approvedBindVault(alice), address(0), "alice consented to nothing");

        uint256 aliceWoodBefore = wood.balanceOf(alice);

        // (3) Mallory rotates her vault onto Alice. Every pre-fix guard passes;
        //     the consent guard at the sWOOD spend site is what stops it.
        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(v, alice);

        // (4) Nothing moved. Ownership, the bond slot and the creator record
        //     are all as they were.
        assertEq(SyndicateVault(payable(v)).owner(), mallory, "vault ownership unchanged");
        assertEq(swood.ownerStake(v), 0, "bond slot still empty");
        (,, address recordedCreator,,,,) = factory.syndicates(factory.vaultToSyndicate(v));
        assertEq(recordedCreator, mallory, "creator record unchanged");

        // Alice's escrow is untouched: still hers, still unbound.
        assertEq(swood.preparedStakeOf(alice), ALICE_STAKE, "escrow intact");
        assertTrue(swood.canCreateVault(alice), "alice not locked out of her own vault");

        // ...and she can still open the vault she actually wanted.
        address aliceVault = _create(alice, aliceAgentId, "alice-fund");
        assertEq(SyndicateVault(payable(aliceVault)).owner(), alice, "alice opened her own vault");
        assertEq(swood.ownerStake(aliceVault), ALICE_STAKE, "her stake bonded where she chose");

        // The refund path also survives — proven on a fresh escrow, since the
        // one above is now legitimately bound to Alice's own vault.
        _prepare(alice, ALICE_STAKE);
        vm.prank(alice);
        swood.cancelPreparedStake();
        assertEq(swood.preparedStakeOf(alice), 0, "escrow refunded");
        assertEq(wood.balanceOf(alice), aliceWoodBefore - ALICE_STAKE, "only the self-chosen bond left her balance");
    }

    // ──────────────────────────────────────────────────────────────
    // Approval lifecycle
    // ──────────────────────────────────────────────────────────────

    /// @notice With consent the rotation goes through, and the approval is
    ///         consumed by the bind.
    function test_rotateOwner_withConsent_bindsAndConsumesApproval() public {
        address v = _malloryEmptySlotVault("consented-fund");
        _prepare(alice, ALICE_STAKE);

        vm.expectEmit(true, true, false, false, address(swood));
        emit StakedWood.OwnerStakeBindingApproved(alice, v);
        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);
        assertEq(swood.approvedBindVault(alice), v, "consent recorded");

        vm.expectEmit(true, true, true, false, address(swood));
        emit StakedWood.OwnerStakeSlotTransferred(v, mallory, alice);
        vm.prank(mallory);
        factory.rotateOwner(v, alice);

        assertEq(SyndicateVault(payable(v)).owner(), alice, "vault ownership rotated");
        assertEq(swood.ownerStake(v), ALICE_STAKE, "stake bound under alice");
        (,, address recordedCreator,,,,) = factory.syndicates(factory.vaultToSyndicate(v));
        assertEq(recordedCreator, alice, "creator record follows the owner");

        // Single-use: the consent is gone the moment it is spent.
        assertEq(swood.approvedBindVault(alice), address(0), "approval consumed");
        assertFalse(swood.canCreateVault(alice), "escrow bound");

        // A second rotation naming Alice cannot ride the same consent. The
        // now-funded slot trips `VaultStillStaked` first — approval
        // consumption itself is pinned by the assertion above and, on an empty
        // slot, by `test_consumedApproval_cannotBeReplayedAfterFreshPrepare`.
        vm.prank(alice);
        vm.expectRevert(SyndicateFactory.VaultStillStaked.selector);
        factory.rotateOwner(v, alice);
    }

    /// @notice Consent names one vault. Approving A does not authorize B.
    function test_approval_isVaultSpecific() public {
        address vaultA = _malloryEmptySlotVault("vault-a");
        address vaultB = _malloryEmptySlotVault("vault-b");

        _prepare(alice, ALICE_STAKE);
        vm.prank(alice);
        swood.approveOwnerStakeBinding(vaultA);

        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(vaultB, alice);

        // The approval Alice actually gave still works.
        vm.prank(mallory);
        factory.rotateOwner(vaultA, alice);
        assertEq(swood.ownerStake(vaultA), ALICE_STAKE, "approved vault bound");
    }

    /// @notice Approving again replaces the previous vault rather than adding
    ///         to it — at most one approved vault per address.
    function test_approve_overwritesPreviousApproval() public {
        address vaultA = _malloryEmptySlotVault("overwrite-a");
        address vaultB = _malloryEmptySlotVault("overwrite-b");

        _prepare(alice, ALICE_STAKE);
        vm.startPrank(alice);
        swood.approveOwnerStakeBinding(vaultA);
        swood.approveOwnerStakeBinding(vaultB);
        vm.stopPrank();
        assertEq(swood.approvedBindVault(alice), vaultB, "second approval replaced the first");

        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(vaultA, alice);
    }

    /// @notice Revocation restores the safe state.
    function test_revoke_thenRotate_reverts() public {
        address v = _malloryEmptySlotVault("revoked-fund");
        _prepare(alice, ALICE_STAKE);

        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);

        vm.expectEmit(true, true, false, false, address(swood));
        emit StakedWood.OwnerStakeBindingRevoked(alice, v);
        vm.prank(alice);
        swood.revokeOwnerStakeBinding();
        assertEq(swood.approvedBindVault(alice), address(0), "consent withdrawn");

        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(v, alice);
    }

    /// @notice Revoking with nothing approved is a no-op, not a revert — the
    ///         post-condition callers want is "no standing approval".
    function test_revoke_withNothingApproved_isNoOp() public {
        vm.prank(alice);
        swood.revokeOwnerStakeBinding();
        assertEq(swood.approvedBindVault(alice), address(0));
    }

    /// @notice Cancelling the escrow the consent was scoped to also drops the
    ///         consent (Decision 3, first edge).
    function test_cancelPreparedStake_clearsApproval() public {
        address v = _malloryEmptySlotVault("cancelled-fund");
        _prepare(alice, ALICE_STAKE);

        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);

        vm.prank(alice);
        swood.cancelPreparedStake();
        assertEq(swood.approvedBindVault(alice), address(0), "consent cleared with the escrow");

        // A later escrow cannot be bound on the strength of the dead approval.
        _prepare(alice, ALICE_STAKE);
        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(v, alice);
    }

    /// @notice A fresh `prepareOwnerStake` starts a new escrow lifetime and
    ///         voids any consent left over from the previous one (Decision 3,
    ///         second edge — the replay this closes).
    function test_freshPrepare_clearsApproval_noReplayAgainstLaterEscrow() public {
        address v = _malloryEmptySlotVault("replay-fund");

        // Alice consents to a rotation that is then abandoned. Her escrow goes
        // into her OWN vault instead, so the approval is never consumed.
        _prepare(alice, ALICE_STAKE);
        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);
        _create(alice, aliceAgentId, "alice-own-fund");
        assertEq(swood.approvedBindVault(alice), v, "approval survives an unrelated bind");

        // Much later, Alice escrows a fresh stake for something else. That new
        // lifetime must not inherit the old consent.
        _prepare(alice, ALICE_STAKE);
        assertEq(swood.approvedBindVault(alice), address(0), "stale consent cleared by the fresh escrow");

        vm.prank(mallory);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(v, alice);
    }

    /// @notice A consumed approval is not reusable, even by the vault's own
    ///         owner re-funding their own slot.
    function test_consumedApproval_cannotBeReplayedAfterFreshPrepare() public {
        address v = _malloryEmptySlotVault("reuse-fund");

        _prepare(alice, ALICE_STAKE);
        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);
        vm.prank(mallory);
        factory.rotateOwner(v, alice);

        // Alice now owns V. She exits the bond, then escrows again intending to
        // re-fund the slot — the documented route back to a funded slot.
        _drainBondSlot(alice, v);
        _prepare(alice, ALICE_STAKE);

        // Consent is not implied by ownership: the consumed approval is gone.
        vm.prank(alice);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(v, alice);

        // With a fresh approval the same self-rotation succeeds.
        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);
        vm.prank(alice);
        factory.rotateOwner(v, alice);
        assertEq(swood.ownerStake(v), ALICE_STAKE, "slot re-funded with fresh consent");
    }

    /// @notice The zero vault is not an approvable target.
    function test_approve_rejectsZeroVault() public {
        vm.prank(alice);
        vm.expectRevert(StakedWood.ZeroAddress.selector);
        swood.approveOwnerStakeBinding(address(0));
    }

    /// @notice A standing approval with no live escrow behind it moves nothing:
    ///         the prepared-stake guards still reject the transfer.
    function test_approvalWithoutPreparedStake_isInert() public {
        address v = _malloryEmptySlotVault("inert-fund");

        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);
        assertEq(swood.approvedBindVault(alice), v, "approval standing");
        assertEq(swood.preparedStakeOf(alice), 0, "but no escrow behind it");

        vm.prank(mallory);
        vm.expectRevert(StakedWood.PreparedStakeNotFound.selector);
        factory.rotateOwner(v, alice);
    }

    /// @notice Consent does not substitute for the other guards: an escrow
    ///         below the floor still fails on the bond check.
    function test_consentDoesNotBypassBondFloor() public {
        address v = _malloryEmptySlotVault("floor-fund");

        // Raise the floor after Alice escrowed at the old one.
        _prepare(alice, MIN_OWNER_STAKE);
        vm.prank(owner);
        swood.setMinOwnerStake(MIN_OWNER_STAKE * 2);

        vm.prank(alice);
        swood.approveOwnerStakeBinding(v);

        vm.prank(mallory);
        vm.expectRevert(StakedWood.OwnerBondInsufficient.selector);
        factory.rotateOwner(v, alice);
    }
}
