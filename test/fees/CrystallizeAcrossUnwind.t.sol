// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @notice A strategy whose mid-exit unwind is NOT price-neutral, which is what
///         makes it useful here. Two independent knobs, each modelling a
///         production shape the vault has to survive:
///
///           `idle`  — vault-asset sitting on the strategy that `positions()`
///                     does not report, so the router cannot price it (sale
///                     proceeds awaiting redeployment). A pull surfaces it: it
///                     leaves an unpriced strategy balance and lands in priced
///                     vault float, so NAV RISES across the pull even though
///                     nothing was earned.
///
///           `blind` — the basket stops pricing once liquidated. Models the two
///                     reachable triggers: a PortfolioStrategy that sold out so
///                     every position prices to 0, and a MorphoSupplyStrategy
///                     full-position pull whose sub-unit share residue rounds
///                     to 0 assets. Both make `PriceRouter.valueStrategy` take
///                     its `total == 0 → (0, false)` branch.
contract MockUnwindingStrategy {
    ERC20Mock public immutable asset;
    address public immutable vault;

    uint256 public idle;
    bool public blind;
    bool public unwound;

    constructor(ERC20Mock asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    /// @dev Park `amount` of the strategy's balance outside `positions()`.
    ///      The caller mints the tokens to this contract first.
    function parkIdle(uint256 amount) external {
        idle += amount;
    }

    function setBlind(bool b) external {
        blind = b;
    }

    function availableLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev `IStrategy.withdrawTo(uint256)`. Idle proceeds are spent first (a
    ///      strategy sells nothing it does not have to); anything beyond them
    ///      liquidates the basket.
    function withdrawTo(uint256 assets) external {
        uint256 fromIdle = assets > idle ? idle : assets;
        idle -= fromIdle;
        if (assets > fromIdle) unwound = true;
        asset.transfer(vault, assets);
    }

    /// @dev What `PriceRouter.valueStrategy` would total across `positions()`.
    function positionValue() external view returns (uint256) {
        if (unwound && blind) return 0;
        uint256 bal = asset.balanceOf(address(this));
        return bal > idle ? bal - idle : 0;
    }
}

/// @notice Reproduces `PriceRouter.valueStrategy` faithfully enough for the
///         edge under test — in particular its `total == 0 → (0, false)`
///         branch, the one that flips Lane A off mid-transaction.
contract MockUnwindRouter {
    MockUnwindingStrategy public strategy;
    bool public ok;

    function set(MockUnwindingStrategy strategy_, bool ok_) external {
        strategy = strategy_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        if (!ok || address(strategy) == address(0)) return (0, false);
        uint256 v = strategy.positionValue();
        if (v == 0) return (0, false);
        return (v, true);
    }
}

/// @notice Regression cover for audit findings #10 and #12, both in
///         `SyndicateVault._withdraw`.
///
///         The invariant every test here states one way or another: THE FEE
///         BOOKED TO THE RECIPIENTS IS EXACTLY THE FEE WITHHELD FROM THE
///         EXITER, both measured against the same pre-pull state that
///         `previewRedeem` quoted.
///
///         #10 — the Lane A flag was re-read AFTER `_pullFromStrategy`. An exit
///               big enough to empty the basket had its fees deducted by
///               `previewRedeem` and then crystallized nothing, leaving the
///               withheld assets in the vault as a windfall to the LPs who
///               stayed and shortchanging the fee recipients by exactly that.
///
///         #12 — `_exitFees(shares)` was recomputed AFTER the pull, i.e. at a
///               share price the exiter was never quoted. The pull is not
///               NAV-neutral, so the booked fee could exceed what was actually
///               withheld, with the difference coming out of the LPs who stayed.
contract CrystallizeAcrossUnwindTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockUnwindRouter internal router;
    MockUnwindingStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant MOCK_GOVERNOR = address(0xF00D);
    uint256 internal constant PID = 1;

    uint256 internal constant MGMT_BPS = 200; // 2%/yr, observable over 30 days

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockUnwindRouter();

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        // The governor's per-vault performance ceiling, read by `_exitFees`.
        ISyndicateGovernor.GovernorParams memory gp;
        gp.maxPerformanceFeeBps = 2000;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getGovernorParams()"), abi.encode(gp));

        for (uint256 i = 0; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            usdc.mint(who, 10_000_000e6);
        }
    }

    /// @dev The management rate is fixed at `initialize`, so each test picks the
    ///      fee legs it wants to isolate and deploys its own vault.
    function _deploy(uint256 mgmtBps, uint16 penaltyBps) internal {
        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "V",
                    symbol: "V",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: mgmtBps
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        strategy = new MockUnwindingStrategy(usdc, address(vault));

        vm.prank(owner);
        vault.setInstantExitFeeBps(penaltyBps);

        _setLocked(false);

        for (uint256 i = 0; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            vm.prank(who);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function _setLocked(bool locked) internal {
        vm.mockCall(
            MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(locked ? PID : uint256(0))
        );
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(locked ? uint256(1) : 0));
        if (locked) {
            ISyndicateGovernor.StrategyProposal memory p;
            p.id = PID;
            p.vault = address(vault);
            p.strategy = address(strategy);
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p)
            );
            // `_laneState` resolves the active strategy through the lighter
            // `strategyOf(pid)` getter, not `getProposal`.
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(address(strategy))
            );
        }
    }

    /// @dev Open Lane A with `deployed` of the vault's float moved into the
    ///      strategy basket, the rest left as idle vault float.
    function _openLaneA(uint256 deployed) internal {
        vm.prank(address(vault));
        usdc.transfer(address(strategy), deployed);
        _setLocked(true);
        router.set(strategy, true);
    }

    function _startAccrual() internal {
        vm.prank(MOCK_GOVERNOR);
        vault.startManagementAccrual();
    }

    // ── #10: the exit that closes Lane A on its way out ──

    /// @notice An exit large enough to empty the basket still books the fees it
    ///         was charged.
    ///
    ///         Adversary: an LP sizes their exit so the unwind leaves the
    ///         strategy with nothing priceable. `PriceRouter.valueStrategy`
    ///         answers `(0, false)` from that point on, so a Lane A flag read
    ///         after the pull says "Lane B" — and the fees `previewRedeem`
    ///         already withheld from this very exiter are never recorded. The
    ///         assets sit in the vault as a windfall to whoever stays, and the
    ///         fee recipients are shortchanged by the full amount.
    function test_anExitThatClosesLaneAStillBooksTheFeesItWasCharged() public {
        _deploy(MGMT_BPS, 0);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA(1_900_000e6); // 100k float, 1.9M in the basket
        _startAccrual();
        // The unwind sells the basket out and the leftovers stop pricing — a
        // PortfolioStrategy with no positions left, or a Morpho sub-unit share
        // residue. That is what takes the router's `total == 0` branch.
        strategy.setBlind(true);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(bob);
        uint256 gross = vault.convertToAssets(shares);
        (uint256 quotedMgmt, uint256 quotedPerf) = vault.previewExitFees(shares);
        uint256 quoted = vault.previewRedeem(shares);
        assertGt(quotedMgmt, 0, "the exiter must be quoted a management fee");
        assertEq(gross - quoted, quotedMgmt + quotedPerf, "with no penalty, the withholding IS the fee");

        uint256 balanceBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        // The exit did what it was built to do: Lane A is closed behind it.
        assertEq(strategy.positionValue(), 0, "the basket must price to 0 after the unwind");
        uint256 probe = vault.balanceOf(alice);
        (uint256 afterMgmt, uint256 afterPerf) = vault.previewExitFees(probe);
        assertEq(afterMgmt + afterPerf, 0, "Lane A must be shut, or this test proves nothing");

        assertEq(usdc.balanceOf(bob) - balanceBefore, quoted, "delivered must equal quoted");
        assertEq(vault.crystallizedMgmt(), quotedMgmt, "the withheld management fee must be booked");
        assertEq(vault.crystallizedPerf(), quotedPerf, "the withheld performance fee must be booked");
    }

    /// @notice The core invariant stated directly, across the same Lane-A-closing
    ///         exit: booked == withheld, to the wei.
    function test_theBookedFeeEqualsTheWithheldFeeAcrossAClosingExit() public {
        _deploy(MGMT_BPS, 0);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA(1_900_000e6); // 100k float, 1.9M in the basket
        _startAccrual();
        strategy.setBlind(true);
        // Above the mark, so the performance leg is live too.
        usdc.mint(address(strategy), 400_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(bob);
        uint256 gross = vault.convertToAssets(shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 withheld = gross - quoted;
        (, uint256 quotedPerf) = vault.previewExitFees(shares);
        assertGt(quotedPerf, 0, "above the mark, performance is owed");

        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        uint256 probe = vault.balanceOf(alice);
        (uint256 afterMgmt, uint256 afterPerf) = vault.previewExitFees(probe);
        assertEq(afterMgmt + afterPerf, 0, "Lane A must be shut, or this test proves nothing");

        assertEq(
            vault.crystallizedMgmt() + vault.crystallizedPerf(),
            withheld,
            "the recipients must be booked exactly what the exiter was charged"
        );
    }

    // ── #12: the pull is not NAV-neutral ──

    /// @notice An exit whose unwind RAISES the vault's NAV must still book only
    ///         what it withheld.
    ///
    ///         Adversary: a strategy holding vault-asset that `positions()` does
    ///         not report. Pulling moves that balance out of an unpriced venue
    ///         into priced vault float, so the vault's own price per share jumps
    ///         across the pull without a cent being earned. Pricing the
    ///         recipients' side after the pull books them a performance fee the
    ///         exiter was never quoted, and the excess comes straight out of the
    ///         LPs who stayed.
    ///
    ///         Lane A is deliberately still OPEN at the end here, which is what
    ///         separates this from the #10 cases: latching the flag alone does
    ///         not fix it, the fee AMOUNT has to be latched too.
    function test_aPullThatRaisesNavStillBooksOnlyWhatItWithheld() public {
        _deploy(0, 0); // performance leg only, no penalty

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA(2_000_000e6); // everything deployed: any exit must pull
        // A real gain, priced by the router.
        usdc.mint(address(strategy), 400_000e6);
        // And unpriced sale proceeds the router cannot see.
        usdc.mint(address(strategy), 300_000e6);
        strategy.parkIdle(300_000e6);

        uint256 navBefore = vault.totalAssets();
        assertEq(navBefore, 2_400_000e6, "the parked proceeds must be invisible to NAV");

        uint256 shares = vault.balanceOf(bob);
        uint256 gross = vault.convertToAssets(shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 withheld = gross - quoted;
        (uint256 quotedMgmt, uint256 quotedPerf) = vault.previewExitFees(shares);
        assertEq(quotedMgmt, 0, "no management fee configured");
        assertGt(quotedPerf, 0, "above the mark, performance is owed");
        assertEq(withheld, quotedPerf, "with no penalty, the withholding IS the fee");

        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        // The pull surfaced the parked proceeds, so the post-pull price per
        // share is strictly above the one bob was quoted against.
        assertGt(
            usdc.balanceOf(address(vault)) + strategy.positionValue(),
            navBefore - quoted,
            "the pull must have raised NAV, or this test proves nothing"
        );
        uint256 probe = vault.balanceOf(alice);
        (, uint256 stillOwed) = vault.previewExitFees(probe);
        assertGt(stillOwed, 0, "Lane A must still be open, or this is the #10 case");

        assertEq(vault.crystallizedPerf(), quotedPerf, "booked must equal withheld, not the post-pull recompute");
        assertEq(vault.crystallizedMgmt(), 0, "no management leg to book");
    }

    /// @notice The same invariant with the early-exit penalty switched on. The
    ///         penalty is fund money, so it must not leak into the recipients'
    ///         ledger: what gets booked is the withholding MINUS the penalty,
    ///         exactly, even though Lane A shuts on the way out.
    function test_thePenaltyStaysWithTheFundWhenLaneAClosesMidExit() public {
        _deploy(MGMT_BPS, 200); // 2% penalty, the enablement rate

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA(1_900_000e6);
        _startAccrual();
        strategy.setBlind(true);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(bob);
        uint256 gross = vault.convertToAssets(shares);
        (uint256 quotedMgmt, uint256 quotedPerf) = vault.previewExitFees(shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 penalty = gross - quoted - quotedMgmt - quotedPerf;
        assertGt(penalty, 0, "the penalty must be live for this test to mean anything");

        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        uint256 probe = vault.balanceOf(alice);
        (uint256 afterMgmt, uint256 afterPerf) = vault.previewExitFees(probe);
        assertEq(afterMgmt + afterPerf, 0, "Lane A must be shut, or this test proves nothing");

        assertEq(vault.crystallizedMgmt(), quotedMgmt, "recipients get the fee");
        assertEq(vault.crystallizedPerf(), quotedPerf, "and only the fee");
        uint256 parked = vault.crystallizedMgmt() + vault.crystallizedPerf();
        assertEq(gross - quoted - parked, penalty, "the penalty never reaches a recipient");
    }

    // ── Crystallized fees are settled-only ──

    /// @notice The parked fee assets are not necessarily IN the vault while a
    ///         proposal is live — a Lane A exit that outruns float pulls back
    ///         only the exiter's payout, leaving the fee it withheld inside the
    ///         strategy until settlement. Consuming the counters mid-proposal
    ///         would therefore zero a claim the vault cannot pay. The governor
    ///         already consumes only after `_activeProposal` is cleared; this
    ///         pins that ordering as enforced, not assumed.
    function test_crystallizedFeesCannotBeConsumedMidProposal() public {
        _deploy(MGMT_BPS, 0);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA(900_000e6); // thin float: the exit below forces a pull
        _startAccrual();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        // Hoisted: a call in argument position would consume the prank.
        uint256 exitShares = vault.balanceOf(alice) / 5;
        vm.prank(alice);
        vault.redeem(exitShares, alice, alice);
        assertGt(vault.crystallizedMgmt(), 0, "the exit booked a fee");

        // Still locked: the assets backing that booking are in the strategy.
        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.consumeCrystallizedMgmt();

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(ISyndicateVault.RedemptionsLocked.selector);
        vault.consumeCrystallizedPerf();

        // Once the proposal is settled the assets are back and the release works.
        _setLocked(false);
        uint256 booked = vault.crystallizedMgmt();
        vm.prank(MOCK_GOVERNOR);
        assertEq(vault.consumeCrystallizedMgmt(), booked, "released after settlement");
    }

    // ── The queue path is untouched ──

    /// @notice A withdrawal driven by the bound queue crystallizes nothing, in
    ///         Lane A or out of it. A Lane B claim settles at the frozen
    ///         post-settlement price and has already borne its share; booking a
    ///         fee here would double-bill the same shares.
    /// @notice The queue's REAL claim path (`claim` → `settleRedeem`) bypasses
    ///         `_withdraw` entirely, so `previewRedeem`'s exit-fee deduction
    ///         never touches a queue claimant.
    ///
    ///         Why this is pinned: `previewRedeem` is a plain view with no
    ///         caller context, so it deducts the Lane A exit fee for everyone,
    ///         while `_withdraw` deliberately crystallizes nothing for the
    ///         queue. Those two only stay consistent because the queue never
    ///         goes through `_withdraw`. If a refactor ever routes it there,
    ///         claimants would be short-paid by the fee with nothing booked
    ///         against it — silently, since the shortfall just stays in the
    ///         vault. This test fails loudly at that moment.
    function test_theQueueClaimPathBypassesWithdrawAndItsFees() public {
        _deploy(MGMT_BPS, 200);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA(200_000e6);
        _startAccrual();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(alice) / 5;
        // Non-vacuity: an instant exit of this size is quoted net of fees.
        uint256 quotedNet = vault.previewRedeem(shares);
        uint256 gross = vault.convertToAssets(shares);
        assertLt(quotedNet, gross, "an instant exit of this size IS fee'd");

        // `settleRedeem` is the only thing the queue's `claim` calls on the
        // vault: burn the escrowed shares, transfer the frozen-price assets.
        // No `_withdraw`, no preview, no fee.
        vm.prank(alice);
        vault.requestRedeem(shares, alice);

        uint256 balBefore = usdc.balanceOf(alice);
        uint256 mgmtBefore = vault.crystallizedMgmt();
        uint256 perfBefore = vault.crystallizedPerf();

        vm.prank(address(queue));
        vault.settleRedeem(shares, gross, alice);

        assertEq(usdc.balanceOf(alice) - balBefore, gross, "claimant paid in full, no exit fee skimmed");
        assertEq(vault.crystallizedMgmt(), mgmtBefore, "and nothing is booked against them");
        assertEq(vault.crystallizedPerf(), perfBefore, "and nothing is booked against them");
    }

    function test_theQueuePathStillCrystallizesNothing() public {
        _deploy(MGMT_BPS, 0);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _openLaneA(200_000e6); // fat float: the queue path takes no pull
        _startAccrual();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(alice) / 5;
        // Non-vacuity: an instant exit of this size WOULD owe a fee right now.
        (uint256 wouldOweMgmt,) = vault.previewExitFees(shares);
        assertGt(wouldOweMgmt, 0, "a direct exit of the same size owes a fee");

        vm.prank(alice);
        vault.requestRedeem(shares, alice);
        assertEq(vault.balanceOf(address(queue)), shares, "the queue must hold the escrowed shares");

        vm.prank(address(queue));
        vault.redeem(shares, alice, address(queue));

        assertEq(vault.crystallizedMgmt(), 0, "the queue never crystallizes");
        assertEq(vault.crystallizedPerf(), 0, "the queue never crystallizes");

        // Control: the very next instant exit, same vault, same instant, does.
        uint256 direct = vault.maxRedeem(alice);
        assertGt(direct, 0, "alice must still have a redeemable balance");
        vm.prank(alice);
        vault.redeem(direct, alice, alice);
        assertGt(vault.crystallizedMgmt(), 0, "the instant path still crystallizes");
    }
}
