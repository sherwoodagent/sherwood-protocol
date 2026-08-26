// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RobinhoodMainnetIntegrationTest} from "./RobinhoodMainnetIntegrationTest.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {IProtocolConfig} from "../../src/interfaces/IProtocolConfig.sol";
import {PortfolioStrategy} from "../../src/strategies/PortfolioStrategy.sol";
import {UniswapSwapAdapter} from "../../src/adapters/UniswapSwapAdapter.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

/**
 * @title RobinhoodMainnetFullExitTest
 * @notice The complete depositor round trip on a Robinhood Chain mainnet fork:
 *         two LPs deposit ASYMMETRIC amounts, a real `PortfolioStrategy` buys
 *         WETH over the live Uniswap v3 USDG/WETH 500 pool, the proposal settles
 *         against live Chainlink prices, and BOTH LPs exit to the last wei —
 *         instantly, through the async queue, and in adversarial orderings.
 *
 *         Every existing 4663 suite stops at `settleProposal`. Not one of them
 *         contains a `redeem`, `withdraw`, `requestRedeem` or `claim`, so the
 *         half of the protocol that actually pays depositors back has never run
 *         against live liquidity. This suite is that half.
 *
 *         The assertions are conservation identities, not "it did not revert":
 *           - assets out + assets left == assets present, EXACTLY (nothing else
 *             moves in the window, so this is an equality, not a bound);
 *           - realized value per share is equal for the LP who exited early and
 *             the LP who waited (the pricing-bug detector);
 *           - a queue claim moves the price for nobody;
 *           - fee outflow equals exactly the fee the governor says it charged.
 *
 * @dev Fee routing on this fork stack, read from source (NOT assumed):
 *      `script/Deploy.s.sol::deployCore` never calls `setProtocolFeeRecipient` /
 *      `setGuardiansFeeRecipient` (only the chain-specific deploy scripts do),
 *      so both are `address(0)`. `SyndicateGovernor._chargeManagementFee` and
 *      `_chargePerformanceFee` therefore zero those legs and fold them into the
 *      agent's remainder. Net: the AGENT receives 100% of the management fee and
 *      `perfSplit.agentBps + protocolBps + guardianBps` of the performance fee,
 *      and the vault OWNER receives `perfSplit.ownerBps`. That makes both fee
 *      recipients directly measurable as ERC-20 balance deltas.
 *
 * @dev Run:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        export ROBINHOOD_FORK_CHAIN_ID=9994663
 *        forge test --match-path "test/integration/RobinhoodMainnetFullExit.t.sol" -vv
 */
