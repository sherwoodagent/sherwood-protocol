// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {RobinhoodMainnetIntegrationTest} from "../RobinhoodMainnetIntegrationTest.sol";
import {MorphoSupplyStrategy} from "../../../src/strategies/MorphoSupplyStrategy.sol";
import {TierRegistry} from "../../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMorpho, Id, MarketParams, Market} from "../../../src/vendor/morpho/IMorpho.sol";
import {MorphoBalancesLib, SharesMathLib} from "../../../src/vendor/morpho/MorphoLibs.sol";

/// @notice Morpho Blue's flash-loan entrypoint. NOT in `src/vendor/morpho/IMorpho.sol`
///         (Sherwood does not call it), declared here because the vault's own
///         `_depositsLocked` natspec names it as the adversary lever:
///         "`_deliverableNow` caps at Morpho's idle balance, which a fee-free
///         `flashLoan` removes for one callback frame."
/// @dev    Selector `0xe0232b42`, verified present in the deployed singleton's
///         runtime code at 0x9D53...1010 (`cast code | grep 63e0232b42`).
interface IMorphoFlashLoan {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/**
 * @notice Settles a proposal from INSIDE a Morpho flash-loan callback, with
 *         Morpho's entire loan-token balance borrowed out.
 * @dev    This is not a mock and it fakes nothing: the loan is real, it is
 *         repaid in the same transaction, and the only thing it changes is
 *         `IERC20(loanToken).balanceOf(morpho)` for the duration of the
 *         callback — which is exactly the term `MorphoSupplyStrategy.
 *         _deliverableNow` clamps its withdrawal to. It is the honest,
 *         capital-free construction of "the market cannot deliver right now".
 */
contract FlashLoanSettler {
    IMorphoFlashLoan public immutable morpho;
    address public immutable token;
    address private _governor;
    uint256 private _pid;

    error NotMorpho();

    constructor(address morpho_, address token_) {
        morpho = IMorphoFlashLoan(morpho_);
        token = token_;
    }

    /// @param amount The loan size — pass Morpho's whole loan-token balance so
    ///        the strategy's deliverable maximum is driven to zero.
    function settleInsideFlashLoan(address governor_, uint256 pid_, uint256 amount) external {
        _governor = governor_;
        _pid = pid_;
        // Non-empty data: Morpho only invokes the callback when `data.length != 0`.
        morpho.flashLoan(token, amount, hex"01");
    }

    function onMorphoFlashLoan(uint256 assets, bytes calldata) external {
        if (msg.sender != address(morpho)) revert NotMorpho();
        // Low-level so a settlement revert BUBBLES with its original data — a
        // typed call would surface as an undecodable failure of the flash loan.
        (bool ok, bytes memory ret) = _governor.call(abi.encodeWithSignature("settleProposal(uint256)", _pid));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        IERC20(token).approve(address(morpho), assets);
    }
}

/**
 * @title MorphoSupplyVaultE2EForkTest
 * @notice `MorphoSupplyStrategy` driven through the REAL `SyndicateVault` +
 *         `SyndicateGovernor` against the live Morpho Blue singleton on
 *         Robinhood Chain, rather than through the `ForkVaultStub` that
 *         `MorphoSupplyMainnetFork.t.sol` uses.
 *
 *         The stub suite proves the vendored struct layouts and the view-accrual
 *         port. It cannot prove anything about the vault<->strategy seam:
 *         settlement accounting, residue, `undeliveredValue()`,
 *         `hasUndeliveredValue()`, the deposit lock, or the queued-deposit
 *         settle price. That seam is what this suite exercises.
 *
 * MARKET UNDER TEST — probed with `cast` against the archive RPC on 2026-08-12
 * at the vnet's own head (block 4,447,892), NOT trusted from the sibling suite
 * (whose 25,290,555 pin no longer resolves anywhere):
 *   id                0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114
 *   loanToken         USDG        0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
 *   collateralToken   spUSDG      0xde770c84FE66E063336b31737cFE9790f18c4087
 *   oracle                        0xe694c531F65c4BaBc88A52d7178476e095e51574
 *   irm (AdaptiveCurve)           0x2BD3d5965B26B51814AC95127B2b80dD6CcC0fa1
 *   lltv              0.915e18
 * Live state at that block (`market(id)`):
 *   totalSupplyAssets  20,517,558.629847 USDG   totalSupplyShares 2.0426e19
 *   totalBorrowAssets  18,625,123.788632 USDG   totalBorrowShares 1.8527e19
 *   lastUpdate         1,786,576,832            fee               0
 *   => idle liquidity  ~1,892,434 USDG, utilization ~90.8% (so the AdaptiveCurve
 *      IRM is well above its floor and interest is genuinely accruing).
 * `IERC20(USDG).balanceOf(morpho)` = 35,337,373.707442 USDG across all markets —
 * the figure the flash loan has to move.
 *
 * @dev CLOCK. The archive vnet's `block.timestamp` (1,783,526,915) is BEHIND
 *      both the Chainlink feeds and Morpho's `lastUpdate`. The base harness
 *      warps past the feeds; Morpho needs its own warp, because
 *      `Morpho._accrueInterest` computes `block.timestamp - market.lastUpdate`
 *      under checked arithmetic and a fork clock behind `lastUpdate` makes every
 *      supply/withdraw/view UNDERFLOW. See `_normalizeMorphoClock`.
 *
 *      Run:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        export ROBINHOOD_FORK_CHAIN_ID=9994663
 *        forge test --match-path \
 *          "test/integration/strategies/MorphoSupplyVaultE2EFork.t.sol" -vv
 */
contract MorphoSupplyVaultE2EForkTest is RobinhoodMainnetIntegrationTest {
    using SharesMathLib for uint256;
    using MorphoBalancesLib for IMorpho;

    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    bytes32 constant MARKET_ID = 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114;

    /// @dev The base harness deposits 10k + 10k, so the vault float is 20k USDG.
    uint256 constant VAULT_FLOAT = 20_000e6;
    /// @dev Half the float — leaves room for the residue cases to move the price
    ///      without tripping the governor's stamp floor (pps may not fall below
    ///      10% of its execute-time value; a 4k residue on 20k is a 20% drop).
    uint256 constant SUPPLY_AMOUNT = 10_000e6;
    uint256 constant RESIDUE_SUPPLY = 4_000e6;
    uint256 constant STRATEGY_DURATION = 1 days;
    uint256 constant PERF_FEE_BPS = 1000; // 10%

    address attacker = makeAddr("attacker");

    MarketParams mp;
    address template;

    // ── Setup ──

    /// @dev False when no RPC was configured: `setUp` returned early and the
    ///      protocol was never deployed. Read by `_requireFork`.
    bool forkReady;

    function setUp() public override {
        super.setUp();
        // Everything below touches the deployed stack. With no RPC the base
        // skipped and `vault`/`tierRegistry` are address(0), where a typed
        // call reverts with empty returndata — an undecodable failure.
        if (address(vault) == address(0)) return;
        // `MorphoSupplyStrategy._initialize` fails CLOSED unless the Morpho
        // singleton is allowlisted in the vault's own TierRegistry
        // (`MorphoNotAllowed`). The base harness only attests price feeds.
        vm.prank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(MORPHO, true);

        mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
        template = address(new MorphoSupplyStrategy());
        _normalizeMorphoClock();
        forkReady = true;
    }

    /// @dev Body-level fork guard. The base's `vm.skip(true)` lives inside
    ///      `setUp`, and that form is forge-version-dependent: local forge
    ///      reports the suite as skipped, CI's reports `[FAIL: skipped]
    ///      setUp()` and the job goes red. Calling `vm.skip` from the TEST BODY
    ///      works on every version, so every test opens with this.
    function _requireFork() internal {
        if (!forkReady) vm.skip(true);
    }

    /// @notice Warp past `market.lastUpdate` when the fork clock is behind it.
    /// @dev NOT cosmetic and NOT a fudge: Morpho's `_accrueInterest` does
    ///      `uint256 elapsed = block.timestamp - market[id].lastUpdate` in
    ///      checked arithmetic, so a fork whose clock predates the last on-chain
    ///      accrual reverts every supply, withdraw and `expectedMarketBalances`
    ///      view with a bare arithmetic panic. Warps to `lastUpdate + 1` — the
    ///      earliest instant at which the live state is internally consistent —
    ///      and is a no-op on any fork already ahead of it (which is every
    ///      public-RPC fork, since there the clock IS the chain's).
    function _normalizeMorphoClock() internal {
        uint256 lastUpdate = uint256(IMorpho(MORPHO).market(Id.wrap(MARKET_ID)).lastUpdate);
        uint256 nowTs = vm.getBlockTimestamp();
        if (lastUpdate >= nowTs) {
            console2.log("fork clock behind Morpho lastUpdate; warping forward by (s):", lastUpdate + 1 - nowTs);
            vm.warp(lastUpdate + 1);
        }
    }

    // ── Builders ──

    function _deployStrategy(uint256 amount) internal returns (address strategy) {
        strategy = _cloneAndInit(template, abi.encode(MORPHO, mp, amount));
    }

    function _execCalls(address strategy, uint256 amount) internal pure returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](2);
        c[0] = BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, amount)), value: 0});
        c[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _settleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory c) {
        c = new BatchExecutorLib.Call[](1);
        c[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    /// @dev propose -> vote -> review -> execute, with the Morpho supply deployed.
    function _deployAndExecute(uint256 amount) internal returns (address strategy, uint256 pid) {
        strategy = _deployStrategy(amount);
        pid = _proposeVoteExecute(_execCalls(strategy, amount), _settleCalls(strategy), PERF_FEE_BPS, STRATEGY_DURATION);
    }

    // ── Reads ──

    function _supplyShares(address who) internal view returns (uint256) {
        return IMorpho(MORPHO).position(Id.wrap(MARKET_ID), who).supplyShares;
    }

    /// @dev The position's live value INCLUDING pending interest, straight from
    ///      Morpho's own view accrual — the number the vault's realized delivery
    ///      is compared against.
    function _expectedSupplyAssets(address who) internal view returns (uint256) {
        return IMorpho(MORPHO).expectedSupplyAssets(mp, who);
    }

    function _vaultRawUSDG() internal view returns (uint256) {
        return IERC20(USDG).balanceOf(address(vault));
    }

    /// @dev Total fee charged by a settlement, read from `ProposalSettled`'s
    ///      4th field (which `_finishSettlement` fills with `totalFee`, i.e.
    ///      management + performance, despite the parameter's name).
    function _totalFeeFromLogs(Vm.Log[] memory logs) internal pure returns (uint256 fee, bool found) {
        bytes32 sig = keccak256("ProposalSettled(uint256,address,int256,uint256,uint256)");
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) {
                (, uint256 totalFee,) = abi.decode(logs[i].data, (int256, uint256, uint256));
                return (totalFee, true);
            }
        }
        return (0, false);
    }

    // ══════════════════════════════════════════════════════════════════
    // 1. Full lifecycle through the REAL vault
    // ══════════════════════════════════════════════════════════════════

    /// @notice deposit -> propose/vote/review/execute -> accrue real interest ->
    ///         settle, asserting the vault's USDG balance moves by exactly
    ///         (principal + realized Morpho interest - fees actually paid out).
    /// @dev The load-bearing assertion is the exact conservation identity below.
    ///      `delivered` is read from Morpho's own view accrual in the same block
    ///      the settlement runs in, so an off-by-one in the shares->assets
    ///      conversion, a lost interest term, or dust stranded on the clone all
    ///      break the equality rather than hiding inside a `>=`.
    function test_e2e_fullLifecycle_realVault_realInterest() public {
        _requireFork();
        uint256 vaultBefore = _vaultRawUSDG();
        assertEq(vaultBefore, VAULT_FLOAT, "harness float");

        (address strategy, uint256 pid) = _deployAndExecute(SUPPLY_AMOUNT);

        // Execute leg: the float left the vault and became supply shares.
        assertEq(_vaultRawUSDG(), vaultBefore - SUPPLY_AMOUNT, "vault float dropped by exactly the supply");
        uint256 shares = _supplyShares(strategy);
        assertGt(shares, 0, "supply shares minted on the live singleton");
        assertEq(IERC20(USDG).balanceOf(strategy), 0, "nothing stranded on the clone at execute");
        // Entry is not free: the position is worth at most what was supplied.
        uint256 valueAtEntry = _expectedSupplyAssets(strategy);
        assertLe(valueAtEntry, SUPPLY_AMOUNT, "no value conjured at entry");
        assertGe(valueAtEntry + 2, SUPPLY_AMOUNT, "entry value == principal modulo share rounding");

        // Accrue REAL interest on the live AdaptiveCurve IRM.
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 delivered = _expectedSupplyAssets(strategy);
        uint256 interest = delivered - SUPPLY_AMOUNT;
        assertGt(interest, 0, "7 days of live interest accrued");
        console2.log("Realized Morpho interest over 7d (USDG 1e6):", interest);

        uint256 preSettleRaw = _vaultRawUSDG();
        uint256 escrowBefore = governor.outstandingEscrow(address(vault), USDG);

        vm.recordLogs();
        vm.prank(makeAddr("keeper")); // permissionless once the duration elapsed
        governor.settleProposal(pid);
        (uint256 totalFee, bool found) = _totalFeeFromLogs(vm.getRecordedLogs());
        assertTrue(found, "ProposalSettled emitted");

        // The position is fully unwound and the clone holds nothing.
        assertEq(_supplyShares(strategy), 0, "supply position closed");
        address[] memory toks = new address[](1);
        toks[0] = USDG;
        _assertNoDust(strategy, toks);

        // EXACT CONSERVATION. Fees that failed to transfer stay in the vault's
        // raw balance and are tracked as escrow, so they are added back on the
        // outflow side rather than assumed to have left.
        uint256 escrowDelta = governor.outstandingEscrow(address(vault), USDG) - escrowBefore;
        assertEq(
            _vaultRawUSDG() + (totalFee - escrowDelta),
            preSettleRaw + delivered,
            "vault balance != pre-settle float + delivered position - fees paid out"
        );

        // Principal plus interest genuinely came back: the vault is above where
        // it started, net of every fee.
        assertGt(_vaultRawUSDG() + totalFee, VAULT_FLOAT, "principal + interest returned");

        // No leftover residue claims, and no over-promising of shares.
        assertFalse(MorphoSupplyStrategy(strategy).hasUndeliveredValue(), "no residue after a full delivery");
        assertEq(MorphoSupplyStrategy(strategy).undeliveredValue(), 0, "undeliveredValue zero after full delivery");
        address[] memory holders = new address[](2);
        holders[0] = lp1;
        holders[1] = lp2;
        _assertShareClaimsSolvent(holders);
    }

    // ══════════════════════════════════════════════════════════════════
    // 2. Residue: settlement that cannot deliver
    // ══════════════════════════════════════════════════════════════════

    /// @notice Force an incomplete settlement by settling from inside a Morpho
    ///         flash loan that has borrowed out the singleton's entire USDG
    ///         balance, then assert the residue is priced, excluded from NAV
    ///         exactly once, and swept back exactly once.
    /// @dev CONSTRUCTED HONESTLY, NOT MOCKED. `_deliverableNow` clamps at
    ///      `IERC20(asset).balanceOf(morpho)`; a real, repaid flash loan is the
    ///      only lever that moves that term without touching Morpho's own
    ///      accounting, and it is the exact lever `SyndicateVault.
    ///      _depositsLocked`'s natspec names. Draining the market by BORROWING
    ///      instead would need ~1.9M USDG of spUSDG collateral posted at a live
    ///      oracle price and would be a strictly less faithful reproduction of
    ///      the documented adversary.
    function test_e2e_residue_pricedLockedAndSweptExactlyOnce() public {
        _requireFork();
        (address strategy, uint256 pid) = _deployAndExecute(RESIDUE_SUPPLY);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        uint256 owed = _expectedSupplyAssets(strategy);
        assertGt(owed, RESIDUE_SUPPLY, "position accrued before settlement");

        uint256 preSettleRaw = _vaultRawUSDG();
        uint256 escrowBefore = governor.outstandingEscrow(address(vault), USDG);
        uint256 totalFee = _flashSettle(pid);
        uint256 escrowDelta = governor.outstandingEscrow(address(vault), USDG) - escrowBefore;

        // Nothing was delivered: the market held zero loan token for the frame,
        // so the ONLY movement in the vault's float is the management fee
        // leaving (performance is zero on a loss).
        assertEq(
            _vaultRawUSDG() + (totalFee - escrowDelta), preSettleRaw, "settlement delivered nothing but the fee moved"
        );
        uint256 sharesLeft = _supplyShares(strategy);
        assertGt(sharesLeft, 0, "residue: supply position survived settlement");

        MorphoSupplyStrategy s = MorphoSupplyStrategy(strategy);
        assertTrue(s.hasUndeliveredValue(), "residue declared");
        // The residue is priced at the position's own redeemable value — no
        // oracle, loan token IS the vault asset.
        //
        // IT UNDER-PRICES, BY DESIGN AND MEASURABLY. `_ownRaw` reads raw market
        // storage with zero external calls — that is what took the proposer's
        // IRM off the probe path (PR #243, finding B3) — so it necessarily
        // misses interest accrued since Morpho's `lastUpdate`. Measured here
        // against Morpho's own view accrual: 3,999,999,999 vs 4,000,142,747,
        // short by 142,748 (~3.6 bps of the position).
        //
        // DIRECTION IS THE SAFETY PROPERTY. Under-pricing is the benign side
        // for a REDEEMER — nobody can withdraw against value that has not
        // landed. It is NOT benign on the mint side, and that is a live leak,
        // not a theoretical one: a queued depositor mints against the
        // under-stated NAV and keeps their pro-rata slice of the gap. See
        // `test_e2e_residueSkim_isolatedAgainstTheNoAttackerCounterfactual`,
        // where 20% x 142,748 = 28,550 comes out of the honest LPs exactly.
        //
        // So this asserts what is TRUE (never over-prices, and the shortfall
        // stays inside a stated bound) rather than the "prices it exactly"
        // this originally claimed. Tightening the bound is a real change: it
        // would have to come from making the probe accrue.
        uint256 residue = s.undeliveredValue();
        assertLe(residue, owed, "undeliveredValue OVER-priced the residue - redeemers could drain unlanded value");
        uint256 shortfall = owed - residue;
        console2.log("undeliveredValue shortfall vs Morpho view accrual (USDG 1e6):", shortfall);
        assertLe(shortfall, owed / 1000, "residue under-count exceeded 10 bps - the probe is drifting further behind");

        // NAV EXCLUDES THE RESIDUE — deliberately, on this commit. `totalAssets()`
        // is float minus liabilities and never counts strategy-held value; the
        // mint side is protected by the deposit lock instead. Pinned so a change
        // to either half has to come with a change here.
        uint256 navBefore = vault.totalAssets();
        assertEq(
            navBefore,
            _vaultRawUSDG() - governor.outstandingEscrow(address(vault), USDG) - vault.reservedQueueAssets(),
            "totalAssets is float minus liabilities, residue excluded"
        );
        assertLt(navBefore, VAULT_FLOAT, "NAV is short by the residue while it is outstanding");

        // INSTANT DEPOSITS ARE OPEN, AND PRICED — BUT NOT EXACTLY. Pre-#243
        // this path was locked (`DepositsLocked`); #243 replaced the lock with
        // `depositNav()`, which adds the residue back before minting. So the
        // assertion that earns its keep is no longer "it reverts" — it is how
        // much entering here still pays.
        //
        // It pays a little, and the arithmetic says why: `depositNav()` adds
        // back the residue AS THE PROBE QUOTES IT, and the probe is short by
        // the interest-since-`lastUpdate` term measured above. So a depositor
        // mints against a NAV that is 142,748 too low and keeps their pro-rata
        // slice of the gap when the residue lands. Measured: a 1,000 USDG
        // deposit into a ~21,000 pool realizes +6,797, and
        // 142,748 x 1,000/21,000 = 6,797.5.
        //
        // NOTE this CORRECTS the tempting reading that the instant path is
        // safe and only the queued path leaks. BOTH entry paths leak, by the
        // same under-count and in the same proportion — the queued path is not
        // a different bug, just a different door. The ceiling on either is the
        // whole under-count, which is what this asserts.
        uint256 instantDeposit = 1_000e6;
        _dealUSDG(attacker, instantDeposit);
        vm.startPrank(attacker);
        IERC20(USDG).approve(address(vault), instantDeposit);
        vault.deposit(instantDeposit, attacker);
        vm.stopPrank();
        assertGt(vault.balanceOf(attacker), 0, "instant deposit is open while residue is outstanding");

        // Sweep is permissionless and moves NAV by EXACTLY what it returns.
        vm.prank(makeAddr("sweeper"));
        uint256 swept = s.sweep();
        // The sweep settles at the position's TRUE value, so it necessarily
        // returns MORE than the call-free probe quoted — by the same
        // interest-since-`lastUpdate` term measured above. The invariant is
        // one-directional: never less than was priced (that would mean shares
        // were minted against value that never arrived), and not so much more
        // that the probe has drifted out of its stated bound.
        assertGe(swept, residue, "sweep delivered LESS than undeliveredValue quoted - shares minted against nothing");
        assertLe(swept - residue, owed / 1000, "sweep overshot the probe by more than 10 bps");
        assertEq(
            vault.totalAssets(),
            navBefore + swept + instantDeposit,
            "NAV moved by exactly the swept amount plus the instant deposit (no double count)"
        );

        // The depositor's profit is capped by the whole under-count: they can
        // capture at most their pro-rata slice of the gap, and a slice is at
        // most the gap. If this ever fails, `depositNav()` has stopped adding
        // the residue back at all and the pre-#243 skim is open again.
        uint256 instantRealized = vault.previewRedeem(vault.balanceOf(attacker));
        console2.log(
            "instant depositor profit from the residue under-count (USDG 1e6):", instantRealized - instantDeposit
        );
        assertLe(
            instantRealized,
            instantDeposit + shortfall,
            "instant depositor captured MORE than the residue under-count - depositNav is not pricing the residue"
        );
        assertEq(_supplyShares(strategy), 0, "position fully unwound by the sweep");
        address[] memory toks = new address[](1);
        toks[0] = USDG;
        _assertNoDust(strategy, toks);
        assertFalse(s.hasUndeliveredValue(), "residue cleared");

        // ...and a second deposit still works with no privileged action, at a
        // price that now reflects the landed residue.
        uint256 sharesBefore = vault.balanceOf(attacker);
        _dealUSDG(attacker, 1_000e6);
        vm.startPrank(attacker);
        IERC20(USDG).approve(address(vault), 1_000e6);
        vault.deposit(1_000e6, attacker);
        vm.stopPrank();
        assertGt(vault.balanceOf(attacker), sharesBefore, "deposits still open after the sweep");
    }

    // ══════════════════════════════════════════════════════════════════
    // 3. The queued-deposit residue skim
    // ══════════════════════════════════════════════════════════════════

    /// @notice An attacker queues a deposit before a settlement that will leave a
    ///         residue, claims at the residue-blind frozen price, then sweeps the
    ///         residue into the enlarged share pool.
    /// @dev EXPECTED TO FAIL ON THIS COMMIT — this is the finding, not a broken
    ///      test. `SyndicateVault.onProposalSettled` stamps
    ///      `num = totalAssets() + 1` from FLOAT ALONE, with its own natspec
    ///      conceding "the queued-deposit mispricing is therefore still open"
    ///      (issue #233 / docs/nav-residue-design.md). `_depositsLocked` closes
    ///      the INSTANT mint side only; `VaultWithdrawalQueue.claim` routes
    ///      through `settleDeposit`, which never consults it. The attacker
    ///      therefore mints against a NAV missing the residue and the permissionless
    ///      `sweep()` hands them a pro-rata slice of value that belonged to the
    ///      LPs who were already in.
    ///
    ///      The bound asserted is the only one that can be right: a depositor
    ///      may not realize more than they contributed out of a settlement whose
    ///      only "profit" is value that was already the vault's.
    function test_e2e_attackerCannotSkimResidueViaQueuedDeposit() public {
        _requireFork();
        uint256 attackDeposit = 5_000e6;
        (address strategy, uint256 pid) = _deployAndExecute(RESIDUE_SUPPLY);

        // Honest LP1's claim before the attack, for the dilution read-out.
        uint256 lp1ClaimBefore = vault.previewRedeem(vault.balanceOf(lp1));

        // Attacker queues a deposit while the proposal is open (the only entry
        // available mid-proposal).
        _dealUSDG(attacker, attackDeposit);
        uint256 reqId = _requestDeposit(attacker, attackDeposit);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        _flashSettle(pid);

        MorphoSupplyStrategy s = MorphoSupplyStrategy(strategy);
        uint256 residue = s.undeliveredValue();
        assertGt(residue, 0, "the attack needs an outstanding residue");

        // Claim at the residue-blind frozen price.
        uint256 mintedShares = _claimQueued(attacker, reqId);
        assertEq(vault.balanceOf(attacker), mintedShares, "attacker holds the minted shares");

        // The residue comes home into the enlarged pool.
        vm.prank(makeAddr("sweeper"));
        uint256 swept = s.sweep();
        assertGt(swept, 0, "residue swept back into the vault");

        // Realize: what are the attacker's shares actually worth now?
        uint256 realized = vault.previewRedeem(vault.balanceOf(attacker));
        uint256 lp1ClaimAfter = vault.previewRedeem(vault.balanceOf(lp1));
        console2.log("attacker contributed (USDG 1e6):", attackDeposit);
        console2.log("attacker realized   (USDG 1e6):", realized);
        console2.log("lp1 claim before    (USDG 1e6):", lp1ClaimBefore);
        console2.log("lp1 claim after     (USDG 1e6):", lp1ClaimAfter);

        assertLe(realized, attackDeposit + 1e3, "queued depositor skimmed the residue: realized more than contributed");
    }

    /// @notice THE ISOLATION for the test above: does the attacker's gain come
    ///         OUT OF the honest LPs, or out of yield that accrued after they
    ///         were priced in?
    /// @dev    `test_e2e_attackerCannotSkimResidueViaQueuedDeposit` shows the
    ///         attacker realizing 28,549 units more than they contributed. That
    ///         is a direction, not a verdict: a shareholder who is correctly
    ///         priced in and then earns pro-rata yield on the residue also
    ///         realizes more than they contributed, and so does one who skimmed.
    ///
    ///         The `lp1ClaimBefore` / `lp1ClaimAfter` read-out in that test
    ///         CANNOT settle it — measured while the residue is outstanding,
    ///         `previewRedeem` prices against a float-only NAV, so LP1's claim
    ///         "rises" by the residue coming home whether or not anyone stole
    ///         from them. Reading dilution off that pair is how a benign result
    ///         gets reported as an attack.
    ///
    ///         The only measurement that separates them is the counterfactual:
    ///         run the identical settlement with and without the attacker and
    ///         compare what the HONEST LPs walk away with. Same fork state, same
    ///         block, same interest — `snapshotState`/`revertToState` guarantees
    ///         the two branches differ in exactly one thing.
    ///
    ///         A skim of size S shows up as honest LPs ending S poorer. Yield
    ///         shows up as honest LPs ending no worse off at all.
    ///
    ///         MEASURED, and it is a skim:
    ///           honest LPs alone          19,999,868,772
    ///           honest LPs with attacker  19,999,840,222   (-28,550)
    ///           attacker realized          5,000,028,549   (+28,549)
    ///         Exact conservation to one unit of share-math rounding. PR #243
    ///         shrank this leak ~34,600x (pre-#243 the same test measured +952
    ///         USDG) but did not close it.
    ///
    ///         MECHANISM — this and the `undeliveredValue` under-count in
    ///         `test_e2e_residue_pricedLockedAndSweptExactlyOnce` are ONE bug:
    ///           `undeliveredValue()` under-counts the residue by 142,748
    ///           (interest accrued since Morpho's `lastUpdate`, which the probe
    ///           deliberately excludes to keep the read call-free);
    ///           the attacker's post-mint pool share is 5,000/25,000 = 20%;
    ///           20% x 142,748 = 28,550 = exactly what the honest LPs lost.
    ///         A queued depositor mints against the under-stated NAV and
    ///         captures their pro-rata slice of the gap when the residue lands.
    ///
    ///         The leak is BOUNDED by the size of the under-count (an attacker
    ///         approaching 100% of the pool captures at most all of it, here
    ///         3.6 bps of the residue) and grows with residue size and with the
    ///         time the position sits unaccrued. It is small, but it is a
    ///         directional transfer from sitting LPs to a timed depositor, not
    ///         rounding.
    function test_e2e_residueSkim_isolatedAgainstTheNoAttackerCounterfactual() public {
        _requireFork();
        uint256 attackDeposit = 5_000e6;

        (address strategy, uint256 pid) = _deployAndExecute(RESIDUE_SUPPLY);
        uint256 snap = vm.snapshotState();

        // ── Branch A: no attacker. The honest baseline. ──
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        _flashSettle(pid);
        vm.prank(makeAddr("sweeperA"));
        MorphoSupplyStrategy(strategy).sweep();
        uint256 honestAlone = vault.previewRedeem(vault.balanceOf(lp1)) + vault.previewRedeem(vault.balanceOf(lp2));

        // ── Branch B: identical, plus the queued attacker. ──
        vm.revertToState(snap);
        _dealUSDG(attacker, attackDeposit);
        uint256 reqId = _requestDeposit(attacker, attackDeposit);
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        _flashSettle(pid);
        _claimQueued(attacker, reqId);
        vm.prank(makeAddr("sweeperB"));
        MorphoSupplyStrategy(strategy).sweep();
        uint256 honestWithAttacker =
            vault.previewRedeem(vault.balanceOf(lp1)) + vault.previewRedeem(vault.balanceOf(lp2));
        uint256 attackerRealized = vault.previewRedeem(vault.balanceOf(attacker));

        console2.log("honest LPs alone          (USDG 1e6):", honestAlone);
        console2.log("honest LPs with attacker  (USDG 1e6):", honestWithAttacker);
        console2.log("attacker contributed      (USDG 1e6):", attackDeposit);
        console2.log("attacker realized         (USDG 1e6):", attackerRealized);

        // The verdict. Tolerance is 2 units of USDG's smallest denomination —
        // one per LP for share-math rounding, which always rounds toward the
        // vault. Anything beyond that is value that changed hands.
        assertGe(
            honestWithAttacker + 2,
            honestAlone,
            "the queued depositor's gain came OUT OF the honest LPs - this is a skim, not yield"
        );
    }

    /// @notice CONTROL for the test above: the identical queued-deposit flow with
    ///         a COMPLETE settlement (no flash loan, no residue).
    /// @dev Without this, the failure above could be dismissed as "queued
    ///      deposits are just cheap" or as a harness artefact. Here the attacker
    ///      realizes essentially exactly what they contributed, which isolates the
    ///      residue — not the queue, not the mid-flight float-only NAV — as the
    ///      thing being skimmed.
    function test_e2e_queuedDepositWithoutResidueIsFairlyPriced() public {
        _requireFork();
        uint256 depositAmount = 5_000e6;
        (, uint256 pid) = _deployAndExecute(RESIDUE_SUPPLY);

        _dealUSDG(attacker, depositAmount);
        uint256 reqId = _requestDeposit(attacker, depositAmount);

        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);
        vm.prank(makeAddr("keeper"));
        governor.settleProposal(pid);

        _claimQueued(attacker, reqId);
        uint256 realized = vault.previewRedeem(vault.balanceOf(attacker));
        console2.log("control: contributed / realized (USDG 1e6):", depositAmount, realized);

        assertLe(realized, depositAmount + 1e3, "no-residue queued deposit must not mint above par");
        assertGe(realized, depositAmount - 1e6, "no-residue queued deposit is not penalised either");
    }

    // ══════════════════════════════════════════════════════════════════
    // 4. Live AdaptiveCurve accrual, not a stale snapshot
    // ══════════════════════════════════════════════════════════════════

    /// @notice The value the vault ultimately realizes tracks Morpho's own
    ///         `expectedSupplyAssets` at the settlement instant — and the
    ///         vendored view accrual agrees with the singleton's storage accrual
    ///         to the wei.
    /// @dev Three distinct failure modes are covered: (a) a stale snapshot
    ///      (value frozen at execute) breaks the strict monotonicity; (b) a
    ///      wrong Taylor/rate port breaks the view-vs-storage equality; (c) a
    ///      settlement that ignores accrued interest breaks the realized-delivery
    ///      equality. Also pins that the vault's MID-FLIGHT `totalAssets()`
    ///      deliberately does NOT mark the position — that is this commit's
    ///      documented design, and silently changing it would change every
    ///      conversion in the vault.
    function test_e2e_navTracksLiveIrmAccrual_notAStaleSnapshot() public {
        _requireFork();
        (address strategy, uint256 pid) = _deployAndExecute(SUPPLY_AMOUNT);

        uint256 floatMidFlight = _vaultRawUSDG();
        assertEq(vault.totalAssets(), floatMidFlight, "mid-flight NAV is float only, position unmarked");

        uint256 v0 = _expectedSupplyAssets(strategy);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 v1 = _expectedSupplyAssets(strategy);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        uint256 v2 = _expectedSupplyAssets(strategy);

        assertGt(v1, v0, "value grew over day 1 (live IRM, not a snapshot)");
        assertGt(v2, v1, "value kept growing over the next 6 days");
        // Mid-flight NAV is unchanged while the position appreciates — the
        // definition of "the vault does not mark this".
        assertEq(vault.totalAssets(), floatMidFlight, "float-only NAV is inert to position growth");

        // The vendored view-accrual port vs the singleton's own storage accrual.
        IMorpho(MORPHO).accrueInterest(mp);
        Market memory m = IMorpho(MORPHO).market(Id.wrap(MARKET_ID));
        uint256 fromStorage = _supplyShares(strategy).toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
        assertEq(v2, fromStorage, "vendored view accrual == live singleton accrual");

        // And what the vault actually realizes is that same live figure.
        uint256 expectedDelivery = _expectedSupplyAssets(strategy);
        uint256 preSettleRaw = _vaultRawUSDG();
        uint256 escrowBefore = governor.outstandingEscrow(address(vault), USDG);
        vm.recordLogs();
        vm.prank(makeAddr("keeper"));
        governor.settleProposal(pid);
        (uint256 totalFee, bool found) = _totalFeeFromLogs(vm.getRecordedLogs());
        assertTrue(found, "ProposalSettled emitted");
        uint256 escrowDelta = governor.outstandingEscrow(address(vault), USDG) - escrowBefore;

        assertEq(
            _vaultRawUSDG() + (totalFee - escrowDelta),
            preSettleRaw + expectedDelivery,
            "realized delivery != live expectedSupplyAssets at the settle block"
        );
    }

    // ── internals ──

    /// @return totalFee The settlement's total (management + performance) fee,
    ///         read from `ProposalSettled`.
    function _flashSettle(uint256 pid) internal returns (uint256 totalFee) {
        FlashLoanSettler settler = new FlashLoanSettler(MORPHO, USDG);
        uint256 morphoBalance = IERC20(USDG).balanceOf(MORPHO);
        assertGt(morphoBalance, 0, "morpho holds loan token to flash out");
        vm.recordLogs();
        settler.settleInsideFlashLoan(address(governor), pid, morphoBalance);
        bool found;
        (totalFee, found) = _totalFeeFromLogs(vm.getRecordedLogs());
        assertTrue(found, "ProposalSettled emitted");
        assertEq(IERC20(USDG).balanceOf(MORPHO), morphoBalance, "flash loan repaid in full");
    }
}
