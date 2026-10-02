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
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {ITierRegistry} from "../../src/interfaces/ITierRegistry.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAssetLedger} from "../mocks/MockAssetLedger.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockSwapAdapter} from "../mocks/MockSwapAdapter.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @notice Permissive tier registry that points at a REAL StrategyFactory.
contract RescueTierRegistry is ITierRegistry {
    address public immutable sf;

    constructor(address sf_) {
        sf = sf_;
    }

    function tierOf(address, bytes4) external pure returns (uint8, uint16) {
        return (2, 10_000);
    }

    function isCounterpartyAllowed(address) external pure returns (bool) {
        return true;
    }

    function isMorphoMarketAllowed(bytes32) external pure returns (bool) {
        return true;
    }

    function strategyFactory() external view returns (address) {
        return sf;
    }

    function classOf(address) external pure returns (bytes32) {
        return bytes32(0);
    }

    function isPriceSourceForToken(address, bytes32) external pure returns (bool) {
        return true;
    }
}

contract RescueAggregator {
    uint8 public decimals;
    int256 internal _answer;
    uint256 internal _updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, _answer, 0, _updatedAt, 0);
    }
}

/// @notice Stand-in for another vault: answers `governor()` and `asset()` so a template clone can initialise against it.
contract OtherVaultStub {
    address public governor;
    address public asset;

    constructor(address governor_, address asset_) {
        governor = governor_;
        asset = asset_;
    }
}

