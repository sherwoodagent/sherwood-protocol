// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

/// @title Governor_vetoDenominatorExits
/// @notice SHE-205 / SHE-258: while a proposal is open no share is minted or burned, so the
///         veto bar is measured against a supply nothing can shrink. The only exit is a
///         queued redeem, cancellable until its proposal is stamped at settle.
contract GovernorVetoDenominatorExitsTest is Test {
    SyndicateGovernor governor;
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    ERC20Mock usdc;
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address attacker = makeAddr("attacker");

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
            ISyndicateGovernor.GovernorParams(1 days, 1 days, 4000, 1500, 1 days, 48 hours, 5, 1 hours, 30 days);
        address tiers = address(deployTierRegistry(address(this)));
        bytes memory gInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (address(vault), address(new MockRegistryMinimal()), address(cfg), address(this), tiers, gp)
        );
        governor =
            SyndicateGovernor(address(new ERC1967Proxy(address(new SyndicateGovernor(24 hours, 1 hours)), gInit)));
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(0)));
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, who);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1); // snapshot is `timestamp - 1`
    }

    function _calls(uint256 allowance) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call(address(usdc), abi.encodeCall(usdc.approve, (address(1), allowance)), 0);
    }

    function _propose() internal returns (uint256 pid) {
        ISyndicateGovernor.RiskEnvelope memory env = GovEnvelope.permissive(address(vault));
        ISyndicateGovernor.CoProposer[] memory none;
        vm.prank(agent);
        pid = governor.propose(
            address(vault),
            address(0),
            "she258",
            7 days,
            env,
            _calls(1),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            _calls(0),
            GovEnvelope.defaultCaps(env.maxCapital, 1),
            none
        );
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _endVote() internal {
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
    }

    function _settle(uint256 pid) internal {
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
    }

    function _instantExitReverts(address who) internal {
        assertEq(vault.maxRedeem(who), 0);
        assertEq(vault.maxWithdraw(who), 0);
        vm.prank(who);
        vm.expectPartialRevert(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector);
        vault.redeem(1, who, who);
    }

    /// @notice Instant redeem/withdraw revert from propose until settle; ERC20 transfer still works.
    function test_sharesCannotLeaveTheVaultWhileAProposalIsOpen() public {
        _deposit(lp1, 60_000e6);
        _deposit(lp2, 40_000e6);
        uint256 supply = vault.totalSupply();
        uint256 pid = _propose();
        assertTrue(vault.redemptionsLocked(), "locked at Pending");
        _instantExitReverts(lp1);
        _endVote();
        _instantExitReverts(lp1); // Approved, not yet executed
        governor.executeProposal(pid);
        _instantExitReverts(lp1);
        uint256 half = vault.balanceOf(lp1) / 2;
        uint256 lp2Before = vault.balanceOf(lp2);
        vm.prank(lp1);
        vault.transfer(lp2, half);
        assertEq(vault.balanceOf(lp2), lp2Before + half, "shares still move between holders");
        assertEq(vault.totalSupply(), supply, "supply unchanged from propose to settle");
        _settle(pid);
        assertFalse(vault.redemptionsLocked(), "unlocked at settle");
        vm.prank(lp1);
        vault.redeem(half, lp1, lp1);
        assertLt(vault.totalSupply(), supply, "instant exit reopened after settle");
    }

    /// @notice A queued redeem is the only exit while a proposal is open; it can be cancelled until stamped.
    function test_queuedRedeemIsTheOnlyExitDuringAProposalAndIsCancellableUntilStamped() public {
        _deposit(lp1, 60_000e6);
        uint256 shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        vm.expectRevert(ISyndicateVault.RedemptionsNotLocked.selector);
        vault.requestRedeem(shares, lp1); // no proposal open: instant path only
        uint256 pid = _propose();
        vm.startPrank(lp1);
        uint256 first = vault.requestRedeem(shares / 2, lp1);
        uint256 second = vault.requestRedeem(shares / 2, lp1);
        assertEq(queue.getRequest(first).pid, pid, "tagged with the open (not yet executing) proposal");
        assertEq(vault.totalSupply(), shares, "queued shares stay in supply");
        queue.cancel(first);
        assertEq(vault.balanceOf(lp1), shares / 2, "cancel returns the escrowed shares before the stamp");
        vm.stopPrank();
        _endVote();
        governor.executeProposal(pid);
        _settle(pid);
        vm.prank(lp1);
        vm.expectRevert(IVaultWithdrawalQueue.AlreadySettled.selector);
        queue.cancel(second);
        vm.prank(lp1);
        queue.claim(second);
        assertEq(vault.totalSupply(), shares / 2, "the claim burns the queued shares at the settle price");
    }

    /// @notice The veto denominator at resolve is the supply snapshot at propose; nothing the attacker
    ///         does between propose and settle moves it. 80k Against on a 200k snapshot sits exactly on
    ///         the 40% bar; one unit fewer clears it.
    function test_vetoBarEqualsTheSnapshotSupplyBecauseNoShareCanLeave() public {
        assertEq(uint256(_resolveWithAgainst(80_000e6)), uint256(ISyndicateGovernor.ProposalState.Rejected));
        setUp(); // fresh instance for the other side of the bar
        assertEq(uint256(_resolveWithAgainst(80_000e6 - 1)), uint256(ISyndicateGovernor.ProposalState.Approved));
    }

    function _resolveWithAgainst(uint256 againstAssets) internal returns (ISyndicateGovernor.ProposalState) {
        _deposit(lp1, againstAssets);
        _deposit(lp2, 120_000e6 - againstAssets);
        _deposit(attacker, 80_000e6);
        uint256 pid = _propose();
        uint256 snapshot = vault.getPastTotalSupply(governor.getProposal(pid).snapshotTimestamp);
        _instantExitReverts(attacker);
        vm.startPrank(attacker);
        vault.requestRedeem(vault.balanceOf(attacker) / 2, attacker);
        vault.transfer(lp2, vault.balanceOf(attacker));
        vm.stopPrank();
        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.Against);
        _endVote();
        assertEq(vault.totalSupply(), snapshot, "denominator at resolve == snapshot at propose");
        return governor.getProposalState(pid);
    }
}
