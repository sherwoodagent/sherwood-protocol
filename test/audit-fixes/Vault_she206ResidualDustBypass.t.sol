// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Vault_she206ResidualDustBypass
/// @notice SHE-206 residual (SHE-257). One share-wei held back from an async
///         exit keeps `_pricingSupply()` at 1, so the `== 0` reset guards of
///         `Vault_she206HwmPricingSupply.t.sol` never fire and the stale mark
///         reads a zero-P&L re-seeding deposit as almost entirely "profit".
///
/// @dev    The vault view `aboveHighWaterMark()` still says so — the mark is
///         not repaired. What is closed is the CHARGE: `_chargePerformanceFee`
///         clamps its base to the proposal's realized P&L, so every settlement
///         below charges the constants, which are now 0.
///
///         Real governor, real queue: the clamp lives in the governor, so a
///         mocked one cannot witness it.
contract VaultShe206ResidualDustBypassTest is Test {
    SyndicateGovernor internal governor;
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ProtocolConfig internal protocolConfig;
    MockRegistryMinimal internal guardianRegistry;
    MockAgentRegistry internal agentRegistry;
    ERC20Mock internal usdc;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal donor = makeAddr("donor");
    address internal sink = makeAddr("sink");
    address internal constant DEAD = address(0xdEaD);

    uint256 internal constant VOTING_PERIOD = 1 days;
    uint256 internal constant COOLDOWN_PERIOD = 1 days;
    uint256 internal constant STRATEGY_DURATION = 7 days;
    uint256 internal constant SELF_SETTLE_FLOOR = 1 hours;
    uint256 internal constant PERF_FEE_BPS = 1500;

    uint256 internal constant EPOCH1 = 1_000e6;
    /// @dev The re-seeding deposit that used to get charged. 10,000 USDC.
    uint256 internal constant EPOCH2 = 10_000e6;
    /// @dev One whole USDC of residue behind the near-empty pricing supply.
    uint256 internal constant RESIDUE = 1e6;

    /// @dev Pre-SHE-257 these read 9_999_990_001 and 4_999_994_999: the base
    ///      the settlement charged on a zero-P&L 10,000 USDC deposit, with and
    ///      without a donation. The clamp drives both to 0.
    uint256 internal constant RESIDUAL_FEE_BASE_WITH_DONATION = 0;
    uint256 internal constant RESIDUAL_FEE_BASE_NO_DONATION = 0;

    function setUp() public {
        protocolConfig = new ProtocolConfig(owner);
        vm.prank(owner);
        protocolConfig.setProtocolFeeRecipient(owner);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        uint256 agentNftId = agentRegistry.mint(agent);

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

        // Test contract is the vault's factory: binds the queue, answers `governorOf`.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.startPrank(owner);
        vault.registerAgent(agentNftId, agent);
        vault.setAgentFeeBps(PERF_FEE_BPS);
        vm.stopPrank();

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(protocolConfig),
                address(this),
                address(deployTierRegistry(address(this))),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: 1 days,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        usdc.mint(alice, 100_000e6);
        usdc.mint(bob, 100_000e6);
        usdc.mint(donor, 100_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── lifecycle helpers ──

    function _benignCalls() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(vault), 0)), value: 0
        });
    }

    /// @dev Propose, have `voter` approve, and execute. Hoists every staticcall
    ///      ahead of the one-shot pranks.
    function _proposeAndExecute(address voter) internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        BatchExecutorLib.Call[] memory calls = _benignCalls();
        uint256[] memory caps = GovEnvelope.defaultCaps(env.maxCapital, calls.length);
        vm.warp(vm.getBlockTimestamp() + 1); // vote weight snapshots before propose
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://p",
            STRATEGY_DURATION,
            env,
            calls,
            caps,
            calls,
            caps,
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(voter);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        vm.warp(vm.getBlockTimestamp() + SELF_SETTLE_FLOOR + 1);
    }

    /// @dev Settle `pid` and return the performance-fee base the governor
    ///      charged (0 when no `PerformanceFeeCharged` was emitted).
    function _settleAndChargedBase(uint256 pid) internal returns (uint256 base) {
        vm.recordLogs();
        vm.prank(agent);
        governor.settleProposal(pid);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == ISyndicateGovernor.PerformanceFeeCharged.selector) {
                (, base) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _pricingSupply() internal view returns (uint256) {
        uint256 supply = vault.totalSupply();
        uint256 stamped = queue.stampedUnclaimedShares();
        return supply > stamped ? supply - stamped : 0;
    }

    /// @dev Epoch 1: alice deposits, a proposal runs flat, and she exits through
    ///      the queue holding back exactly one share-wei (or burns it first).
    /// @return mark1 the epoch-1 mark, which survives the settlement.
    function _asyncExitKeepingOneWei(bool burnIt) internal returns (uint256 mark1) {
        vm.prank(alice);
        uint256 shares = vault.deposit(EPOCH1, alice);
        mark1 = vault.highWaterPricePerShare();
        assertGt(mark1, 0, "sanity: mark seeded on the first deposit");

        if (burnIt) {
            vm.prank(alice);
            vault.transfer(DEAD, 1);
        }
        uint256 pid = _proposeAndExecute(alice);
        vm.prank(alice);
        vault.requestRedeem(shares - 1, alice);
        assertEq(_settleAndChargedBase(pid), 0, "sanity: a flat epoch charges nothing");

        assertEq(_pricingSupply(), 1, "one share-wei of live pricing supply is what defeats the `== 0` guards");
        assertEq(vault.highWaterPricePerShare(), mark1, "so no reset fires and the stale epoch-1 mark stands");
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);
    }

    /// @dev Bob re-seeds the fund with zero P&L anywhere in the sequence.
    function _bobReseeds() internal {
        vm.prank(bob);
        vault.deposit(EPOCH2, bob);
    }

    // ── the three residual scenarios, charged base now 0 ──

    /// @notice One share-wei withheld plus one USDC of residue: the view still
    ///         reads ~9,999.99 USDC above the mark, the settlement charges 0.
    function test_perfBaseNeverExceedsRealizedPnl_oneWeiWithDonation() public {
        uint256 mark1 = _asyncExitKeepingOneWei(false);
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);
        _bobReseeds();
        assertGt(vault.aboveHighWaterMark(), EPOCH2 * 99 / 100, "the stale mark still reads bob's principal as profit");
        assertEq(vault.highWaterPricePerShare(), mark1, "the stale mark is what the deposit is measured against");

        uint256 pid = _proposeAndExecute(bob);
        uint256 before = usdc.balanceOf(address(vault));
        assertEq(_settleAndChargedBase(pid), RESIDUAL_FEE_BASE_WITH_DONATION, "zero P&L charges no base");
        assertEq(usdc.balanceOf(address(vault)), before, "not a wei of bob's principal left as fee");
    }

    /// @notice The same bypass with no donation: the stamp's own rounding wei
    ///         is enough for the view (~4,999.99 USDC), and still charges 0.
    function test_perfBaseNeverExceedsRealizedPnl_oneWeiNoDonation() public {
        _asyncExitKeepingOneWei(false);
        assertEq(vault.totalAssets(), 1, "the stamp's own rounding dust, nothing added");
        _bobReseeds();
        assertGt(vault.aboveHighWaterMark(), EPOCH2 * 49 / 100, "the dust alone inflates the view");

        uint256 pid = _proposeAndExecute(bob);
        uint256 before = usdc.balanceOf(address(vault));
        assertEq(_settleAndChargedBase(pid), RESIDUAL_FEE_BASE_NO_DONATION, "zero P&L charges no base");
        assertEq(usdc.balanceOf(address(vault)), before, "not a wei of bob's principal left as fee");
    }

    /// @notice The share-wei burned to `0xdEaD`: the reset is disabled for the
    ///         vault's whole life, and every zero-P&L epoch still charges 0.
    function test_perfBaseNeverExceedsRealizedPnl_oneWeiBurnedToDead() public {
        uint256 mark1 = _asyncExitKeepingOneWei(true);
        assertEq(vault.balanceOf(alice), 0, "alice is fully out");
        assertEq(vault.balanceOf(DEAD), 1, "the wei that keeps the pricing supply alive is unreachable");
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);
        _bobReseeds();
        assertGt(vault.aboveHighWaterMark(), EPOCH2 * 99 / 100, "permanently inflated view");
        assertEq(vault.highWaterPricePerShare(), mark1, "the epoch-1 mark outlives everyone who held under it");

        uint256 pid = _proposeAndExecute(bob);
        uint256 before = usdc.balanceOf(address(vault));
        assertEq(_settleAndChargedBase(pid), RESIDUAL_FEE_BASE_WITH_DONATION, "zero P&L charges no base");
        assertEq(usdc.balanceOf(address(vault)), before, "not a wei of bob's principal left as fee");
    }

    /// @notice A LOSS under the inflated view charges nothing either: the clamp
    ///         floors the base at zero rather than casting `pnl` to uint.
    function test_perfBaseNeverExceedsRealizedPnl_lossUnderAStaleMarkChargesNothing() public {
        _asyncExitKeepingOneWei(false);
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);
        _bobReseeds();

        uint256 pid = _proposeAndExecute(bob);
        vm.prank(address(vault));
        usdc.transfer(sink, 1e6);
        assertGt(vault.aboveHighWaterMark(), 0, "sanity: the view is still above the mark after the loss");
        uint256 before = usdc.balanceOf(address(vault));
        assertEq(_settleAndChargedBase(pid), 0, "a loss charges no base");
        assertEq(usdc.balanceOf(address(vault)), before, "nothing left the vault at settlement");
    }

    // ── the invariant ──

    /// @notice The charged base is exactly `min(aboveHighWaterMark(), pnl)`:
    ///         with the view inflated far past a real gain, the base is the gain.
    function test_performanceFeeBaseNeverExceedsTheProposalsRealizedPnl() public {
        _asyncExitKeepingOneWei(false);
        vm.prank(donor);
        usdc.transfer(address(vault), RESIDUE);
        _bobReseeds();

        uint256 pid = _proposeAndExecute(bob);
        uint256 gain = 500e6;
        usdc.mint(address(vault), gain);
        uint256 view_ = vault.aboveHighWaterMark();
        assertGt(view_, gain, "sanity: the view claims far more than the proposal earned");

        uint256 before = usdc.balanceOf(address(vault));
        uint256 base = _settleAndChargedBase(pid);
        assertEq(base, gain, "the base is the proposal's realized P&L, not the view");
        assertEq(before - usdc.balanceOf(address(vault)), gain * PERF_FEE_BPS / 10_000, "the fee is 15% of the gain");
    }

    /// @notice The same equality on a fuzzed gain: `base == min(view, pnl)`.
    function testFuzz_performanceFeeBaseIsMinOfViewAndRealizedPnl(uint256 gain) public {
        // Floor of 7: below it the 15% fee rounds to zero and no event carries a base.
        gain = bound(gain, 7, 50_000e6);
        _asyncExitKeepingOneWei(false);
        _bobReseeds();

        uint256 pid = _proposeAndExecute(bob);
        usdc.mint(address(vault), gain);
        uint256 view_ = vault.aboveHighWaterMark();

        uint256 base = _settleAndChargedBase(pid);
        assertEq(base, view_ < gain ? view_ : gain, "base == min(aboveHighWaterMark, pnl)");
    }

    /// @notice A donation that lands between two settlements lifts the view
    ///         above the mark but is not the next proposal's P&L: charged 0.
    function test_donationBetweenSettlementsIsNeverChargedAsPerformanceFee() public {
        vm.prank(alice);
        vault.deposit(EPOCH1, alice);
        assertEq(_settleAndChargedBase(_proposeAndExecute(alice)), 0, "sanity: a flat epoch charges nothing");
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);

        uint256 donation = 100e6;
        vm.prank(donor);
        usdc.transfer(address(vault), donation);
        assertApproxEqRel(vault.aboveHighWaterMark(), donation, 1e12, "sanity: the whole donation sits above the mark");

        uint256 pid = _proposeAndExecute(alice);
        uint256 before = usdc.balanceOf(address(vault));
        assertEq(_settleAndChargedBase(pid), 0, "zero P&L on the proposal: no base");
        assertEq(usdc.balanceOf(address(vault)), before, "the donation stays with the holders");
    }

    // ── supply immobility, the premise the clamp is exact on ──

    /// @notice `totalSupply()` and `_pricingSupply()` cannot move between execute
    ///         and the fee read: every mint/burn path is shut, and the fee is
    ///         read before the settlement stamp moves the pricing supply.
    function test_shareSupplyIsConstantBetweenExecuteAndSettle() public {
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(EPOCH1, alice);

        // Epoch 1 leaves a stamped-but-unclaimed redeem behind.
        uint256 pid1 = _proposeAndExecute(alice);
        vm.prank(alice);
        vault.requestRedeem(aliceShares / 2, alice);
        _settleAndChargedBase(pid1);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN_PERIOD + 1);
        _bobReseeds();

        uint256 pid2 = _proposeAndExecute(alice);
        uint256 supplyAtExecute = vault.totalSupply();
        uint256 pricingAtExecute = _pricingSupply();

        // Instant lanes: shut.
        vm.startPrank(bob);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1e6, bob);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.mint(1e6, bob);
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(1e6, bob, bob);
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxWithdraw.selector);
        vault.withdraw(1e6, bob, bob);
        vm.stopPrank();

        // A prior epoch's stamped redeem: cannot claim (burn) mid-proposal.
        vm.prank(alice);
        vm.expectRevert(IVaultWithdrawalQueue.VaultLocked.selector);
        queue.claim(1);

        // Queue requests move custody, not supply; a deposit claim cannot mint.
        vm.startPrank(bob);
        uint256 depReq = vault.requestDeposit(1e6, bob);
        vm.expectRevert(IVaultWithdrawalQueue.VaultLocked.selector);
        queue.claim(depReq);
        uint256 redReq = vault.requestRedeem(1e6, bob);
        queue.cancel(redReq);
        uint256 escrowed = 2e6;
        vault.requestRedeem(escrowed, bob);
        vm.stopPrank();
        usdc.mint(address(vault), 300e6);

        assertEq(vault.totalSupply(), supplyAtExecute, "no mint or burn between execute and settle");
        assertEq(_pricingSupply(), pricingAtExecute, "no stamp between execute and settle");

        // The fee is read at the execute-time pricing supply, before the stamp.
        uint256 viewBeforeSettle = vault.aboveHighWaterMark();
        assertLt(viewBeforeSettle, 300e6, "sanity: the view sits below the gain, so it is the unclamped base");
        assertEq(_settleAndChargedBase(pid2), viewBeforeSettle, "base read at the pre-stamp pricing supply");
        assertEq(vault.totalSupply(), supplyAtExecute, "settlement itself mints and burns nothing");
        assertEq(
            _pricingSupply(), pricingAtExecute - escrowed, "only the stamp, after the fee, moves the pricing supply"
        );
    }
}
