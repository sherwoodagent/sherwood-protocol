// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";

/// @dev Tier registry stand-in whose `strategyFactory()` is the REAL StrategyFactory, so every
///      batch target / proposal strategy must pass the real `isRegisteredStrategy`.
///      `tierOf` is the conservative end (tier 2, full notional); with zero caps coverage is 0 anyway.
contract ZeroEgress_TierRegistryStub is ITierRegistry {
    address public immutable factoryAddr;

    constructor(address f) {
        factoryAddr = f;
    }

    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }

    function isCounterpartyAllowed(address) external pure returns (bool) {
        return true;
    }

    function strategyFactory() external view returns (address) {
        return factoryAddr;
    }

    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }
}

/// @dev Owner-authored hand-written strategy: `execute()` flips executed on, `settle()` flips it off.
contract ZeroEgress_HealthyStrategy {
    address public vault;
    address public proposer;
    bool public executed;

    constructor(address v, address p) {
        vault = v;
        proposer = p;
    }

    function execute() external {
        executed = true;
    }

    function settle() external {
        executed = false;
    }
}

/// @dev Owner-authored strategy whose `settle()` never clears `executed`, so the normal settle
///      and `unstick` both refuse (`StrategyNotSettled`) while the emergency finalize is exempt.
contract ZeroEgress_StuckStrategy {
    address public vault;
    address public proposer;
    bool public executed;

    constructor(address v, address p) {
        vault = v;
        proposer = p;
    }

    function execute() external {
        executed = true;
    }

    function settle() external {}
}

/// @dev Lender stand-in: holds a non-asset collateral for `borrower` until `debt` is repaid in the asset.
contract ZeroEgress_Lender {
    IERC20 public immutable debtToken;
    IERC20 public immutable collateral;
    address public borrower;
    uint256 public debt;

    constructor(IERC20 d, IERC20 c) {
        debtToken = d;
        collateral = c;
    }

    function open(address b, uint256 amount) external {
        borrower = b;
        debt = amount;
    }

    function repay() external {
        require(msg.sender == borrower, "borrower");
        debtToken.transferFrom(msg.sender, address(this), debt);
        debt = 0;
        collateral.transfer(borrower, collateral.balanceOf(address(this)));
    }
}

/// @dev Strategy whose committed leg is dead; `unwind()` repays the lender from its own balance and
///      sends the freed collateral to the vault. `release()` returns asset it holds to the vault.
contract ZeroEgress_RepayStrategy {
    address public vault;
    address public proposer;
    bool public executed;
    IERC20 public immutable asset;
    IERC20 public immutable collateral;
    ZeroEgress_Lender public lender;

    constructor(address v, address p, IERC20 a, IERC20 c) {
        vault = v;
        proposer = p;
        asset = a;
        collateral = c;
    }

    function setLender(ZeroEgress_Lender l) external {
        lender = l;
    }

    function execute() external {
        executed = true;
    }

    function settle() external {}

    function unwind() external {
        asset.approve(address(lender), type(uint256).max);
        lender.repay();
        collateral.transfer(vault, collateral.balanceOf(address(this)));
        executed = false;
    }

    function release() external {
        asset.transfer(vault, asset.balanceOf(address(this)));
        executed = false;
    }
}

