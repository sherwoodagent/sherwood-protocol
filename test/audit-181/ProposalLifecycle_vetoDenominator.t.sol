// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title ProposalLifecycle_vetoDenominator
/// @notice Audit issue #181, FINDING #14 (HIGH) —
///         `ProposalLifecycle._computeState` priced the veto threshold off
///         `getPastTotalSupply(p.snapshotTimestamp)` directly. Escrowed
///         redeem-queue shares stay in `totalSupply()` until CLAIM burns them
///         (the queue burns at claim, not at the settle stamp) and
///         `SyndicateVault._update` auto-delegates the queue to ITSELF on
///         receipt, so those shares get checkpointed into
///         `getPastTotalSupply` even though the queue never votes (no
///         governance surface) and the escrowed shares carry zero remaining
///         economic exposure (settle price already stamped, assets already
///         reserved). Left in the denominator, a whale who queues and stamps
///         a large-enough redeem WITHOUT claiming can push the veto threshold
///         beyond the total weight the honest remaining LPs can ever cast —
///         veto becomes arithmetically impossible even at 100% honest
///         turnout, for exactly the LPs who now bear 100% of the live
///         economics.
///
///         Worked example from the audit (reproduced below): supply 100,
///         whale 85 (queued + stamped, unclaimed), honest LPs 15,
///         `vetoThresholdBps == 2000` (the protocol MIN). Raw-supply
///         threshold = 100 * 2000 / 10_000 = 20 > the honest LPs' entire 15 —
///         veto is impossible pre-fix even though the honest LPs are the
///         ENTIRE live economics (`_pricingSupply()` excludes the same
///         escrowed shares).
///
///         THE FIX: net the withdrawal queue's own checkpointed voting
///         weight — which equals its escrowed custody balance exactly,
///         because the queue auto-delegates to itself and never delegates
///         elsewhere or votes — out of `getPastTotalSupply` before applying
///         `vetoThresholdBps`.
///
///         Setup strategy: the escrow scenario is driven directly through
///         `SyndicateVault` + `VaultWithdrawalQueue` with the vault's
///         `governorOf` mocked to a bare address (mirrors
///         `test/audit-181/Vault_settleStampDenominator.t.sol`) — no real
///         proposal needs to execute or settle for shares to become
///         queued+stamped+unclaimed. A SEPARATE, real `SyndicateGovernor` is
///         then bound to the SAME vault to exercise the actual
///         `_computeState` veto arithmetic under test via `propose` / `vote`
///         / `stateOf`; that governor never touches the vault's
///         `governorOf`-mocked read surface (`redemptionsLocked` /
///         `_activePid`), so the two coexist without interference.
contract ProposalLifecycleVetoDenominatorTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    SyndicateGovernor governor;
    MockRegistryMinimal registry;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    ERC20Mock targetToken;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address whale = makeAddr("whale"); // queues + stamps a redeem covering 85% of supply, never claims
    address honestLp = makeAddr("honestLp"); // the entire live economics once the whale's exit is priced in
    address constant MOCK_GOVERNOR = address(0xF00D);

    uint256 constant WHALE_ASSETS = 85_000e6;
    uint256 constant HONEST_ASSETS = 15_000e6;

    // MIN_VETO_THRESHOLD_BPS on GovernorParameters (20%) — also the exact
    // value used in the audit's worked example.
    uint256 constant VETO_THRESHOLD_BPS = 2000;

    uint256 agentNftId;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        targetToken = new ERC20Mock("Target", "TGT", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        agentNftId = agentRegistry.mint(agent);

        // ── Vault + async withdrawal queue ──
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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        // Vault resolves its governor via the factory (this test contract).
        // Pointed at a bare mock address so the escrow setup below (driven
        // directly through the vault, mirroring
        // `Vault_settleStampDenominator.t.sol`) needs no real proposal
        // lifecycle. No open proposal at genesis.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        _setVaultProposal(0, 0, 0);

        // ── Real governor, bound to the SAME vault, for the veto check ──
        // `reviewPeriod() == 0` on MockRegistryMinimal collapses the
        // guardian-review window so a passing vote resolves straight to
        // Approved/Rejected at `voteEnd` — this test drives the veto edge
        // alone and needs no guardian setup.
        registry = new MockRegistryMinimal();
        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(registry),
                address(new ProtocolConfig(owner)),
                address(this),
                address(deployTierRegistry(address(this))), // factory
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: 1 days,
                    executionWindow: 1 days,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
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

        // LPs in: whale 85%, honest LP 15% — matches the audit's worked
        // example exactly.
        usdc.mint(whale, WHALE_ASSETS);
        usdc.mint(honestLp, HONEST_ASSETS);
        vm.startPrank(whale);
        usdc.approve(address(vault), WHALE_ASSETS);
        vault.deposit(WHALE_ASSETS, whale);
        vm.stopPrank();
        vm.startPrank(honestLp);
        usdc.approve(address(vault), HONEST_ASSETS);
        vault.deposit(HONEST_ASSETS, honestLp);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Drives the `IProposalStatus` selectors the vault reads through
    ///      the mocked governor (mirrors `Vault_settleStampDenominator.t.sol`).
    function _setVaultProposal(uint256 activePid, uint256 openCount, uint256 proposalCount_) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(activePid));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(openCount));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("proposalCount()"), abi.encode(proposalCount_));
    }

    function _emptyCoProposers() private pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    function _calls() private view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(targetToken), 0)), value: 0
        });
    }

    /// @dev Proposes on the REAL governor. Never executed in this test — only
    ///      the Pending -> {Rejected, Approved} edge at `voteEnd` is under
    ///      test, so a trivial (never-run) call batch is enough to satisfy
    ///      `propose`'s non-empty-calls requirement.
    function _propose() private returns (uint256 proposalId) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            address(0),
            "ipfs://veto-denominator",
            1 hours,
            env,
            _calls(),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _emptyCoProposers()
        );
    }

    /// @notice A whale who queues and stamps a redeem covering 85% of supply,
    ///         and never claims, must NOT be able to push the veto threshold
    ///         beyond the honest remaining LP's total voting weight.
    ///         Pre-fix: `vetoThreshold` is priced off the raw, escrow-
    ///         inflated `getPastTotalSupply`, so the honest LP's full 15% can
    ///         never reach a 20%-of-100 threshold and the proposal resolves
    ///         Approved. Post-fix: the escrowed, non-voting queue balance is
    ///         netted out first, so the honest LP is 100% of the LIVE supply
    ///         and trivially clears the threshold — Rejected.
    function test_escrowedQueueShares_excludedFromVetoDenominator() public {
        // ── Fake proposal "1": whale queues its entire position, it settles
        //    (stamping the queue's frozen price), and the whale never claims.
        _setVaultProposal(1, 1, 1); // active proposal 1 -> redemptionsLocked() == true

        uint256 whaleShares = vault.balanceOf(whale);
        assertGt(whaleShares, 0, "whale must hold shares to queue");
        vm.prank(whale);
        vault.requestRedeem(whaleShares, whale);

        _setVaultProposal(0, 0, 1); // settlement resets active/open count to 0
        vm.prank(MOCK_GOVERNOR);
        vault.onProposalSettled(1);

        // Escrowed, STAMPED, UNCLAIMED: shares sit at the queue, checkpointed
        // there (auto-delegate-to-self on receipt), zero remaining exposure.
        assertEq(vault.balanceOf(address(queue)), whaleShares, "whale shares must sit escrowed at the queue");

        vm.warp(vm.getBlockTimestamp() + 1);

        // ── Real proposal on the real governor: only the honest LP votes,
        //    entirely Against.
        uint256 pid = _propose();
        ISyndicateGovernor.StrategyProposal memory p = governor.getProposal(pid);

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(honestLp);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);

        // Sanity-check the scenario actually reproduces the audit's premise
        // before asserting the fix: the escrowed whale shares are still
        // counted in the raw checkpoint, the queue holds exactly that many
        // checkpointed (non-voting) votes, and the honest LP's entire weight
        // sits BELOW the unfixed (raw-supply) threshold.
        uint256 rawSupply = vault.getPastTotalSupply(p.snapshotTimestamp);
        uint256 queueVotes = vault.getPastVotes(address(queue), p.snapshotTimestamp);
        uint256 honestWeight = vault.getPastVotes(honestLp, p.snapshotTimestamp);
        assertEq(queueVotes, whaleShares, "queue's checkpointed votes must equal the escrowed whale shares");
        uint256 buggyThreshold = (rawSupply * VETO_THRESHOLD_BPS) / 10_000;
        assertLt(
            honestWeight,
            buggyThreshold,
            "premise check: honest LP alone must be unable to clear the UNFIXED (raw-supply) threshold"
        );

        vm.warp(p.voteEnd + 1);

        // THE FIX under test: with the escrowed, non-voting queue balance
        // netted out of the denominator, the honest LP's Against vote (100%
        // of live supply) clears the threshold and the proposal is Rejected.
        // Against the unfixed code this assertion fails — `stateOf` reports
        // Approved instead, because 15,000 < 20,000 (20% of the raw,
        // escrow-inflated 100,000 supply).
        assertEq(
            uint256(governor.stateOf(pid)),
            uint256(ISyndicateGovernor.ProposalState.Rejected),
            "honest LP must be able to veto once escrowed, non-voting whale shares are excluded from the threshold"
        );
    }
}