contract RobinhoodMainnetFullExitTest is RobinhoodMainnetIntegrationTest {
    // ── Strategy sizing ──
    uint256 constant DEPLOY_AMOUNT = 5_000e6; // USDG pushed into the basket
    uint256 constant STRATEGY_DURATION = 1 hours;
    uint256 constant PERF_FEE_BPS = 1000; // 10% carry
    uint256 constant MAX_SLIPPAGE_BPS = 500; // 5%, inside MAX_SLIPPAGE_CEILING_BPS

    /// @dev The base harness deposits 10k for each LP. This tops lp1 up so the
    ///      book is ASYMMETRIC (15k vs 10k) — a pro-rata bug that happens to
    ///      cancel at 50/50 does not cancel at 60/40.
    uint256 constant LP1_EXTRA = 5_000e6;

    /// @dev Profit injected as USDG straight onto the strategy clone. `_settle`
    ///      ends with `_pushAllToVault(asset)`, so an asset-denominated balance
    ///      on the clone arrives in the vault at settlement exactly like trading
    ///      profit would. Used only by the fee test, which needs the fund ABOVE
    ///      its high-water mark for the performance leg to charge at all — a
    ///      real WETH round trip through a 5bp pool reliably ends slightly DOWN,
    ///      which would leave `perfFee == 0` and make the split unverifiable.
    uint256 constant INJECTED_PROFIT = 1_000e6;

    /// @dev Rounding budget for a full two-LP drain, in USDG wei (6 dec).
    ///      Sources, each independent and each at most 1 wei:
    ///        1. `redeem` floors `mulDiv(shares, totalAssets+1, pricingSupply +
    ///           10**offset)` — one floor per redeeming LP, so 2 wei;
    ///        2. the ERC-4626 virtual offset (`10**6` virtual shares against a
    ///           ~2.5e16 real supply) leaves `totalAssets * 1e6 / (supply+1e6)`
    ///           ≈ 25e9 * 4e-11 < 1 wei permanently in the vault.
    ///      2 + 1 = 3, plus 1 wei of slack = 4. Deliberately NOT a percentage:
    ///      at this size a percentage tolerance would swallow thousands of wei
    ///      and hide a real leak.
    uint256 constant DRAIN_DUST_WEI = 4;

    /// @dev Tolerance when comparing realized value-per-share between two LPs,
    ///      expressed in the `assets * 1e18 / shares` unit used below (pps here
    ///      is ~1e12). One wei of asset rounding on a ~1.5e16 share balance
    ///      moves that figure by `1e18 / 1.5e16` ≈ 67 units, so 400 is under
    ///      6 wei of asset-level rounding — tight enough that a systematic
    ///      per-share advantage of even 0.000001% (≈1e4 units) fails.
    uint256 constant PPS_EQUALITY_TOLERANCE = 400;

    address swapAdapter;
    address template;

    // keccak256("ManagementFeeCharged(uint256,address,uint256,uint256)")
    bytes32 constant MGMT_FEE_TOPIC = keccak256("ManagementFeeCharged(uint256,address,uint256,uint256)");
    // keccak256("PerformanceFeeCharged(uint256,address,uint256,uint256)")
    bytes32 constant PERF_FEE_TOPIC = keccak256("PerformanceFeeCharged(uint256,address,uint256,uint256)");

    function setUp() public override {
        super.setUp();
        if (address(vault) == address(0)) return; // fork unavailable; setUp skipped

        swapAdapter =
            address(new UniswapSwapAdapter(UNISWAP_SWAP_ROUTER, UNISWAP_QUOTER_V2, V4_POOL_MANAGER, V4_QUOTER));
        template = address(new PortfolioStrategy());
        vm.prank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(swapAdapter, true);

        // Asymmetric book: lp1 15k, lp2 10k.
        _dealUSDG(lp1, LP1_EXTRA);
        vm.startPrank(lp1);
        IERC20(USDG).approve(address(vault), LP1_EXTRA);
        vault.deposit(LP1_EXTRA, lp1);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Repo convention: never `vm.skip` from `setUp` (forge-version
    ///      dependent). The shared base still does, so this is the body-side
    ///      guard for the case where the fork is unavailable and `vault` was
    ///      never created.
    function _requireFork() internal {
        if (address(vault) == address(0)) vm.skip(true);
    }

    // ==================== STRATEGY PLUMBING ====================
    // Mirrors PortfolioMainnetFork.t.sol's 100% WETH / v3 fee-500 basket.

    function _initData(uint256 totalAmt) internal view returns (bytes memory) {
        address[] memory tokens = new address[](1);
        tokens[0] = WETH;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 10_000;
        bytes[] memory extraData = new bytes[](1);
        extraData[0] = abi.encodePacked(uint8(0), abi.encode(FEE_500));
        uint8[] memory priceDecimals = new uint8[](1);
        priceDecimals[0] = 8;
        bytes32[] memory feedIds = new bytes32[](1);
        feedIds[0] = bytes32(uint256(uint160(CHAINLINK_ETH_USD_FEED)));

        return abi.encode(
            USDG,
            swapAdapter,
            address(0), // push mode
            tokens,
            weights,
            totalAmt,
            MAX_SLIPPAGE_BPS,
            extraData,
            priceDecimals,
            feedIds
        );
    }

    function _execCalls(address strategy, uint256 amount) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, amount)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _settleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    /// @notice Deploy a WETH basket clone and drive it through
    ///         propose -> vote -> guardian review -> execute. On return the
    ///         proposal is EXECUTED: `redemptionsLocked() == true`, instant
    ///         exits are shut and only the async queue is open.
    function _executeStrategy() internal returns (address strategy, uint256 proposalId) {
        strategy = _cloneAndInit(template, _initData(DEPLOY_AMOUNT));
        proposalId = _proposeVoteExecute(
            _execCalls(strategy, DEPLOY_AMOUNT), _settleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION
        );
        assertGt(IERC20(WETH).balanceOf(strategy), 0, "execute leg bought no WETH");
        assertTrue(vault.redemptionsLocked(), "vault not locked while the strategy is deployed");
    }

    /// @notice Warp past `strategyDuration` and settle, unwinding WETH -> USDG.
    function _settle(address strategy, uint256 proposalId) internal {
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        governor.settleProposal(proposalId);
        assertEq(IERC20(WETH).balanceOf(strategy), 0, "strategy did not fully unwind");
        assertFalse(vault.redemptionsLocked(), "vault still locked after settlement");
    }

    /// @dev Realized value per share, in the same 1e18-scaled unit
    ///      `pricePerShare()` reports (~1e12 for a 6-decimal asset).
    function _realizedPps(uint256 assetsOut, uint256 sharesBurned) internal pure returns (uint256) {
        return Math.mulDiv(assetsOut, 1e18, sharesBurned);
    }

    function _usdg(address who) internal view returns (uint256) {
        return IERC20(USDG).balanceOf(who);
    }

    // ==================== 1. INSTANT FULL EXIT ====================

    /// @notice Both LPs redeem 100% instantly after settlement.
    /// @dev Would catch: assets stranded in the vault beyond the declared dust
    ///      budget, a redeem that pays out more than the vault holds, shares
    ///      that survive a full drain, and an early/late asymmetry between the
    ///      two LPs' realized price.
    function test_fullExit_bothLpsRedeemEverythingAfterSettlement() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _executeStrategy();
        _settle(strategy, proposalId);

        // Nothing is queued, so the vault owes the queue nothing and — with the
        // settlement fees delivered rather than escrowed — `totalAssets()` is
        // exactly the balance. Pin both, because every identity below assumes it.
        assertEq(_queue().reservedAssets(), 0, "unexpected queue reserve");
        assertEq(governor.outstandingEscrow(address(vault), USDG), 0, "a settlement fee escrowed instead of paying");
        uint256 vaultAssets = _usdg(address(vault));
        assertEq(vault.totalAssets(), vaultAssets, "totalAssets diverged from the raw balance");

        uint256 shares1 = vault.balanceOf(lp1);
        uint256 shares2 = vault.balanceOf(lp2);
        assertGt(shares1, shares2, "book is not asymmetric: lp1 should hold more");
        assertEq(vault.totalSupply(), shares1 + shares2, "third-party shares exist; the drain identity would not hold");

        address[] memory holders = new address[](2);
        holders[0] = lp1;
        holders[1] = lp2;
        _assertShareClaimsSolvent(holders);

        (uint256 redeemed1, uint256 out1) = _instantRedeemMax(lp1);
        (uint256 redeemed2, uint256 out2) = _instantRedeemMax(lp2);

        assertEq(redeemed1, shares1, "lp1 could not redeem its whole balance instantly");
        assertEq(redeemed2, shares2, "lp2 could not redeem its whole balance instantly");
        assertEq(vault.balanceOf(lp1), 0, "lp1 left shares behind");
        assertEq(vault.balanceOf(lp2), 0, "lp2 left shares behind");
        assertEq(vault.totalSupply(), 0, "shares survived a full drain (no dead-share floor exists in this vault)");

        // CONSERVATION, as an exact equality. Between the two reads the only
        // asset movements are the two payouts, so anything other than equality
        // is value appearing or vanishing.
        uint256 leftover = _usdg(address(vault));
        console2.log("vault assets before exit / dust left after full drain (wei):", vaultAssets, leftover);
        assertEq(out1 + out2 + leftover, vaultAssets, "USDG conservation broken across the exit");
        assertLe(leftover, DRAIN_DUST_WEI, "more than the declared rounding dust stranded in the vault");
        assertLe(vault.totalAssets(), DRAIN_DUST_WEI, "totalAssets has an unclaimed remainder beyond fee dust");

        // FAIRNESS: two LPs redeeming in the same block at the same price must
        // realize the same value per share regardless of size.
        uint256 pps1 = _realizedPps(out1, shares1);
        uint256 pps2 = _realizedPps(out2, shares2);
        console2.log("lp1 out / realized pps:", out1, pps1);
        console2.log("lp2 out / realized pps:", out2, pps2);
        assertApproxEqAbs(pps1, pps2, PPS_EQUALITY_TOLERANCE, "instant exit favours one LP over the other");
    }

    // ==================== 2. PARTIAL / MID-STRATEGY EXIT ====================

    /// @notice Mid-strategy instant exit is GATED; the LP that routes half its
    ///         stack through the queue must end up neither ahead of nor behind
    ///         the LP that simply waited.
    /// @dev Would catch: the mid-strategy gate silently opening (an LP redeeming
    ///      against a NAV that excludes deployed capital would be paid a
    ///      fraction of its worth and dilute everyone else), and any pricing gap
    ///      between the queue's frozen stamp and the post-settlement spot price.
    function test_partialExit_midStrategyGatedThenPricedIdenticallyToWaiting() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _executeStrategy();

        uint256 shares1 = vault.balanceOf(lp1);
        uint256 shares2 = vault.balanceOf(lp2);
        uint256 half = shares1 / 2;

        // THE GATE, asserted by its specific error rather than by silence.
        // `maxRedeem`/`maxWithdraw` are the canonical lock (OZ ERC4626 consults
        // them before `_withdraw`), so both must read 0 AND the call must
        // revert with OZ's max-exceeded error naming that 0.
        assertEq(vault.maxRedeem(lp1), 0, "instant redeem is open mid-strategy");
        assertEq(vault.maxWithdraw(lp1), 0, "instant withdraw is open mid-strategy");
        vm.prank(lp1);
        vm.expectRevert(abi.encodeWithSignature("ERC4626ExceededMaxRedeem(address,uint256,uint256)", lp1, half, 0));
        vault.redeem(half, lp1, lp1);

        // So lp1 takes the only open door: the async queue.
        uint256 reqId = _requestRedeem(lp1, half);
        assertEq(vault.balanceOf(lp1), shares1 - half, "escrowed shares were not moved out of lp1");
        assertEq(vault.balanceOf(vault.withdrawalQueue()), half, "queue did not take custody of the shares");

        _settle(strategy, proposalId);

        uint256 claimed = _claimQueued(lp1, reqId);
        uint256 instant1 = _instantRedeem(lp1, vault.balanceOf(lp1));
        (uint256 redeemed2, uint256 instant2) = _instantRedeemMax(lp2);
        assertEq(redeemed2, shares2, "lp2 could not exit fully");

        assertEq(vault.balanceOf(lp1), 0, "lp1 left shares behind");
        assertEq(vault.balanceOf(lp2), 0, "lp2 left shares behind");

        // The whole point: half-early lp1 vs waited-the-whole-time lp2.
        uint256 pps1 = _realizedPps(claimed + instant1, shares1);
        uint256 pps2 = _realizedPps(instant2, shares2);
        console2.log("lp1 queued / instant:", claimed, instant1);
        console2.log("lp1 realized pps:", pps1);
        console2.log("lp2 realized pps:", pps2);
        assertApproxEqAbs(
            pps1, pps2, PPS_EQUALITY_TOLERANCE, "partial mid-strategy exit is not value-neutral vs waiting"
        );
    }

    // ==================== 3. QUEUED REDEEM, END TO END ====================

    /// @notice requestRedeem -> settleProposal (stamp) -> claim.
    /// @dev PRICING SEMANTICS, read from source, not guessed: a Redeem request
    ///      is priced at the SETTLEMENT STAMP OF ITS OWN PROPOSAL — neither at
    ///      request time nor at claim time. `VaultWithdrawalQueue.claim` uses
    ///      `pricePid = r.pid` for `RequestKind.Redeem` (only Deposits reprice
    ///      to `_lastStampedPid`), and pays `mulDiv(shares, sp.num, sp.den)`
    ///      where `num/den` were frozen by `stampSettlement`. This test asserts
    ///      that exact number.
    ///      Would catch: a claim priced off live NAV (which would let a claimant
    ///      pick a block), and a claim that moves the share price for the
    ///      holders who stayed.
    function test_queuedRedeem_pricedAtItsOwnSettlementStamp() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _executeStrategy();

        uint256 shares1 = vault.balanceOf(lp1);
        uint256 reqId = _requestRedeem(lp1, shares1);

        // Not claimable before the stamp exists.
        // HOIST THE QUEUE READ. `_queue()` is `vault.withdrawalQueue()`, an
        // external staticcall — leaving it inline would be evaluated FIRST and
        // consume the armed one-shot `expectRevert`, which then fails with
        // "next call did not revert as expected" against the wrong call.
        IVaultWithdrawalQueue q = _queue();
        vm.expectRevert(IVaultWithdrawalQueue.NotSettled.selector);
        q.claim(reqId);

        _settle(strategy, proposalId);

        IVaultWithdrawalQueue.SettlePrice memory sp = _queue().getSettlePrice(proposalId);
        assertTrue(sp.stamped, "settlement did not stamp a price for this proposal");
        uint256 expected = Math.mulDiv(shares1, sp.num, sp.den);
        assertGt(expected, 0, "stamped price pays a full LP nothing");

        // A claim hands out assets that were ALREADY carved out of both
        // `totalAssets()` (via the reserve) and `_pricingSupply()` (via
        // `stampedUnclaimedShares`), so it must not move the price for lp2.
        uint256 ppsBefore = _pricePerShare();
        uint256 lp1Before = _usdg(lp1);
        uint256 supplyBefore = vault.totalSupply();

        uint256 claimed = _claimQueued(lp2, reqId); // permissionless caller, proceeds to lp1

        assertEq(claimed, expected, "queued redeem was not paid at its proposal's stamped price");
        assertEq(_usdg(lp1) - lp1Before, claimed, "proceeds did not reach the request owner");
        assertEq(supplyBefore - vault.totalSupply(), shares1, "escrowed shares were not burned at claim");
        _assertPpsNotBelow(ppsBefore, "queue claim");
        assertApproxEqAbs(
            _pricePerShare(), ppsBefore, PPS_EQUALITY_TOLERANCE, "a queue claim moved the price for holders who stayed"
        );

        // lp2, who never queued, still exits in full afterwards.
        uint256 lp2Shares = vault.balanceOf(lp2);
        (uint256 redeemed2, uint256 out2) = _instantRedeemMax(lp2);
        assertEq(redeemed2, lp2Shares, "lp2 could not redeem its whole balance after a queued claim");
        assertEq(vault.balanceOf(lp2), 0, "lp2 could not fully exit after a queued claim");
        assertGt(out2, 0, "lp2 exited for nothing");
        assertEq(vault.totalSupply(), 0, "shares survived after both LPs exited");
    }

    // ==================== 4. EXIT ORDERING FAIRNESS ====================

    /// @notice Both LPs queue a full exit (lp1 first, lp2 second) and claim in
    ///         the OPPOSITE order. Neither may extract more than pro rata.
    /// @dev Would catch: a first-mover or last-mover premium in the queue —
    ///      e.g. a claim that repriced against the shrinking pool, which would
    ///      let whoever claims last absorb the earlier claimant's rounding, or
    ///      an ordering that lets the pair drain more than was reserved for them.
    function test_exitOrdering_claimOrderCannotBeatRequestOrder() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _executeStrategy();

        uint256 shares1 = vault.balanceOf(lp1);
        uint256 shares2 = vault.balanceOf(lp2);
        uint256 req1 = _requestRedeem(lp1, shares1); // requested FIRST
        uint256 req2 = _requestRedeem(lp2, shares2); // requested SECOND

        _settle(strategy, proposalId);

        IVaultWithdrawalQueue.SettlePrice memory sp = _queue().getSettlePrice(proposalId);
        uint256 reservedForPair = _queue().reservedAssets();
        assertGt(reservedForPair, 0, "settlement reserved nothing for the queued exits");

        // Claim in the REVERSE order.
        uint256 out2 = _claimQueued(lp2, req2);
        uint256 out1 = _claimQueued(lp1, req1);

        // Same frozen price for both, independent of either ordering.
        assertEq(out1, Math.mulDiv(shares1, sp.num, sp.den), "lp1 not paid at the frozen stamp");
        assertEq(out2, Math.mulDiv(shares2, sp.num, sp.den), "lp2 not paid at the frozen stamp");

        uint256 pps1 = _realizedPps(out1, shares1);
        uint256 pps2 = _realizedPps(out2, shares2);
        console2.log("ordering: lp1 pps / lp2 pps:", pps1, pps2);
        assertApproxEqAbs(pps1, pps2, PPS_EQUALITY_TOLERANCE, "claim ordering produced a per-share advantage");

        // Neither LP, nor the pair, extracted more than was set aside for them.
        assertLe(out1 + out2, reservedForPair, "queued claims paid out more than the settlement reserved");
        assertEq(vault.totalSupply(), 0, "escrowed shares were not fully burned");
        assertEq(_queue().reservedAssets(), 0, "reserve not released after the final claim");
        assertLe(_usdg(address(vault)), DRAIN_DUST_WEI, "assets stranded after both queued exits");
    }

    // ==================== 5. FEE ACCOUNTING ====================

    /// @notice With a non-zero agent fee and the 50bps management fee, the fee
    ///         that LEAVES the vault must equal, to the wei, the fee the
    ///         governor says it charged — and land with the right recipients.
    /// @dev Would catch: a double charge (outflow == 2x the emitted fee), a
    ///      fee-on-fee (the performance leg computed on a base that still
    ///      contains the management fee), a silent escrow instead of a payment,
    ///      and a fee taken out of the LPs twice by also depressing their exit.
    function test_feeAccounting_chargedOnceAndDeliveredToTheRightRecipients() public {
        _requireFork();

        (address strategy, uint256 proposalId) = _executeStrategy();

        // Push the fund above its high-water mark so the performance leg has a
        // base at all (see INJECTED_PROFIT).
        _dealUSDG(strategy, _usdg(strategy) + INJECTED_PROFIT);

        uint256 agentBefore = _usdg(agent);
        uint256 ownerBefore = _usdg(owner);
        uint256 lp1Shares = vault.balanceOf(lp1);
        uint256 lp2Shares = vault.balanceOf(lp2);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        vm.recordLogs();
        governor.settleProposal(proposalId);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 mgmtFee,, uint256 mgmtCount) = _readFeeEvent(logs, MGMT_FEE_TOPIC);
        (uint256 perfFee, uint256 perfBase, uint256 perfCount) = _readFeeEvent(logs, PERF_FEE_TOPIC);

        // CHARGED ONCE means literally once: one event apiece.
        assertEq(mgmtCount, 1, "management fee charged more than once in one settlement");
        assertEq(perfCount, 1, "performance fee charged more than once in one settlement");
        assertGt(mgmtFee, 0, "the always-on management fee charged nothing");
        assertGt(perfFee, 0, "no performance fee despite injected profit: test premise broken");

        // The performance leg is ONE division of ONE base — not a waterfall on
        // top of the management fee. `base` is `aboveHighWaterMark()` read
        // AFTER the management fee left, so `perfFee == base * bps / 10_000`
        // exactly; a fee-on-fee would break this equality.
        uint256 maxPerfBps = governor.getGovernorParams().maxPerformanceFeeBps;
        uint256 effectiveBps = PERF_FEE_BPS > maxPerfBps ? maxPerfBps : PERF_FEE_BPS;
        assertEq(perfFee, (perfBase * effectiveBps) / 10_000, "performance fee is not one clean division of its base");

        // Split, with protocol + guardian recipients unwired (see contract doc):
        // owner takes perfSplit.ownerBps of the performance fee; the agent takes
        // the whole management fee plus the entire remainder of the performance
        // fee.
        uint256 ownerBps = _perfOwnerBps();
        uint256 expectedOwner = (perfFee * ownerBps) / 10_000;
        uint256 expectedAgent = mgmtFee + (perfFee - expectedOwner);

        uint256 agentGain = _usdg(agent) - agentBefore;
        uint256 ownerGain = _usdg(owner) - ownerBefore;
        console2.log("mgmtFee / perfFee:", mgmtFee, perfFee);
        console2.log("agent gain / owner gain:", agentGain, ownerGain);

        assertEq(ownerGain, expectedOwner, "vault owner's performance slice is wrong");
        assertEq(agentGain, expectedAgent, "agent's fee (management + performance remainder) is wrong");
        // Total outflow == total charged. A double charge or a fee-on-fee lands here.
        assertEq(agentGain + ownerGain, mgmtFee + perfFee, "fee outflow does not equal the fee charged");
        assertEq(governor.outstandingEscrow(address(vault), USDG), 0, "part of the fee escrowed rather than paid");

        // LPs are charged ONCE: the fee left the vault before the stamp, so the
        // exit they get is the post-fee NAV and nothing further is withheld.
        uint256 vaultAssets = _usdg(address(vault));
        assertEq(vault.totalAssets(), vaultAssets, "totalAssets diverged from balance post-fee");
        (uint256 redeemed1, uint256 out1) = _instantRedeemMax(lp1);
        (uint256 redeemed2, uint256 out2) = _instantRedeemMax(lp2);
        assertEq(redeemed1, lp1Shares, "lp1 could not fully exit post-fee");
        assertEq(redeemed2, lp2Shares, "lp2 could not fully exit post-fee");
        assertEq(out1 + out2 + _usdg(address(vault)), vaultAssets, "USDG conservation broken across the post-fee exit");
        assertLe(_usdg(address(vault)), DRAIN_DUST_WEI, "assets stranded after the post-fee drain");
        assertApproxEqAbs(
            _realizedPps(out1, lp1Shares),
            _realizedPps(out2, lp2Shares),
            PPS_EQUALITY_TOLERANCE,
            "fees were not charged pro rata across LPs"
        );
    }

    /// @dev `perfSplit().ownerBps`, read live from the protocol config the
    ///      governor snapshots — never hard-coded, so a config change does not
    ///      turn this suite into a green test of a stale constant.
    function _perfOwnerBps() internal view returns (uint256) {
        return IProtocolConfig(governor.protocolConfig()).perfSplit().ownerBps;
    }

    /// @dev Both fee events carry exactly `(uint256 amount, uint256 <base>)` as
    ///      their non-indexed data (`ManagementFeeCharged(pid, asset, amount,
    ///      assetSeconds)` / `PerformanceFeeCharged(pid, asset, amount,
    ///      aboveMark)`, first two params indexed). `count` is returned so
    ///      "charged once" is tested rather than assumed.
    function _readFeeEvent(Vm.Log[] memory logs, bytes32 topic)
        internal
        pure
        returns (uint256 amount, uint256 base, uint256 count)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                (amount, base) = abi.decode(logs[i].data, (uint256, uint256));
                unchecked {
                    ++count;
                }
            }
        }
    }
}
