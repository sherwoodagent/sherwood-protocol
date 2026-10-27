// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {GovernorBeacon} from "../../src/GovernorBeacon.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice Hand-registered strategy that pulls `amount` at execute and returns it all at settle.
contract ClaimGateStrategy {
    address public immutable vault;
    address public immutable proposer;
    IERC20 public immutable asset;
    bool public executed;

    constructor(address vault_, address proposer_, address asset_) {
        vault = vault_;
        proposer = proposer_;
        asset = IERC20(asset_);
    }

    function execute(uint256 amount) external {
        require(msg.sender == vault, "vault");
        asset.transferFrom(vault, address(this), amount);
        executed = true;
    }

    function settle() external {
        require(msg.sender == vault, "vault");
        asset.transfer(vault, asset.balanceOf(address(this)));
        executed = false;
    }
}

/// @notice FP-17 (audit 2026-10-02, N-16 i): a queued-deposit claim honours pause and the depositor whitelist.
contract Vault_queuedDepositClaimGateTest is Test {
    SyndicateFactory public factory;
    GuardianRegistry public registry;
    StakedWood public swood;
    StrategyFactory public strategyFactory;
    ProtocolConfig public pc;
    ERC20Mock public usdc;
    ERC20Mock public wood;
    MockAgentRegistry public agentRegistry;

    SyndicateVault public vault;
    SyndicateGovernor public gov;
    IVaultWithdrawalQueue public queue;
    ClaimGateStrategy public strategy;

    address public owner = makeAddr("protocolSafe");
    address public creator = makeAddr("vaultOwner");
    address public lp1 = makeAddr("lp1");
    address public lpX = makeAddr("lpX");
    address public lpY = makeAddr("lpY");
    address public lpZ = makeAddr("lpZ");
    address public keeper = makeAddr("keeper");

    uint256 constant MIN_OWNER_STAKE = 10_000e18;
    uint256 constant REVIEW_PERIOD = 24 hours;
    uint256 constant STRATEGY_DURATION = 7 days;
    uint256 constant DEPLOYED = 60_000e6;
    uint256 constant QUEUED = 10_000e6;

    uint256 reqX;
    uint256 reqY;
    uint256 reqZ;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        wood = new ERC20Mock("WOOD", "WOOD", 18);
        agentRegistry = new MockAgentRegistry();
        uint256 creatorAgentId = agentRegistry.mint(creator);

        address executorLib = address(new BatchExecutorLib());
        address vaultImpl = address(new SyndicateVault());
        pc = new ProtocolConfig(owner);
        TierRegistry tierRegistry = new TierRegistry(owner);
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
                    minGuardianStake: 10_000e18,
                    coolDownPeriod: 7 days,
                    minOwnerStake: MIN_OWNER_STAKE,
                    minSlashBps: 1000,
                    maxSlashBps: 9999,
                    ageFloorBps: 2500,
                    maturationPeriod: 30 days
                }))
        );
        swood = StakedWood(address(new ERC1967Proxy(address(swoodImpl), swoodInit)));
        GovernorBeacon beacon = new GovernorBeacon(address(new SyndicateGovernor(24 hours, 1 hours)), owner);
        SyndicateFactory factoryImpl = new SyndicateFactory();
        GuardianRegistry regImpl = new GuardianRegistry(6 hours);
        bytes memory regInit = abi.encodeCall(
            GuardianRegistry.initialize, (owner, predictedFactoryProxy, address(swood), REVIEW_PERIOD, 3000)
        );
        registry = GuardianRegistry(address(new ERC1967Proxy(address(regImpl), regInit)));
        require(address(registry) == predictedRegistryProxy, "registry address prediction mismatch");
        vm.prank(owner);
        swood.setRegistry(address(registry));

        bytes memory factoryInit = abi.encodeCall(
            SyndicateFactory.initialize,
            (SyndicateFactory.InitParams({
                    owner: owner,
                    executorImpl: executorLib,
                    vaultImpl: vaultImpl,
                    agentRegistry: address(agentRegistry),
                    beacon: address(beacon),
                    protocolConfig: address(pc),
                    managementFeeBps: 0,
                    guardianRegistry: address(registry),
                    tierRegistry: address(tierRegistry)
                }))
        );
        factory = SyndicateFactory(address(new ERC1967Proxy(address(factoryImpl), factoryInit)));
        require(address(factory) == predictedFactoryProxy, "factory address prediction mismatch");
        strategyFactory = new StrategyFactory(address(factory), owner);
        vm.prank(owner);
        tierRegistry.setStrategyFactory(address(strategyFactory));

        wood.mint(creator, 100_000e18);
        vm.startPrank(creator);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        (, address v) = factory.createSyndicate(
            creatorAgentId,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://fp17",
                asset: usdc,
                name: "FP17 Vault",
                symbol: "fp17V",
                openDeposits: true,
                subdomain: "fp17-fund"
            })
        );
        vault = SyndicateVault(payable(v));
        vault.registerAgent(creatorAgentId, creator);
        vm.stopPrank();
        gov = SyndicateGovernor(factory.governorOf(v));
        queue = IVaultWithdrawalQueue(vault.withdrawalQueue());

        usdc.mint(lp1, 100_000e6);
        vm.startPrank(lp1);
        usdc.approve(v, type(uint256).max);
        vault.deposit(100_000e6, lp1);
        vm.stopPrank();

        // Launch posture: invite-only deposits.
        vm.startPrank(owner);
        factory.setDepositsRestricted(true);
        factory.setOwnerOnlyProposals(true);
        vm.stopPrank();
        skip(1 days);

        strategy = new ClaimGateStrategy(v, creator, address(usdc));
        strategyFactory.registerStrategy(address(strategy));

        // Three whitelisted LPs queue a deposit each while a proposal is live, then it settles.
        uint256 pid = _proposeDeploy();
        skip(24 hours + 1);
        registry.openReview(address(gov), pid);
        skip(REVIEW_PERIOD + 1);
        gov.executeProposal(pid);
        reqX = _queueDeposit(lpX);
        reqY = _queueDeposit(lpY);
        reqZ = _queueDeposit(lpZ);
        skip(STRATEGY_DURATION + 1);
        vm.prank(keeper);
        gov.settleProposal(pid);
        assertFalse(vault.depositsLocked(), "claims open");
    }

    function _proposeDeploy() internal returns (uint256 pid) {
        BatchExecutorLib.Call[] memory ex = new BatchExecutorLib.Call[](2);
        ex[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(strategy), DEPLOYED)), value: 0
        });
        ex[1] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(ClaimGateStrategy.execute, (DEPLOYED)), value: 0
        });
        uint256[] memory exCaps = new uint256[](2);
        exCaps[1] = DEPLOYED;
        BatchExecutorLib.Call[] memory st = new BatchExecutorLib.Call[](1);
        st[0] = BatchExecutorLib.Call({
            target: address(strategy), data: abi.encodeCall(ClaimGateStrategy.settle, ()), value: 0
        });
        uint256 cap = vault.totalAssets();
        vm.prank(creator);
        pid = gov.propose(
            address(vault),
            address(strategy),
            "ipfs://fp17",
            STRATEGY_DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: cap, maxDrawdownBps: 10_000}),
            ex,
            exCaps,
            st,
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _queueDeposit(address lp) internal returns (uint256 req) {
        vm.prank(creator);
        vault.approveDepositor(lp);
        usdc.mint(lp, QUEUED);
        vm.startPrank(lp);
        usdc.approve(address(vault), QUEUED);
        req = vault.requestDeposit(QUEUED, lp);
        vm.stopPrank();
    }

    /// @notice A claim for a receiver removed from the whitelist reverts; the receiver cancels and gets the assets back.
    function test_claimForRemovedDepositorReverts_cancelRefunds() public {
        vm.prank(creator);
        vault.removeDepositor(lpX);
        vm.prank(keeper);
        vm.expectRevert(ISyndicateVault.NotApprovedDepositor.selector);
        queue.claim(reqX);

        vm.prank(lpX);
        queue.cancel(reqX);
        assertEq(usdc.balanceOf(lpX), QUEUED, "assets refunded");
        assertEq(vault.balanceOf(lpX), 0, "no shares minted");
    }

    /// @notice A claim while the vault is paused reverts; cancel still refunds while paused.
    function test_claimWhilePausedReverts_cancelRefunds() public {
        vm.prank(creator);
        vault.pause();
        vm.prank(keeper);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        queue.claim(reqY);

        vm.prank(lpY);
        queue.cancel(reqY);
        assertEq(usdc.balanceOf(lpY), QUEUED, "assets refunded while paused");
        assertEq(vault.balanceOf(lpY), 0, "no shares minted");
    }

    /// @notice Control: an approved receiver's claim on an unpaused vault still mints, including after an unpause.
    function test_control_normalClaimMints() public {
        vm.startPrank(creator);
        vault.pause();
        vault.unpause();
        vm.stopPrank();
        vm.prank(keeper);
        uint256 shares = queue.claim(reqZ);
        assertGt(shares, 0);
        assertEq(vault.balanceOf(lpZ), shares, "minted to the receiver");
    }
}
