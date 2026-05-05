// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../src/SyndicateVault.sol";
import {ISyndicateVault} from "../src/interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "../src/interfaces/ISyndicateGovernor.sol";
import {BatchExecutorLib} from "../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20Mock} from "./mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "./mocks/MockAgentRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title VaultLiveWithdrawTest — coverage for the partial-unwind path
/// @notice Covers `_pullFromLiveAdapter` semantics and the
///         `liveAdapterWithdrawn[pid]` accumulator used by the governor's
///         settlement PnL formula. The vault asks the bound adapter to free
///         `deficit = (assets + reserve) - float` via `onLiveWithdraw`, then
///         measures the actual balance delta (strategies cannot lie). All-or-
///         nothing: less than `deficit` → revert and queue fallback; success
///         → record received amount under the active proposal so settlement
///         can credit it back.
contract VaultLiveWithdrawTest is Test {
    SyndicateVault vault;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;

    address owner = makeAddr("owner");
    address constant MOCK_GOVERNOR = address(0xF00D);
    uint256 constant PID = 7;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        vm.mockCall(address(this), abi.encodeWithSignature("governor()"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount(address)"), abi.encode(uint256(0)));
    }

    /// @dev Lock the vault and wire the supplied adapter as the resolved
    ///      strategy via `governor.getProposal(pid).strategy`.
    function _attachAdapter(address adapter) internal {
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal(address)"), abi.encode(PID));
        ISyndicateGovernor.StrategyProposal memory p;
        p.id = PID;
        p.vault = address(vault);
        p.strategy = adapter;
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSelector(ISyndicateGovernor.getProposal.selector, PID), abi.encode(p));
    }

    /// @dev Seed alice with shares while unlocked, then engage the live-NAV
    ///      proposal. Pre-deposit drives `liveAdapterPrincipal` so we can
    ///      reset it to test the withdraw path independently if needed.
    function _seedAndAttach(LiveWithdrawAdapter adapter, uint256 deposited) internal returns (address alice) {
        alice = makeAddr("alice");
        usdc.mint(alice, deposited);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(deposited, alice);
        // Move all float onto the adapter so a withdraw must trigger the pull.
        vm.prank(address(vault));
        usdc.transfer(address(adapter), deposited);
        adapter.setReturnable(deposited);
        _attachAdapter(address(adapter));
    }

    // ──────────────────────── happy path ────────────────────────

    function test_withdraw_pullsFromAdapterWhenFloatShort() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);
        address alice = _seedAndAttach(adapter, 1_000e6);

        // Float = 0, adapter holds 1000. Withdraw 400 — vault must pull 400.
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);

        assertEq(usdc.balanceOf(alice), 400e6, "alice received the underlying");
        assertEq(adapter.lastOnLiveWithdrawArg(), 400e6, "adapter saw the deficit amount");
        assertEq(vault.liveAdapterWithdrawn(PID), 400e6, "withdrawn principal accumulated under pid");
    }

    function test_withdraw_accumulatesAcrossMultiplePulls() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);
        address alice = _seedAndAttach(adapter, 1_000e6);

        vm.prank(alice);
        vault.withdraw(150e6, alice, alice);
        vm.prank(alice);
        vault.withdraw(250e6, alice, alice);
        vm.prank(alice);
        vault.withdraw(100e6, alice, alice);

        assertEq(vault.liveAdapterWithdrawn(PID), 500e6, "accumulator sums all pulls");
    }

    function test_withdraw_pullsOnlyDeficitNotFullAmount() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(800e6, true);
        // Deposit 1000, leave 200 as float, push 800 to adapter.
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        vm.prank(address(vault));
        usdc.transfer(address(adapter), 800e6);
        adapter.setReturnable(800e6);
        _attachAdapter(address(adapter));

        // Withdraw 500: float 200 covers the first 200, deficit 300 must pull from adapter.
        vm.prank(alice);
        vault.withdraw(500e6, alice, alice);

        assertEq(adapter.lastOnLiveWithdrawArg(), 300e6, "pull is deficit-only, not full withdraw amount");
        assertEq(vault.liveAdapterWithdrawn(PID), 300e6, "accumulator reflects deficit only");
    }

    // ──────────────────────── failure modes ────────────────────────

    /// @notice Adapter can't free enough underlying — vault reverts with
    ///         QueueReserveBreached and `liveAdapterWithdrawn` stays untouched.
    function test_withdraw_revertsAndDoesNotAccumulate_whenAdapterShort() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);
        address alice = _seedAndAttach(adapter, 1_000e6);

        // Adapter only returns 200 of any 400 requested.
        adapter.setReturnable(200e6);

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.QueueReserveBreached.selector);
        vault.withdraw(400e6, alice, alice);

        assertEq(vault.liveAdapterWithdrawn(PID), 0, "no accumulation on partial pull");
    }

    /// @notice Adapter `onLiveWithdraw` reverts (e.g. paused upstream pool).
    ///         Vault catches the revert, treats the pull as failed, and
    ///         surfaces `QueueReserveBreached` to the LP.
    function test_withdraw_revertsAndDoesNotAccumulate_whenAdapterReverts() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);
        address alice = _seedAndAttach(adapter, 1_000e6);

        adapter.setShouldRevert(true);

        vm.prank(alice);
        vm.expectRevert(ISyndicateVault.QueueReserveBreached.selector);
        vault.withdraw(100e6, alice, alice);

        assertEq(vault.liveAdapterWithdrawn(PID), 0, "no accumulation on revert");
    }

    // ──────────────────────── PnL accounting (governor-side formula) ────────────────────────

    /// @notice Settlement PnL formula is
    ///         `pnl = balance + withdrawn − (snapshot + principal)`.
    ///         Verifies the vault-side accumulators that drive the formula
    ///         compose so a pure-LP-flow lifecycle nets to zero.
    function test_pnlFormula_LPFlowOnly_netsToZero() public {
        LiveWithdrawAdapter adapter = new LiveWithdrawAdapter(usdc, address(vault));
        adapter.setValue(1_000e6, true);

        // Seed deposits get tracked under liveAdapterPrincipal because they
        // forward to the adapter via onLiveDeposit.
        address alice = makeAddr("alice");
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        // Pre-attach adapter so deposits route through onLiveDeposit.
        _attachAdapter(address(adapter));

        vm.prank(alice);
        vault.deposit(1_000e6, alice);
        // After the live-deposit forward: float = 0; adapter = 1000.
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 1_000e6);
        assertEq(vault.liveAdapterPrincipal(PID), 1_000e6, "deposit principal tracked");

        // Now an LP partial exit triggers a 400-unit pull.
        adapter.setReturnable(1_000e6);
        vm.prank(alice);
        vault.withdraw(400e6, alice, alice);
        assertEq(vault.liveAdapterWithdrawn(PID), 400e6, "withdrawn delta tracked");

        // Snapshot at execute time was 0 (no pre-deposit). With:
        //   balance         = 0      (float drained again post-withdraw)
        //   withdrawn[pid]  = 400e6
        //   snapshot        = 0
        //   principal[pid]  = 1000e6
        // PnL = (balance + withdrawn) − (snapshot + principal)
        //     = (0 + 400)            − (0 + 1000)
        //     = −600
        // The 600 difference matches alice's still-deposited 600 sitting on the adapter — not a strategy loss.
        // Settlement caller pulls back the 600 from the adapter as part of `_settle`, lifting balance by 600 and netting PnL to 0.
        // That redemption isn't modelled here (this test isolates the vault's accounting hooks); the assertion is on the per-mapping
        // values that drive the formula.
        assertEq(usdc.balanceOf(address(adapter)), 600e6, "adapter still holds remaining principal");

        // Simulate `_settle` redeeming the adapter into the vault.
        vm.prank(address(adapter));
        usdc.transfer(address(vault), 600e6);
        // Now: balance = 600 (alice withdrew 400 of her 1000); withdrawn = 400; snapshot = 0; principal = 1000.
        // pnl = (600 + 400) - (0 + 1000) = 0. Pure LP flow → no strategy P&L attribution.
        int256 pnl = int256(IERC20(usdc).balanceOf(address(vault)) + vault.liveAdapterWithdrawn(PID))
            - int256(uint256(0) + vault.liveAdapterPrincipal(PID));
        assertEq(pnl, 0, "pure LP flow nets to zero P&L");
    }
}