/// @notice FP-04 token leg (audit 2026-10-02, N-05): a rescued non-asset token can only go to a strategy clone of the vault.
contract Vault_rescueERC20StrategyOnlyTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    GuardianRegistry public registry;
    StakedWood public swood;
    StrategyFactory public sf;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    ERC20Mock public tsla;
    MockAgentRegistry public agentRegistry;
    MockSwapAdapter public adapter;
    RescueAggregator public feed;
    PortfolioStrategy public template;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant DEPLOY_AMOUNT = 50_000e6;
    uint256 constant STRATEGY_DURATION = 2 days;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        tsla = new ERC20Mock("Tesla Token", "TSLA", 18);
        BatchExecutorLib executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        vm.mockCall(address(this), abi.encodeWithSignature("agentRegistry()"), abi.encode(address(agentRegistry)));
        // This test contract stands in for the SyndicateFactory: every vault reads as registered.
        vm.mockCall(address(this), abi.encodeWithSignature("vaultToSyndicate(address)"), abi.encode(uint256(1)));
        uint256 agentNftId = agentRegistry.mint(agent);

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
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(new SyndicateVault()), vaultInit))));
        vm.prank(owner);
        vault.registerAgent(agentNftId, agent);

        ProtocolConfig pc = new ProtocolConfig(owner);
        sf = new StrategyFactory(address(this), owner);
        address tierRegistry = address(new RescueTierRegistry(address(sf)));
        uint256 baseNonce = vm.getNonce(address(this));
        address predictedGovernor = vm.computeCreateAddress(address(this), baseNonce + 3);
        address predictedRegistryProxy = vm.computeCreateAddress(address(this), baseNonce + 5);

        StakedWood swoodImpl = new StakedWood();
        bytes memory swoodInit = abi.encodeCall(
            StakedWood.initialize,
            (StakedWood.InitParams({
                    owner: owner,
                    wood: address(wood),
                    factory: address(this),
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 10_000,
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
                    executionWindow: 1 days,
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
            abi.encodeCall(GuardianRegistry.initialize, (owner, address(this), address(swood), REVIEW_PERIOD, 3000));
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        address govVault = governor.vault();
        vm.prank(registry.factory());
        registry.addGovernor(address(governor), govVault);
        require(address(registry) == predictedRegistryProxy, "registry addr mismatch");
        // Portfolio's $1 asset check reads governor.exposureLedger(); only the getter is mocked.
        MockAssetLedger usdLedger = new MockAssetLedger();
        usdLedger.setPrice(address(usdc), 1e8);
        vm.mockCall(address(governor), abi.encodeWithSignature("exposureLedger()"), abi.encode(address(usdLedger)));
        vm.prank(owner);
        swood.setRegistry(address(registry));

        usdc.mint(lp1, 60_000e6);
        usdc.mint(lp2, 40_000e6);
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
        swood.bindOwnerStake(owner, address(vault));

        adapter = new MockSwapAdapter();
        adapter.setRate(address(usdc), address(tsla), 1e28);
        adapter.setRate(address(tsla), address(usdc), 1e8);
        tsla.mint(address(adapter), 1_000_000e18);
        usdc.mint(address(adapter), 100_000_000e6);
        feed = new RescueAggregator(8, 100e8, vm.getBlockTimestamp());
        template = new PortfolioStrategy();
        vm.prank(owner);
        sf.setTemplateApproval(address(template), true);
    }

    // ── helpers ──

    function _initData() internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(tsla);
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        uint8[] memory priceDecs = new uint8[](1);
        priceDecs[0] = 8;
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        return abi.encode(
            address(usdc), address(adapter), tokens, weights, DEPLOY_AMOUNT, 100, new bytes[](1), priceDecs, feeds
        );
    }

    function _call(address target, bytes memory data) internal pure returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: target, data: data, value: 0});
    }

    function _one(BatchExecutorLib.Call memory c) internal pure returns (BatchExecutorLib.Call[] memory a) {
        a = new BatchExecutorLib.Call[](1);
        a[0] = c;
    }

    function _factoryClone(address boundVault) internal returns (address clone) {
        vm.prank(agent);
        clone = sf.cloneAndInit(address(template), boundVault, agent, _initData());
    }

    function _vote(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        registry.openReview(address(governor), pid);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        feed.setUpdatedAt(vm.getBlockTimestamp());
    }

    /// @dev A factory clone executes a 500 TSLA basket; an emergency batch rescues it into the vault and finalises.
    function _basketRescuedIntoVault() internal returns (address clone) {
        clone = _factoryClone(address(vault));
        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(IERC20.approve, (clone, DEPLOY_AMOUNT)));
        execCalls[1] = _call(clone, abi.encodeCall(BaseStrategy.execute, ()));
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = DEPLOY_AMOUNT;
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            clone,
            "ipfs://fp04",
            STRATEGY_DURATION,
            env,
            execCalls,
            execCaps,
            _one(_call(clone, abi.encodeCall(BaseStrategy.settle, ()))),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        _vote(pid);
        governor.executeProposal(pid);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        BatchExecutorLib.Call[] memory rescue = new BatchExecutorLib.Call[](2);
        rescue[0] = _call(clone, abi.encodeCall(BaseStrategy.rescueTo, (address(tsla))));
        rescue[1] = _call(clone, abi.encodeCall(BaseStrategy.rescueTo, (address(usdc))));
        vm.prank(owner);
        governor.emergencySettleWithCalls(pid, rescue);
        vm.warp(vm.getBlockTimestamp() + REVIEW_PERIOD + 1);
        vm.prank(owner);
        governor.finalizeEmergencySettle(pid);
        assertEq(tsla.balanceOf(address(vault)), 500e18, "basket in the vault");
        assertEq(vault.totalAssets(), 50_000e6, "basket unpriced");
    }

    function _expectRescueRefused(address to) internal {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.RescueRecipientNotStrategy.selector, to));
        vault.rescueERC20(address(tsla), to, 500e18);
    }

    // ── tests ──

    /// @notice The owner and an arbitrary address cannot receive a rescued non-asset token.
    function test_rescueToOwnerOrArbitraryAddressReverts() public {
        _basketRescuedIntoVault();
        _expectRescueRefused(owner);
        _expectRescueRefused(makeAddr("anyone"));
        assertEq(tsla.balanceOf(address(vault)), 500e18);
    }

    /// @notice A hand-registered strategy bound to this vault passes `isRegisteredStrategy` but is refused.
    function test_rescueToHandRegisteredStrategyReverts() public {
        _basketRescuedIntoVault();
        PortfolioStrategy hand = PortfolioStrategy(Clones.clone(address(template)));
        hand.initialize(address(vault), agent, _initData());
        sf.registerStrategy(address(hand));
        assertTrue(sf.isRegisteredStrategy(address(hand)), "registered");
        assertEq(hand.vault(), address(vault), "bound here");
        _expectRescueRefused(address(hand));
    }

    /// @notice A template clone bound to another vault is refused.
    function test_rescueToCloneOfAnotherVaultReverts() public {
        _basketRescuedIntoVault();
        address other = _factoryClone(address(new OtherVaultStub(address(governor), address(usdc))));
        assertTrue(sf.cloneTemplate(other) != address(0), "factory clone");
        _expectRescueRefused(other);
    }

    /// @notice With the strategy factory unwired, even this vault's own clone is refused.
    function test_rescueWithUnwiredFactoryReverts() public {
        address clone = _basketRescuedIntoVault();
        vm.mockCall(address(governor), abi.encodeWithSignature("tierRegistry()"), abi.encode(address(0)));
        _expectRescueRefused(clone);
    }

    /// @notice Rescue to this vault's template clone succeeds, and a later proposal settling that clone returns the value.
    function test_rescueToOwnCloneThenLaterSettleReturnsValue() public {
        address clone = _basketRescuedIntoVault();
        vm.prank(owner);
        vault.rescueERC20(address(tsla), clone, 500e18);
        assertEq(tsla.balanceOf(clone), 500e18);

        vm.warp(vm.getBlockTimestamp() + 1 days + 1); // cooldown
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        vm.prank(agent);
        uint256 pid2 = governor.propose(
            address(vault),
            clone,
            "ipfs://fp04-recover",
            1 hours,
            env,
            _one(_call(clone, abi.encodeCall(BaseStrategy.settle, ()))),
            new uint256[](1),
            _one(_call(clone, abi.encodeCall(BaseStrategy.rescueTo, (address(usdc))))),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        _vote(pid2);
        governor.executeProposal(pid2);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        governor.settleProposal(pid2);
        assertEq(tsla.balanceOf(clone), 0);
        assertEq(vault.totalAssets(), 100_000e6, "value back in the vault");
    }
}