/// @title V1-02 regression: `finalizeEmergencySettle` runs the owner batch with a zero net egress budget.
/// @notice Adapted from the audit PoC `test/audit-2026-10-01/E2_2_emergencyVetoElectorate.t.sol`; the
///         guardian-veto electorate is unchanged, so padding still defeats the veto, but the batch can
///         no longer move vault float.
contract GovernorEmergency_zeroEgressBudgetTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    StrategyFactory public strategyFactory;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;

    address public owner = makeAddr("owner");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public guardianA = makeAddr("guardianA");
    address public guardianB = makeAddr("guardianB");
    address public padder = makeAddr("padder");
    address public recipient = makeAddr("recipient");
    address public stranger = makeAddr("stranger");
    address public factoryEoa;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;

    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant UNSTAKE_COOLDOWN = 7 days;
    uint256 constant GUARDIAN_STAKE = 30_000e18; // each of A, B → H = 60k
    uint256 constant H = 2 * GUARDIAN_STAKE;
    uint256 constant TVL = 100_000e6;
    uint256 constant DURATION = 7 days;

    function setUp() public {
        factoryEoa = address(this);

        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        uint256 ownerAgentId = agentRegistry.mint(owner);

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

        // Launch posture: owner registers itself as the agent (NFT owner == vault owner is accepted).
        vm.prank(owner);
        vault.registerAgent(ownerAgentId, owner);

        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        // REAL StrategyFactory (registerStrategy is permissionless) behind a tier-registry stub.
        strategyFactory = new StrategyFactory(address(this), owner);
        address tierReg = address(new ZeroEgress_TierRegistryStub(address(strategyFactory)));
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: factoryEoa,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: UNSTAKE_COOLDOWN,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                predictedRegistryProxy,
                address(_hoistedPC),
                address(this),
                tierReg,
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
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
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(true));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        address govVault = governor.vault();
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), govVault);
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        vm.prank(owner);
        swood.setRegistry(address(registry));

        usdc.mint(lp1, 100_000e6);
        usdc.mint(lp2, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        wood.mint(owner, 100_000e18);
        vm.startPrank(owner);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.stopPrank();
        vm.prank(factoryEoa);
        swood.bindOwnerStake(owner, address(vault));

        _stake(guardianA, GUARDIAN_STAKE, 1);
        _stake(guardianB, GUARDIAN_STAKE, 2);
        vm.warp(vm.getBlockTimestamp() + 30 days);
    }

    // ───────────────────────── helpers ─────────────────────────

    function _stake(address g, uint256 amt, uint256 agentId) internal {
        wood.mint(g, amt);
        vm.startPrank(g);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(amt, agentId);
        vm.stopPrank();
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](1);
        c[0] = BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _zeroCaps() internal pure returns (uint256[] memory caps) {
        caps = new uint256[](1);
    }

    /// @dev Padder stakes D at T-1 (when D > 0), owner proposes at T, padder requests unstake at T.
    function _propose(address strat, uint256 maxCapital, BatchExecutorLib.Call[] memory settleLeg, uint256 d)
        internal
        returns (uint256 pid)
    {
        if (d > 0) {
            _stake(padder, d, 99);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        vm.prank(owner);
        pid = governor.propose(
            address(vault),
            strat,
            "ipfs://e2-2",
            DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 500}),
            _call(strat, abi.encodeWithSignature("execute()")),
            _zeroCaps(),
            settleLeg,
            _zeroCaps(),
            new ISyndicateGovernor.CoProposer[](0)
        );
        if (d > 0) {
            vm.prank(padder);
            swood.requestUnstakeGuardian(); // same second as propose
        }
    }

    function _openReviewAndExecute(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        governor.executeProposal(pid);
    }

    /// @dev Full lifecycle up to an executed proposal whose duration has elapsed; padder reclaims D first.
    function _executedAndMatured(address strat, uint256 maxCapital, BatchExecutorLib.Call[] memory settleLeg, uint256 d)
        internal
        returns (uint256 pid)
    {
        uint256 proposedAt = vm.getBlockTimestamp() + (d > 0 ? 1 : 0);
        pid = _propose(strat, maxCapital, settleLeg, d);
        _openReviewAndExecute(pid);
        if (d > 0) {
            vm.warp(proposedAt + UNSTAKE_COOLDOWN);
            vm.prank(padder);
            swood.claimUnstakeGuardian();
            assertEq(wood.balanceOf(padder), d, "padder recovered D in full before the emergency path opens");
            assertEq(swood.totalGuardianStake(), H, "live electorate is back to the honest H");
        }
        uint256 matured = governor.getProposal(pid).executedAt + DURATION;
        assertGt(matured, vm.getBlockTimestamp(), "padder claimed before emergencySettleWithCalls is reachable");
        vm.warp(matured);
    }

    function _healthy() internal returns (address s) {
        s = address(new ZeroEgress_HealthyStrategy(address(vault), owner));
        strategyFactory.registerStrategy(s);
    }

    function _stuck() internal returns (address s) {
        s = address(new ZeroEgress_StuckStrategy(address(vault), owner));
        strategyFactory.registerStrategy(s);
    }

    function _executedStuck(uint256 d) internal returns (uint256) {
        address s = _stuck();
        return _executedAndMatured(s, TVL, _call(s, abi.encodeWithSignature("settle()")), d);
    }

    function _drainCalls(uint256 amt) internal view returns (BatchExecutorLib.Call[] memory) {
        return _call(address(usdc), abi.encodeCall(usdc.transfer, (recipient, amt)));
    }

    function _openEmergency(uint256 pid, BatchExecutorLib.Call[] memory calls) internal {
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, calls);
    }

    function _honestBlock(uint256 pid) internal {
        vm.prank(guardianA);
        registry.voteBlockEmergencySettle(address(governor), pid);
        vm.prank(guardianB);
        registry.voteBlockEmergencySettle(address(governor), pid);
    }

    function _weth() internal returns (ERC20Mock) {
        return new ERC20Mock("Wrapped Ether", "WETH", 18);
    }

    function _expectNoNetEgress(uint256 pid, uint256 netOutflow) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, netOutflow, 0));
        governor.finalizeEmergencySettle(pid);
    }

    // ───────────────────────── inverted drains ─────────────────────────

    /// @notice The full PoC sequence (propose-time padding defeats the veto) now ends in `MaxNetOutflowExceeded(TVL, 0)`.
    function test_paddedUnblockedEmergency_cannotDrainFloat() public {
        address s = _stuck();
        uint256 pid = _executedAndMatured(s, TVL, _call(s, abi.encodeWithSignature("settle()")), 150_000e18);
        assertEq(governor.getRequiredCoverage(pid), 0, "zero caps: no coverage");
        assertEq(governor.getEffectiveMaxCapital(pid), TVL, "effectiveMaxCapital is still 100% TVL");

        _openEmergency(pid, _drainCalls(TVL));
        _honestBlock(pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, TVL);

        assertEq(usdc.balanceOf(recipient), 0, "nothing left");
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault intact");
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
        registry.resolveEmergencyReview(address(governor), pid);
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "veto residual unchanged: round not blocked");
    }

    /// @notice A self-registered strategy that never clears `executed()` defeats the settle race, but the drain still reverts.
    function test_stuckSelfRegisteredStrategy_cannotDrainFloat() public {
        address s = address(new ZeroEgress_StuckStrategy(address(vault), owner));
        vm.prank(stranger);
        strategyFactory.registerStrategy(s);
        uint256 pid = _executedAndMatured(s, TVL, _call(s, abi.encodeWithSignature("settle()")), 150_000e18);
        _openEmergency(pid, _drainCalls(TVL));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.StrategyNotSettled.selector, s));
        governor.settleProposal(pid);

        _honestBlock(pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, TVL);
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault intact");
    }

    /// @notice A settlement leg that skips `settle()` defeats the settle race, but the drain still reverts.
    function test_settleLegSkippingSettle_cannotDrainFloat() public {
        address s = _healthy();
        uint256 pid =
            _executedAndMatured(s, TVL, _call(address(usdc), abi.encodeCall(usdc.approve, (s, 0))), 150_000e18);
        _openEmergency(pid, _drainCalls(TVL));
        _honestBlock(pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, TVL);
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault intact");
    }

    // ───────────────────────── the precise bound ─────────────────────────

    /// @notice With nothing deployed, an emergency `asset.transfer(recipient, n)` reverts for every n > 0.
    function testFuzz_zeroCoverage_anyPositiveTransferReverts(uint256 amount) public {
        amount = bound(amount, 1, TVL);
        uint256 pid = _executedStuck(0);
        _openEmergency(pid, _drainCalls(amount));
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, amount);
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault intact");
    }

    /// @notice Residual pin: asset the strategy returns in the same batch can still be redirected, but not one unit more.
    function test_capitalReturnedInBatch_canStillBeRedirected() public {
        ERC20Mock weth = _weth();
        uint256 held = 25_000e6;
        ZeroEgress_RepayStrategy s = new ZeroEgress_RepayStrategy(address(vault), owner, usdc, weth);
        strategyFactory.registerStrategy(address(s));
        uint256 pid = _executedAndMatured(address(s), TVL, _call(address(s), abi.encodeWithSignature("settle()")), 0);
        usdc.mint(address(s), held); // stands in for capital the strategy holds

        BatchExecutorLib.Call[] memory calls = new BatchExecutorLib.Call[](2);
        calls[0] = BatchExecutorLib.Call({target: address(s), data: abi.encodeWithSignature("release()"), value: 0});
        calls[1] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (recipient, held + 1)), value: 0
        });
        _openEmergency(pid, calls);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, 1);

        calls[1].data = abi.encodeCall(usdc.transfer, (recipient, held));
        _openEmergency(pid, calls);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);
        assertEq(usdc.balanceOf(recipient), held, "returned capital redirected; the guardian veto is the control here");
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault float untouched");
    }

    // ───────────────────────── honest unwind ─────────────────────────

    /// @notice A repay funded from vault float reverts; the same repay funded from outside the vault unwinds and settles.
    function test_honestRepay_fundedFromOutsideTheVault() public {
        ERC20Mock weth = _weth();
        uint256 debt = 10_000e6;
        uint256 collat = 50_000e18;
        ZeroEgress_RepayStrategy s = new ZeroEgress_RepayStrategy(address(vault), owner, usdc, weth);
        ZeroEgress_Lender lender = new ZeroEgress_Lender(usdc, weth);
        s.setLender(lender);
        lender.open(address(s), debt);
        weth.mint(address(lender), collat);
        strategyFactory.registerStrategy(address(s));
        uint256 pid = _executedAndMatured(address(s), TVL, _call(address(s), abi.encodeWithSignature("settle()")), 0);

        // Funding the repay from vault float is net egress.
        BatchExecutorLib.Call[] memory vaultFunded = new BatchExecutorLib.Call[](2);
        vaultFunded[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (address(s), debt)), value: 0
        });
        vaultFunded[1] =
            BatchExecutorLib.Call({target: address(s), data: abi.encodeWithSignature("unwind()"), value: 0});
        _openEmergency(pid, vaultFunded);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        _expectNoNetEgress(pid, debt);

        // The owner sends the repay to the strategy from outside; the batch only unwinds.
        usdc.mint(owner, debt);
        vm.prank(owner);
        usdc.transfer(address(s), debt);
        _openEmergency(pid, _call(address(s), abi.encodeWithSignature("unwind()")));
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(weth.balanceOf(address(vault)), collat, "collateral back in the vault");
        assertEq(usdc.balanceOf(address(vault)), TVL, "vault float untouched");
        assertEq(lender.debt(), 0, "debt repaid");
    }
}
