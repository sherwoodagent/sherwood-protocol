// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
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

/// @notice REVOCATION VS THE CLASS FALLBACK.
///
///         This registry expresses revocation as ERASURE: `_demote` deletes
///         `_configs[k]` and `_adapterAllowed[target]`, which was a complete
///         revocation only because the absence of a record WAS the tier-2
///         default. `codehash-class-certification` put a permissive fallback
///         behind that absence, so without the per-member denial flags every
///         demotion against a class member became a silent no-op — the record
///         was still deleted, but the very next read landed on the class and
///         returned the standing that had just been taken away.
///
///         Worse, the demotion guards keyed off the ADDRESS entry, so the
///         normal class-certified clone (which has no address entry) reverted
///         `NotCertified` into `ChallengeGame`'s bare catch: a won challenge
///         produced an `AdapterDemotionFailed` event and nothing else.
///
///         These tests pin the property the erasure model depends on: a record
///         may be absent because it was never granted, or absent because it was
///         TAKEN AWAY, and only the first may consult the class.
contract TierRegistryClassMemberDenialTest is Test {
    TierRegistry registry;
    StrategyFactory factory;
    MockStrategy template;
    ERC20Mock usdc;
    MockMToken mUsdc;
    _MockSyndicateRegistry syndicateRegistry;
    _MockVault vault;

    address owner = makeAddr("owner");
    address vaultOwner = makeAddr("vaultOwner");
    address court = makeAddr("court");

    bytes4 constant SEL = bytes4(keccak256("execute()"));
    bytes4 constant OTHER_SEL = bytes4(keccak256("settle()"));
    uint8 constant TIER_1 = 1;
    uint8 constant TIER_ARBITRARY = 2;
    uint16 constant BOUND = 500;
    uint16 constant FULL_NOTIONAL_BPS = 10_000;

    function setUp() public {
        registry = new TierRegistry(owner);
        syndicateRegistry = new _MockSyndicateRegistry();
        factory = new StrategyFactory(address(syndicateRegistry), address(this));
        template = new MockStrategy();
        factory.setTemplateApproval(address(template), true);
        usdc = new ERC20Mock("USDC", "USDC", 6);
        mUsdc = new MockMToken(address(usdc), "Moonwell USDC", "mUsdc");
        vault = new _MockVault(vaultOwner);
        vm.prank(owner);
        registry.setAuthorizedDemoter(court);
    }

    function _cloneViaFactory() internal returns (address clone) {
        bytes memory initData = abi.encode(address(usdc), address(mUsdc), 1_000e6, 990e6, false);
        vm.prank(vaultOwner);
        clone = factory.cloneAndInit(address(template), address(vault), vaultOwner, initData);
    }

    function _certifyClass(address tmpl, bytes4 sel) internal {
        vm.prank(owner);
        registry.proposeClassCertification(tmpl, sel, TIER_1, BOUND, address(0), tmpl.codehash);
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certifyClass(tmpl, sel);
    }

    function _certifyAndAllowClass(address tmpl) internal {
        _certifyClass(tmpl, SEL);
        vm.prank(owner);
        registry.setClassAllowed(tmpl, true);
    }

    function _assertFullyTrusted(address clone, string memory ctx) internal view {
        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_1, string.concat(ctx, ": tier"));
        assertEq(bound, BOUND, string.concat(ctx, ": bound"));
        assertTrue(registry.isAdapterAllowed(clone), string.concat(ctx, ": allowlist"));
    }

    function _assertFullyRevoked(address clone, string memory ctx) internal view {
        (uint8 tier, uint16 bound) = registry.tierOf(clone, SEL);
        assertEq(tier, TIER_ARBITRARY, string.concat(ctx, ": tier"));
        assertEq(bound, FULL_NOTIONAL_BPS, string.concat(ctx, ": bound"));
        assertFalse(registry.isAdapterAllowed(clone), string.concat(ctx, ": allowlist"));
    }

    // ── The core regression: a conviction must actually land ──

    /// @notice THE test this whole change exists for. A class-only clone is the
    ///         normal case under class certification — it has no address entry
    ///         at all — so the address-keyed demotion guard made it unreachable.
    ///         `ChallengeGame` swallows the revert, so the failure mode was a
    ///         won challenge that changed nothing on-chain.
    function test_demoteByChallenge_classOnlyMemberIsReachable() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        _assertFullyTrusted(clone, "before conviction");

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);

        _assertFullyRevoked(clone, "after conviction");
    }

    /// @notice And the erasure sticks across a re-read: the class is still
    ///         certified and still allowlisted, so nothing but the denial flags
    ///         is holding this clone down.
    function test_demoteByChallenge_convictionSurvivesWhileClassStaysLive() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);

        (uint8 classTier,) = registry.classTierOf(address(template), SEL);
        assertEq(classTier, TIER_1, "the class itself is untouched");
        assertTrue(registry.isClassAllowed(address(template)), "and still allowlisted");
        assertTrue(registry.isClassTierDenied(clone, SEL), "the member is denied");
        assertTrue(registry.isClassAllowDenied(clone), "on both axes");
        _assertFullyRevoked(clone, "re-read");
    }

    /// @notice THE RESIDUAL LEFT OPEN BY pashov 2026-08 finding #15, pinned so
    ///         it is never mistaken for a closed case. That fix stopped
    ///         `_demote` from erasing an EXPLICIT `_adapterAllowed` entry, so an
    ///         address-allowlisted target keeps the batch-callee standing the
    ///         vault needs to run an already-committed settlement batch. A clone
    ///         standing ONLY on its class has no such entry: `isAdapterAllowed`
    ///         falls through to the `_classAllowDenied` check, which `_demote`
    ///         still sets, and the clone loses callee standing exactly as
    ///         before. If that clone is the in-flight strategy holding the
    ///         vault's capital, `settleProposal`/`unstick`/
    ///         `finalizeEmergencySettle` still revert `DisallowedBatchCallee`
    ///         and LP exits are still shut until an owner ceremony.
    ///
    ///         Closing it means separating the conviction RECORD from the
    ///         class-denial FLAG (they are one mapping today, and the governor's
    ///         propose-time refusal reads it). That was deliberately not taken
    ///         in the finding-#15 change. Change this test's expectations only
    ///         alongside that separation.
    function test_conviction_classOnlyMemberStillLosesCalleeStanding() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        assertTrue(registry.isAdapterAllowed(clone), "class fallback grants callee standing");

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);

        assertFalse(registry.isAdapterAllowed(clone), "RESIDUAL: class-only standing is still revoked on conviction");
        assertTrue(registry.isClassAllowDenied(clone));
    }

    /// @notice Blast radius is one clone. The point of a per-member denial is
    ///         that the alternative — `demoteClass` — revokes every clone of the
    ///         template, guilty and innocent together.
    function test_demoteByChallenge_siblingClonesUnaffected() public {
        _certifyAndAllowClass(address(template));
        address guilty = _cloneViaFactory();
        address sibling = _cloneViaFactory();

        vm.prank(court);
        registry.demoteByChallenge(guilty, SEL);

        _assertFullyRevoked(guilty, "guilty");
        _assertFullyTrusted(sibling, "sibling");

        // And a clone deployed AFTER the conviction still inherits the class.
        _assertFullyTrusted(_cloneViaFactory(), "later clone");
    }

    /// @notice Denial granularity matches the certification it erases: the tier
    ///         axis is per-selector, so an unrelated certified selector keeps
    ///         reading the class. The ALLOWLIST axis is deliberately broader —
    ///         see `_demote`'s over-broadness note — so it goes either way.
    function test_demote_otherSelectorKeepsReadingTheClass() public {
        _certifyClass(address(template), SEL);
        _certifyClass(address(template), OTHER_SEL);
        address clone = _cloneViaFactory();

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);

        (uint8 demotedTier,) = registry.tierOf(clone, SEL);
        assertEq(demotedTier, TIER_ARBITRARY, "convicted selector is revoked");
        (uint8 otherTier, uint16 otherBound) = registry.tierOf(clone, OTHER_SEL);
        assertEq(otherTier, TIER_1, "unrelated selector still reads the class");
        assertEq(otherBound, BOUND, "including its bound");
    }

    /// @notice The address-certified variant of the same bug: here `_demote`
    ///         had something to delete, so it succeeded — and the class then
    ///         handed the standing straight back.
    function test_demote_addressCertifiedCloneIsNotRestoredByItsClass() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.startPrank(owner);
        registry.proposeCertification(clone, SEL, 0, 100, address(0), clone.codehash);
        vm.stopPrank();
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certify(clone, SEL);
        (uint8 tierBefore,) = registry.tierOf(clone, SEL);
        assertEq(tierBefore, 0, "address entry wins while live");

        vm.prank(owner);
        registry.demote(clone, SEL);

        _assertFullyRevoked(clone, "after address demotion");
    }

    // ── Owner-level denial, the same hole through a different door ──

    /// @notice `setAdapterAllowed(x, false)` was a no-op against a class member:
    ///         the address flag went false, the class fallback ran, and the next
    ///         read returned true. The owner could not disallow a single member.
    function test_setAdapterAllowed_falseBeatsTheClassFallback() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();
        assertTrue(registry.isAdapterAllowed(clone), "allowed via class");

        vm.prank(owner);
        registry.setAdapterAllowed(clone, false);

        assertFalse(registry.isAdapterAllowed(clone), "owner denial holds");
        assertTrue(registry.isAdapterAllowed(_cloneViaFactory()), "siblings unaffected");
    }

    /// @notice And `true` is the recovery ceremony, exactly as it already was on
    ///         the address path — no new instant-grant surface, just the
    ///         existing one made to mean what it says.
    function test_setAdapterAllowed_trueRestoresStandingAfterConviction() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);
        assertFalse(registry.isAdapterAllowed(clone), "revoked");

        vm.prank(owner);
        registry.setAdapterAllowed(clone, true);

        assertTrue(registry.isAdapterAllowed(clone), "owner restored it");
        assertFalse(registry.isClassAllowDenied(clone), "denial cleared");
    }

    /// @notice The TIER axis has no instant restore, deliberately: recovery is
    ///         the ordinary announced `proposeCertification` / `certify`
    ///         ceremony, whose address entry wins ahead of both the denial flag
    ///         and the class. A clearable tier denial would be an instant owner
    ///         path to re-price a convicted address, undercutting `certifyDelay`.
    function test_demotedMember_recoversTierOnlyThroughTheAnnouncedCeremony() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(court);
        registry.demoteByChallenge(clone, SEL);
        assertTrue(registry.isClassTierDenied(clone, SEL), "denied");

        // Re-allowlisting does NOT re-price it.
        vm.prank(owner);
        registry.setAdapterAllowed(clone, true);
        (uint8 stillDemoted,) = registry.tierOf(clone, SEL);
        assertEq(stillDemoted, TIER_ARBITRARY, "allowlist restore does not restore tier");

        // The announced ceremony does, and only after the delay.
        vm.prank(owner);
        registry.proposeCertification(clone, SEL, TIER_1, BOUND, address(0), clone.codehash);
        (uint8 duringDelay,) = registry.tierOf(clone, SEL);
        assertEq(duringDelay, TIER_ARBITRARY, "still demoted during the announcement window");

        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certify(clone, SEL);
        (uint8 restored, uint16 restoredBound) = registry.tierOf(clone, SEL);
        assertEq(restored, TIER_1, "address entry restores the tier");
        assertEq(restoredBound, BOUND, "at its announced bound");
    }

    // ── The anti-grief guard the widened check must not lose ──

    /// @notice `_isCertifiedFor` widened the demotion guard to accept class
    ///         members, and must NOT have widened it to accept anything else.
    ///         `ChallengeGame.file` only checks that the named pair appears in
    ///         the executed calldata, so a selector certified NOWHERE is still
    ///         rejected — otherwise a challenger could name a routine
    ///         uncertified selector on a legitimate adapter and strip its whole
    ///         fund-movement standing for the price of one filing.
    function test_demoteByChallenge_uncertifiedSelectorStillReverts() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.prank(court);
        vm.expectRevert(TierRegistry.NotCertified.selector);
        registry.demoteByChallenge(clone, OTHER_SEL);

        _assertFullyTrusted(clone, "untouched by the failed filing");
    }

    /// @notice A non-member with no certification anywhere is likewise still
    ///         rejected — the widening keys off class MEMBERSHIP, not off the
    ///         existence of some class somewhere.
    function test_demoteByChallenge_nonMemberStillReverts() public {
        _certifyAndAllowClass(address(template));
        address stranger = address(new MockStrategy());

        vm.prank(court);
        vm.expectRevert(TierRegistry.NotCertified.selector);
        registry.demoteByChallenge(stranger, SEL);
    }

    /// @notice A demotion is still gated on the demoter role. Pinned here
    ///         because `_isCertifiedFor` sits next to that check.
    function test_demoteByChallenge_stillRoleGated() public {
        _certifyAndAllowClass(address(template));
        address clone = _cloneViaFactory();

        vm.expectRevert(TierRegistry.NotAuthorizedDemoter.selector);
        registry.demoteByChallenge(clone, SEL);
    }

    // ── Non-members pay the flags but are otherwise unaffected ──

    /// @notice `_demote` sets both flags unconditionally rather than probing
    ///         class membership first, so revocation completeness never depends
    ///         on membership state that can change afterwards. For a target that
    ///         belongs to no class this is two SSTOREs and no behaviour change.
    function test_demote_nonMemberBehaviourUnchanged() public {
        address plain = address(new MockStrategy());
        vm.startPrank(owner);
        registry.proposeCertification(plain, SEL, TIER_1, BOUND, address(0), plain.codehash);
        vm.stopPrank();
        vm.warp(block.timestamp + registry.certifyDelay() + 1);
        registry.certify(plain, SEL);
        vm.prank(owner);
        registry.setAdapterAllowed(plain, true);

        vm.prank(owner);
        registry.demote(plain, SEL);

        (uint8 tier, uint16 bound) = registry.tierOf(plain, SEL);
        assertEq(tier, TIER_ARBITRARY, "tier-2 default as always");
        assertEq(bound, FULL_NOTIONAL_BPS, "full notional as always");
        // pashov 2026-08 finding #15: the demotion no longer erases an EXPLICIT
        // address-level allow — that erasure is what bricked the settlement of
        // an already-executed proposal naming this target. The conviction is
        // recorded in `_classAllowDenied` and enforced at propose time instead.
        assertTrue(registry.isAdapterAllowed(plain), "explicit allow survives the demotion");
        assertTrue(registry.isClassAllowDenied(plain), "the conviction is recorded");
    }
}
