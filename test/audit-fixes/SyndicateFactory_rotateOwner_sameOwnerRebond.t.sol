// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice Hand-written strategy whose committed `settle` leg is dead; `forceUnwind` still works.
contract RebondStuckStrategy {
    error VenueDead();
    error NotVault();

    address public immutable vault;
    address public immutable proposer;
    IERC20 public immutable asset;
    address public immutable admin;
    bool public executed;
    bool public broken = true;

    constructor(address vault_, address proposer_, address asset_) {
        vault = vault_;
        proposer = proposer_;
        asset = IERC20(asset_);
        admin = msg.sender;
    }

    function name() external pure returns (string memory) {
        return "stuck";
    }

    function execute(uint256 amount) external {
        if (msg.sender != vault) revert NotVault();
        asset.transferFrom(vault, address(this), amount);
        executed = true;
    }

    function settle() external {
        if (msg.sender != vault) revert NotVault();
        if (broken) revert VenueDead();
        asset.transfer(vault, asset.balanceOf(address(this)));
        executed = false;
    }

    function forceUnwind() external {
        if (msg.sender != vault) revert NotVault();
        asset.transfer(vault, asset.balanceOf(address(this)));
        executed = false;
    }

    function setBroken(bool b) external {
        require(msg.sender == admin, "admin");
        broken = b;
    }
}

