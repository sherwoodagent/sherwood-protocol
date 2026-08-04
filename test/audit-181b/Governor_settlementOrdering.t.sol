// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

/// @title Governor_settlementOrdering — audit issue #181 finding #24 regression
/// @notice `_finishSettlement` used to release the vault's locks
///         (`_activeProposal = 0` / `_decOpen()`) at the TOP of the function,
///         before the fee transfers and the `onProposalSettled` price stamp
///         that follow. For the whole span between "locks cleared" and "stamp
///         landed", `redemptionsLocked()` / `_depositsLocked()` on the vault
///         both read false and the settle price was not yet frozen, even
///         though the performance fee transfer that triggered a recipient's
///         callback was still in flight.
///
///         This regression proves the reordering closes that window: a
///         callback-bearing fee asset (an ERC-777-style hook fires
///         synchronously out of `transfer`) lets the fee recipient (here, the
///         proposer, paid via `_distributeAgentFee`) attempt an instant
///         `redeem()` from INSIDE the fee transfer that is still part of
///         `_finishSettlement`. Against the pre-fix ordering the redeem would
///         succeed (the locks were already down); against the fix it must
///         fail, because `_activeProposal` / `_openProposalCount` are only
///         cleared after every external call in `_finishSettlement` has run.
///
///         V1 ships plain USDC (no hook), so this is not exploitable today —
///         but `SyndicateFactory.createSyndicate` places no constraint on
///         `config.asset`, so the ordering must be correct independent of
///         which asset a future syndicate onboards.
contract Governor_settlementOrdering_Test is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    HookedAsset public hookedAsset;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    MaliciousFeeRecipient public attacker;

    address public owner = makeAddr("owner");
    address public lp1 = makeAddr("lp1");
    address public lp2 = makeAddr("lp2");

    uint256 public attackerAgentId;

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant VETO_THRESHOLD_BPS = 4000;
    uint256 constant MAX_PERF_FEE_BPS = 1500;
    uint256 constant COOLDOWN_PERIOD = 1 days;
    uint256 constant MAX_STRATEGY_DURATION = 30 days;
    uint256 constant MIN_SELF_SETTLE = 1 hours;
    uint256 constant STRATEGY_DURATION = 7 days;

    uint256 constant LP1_DEPOSIT = 60_000e6;
    uint256 constant LP2_DEPOSIT = 40_000e6;
    uint256 constant ATTACKER_DEPOSIT = 10_000e6;
    // Minted straight to the vault float after execute to simulate a
    // profitable strategy (pricePerShare rises above the high-water mark)
    // without needing a real strategy adapter.
    uint256 constant PROFIT = 5_000e6;

    function setUp() public {
        hookedAsset = new HookedAsset("Hooked Stable", "hUSD", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (
                ISyndicateVault.InitParams({
                    asset: address(hookedAsset),
                    name: "Sherwood Vault",
                    symbol: "swHUSD",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                })
            )
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this), // factory (test contract)
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: VETO_THRESHOLD_BPS,
                    maxPerformanceFeeBps: MAX_PERF_FEE_BPS,
                    cooldownPeriod: COOLDOWN_PERIOD,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: MAX_STRATEGY_DURATION
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));
        // Per-vault governor: the vault resolves its governor via its factory
        // (this test contract). Mock governorOf(vault) -> the deployed governor.
        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        // The proposer/agent is a CONTRACT that implements the hooked asset's
        // post-transfer callback, so it can attempt to re-enter the vault
        // from inside its own performance-fee payout.
        attacker = new MaliciousFeeRecipient(address(vault), address(governor));
        attackerAgentId = agentRegistry.mint(address(attacker));
        vm.prank(owner);
        vault.registerAgent(attackerAgentId, address(attacker));

        hookedAsset.mint(lp1, LP1_DEPOSIT);
        hookedAsset.mint(lp2, LP2_DEPOSIT);
        hookedAsset.mint(address(attacker), ATTACKER_DEPOSIT);

        vm.startPrank(lp1);
        hookedAsset.approve(address(vault), LP1_DEPOSIT);
        vault.deposit(LP1_DEPOSIT, lp1);
        vm.stopPrank();

        vm.startPrank(lp2);
        hookedAsset.approve(address(vault), LP2_DEPOSIT);
        vault.deposit(LP2_DEPOSIT, lp2);
        vm.stopPrank();

        // The attacker is also an LP so it holds redeemable shares to attempt
        // the instant exit with, once it collects its performance fee.
        vm.startPrank(address(attacker));
        hookedAsset.approve(address(vault), ATTACKER_DEPOSIT);
        vault.deposit(ATTACKER_DEPOSIT, address(attacker));
        vm.stopPrank();

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    /// @dev Inert calls (empty calldata to an address with no code) — this
    ///      test only needs a proposal to reach Executed/Settled, not an
    ///      actual capital deployment.
    function _inertCalls() internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: address(0xdead), data: "", value: 0});
    }

    /// @notice Regression for audit issue #181 finding #24: `_finishSettlement`
    ///         must not release `_activeProposal` / `_openProposalCount`
    ///         until every external call it makes (fee transfers, the
    ///         `onProposalSettled` price stamp) has completed.
    ///
    ///         Against the PRE-FIX ordering (locks cleared at the top of
    ///         `_finishSettlement`), the assertions below fail: the callback
    ///         observes `getActiveProposal() == 0` / `redemptionsLocked() ==
    ///         false` mid-fee-transfer, and the attacker's reentrant `redeem`
    ///         SUCCEEDS (draining shares at the pre-fee, pre-stamp NAV, on
    ///         top of collecting the fee itself).
    ///
    ///         Against the FIX, the callback observes the proposal still
    ///         active/locked, and the reentrant `redeem` reverts (`maxRedeem`
    ///         floors at 0 while locked). That revert is caught locally by
    ///         the hook itself (see `MaliciousFeeRecipient.onTokensReceived`)
    ///         rather than left to bubble out of `transferPerformanceFee` --
    ///         a revert propagating that far would unwind the hook's own
    ///         observations along with it. So the fee transfer completes
    ///         normally (delivered, not escrowed) and settlement finishes,
    ///         but the exploit attempt is neutralized.
    function test_feeRecipientCallback_cannotExitWhileLocksStillDown() public {
        uint256 pid;
        {
            uint256 attackerShares = vault.balanceOf(address(attacker));
            attacker.setSharesToRedeem(attackerShares);

            vm.prank(address(attacker));
            pid = governor.propose(
                address(vault),
                address(0), // queue-only proposal, no strategy adapter needed
                "ipfs://settlement-ordering",
                STRATEGY_DURATION,
                GovEnvelope.permissive(address(vault)),
                _inertCalls(),
                GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_inertCalls()).length),
                _inertCalls(),
                GovEnvelope.defaultCaps((GovEnvelope.permissive(address(vault))).maxCapital, (_inertCalls()).length),
                _emptyCoProposers()
            );
            vm.warp(vm.getBlockTimestamp() + 1);
        }

        vm.prank(lp1);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);

        governor.executeProposal(pid);

        // Simulate a profitable strategy: pricePerShare rises above the
        // high-water mark, so settlement charges a nonzero performance fee
        // and the proposer's slice flows through `_payFee` ->
        // `transferPerformanceFee` -> the hooked asset's callback.
        hookedAsset.mint(address(vault), PROFIT);

        vm.warp(vm.getBlockTimestamp() + MIN_SELF_SETTLE);

        // Arm the hook only now: earlier setup transfers (mints, LP
        // deposits) must not trigger it, only the settlement fee payout.
        hookedAsset.arm(address(attacker));

        uint256 attackerSharesBeforeSettle = vault.balanceOf(address(attacker));
        uint256 attackerAssetBeforeSettle = hookedAsset.balanceOf(address(attacker));

        vm.prank(address(attacker));
        governor.settleProposal(pid);

        // The callback must actually have fired — otherwise this test proves
        // nothing about the ordering.
        assertTrue(attacker.hookFired(), "fee callback never fired; test setup is broken");

        // The direct proof of finding #24: captured INSIDE the callback,
        // before the reentrant redeem attempt below.
        assertEq(
            attacker.capturedActiveProposal(),
            pid,
            "finding #24: _activeProposal was cleared before the fee transfer completed"
        );
        assertEq(
            attacker.capturedOpenProposalCount(),
            1,
            "finding #24: _openProposalCount was decremented before the fee transfer completed"
        );
        assertTrue(
            attacker.capturedRedemptionsLocked(), "finding #24: redemptionsLocked() read false mid fee-distribution"
        );

        // The economic consequence.
        assertFalse(
            attacker.redeemSucceeded(),
            "finding #24: attacker redeemed at a pre-fee, pre-stamp NAV from inside settlement"
        );
        assertEq(
            vault.balanceOf(address(attacker)),
            attackerSharesBeforeSettle,
            "attacker shares must be untouched: the reentrant redeem must have reverted, not partially executed"
        );
        // Unlike a bare revert propagating out of transferPerformanceFee, the
        // hook catches the reentrant redeem's failure locally (see
        // MaliciousFeeRecipient.onTokensReceived), so the fee transfer itself
        // completes normally: it is delivered to the attacker, not escrowed.
        assertEq(
            governor.unclaimedFees(address(vault), address(attacker), address(hookedAsset)),
            0,
            "the fee transfer must not itself revert: only the nested reentrant redeem should fail"
        );
        assertGt(
            hookedAsset.balanceOf(address(attacker)) - attackerAssetBeforeSettle,
            0,
            "the performance fee must still be delivered to the recipient despite the blocked reentrancy attempt"
        );

        // Settlement itself must still complete despite the neutralized
        // reentry attempt (the revert is caught, not propagated).
        assertEq(
            uint256(governor.getProposal(pid).state),
            uint256(ISyndicateGovernor.ProposalState.Settled),
            "settlement must complete even though the reentrant call inside it reverted"
        );

        // And the locks must be fully released once settlement is actually
        // done — the fix only delays release, it does not skip it.
        assertEq(governor.getActiveProposal(), 0, "locks must be released once _finishSettlement fully returns");
        assertEq(
            governor.openProposalCount(), 0, "openProposalCount must be released once _finishSettlement fully returns"
        );
    }
}

