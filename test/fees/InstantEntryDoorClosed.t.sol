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

/// @notice Holds the basket and hands it all back at settlement — the stand-in
///         for a PortfolioStrategy whose unwind realizes executable prices.
contract MockBasketStrategy {
    ERC20Mock public immutable asset;
    address public immutable vault;

    constructor(ERC20Mock asset_, address vault_) {
        asset = asset_;
        vault = vault_;
    }

    function availableLiquidity() external view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function withdrawTo(uint256 assets) external {
        uint256 bal = asset.balanceOf(address(this));
        asset.transfer(vault, assets > bal ? bal : assets);
    }
}

/// @notice Prices the strategy at `markBps / 10_000` of what it actually holds.
///
///         `markBps == 10_000` is the case where the router's mark equals
///         executable value. Anything below models the regime
///         `Erc20SpotAdapter`'s divergence gate DELIBERATELY tolerates: the
///         oracle mark and the pool price are allowed to disagree by up to
///         `maxDivergenceBps` (100bps as seeded by `script/DeployLaneA.s.sol`)
///         and Lane A stays open across that whole band. `markBps = 9_900` is
///         the gate sitting exactly on its bound with the mark BELOW
///         executable — the would-be-entrant-favourable side.
contract MarkingRouter {
    ERC20Mock public asset;
    address public strategy;
    bool public ok;
    uint256 public markBps = 10_000;

    function set(ERC20Mock asset_, address strategy_, bool ok_, uint256 markBps_) external {
        asset = asset_;
        strategy = strategy_;
        ok = ok_;
        markBps = markBps_;
    }

    function valueStrategy(address) external view returns (uint256, bool) {
        if (!ok || strategy == address(0)) return (0, false);
        return ((asset.balanceOf(strategy) * markBps) / 10_000, true);
    }
}

