// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @notice Issue #43 — per-call capital declarations. Tests this change owes
///         beyond the ABI-migration sweep (tasks.md §8): the issue's own
///         headline coverage scenario, the per-call tier-2 ceiling, the
///         propose-time cap-array validation matrix, regression guards
///         re-evaluated against per-call caps, and the unwired-registry
///         default. Fixture mirrors `test/governor/TierResolution.t.sol`
///         (test contract as factory, `MockRegistryMinimal` — no guardian
///         review complexity needed for any of these).
contract PerCallCapitalDeclarationsTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public mockAdapter;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    TierRegistry public tierRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        mockAdapter = new ERC20Mock("Adapter", "ADP", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        tierRegistry = new TierRegistry(address(this));

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 50
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vm.stopPrank();

        usdc.mint(lp1, 100_000_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 20_000_000e6);
        vault.deposit(20_000_000e6, lp1);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _wireTierRegistry() internal {
        governor.setTierRegistry(address(tierRegistry));
        tierRegistry.setAdapterAllowed(address(mockAdapter), true);
        tierRegistry.setAdapterAllowed(address(usdc), true);
    }

    /// @dev Shared fixture helper (mirrors `TierRegistryTest._certifyNow`):
    ///      reaches the same end state as the old instant `certify` via the
    ///      new two-step flow from #45's certification timelock — propose
    ///      (test contract is `tierRegistry`'s owner, no prank needed), warp
    ///      past the pinned `readyAt` (`vm.getBlockTimestamp()`, never a
    ///      cached `block.timestamp` local — this repo's optimizer CSEs it
    ///      across `vm.warp`), execute. Every call site here pins no bond
    ///      (`submitter == address(0)`), so the finalize step needs no prank.
    function _certifyNow(address target_, bytes4 selector_, uint8 tier_, uint16 bound_, address submitter_) internal {
        tierRegistry.proposeCertification(target_, selector_, tier_, bound_, submitter_, target_.codehash);
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(target_, selector_);
    }

    function _benignSettle() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(mockAdapter), 0)), value: 0
        });
    }

    function _advancePastVoting() internal {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ── 8.1(a): the issue's own headline scenario ──────────────────────────

    /// @notice Asserts the tier AND coverage for the issue's own worked
    ///         example: maxCapital = 10,000,000; a tier-0 call (100 bps
    ///         bound) capped at 8,000,000, a tier-1 call (500 bps) capped at
    ///         1,900,000, and a tier-2 (uncertified) call capped at 100,000.
    ///         requiredCoverage = 80,000 + 95,000 + 100,000 = 275,000 — not
    ///         the 10,000,000+ the pre-#43 proposal-wide formula would have
    ///         priced. Tier is the MAX (2), even though coverage stays the
    ///         per-call sum.
    function test_issueHeadlineScenario_tierAndCoverage() public {
        _wireTierRegistry();
        _certifyNow(address(mockAdapter), mockAdapter.approve.selector, 0, 100, address(0));
        _certifyNow(address(mockAdapter), mockAdapter.transfer.selector, 1, 500, address(0));
        // Third call: uncertified (tier 2, 10_000 bps) -- mockAdapter.mint has
        // no certification entry.

        uint256 maxCapital = 10_000_000e6;
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](3);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.approve, (address(usdc), 1)), value: 0
        });
        execCalls[1] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.transfer, (address(usdc), 1)), value: 0
        });
        execCalls[2] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](3);
        execCaps[0] = 8_000_000e6;
        execCaps[1] = 1_900_000e6;
        execCaps[2] = 100_000e6;

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://headline",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        assertEq(governor.getProposalTier(pid), 2, "one uncertified call -> tier 2 (the fail-closed max)");
        // exec: 8_000_000e6*100/10_000 + 1_900_000e6*500/10_000 + 100_000e6*10_000/10_000
        //     = 80_000e6 + 95_000e6 + 100_000e6 = 275_000e6
        // settle: single call, cap defaults to 0 (new uint256[](1) is zero-initialized).
        assertEq(governor.getRequiredCoverage(pid), 275_000e6, "issue's own worked example: 275,000, not 10M+");
    }

    // ── 8.1(d) / design.md D2: the per-call tier-2 ceiling ──────────────────

    function test_tier2Ceiling_aboveCeilingRejectedAtPropose() public {
        _wireTierRegistry();
        vm.prank(owner);
        governor.setTier2CallCapBps(200); // 2%

        uint256 maxCapital = vault.totalAssets() / 10; // comfortably under the 100% cap
        uint256 ceiling = (vault.totalAssets() * 200) / 10_000;

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        // uncertified -> tier 2
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = ceiling + 1; // one wei above the ceiling

        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.Tier2CallCapExceedsCeiling.selector, 0));
        governor.propose(
            address(vault),
            address(0),
            "ipfs://tier2-ceiling",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice The SAME cap value that reverts on an uncertified (tier-2)
    ///         call is accepted on a certified tier-0 call — the ceiling
    ///         binds tier-2 pricing specifically, not caps in general.
    function test_tier2Ceiling_sameCapAcceptedOnCertifiedTier0Call() public {
        _wireTierRegistry();
        _certifyNow(address(mockAdapter), mockAdapter.mint.selector, 0, 50, address(0));
        vm.prank(owner);
        governor.setTier2CallCapBps(200);

        uint256 maxCapital = vault.totalAssets() / 10;
        uint256 ceiling = (vault.totalAssets() * 200) / 10_000;

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = ceiling + 1; // same "above ceiling" value

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://tier0-ok",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getProposalTier(pid), 0, "certified tier 0 -- the ceiling never applied");
    }

    // ── 8.8: tier2CallCapBps parameter ──────────────────────────────────────

    function test_tier2CallCapBps_unsetReadsAsInertDefault() public view {
        assertEq(governor.tier2CallCapBps(), 10_000, "unset reads as 10_000 (no ceiling)");
    }

    function test_tier2CallCapBps_setterBoundsAndEvent() public {
        // Hoisted: a call in argument position (here, reading the param-key
        // constant) would consume the single-use `vm.prank` below before
        // `setTier2CallCapBps` ever runs (error-guardrails' documented gotcha).
        bytes32 paramKey = governor.PARAM_TIER2_CALL_CAP_BPS();
        vm.prank(owner);
        vm.expectEmit(true, false, false, true, address(governor));
        emit ISyndicateGovernor.ParameterChangeFinalized(paramKey, 10_000, 200);
        governor.setTier2CallCapBps(200);
        assertEq(governor.tier2CallCapBps(), 200);

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidTier2CallCapBps.selector);
        governor.setTier2CallCapBps(0);

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.InvalidTier2CallCapBps.selector);
        governor.setTier2CallCapBps(10_001);
    }

    function test_tier2CallCapBps_onlyVaultOwner() public {
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.NotVaultOwner.selector);
        governor.setTier2CallCapBps(200);
    }

    /// @notice Frozen mid-proposal, like every other governance parameter.
    function test_tier2CallCapBps_frozenDuringOpenProposal() public {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        vm.prank(agent);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://freeze",
            7 days,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            GovEnvelope.defaultCaps(GovEnvelope.permissive(address(vault)).maxCapital, 1),
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        governor.setTier2CallCapBps(200);
    }

    // ── 8.2: validation matrix ───────────────────────────────────────────────

    function test_validation_execCapsLengthMismatch() public {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        execCalls[1] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        uint256[] memory execCaps = new uint256[](1); // wrong length
        // Hoisted: `GovEnvelope.permissive` makes an external call
        // (`totalAssets()`); evaluating it INSIDE the propose() argument list
        // would make that call, not propose() itself, the "next call"
        // `vm.expectRevert` intercepts (error-guardrails' argument-position
        // gotcha, this time against expectRevert rather than prank).
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.CallCapsLengthMismatch.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://mismatch-exec",
            7 days,
            env,
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function test_validation_settleCapsLengthMismatch() public {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](2);
        settleCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        settleCalls[1] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        uint256[] memory settleCaps = new uint256[](1); // wrong length
        // Hoisted -- see the identical note in test_validation_execCapsLengthMismatch.
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        uint256[] memory execCaps = GovEnvelope.defaultCaps(env.maxCapital, 1);

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.CallCapsLengthMismatch.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://mismatch-settle",
            7 days,
            env,
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function test_validation_execCapsSumExceedsMaxCapital() public {
        uint256 maxCapital = 1_000e6;
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        execCalls[1] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        uint256[] memory execCaps = new uint256[](2);
        execCaps[0] = 600e6;
        execCaps[1] = 500e6; // sum 1_100e6 > maxCapital

        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.CallCapsExceedMaxCapital.selector);
        governor.propose(
            address(vault),
            address(0),
            "ipfs://over-cap",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @notice The execute and settlement batches are bounded INDEPENDENTLY —
    ///         each cap array can legally sum to exactly `maxCapital` even
    ///         though their COMBINED sum exceeds it.
    function test_validation_execAndSettleCapsIndependentlyBounded() public {
        uint256 maxCapital = 1_000e6;
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = maxCapital; // sums to exactly maxCapital

        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](1);
        settleCalls[0] = BatchExecutorLib.Call({target: address(mockAdapter), data: "", value: 0});
        uint256[] memory settleCaps = new uint256[](1);
        settleCaps[0] = maxCapital; // ALSO sums to exactly maxCapital -- combined 2x maxCapital

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://independent-caps",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertGt(pid, 0, "accepted -- each batch bounded independently");
    }

    /// @notice A zero-capped call that actually moves 1 wei of the vault
    ///         asset reverts at EXECUTE time (per-call meter), even though it
    ///         proposed fine (zero caps are always propose-time legal).
    function test_validation_zeroCapCallMoving1WeiReverts() public {
        // A call that actually moves the vault's asset(): transfer 1 wei out.
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (address(0xBEEF), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1); // zero cap

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://zero-cap-move",
            7 days,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        _advancePastVoting();
        vm.expectRevert(abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 0, 1, 0));
        governor.executeProposal(pid);
    }

    /// @notice design.md D2 / spec "All-zero caps price zero coverage": with a
    ///         wired registry, an all-zero-cap batch prices to ZERO coverage
    ///         regardless of tier, and the per-call meter still blocks any
    ///         actual outflow at execute time.
    function test_allZeroCaps_pricesZeroCoverage_meterStillBlocksOutflow() public {
        _wireTierRegistry();
        _certifyNow(address(mockAdapter), mockAdapter.mint.selector, 0, 50, address(0));
        // The vault's selector guard (Part 2, registry-dependent) requires
        // transfer recipients to be allowlisted -- orthogonal to this test's
        // subject (the per-call cap meter), so allowlist it explicitly rather
        // than let an unrelated guard fire first.
        tierRegistry.setAdapterAllowed(address(0xBEEF), true);

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (address(0xBEEF), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1); // zero

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://all-zero",
            7 days,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        assertEq(governor.getRequiredCoverage(pid), 0, "all-zero caps price zero coverage regardless of tier");

        _advancePastVoting();
        vm.expectRevert(abi.encodeWithSelector(BatchExecutorLib.CallCapExceeded.selector, 0, 1, 0));
        governor.executeProposal(pid);
    }

    // ── 8.3: regression guards re-evaluated against per-call caps ──────────

    function test_regression_coverageRegressed_whenACappedCallsBoundRises() public {
        _wireTierRegistry();
        _certifyNow(address(mockAdapter), mockAdapter.mint.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = 1_000e6;

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://coverage-regress",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: 10_000e6, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getRequiredCoverage(pid), 5e6, "1_000e6 * 50/10_000");

        // Same tier, but the certified bound rises 10x -- coverage regresses
        // even though the tier does not. The re-certification must clear
        // #45's certification timelock before `executeProposal` re-resolves
        // live coverage below, but a second full `certifyDelay` (default 3
        // days) stacked on top of `_advancePastVoting`'s warp would blow past
        // this proposal's EXECUTION_WINDOW (1 day) and revert
        // `ProposalNotApproved` instead of the `CoverageRegressed` this test
        // is actually about. Fix: shrink `certifyDelay` to its floor
        // (MIN_CERTIFY_DELAY, exactly VOTING_PERIOD here) and propose the
        // re-cert NOW, so its `readyAt` elapses from the SAME
        // `_advancePastVoting` warp that clears the vote, instead of adding
        // a second one.
        tierRegistry.setCertifyDelay(tierRegistry.MIN_CERTIFY_DELAY());
        tierRegistry.proposeCertification(
            address(mockAdapter), mockAdapter.mint.selector, 0, 500, address(0), address(mockAdapter).codehash
        );

        _advancePastVoting();
        tierRegistry.certify(address(mockAdapter), mockAdapter.mint.selector);

        vm.expectRevert(ISyndicateGovernor.CoverageRegressed.selector);
        governor.executeProposal(pid);
    }

    function test_regression_tierRegressed_whenAdapterDemoted() public {
        _wireTierRegistry();
        _certifyNow(address(mockAdapter), mockAdapter.mint.selector, 0, 50, address(0));

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = 1_000e6;

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://tier-regress",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: 10_000e6, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getProposalTier(pid), 0);

        _advancePastVoting();
        // Codehash change -> the registry's lazy fail-safe demotes to tier 2.
        vm.etch(address(mockAdapter), address(executorLib).code);

        vm.expectRevert(ISyndicateGovernor.TierRegressed.selector);
        governor.executeProposal(pid);
    }

    /// @notice design.md D2's deliberate residual: a zero-cap call's adapter
    ///         demoting inside an ALREADY-tier-2 batch changes nothing —
    ///         coverage is unaffected (0 * anything = 0) and the tier was
    ///         already at the max, so execution proceeds normally.
    function test_regression_zeroCapCallDemotion_insideAlreadyTier2Batch_executesFine() public {
        _wireTierRegistry();
        // The vault's selector guard (Part 2) requires an `approve` spender to
        // be allowlisted -- orthogonal to this test's subject (tier/coverage
        // regression under caps), so allowlist the spender explicitly.
        tierRegistry.setAdapterAllowed(address(this), true);
        // Two calls: one uncertified (forces tier 2 already), one certified
        // tier-0 but capped at ZERO.
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        // `approve` (never requires a balance precondition, unlike `transfer`)
        // stays uncertified -- this is the call that forces tier 2.
        execCalls[0] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.approve, (address(this), 1)), value: 0
        });
        execCalls[1] = BatchExecutorLib.Call({
            target: address(mockAdapter), data: abi.encodeCall(mockAdapter.mint, (address(this), 1)), value: 0
        });
        _certifyNow(address(mockAdapter), mockAdapter.mint.selector, 0, 50, address(0));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[0] = 0; // uncertified call -- moves nothing declared
        execCaps[1] = 0; // certified tier-0 call, ALSO capped at zero

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://zero-cap-demotion",
            7 days,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getProposalTier(pid), 2, "uncertified call already pins tier 2");
        assertEq(governor.getRequiredCoverage(pid), 0, "both caps zero");

        _advancePastVoting();
        // Demote the certified call too -- tier stays 2 (already the max),
        // coverage stays 0 (cap is 0 either way). Neither regression guard
        // fires; the batch's own calls move nothing, so it executes cleanly.
        // Etched with a harmless-fallback contract (not executorLib's code,
        // which has no fallback at all) so the batch's approve/mint calls
        // still succeed post-demotion -- this test's subject is the
        // tier/coverage arithmetic, not whether the demoted contract remains
        // independently callable.
        vm.etch(address(mockAdapter), address(new HarmlessFallback()).code);
        // issue #166: the etch above changes `mockAdapter`'s codehash, which
        // the pre-existing codehash-drift self-heal (issue #137) correctly
        // reads as revoking `isAdapterAllowed` -- that check is now ALSO the
        // batch callee gate (Part 2a), not just the fund-destination check
        // Part 2b already was, so an un-re-attested etch would refuse the
        // whole batch with `DisallowedBatchCallee` before execution even
        // reaches the tier/coverage arithmetic this test is about (see the
        // comment above: "not whether the demoted contract remains
        // independently callable"). Re-snapshot the new (harmless) code,
        // mirroring the owner re-attestation ceremony `setAdapterAllowed`'s
        // natspec documents for a verified legitimate bytecode change.
        tierRegistry.setAdapterAllowed(address(mockAdapter), true);
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    // ── 8.4: unwired-registry default ───────────────────────────────────────

    function test_unwiredRegistry_defaultIgnoresCapsForPricing_butStillMeters() public {
        // Deliberately NOT wiring a TierRegistry.
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (address(0xBEEF), 1)), value: 0
        });
        uint256 maxCapital = 1_000e6;
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = 500e6; // an arbitrary legal cap; irrelevant to pricing when unwired

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://unwired",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        assertEq(governor.getProposalTier(pid), 2, "unwired -> tier 2 regardless of caps");
        assertEq(governor.getRequiredCoverage(pid), maxCapital, "unwired -> requiredCoverage == maxCapital flat");

        // Caps are STILL metered at execution even though pricing ignored them:
        // the call moves 1 wei, well under its declared 500e6 cap, so it
        // executes fine.
        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(uint256(governor.getProposalState(pid)), uint256(ISyndicateGovernor.ProposalState.Executed));
    }
}

/// @dev A "demoted" adapter stand-in: accepts and no-ops ANY call, so
///      `vm.etch`-ing a certified adapter's address with this contract's code
///      changes the live codehash (simulating a real proxy-upgrade demotion)
///      WITHOUT breaking calls already batched against that address —
///      unlike etching with a real contract's code (e.g. `BatchExecutorLib`,
///      which has no fallback), which would make every call revert with "no
///      matching function" instead of exercising the tier/coverage
///      regression logic this suite actually tests.
contract HarmlessFallback {
    fallback() external payable {}
}
