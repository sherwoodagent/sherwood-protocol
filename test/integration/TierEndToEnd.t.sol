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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @notice A minimal DeFi adapter that pulls capital out of the calling vault.
///         `deploy` moves `amount` of `token` from the caller (the vault, in the
///         batch-execution context) into the adapter — a stand-in for capital
///         being deployed into a strategy/pool, which is exactly what the vault's
///         net-outflow meter (Task 4) and the tier coverage math (Tasks 5/6) are
///         built to bound. It carries real code so `TierRegistry.certify` can
///         snapshot its EXTCODEHASH.
contract MockDeployAdapter {
    function deploy(IERC20 token, uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }
}

/// @notice Task 7 — end-to-end tier lifecycle (spec 2026-07-22 §3.1/§3.2).
///         Non-fork: mock USDC + a simple fund-moving adapter, so it runs in CI
///         without an RPC. Exercises the full propose→execute path and proves
///         BOTH the coverage math (tier→requiredCoverage) and the two on-chain
///         enforcement points wired in Tasks 4/6:
///           - `MaxNetOutflowExceeded` (custody-level net-outflow ceiling), and
///           - `TierRegressed` (execute-time re-resolve fail-safe).
///
///         Harness mirrors `test/governor/TierResolution.t.sol` (the test
///         contract acts as the factory, so it may call the onlyFactory
///         `setTierRegistry`; `_advancePastVoting` copies that suite's helper).
///
/// @dev Adapter-tier honesty: `UniswapSwapAdapter.swap` DOES enforce a min-out,
///      but that floor is CALLER-SUPPLIED calldata (`amountOutMin`), not an
///      on-chain oracle bound the adapter computes itself — the contract's own
///      MEV note says the oracle anchoring lives caller-side in
///      `PortfolioStrategy.rebalanceDelta`. Per the plan, a proposal-calldata
///      bound guardians must price is not a self-bounded tier, so
///      UniswapSwapAdapter stays at the tier-2 default; this e2e uses a mock
///      adapter for the certified (reduced-coverage) flow so the codehash can be
///      controlled for the regression check.
contract TierEndToEndTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockDeployAdapter public adapter;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    TierRegistry public tierRegistry;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant MAX_CAPITAL = 1_000e6;
    uint256 constant DEPOSIT = 60_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        adapter = new MockDeployAdapter();
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
                address(this), // factory (test contract) — may call setTierRegistry
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

        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, lp1);
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Helpers (mirroring test/governor/TierResolution.t.sol) ──

    /// @dev Wires the TierRegistry into the governor (test contract is factory).
    function _wireTierRegistry() internal {
        governor.setTierRegistry(address(tierRegistry));
    }

    function _settleCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(adapter), 0)), value: 0
        });
    }

    function _propose(BatchExecutorLib.Call[] memory executeCalls) internal returns (uint256 proposalId) {
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://tier-e2e",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: MAX_CAPITAL, maxDrawdownBps: 10_000}),
            executeCalls,
            _settleCalls(),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev Batch that deploys `amount` USDC into the adapter: approve then pull.
    ///      Net asset outflow from the vault is exactly `amount`.
    function _deployCalls(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(adapter), amount)), value: 0
        });
        calls[1] = BatchExecutorLib.Call({
            target: address(adapter), data: abi.encodeCall(adapter.deploy, (IERC20(address(usdc)), amount)), value: 0
        });
    }

    /// @dev Single certified call — one target/selector so the proposal resolves
    ///      to the adapter's certified tier (not diluted to tier 2 by a companion
    ///      uncertified `approve`).
    function _singleDeployCall(uint256 amount) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(adapter), data: abi.encodeCall(adapter.deploy, (IERC20(address(usdc)), amount)), value: 0
        });
    }

    /// @dev With `reviewPeriod == 0` (MockRegistryMinimal), the vote window
    ///      closing maps straight to Approved — the executable state.
    function _advancePastVoting() internal {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ── Flow 1: uncertified adapter → tier 2, full-notional coverage ──

    /// @notice An uncertified adapter resolves to tier 2 (full-notional
    ///         coverage). A batch within maxCapital executes cleanly; a batch
    ///         exceeding maxCapital trips the custody-level net-outflow ceiling.
    function test_e2e_tier2UnknownAdapterFullNotionalCoverage() public {
        _wireTierRegistry(); // registry is wired but nothing is certified

        // --- Over-cap proposal: net outflow > maxCapital → MaxNetOutflowExceeded.
        // Run FIRST: the revert rolls the whole tx back (proposal stays Approved,
        // slot still held, no settlement), so the proposer can cancel to free the
        // single-open-proposal slot without a prior settlement muddying state.
        uint256 amountOver = MAX_CAPITAL * 2; // 2_000e6 > 1_000e6 cap, < 60_000e6 balance
        uint256 pidOver = _propose(_deployCalls(amountOver));
        assertEq(governor.getProposalTier(pidOver), 2, "uncertified => tier 2");
        assertEq(governor.getRequiredCoverage(pidOver), MAX_CAPITAL, "tier 2 => full-notional coverage");

        _advancePastVoting();
        // MaxNetOutflowExceeded carries (netOutflow, cap) — full encode so the
        // args match too (bare-selector expectRevert only matches no-arg errors).
        // The whole `amountOver` is moved out, so netOutflow == amountOver.
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, amountOver, MAX_CAPITAL));
        governor.executeProposal(pidOver);

        // Free the (still-Approved) slot so a fresh proposal can be filed.
        vm.prank(agent);
        governor.cancelProposal(pidOver);

        // --- Within-cap proposal: executes and moves exactly `amountOk` out.
        uint256 amountOk = MAX_CAPITAL / 2; // 500e6 <= cap
        uint256 pidOk = _propose(_deployCalls(amountOk));
        assertEq(governor.getProposalTier(pidOk), 2);
        assertEq(governor.getRequiredCoverage(pidOk), MAX_CAPITAL);

        // Same warp clears both the voting window AND the cancel-stamped cooldown.
        _advancePastVoting();

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        governor.executeProposal(pidOk);

        assertEq(
            uint256(governor.getProposalState(pidOk)),
            uint256(ISyndicateGovernor.ProposalState.Executed),
            "within-cap batch should execute"
        );
        assertEq(usdc.balanceOf(address(vault)), vaultBefore - amountOk, "net outflow = amountOk");
        assertEq(usdc.balanceOf(address(adapter)), amountOk, "capital landed in adapter");
    }

    // ── Flow 2: certified adapter → reduced coverage + regression fail-safe ──

    /// @notice The owner certifies (adapter, deploy) at tier 0 with a 100 bps
    ///         extractable bound → the proposal prices at tier 0 with coverage of
    ///         1% of maxCapital. If the adapter's codehash then changes (proxy
    ///         upgrade / etch) the execute-time re-resolve sees tier 2 > the
    ///         propose-time tier 0 and reverts TierRegressed rather than running
    ///         at the stale, under-covered price.
    function test_e2e_certifiedAdapterReducedCoverage() public {
        _wireTierRegistry();
        tierRegistry.certify(address(adapter), adapter.deploy.selector, 0, 100); // tier 0, 1%

        uint256 pid = _propose(_singleDeployCall(MAX_CAPITAL));
        assertEq(governor.getProposalTier(pid), 0, "certified tier 0 snapshotted at propose");
        assertEq(
            governor.getRequiredCoverage(pid),
            (MAX_CAPITAL * 100) / 10_000, // 1% of 1_000e6 = 10e6
            "coverage = 100 bps of maxCapital"
        );

        _advancePastVoting();

        // Adapter codehash changes → the lazy fail-safe in TierRegistry.tierOf
        // now reports tier 2 for the certified call.
        vm.etch(address(adapter), address(executorLib).code);
        (uint8 liveTier,) = tierRegistry.tierOf(address(adapter), adapter.deploy.selector);
        assertEq(liveTier, 2, "adapter demoted to tier 2 since propose");

        vm.expectRevert(ISyndicateGovernor.TierRegressed.selector);
        governor.executeProposal(pid);
    }
}
