// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {MockStrategy} from "./mocks/MockStrategy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockMToken} from "./mocks/MockMToken.sol";

/// @dev Minimal SyndicateFactory stand-in returning a non-zero
///      `vaultToSyndicate(vault)` so the factory's vault check passes.
contract _MockSyndicateRegistry {
    function vaultToSyndicate(address) external pure returns (uint256) {
        return 1;
    }
}

/// @dev Minimal vault stand-in.
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
        vm.prank(owner);
        registry.setStrategyFactory(address(factory));
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
    function _certifyClassFor(address tmpl, bytes4 sel) internal {
        vm.prank(owner);
        registry.proposeClassCertification(tmpl, sel, TIER_1, BOUND, address(0), tmpl.codehash);
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certifyClass(tmpl, sel);
    }

    function _certifyClass(address tmpl) internal {
        _certifyClassFor(tmpl, SEL);
    }

    function _certifyAndAllowClass(address tmpl) internal {
        _certifyClass(tmpl);
    }

    // ── 5.1 Membership positive ──

    /// @notice The whole point: a clone is tiered with NO per-clone owner action.
    function test_classMembership_cloneInheritsTier() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_1, "clone inherits the class tier");
        assertEq(bound, BOUND, "clone inherits the class bound");
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
        assertEq(registry.classOf(address(template)), bytes32(0), "belongs to no class");
    }

    /// @notice A clone of an UNcertified template is not a member.
    function test_classMembership_cloneOfOtherTemplateIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        MockStrategy other = new MockStrategy();
        address foreign = Clones.clone(address(other));
        (uint8 tier,) = registry.tierOf(foreign, SEL);
        assertEq(tier, 2, "different template, different class");
    }

    /// @notice An EOA belongs to no class.
    function test_classMembership_eoaIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        assertEq(registry.classOf(makeAddr("eoa")), bytes32(0));
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

    /// @notice A byte-identical `Clones.clone` the factory never deployed is
    ///         refused on the tier and funds axes. Bytecode alone is not the
    ///         proof: those axes also require the factory to name the same
    ///         template. The callee axis is the deliberate exception — being
    ///         callable confers no right to receive value, and conditioning it
    ///         on provenance would strand real clones behind a re-point.
    function test_classMembership_cloneMadeOutsideFactoryIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        address rogue = Clones.clone(address(template));
        address minted = _cloneViaFactory();
        assertEq(rogue.codehash, minted.codehash, "byte-identical to a factory clone");

        (uint8 tier, uint16 bound) = registry.tierOf(rogue, SEL);
        assertEq(tier, 2, "no provenance, no class tier");
        assertEq(bound, 10_000);
        assertEq(registry.classOf(rogue), bytes32(0), "belongs to no class");

        (uint8 mTier,) = registry.tierOf(minted, SEL);
        assertEq(mTier, TIER_1, "control: the factory's own clone is a member");
    }

    /// @notice A clone the factory DID deploy whose bytecode is later moved
    ///         away from the anchor codehash is not a member either — the
    ///         provenance record is a second condition, never a replacement.
    function test_classMembership_factoryCloneWithDriftedBytecodeIsNotAMember() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        assertEq(registry.classOf(clone), registry.cloneCodehashOf(address(template)), "precondition: a member");

        vm.etch(clone, hex"600160005260206000f3");

        assertEq(registry.classOf(clone), bytes32(0), "drifted bytecode leaves the class");
        (uint8 tier,) = registry.tierOf(clone, SEL);
        assertEq(tier, 2);
        assertEq(factory.cloneTemplate(clone), address(template), "even though provenance still says so");
    }

    // ── 5.5b The factory pointer ──

    function test_setStrategyFactory_onlyOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.setStrategyFactory(address(factory));
    }

    function test_setStrategyFactory_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidStrategyFactory.selector);
        registry.setStrategyFactory(address(0));
    }

    /// @notice Every class read STATICCALLs the factory, so an EOA there would
    ///         revert `tierOf` for every target — every proposal included.
    function test_setStrategyFactory_rejectsAnEoa() public {
        address eoa = makeAddr("notAFactory");
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidStrategyFactory.selector);
        registry.setStrategyFactory(eoa);
    }

    /// @notice Fail closed: a registry with no factory wired resolves no class
    ///         at all, however complete the certification ceremony was.
    function test_classOf_isZeroWhileTheFactoryIsUnset() public {
        TierRegistry fresh = new TierRegistry(owner);
        assertEq(fresh.strategyFactory(), address(0), "precondition: unset");

        vm.startPrank(owner);
        fresh.proposeClassCertification(address(template), SEL, TIER_1, BOUND, address(0), address(template).codehash);
        vm.warp(block.timestamp + fresh.certifyDelay() + 1);
        vm.stopPrank();
        fresh.certifyClass(address(template), SEL);

        address clone = _cloneViaFactory();
        assertEq(fresh.classOf(clone), bytes32(0), "no factory, no class");
        (uint8 tier,) = fresh.tierOf(clone, SEL);
        assertEq(tier, 2);
    }

    /// @notice A contract that does not answer `cloneTemplate` cannot be the
    ///         provenance source — every class read would have to interpret its
    ///         silence, so the pointer is probed before it is accepted.
    function test_setStrategyFactory_refusesAContractWithoutTheProvenanceSelector() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.InvalidStrategyFactory.selector);
        registry.setStrategyFactory(address(syndicateRegistry));
    }

    /// @notice Re-pointing the registry at a different factory takes the tier
    ///         and funds axes from clones the old factory minted, but NOT the
    ///         callee axis: the vault must still be able to call in and reclaim
    ///         capital the clone is holding. Pointing back restores all three.
    function test_repointingTheFactoryClosesTheClassTierUntilPointedBack() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        (uint8 tier0,) = registry.tierOf(clone, SEL);
        assertEq(tier0, TIER_1, "precondition: certified tier");

        StrategyFactory replacement = new StrategyFactory(address(syndicateRegistry), address(this));
        vm.prank(owner);
        registry.setStrategyFactory(address(replacement));

        (uint8 tier1,) = registry.tierOf(clone, SEL);
        assertEq(tier1, 2, "and the tier falls back to the uncertified default");

        vm.prank(owner);
        registry.setStrategyFactory(address(factory));
        (uint8 tier2,) = registry.tierOf(clone, SEL);
        assertEq(tier2, TIER_1, "and the certified tier");
    }

    /// @notice A factory whose code stops answering `cloneTemplate` degrades
    ///         every class read to a non-member answer instead of reverting it.
    ///         A reverting `tierOf` would take the whole batch guard down.
    function test_classReadsDegradeWhenTheFactoryStopsAnsweringProvenance() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        // Bytecode that reverts with empty returndata for every call.
        vm.etch(address(factory), hex"60006000fd");

        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, 2, "no provenance answer, no class tier");
        assertEq(bound, 10_000);
        assertEq(registry.classOf(clone), bytes32(0), "the target belongs to no class");
    }

    // ── 5.5c Re-pointing the class at new template code ──

    /// @notice Certifications are keyed to the template codehash they were
    ///         reviewed against. Re-certifying ONE selector against new
    ///         template code must not revive the selectors certified against
    ///         the old code, nor the class's funds and callee bits.
    function test_recertifyingAgainstNewTemplateCodeOrphansTheOldCertifications() public {
        bytes4 selB = bytes4(keccak256("settle()"));
        bytes4 selC = bytes4(keccak256("unwind()"));

        _certifyClassFor(address(template), SEL);
        _certifyClassFor(address(template), selB);
        address clone = _cloneViaFactory();

        (uint8 tA,) = registry.tierOf(clone, SEL);
        (uint8 tB,) = registry.tierOf(clone, selB);
        assertEq(tA, TIER_1, "precondition: A certified");
        assertEq(tB, TIER_1, "precondition: B certified");

        // The template's code moves; the clone's own codehash does not.
        vm.etch(address(template), hex"600160005260206000f3");
        _certifyClassFor(address(template), selC);

        (uint8 tA2,) = registry.tierOf(clone, SEL);
        (uint8 tB2,) = registry.tierOf(clone, selB);
        (uint8 tC,) = registry.tierOf(clone, selC);
        assertEq(tA2, 2, "A was certified against the old template code");
        assertEq(tB2, 2, "and so was B");
        assertEq(tC, TIER_1, "only the selector reviewed against the new code is served");

        (uint8 tA3,) = registry.tierOf(clone, SEL);
        assertEq(tA3, 2, "and still does not revive A");
    }

    /// @notice Re-certifying against UNCHANGED template code is not a re-point:
    ///         sibling selectors keep resolving.
    function test_recertifyingAgainstUnchangedTemplateCodeKeepsSiblingSelectors() public {
        bytes4 selB = bytes4(keccak256("settle()"));
        _certifyClassFor(address(template), SEL);
        _certifyClassFor(address(template), selB);
        address clone = _cloneViaFactory();

        vm.prank(owner);
        registry.demoteClass(address(template), selB);
        _certifyClassFor(address(template), selB);

        (uint8 tA,) = registry.tierOf(clone, SEL);
        (uint8 tB,) = registry.tierOf(clone, selB);
        assertEq(tA, TIER_1, "A is untouched by B's re-certification");
        assertEq(tB, TIER_1, "and B is restored");
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
    }

    /// @notice Re-certification restores the class tier; nothing else needs restoring.
    function test_demoteClass_reCertificationRestoresTheTier() public {
        _certifyClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(owner);
        registry.demoteClass(address(template), SEL);
        (uint8 demoted,) = registry.tierOf(clone, SEL);
        assertEq(demoted, 2, "demoted");

        _certifyClass(address(template));
        (uint8 tier,) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_1, "tier is restored by re-certification");
    }

    function test_demoteClass_onUncertifiedClassReverts() public {
        vm.prank(owner);
        vm.expectRevert(TierRegistry.ClassNotCertified.selector);
        registry.demoteClass(address(template), SEL);
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
