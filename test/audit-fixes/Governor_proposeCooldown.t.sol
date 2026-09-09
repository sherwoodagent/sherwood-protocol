// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_proposeCooldown
/// @notice Redemptions lock from propose and `cancelProposal` is proposer-anytime in the vote
///         window, so `propose` honours the settle cooldown that every cancel stamps: an LP
///         gets one cooldown of open exit per cancel cycle.
contract GovernorProposeCooldownTest is Test {
    uint256 constant COOLDOWN = 1 days;

    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    ERC20Mock usdc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp = makeAddr("lp");

    function setUp() public {
        ProtocolConfig cfg = new ProtocolConfig(owner);
        vm.prank(owner);
        cfg.setProtocolFeeRecipient(owner);
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        MockAgentRegistry reg = new MockAgentRegistry();
        uint256 nft = reg.mint(agent);
        ISyndicateVault.InitParams memory ip = ISyndicateVault.InitParams(
            address(usdc), "Sherwood Vault", "swUSDC", owner, address(new BatchExecutorLib()), true, address(reg), 0
        );
        bytes memory vInit = abi.encodeCall(SyndicateVault.initialize, (ip));
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(new SyndicateVault()), vInit))));
        vm.prank(owner);
        vault.registerAgent(nft, agent);
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        ISyndicateGovernor.GovernorParams memory gp =
            ISyndicateGovernor.GovernorParams(1 days, 1 days, 4000, 1500, COOLDOWN, 48 hours, 5, 1 hours, 30 days);
        address tiers = address(deployTierRegistry(address(this)));
        bytes memory gInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(new MockRegistryMinimal()), address(cfg), address(this), tiers, gp)
        );
        governor =
            SyndicateGovernor(address(new ERC1967Proxy(address(new SyndicateGovernor(24 hours, 1 hours)), gInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));

        usdc.mint(lp, 100_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), 100_000e6);
        vault.deposit(100_000e6, lp);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _calls(uint256 allowance) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call(address(usdc), abi.encodeCall(usdc.approve, (address(1), allowance)), 0);
    }

    /// @dev No warp after: the caller decides the block the next call lands in.
    function _propose() internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory none;
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "cooldown",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            none
        );
    }

    function _cancel(uint256 pid) internal {
        vm.prank(agent);
        governor.cancelProposal(pid);
    }

    function _proposeRevertsCooldown() internal {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory none;
        vm.prank(agent);
        vm.expectRevert(ISyndicateGovernor.CooldownNotElapsed.selector);
        governor.propose(
            address(vault),
            address(0),
            "cooldown",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            none
        );
    }

    /// @notice The first proposal is not gated: no deadline has been stamped yet.
    function test_firstProposalIgnoresTheZeroSettleClock() public {
        assertLt(vm.getBlockTimestamp(), COOLDOWN, "fixture must sit inside a would-be cooldown from t=0");
        assertEq(governor.getCooldownEnd(), 0, "deadline unstamped");
        assertEq(_propose(), 1);
    }

    /// @notice The deadline is stamped at the terminal event with the period in force then, so the
    ///         owner cannot shorten an exit window the LPs are already inside.
    function test_ownerCannotShrinkAnOpenExitWindowFromInsideIt() public {
        uint256 pid = _propose();
        _cancel(pid);
        uint256 t = vm.getBlockTimestamp();
        assertEq(governor.getCooldownEnd(), t + COOLDOWN, "deadline stamped at cancel");

        vm.warp(t + 10 minutes);
        vm.prank(owner);
        governor.setCooldownPeriod(1 hours);
        assertEq(governor.getCooldownEnd(), t + COOLDOWN, "the running deadline moved");

        vm.warp(t + 1 hours);
        _proposeRevertsCooldown();
        assertGt(vault.maxRedeem(lp), 0, "exit closed early");

        vm.warp(t + COOLDOWN);
        assertEq(_propose(), pid + 1);
    }

    /// @notice A new period applies from the next terminal event onward.
    function test_newCooldownAppliesFromTheNextTerminalEvent() public {
        uint256 pid = _propose();
        _cancel(pid);
        vm.prank(owner);
        governor.setCooldownPeriod(1 hours);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);

        pid = _propose();
        _cancel(pid);
        assertEq(governor.getCooldownEnd(), vm.getBlockTimestamp() + 1 hours, "new period not applied");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        assertEq(_propose(), pid + 1);
    }

    function test_cancelThenProposeWithinCooldownReverts() public {
        uint256 pid = _propose();
        _cancel(pid);
        assertGt(vault.maxRedeem(lp), 0, "cancel reopens exit");

        vm.warp(vm.getBlockTimestamp() + COOLDOWN - 1);
        _proposeRevertsCooldown();
        assertGt(vault.maxRedeem(lp), 0, "exit stays open");
    }

    function test_cancelThenProposeAfterCooldownSucceeds() public {
        uint256 pid = _propose();
        _cancel(pid);
        vm.warp(vm.getBlockTimestamp() + COOLDOWN);
        assertEq(_propose(), pid + 1);
        assertEq(vault.maxRedeem(lp), 0, "locked again by the new proposal");
    }

    function test_lpGetsOneCooldownOfOpenExitPerCancelCycle() public {
        for (uint256 cycle; cycle < 5; ++cycle) {
            uint256 pid = _propose();
            assertEq(vault.maxRedeem(lp), 0, "locked while open");
            _cancel(pid);
            _proposeRevertsCooldown(); // the same-block re-propose is what denied exit before
            vm.warp(vm.getBlockTimestamp() + COOLDOWN);

            uint256 open = vault.maxRedeem(lp);
            assertGt(open, 0, "exit open after the cooldown");
            uint256 before = usdc.balanceOf(lp);
            vm.prank(lp);
            vault.redeem(1e6, lp, lp);
            assertGt(usdc.balanceOf(lp), before, "redeem paid out");
        }
    }
}
