// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockMToken} from "./mocks/MockMToken.sol";

/// @dev Minimal SyndicateFactory stand-in returning a non-zero
///      `vaultToSyndicate(vault)` so `StrategyFactory._authClone` passes.
contract _MockSyndicateRegistry {
    function vaultToSyndicate(address) external pure returns (uint256) {
        return 1;
    }
}

/// @dev Minimal vault stand-in exposing IVaultMembership.
contract _MockVault {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isAgent(address) external pure returns (bool) {
        return false;
    }
}

/// @notice Codehash-class certification (`codehash-class-certification`).
///
///         The class mechanism rests on one bytecode fact: every ERC-1167
///         clone of a template is byte-identical, so all clones share one
///         EXTCODEHASH and that hash identifies the template. If that fact
///         ever stops holding — a clone variant writing per-instance data into
///         the clone's bytecode — every class silently dissolves to the tier-2
///         default with no revert anywhere. These tests are the tripwire.
contract TierRegistryClassCertificationTest is Test {
    TierRegistry registry;
    StrategyFactory factory;
    MockStrategy template;
    ERC20Mock usdc;
    MockMToken mUsdc;
    _MockSyndicateRegistry syndicateRegistry;
    _MockVault vault;

    address owner = makeAddr("owner");
    address vaultOwner = makeAddr("vaultOwner");

    function setUp() public {
        registry = new TierRegistry(owner);
        syndicateRegistry = new _MockSyndicateRegistry();
        factory = new StrategyFactory(address(syndicateRegistry), address(this));
        template = new MockStrategy();
        factory.setTemplateApproval(address(template), true);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        mUsdc = new MockMToken(address(usdc), "Moonwell USDC", "mUsdc");
        vault = new _MockVault(vaultOwner);
    }

    function _cloneViaFactory() internal returns (address clone) {
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
        vm.prank(vaultOwner);
        clone = factory.cloneAndInit(address(template), address(vault), vaultOwner, initData);
    }

    // ── Task 1.2: the derivation is pinned against a REAL factory clone ──

    /// @notice The load-bearing test of this whole change. `cloneCodehashOf` is
    ///         a hand-written byte layout; if `StrategyFactory` ever changes
    ///         clone mechanism, the layout stops matching reality and every
    ///         class quietly matches nothing. Nothing else in the system would
    ///         raise an error — proposals keep executing, just back at tier 2.
    ///         So this asserts the derivation against a clone the factory
    ///         actually produced, not against a constant.
    function test_cloneCodehashOf_matchesRealFactoryClone() public {
        address clone = _cloneViaFactory();
        assertEq(
            clone.codehash,
            registry.cloneCodehashOf(address(template)),
            "derived clone codehash must equal a real factory clone's live EXTCODEHASH"
        );
    }

    /// @notice Every clone of one template is byte-identical — the property the
    ///         class abstraction is built on.
    function test_cloneCodehashOf_allClonesShareOneCodehash() public {
        address a = _cloneViaFactory();
        address b = _cloneViaFactory();
        assertTrue(a != b, "distinct clone addresses");
        assertEq(a.codehash, b.codehash, "clones of one template share a codehash");
        assertEq(a.codehash, registry.cloneCodehashOf(address(template)), "and it is the derived value");
    }

    /// @notice A clone of a DIFFERENT template must not fall into this class.
    ///         The template address is baked into the clone's bytecode, so the
    ///         codehashes must differ.
    function test_cloneCodehashOf_differentTemplateDifferentClass() public {
        MockStrategy other = new MockStrategy();
        assertTrue(
            registry.cloneCodehashOf(address(template)) != registry.cloneCodehashOf(address(other)),
            "distinct templates must derive distinct class fingerprints"
        );
    }

    /// @notice `Clones.cloneDeterministic` produces the same runtime code as
    ///         `Clones.clone` — only the deploy opcode differs — so both
    ///         factory entry points land in the same class.
    function test_cloneCodehashOf_deterministicCloneSameClass() public {
        address direct = Clones.clone(address(template));
        address deterministic = Clones.cloneDeterministic(address(template), keccak256("salt"));
        assertEq(direct.codehash, deterministic.codehash, "both clone variants share a class");
        assertEq(direct.codehash, registry.cloneCodehashOf(address(template)), "and it is the derived value");
    }

    /// @notice The derivation is pure — it describes what a clone WOULD hash
    ///         to, and says nothing about whether anything is deployed. The
    ///         codeless-template refusal belongs to certification, not here.
    function test_cloneCodehashOf_pureForUndeployedTemplate() public {
        address never = makeAddr("neverDeployed");
        assertTrue(registry.cloneCodehashOf(never) != bytes32(0), "derivation is defined for any address");
    }

    // ── Namespace isolation (task 5.8, key-derivation half) ──

    /// @notice Address keys and class keys must not alias. Their preimages
    ///         differ in length (24 vs 36 bytes), and the entries live in
    ///         separate mappings, so neither can be reached through the other.
    function test_classKey_doesNotAliasAddressKey() public view {
        bytes4 sel = bytes4(keccak256("execute()"));
        bytes32 clazz = registry.cloneCodehashOf(address(template));
        assertTrue(
            registry.classKey(clazz, sel) != registry.key(address(template), sel),
            "class and address keys occupy distinct namespaces"
        );
    }

    // ── Certification helpers ──

    bytes4 constant SEL = bytes4(keccak256("execute()"));
    uint8 constant TIER_1 = 1;
    uint16 constant BOUND = 500;

    /// @dev Two-step certify: propose, warp past `certifyDelay`, execute.
    ///      No bond is configured, so execution is permissionless.
    function _certifyClass(address tmpl) internal {
        vm.prank(owner);
        registry.proposeClassCertification(tmpl, SEL, TIER_1, BOUND, address(0), tmpl.codehash);
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certifyClass(tmpl, SEL);
    }

    function _certifyAndAllowClass(address tmpl) internal {
        _certifyClass(tmpl);
        vm.prank(owner);
        registry.setClassAllowed(tmpl, true);
    }

    // ── 5.1 Membership positive ──

    /// @notice The whole point: a clone is tiered and callable with NO
    ///         per-clone owner action ever having been taken.
    function test_classMembership_cloneInheritsTierAndAllowlist() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_1, "clone inherits the class tier");
        assertEq(bound, BOUND, "clone inherits the class bound");
        assertTrue(registry.isAdapterAllowed(clone), "clone inherits class allowlist standing");
        assertEq(registry.classOf(clone), registry.cloneCodehashOf(address(template)), "clone reports its class");
    }

    /// @notice A second clone, minted after certification, needs no action either.
    function test_classMembership_laterClonesInheritToo() public {
        _certifyAndAllowClass(address(template));
        address first = _cloneViaFactory();
        address second = _cloneViaFactory();
        (uint8 t1,) = registry.tierOf(first, SEL);
        (uint8 t2,) = registry.tierOf(second, SEL);
        assertEq(t1, TIER_1);
        assertEq(t2, TIER_1);
        assertTrue(registry.isAdapterAllowed(second), "every clone, not just the first");
    }

    /// @notice An uncertified selector on a certified class stays tier 2 —
    ///         class configs are per-selector, exactly like address configs.
    function test_classMembership_uncertifiedSelectorStaysTier2() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        (uint8 tier, uint16 bound) = registry.tierOf(clone, bytes4(keccak256("settle()")));
        assertEq(tier, 2, "other selectors are not covered");
        assertEq(bound, 10_000);
    }

    // ── 5.2 Membership negative ──

    /// @notice A contract that is not an ERC-1167 clone of the template is not
    ///         a member, however similar its interface. Membership is code
    ///         identity, not interface shape. The template itself is the
    ///         sharpest case: it implements everything, and is not a clone.
    function test_classMembership_lookAlikeIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        (uint8 tier,) = registry.tierOf(address(template), SEL);
        assertEq(tier, 2, "the template is not a clone of itself");
        assertFalse(registry.isAdapterAllowed(address(template)), "and gains no allowlist standing");
        assertEq(registry.classOf(address(template)), bytes32(0), "belongs to no class");
    }

    /// @notice A clone of an UNcertified template is not a member.
    function test_classMembership_cloneOfOtherTemplateIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        MockStrategy other = new MockStrategy();
        address foreign = Clones.clone(address(other));
        (uint8 tier,) = registry.tierOf(foreign, SEL);
        assertEq(tier, 2, "different template, different class");
        assertFalse(registry.isAdapterAllowed(foreign));
    }

    /// @notice An EOA belongs to no class.
    function test_classMembership_eoaIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        assertEq(registry.classOf(makeAddr("eoa")), bytes32(0));
        assertFalse(registry.isAdapterAllowed(makeAddr("eoa")));
    }

    // ── 5.3 Level-2 staleness ──

    /// @notice THE test for the second membership level. A clone's codehash
    ///         embeds the template's ADDRESS, not its CODE — so mutating the
    ///         template in place leaves every clone's codehash identical while
    ///         changing what every clone does. Without the anchor check the
    ///         class would keep vouching for the new code across every clone at
    ///         once. Adversary: metamorphic CREATE2 + SELFDESTRUCT redeploy.
    function test_classMembership_templateMutationRevokesEveryClone() public {
        _certifyAndAllowClass(address(template));
        address a = _cloneViaFactory();
        address b = _cloneViaFactory();
        bytes32 codehashBefore = a.codehash;

        // Mutate the template's code at the same address.
        vm.etch(address(template), hex"600160005260206000f3");

        assertEq(a.codehash, codehashBefore, "the clone's own codehash is UNCHANGED by this");
        (uint8 tierA,) = registry.tierOf(a, SEL);
        (uint8 tierB,) = registry.tierOf(b, SEL);
        assertEq(tierA, 2, "yet the clone reads tier 2 on the very next read");
        assertEq(tierB, 2, "for every clone, not just one");
        assertFalse(registry.isAdapterAllowed(a), "and loses allowlist standing");
        assertFalse(registry.isAdapterAllowed(b));
        assertEq(registry.classOf(a), bytes32(0), "membership is gone with no demotion call");
    }

    /// @notice The lazy revocation needs no `poke` — but `pokeClass` persists
    ///         it for watchtowers, and refuses while the template is unchanged.
    function test_pokeClass_refusesWhileTemplateUnchanged() public {
        _certifyAndAllowClass(address(template));
        vm.expectRevert(TierRegistry.CodehashMatches.selector);
        registry.pokeClass(address(template), SEL);
    }

    function test_pokeClass_persistsAfterTemplateMutation() public {
        _certifyAndAllowClass(address(template));
        vm.etch(address(template), hex"600160005260206000f3");
        registry.pokeClass(address(template), SEL);
        assertFalse(registry.isClassAllowed(address(template)), "class allowlist cleared on demotion");
    }

    // ── 5.4 Precedence ──

    /// @notice An address entry always wins over class membership, so the owner
    ///         keeps a per-clone override without disturbing the class.
    function test_precedence_addressEntryWinsOverClass() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(owner);
        registry.proposeCertification(clone, SEL, 0, 100, address(0), clone.codehash);
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certify(clone, SEL);

        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, 0, "address certification wins");
        assertEq(bound, 100, "including its bound");

        // Other clones still read the class.
        address sibling = _cloneViaFactory();
        (uint8 sTier,) = registry.tierOf(sibling, SEL);
        assertEq(sTier, TIER_1, "the class is undisturbed");
    }

    // ── 5.5 Clone created outside the factory ──

    /// @notice A deliberate loosening, pinned so it reads as intended rather
    ///         than as an oversight: membership is proven from bytecode, so
    ///         `StrategyFactory._authClone` is not enforced for it. Analyzed as
    ///         granting no capability — the clone is inert until a proposal
    ///         names it, and that proposal still faces vote and guardian review.
    function test_classMembership_cloneMadeOutsideFactoryIsMember() public {
        _certifyAndAllowClass(address(template));
        address rogue = Clones.clone(address(template));
        (uint8 tier,) = registry.tierOf(rogue, SEL);
        assertEq(tier, TIER_1, "bytecode is the proof, not provenance");
        assertTrue(registry.isAdapterAllowed(rogue));
    }

    // ── 5.6 Immutable-args clone: the quiet-failure mode ──

    /// @notice If clones ever carry per-instance bytecode, their codehashes
    ///         diverge and the class dissolves — silently. Nothing reverts;
    ///         proposals keep working, just back at tier 2 with the per-call
    ///         cap reinstated. Pinned because a quiet regression to the status
    ///         quo is the hardest kind to notice.
    function test_classMembership_perInstanceBytecodeDissolvesClassSilently() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        // Simulate a clone carrying appended per-instance data.
        bytes memory withArgs = abi.encodePacked(clone.code, bytes32(uint256(0xdeadbeef)));
        address fake = makeAddr("cloneWithImmutableArgs");
        vm.etch(fake, withArgs);

        (uint8 tier,) = registry.tierOf(fake, SEL);
        assertEq(tier, 2, "distinct codehash => not a member");
        assertFalse(registry.isAdapterAllowed(fake), "and silently unallowlisted");
        assertEq(registry.classOf(fake), bytes32(0), "no error is raised anywhere");
    }

    // ── 5.7 Class demotion ──

    function test_demoteClass_revokesEveryCloneAtOnce() public {
        _certifyAndAllowClass(address(template));
        address a = _cloneViaFactory();
        address b = _cloneViaFactory();

        vm.prank(owner);
        registry.demoteClass(address(template), SEL);

        (uint8 tierA,) = registry.tierOf(a, SEL);
        (uint8 tierB,) = registry.tierOf(b, SEL);
        assertEq(tierA, 2);
        assertEq(tierB, 2);
        assertFalse(registry.isAdapterAllowed(a), "allowlist cleared for the whole class");
        assertFalse(registry.isAdapterAllowed(b));
    }

    /// @notice Re-certification must never restore allowlist standing — the
    ///         address path's rule, and the blast radius here is every clone.
    function test_demoteClass_reCertificationDoesNotRestoreAllowlist() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(owner);
        registry.demoteClass(address(template), SEL);
        assertFalse(registry.isClassAllowed(address(template)));

        _certifyClass(address(template));
        (uint8 tier,) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_1, "tier is restored by re-certification");
        assertFalse(registry.isAdapterAllowed(clone), "but the funds path is NOT");
        assertFalse(registry.isClassAllowed(address(template)));

        vm.prank(owner);
        registry.setClassAllowed(address(template), true);
        assertTrue(registry.isAdapterAllowed(clone), "only an explicit owner grant reopens it");
    }

    function test_demoteClass_onUncertifiedClassReverts() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.ClassNotCertified.selector);
        registry.demoteClass(address(template), SEL);
    }

    function test_setClassAllowed_beforeCertificationReverts() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.ClassNotCertified.selector);
        registry.setClassAllowed(address(template), true);
    }

    // ── 5.8 Namespace isolation ──

    /// @notice An address certification must not be reachable through a class
    ///         entry point. The two live in separate mappings, so this is
    ///         structural rather than probabilistic.
    function test_namespaceIsolation_addressCertNotVisibleAsClass() public {
        address clone = _cloneViaFactory();
        vm.prank(owner);
        registry.proposeCertification(clone, SEL, 0, 100, address(0), clone.codehash);
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certify(clone, SEL);

        // The address entry exists, but no class does.
        (uint8 tier,) = registry.tierOf(clone, SEL);
        assertEq(tier, 0, "address entry resolves");
        assertEq(registry.classOf(clone), bytes32(0), "no class was created");

        vm.prank(owner);
        vm.expectRevert(TierRegistry.ClassNotCertified.selector);
        registry.demoteClass(address(template), SEL);
    }

    /// @notice And a class certification is not reachable through the address
    ///         demotion path.
    function test_namespaceIsolation_classCertNotDemotableAsAddress() public {
        _certifyClass(address(template));
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotCertified.selector);
        registry.demote(address(template), SEL);
    }

    // ── Gas: the class fallback's cost on the address-miss branch (task 6.4) ──

    /// @notice `SyndicateVault._guardBatchCalls` calls `isAdapterAllowed` once
    ///         per batch sub-call, so any cost added there is paid on every
    ///         governor batch. The class lookup runs ONLY when the address path
    ///         misses, so this measures both branches and reports the delta
    ///         rather than assuming it is negligible.
    ///
    ///         Measured, not asserted tight: the numbers are logged so a future
    ///         change that makes the miss branch materially more expensive is
    ///         visible in the diff. The bound below is a smoke test — a class
    ///         lookup is two EXTCODEHASH plus a storage read, so anything past
    ///         ~15k means the shape changed, not that it drifted.
    function test_gas_isAdapterAllowed_addressHitVsClassMiss() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        // Address-path hit: an explicitly allowlisted address returns before
        // any class work happens.
        vm.prank(owner);
        registry.setAdapterAllowed(clone, true);
        uint256 g0 = gasleft();
        bool hit = registry.isAdapterAllowed(clone);
        uint256 addressPathGas = g0 - gasleft();
        assertTrue(hit);

        // Address-path miss: falls through to the two-level class check.
        address sibling = _cloneViaFactory();
        uint256 g1 = gasleft();
        bool viaClass = registry.isAdapterAllowed(sibling);
        uint256 classPathGas = g1 - gasleft();
        assertTrue(viaClass, "sibling is allowed via its class, not by address");

        emit log_named_uint("isAdapterAllowed gas, address hit", addressPathGas);
        emit log_named_uint("isAdapterAllowed gas, class fallback", classPathGas);
        emit log_named_uint("delta paid only on address miss", classPathGas - addressPathGas);

        assertLt(classPathGas - addressPathGas, 15_000, "class fallback cost changed shape, not just drifted");
    }

    // ── Certification guards ──

    /// @notice Task 1.3: a codeless template has no class to anchor, and
    ///         anchoring one would let whatever code later appears at that
    ///         address satisfy the level-2 check (counterfactual CREATE2).
    function test_proposeClassCertification_codelessTemplateReverts() public {
        address never = makeAddr("neverDeployed");
        vm.prank(owner);
        vm.expectRevert(TierRegistry.NotAContract.selector);
        registry.proposeClassCertification(never, SEL, TIER_1, BOUND, address(0), bytes32(0));
    }

    /// @notice Template code drifting between owner review and mining voids the
    ///         proposal, mirroring the address path's guard.
    function test_proposeClassCertification_codehashDriftReverts() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.CodehashChanged.selector);
        registry.proposeClassCertification(address(template), SEL, TIER_1, BOUND, address(0), keccak256("stale"));
    }

    /// @notice A template mutated mid-window voids the pending grant rather
    ///         than certifying different bytecode under an old announcement.
    function test_certifyClass_templateMutatedMidWindowReverts() public {
        vm.prank(owner);
        registry.proposeClassCertification(
            address(template), SEL, TIER_1, BOUND, address(0), address(template).codehash
        );
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        vm.etch(address(template), hex"600160005260206000f3");
        vm.expectRevert(TierRegistry.TemplateCodehashChanged.selector);
        registry.certifyClass(address(template), SEL);
    }

    function test_certifyClass_beforeDelayReverts() public {
        vm.prank(owner);
        registry.proposeClassCertification(
            address(template), SEL, TIER_1, BOUND, address(0), address(template).codehash
        );
        vm.expectRevert(TierRegistry.CertifyDelayNotElapsed.selector);
        registry.certifyClass(address(template), SEL);
    }

    function test_certifyClass_withNoPendingReverts() public {
        vm.expectRevert(TierRegistry.NoPendingClassCertification.selector);
        registry.certifyClass(address(template), SEL);
    }

    function test_proposeClassCertification_tier2Reverts() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidTier.selector);
        registry.proposeClassCertification(address(template), SEL, 2, BOUND, address(0), address(template).codehash);
    }

    function test_proposeClassCertification_onlyOwner() public {
        vm.expectRevert();
        registry.proposeClassCertification(
            address(template), SEL, TIER_1, BOUND, address(0), address(template).codehash
        );
    }
}
