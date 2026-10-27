// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "../../src/interfaces/IStakedWood.sol";
import {RobinhoodParams} from "../../script/robinhood-mainnet/RobinhoodParams.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @notice FP-13 (audit 2026-10-02, N-15 i): a lowered protocol duration ceiling binds every vault at propose.
contract Governor_protocolDurationCeilingAtProposeTest is Test {
    SyndicateFactory factory;
    ProtocolConfig cfg;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address safe = makeAddr("safe");
    address lp = makeAddr("lp");
    address guardianRegistry = makeAddr("guardianRegistry");
    address swood = makeAddr("swood");
    uint256 nonce;

    function setUp() public {
        usdc = new ERC20Mock("USD Global", "USDG", 6);
        agentRegistry = new MockAgentRegistry();
        GovernorBeacon beacon = new GovernorBeacon(
            address(new SyndicateGovernor(RobinhoodParams.MIN_VOTING_PERIOD, RobinhoodParams.MIN_COOLDOWN_PERIOD)), safe
        );
        cfg = new ProtocolConfig(safe);
        bytes memory init = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: safe,
                    executorImpl: address(new BatchExecutorLib()),
                    vaultImpl: address(new SyndicateVault()),
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(cfg),
                    managementFeeBps: RobinhoodParams.MANAGEMENT_FEE_BPS,
                    guardianRegistry: guardianRegistry,
                    tierRegistry: address(deployTierRegistry(safe))
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(new SyndicateFactory()), init)));

        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.addGovernor.selector), "");
        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.swood.selector), abi.encode(swood));
        vm.mockCall(
            guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.ownerBondLive.selector), abi.encode(true)
        );
        vm.mockCall(guardianRegistry, abi.encodeWithSelector(IGuardianRegistry.reviewPeriod.selector), abi.encode(0));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.canCreateVault.selector), abi.encode(true));
        vm.mockCall(swood, abi.encodeWithSelector(IStakedWood.bindOwnerStake.selector), "");

        vm.startPrank(safe);
        cfg.setMaxStrategyDuration(RobinhoodParams.MAX_STRATEGY_DURATION);
        factory.setOwnerOnlyProposals(true);
        vm.stopPrank();
    }

    function _create(address owner) internal returns (SyndicateVault vault, SyndicateGovernor gov) {
        nonce++;
        uint256 creatorId = agentRegistry.mint(owner);
        string memory sub = string(abi.encodePacked("fp13-", vm.toString(nonce)));
        vm.prank(owner);
        (, address v) = factory.createSyndicate(
            creatorId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://fp13",
                asset: usdc,
                name: "FP13",
                symbol: "fp13",
                openDeposits: true,
                subdomain: sub
            })
        );
        vault = SyndicateVault(payable(v));
        gov = SyndicateGovernor(factory.governorOf(v));
        uint256 agentId = agentRegistry.mint(owner);
        vm.prank(owner);
        vault.registerAgent(agentId, owner);
        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(v, 100_000e6);
        vault.deposit(100_000e6, lp);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function proposeExt(address owner, SyndicateVault vault, SyndicateGovernor gov, uint256 duration)
        external
        returns (uint256)
    {
        ISyndicateGovernor.RiskEnvelope memory env = ISyndicateGovernor.RiskEnvelope(1e6, 10_000);
        BatchExecutorLib.Call[] memory exec = new BatchExecutorLib.Call[](1);
        exec[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(1), 1e6)), value: 0
        });
        BatchExecutorLib.Call[] memory settle = new BatchExecutorLib.Call[](1);
        settle[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(1), 0)), value: 0
        });
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1e6;
        ISyndicateGovernor.CoProposer[] memory none = new ISyndicateGovernor.CoProposer[](0);
        vm.prank(owner);
        return gov.propose(address(vault), address(0), "ipfs://p", duration, env, exec, caps, settle, caps, none);
    }

    /// @notice After the ceiling drops to 7d, an existing and a newly created vault both refuse 20d and accept 7d.
    function test_loweredCeilingBindsExistingAndNewVaultAtPropose() public {
        address ownerA = makeAddr("ownerA");
        address ownerB = makeAddr("ownerB");
        (SyndicateVault vA, SyndicateGovernor gA) = _create(ownerA);

        vm.prank(safe);
        cfg.setMaxStrategyDuration(7 days);
        (SyndicateVault vB, SyndicateGovernor gB) = _create(ownerB);
        assertEq(gA.getGovernorParams().maxStrategyDuration, 30 days, "A keeps its stored 30d");
        assertEq(gB.getGovernorParams().maxStrategyDuration, 30 days, "B is seeded 30d");

        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooLong.selector);
        this.proposeExt(ownerA, vA, gA, 20 days);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooLong.selector);
        this.proposeExt(ownerB, vB, gB, 20 days);

        uint256 idA = this.proposeExt(ownerA, vA, gA, 7 days);
        uint256 idB = this.proposeExt(ownerB, vB, gB, 7 days);
        assertEq(gA.getProposal(idA).strategyDuration, 7 days);
        assertEq(gB.getProposal(idB).strategyDuration, 7 days);
    }

    /// @notice A vault's own lower maximum still binds under a higher ceiling.
    function test_control_vaultMaxBindsUnderHigherCeiling() public {
        address ownerA = makeAddr("ownerA");
        (SyndicateVault vA, SyndicateGovernor gA) = _create(ownerA);
        vm.prank(ownerA);
        gA.setMaxStrategyDuration(5 days);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooLong.selector);
        this.proposeExt(ownerA, vA, gA, 6 days);
        this.proposeExt(ownerA, vA, gA, 5 days);
    }

    /// @notice With the ceiling unset (0), the vault's own 30d bound applies exactly as before.
    function test_control_unsetCeilingProposesAsToday() public {
        address ownerA = makeAddr("ownerA");
        (SyndicateVault vA, SyndicateGovernor gA) = _create(ownerA);
        vm.prank(safe);
        cfg.setMaxStrategyDuration(0);
        vm.expectRevert(ISyndicateGovernor.StrategyDurationTooLong.selector);
        this.proposeExt(ownerA, vA, gA, 30 days + 1);
        uint256 id = this.proposeExt(ownerA, vA, gA, 30 days);
        assertEq(gA.getProposal(id).strategyDuration, 30 days);
    }
}
