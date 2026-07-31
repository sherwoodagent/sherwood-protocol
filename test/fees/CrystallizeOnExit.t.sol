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

contract MockExitRouter {
    uint256 public v;
    bool public ok;

    function set(uint256 v_, bool ok_) external {
        v = v_;
        ok = ok_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        return (v, ok);
    }
}

/// @notice Covers `specs/instant-exit-fees/spec.md`. The two assertions that
///         matter most are `test_anExitDoesNotMoveTheRemainingHoldersPrice`
///         and `test_leavingEarlyDoesNotMakeTheStayersPayMore` — those pin the
///         invariants depositors actually care about. The rest describe the
///         mechanism; those two would catch it being wrong.
contract CrystallizeOnExitTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;
    MockExitRouter internal router;

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal constant MOCK_GOVERNOR = address(0xF00D);
    address internal constant STRAT = address(0x57A7);
    uint256 internal constant PID = 1;

    /// @dev 2%/yr management, so accrual is observable over a 30-day window.
    uint256 internal constant MGMT_BPS = 200;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MockExitRouter();

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
                    managementFeeBps: MGMT_BPS
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        // The governor's per-vault performance ceiling, read by `_exitFees`.
        ISyndicateGovernor.GovernorParams memory gp;
        gp.maxPerformanceFeeBps = 2000;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getGovernorParams()"), abi.encode(gp));
        _setLocked(false);

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
            p.strategy = STRAT;
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p)
            );
        }
    }

    function _openLaneA() internal {
        _setLocked(true);
        router.set(0, true);
        vm.prank(MOCK_GOVERNOR);
        vault.startManagementAccrual();
    }

    function _gain(uint256 amount) internal {
        usdc.mint(address(vault), amount);
    }

    // ── The invariant that catches a missing exclusion ──

    /// @notice Crystallizing must be invisible to the holders who stay. If the
    ///         parked fee kept counting as fund assets, their price would sit
    ///         too high until settlement paid it out — a phantom loss appearing
    ///         from nowhere.
    function test_anExitDoesNotMoveTheRemainingHoldersPrice() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        _gain(400_000e6); // well above the mark, so both fee legs are live
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 ppsBefore = vault.pricePerShare();

        uint256 shares1 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares1, bob, bob);

        assertApproxEqAbs(vault.pricePerShare(), ppsBefore, 1, "an exit must not move the stayers' price");
    }

    /// @notice And the parked money must actually be parked.
    function test_crystallizedFeesAreExcludedFromTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        _gain(400_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares2 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares2, bob, bob);

        uint256 parked = vault.crystallizedMgmt() + vault.crystallizedPerf();
        assertGt(parked, 0, "fees should have been crystallized");

        uint256 balance = usdc.balanceOf(address(vault));
        assertEq(vault.totalAssets(), balance - parked, "parked fees are not fund assets");
    }

    // ── The invariant that catches a missing net-out ──

    /// @notice Leaving early must not shift fee burden onto the depositors who
    ///         stay. Two identical funds: in one, bob exits at day 15; in the
    ///         other, nobody exits. Alice's position must bear the same fee
    ///         either way.
    ///
    ///         This is the assertion that fails if the settlement charge is not
    ///         netted against what exiters already paid — a bug that reverts
    ///         nothing and simply makes the stayers a little poorer.
    function test_leavingEarlyDoesNotMakeTheStayersPayMore() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        vm.warp(vm.getBlockTimestamp() + 15 days);

        // Bob leaves and pays his share on the way out.
        uint256 shares3 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares3, bob, bob);
        uint256 bobPaid = vault.crystallizedMgmt();
        assertGt(bobPaid, 0, "bob must pay the fee he accrued");

        vm.warp(vm.getBlockTimestamp() + 15 days);

        vm.prank(MOCK_GOVERNOR);
        uint256 assetSeconds = vault.consumeManagementAccrual();
        uint256 totalOwed = (assetSeconds * MGMT_BPS) / (10_000 * 365 days);

        // What the fund still has to fund out of its own assets.
        uint256 stayersOwe = totalOwed - bobPaid;

        // Alice held 1M for the whole 30 days. Her fee should reflect exactly
        // that — not bob's 15 days as well.
        uint256 aliceExpected = (1_000_000e6 * uint256(30 days) * MGMT_BPS) / (10_000 * 365 days);
        assertApproxEqRel(stayersOwe, aliceExpected, 1e15, "the stayer bears only her own time");
    }

    /// @notice The parked total must not exceed what the whole proposal owed —
    ///         the direct statement of "no double-charge".
    function test_crystallizedNeverExceedsTheTotalOwed() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        vm.warp(vm.getBlockTimestamp() + 20 days);
        uint256 shares4 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares4, bob, bob);
        vm.warp(vm.getBlockTimestamp() + 10 days);

        uint256 parked = vault.crystallizedMgmt();
        vm.prank(MOCK_GOVERNOR);
        uint256 assetSeconds = vault.consumeManagementAccrual();
        uint256 totalOwed = (assetSeconds * MGMT_BPS) / (10_000 * 365 days);

        assertLe(parked, totalOwed, "an exiter cannot pay more than the fund owed in total");
    }

    // ── Mechanism ──

    function test_anInstantExiterPaysAccruedManagement() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _openLaneA();
        vm.warp(vm.getBlockTimestamp() + 30 days);

        (uint256 mgmtFee, uint256 perfFee) = vault.previewExitFees(vault.balanceOf(alice));
        assertGt(mgmtFee, 0, "an exiter owes their accrued management fee");
        assertEq(perfFee, 0, "flat fund, no performance fee");

        uint256 shares5 = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares5, alice, alice);
        assertEq(vault.crystallizedMgmt(), mgmtFee, "the preview must match what is booked");
    }

    function test_anExiterAboveTheMarkPaysPerformance() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);

        _openLaneA();
        _gain(200_000e6);

        (, uint256 perfFee) = vault.previewExitFees(vault.balanceOf(alice));
        assertGt(perfFee, 0, "above the mark, performance is owed");
    }

    function test_anExiterBelowTheMarkPaysNoPerformance() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        _openLaneA();

        (uint256 mgmtFee, uint256 perfFee) = vault.previewExitFees(vault.balanceOf(alice));
        assertEq(perfFee, 0, "at the mark, nothing to charge");
        assertEq(mgmtFee, 0, "no time elapsed yet either");
    }

    /// @notice The mark advances only at settlement. Ratcheting on a partial
    ///         exit would leave the stayers measuring from a peak the fund
    ///         never banked.
    function test_aPartialExitDoesNotRatchetTheMark() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        uint256 markBefore = vault.highWaterPricePerShare();
        _openLaneA();
        _gain(400_000e6);

        uint256 shares6 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares6, bob, bob);

        assertEq(vault.highWaterPricePerShare(), markBefore, "only settlement ratchets");
    }

    /// @notice Outside a Lane A window there is nothing to crystallize — a
    ///         queue exit claims at the frozen post-settlement price and has
    ///         already borne its share.
    function test_noCrystallizationOutsideALaneAWindow() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        (uint256 mgmtFee, uint256 perfFee) = vault.previewExitFees(vault.balanceOf(alice));
        assertEq(mgmtFee, 0);
        assertEq(perfFee, 0);

        uint256 shares7 = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares7, alice, alice);
        assertEq(vault.crystallizedMgmt(), 0, "no proposal, no exit fee");
        assertEq(vault.crystallizedPerf(), 0);
    }

    /// @notice The quote must equal what is delivered, or an integrator's
    ///         preview is a lie.
    function test_previewMatchesTheExecutedExit() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        _gain(400_000e6);
        vm.warp(vm.getBlockTimestamp() + 30 days);

        uint256 shares = vault.balanceOf(bob);
        uint256 quoted = vault.previewRedeem(shares);

        uint256 before = usdc.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        assertEq(usdc.balanceOf(bob) - before, quoted, "delivered must equal quoted");
    }

    // ── Release ──

    function test_onlyGovernorMayReleaseParkedFees() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.consumeCrystallizedMgmt();

        vm.prank(alice);
        vm.expectRevert();
        vault.consumeCrystallizedPerf();
    }

    /// @notice Releasing hands the amount back and restores it to fund assets —
    ///         which is why the performance base must be read first.
    function test_releasingParkedFeesRestoresThemToTotalAssets() public {
        vm.prank(alice);
        vault.deposit(1_000_000e6, alice);
        vm.prank(bob);
        vault.deposit(1_000_000e6, bob);

        _openLaneA();
        vm.warp(vm.getBlockTimestamp() + 30 days);
        uint256 shares8 = vault.balanceOf(bob);
        vm.prank(bob);
        vault.redeem(shares8, bob, bob);

        uint256 parked = vault.crystallizedMgmt();
        assertGt(parked, 0);
        uint256 assetsBefore = vault.totalAssets();

        vm.prank(MOCK_GOVERNOR);
        uint256 released = vault.consumeCrystallizedMgmt();

        assertEq(released, parked, "release returns what was parked");
        assertEq(vault.crystallizedMgmt(), 0, "and clears it");
        assertEq(vault.totalAssets(), assetsBefore + parked, "the assets come back into view");
    }
}
