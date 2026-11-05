// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {GenericCallStrategy} from "../../src/strategies/GenericCallStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockCallVenue, RevertingVenue, MockNFT, MockNftMarket} from "../mocks/GenericCallMocks.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PermissiveTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @notice A venue that, when called from a leg, tries every lifecycle entry point it can reach.
contract ReenteringVenue {
    GenericCallStrategy public strategy;
    SyndicateVault public vault;
    SyndicateGovernor public governor;
    uint256 public pid;
    uint256 public successes;
    bytes4[] public reasons;

    function arm(GenericCallStrategy s, SyndicateVault v, SyndicateGovernor g, uint256 p) external {
        strategy = s;
        vault = v;
        governor = g;
        pid = p;
    }

    function poke() external {
        _try(address(strategy), abi.encodeCall(BaseStrategy.settle, ()));
        _try(address(strategy), abi.encodeCall(BaseStrategy.execute, ()));
        _try(address(strategy), abi.encodeCall(BaseStrategy.rescueTo, (vault.asset())));
        _try(address(strategy), abi.encodeCall(GenericCallStrategy.rescueERC721To, (vault.asset(), 0)));
        _try(
            address(vault),
            abi.encodeCall(SyndicateVault.executeGovernorBatch, (new BatchExecutorLib.Call[](0), new uint256[](0), 0))
        );
        _try(address(vault), abi.encodeCall(vault.deposit, (1, address(this))));
        _try(address(vault), abi.encodeCall(SyndicateVault.settleRedeem, (0, 0, address(this))));
        _try(address(governor), abi.encodeCall(SyndicateGovernor.settleProposal, (pid)));
        _try(address(governor), abi.encodeCall(SyndicateGovernor.executeProposal, (pid)));
    }

    function _try(address target, bytes memory data) private {
        (bool ok, bytes memory ret) = target.call(data);
        if (ok) successes++;
        reasons.push(bytes4(ret));
    }

    function attempts() external view returns (uint256) {
        return reasons.length;
    }
}

