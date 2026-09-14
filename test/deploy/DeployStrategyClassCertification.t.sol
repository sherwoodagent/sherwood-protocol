// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {CertifyStrategyClasses} from "../../script/CertifyStrategyClasses.s.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

/// @dev Clone provenance without a full `StrategyFactory` init: `tierOf`'s class
///      fallback only asks the factory pointer which template a clone came from,
///      and `setStrategyFactory` only probes `cloneTemplate(0) == 0`.
contract _ProvenanceFactory {
    mapping(address clone => address template) public cloneTemplate;

    function mint(address template) external returns (address clone) {
        clone = Clones.clone(template);
        cloneTemplate[clone] = template;
    }

    function isRegisteredStrategy(address strategy) external view returns (bool) {
        return cloneTemplate[strategy] != address(0);
    }
}

/// @dev The two ceremony phases are `internal` on the script, which is where
///      they belong - this only lifts them into reach, as `SeedHarness` does
///      for `Deploy._seedTierRegistry`.
contract CertifyHarness is CertifyStrategyClasses {
    function exposed_propose(address deployer, address registry) external {
        _proposeClasses(deployer, registry);
    }

    function exposed_finalize(address registry) external {
        _finalizeClasses(registry);
    }

    /// @dev Strict mode without `vm.setEnv`: that cheatcode is process-global and
    ///      tests in a suite run in parallel, so an env-driven strict test makes
    ///      every test beside it revert. `exposed_envStrict` keeps the env var
    ///      itself pinned, and is the only place the suite touches it.
    bool internal strict;

    function setStrict(bool on) external {
        strict = on;
    }

    function _strictMode() internal view override returns (bool) {
        return strict;
    }

    function exposed_envStrict() external view returns (bool) {
        return super._strictMode();
    }

    /// @dev No shipped address book carries the `*_TEMPLATE` keys, so the
    ///      templates are injected. `useBook` hands a test the production
    ///      resolution back.
    mapping(string key => address) internal injected;
    bool internal useBook;

    function setTemplate(string calldata key, address template) external {
        injected[key] = template;
    }

    function setUseBook(bool on) external {
        useBook = on;
    }

    function _templateAddress(string memory key) internal view override returns (address) {
        return useBook ? super._templateAddress(key) : injected[key];
    }

    /// @dev The harness IS the registry owner (see `setUp`), so owner-only
    ///      set-up a test needs has to originate here. Not script surface.
    function exposed_ownerCall(address target, bytes calldata data) external {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
    }
}