/// @title V1-03 regression: after a blocked emergency round burns the owner bond, the SAME owner
///        re-bonds through `rotateOwner(vault, owner)` while the stuck proposal is still open.
/// @notice Adapted from the audit PoC `test/audit-2026-10-01/D1_emergencyBondLockout.t.sol`.
contract SyndicateFactory_rotateOwner_sameOwnerRebondTest is Test {
    SyndicateFactory public factory;
    GuardianRegistry public registry;
    StakedWood public swood;
    TierRegistry public tierRegistry;
    StrategyFactory public strategyFactory;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;

    SyndicateVault public vault;
    SyndicateGovernor public gov;
    IVaultWithdrawalQueue public queue;
    RebondStuckStrategy public strategy;

    address public owner = makeAddr("protocolSafe");
    address public creator = makeAddr("vaultOwner");
    address public newOwner = makeAddr("newOwner");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public guardianA = makeAddr("guardianA"); // the blocker: exactly 30% of guardian stake
    address public guardianB = makeAddr("guardianB");
    address public keeper = makeAddr("keeper");
    uint256 public creatorAgentId;
    uint256 public newOwnerAgentId;

    address constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant BLOCK_QUORUM_BPS = 3000;
    uint256 constant STRATEGY_DURATION = 7 days;

    uint256 constant STAKE_A = 30_000e18;
    uint256 constant STAKE_B = 70_000e18;
    uint256 constant DEPLOYED = 60_000e6;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        SyndicateVault vaultImpl = new SyndicateVault();
        agentRegistry = new MockAgentRegistry();
        creatorAgentId = agentRegistry.mint(creator);
        newOwnerAgentId = agentRegistry.mint(newOwner);

        ProtocolConfig _hoistedPC = new ProtocolConfig(owner);
        TierRegistry _hoistedTierRegistry = new TierRegistry(owner);
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 6);
        address predictedFactoryProxy = vm.computeCreateAddress(address(this), baseNonce + 7);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: predictedFactoryProxy,
                    minGuardianStake: MIN_GUARDIAN_STAKE,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        GovernorBeacon beacon = new GovernorBeacon(address(govImpl), owner);

        SyndicateFactory factoryImpl = new SyndicateFactory();
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, predictedFactoryProxy, address(swood), REVIEW_PERIOD, BLOCK_QUORUM_BPS)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry address prediction mismatch");

        vm.prank(owner);
        swood.setRegistry(address(registry));

        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: address(executorLib),
                    vaultImpl: address(vaultImpl),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(_hoistedPC),
                    managementFeeBps: 50,
                    guardianRegistry: address(registry),
                    tierRegistry: address(_hoistedTierRegistry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        require(address(factory) == predictedFactoryProxy, "factory address prediction mismatch");

        tierRegistry = _hoistedTierRegistry;
        strategyFactory = new StrategyFactory(address(factory), owner);
        vm.prank(owner);
        tierRegistry.setStrategyFactory(address(strategyFactory));

        wood.mint(creator, 100_000e18);
        wood.mint(newOwner, 100_000e18);
        wood.mint(guardianA, STAKE_A);
        wood.mint(guardianB, STAKE_B);

        vm.startPrank(creator);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        (, address v) = factory.createSyndicate(
            creatorAgentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://d1",
                asset: usdc,
                name: "D1 Vault",
                symbol: "d1V",
                openDeposits: true,
                subdomain: "d1-fund"
            })
        );
        vault = SyndicateVault(payable(v));
        vault.registerAgent(creatorAgentId, creator);
        vm.stopPrank();
        gov = SyndicateGovernor(factory.governorOf(v));
        queue = IVaultWithdrawalQueue(vault.withdrawalQueue());

        usdc.mint(lp1, 60_000e6);
        usdc.mint(lp2, 40_000e6);
        vm.startPrank(lp1);
        usdc.approve(v, type(uint256).max);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdc.approve(v, type(uint256).max);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();

        vm.startPrank(guardianA);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE_A, 101);
        vm.stopPrank();
        vm.startPrank(guardianB);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(STAKE_B, 102);
        vm.stopPrank();
        skip(1 days);

        strategy = new RebondStuckStrategy(v, creator, address(usdc));
        vm.prank(creator);
        strategyFactory.registerStrategy(address(strategy));
    }

    // ── helpers ──

    function _execCalls(address s) internal view returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](2);
        c[0] =
            BatchExecutorLib.Call({target: address(usdc), data: abi.encodeCall(usdc.approve, (s, DEPLOYED)), value: 0});
        c[1] =
            BatchExecutorLib.Call({target: s, data: abi.encodeCall(RebondStuckStrategy.execute, (DEPLOYED)), value: 0});
    }

    function _settleCalls(address s) internal pure returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](1);
        c[0] = BatchExecutorLib.Call({target: s, data: abi.encodeCall(RebondStuckStrategy.settle, ()), value: 0});
    }

    function _emergencyCalls() internal view returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](1);
        c[0] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(RebondStuckStrategy.forceUnwind, ()), value: 0
        });
    }

    function _propose(address s) internal returns (uint256 pid) {
        uint256 cap = vault.totalAssets();
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = DEPLOYED;
        uint256[] memory settleCaps = new uint256[](1);
        vm.prank(creator);
        pid = gov.propose(
            address(vault),
            s,
            "ipfs://stuck",
            STRATEGY_DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: cap, maxDrawdownBps: 10_000}),
            _execCalls(s),
            execCaps,
            _settleCalls(s),
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    /// @dev propose → vote window → review → execute → duration elapsed; the committed leg is dead.
    function _stuckExecutedProposal() internal returns (uint256 pid) {
        pid = _propose(address(strategy));
        skip(24 hours + 1);
        registry.openReview(address(gov), pid);
        skip(REVIEW_PERIOD + 1);
        gov.executeProposal(pid);
        assertEq(usdc.balanceOf(address(strategy)), DEPLOYED, "capital deployed");
        skip(STRATEGY_DURATION + 1);

        vm.prank(keeper);
        vm.expectRevert(RebondStuckStrategy.VenueDead.selector);
        gov.settleProposal(pid);
        vm.prank(creator);
        vm.expectRevert(RebondStuckStrategy.VenueDead.selector);
        gov.unstick(pid);
    }

    /// @dev Owner opens a round, guardianA (30%) blocks it, a keeper resolves it: the bond is burned.
    function _openBlockResolve(uint256 pid) internal {
        vm.prank(creator);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());
        vm.prank(guardianA);
        registry.voteBlockEmergencySettle(address(gov), pid);
        skip(REVIEW_PERIOD + 1);
        vm.prank(keeper);
        registry.resolveEmergencyReview(address(gov), pid);
        assertEq(registry.ownerStake(address(vault)), 0, "bond slashed, slot deleted");
    }

    /// @dev The existing re-bond flow, run by the same owner while the proposal is open.
    function _rebondSameOwner() internal {
        vm.startPrank(creator);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        swood.approveOwnerStakeBinding(address(vault));
        factory.rotateOwner(address(vault), creator);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────
    // Regression (inverts test_poc_D1_blockedRoundPermanentlyLocksVault)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice After a blocked round burns the bond, the same owner re-bonds mid-proposal and a new round settles the vault.
    function test_blockedRound_sameOwnerRebond_recoversVault() public {
        uint256 pid = _stuckExecutedProposal();
        uint256 lp2Shares = vault.balanceOf(lp2);
        vm.prank(lp2);
        uint256 req = vault.requestRedeem(lp2Shares, lp2);

        _openBlockResolve(pid);
        assertEq(wood.balanceOf(BURN), MIN_OWNER_STAKE, "first bond burned");
        vm.prank(creator);
        vm.expectRevert(ISyndicateGovernor.OwnerBondInsufficient.selector);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());

        // Re-bond while the stuck proposal is still Executed and active.
        assertEq(gov.getActiveProposal(), pid, "proposal still active");
        assertEq(gov.openProposalCount(), 1, "proposal still open");
        _rebondSameOwner();
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "bond re-posted");
        assertEq(vault.owner(), creator, "owner unchanged");
        uint256 sid = factory.vaultToSyndicate(address(vault));
        (,, address creatorRecord,,,,) = factory.syndicates(sid);
        assertEq(creatorRecord, creator, "creator record unchanged");
        assertEq(swood.approvedBindVault(creator), address(0), "consent consumed");

        // A new emergency round opens (bond check passes), is not blocked, and settles.
        vm.prank(creator);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());
        skip(REVIEW_PERIOD + 1);
        vm.prank(creator);
        gov.finalizeEmergencySettle(pid);

        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled), "Settled");
        assertEq(gov.openProposalCount(), 0, "nothing open");
        assertEq(usdc.balanceOf(address(strategy)), 0, "capital home");
        assertFalse(vault.depositsLocked(), "deposits unlocked");
        assertFalse(vault.redemptionsLocked(), "redemptions unlocked");
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "second bond intact");

        vm.prank(lp2);
        queue.claim(req);
        assertGt(usdc.balanceOf(lp2), 0, "queued redemption claimed");
        uint256 lp1Shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        assertGt(vault.redeem(lp1Shares, lp1, lp1), 0, "instant redeem works");

        // rotateOwnership drains the agent set even for the same owner: re-register, then propose again.
        assertFalse(vault.isAgent(creator), "same-owner rotation drained the agent set");
        vm.prank(creator);
        vault.registerAgent(creatorAgentId, creator);
        skip(gov.getGovernorParams().cooldownPeriod + 1);
        RebondStuckStrategy next = new RebondStuckStrategy(address(vault), creator, address(usdc));
        vm.prank(creator);
        strategyFactory.registerStrategy(address(next));
        usdc.mint(lp1, 100_000e6);
        vm.prank(lp1);
        vault.deposit(100_000e6, lp1);
        uint256 pid2 = _propose(address(next));
        assertGt(pid2, pid, "owner proposes again after re-registering");
    }

    /// @notice Rotation to any other address in the same mid-proposal state is still refused.
    function test_blockedRound_rotateToStranger_stillRefused() public {
        uint256 pid = _stuckExecutedProposal();
        _openBlockResolve(pid);

        vm.startPrank(newOwner);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        swood.approveOwnerStakeBinding(address(vault));
        vm.stopPrank();

        vm.prank(creator);
        vm.expectRevert(SyndicateFactory.ProposalActive.selector);
        factory.rotateOwner(address(vault), newOwner);
        assertEq(vault.owner(), creator);
        assertEq(registry.ownerStake(address(vault)), 0);
    }

    /// @notice The same-owner re-bond still needs the owner's prepared stake and consent.
    function test_sameOwnerRebond_requiresPreparedStakeAndConsent() public {
        uint256 pid = _stuckExecutedProposal();
        _openBlockResolve(pid);

        vm.prank(creator);
        vm.expectRevert(StakedWood.PreparedStakeNotFound.selector);
        factory.rotateOwner(address(vault), creator);

        vm.prank(creator);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(creator);
        vm.expectRevert(StakedWood.BindingNotApproved.selector);
        factory.rotateOwner(address(vault), creator);

        vm.prank(creator);
        swood.approveOwnerStakeBinding(address(vault));
        vm.prank(creator);
        factory.rotateOwner(address(vault), creator);
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE);
    }

    /// @notice Each blocked attempt costs a bond: a second blocked round burns the re-posted bond.
    function test_secondBlockedRound_burnsSecondBond() public {
        uint256 pid = _stuckExecutedProposal();
        _openBlockResolve(pid);
        _rebondSameOwner();
        _openBlockResolve(pid);
        assertEq(wood.balanceOf(BURN), 2 * MIN_OWNER_STAKE, "both bonds burned");

        vm.prank(creator);
        vm.expectRevert(ISyndicateGovernor.OwnerBondInsufficient.selector);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());
        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Executed));
    }

    /// @notice While a blocked round is unresolved the bond is still posted, so re-bonding waits until anyone resolves it.
    function test_unresolvedBlockedRound_rebondAfterResolve() public {
        uint256 pid = _stuckExecutedProposal();
        vm.prank(creator);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());
        vm.prank(guardianA);
        registry.voteBlockEmergencySettle(address(gov), pid);
        skip(REVIEW_PERIOD + 1);

        vm.prank(creator);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(creator);
        swood.approveOwnerStakeBinding(address(vault));
        vm.prank(creator);
        vm.expectRevert(SyndicateFactory.VaultStillStaked.selector);
        factory.rotateOwner(address(vault), creator);

        vm.prank(keeper);
        registry.resolveEmergencyReview(address(gov), pid);
        vm.prank(creator);
        factory.rotateOwner(address(vault), creator);
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "re-bonded after resolution");
    }

    // ─────────────────────────────────────────────────────────────────────
    // Controls (kept from the PoC)
    // ─────────────────────────────────────────────────────────────────────

    /// @notice Same stuck proposal, no block: the bonded emergency path recovers the vault.
    function test_control_noBlock_finalizeRecovers() public {
        uint256 pid = _stuckExecutedProposal();
        vm.prank(creator);
        gov.emergencySettleWithCalls(pid, _emergencyCalls());
        skip(REVIEW_PERIOD + 1);
        vm.prank(creator);
        gov.finalizeEmergencySettle(pid);

        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(vault.redemptionsLocked());
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "bond intact");
    }

    /// @notice If the venue recovers after the slash, ordinary settlement closes the proposal and re-bonding works.
    function test_control_venueRecovers_settleStillWorksAfterSlash() public {
        uint256 pid = _stuckExecutedProposal();
        _openBlockResolve(pid);

        strategy.setBroken(false);
        vm.prank(keeper);
        gov.settleProposal(pid);
        assertEq(uint256(gov.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(vault.redemptionsLocked());

        _rebondSameOwner();
        assertEq(registry.ownerStake(address(vault)), MIN_OWNER_STAKE, "re-bonded once nothing is open");
    }
}
