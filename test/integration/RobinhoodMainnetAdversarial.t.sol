// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RobinhoodMainnetIntegrationTest} from "./RobinhoodMainnetIntegrationTest.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/// @notice A contract that satisfies `SyndicateGovernor.propose`'s strategy
///         binding (`proposer()` == the proposing agent, `vault()` == the
///         vault) while being nothing but a label: it is never a batch target
///         and holds no capital.
///
///         Its only real surface is the pair of probes
///         `SyndicateVault._depositsLocked` / `_undeliveredValueOf` call on
///         `_lastSettledStrategy` after settlement. Modes let a test pick which
///         way the proposer-controlled probe misbehaves.
contract ProbeGriefStrategy {
    enum Mode {
        RevertAlways,
        BurnGas,
        LieUndelivered,
        Honest
    }

    Mode public mode;
    address private immutable _proposer;
    address private immutable _vault;

    constructor(address proposer_, address vault_, Mode m) {
        _proposer = proposer_;
        _vault = vault_;
        mode = m;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function proposer() external view returns (address) {
        return _proposer;
    }

    function vault() external view returns (address) {
        return _vault;
    }

    function hasUndeliveredValue() external view returns (uint256) {
        return _answer();
    }

    function undeliveredValue() external view returns (uint256) {
        return _answer();
    }

    function _answer() private view returns (uint256) {
        Mode m = mode;
        if (m == Mode.RevertAlways) revert("probe griefs");
        if (m == Mode.BurnGas) {
            // Unbounded loop: consumes whatever gas the caller forwarded. The
            // vault caps the probe at 150k, so this must OOG inside the probe
            // frame and never reach the caller's own budget.
            uint256 acc;
            for (uint256 i = 0; i < type(uint256).max; ++i) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
            return acc;
        }
        if (m == Mode.LieUndelivered) return type(uint128).max;
        return 0;
    }
}

/// @notice Batch-callable adapter that attempts to re-enter every LP-facing and
///         lifecycle-facing entrypoint from inside `executeGovernorBatch`.
///         Records outcomes instead of propagating, so the batch itself still
///         completes and the test can assert on WHICH reentries were refused.
contract ReentrantBatchAdapter {
    address public immutable vaultAddr;
    address public immutable governorAddr;
    address public immutable assetAddr;

    bool public depositReentered;
    bool public withdrawReentered;
    bool public requestDepositReentered;
    bool public requestRedeemReentered;
    bool public settleReentered;
    bool public ran;

    uint256 public pid;

    constructor(address vault_, address governor_, address asset_) {
        vaultAddr = vault_;
        governorAddr = governor_;
        assetAddr = asset_;
    }

    function arm(uint256 pid_) external {
        pid = pid_;
    }

    /// @dev Called by the governor batch with `msg.sender == vault`.
    function poke() external {
        ran = true;
        depositReentered =
            _try(vaultAddr, abi.encodeWithSignature("deposit(uint256,address)", uint256(1e6), address(this)));
        withdrawReentered = _try(
            vaultAddr,
            abi.encodeWithSignature("withdraw(uint256,address,address)", uint256(1), address(this), address(this))
        );
        requestDepositReentered =
            _try(vaultAddr, abi.encodeWithSignature("requestDeposit(uint256,address)", uint256(1e6), address(this)));
        requestRedeemReentered =
            _try(vaultAddr, abi.encodeWithSignature("requestRedeem(uint256,address)", uint256(1), address(this)));
        settleReentered = _try(governorAddr, abi.encodeWithSignature("settleProposal(uint256)", pid));
    }

    /// @dev Control: the SAME deposit call, made outside any batch. Proves a
    ///      failure inside `poke()` was the reentrancy latch and not funding.
    function depositOutsideBatch() external returns (bool) {
        return _try(vaultAddr, abi.encodeWithSignature("deposit(uint256,address)", uint256(1e6), address(this)));
    }

    function approveVault() external {
        IERC20(assetAddr).approve(vaultAddr, type(uint256).max);
    }

    function _try(address target, bytes memory data) private returns (bool ok) {
        (ok,) = target.call(data);
    }
}

/**
 * @title RobinhoodMainnetAdversarialTest
 * @notice Adversarial / negative-path fork suite against live Robinhood Chain
 *         mainnet infrastructure (USDG as the vault asset). Every existing
 *         mainnet fork test is a happy path; this one hunts for the ways the
 *         lifecycle can be wedged, griefed, front-run or rounded against LPs.
 *
 * @dev Deliberately uses NO strategy clone for most cases. The failure surface
 *      under test is the governor/vault/queue lifecycle, and a no-op proposal
 *      whose only batch call is a benign `USDG.balanceOf(vault)` read (the one
 *      selector class `SyndicateVault._guardBatchCalls` exempts on `asset()`)
 *      isolates that lifecycle from live-pool noise. Where real capital
 *      movement is needed, an allowlisted "sink" address is used so the loss is
 *      exact and reproducible rather than a function of live liquidity.
 *
 *      Run:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        export ROBINHOOD_FORK_CHAIN_ID=9994663
 *        forge test --match-path "test/integration/RobinhoodMainnetAdversarial.t.sol" -vv
 */
contract RobinhoodMainnetAdversarialTest is RobinhoodMainnetIntegrationTest {
    uint256 constant DURATION = 1 hours; // == governor minStrategyDuration
    uint256 constant FEE_BPS = 1000;

    address sink = makeAddr("sink");
    address attacker = makeAddr("attacker");
    address victim = makeAddr("victim");
    address guardian = makeAddr("guardian");

    // ==================== local lifecycle helpers ====================
    //
    // The base harness's `_proposeVoteExecute` hardcodes `GovEnvelope.permissive`
    // (maxDrawdownBps = 10_000, i.e. the capital-floor gate is a no-op). Several
    // cases here need a REAL drawdown declaration, a defeated vote, or a review
    // that never approves — so the envelope stages are split out locally rather
    // than by editing the shared base.

    function _benignRead() internal view returns (BatchExecutorLib.Call memory) {
        return BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.balanceOf, (address(vault))), value: 0});
    }

    function _noop() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = _benignRead();
    }

    function _single(BatchExecutorLib.Call memory c) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = c;
    }

    function _propose(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint16 maxDrawdownBps,
        uint256 duration
    ) internal returns (uint256 proposalId) {
        vm.prank(owner);
        vault.setAgentFeeBps(FEE_BPS);

        uint256 maxCapital = vault.totalAssets();
        ISyndicateGovernor.RiskEnvelope memory env =
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: maxDrawdownBps});

        // Cap the LAST exec call (the mover) and the FIRST settle call, matching
        // the base harness's convention.
        uint256[] memory execCaps = new uint256[](execCalls.length);
        execCaps[execCalls.length - 1] = maxCapital;
        uint256[] memory settleCaps = new uint256[](settleCalls.length);
        settleCaps[0] = maxCapital;

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy,
            "ipfs://rh-adversarial",
            duration,
            env,
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            _emptyCoProposers()
        );
    }

    function _voteBoth(uint256 pid, ISyndicateGovernor.VoteType support) internal {
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(pid, support);
        vm.prank(lp2);
        governor.vote(pid, support);
    }

    function _warpPastVoting() internal {
        ISyndicateGovernor.GovernorParams memory params = governor.getGovernorParams();
        vm.warp(vm.getBlockTimestamp() + params.votingPeriod + 1);
    }

    /// @dev Open the guardian review, optionally let `blocker` cast a Block vote,
    ///      then run the window out and resolve.
    function _reviewAndResolve(uint256 pid, address blocker) internal {
        registry.openReview(address(governor), pid);
        if (blocker != address(0)) {
            vm.prank(blocker);
            registry.voteOnProposal(address(governor), pid, IGuardianRegistry.GuardianVoteType.Block);
        }
        vm.warp(vm.getBlockTimestamp() + registry.reviewPeriod() + 1);
        registry.resolveReview(address(governor), pid);
    }

    /// @dev propose -> pass vote -> clear review -> execute. Returns the pid.
    function _runToExecuted(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint16 maxDrawdownBps
    ) internal returns (uint256 pid) {
        pid = _propose(strategy, execCalls, settleCalls, maxDrawdownBps, DURATION);
        _voteBoth(pid, ISyndicateGovernor.VoteType.For);
        _warpPastVoting();
        _reviewAndResolve(pid, address(0));
        governor.executeProposal(pid);
    }

    function _allow(address a) internal {
        vm.prank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(a, true);
    }

    function _usdg(address who) internal view returns (uint256) {
        return IERC20(USDG).balanceOf(who);
    }

    function _holders() internal view returns (address[] memory h) {
        h = new address[](2);
        h[0] = lp1;
        h[1] = lp2;
    }

    // ==================== 1. DEFEATED PROPOSAL ====================

    /// @notice A proposal the LPs vote down must leave the vault exactly as it
    ///         found it: capital untouched, instant exits reopened, execution
    ///         permanently refused, and no bond stranded.
    function test_defeated_capitalStaysAndLpsCanExit() public {
        uint256 assetsBefore = _usdg(address(vault));
        uint256 ppsBefore = _pricePerShare();

        uint256 pid = _propose(address(0), _noop(), _noop(), 10_000, DURATION);
        // Deposits shut the moment the proposal opens...
        assertTrue(vault.totalAssets() > 0, "vault funded");
        _voteBoth(pid, ISyndicateGovernor.VoteType.Against);
        _warpPastVoting();

        // Veto threshold is 2000bps of live supply; 100% Against clears it.
        governor.resolveProposalState(pid);
        assertEq(
            uint8(governor.getProposalState(pid)),
            uint8(ISyndicateGovernor.ProposalState.Rejected),
            "defeated proposal must be Rejected"
        );

        // Capital never moved.
        assertEq(_usdg(address(vault)), assetsBefore, "vault balance moved on a defeated proposal");
        _assertPpsNotBelow(ppsBefore, "defeated proposal");

        // It can never execute, now or later.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        // The vault binding is released, so instant exits are open again.
        assertEq(governor.openProposalCount(), 0, "vault still bound after rejection");
        assertFalse(vault.redemptionsLocked(), "redemptions still locked after rejection");

        uint256 shares = vault.balanceOf(lp1);
        uint256 out = _instantRedeem(lp1, shares);
        // A rejected proposal charged no fee and moved no capital, so the exit
        // is the deposit back, modulo ERC-4626 rounding (down, in the vault's
        // favour).
        assertLe(out, 10_000e6, "LP exited with MORE than deposited on a dead proposal");
        assertGe(out, 10_000e6 - 2, "LP exit shortfall beyond rounding dust");

        // No bond escrow is wired by `DeploySherwood.deployCore` (no
        // ExposureLedger / ProposerBondEscrow on this stack), so `propose` locked
        // no bond and the reclaim is a clean no-op rather than a stranded lock.
        vm.expectRevert(ISyndicateGovernor.NoBondToReclaim.selector);
        governor.reclaimProposerBond(pid);

        _assertShareClaimsSolvent(_holders());
    }

    /// @notice A proposal that PASSES the LP vote but is blocked by the guardian
    ///         review must be equally dead: Rejected, unexecutable, capital
    ///         untouched, exits reopened.
    function test_guardianBlocked_passedVoteStillCannotExecute() public {
        // The guardian's vote weight and the block-quorum denominator are both
        // read at the proposal's snapshot instant, so the stake must exist —
        // and be checkpointed — before `propose`.
        uint256 stake = swood.minGuardianStake();
        wood.mint(guardian, stake);
        vm.startPrank(guardian);
        wood.approve(address(swood), type(uint256).max);
        swood.stakeAsGuardian(stake, 7);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1 hours);

        uint256 assetsBefore = _usdg(address(vault));
        uint256 pid = _propose(address(0), _noop(), _noop(), 10_000, DURATION);
        _voteBoth(pid, ISyndicateGovernor.VoteType.For);
        _warpPastVoting();

        _reviewAndResolve(pid, guardian);

        // The registry's `resolveReview` decides the outcome, but the GOVERNOR's
        // bookkeeping (`_openProposalCount`) is committed lazily — `stateOf`
        // reports Rejected immediately while the vault stays bound until someone
        // calls the permissionless `resolveProposalState`. Assert both halves so
        // a regression that leaves the vault bound FOREVER is still caught.
        assertEq(
            uint8(governor.getProposalState(pid)),
            uint8(ISyndicateGovernor.ProposalState.Rejected),
            "blocked proposal must read Rejected before the commit"
        );
        assertEq(governor.openProposalCount(), 1, "binding released before any commit call");
        governor.resolveProposalState(pid);

        assertEq(
            uint8(governor.getProposalState(pid)),
            uint8(ISyndicateGovernor.ProposalState.Rejected),
            "guardian-blocked proposal must be Rejected"
        );
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        assertEq(_usdg(address(vault)), assetsBefore, "vault balance moved on a blocked proposal");
        assertEq(governor.openProposalCount(), 0, "vault still bound after a block");
        assertFalse(vault.redemptionsLocked(), "redemptions still locked after a block");

        (uint256 sharesOut, uint256 out) = _instantRedeemMax(lp1);
        assertGt(sharesOut, 0, "LP could not exit after a guardian block");
        assertLe(out, 10_000e6, "LP exited with more than deposited");
        _assertShareClaimsSolvent(_holders());
    }

    // ==================== 2. SETTLEMENT FAILURE ====================

    /// @notice Settlement that under-delivers past the declared drawdown must
    ///         REVERT with the specific floor error, must not wedge the vault,
    ///         and once the shortfall is repaired the proposal must settle
    ///         exactly once — a second settle is refused.
    function test_settleUnderDelivering_revertsAtFloor_thenSettlesExactlyOnce() public {
        _allow(sink);
        uint256 vaultBefore = _usdg(address(vault));
        uint256 loss = vaultBefore / 2; // 50% out the door; declared max 10%

        BatchExecutorLib.Call[] memory execCalls = _single(
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.transfer, (sink, loss)), value: 0})
        );

        uint256 pid = _runToExecuted(
            address(0),
            execCalls,
            _noop(),
            1000 /* 10% */
        );
        assertEq(_usdg(address(vault)), vaultBefore - loss, "exec leg did not move the capital");

        vm.warp(vm.getBlockTimestamp() + DURATION + 1);

        // basis = pre-exec balance, allowance = maxCapital * 10%, so the floor is
        // 90% of the pre-exec balance and a 50% loss is far below it.
        uint256 floorAssets = vaultBefore - (vaultBefore * 1000) / 10_000;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateGovernor.SettlementBelowDrawdownFloor.selector, vaultBefore - loss, floorAssets
            )
        );
        governor.settleProposal(pid);

        // NOT WEDGED: the proposal is still Executed, LPs can still queue an
        // async exit, and the queued request is still cancellable pre-stamp.
        assertEq(
            uint8(governor.getProposalState(pid)),
            uint8(ISyndicateGovernor.ProposalState.Executed),
            "proposal left a non-Executed state after a refused settle"
        );
        uint256 reqId = _requestRedeem(lp1, vault.balanceOf(lp1) / 2);
        _cancelQueued(lp1, reqId);

        // Repair the shortfall (the strategy leg finally delivers) and settle.
        vm.prank(sink);
        IERC20(USDG).transfer(address(vault), loss);
        governor.settleProposal(pid);
        assertEq(
            uint8(governor.getProposalState(pid)),
            uint8(ISyndicateGovernor.ProposalState.Settled),
            "settle did not land"
        );

        // Double-settle is refused with a specific error, not silently repeated.
        vm.expectRevert(ISyndicateGovernor.ProposalNotExecuted.selector);
        governor.settleProposal(pid);
        // ...and so is re-execution.
        vm.expectRevert(ISyndicateGovernor.ProposalNotApproved.selector);
        governor.executeProposal(pid);

        // Round trip was flat, so nobody can take out more than they put in.
        assertFalse(vault.redemptionsLocked(), "vault still locked after settlement");
        (, uint256 out1) = _instantRedeemMax(lp1);
        (, uint256 out2) = _instantRedeemMax(lp2);
        assertLe(out1 + out2, 20_000e6, "LPs withdrew more than the 20k deposited on a flat round trip");
        console2.log("flat round trip, LP1+LP2 out:", out1 + out2);
    }

    // ==================== 3. DEPOSIT WHILE LOCKED ====================

    /// @notice Deposits must be shut for the whole window in which capital is
    ///         deployed-but-unpriced, and a queued deposit that lands inside it
    ///         must mint at the realized settle price — never against the
    ///         under-reported mid-flight NAV.
    function test_depositGate_lockedWhileDeployed_queuedDepositPricesAtSettle() public {
        _allow(sink);
        _dealUSDG(victim, 5_000e6);

        uint256 ppsBefore = _pricePerShare();
        uint256 vaultBefore = _usdg(address(vault));
        uint256 deployed = 5_000e6;

        BatchExecutorLib.Call[] memory execCalls = _single(
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.transfer, (sink, deployed)), value: 0})
        );

        // --- Pending (voting open): deposits already shut, queue already open ---
        uint256 pid = _propose(address(0), execCalls, _noop(), 10_000, DURATION);
        assertEq(governor.openProposalCount(), 1, "proposal did not bind the vault");
        assertFalse(vault.redemptionsLocked(), "redemptions locked before execute");

        vm.startPrank(victim);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, victim);
        vm.stopPrank();

        uint256 reqId = _requestDeposit(victim, 1_000e6);

        // --- Executed: capital is out of the vault and unpriced ---
        _voteBoth(pid, ISyndicateGovernor.VoteType.For);
        _warpPastVoting();
        _reviewAndResolve(pid, address(0));
        governor.executeProposal(pid);

        assertEq(_usdg(address(vault)), vaultBefore - deployed, "capital not deployed");
        assertTrue(vault.redemptionsLocked(), "redemptions not locked while executing");
        vm.startPrank(victim);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, victim);
        vm.stopPrank();

        // The queued deposit cannot be claimed before the price is stamped.
        // The queue handle is hoisted OUT of the `expectRevert` window on
        // purpose: `_claimQueued` resolves `vault.withdrawalQueue()` first, and
        // that call in argument position would consume the armed one-shot
        // cheatcode (the failure mode is "next call did not revert").
        IVaultWithdrawalQueue q = _queue();
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        q.claim(reqId);

        // --- Settle: the deployed capital comes back, THEN the price is frozen ---
        vm.prank(sink);
        IERC20(USDG).transfer(address(vault), deployed);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        governor.settleProposal(pid);

        uint256 ppsAtSettle = _pricePerShare();
        uint256 sharesMinted = _claimQueued(victim, reqId);
        assertGt(sharesMinted, 0, "queued deposit minted nothing");

        // The queued depositor must NOT have minted against the mid-flight,
        // under-reported NAV: what they get back is what they put in, not a
        // slice of the 5k that was outside the vault while they queued.
        uint256 victimClaim = vault.previewRedeem(sharesMinted);
        assertLe(victimClaim, 1_000e6, "queued depositor minted against unpriced deployed capital");
        assertGe(victimClaim, 1_000e6 - 10, "queued depositor lost more than rounding dust");

        // And the sitting LPs were not diluted by the entry. Not
        // `_assertPpsNotBelow`: this window legitimately charges the 50bps
        // management fee over the deployed hour, so the bar is that the drop is
        // FEE-SIZED, not zero. 50bps annualized over ~1h is ~5.7e-7 of NAV;
        // anything a queued-deposit mispricing could steal is orders of
        // magnitude above this bound.
        assertGe(ppsAtSettle, ppsBefore - ppsBefore / 100_000, "price per share fell beyond the management fee");
        console2.log("pps before / at settle:", ppsBefore, ppsAtSettle);

        address[] memory h = new address[](3);
        h[0] = lp1;
        h[1] = lp2;
        h[2] = victim;
        _assertShareClaimsSolvent(h);
    }

    // ==================== 4. DONATION / INFLATION ATTACK ====================

    /// @notice Classic ERC-4626 first-depositor inflation attack against a FRESH
    ///         syndicate on the live asset: 1 wei of USDG in, a large direct
    ///         donation, then a victim deposit. The virtual-shares offset
    ///         (= asset decimals, 6 for USDG) must keep the victim's loss at
    ///         dust.
    function test_donationInflation_freshSyndicateOnLiveUsdg() public {
        address owner2 = makeAddr("owner2");
        wood.mint(owner2, MIN_OWNER_STAKE);
        vm.startPrank(owner2);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.stopPrank();

        SyndicateFactory.SyndicateConfig memory cfg = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://adversarial-fresh",
            asset: IERC20(USDG),
            name: "Fresh",
            symbol: "fUSDG",
            openDeposits: true,
            subdomain: "adversarial-fresh"
        });
        vm.prank(owner2);
        (, address freshAddr) = factory.createSyndicate(99, cfg);
        SyndicateVault fresh = SyndicateVault(payable(freshAddr));

        uint256 donation = 10_000e6;
        uint256 victimDeposit = 10_000e6;
        _dealUSDG(attacker, donation + 1);
        _dealUSDG(victim, victimDeposit);

        // 1 wei deposit, then donate straight to the vault to inflate the price.
        vm.startPrank(attacker);
        IERC20(USDG).approve(freshAddr, type(uint256).max);
        fresh.deposit(1, attacker);
        IERC20(USDG).transfer(freshAddr, donation);
        vm.stopPrank();

        vm.startPrank(victim);
        IERC20(USDG).approve(freshAddr, type(uint256).max);
        uint256 victimShares = fresh.deposit(victimDeposit, victim);
        vm.stopPrank();

        assertGt(victimShares, 0, "victim minted zero shares - donation attack succeeded outright");

        vm.prank(victim);
        uint256 victimOut = fresh.redeem(victimShares, victim, victim);
        console2.log("victim in / out:", victimDeposit, victimOut);
        // Loss must be DUST, not a percentage of the deposit. Measured on this
        // fork: 2,500 of 10,000,000,000 units = 2.5e-7 of the deposit, which is
        // two mulDiv floors against the 1e6 virtual-share offset, not dilution.
        // The bound is relative (1e-6 of the deposit) so it stays meaningful at
        // any size; a real inflation attack moves this by percent, not by ppm.
        assertGe(
            victimOut, victimDeposit - victimDeposit / 1_000_000, "victim diluted beyond dust by the donation attack"
        );

        // And the attacker must not have profited off the victim: what they can
        // pull out cannot exceed what they put in (1 wei + the donation).
        uint256 attackerClaim = fresh.previewRedeem(fresh.balanceOf(attacker));
        assertLe(attackerClaim, donation + 1, "attacker extracted more than the donation + stake");
    }

    // ==================== 5. REENTRANCY / CALLBACK SURFACE ====================

    /// @notice Any contract the governor batch calls holds `msg.sender == vault`
    ///         for one frame — the same position a v4 unlock callback or a
    ///         position-manager callback occupies. Every LP-facing and
    ///         lifecycle-facing entrypoint must refuse reentry from there.
    function test_reentrancy_everyEntrypointRefusedFromInsideTheBatch() public {
        ReentrantBatchAdapter adapter = new ReentrantBatchAdapter(address(vault), address(governor), USDG);
        _allow(address(adapter));
        _dealUSDG(address(adapter), 10_000e6);
        adapter.approveVault();

        BatchExecutorLib.Call[] memory execCalls = _single(
            BatchExecutorLib.Call({target: address(adapter), data: abi.encodeWithSignature("poke()"), value: 0})
        );

        uint256 pid = _propose(address(0), execCalls, _noop(), 10_000, DURATION);
        adapter.arm(pid);
        _voteBoth(pid, ISyndicateGovernor.VoteType.For);
        _warpPastVoting();
        _reviewAndResolve(pid, address(0));

        uint256 supplyBefore = vault.totalSupply();
        uint256 assetsBefore = _usdg(address(vault));
        governor.executeProposal(pid);

        assertTrue(adapter.ran(), "adapter was never called - the reentry attempts never happened");
        assertFalse(adapter.depositReentered(), "deposit re-entered from inside the batch");
        assertFalse(adapter.withdrawReentered(), "withdraw re-entered from inside the batch");
        assertFalse(adapter.requestDepositReentered(), "requestDeposit re-entered from inside the batch");
        assertFalse(adapter.requestRedeemReentered(), "requestRedeem re-entered from inside the batch");
        assertFalse(adapter.settleReentered(), "settleProposal re-entered from inside execute");

        // Nothing minted, nothing moved.
        assertEq(vault.totalSupply(), supplyBefore, "supply changed via a reentrant mint");
        assertEq(_usdg(address(vault)), assetsBefore, "vault balance changed during the reentrancy batch");
        assertEq(vault.balanceOf(address(adapter)), 0, "adapter holds shares it should never have minted");

        // CONTROL: the identical deposit call succeeds outside the batch, which
        // proves the five failures above were the reentrancy latch and not a
        // funding/approval artefact.
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        governor.settleProposal(pid);
        assertTrue(adapter.depositOutsideBatch(), "control deposit failed - the reentry test proves nothing");
    }

    // ==================== 6. GRIEFING THE RESIDUE PROBE ====================

    /// @dev Shared driver: run one no-op proposal whose STRATEGY LABEL is `probe`
    ///      (never a batch target), settle it, and leave `probe` pinned as the
    ///      vault's `_lastSettledStrategy`.
    function _settleWithProbeLabel(ProbeGriefStrategy probe) internal returns (uint256 pid) {
        pid = _runToExecuted(address(probe), _noop(), _noop(), 10_000);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        governor.settleProposal(pid);
    }

    /// @notice A settled strategy whose probe REVERTS, or burns unbounded gas,
    ///         must degrade OPEN — it may not brick deposits and it may not make
    ///         a deposit cost unbounded gas.
    function test_grief_revertingAndGasBurningProbe_degradeOpen() public {
        ProbeGriefStrategy probe = new ProbeGriefStrategy(agent, address(vault), ProbeGriefStrategy.Mode.RevertAlways);
        _settleWithProbeLabel(probe);

        _dealUSDG(victim, 2_000e6);
        vm.startPrank(victim);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        uint256 sharesA = vault.deposit(1_000e6, victim);
        vm.stopPrank();
        assertGt(sharesA, 0, "reverting probe bricked deposits");

        // Same again with the unbounded-gas probe. The vault caps the probe at
        // 150k gas, so the loop must die inside the probe frame.
        probe.setMode(ProbeGriefStrategy.Mode.BurnGas);
        vm.startPrank(victim);
        uint256 gasBefore = gasleft();
        uint256 sharesB = vault.deposit(1_000e6, victim);
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();
        assertGt(sharesB, 0, "gas-burning probe bricked deposits");
        console2.log("deposit gas with a gas-burning probe:", gasUsed);
        // A deposit that has to eat the probe's 150k ceiling is still cheap
        // enough to be unconditionally callable; an unbounded burn would blow
        // straight past this.
        assertLt(gasUsed, 900_000, "gas-burning probe made a deposit unboundedly expensive");
    }

    /// @notice SUSPECTED GRIEFING VECTOR (PR #243 finding class B3, verified live).
    ///
    ///         `SyndicateVault._depositsLocked` trusts a nonzero answer from
    ///         `_lastSettledStrategy.hasUndeliveredValue()`, and that address is
    ///         whatever the PROPOSER named as the proposal's `strategy` label.
    ///         `propose` only checks `proposer() == msg.sender` and
    ///         `vault() == vault` — both trivially satisfiable by an attacker
    ///         contract that is never a batch target and never holds a cent.
    ///
    ///         A label that simply LIES ("I still hold undelivered value")
    ///         therefore closes instant deposits for the whole vault, with no
    ///         `sweep()` to call (the escape route the source comment relies on
    ///         belongs to real strategy templates, not to an arbitrary label) and
    ///         no permissionless way to clear the pin — only another proposal
    ///         reaching settlement overwrites `_lastSettledStrategy`, and that
    ///         needs a registered agent plus a full vote+review cycle.
    ///
    ///         This test PASSES by asserting the vector exists. If the branch is
    ///         hardened (e.g. probe only a strategy the batch actually called, or
    ///         bound the lock in time), this test is the one that should flip.
    function test_grief_lyingSettledStrategyLabel_shutsDepositsIndefinitely() public {
        ProbeGriefStrategy probe = new ProbeGriefStrategy(agent, address(vault), ProbeGriefStrategy.Mode.LieUndelivered);
        _settleWithProbeLabel(probe);

        _dealUSDG(victim, 1_000e6);
        vm.startPrank(victim);
        IERC20(USDG).approve(address(vault), type(uint256).max);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, victim);
        vm.stopPrank();

        // The lock is not a transient settlement artefact: it survives a month.
        vm.warp(vm.getBlockTimestamp() + 30 days);
        vm.startPrank(victim);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000e6, victim);
        vm.stopPrank();

        // Bounding the blast radius, and the reason this is a griefing vector
        // rather than a theft: existing LPs are NOT trapped, instant exits stay
        // open, and no accounting is corrupted.
        assertFalse(vault.redemptionsLocked(), "existing LPs trapped by the probe lie");
        (uint256 sharesOut, uint256 out) = _instantRedeemMax(lp1);
        assertGt(sharesOut, 0, "LP exit blocked by the probe lie");
        assertLe(out, 10_000e6, "LP took out more than deposited");

        // And it is cleared only by a SETTLEMENT that re-pins the label — i.e.
        // recovery costs a full governance cycle, it is not permissionless.
        probe.setMode(ProbeGriefStrategy.Mode.Honest);
        vm.startPrank(victim);
        uint256 shares = vault.deposit(1_000e6, victim);
        vm.stopPrank();
        assertGt(shares, 0, "deposits did not reopen once the probe stopped lying");
    }

    // ==================== 7. ROUNDING DIRECTION ====================

    /// @notice Many tiny deposits and redeems interleaved with a strategy round
    ///         trip. Rounding must always favour the vault: nobody may withdraw
    ///         more than they put in when the round trip is flat, and price per
    ///         share must never fall on a pure entry/exit.
    function test_rounding_tinyFlowsAroundARoundTripNeverFavourTheExiter() public {
        _allow(sink);

        uint256 n = 12;
        uint256 unit = 1_001; // deliberately non-round, ~0.001 USDG
        uint256 totalIn;
        uint256 totalOut;
        uint256 ppsFloor = _pricePerShare();

        // Phase 1 — tiny in/out cycles between proposals.
        for (uint256 i = 0; i < n; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("tiny", i)))));
            _dealUSDG(u, unit);
            vm.startPrank(u);
            IERC20(USDG).approve(address(vault), type(uint256).max);
            uint256 sh = vault.deposit(unit, u);
            vm.stopPrank();
            totalIn += unit;

            uint256 outAssets = _instantRedeem(u, sh);
            totalOut += outAssets;
            assertLe(outAssets, unit, "tiny round trip paid out more than it took in");
            _assertPpsNotBelow(ppsFloor, "tiny deposit/redeem cycle");
            ppsFloor = _pricePerShare();
        }

        // Phase 2 — a flat strategy round trip (out and back, no PnL).
        uint256 deployed = 5_000e6;
        BatchExecutorLib.Call[] memory execCalls = _single(
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.transfer, (sink, deployed)), value: 0})
        );
        uint256 pid = _runToExecuted(address(0), execCalls, _noop(), 10_000);
        vm.prank(sink);
        IERC20(USDG).transfer(address(vault), deployed);
        vm.warp(vm.getBlockTimestamp() + DURATION + 1);
        governor.settleProposal(pid);

        // Phase 3 — the same tiny cycles after the round trip.
        for (uint256 i = 0; i < n; ++i) {
            address u = address(uint160(uint256(keccak256(abi.encode("tiny2", i)))));
            _dealUSDG(u, unit);
            vm.startPrank(u);
            IERC20(USDG).approve(address(vault), type(uint256).max);
            uint256 sh = vault.deposit(unit, u);
            vm.stopPrank();
            totalIn += unit;

            uint256 outAssets = _instantRedeem(u, sh);
            totalOut += outAssets;
            assertLe(outAssets, unit, "tiny round trip paid out more than it took in (post-settle)");
        }

        console2.log("tiny flows in / out:", totalIn, totalOut);
        assertLe(totalOut, totalIn, "aggregate tiny flows extracted value from the vault");

        // Original LPs still whole (flat round trip; management fee is the only
        // legitimate leak and it accrues to the owner, not to an exiting LP).
        (, uint256 o1) = _instantRedeemMax(lp1);
        (, uint256 o2) = _instantRedeemMax(lp2);
        assertLe(o1 + o2, 20_000e6, "LPs extracted more than they deposited on a flat round trip");
        console2.log("LP1+LP2 out after flat round trip:", o1 + o2);
    }
}