/// @notice Minimal ERC-777-style callback asset: fires a synchronous
///         `onTokensReceived` hook on the armed recipient at the end of every
///         `_update` (covers `transfer`/`transferFrom`/`mint`), modelling the
///         "callback-bearing vault asset" finding #24 is about. Disarmed
///         (`address(0)`) by default so incidental setup transfers never
///         trigger it — tests arm it explicitly right before the transfer
///         under test.
contract HookedAsset is ERC20 {
    uint8 private immutable _decimalsValue;
    address public armedRecipient;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimalsValue = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimalsValue;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address recipient) external {
        armedRecipient = recipient;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to != address(0) && to == armedRecipient) {
            IPostTransferHook(to).onTokensReceived(from, value);
        }
    }
}

interface IPostTransferHook {
    function onTokensReceived(address from, uint256 value) external;
}

/// @notice The hostile fee recipient. Registered as the vault's sole agent so
///         it is also the proposer (and therefore the performance-fee
///         recipient via `_distributeAgentFee`). Also an LP in its own right,
///         so it holds shares to attempt an instant exit with the moment its
///         fee payout callback fires.
contract MaliciousFeeRecipient is IPostTransferHook {
    IERC4626 public immutable vaultAsRedeemable;
    ISyndicateVault public immutable vaultStatus;
    ISyndicateGovernor public immutable governorStatus;

    uint256 public sharesToRedeem;
    bool public hookFired;
    bool public redeemSucceeded;
    uint256 public redeemedAssets;

    // Captured DURING the callback, before the redeem attempt below — the
    // direct observation that finding #24 is about.
    uint256 public capturedActiveProposal;
    uint256 public capturedOpenProposalCount;
    bool public capturedRedemptionsLocked;

    constructor(address vault_, address governor_) {
        vaultAsRedeemable = IERC4626(vault_);
        vaultStatus = ISyndicateVault(vault_);
        governorStatus = ISyndicateGovernor(governor_);
    }

    function setSharesToRedeem(uint256 shares) external {
        sharesToRedeem = shares;
    }

    /// @dev Fires synchronously from inside `SyndicateVault.transferPerformanceFee`'s
    ///      `safeTransfer` call, itself inside `SyndicateGovernor._finishSettlement`.
    ///      The reentrant redeem is wrapped in try/catch HERE, inside the hook,
    ///      rather than left to revert upward. A revert anywhere in this call
    ///      unwinds every storage write made since the fee transfer began --
    ///      including hookFired/capturedActiveProposal/etc above -- because a
    ///      reverted (sub)call discards all state changes made during it, not
    ///      just the ones after the point of failure (and EIP-1153 transient
    ///      storage rolls back the same way as regular storage). Letting the
    ///      redeem's revert propagate out of this function would therefore
    ///      wipe out the very observations this test needs to read back after
    ///      settleProposal returns. Catching it locally keeps those
    ///      observations intact while still recording that the redeem itself
    ///      failed (redeemSucceeded stays false), and lets the outer fee
    ///      transfer complete normally instead of being caught and escrowed
    ///      by `_payFee`.
    function onTokensReceived(address, uint256) external {
        hookFired = true;
        capturedActiveProposal = governorStatus.getActiveProposal();
        capturedOpenProposalCount = governorStatus.openProposalCount();
        capturedRedemptionsLocked = vaultStatus.redemptionsLocked();

        try vaultAsRedeemable.redeem(sharesToRedeem, address(this), address(this)) returns (uint256 assetsOut) {
            redeemSucceeded = true;
            redeemedAssets = assetsOut;
        } catch {
            // Expected under the fix: maxRedeem() floors at 0 while
            // redemptionsLocked() is true, so redeem() reverts with
            // ERC4626ExceededMaxRedeem. redeemSucceeded stays false.
        }
    }
}
