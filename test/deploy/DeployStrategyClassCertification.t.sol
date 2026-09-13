// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CertifyStrategyClasses} from "../../script/CertifyStrategyClasses.s.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {ConcentratedLiquidityStrategy} from "../../src/strategies/ConcentratedLiquidityStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockProposalStatus} from "../mocks/MockProposalStatus.sol";

/// @dev The two ceremony phases are `internal` on the script, which is where
///      they belong - this only lifts them into reach, as `SeedHarness` does
///      for `Deploy._seedTierRegistry`.
contract CertifyHarness is CertifyStrategyClasses {
    function exposed_propose(address deployer, address registry) external {
        _proposeClasses(deployer, registry);
    }

    function exposed_finalize(address deployer, address registry) external {
        _finalizeClasses(deployer, registry);
    }
}

/// @title script/CertifyStrategyClasses.s.sol - the strategy class ceremony
///
/// @notice A protocol deployed without this ceremony cannot execute a single
///         strategy proposal. Every batch naming a strategy clone dies in
///         `SyndicateVault._guardBatchCalls`: the callee axis refuses the clone
///         as a target (`DisallowedBatchCallee`) and the funds axis refuses it
///         as a recipient (`DisallowedTransferTarget`). Nothing in `script/`
///         performed the class writes that open those axes.
///
/// @dev    The load-bearing assertions here are on a real vault batch against a
///         real ERC-1167 clone, not on "the script called propose". A clone's
///         standing is derived from its CODEHASH, so a ceremony that ran every
///         call in the right order and still left the class unallowed is a
///         passing call sequence and a dead protocol.
///
///         Fixed to chain 9994663 (the vnet book) because it is the only
///         address book carrying all three `*_TEMPLATE` keys - the script walks
///         it, so a key renamed or dropped there breaks this test.
contract DeployStrategyClassCertificationTest is Test {
    CertifyHarness internal harness;
    TierRegistry internal registry;

    // chains/9994663.json - the script reads templates by these keys.
    address constant PORTFOLIO_TEMPLATE = 0x0e768a93B814282776022c3EBfc4e3f22Fa1605E;
    address constant CL_TEMPLATE = 0xAEAdFe50002c75bB2DE013752aE7e3633427d128;
    address constant MORPHO_TEMPLATE = 0xDd302ffcfA08071780eC1A2f12BccFB9ba6b6731;

    bytes4 constant SEL_EXECUTE = IStrategy.execute.selector;
    bytes4 constant SEL_SETTLE = IStrategy.settle.selector;

    address internal deployer;
    address internal multisig = makeAddr("multisig");
    address internal alice = makeAddr("alice");

    address internal portfolioClone;
    address internal clClone;
    address internal morphoClone;

    // Vault fixture - the real guard, not a stand-in for it.
    SyndicateVault internal vault;
    ERC20Mock internal usdc;
    MockProposalStatus internal governor;

    function setUp() public {
        vm.chainId(9994663);

        // The book's template addresses are fixed, so put real template code at
        // them: `cloneCodehashOf` is derived from the template ADDRESS, and the
        // script's own liveness check reads `template.code.length`.
        vm.etch(PORTFOLIO_TEMPLATE, address(new PortfolioStrategy()).code);
        vm.etch(CL_TEMPLATE, address(new ConcentratedLiquidityStrategy()).code);
        vm.etch(MORPHO_TEMPLATE, address(new MorphoSupplyStrategy()).code);

        portfolioClone = Clones.clone(PORTFOLIO_TEMPLATE);
        clClone = Clones.clone(CL_TEMPLATE);
        morphoClone = Clones.clone(MORPHO_TEMPLATE);

        harness = new CertifyHarness();
        // Every registry write is nested inside the harness call, so the
        // registry owner must BE the harness - a prank on the entry call would
        // not carry into the nested write.
        deployer = address(harness);
        registry = new TierRegistry(deployer);

        _deployVault();
    }

    function _deployVault() private {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        MockAgentRegistry agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: makeAddr("vaultOwner"),
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        governor = new MockProposalStatus();
        governor.setTierRegistry(address(registry));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        usdc.mint(alice, 1_000_000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(10_000e6, alice);
        vm.stopPrank();
    }

    // -- Ceremony drivers --

    function _propose() internal {
        harness.exposed_propose(deployer, address(registry));
    }

    function _finalize() internal {
        harness.exposed_finalize(deployer, address(registry));
    }

    function _runCeremony() internal {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        _finalize();
    }

    // -- Vault batch drivers --

    function _one(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _exec(BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(address(governor));
        vault.executeGovernorBatch(calls, new uint256[](0), type(uint256).max);
    }

    /// @dev Callee axis probe. `name()` is unrecognized by the selector switch,
    ///      so it reaches the clone iff PART 2a let the target through.
    function _callClone(address clone) internal {
        _exec(_one(clone, abi.encodeCall(IStrategy.name, ())));
    }

    /// @dev Funds axis probe: the vault paying the clone one unit of asset.
    function _payClone(address clone) internal {
        _exec(_one(address(usdc), abi.encodeCall(usdc.transfer, (clone, 1))));
    }

    // -- 1. The bug, pinned --

    /// @notice Before the ceremony a clone is on neither axis, and the vault
    ///         refuses both the call and the payment - this is what a freshly
    ///         deployed protocol ships as today.
    function test_beforeTheCeremony_theVaultRefusesEveryBatchNamingAClone() public {
        assertFalse(registry.isCallableTarget(portfolioClone), "clone callable before certification");
        assertFalse(registry.isAdapterAllowed(portfolioClone), "clone fundable before certification");

        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, portfolioClone));
        _callClone(portfolioClone);

        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, address(usdc), usdc.transfer.selector, portfolioClone
            )
        );
        _payClone(portfolioClone);
    }

    // -- 2. Phase A --

    /// @notice Phase A announces every eligible template against BOTH selectors
    ///         a governor batch names, pinning the template's live codehash and
    ///         the declared risk parameters.
    function test_propose_announcesEveryTemplateOnBothSelectors() public {
        _propose();

        uint64 expectedReadyAt = uint64(vm.getBlockTimestamp() + registry.certifyDelay());
        address[2] memory templates = [PORTFOLIO_TEMPLATE, CL_TEMPLATE];
        bytes4[2] memory selectors = [SEL_EXECUTE, SEL_SETTLE];

        for (uint256 i; i < templates.length; ++i) {
            for (uint256 j; j < selectors.length; ++j) {
                TierRegistry.PendingClassCertification memory p =
                    registry.pendingClassCertificationOf(templates[i], selectors[j]);
                assertEq(p.readyAt, expectedReadyAt, "selector not announced");
                assertEq(p.tier, 1, "announced at the wrong tier");
                assertEq(p.extractableBoundBps, 2_000, "announced with the wrong bound");
                assertEq(p.templateCodehash, templates[i].codehash, "template codehash not pinned");
            }
        }
    }

    // -- 3. The delay --

    /// @notice The delay is the reason this is two phases. Finalizing early must
    ///         surface the registry's own refusal, not be papered over by a
    ///         script-side skip that leaves the class silently unallowed.
    function test_finalize_revertsBeforeTheDelayHasElapsed() public {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay() - 1);

        vm.expectRevert(TierRegistry.CertifyDelayNotElapsed.selector);
        _finalize();
    }

    /// @notice Once the delay elapses the same call certifies both selectors.
    function test_finalize_certifiesBothSelectorsAfterTheDelay() public {
        _runCeremony();

        (uint8 execTier, uint16 execBound) = registry.classTierOf(PORTFOLIO_TEMPLATE, SEL_EXECUTE);
        (uint8 settleTier, uint16 settleBound) = registry.classTierOf(PORTFOLIO_TEMPLATE, SEL_SETTLE);
        assertEq(execTier, 1, "execute() not certified");
        assertEq(execBound, 2_000, "execute() bound not certified");
        assertEq(settleTier, 1, "settle() not certified");
        assertEq(settleBound, 2_000, "settle() bound not certified");
    }

    // -- 4. The property --

    /// @notice THE test: after the ceremony a clone nobody ever named clears
    ///         both axes, and the vault executes a batch that called and paid
    ///         it. Certification alone does not do this - `setClassAllowed` is a
    ///         separate owner write and `certifyClass` never performs it.
    function test_afterTheCeremony_theVaultAcceptsABatchNamingAClone() public {
        _runCeremony();

        assertTrue(registry.isCallableTarget(portfolioClone), "clone not callable after ceremony");
        assertTrue(registry.isAdapterAllowed(portfolioClone), "clone not fundable after ceremony");
        assertTrue(registry.isCallableTarget(clClone), "CL clone not callable after ceremony");
        assertTrue(registry.isAdapterAllowed(clClone), "CL clone not fundable after ceremony");

        _callClone(portfolioClone);
        _payClone(portfolioClone);
        assertEq(usdc.balanceOf(portfolioClone), 1, "vault could not pay the clone");
    }

    /// @notice The grant is class-scoped, not global. `MorphoSupplyStrategy` is
    ///         deliberately excluded from the class set (it validates its Morpho
    ///         address by asking that address), so its clones stay refused.
    function test_afterTheCeremony_anExcludedTemplatesCloneIsStillRefused() public {
        _runCeremony();

        assertFalse(registry.isCallableTarget(morphoClone), "excluded template's clone became callable");
        assertFalse(registry.isAdapterAllowed(morphoClone), "excluded template's clone became fundable");

        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, morphoClone));
        _callClone(morphoClone);
    }

    // -- 5. Ownership --

    /// @notice Both phases are `onlyOwner` writes. Once the Ownable2Step handoff
    ///         completes the multisig runs the ceremony, and the script must say
    ///         so rather than aborting a deploy that already broadcast.
    function test_ceremony_isSkippedOnceOwnershipHasMoved() public {
        vm.prank(deployer);
        registry.transferOwnership(multisig);
        vm.prank(multisig);
        registry.acceptOwnership();

        // Neither phase may revert.
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        _finalize();

        assertFalse(registry.isClassAllowed(PORTFOLIO_TEMPLATE), "wrote to a registry it no longer owns");
    }

    /// @notice A merely PENDING handoff leaves the deployer as owner, which is
    ///         what makes the documented runbook order legal: core deploy ->
    ///         template deploys -> this ceremony -> multisig `acceptOwnership()`.
    function test_ceremony_stillWorksWhileTheHandoffIsMerelyPending() public {
        vm.prank(deployer);
        registry.transferOwnership(multisig);

        _runCeremony();

        assertEq(registry.owner(), deployer, "handoff completed without acceptOwnership");
        assertTrue(registry.isClassAllowed(PORTFOLIO_TEMPLATE), "pending handoff blocked the ceremony");
    }

    // -- 6. Re-runs --

    /// @notice `finalize()` is re-runnable, and a re-run is a NO-OP rather than
    ///         a redundant owner write: an already-allowed class must emit no
    ///         `ClassAllowedSet` at all.
    function test_finalize_isIdempotent() public {
        _runCeremony();

        vm.recordLogs();
        _finalize();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(
                logs[i].topics[0] != TierRegistry.ClassAllowedSet.selector, "re-run repeated the setClassAllowed write"
            );
        }
        assertTrue(registry.isCallableTarget(portfolioClone), "re-run revoked the callee axis");
        assertTrue(registry.isAdapterAllowed(portfolioClone), "re-run revoked the funds axis");
    }

    /// @notice A re-run of `propose()` after the ceremony must not re-announce
    ///         an already-allowed class.
    function test_propose_isIdempotent() public {
        _runCeremony();

        _propose();

        assertEq(
            registry.pendingClassCertificationOf(PORTFOLIO_TEMPLATE, SEL_EXECUTE).readyAt,
            0,
            "re-proposed an already-certified class"
        );
    }

    /// @dev Certified but NOT allowed: `certifyClass` is permissionless, so a
    ///      third party (or an interrupted `finalize()`) can leave the ceremony
    ///      exactly here. The outer already-allowed skip does not cover it.
    function _certifyOutsideTheScript() internal {
        _propose();
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        registry.certifyClass(PORTFOLIO_TEMPLATE, SEL_EXECUTE);
        registry.certifyClass(PORTFOLIO_TEMPLATE, SEL_SETTLE);
        registry.certifyClass(CL_TEMPLATE, SEL_EXECUTE);
        registry.certifyClass(CL_TEMPLATE, SEL_SETTLE);
    }

    /// @notice `finalize()` resumes from a half-finished ceremony: with the
    ///         grants already executed it must open the axes rather than
    ///         re-executing a pending record that no longer exists.
    function test_finalize_resumesWhenCertificationAlreadyExecuted() public {
        _certifyOutsideTheScript();

        _finalize();

        assertTrue(registry.isCallableTarget(portfolioClone), "clone not callable after resumed finalize");
        assertTrue(registry.isAdapterAllowed(portfolioClone), "clone not fundable after resumed finalize");
    }

    /// @notice `propose()` re-run against a certified-but-unallowed class must
    ///         not re-announce it — that would replace a live grant with a new
    ///         three-day wait.
    function test_propose_doesNotReannounceACertifiedButUnallowedClass() public {
        _certifyOutsideTheScript();

        _propose();

        assertEq(
            registry.pendingClassCertificationOf(PORTFOLIO_TEMPLATE, SEL_EXECUTE).readyAt,
            0,
            "re-announced a class that is already certified"
        );
    }

    // -- 7. The bond --

    /// @notice With a submitter bond configured, `certifyClass` becomes
    ///         submitter-only and pulls WOOD from that submitter. The script
    ///         funds no such flow, so it must refuse rather than announce a
    ///         grant nobody can execute.
    function test_propose_isSkippedWhenASubmitterBondIsConfigured() public {
        ERC20Mock wood = new ERC20Mock("WOOD", "WOOD", 18);
        vm.startPrank(deployer);
        registry.setWood(address(wood));
        registry.setSubmitterBondWood(1e18);
        vm.stopPrank();

        _propose();

        assertEq(
            registry.pendingClassCertificationOf(PORTFOLIO_TEMPLATE, SEL_EXECUTE).readyAt,
            0,
            "announced a grant nobody can execute"
        );
    }
}