/// @notice Adapter that records onLiveWithdraw calls and conditionally
///         transfers a configured amount back to the vault, plus a knob to
///         force reverts. Used by the partial-unwind tests above.
contract LiveWithdrawAdapter {
    ERC20Mock public asset;
    address public boundVault;
    uint256 public mockValue;
    bool public mockValid;

    uint256 public lastOnLiveWithdrawArg;
    uint256 public liveWithdrawCount;
    uint256 public lastOnLiveDepositArg;
    uint256 public liveDepositCount;

    /// @notice Amount the adapter will return on the next onLiveWithdraw
    ///         call. Set to less than `assetsNeeded` to simulate a partial
    ///         unwind and watch the vault refuse the LP withdraw.
    uint256 public returnable;
    bool public shouldRevert;

    constructor(ERC20Mock asset_, address vault_) {
        asset = asset_;
        boundVault = vault_;
    }

    function setValue(uint256 v, bool valid_) external {
        mockValue = v;
        mockValid = valid_;
    }

    function setReturnable(uint256 r) external {
        returnable = r;
    }

    function setShouldRevert(bool x) external {
        shouldRevert = x;
    }

    function positionValue() external view returns (uint256, bool) {
        return (mockValue, mockValid);
    }

    function onLiveWithdraw(uint256 assetsNeeded) external returns (uint256 returned) {
        if (shouldRevert) revert("paused");
        liveWithdrawCount++;
        lastOnLiveWithdrawArg = assetsNeeded;
        // Transfer `min(returnable, assetsNeeded)` back to the vault.
        uint256 amount = returnable < assetsNeeded ? returnable : assetsNeeded;
        if (amount > 0) {
            asset.transfer(boundVault, amount);
            returnable -= amount;
        }
        return amount;
    }

    function onLiveDeposit(uint256 assets) external {
        liveDepositCount++;
        lastOnLiveDepositArg = assets;
    }
}