/// @title script/CertifyStrategyClasses.s.sol - the strategy class ceremony
///
/// @notice A protocol deployed by the documented ceremony prices every strategy
///         proposal at FULL NOTIONAL. `SyndicateGovernor._scanCalls` reads
///         `tierOf(target, selector)` per call and an uncertified class answers
///         `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)`, so the required guardian
///         coverage is the whole declared cap of every leg. Nothing in
///         `script/` performed the class grant that lowers it.
///
/// @dev    The load-bearing assertions are on `tierOf` against a real ERC-1167
///         clone with real factory provenance - the exact read the governor
///         makes - not on "the script called certifyClass". A ceremony that ran
///         every call in the right order and still leaves a clone at tier 2 is
///         a passing call sequence and no discount at all.
///
///         Fixed to chain 4663 (the only shipped address book) so the
///         book-resolution path a strict test drives is the real one.
contract DeployStrategyClassCertificationTest is Test {
    CertifyHarness internal harness;
    TierRegistry internal registry;
    _ProvenanceFactory internal factory;

    string constant PORTFOLIO_KEY = "PORTFOLIO_TEMPLATE";
    string constant CL_KEY = "CONCENTRATED_LIQUIDITY_TEMPLATE";
    string constant MORPHO_KEY = "MORPHO_SUPPLY_TEMPLATE";

    bytes4 constant SEL_EXECUTE = IStrategy.execute.selector;
    bytes4 constant SEL_SETTLE = IStrategy.settle.selector;
    // Any selector the script does NOT walk.
    bytes4 constant SEL_THIRD = IStrategy.name.selector;

    uint8 constant TIER_1 = 1;
    uint16 constant PORTFOLIO_BOUND = 2_000;

    // The script's own halt strings, so a test cannot pass on an unrelated revert.
    bytes constant HALT_FINALIZE = bytes("class certification halted - see RUNBOOK lines above");
    bytes constant HALT_REVOKED = bytes("class previously certified then revoked - see RUNBOOK lines above");

    address internal deployer;
    address internal multisig = makeAddr("multisig");

    address internal portfolioTemplate;
    address internal clTemplate;
    address internal morphoTemplate;

    address internal portfolioClone;
    address internal clClone;
    address internal morphoClone;

    function setUp() public {
        vm.chainId(4663);

        portfolioTemplate = address(new PortfolioStrategy());
        clTemplate = address(new ConcentratedLiquidityStrategy());
        morphoTemplate = address(new MorphoSupplyStrategy());

        harness = new CertifyHarness();
        // Every registry write is nested inside the harness call, so the
        // registry owner must BE the harness - a prank on the entry call would
        // not carry into the nested write.
        deployer = address(harness);
        registry = new TierRegistry(deployer);

        harness.setTemplate(PORTFOLIO_KEY, portfolioTemplate);
        harness.setTemplate(CL_KEY, clTemplate);
        harness.setTemplate(MORPHO_KEY, morphoTemplate);

        factory = new _ProvenanceFactory();
        _ownerCall(abi.encodeCall(TierRegistry.setStrategyFactory, (address(factory))));

        portfolioClone = factory.mint(portfolioTemplate);
        clClone = factory.mint(clTemplate);
        morphoClone = factory.mint(morphoTemplate);
    }

    // -- Drivers --

    function _ownerCall(bytes memory data) internal {
        harness.exposed_ownerCall(address(registry), data);
    }

    function _propose() internal {
        harness.exposed_propose(deployer, address(registry));
    }

    function _finalize() internal {
        harness.exposed_finalize(address(registry));
    }

    function _runCeremony() internal {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        _finalize();
    }

    function _strict(bool on) internal {
        harness.setStrict(on);
    }

    function _assertPricedAt(address clone, uint8 tier, uint16 bound, string memory what) internal view {
        (uint8 execTier, uint16 execBound) = registry.tierOf(clone, SEL_EXECUTE);
        (uint8 settleTier, uint16 settleBound) = registry.tierOf(clone, SEL_SETTLE);
        assertEq(execTier, tier, string.concat(what, ": execute() tier"));
        assertEq(execBound, bound, string.concat(what, ": execute() bound"));
        assertEq(settleTier, tier, string.concat(what, ": settle() tier"));
        assertEq(settleBound, bound, string.concat(what, ": settle() bound"));
    }

    function _fullNotional(address clone, string memory what) internal view {
        _assertPricedAt(clone, registry.TIER_ARBITRARY(), registry.FULL_NOTIONAL_BPS(), what);
    }

    // -- 1. The bug, pinned --

    /// @notice Before the ceremony every strategy clone resolves to the
    ///         uncertified default, so the governor books the whole declared
    ///         cap of every leg as required guardian coverage.
    function test_beforeTheCeremony_everyStrategyCloneIsPricedAtFullNotional() public view {
        _fullNotional(portfolioClone, "portfolio clone");
        _fullNotional(clClone, "CL clone");
        _fullNotional(morphoClone, "morpho clone");
    }

    // -- 2. Phase A --

    /// @notice Phase A announces the eligible template against BOTH selectors a
    ///         governor batch names, pinning its live codehash and the declared
    ///         risk parameters.
    function test_propose_announcesThePortfolioTemplateOnBothSelectors() public {
        _propose();

        uint64 expectedReadyAt = uint64(vm.getBlockTimestamp() + registry.certifyDelay());
        bytes4[2] memory selectors = [SEL_EXECUTE, SEL_SETTLE];
        for (uint256 i; i < selectors.length; ++i) {
            TierRegistry.PendingClassCertification memory p =
                registry.pendingClassCertificationOf(portfolioTemplate, selectors[i]);
            assertEq(p.readyAt, expectedReadyAt, "selector not announced");
            assertEq(p.tier, TIER_1, "announced at the wrong tier");
            assertEq(p.extractableBoundBps, PORTFOLIO_BOUND, "announced with the wrong bound");
            assertEq(p.templateCodehash, portfolioTemplate.codehash, "template codehash not pinned");
        }
    }

    /// @notice CL and Morpho are outside the class set, so phase A announces
    ///         nothing for them even though both are in the address book.
    function test_propose_leavesTheExcludedTemplatesUnannounced() public {
        _propose();

        assertEq(registry.pendingClassCertificationOf(clTemplate, SEL_EXECUTE).readyAt, 0, "CL was announced after all");
        assertEq(
            registry.pendingClassCertificationOf(morphoTemplate, SEL_EXECUTE).readyAt,
            0,
            "Morpho was announced after all"
        );
    }

    // -- 3. The delay --

    /// @notice The delay is the reason this is two phases. Finalizing early must
    ///         surface the registry's own refusal, not be papered over by a
    ///         script-side skip that leaves the class silently uncertified.
    function test_finalize_revertsBeforeTheDelayHasElapsed() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay() - 1);

        vm.expectRevert(TierRegistry.CertifyDelayNotElapsed.selector);
        _finalize();
    }

    /// @notice Once the delay elapses the same call certifies both selectors.
    function test_finalize_certifiesBothSelectorsAfterTheDelay() public {
        _runCeremony();

        (uint8 execTier, uint16 execBound) = registry.classTierOf(portfolioTemplate, SEL_EXECUTE);
        (uint8 settleTier, uint16 settleBound) = registry.classTierOf(portfolioTemplate, SEL_SETTLE);
        assertEq(execTier, TIER_1, "execute() not certified");
        assertEq(execBound, PORTFOLIO_BOUND, "execute() bound not certified");
        assertEq(settleTier, TIER_1, "settle() not certified");
        assertEq(settleBound, PORTFOLIO_BOUND, "settle() bound not certified");
    }

    // -- 4. The property --

    /// @notice THE test: after the ceremony a clone nobody ever named is priced
    ///         at the certified bound on the exact read `_scanCalls` makes.
    function test_afterTheCeremony_aPortfolioCloneIsPricedAtTheCertifiedBound() public {
        _runCeremony();

        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "certified portfolio clone");
    }

    /// @notice The grant is class-scoped, and the exclusions are deliberate. CL
    ///         leaves `marketParams.oracle/irm/lltv` unbound on its levered path
    ///         and Morpho takes the whole tuple from init data, so neither has a
    ///         bounded loss surface to discount. Both keep paying full notional.
    function test_afterTheCeremony_theExcludedTemplatesClonesStayAtFullNotional() public {
        _runCeremony();

        _fullNotional(clClone, "CL clone after the ceremony");
        _fullNotional(morphoClone, "morpho clone after the ceremony");
    }

    // -- 5. Ownership --

    /// @notice `proposeClassCertification` is `onlyOwner`. Once the Ownable2Step
    ///         handoff completes the multisig runs phase A, and the script must
    ///         say so rather than aborting a deploy that already broadcast.
    function test_propose_isSkippedOnceOwnershipHasMoved() public {
        _handoff();

        _propose(); // must not revert

        assertEq(
            registry.pendingClassCertificationOf(portfolioTemplate, SEL_EXECUTE).readyAt,
            0,
            "wrote to a registry it no longer owns"
        );
    }

    /// @notice A merely PENDING handoff leaves the deployer as owner, which is
    ///         what makes the documented runbook order legal: core deploy ->
    ///         template deploys -> this ceremony -> multisig `acceptOwnership()`.
    function test_ceremony_stillWorksWhileTheHandoffIsMerelyPending() public {
        vm.prank(deployer);
        registry.transferOwnership(multisig);

        _runCeremony();

        assertEq(registry.owner(), deployer, "handoff completed without acceptOwnership");
        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "pending handoff blocked the ceremony");
    }

    /// @notice Phase B carries no ownership guard: `certifyClass` is
    ///         permissionless without a bond, so a handoff landing inside the
    ///         three-day gap must not strand a ceremony already announced.
    function test_finalize_completesAfterTheHandoff() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        _handoff();

        _finalize();

        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "handoff stranded the ceremony");
    }

    function _handoff() internal {
        vm.prank(deployer);
        registry.transferOwnership(multisig);
        vm.prank(multisig);
        registry.acceptOwnership();
    }

    // -- 6. Re-runs --

    /// @notice `finalize()` is re-runnable, and a re-run is a NO-OP rather than
    ///         a redundant write: an already-certified class must emit no
    ///         `ClassCertified` at all.
    function test_finalize_isIdempotent() public {
        _runCeremony();

        vm.recordLogs();
        _finalize();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != TierRegistry.ClassCertified.selector, "re-run repeated the grant");
        }
        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "re-run revoked the grant");
    }

    /// @notice A re-run of `propose()` after the ceremony must not re-announce
    ///         an already-certified class - that would replace a live grant with
    ///         a new three-day wait.
    function test_propose_isIdempotent() public {
        _runCeremony();

        _propose();

        assertEq(
            registry.pendingClassCertificationOf(portfolioTemplate, SEL_EXECUTE).readyAt,
            0,
            "re-proposed an already-certified class"
        );
    }

    /// @dev Certified outside the script: `certifyClass` is permissionless, so a
    ///      third party (or an interrupted `finalize()`) can leave the ceremony
    ///      exactly here.
    function _certifyOutsideTheScript() internal {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        registry.certifyClass(portfolioTemplate, SEL_EXECUTE);
        registry.certifyClass(portfolioTemplate, SEL_SETTLE);
    }

    /// @notice `finalize()` resumes from a half-finished ceremony: with the
    ///         grants already executed it must recognise them rather than
    ///         re-executing a pending record that no longer exists.
    function test_finalize_resumesWhenCertificationAlreadyExecuted() public {
        _certifyOutsideTheScript();

        _finalize(); // must not revert

        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "resumed finalize lost the grant");
    }

    // -- 7. The bond --

    /// @notice With a submitter bond configured, `certifyClass` becomes
    ///         submitter-only and pulls WOOD from that submitter. The script
    ///         funds no such flow, so it must refuse rather than announce a
    ///         grant nobody can execute.
    function test_propose_isSkippedWhenASubmitterBondIsConfigured() public {
        _configureBond();

        _propose();

        assertEq(
            registry.pendingClassCertificationOf(portfolioTemplate, SEL_EXECUTE).readyAt,
            0,
            "announced a grant nobody can execute"
        );
    }

    function _configureBond() internal {
        ERC20Mock wood = new ERC20Mock("WOOD", "WOOD", 18);
        _ownerCall(abi.encodeCall(TierRegistry.setWood, (address(wood))));
        _ownerCall(abi.encodeCall(TierRegistry.setSubmitterBondWood, (1e18)));
    }

    // -- 8. Half-certified, revoked, expired, drifted --

    /// @notice A governor batch names execute() AND settle(), so one certified
    ///         selector still prices the other at full notional. A cancelled
    ///         `settle()` record reads `readyAt == 0` - the same value as
    ///         "already executed" - and treating that as done ships a half class.
    function test_finalize_haltsWhenOnlyOneSelectorWasAnnounced() public {
        _propose();
        _ownerCall(abi.encodeCall(TierRegistry.cancelClassCertification, (portfolioTemplate, SEL_SETTLE)));
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());

        vm.expectRevert(HALT_FINALIZE);
        _finalize();

        (uint8 settleTier,) = registry.classTierOf(portfolioTemplate, SEL_SETTLE);
        assertEq(settleTier, registry.TIER_ARBITRARY(), "settle() was certified after all - test is vacuous");
        _fullNotional(portfolioClone, "half-certified class was priced as certified");
    }

    function _demoteForCause(bytes4 selector) internal {
        _ownerCall(abi.encodeCall(TierRegistry.setAuthorizedDemoter, (address(this))));
        registry.demoteClassByChallenge(portfolioTemplate, selector);
    }

    /// @notice A conviction revokes a class. Re-running phase A must not quietly
    ///         re-announce it - the anchor survives `_demoteClass`, so "never
    ///         certified" and "certified then taken away" are distinguishable.
    function test_propose_refusesToReannounceAClassDemotedForCause() public {
        _runCeremony();
        _demoteForCause(SEL_SETTLE);

        vm.expectRevert(HALT_REVOKED);
        _propose();

        assertEq(
            registry.pendingClassCertificationOf(portfolioTemplate, SEL_SETTLE).readyAt,
            0,
            "re-announced a class revoked for cause"
        );
    }

    /// @notice And phase B must not restore the discount on it either.
    function test_finalize_refusesToRecertifyAClassDemotedForCause() public {
        _runCeremony();
        _demoteForCause(SEL_SETTLE);

        vm.expectRevert(HALT_REVOKED);
        _finalize();

        (uint8 settleTier, uint16 settleBound) = registry.tierOf(portfolioClone, SEL_SETTLE);
        assertEq(settleTier, registry.TIER_ARBITRARY(), "re-granted a tier revoked for cause");
        assertEq(settleBound, registry.FULL_NOTIONAL_BPS(), "re-granted a discount revoked for cause");
    }

    /// @notice `_demoteClass` erases only the selector it is given, and nothing
    ///         class-wide survives it, so a conviction on a selector the script
    ///         never walks leaves execute()/settle() certified and both phases
    ///         are clean no-ops. This is the guard the allowlist used to need.
    function test_bothPhases_areNoOpsAfterAConvictionOnAnUnwalkedSelector() public {
        _runCeremony();
        _ownerCall(
            abi.encodeCall(
                TierRegistry.proposeClassCertification,
                (portfolioTemplate, SEL_THIRD, TIER_1, PORTFOLIO_BOUND, address(0), portfolioTemplate.codehash)
            )
        );
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        registry.certifyClass(portfolioTemplate, SEL_THIRD);

        _demoteForCause(SEL_THIRD);

        (uint8 thirdTier,) = registry.classTierOf(portfolioTemplate, SEL_THIRD);
        assertEq(thirdTier, registry.TIER_ARBITRARY(), "the conviction did not land - test is vacuous");

        _propose();
        _finalize();

        _assertPricedAt(portfolioClone, TIER_1, PORTFOLIO_BOUND, "an unrelated conviction disturbed the class");
    }

    /// @notice `certifyClass` is legal only inside `MAX_CERTIFY_WINDOW` past
    ///         `readyAt`. An operator who waits gets the window and the recovery
    ///         named, not a bare `CertificationExpired()`.
    function test_finalize_namesTheLapsedWindowRatherThanRevertingBare() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay() + registry.MAX_CERTIFY_WINDOW() + 1);

        vm.expectRevert(HALT_FINALIZE);
        _finalize();
    }

    /// @notice Drift carried by the PENDING records, before any anchor exists:
    ///         `certifyClass` would revert `TemplateCodehashChanged` from inside
    ///         the registry, which names neither the template nor the recovery.
    function test_finalize_detectsDriftCarriedByThePendingRecords() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        vm.etch(portfolioTemplate, address(new MorphoSupplyStrategy()).code);

        assertEq(
            registry.classAnchorOf(registry.cloneCodehashOf(portfolioTemplate)).template,
            address(0),
            "an anchor exists - the anchor check would fire instead"
        );

        vm.expectRevert(HALT_FINALIZE);
        _finalize();
    }

    /// @notice Once both grants are executed no pending record survives, so the
    ///         per-selector drift guard reads nothing. Without the ANCHOR check
    ///         `finalize()` reports success over a class whose every clone has
    ///         silently fallen back to full notional.
    function test_finalize_haltsWhenTheTemplateDriftedAfterBothGrantsExecuted() public {
        _certifyOutsideTheScript();
        vm.etch(portfolioTemplate, address(new MorphoSupplyStrategy()).code);

        assertEq(
            registry.pendingClassCertificationOf(portfolioTemplate, SEL_SETTLE).readyAt,
            0,
            "a pending record survived - the per-selector guard would catch this"
        );
        _fullNotional(portfolioClone, "drift did not void the class - test is vacuous");

        vm.expectRevert(HALT_FINALIZE);
        _finalize();
    }

    // -- 9. Strict mode --

    /// @notice Every skip path exits 0 having written nothing, which is right
    ///         behind a deploy that already broadcast and wrong for a run that IS
    ///         the ceremony step. Strict mode is the latter.
    function test_strictMode_revertsWhereTheDefaultSkips() public {
        _handoff();

        // Default: skips. Pinned by test_propose_isSkippedOnceOwnershipHasMoved.
        _strict(true);
        vm.expectRevert(bytes("deployer does not own TierRegistry - class certification would be a no-op"));
        _propose();
        _strict(false);

        _propose();
    }

    /// @notice And the knob that reaches it in production is `CERTIFY_STRICT`.
    ///         The only place this suite reads that env var, so no test running
    ///         beside it can see the flip.
    function test_strictMode_isDrivenByTheCertifyStrictEnvVar() public {
        vm.setEnv("CERTIFY_STRICT", "true");
        assertTrue(harness.exposed_envStrict(), "CERTIFY_STRICT=true did not arm strict mode");
        vm.setEnv("CERTIFY_STRICT", "false");
        assertFalse(harness.exposed_envStrict(), "strict mode stayed armed");
    }

    /// @notice With a bond configured `certifyClass` is submitter-only and pulls
    ///         WOOD. A run that IS the ceremony step must not exit 0 having
    ///         announced nothing.
    function test_strictMode_revertsWhenASubmitterBondIsConfigured() public {
        _configureBond();

        _strict(true);
        vm.expectRevert(bytes("submitterBondWood is non-zero - this script funds no bonded submitter"));
        _propose();
        _strict(false);
    }

    /// @notice The production resolution walks `chains/{chainId}.json`, which
    ///         carries no `*_TEMPLATE` key on any shipped chain today. The
    ///         default skip would certify nothing and still exit 0.
    function test_strictMode_revertsWhenATemplateIsMissingFromTheBook() public {
        harness.setUseBook(true);

        _strict(true);
        vm.expectRevert(bytes("strategy template missing from the address book"));
        _propose();

        vm.expectRevert(bytes("strategy template missing from the address book"));
        _finalize();
        _strict(false);
    }

    /// @notice The book address is present but codeless - a template deploy that
    ///         never landed, or a book pointing at the wrong chain.
    function test_strictMode_revertsWhenTheTemplateAddressHasNoCode() public {
        vm.etch(portfolioTemplate, "");
        assertEq(portfolioTemplate.code.length, 0, "etch did not clear the template - test is vacuous");

        _strict(true);
        vm.expectRevert(bytes("no code at the address book's strategy template address"));
        _propose();
        _strict(false);
    }
}
