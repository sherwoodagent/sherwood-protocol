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

/// @notice A strategy stub that holds value and returns it on request, so the
///         float / pulled split of an exit is controllable.
contract MockLiquidStrategy {
    ERC20Mock public immutable asset;
    address public immutable vault;

    constructor(ERC20Mock asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function availableLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @dev Matches `IStrategy.withdrawTo(uint256)` — the vault names the
    ///      amount and the strategy returns it to the vault.
    function withdrawTo(uint256 assets) external {
        uint256 bal = asset.balanceOf(address(this));
        uint256 send = assets > bal ? bal : assets;
        asset.transfer(vault, send);
    }
}

/// @notice Prices the strategy at its LIVE asset balance rather than a fixed
///         figure. A static valuation would keep reporting the pre-pull number
///         after `withdrawTo` drains the strategy, double-counting the pulled
///         assets in `totalAssets()` and manufacturing a phantom gain — which
///         would then look like a performance fee that the exit never earned.
contract MockPenaltyRouter {
    ERC20Mock public asset;
    address public strategy;
    bool public ok;

    function set(ERC20Mock asset_, address strategy_, bool ok_) external {
        asset = asset_;
        strategy = strategy_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        if (!ok || strategy == address(0)) return (0, false);
        return (asset.balanceOf(strategy), true);
    }
}

/// @notice Covers the early-exit penalty half of
///         `specs/instant-exit-fees/spec.md`: charged on the pulled portion
///         only, accrues to the vault rather than to any recipient, bounded by
///         a protocol maximum, and never charged on a queue exit.
contract InstantExitFeeTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockPenaltyRouter internal router;
    MockLiquidStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant MOCK_GOVERNOR = address(0xF00D);
    uint256 internal constant PID = 1;

    uint16 internal constant PENALTY_BPS = 50; // 0.5%, the proposed launch rate

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockPenaltyRouter();

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
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));
        strategy = new MockLiquidStrategy(usdc, address(vault));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        ISyndicateGovernor.GovernorParams memory gp;
        gp.maxPerformanceFeeBps = 2000;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getGovernorParams()"), abi.encode(gp));
        _setLocked(false);

        vm.prank(owner);
        vault.setInstantExitFeeBps(PENALTY_BPS);

        for (uint256 i = 0; i < 2; ++i) {
            address who = i == 0 ? alice : bob;
            usdc.mint(who, 10_000_000e6);
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

    /// @dev Open Lane A with `deployed` assets moved into the strategy, leaving
    ///      the rest as idle float.
    function _openLaneA(uint256 deployed) internal {
        vm.prank(address(vault));
        usdc.transfer(address(strategy), deployed);
        _setLocked(true);
        router.set(usdc, address(strategy), true);
    }

    // ── The rate ──

    function test_theRateIsOwnerSetAndBounded() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(200);
        assertEq(vault.instantExitFeeBps(), 200);
    }

    function test_aRateAboveTheMaximumReverts() public {
        vm.prank(owner);
        vm.expectRevert(ISyndicateVault.InstantExitFeeTooHigh.selector);
        vault.setInstantExitFeeBps(201);
    }

    function test_onlyTheOwnerMaySetTheRate() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setInstantExitFeeBps(10);
    }

    function test_theMaximumIsTwoPercent() public view {
        assertEq(vault.MAX_INSTANT_EXIT_FEE_BPS(), 200);
    }

    // ── Incidence ──

    /// @notice An exit served entirely from idle float still pays the full
    ///         penalty. The toll prices the oracle-vs-pool basis the exiter
    ///         realizes against the marked NAV, and that harm to the LPs who
    ///         stay is identical whether or not a sale was forced.
    ///
    ///         Regression: a float-scoped charge left a fee-free window that
    ///         fresh Lane A deposits kept enlarging, so an arbitrageur could
    ///         size an exit to the float and harvest the basis at zero cost.
    function test_anExitServedEntirelyFromFloatStillPaysTheFullPenalty() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA(500_000e6); // 500k deployed, 500k idle — fat float

        // Redeem 10% of supply -> ~100k, comfortably inside the 500k float.
        uint256 shares = vault.balanceOf(alice) / 10;
        uint256 gross = vault.convertToAssets(shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 charged = gross - quoted;

        assertApproxEqAbs(charged, (gross * PENALTY_BPS) / 10_000, 1, "float-served exits pay in full");
        assertLt(quoted, gross, "no fee-free window");
    }

    /// @notice An exit that outruns float pays on the whole exit, at the same
    ///         flat rate as the float-served case above — the charge does not
    ///         depend on how much of the exit forced a pull.
    function test_anExitThatForcesAnUnwindPaysOnTheWholeExit() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA(900_000e6); // only 100k idle — thin float

        uint256 shares = vault.balanceOf(alice) / 2; // ~500k
        uint256 gross = vault.convertToAssets(shares);
        uint256 quoted = vault.previewRedeem(shares);
        uint256 charged = gross - quoted;

        assertApproxEqAbs(charged, (gross * PENALTY_BPS) / 10_000, 1, "penalty applies to the whole exit");
    }

    /// @notice The penalty stays in the fund. It compensates the depositors who
    ///         stay for the forced unwind — it is not revenue, and no fee
    ///         recipient sees any of it.
    function test_thePenaltyAccruesToTheFundNotToARecipient() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);
        _openLaneA(1_800_000e6); // 200k idle

        uint256 ppsBefore = vault.pricePerShare();

        uint256 shares = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        // Unlike crystallized fees (which are parked and excluded), the penalty
        // is fund money — so the holders who stayed are strictly better off.
        assertGt(vault.pricePerShare(), ppsBefore, "the penalty enriches the stayers");
        assertEq(vault.crystallizedMgmt(), 0, "not a management fee");
        assertEq(vault.crystallizedPerf(), 0, "not a performance fee");
    }

    /// @notice A zero rate disables the charge entirely.
    function test_aZeroRateChargesNothing() public {
        vm.prank(owner);
        vault.setInstantExitFeeBps(0);

        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA(900_000e6);

        uint256 shares = vault.balanceOf(alice) / 2;
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares), "rate 0, no charge");
    }

    // ── Lane B is exempt ──

    /// @notice Outside a Lane A window nothing is charged. A queue exiter
    ///         claims at the frozen post-settlement price and never pays this.
    function test_aQueueExitNeverPaysThePenalty() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        uint256 shares = vault.balanceOf(alice) / 2;
        assertEq(vault.previewRedeem(shares), vault.convertToAssets(shares), "no proposal, no penalty");
    }

    // ── Preview exactness ──

    /// @notice What is quoted is what is delivered.
    function test_previewMatchesTheExecutedExit() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);
        _openLaneA(1_800_000e6);

        uint256 shares = vault.balanceOf(bob);
        uint256 quoted = vault.previewRedeem(shares);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        assertEq(usdc.balanceOf(bob) - before, quoted, "delivered must equal quoted");
    }

    /// @notice `previewRedeem` must stay monotone across the float boundary —
    ///         redeeming more shares can never deliver fewer assets, kink or
    ///         no kink.
    function test_previewRedeemIsMonotoneAcrossTheKink() public {
        vm.prank(alice);
        vault.deposit(2_000_000e6, alice);
        _openLaneA(1_800_000e6); // 200k idle: the kink sits inside the range

        uint256 supply = vault.balanceOf(alice);
        uint256 previous = 0;
        for (uint256 i = 1; i <= 10; ++i) {
            uint256 net = vault.previewRedeem((supply * i) / 10);
            assertGe(net, previous, "more shares must never deliver fewer assets");
            previous = net;
        }
    }

    /// @notice `previewWithdraw` grosses up across the kink, so a withdraw
    ///         delivers at least what was asked for. Erring the other way would
    ///         break the EIP-4626 guarantee.
    function test_previewWithdrawDeliversAtLeastTheRequestedAssets() public {
        vm.prank(alice);
        vault.deposit(2_000_000e6, alice);
        _openLaneA(1_800_000e6);

        uint256 want = 500_000e6;
        uint256 shares = vault.previewWithdraw(want);
        assertGe(vault.previewRedeem(shares), want, "the gross-up must not land short");
    }

    // ── Ordering against crystallization ──

    /// @notice The two charges are independent and stack in a fixed order:
    ///         crystallization first (to the recipients), then the penalty on
    ///         what remains (to the vault).
    function test_bothChargesApplyAndThePenaltyComesSecond() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);
        _openLaneA(1_800_000e6);

        // Push the fund above its mark so a performance fee is owed too.
        usdc.mint(address(vault), 200_000e6);

        uint256 shares = vault.balanceOf(bob);
        uint256 gross = vault.convertToAssets(shares);
        (uint256 mgmtFee, uint256 perfFee) = vault.previewExitFees(shares);
        uint256 net = vault.previewRedeem(shares);

        assertGt(perfFee, 0, "above the mark, performance is owed");
        // The penalty is charged on the post-crystallization remainder, so the
        // total taken exceeds the fees alone but is less than charging the
        // penalty on the gross.
        uint256 taken = gross - net;
        assertGt(taken, mgmtFee + perfFee, "the penalty stacks on top");
        assertLt(taken, mgmtFee + perfFee + (gross * PENALTY_BPS) / 10_000, "but applies to the net, not the gross");
    }
}