/// @title GenericCallStrategy_lifecycle
/// @notice A real governor/vault/registry stack driving a real `GenericCallStrategy` clone.
contract GenericCallStrategyLifecycleTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdg;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;
    MockCallVenue public venue;
    GenericCallStrategy public template;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");
    address public factoryEoa;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant STRATEGY_DURATION = 2 days;
    uint256 constant PULL = 10_000e6;
    uint256 constant YIELD = 500e6;

    function setUp() public {
        factoryEoa = address(this);
        usdg = new ERC20Mock("Global Dollar", "USDG", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        uint256 agentNftId = agentRegistry.mint(agent);

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdg),
                    name: "Sherwood Vault",
                    symbol: "swUSDG",
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

        ProtocolConfig pc = new ProtocolConfig(owner);
        address tierRegistry = address(new PermissiveTierRegistry());
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
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                predictedRegistryProxy,
                address(pc),
                address(this),
                tierRegistry,
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
        vm.mockCall(address(this), abi.encodeWithSignature("depositsRestricted()"), abi.encode(false));
        vm.mockCall(address(this), abi.encodeWithSignature("ownerOnlyProposals()"), abi.encode(false));
        require(address(governor) == predictedGovernor, "governor addr mismatch");

        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit =
            abi.encodeCall(GuardianRegistry.initialize, (owner, factoryEoa, address(swood), REVIEW_PERIOD, 3000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), governor.vault());
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");

        vm.prank(owner);
        swood.setRegistry(address(registry));

        usdg.mint(lp1, 100_000e6);
        usdg.mint(lp2, 100_000e6);
        vm.startPrank(lp1);
        usdg.approve(address(vault), 60_000e6);
        vault.deposit(60_000e6, lp1);
        vm.stopPrank();
        vm.startPrank(lp2);
        usdg.approve(address(vault), 40_000e6);
        vault.deposit(40_000e6, lp2);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);

        wood.mint(owner, 100_000e18);
        vm.prank(owner);
        wood.approve(address(swood), type(uint256).max);
        vm.prank(owner);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.prank(factoryEoa);
        swood.bindOwnerStake(owner, address(vault));

        venue = new MockCallVenue();
        template = new GenericCallStrategy();
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _clone(BatchExecutorLib.Call[] memory e, BatchExecutorLib.Call[] memory s)
        internal
        returns (GenericCallStrategy c)
    {
        c = GenericCallStrategy(Clones.clone(address(template)));
        c.initialize(
            address(vault), agent, abi.encode(PULL, e, s, new GenericCallStrategy.BalancePatch[](0), new address[](0))
        );
    }

    /// @dev The batch shape the Arena runner and the CLI emit, with caps [0, PULL] and [0].
    function _propose(GenericCallStrategy c) internal returns (uint256 pid) {
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdg), abi.encodeCall(IERC20.approve, (address(c), PULL)));
        execCalls[1] = _call(address(c), abi.encodeCall(BaseStrategy.execute, ()));
        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](1);
        settleCalls[0] = _call(address(c), abi.encodeCall(BaseStrategy.settle, ()));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = PULL;
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(c),
            "ipfs://generic-call",
            STRATEGY_DURATION,
            env,
            execCalls,
            execCaps,
            settleCalls,
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _approve(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
    }

    function _depositLeg() internal view returns (BatchExecutorLib.Call[] memory e) {
        e = new BatchExecutorLib.Call[](2);
        e[0] = _call(address(usdg), abi.encodeCall(IERC20.approve, (address(venue), PULL)));
        e[1] = _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (address(usdg), PULL)));
    }

    /// @notice Propose, vote, review, execute and settle with the runner's batch shape; the yield is P&L.
    function test_lifecycle_executeAndSettleThroughGovernor() public {
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](1);
        s[0] = _call(address(venue), abi.encodeCall(MockCallVenue.withdrawWithYield, (address(usdg), PULL, YIELD)));
        GenericCallStrategy c = _clone(_depositLeg(), s);
        uint256 pid = _propose(c);
        assertEq(governor.getProposalTier(pid), 2, "uncertified clone prices at tier 2");
        _approve(pid);

        uint256 vaultBefore = usdg.balanceOf(address(vault));
        governor.executeProposal(pid);
        assertEq(usdg.balanceOf(address(vault)), vaultBefore - PULL, "vault paid the pull");
        assertEq(usdg.allowance(address(vault), address(c)), 0, "vault allowance reset");
        assertEq(usdg.allowance(address(c), address(venue)), 0, "venue allowance revoked");
        assertEq(venue.deposited(address(usdg), address(c)), PULL);
        assertTrue(vault.redemptionsLocked());

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        governor.settleProposal(pid);

        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Settled));
        assertEq(usdg.balanceOf(address(c)), 0, "nothing left on the clone");
        uint256 vaultAfter = usdg.balanceOf(address(vault));
        assertGt(vaultAfter, vaultBefore, "yield reached the vault");
        assertLe(vaultAfter, vaultBefore + YIELD, "no more than the yield");
        assertFalse(vault.redemptionsLocked());
    }

    /// @notice A failing inner call reverts `executeProposal` with the leg, index and venue error.
    function test_lifecycle_failedInnerCallRevertsExecuteProposal() public {
        RevertingVenue bad = new RevertingVenue();
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](1);
        e[0] = _call(address(bad), abi.encodeCall(RevertingVenue.fail, (3)));
        GenericCallStrategy c = _clone(e, new BatchExecutorLib.Call[](0));
        uint256 pid = _propose(c);
        _approve(pid);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.CallFailed.selector,
                uint8(0),
                0,
                abi.encodeWithSelector(RevertingVenue.Boom.selector, 3)
            )
        );
        governor.executeProposal(pid);
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Pending));
    }

    /// @dev The refusal each `poke` attempt must hit, in order; settleRedeem proves the vault lock is held.
    function _expectedReasons() internal pure returns (bytes4[9] memory) {
        return [
            BaseStrategy.NotVault.selector,
            BaseStrategy.NotVault.selector,
            BaseStrategy.NotVault.selector,
            BaseStrategy.NotVault.selector,
            ISyndicateVault.NotGovernor.selector,
            ISyndicateVault.DepositsLocked.selector,
            ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector,
            ISyndicateGovernor.Reentrancy.selector,
            ISyndicateGovernor.Reentrancy.selector
        ];
    }

    function _assertReasons(ReenteringVenue r, uint256 from) internal view {
        bytes4[9] memory want = _expectedReasons();
        for (uint256 k; k < want.length; ++k) {
            assertEq(bytes32(r.reasons(from + k)), bytes32(want[k]), vm.toString(k));
        }
    }

    /// @notice A venue in either leg reaches no lifecycle entry point: each attempt hits its own guard.
    function test_lifecycle_reenteringVenueGetsNothing() public {
        ReenteringVenue r = new ReenteringVenue();
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](1);
        e[0] = _call(address(r), abi.encodeCall(ReenteringVenue.poke, ()));
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](1);
        s[0] = _call(address(r), abi.encodeCall(ReenteringVenue.poke, ()));
        GenericCallStrategy c = _clone(e, s);
        uint256 pid = _propose(c);
        r.arm(c, vault, governor, pid);
        _approve(pid);

        governor.executeProposal(pid);
        assertEq(r.attempts(), 9);
        assertEq(r.successes(), 0, "execute leg reached the lifecycle");
        _assertReasons(r, 0);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        governor.settleProposal(pid);
        assertEq(r.attempts(), 18);
        assertEq(r.successes(), 0, "settle leg reached the lifecycle");
        _assertReasons(r, 9);
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
    }

    /// @notice An NFT bought at execute whose sale fails at settle is pulled home by the owner's emergency batch.
    function test_lifecycle_stuckNftRecoveredByEmergencyBatch() public {
        MockNFT nft = new MockNFT();
        MockNftMarket market = new MockNftMarket(nft, usdg);
        nft.mint(address(market), 7);
        usdg.mint(address(market), PULL);
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(address(usdg), abi.encodeCall(IERC20.approve, (address(market), PULL)));
        e[1] = _call(address(market), abi.encodeCall(MockNftMarket.buy, (7, PULL)));
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](2);
        s[0] = _call(address(nft), abi.encodeCall(nft.setApprovalForAll, (address(market), true)));
        s[1] = _call(address(market), abi.encodeCall(MockNftMarket.sell, (7, PULL)));
        GenericCallStrategy c = _clone(e, s);
        uint256 pid = _propose(c);
        _approve(pid);
        governor.executeProposal(pid);
        assertEq(nft.ownerOf(7), address(c));

        market.setClosed(true);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                GenericCallStrategy.CallFailed.selector,
                uint8(1),
                1,
                abi.encodeWithSignature("Error(string)", "market closed")
            )
        );
        governor.settleProposal(pid);

        BatchExecutorLib.Call[] memory rescue = new BatchExecutorLib.Call[](1);
        rescue[0] = _call(address(c), abi.encodeCall(GenericCallStrategy.rescueERC721To, (address(nft), 7)));
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, rescue);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(nft.ownerOf(7), address(vault), "NFT home");
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(vault.redemptionsLocked());
    }

    /// @notice A position held inside a venue whose settle leg can never run is lost: `unstick` replays the
    ///         same leg, and the emergency batch recovers only what the clone itself holds.
    function test_lifecycle_venueHeldPositionIsLostWhenSettleCannotRun() public {
        uint256 half = PULL / 2;
        BatchExecutorLib.Call[] memory e = new BatchExecutorLib.Call[](2);
        e[0] = _call(address(usdg), abi.encodeCall(IERC20.approve, (address(venue), half)));
        e[1] = _call(address(venue), abi.encodeCall(MockCallVenue.deposit, (address(usdg), half)));
        BatchExecutorLib.Call[] memory s = new BatchExecutorLib.Call[](1);
        s[0] = _call(address(venue), abi.encodeCall(MockCallVenue.withdraw, (address(usdg), half)));
        GenericCallStrategy c = _clone(e, s);
        uint256 pid = _propose(c);
        _approve(pid);
        uint256 vaultBefore = usdg.balanceOf(address(vault));
        governor.executeProposal(pid);
        assertEq(usdg.balanceOf(address(c)), PULL - half, "half kept on the clone");

        venue.setClosed(true);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        bytes memory closed = abi.encodeWithSelector(
            GenericCallStrategy.CallFailed.selector,
            uint8(1),
            0,
            abi.encodeWithSelector(MockCallVenue.VenueClosed.selector)
        );
        vm.expectRevert(closed);
        governor.settleProposal(pid);
        vm.prank(owner);
        vm.expectRevert(closed);
        governor.unstick(pid);

        BatchExecutorLib.Call[] memory rescue = new BatchExecutorLib.Call[](1);
        rescue[0] = _call(address(c), abi.encodeCall(BaseStrategy.rescueTo, (address(usdg))));
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, rescue);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);

        assertEq(usdg.balanceOf(address(vault)), vaultBefore - half, "the clone's half came home");
        assertEq(venue.deposited(address(usdg), address(c)), half, "the venue's half is stranded");
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(uint256(c.state()), uint256(BaseStrategy.State.Executed), "clone orphaned");
        assertEq(uint256(governor.getProposal(pid).state), uint256(ISyndicateGovernor.ProposalState.Settled));
        assertFalse(vault.redemptionsLocked());
    }
}