/// @notice Audit finding #14 (deposit-side arbitrage against a tolerated
///         oracle-vs-pool spread) is closed by removing instant entry, not by
///         pricing it. See `SyndicateVault._deposit` for the full reasoning;
///         this file pins the closure with the exact mechanism the finding
///         described, so a regression that reopens the door fails loudly here.
///
///         The finding: `Erc20SpotAdapter`'s divergence gate deliberately
///         tolerates a mark below executable value (up to `maxDivergenceBps`).
///         A Lane A instant deposit while that gap is open mints against the
///         understatement. The `_laneALockPid` lock does NOT price this away —
///         `SyndicateGovernor.settleProposal` is permissionless once
///         `strategyDuration` has elapsed, so an entrant can deposit, settle,
///         and redeem in ONE transaction: the lock expires in the same call
///         frame that realizes true prices, the exit lands post-settlement
///         (Lane B — no exit fee, no depth cap), and the round trip is
///         riskless. The fix is structural: `_deposit` reverts `DepositsLocked`
///         for ANY deposit while a proposal is open, Lane A or not, so this
///         entire chain never starts.
contract InstantEntryDoorClosedTest is Test {
    SyndicateVault internal vault;
    VaultWithdrawalQueue internal queue;
    BatchExecutorLib internal executorLib;
    ERC20Mock internal usdc;
    MockAgentRegistry internal agentRegistry;
    MarkingRouter internal router;
    MockBasketStrategy internal strategy;

    address internal owner = makeAddr("owner");
    address internal incumbent = makeAddr("incumbent");
    address internal entrant = makeAddr("entrant");
    address internal constant MOCK_GOVERNOR = address(0xF00D);
    uint256 internal constant PID = 1;

    /// @dev The exit-side toll `DeployLaneA` G1 wires, and the vault's hard cap.
    uint16 internal constant TOLL_BPS = 200;
    /// @dev `Erc20SpotAdapter`'s seeded divergence bound (G4). The mark may sit
    ///      this far below executable value with Lane A still open.
    uint256 internal constant GATE_BPS = 100;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        router = new MarkingRouter();

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
        strategy = new MockBasketStrategy(usdc, address(vault));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(address(this), abi.encodeWithSignature("priceRouter()"), abi.encode(address(router)));
        ISyndicateGovernor.GovernorParams memory gp;
        gp.maxPerformanceFeeBps = 2000;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getGovernorParams()"), abi.encode(gp));
        _setLocked(false);

        vm.prank(owner);
        vault.setInstantExitFeeBps(TOLL_BPS);

        for (uint256 i = 0; i < 2; ++i) {
            address who = i == 0 ? incumbent : entrant;
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
            vm.mockCall(
                MOCK_GOVERNOR, abi.encodeWithSignature("strategyOf(uint256)", PID), abi.encode(address(strategy))
            );
        }
    }

    /// @dev Deploy `amount` into the strategy and open Lane A with the router
    ///      marking the position at `markBps` of what it really holds.
    function _openLaneA(uint256 amount, uint256 markBps) internal {
        // Fund the vault first (ordinary instant deposit — no proposal is
        // open yet) so the transfer below has a real balance to move.
        vm.prank(incumbent);
        vault.deposit(amount, incumbent);

        vm.prank(address(vault));
        usdc.transfer(address(strategy), amount);
        _setLocked(true);
        router.set(usdc, address(strategy), true, markBps);
    }

    // ── The door is closed, full stop ──

    /// @notice Regression pin: the exact regime the finding names — Lane A
    ///         live, mark sitting at the tolerated-spread bound below
    ///         executable value — still refuses an instant deposit.
    function test_instantDepositRevertsEvenWhenLaneAWouldHavePricedItCheap() public {
        _openLaneA(1_000_000e6, 10_000 - GATE_BPS); // mark 100bps below executable

        // Precondition: Lane A genuinely is live (a stale/unavailable router
        // would make this test vacuous — it would pass whether or not the
        // door is closed, because deposits are ALSO blocked when Lane A is
        // down).
        (, bool laneAOk) = router.valueStrategy(address(strategy));
        assertTrue(laneAOk, "precondition: Lane A router reports a valid mark");

        vm.prank(entrant);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000_000e6, entrant);
    }

    /// @notice Ordinary case: any deposit while a proposal is open reverts,
    ///         regardless of whether the mark happens to equal executable
    ///         value (markBps = 10_000). Entry is closed on proposal state
    ///         alone, not on the presence of a mispricing.
    function test_instantDepositRevertsWhileAnyProposalIsOpen() public {
        _openLaneA(1_000_000e6, 10_000);

        vm.prank(entrant);
        vm.expectRevert(ISyndicateVault.DepositsLocked.selector);
        vault.deposit(1_000_000e6, entrant);
    }

    /// @notice The queue path stays open and correctly priced: an entrant who
    ///         wants in mid-proposal must use `requestDeposit`, which mints at
    ///         the realized settlement price — the honest route the closed
    ///         instant door pushes everyone toward.
    function test_queueDepositRemainsAvailableWhileLocked() public {
        _openLaneA(1_000_000e6, 10_000 - GATE_BPS);

        vm.prank(entrant);
        vault.requestDeposit(1_000_000e6, entrant);
        // No revert: the queue is the only mid-proposal entry point left.
        assertEq(usdc.balanceOf(address(queue)), 1_000_000e6, "escrowed in the queue, not minted instantly");
    }

    /// @notice No regression on the unlocked path: outside any proposal,
    ///         instant deposits work exactly as before.
    function test_instantDepositStillWorksOutsideAnyProposal() public {
        vm.prank(entrant);
        vault.deposit(1_000_000e6, entrant);
        assertGt(vault.balanceOf(entrant), 0, "minted normally when nothing is locked");
    }

    /// @notice No entry-fee surface survives the door closure: nothing is left
    ///         to configure, tune, or forget to configure.
    function test_noEntryFeeSurfaceExists() public view {
        // solc: neither `instantEntryFeeBps()` nor `setInstantEntryFeeBps`
        // exist on `SyndicateVault` any more — this test's mere ability to
        // compile without referencing them is the assertion. Kept as an
        // explicit marker so the intent is visible in the test list, not just
        // in what's absent from the diff.
        assertEq(vault.instantExitFeeBps(), TOLL_BPS, "the EXIT toll is unaffected by closing entry");
    }
}
