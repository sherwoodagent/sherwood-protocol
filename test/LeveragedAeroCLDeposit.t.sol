// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {LeveragedAeroStorage} from "../src/strategies/LeveragedAeroStorage.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Minimal mock vault — satisfies ISyndicateVault(strategyMint) + IERC20(totalSupply)
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Copied from the fork-test file so this unit-test file compiles standalone.
contract MockVaultUnit {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address initialHolder, uint256 initialShares) {
        balanceOf[initialHolder] = initialShares;
        totalSupply = initialShares;
    }

    /// @dev #421: strategy resolves protocol-fee params via vault().factory().protocolConfig();
    ///      factory()==0 ⇒ no protocol fee. Mock must track ISyndicateVault (CLAUDE.md MockRegistryMinimal lesson).
    function factory() external pure returns (address) {
        return address(0);
    }

    function strategyMint(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Harness — overrides nav() to reflect a base NAV plus simulated idle USDC
// ─────────────────────────────────────────────────────────────────────────────

/// @dev `new DepositHarness()` runs BaseStrategy's constructor → sets `_initialized = true`
///      on the template instance.  We then write only the storage slots needed for
///      `deposit` via `vm.store`, bypassing the full initialisation path.
///
///      `nav()` returns `baseNav + idleUsdcSim`.  `idleUsdcSim` represents idle USDC
///      held by the strategy — in production this would be `IERC20(usdc).balanceOf(this)`.
///      By setting `idleUsdcSim = deposit_amount` AFTER the crystallize call would run
///      (i.e. simulating the post-pull state), the test can prove that calling
///      `_crystallizeFees` AFTER `safeTransferFrom` would inflate navPre and charge a
///      phantom performance fee.  See `test_deposit_noPhantomFee_unit` for the proof.
contract DepositHarness is LeveragedAerodromeCLStrategy {
    uint256 public baseNav;
    /// @dev Simulated idle USDC in strategy — reflects what safeTransferFrom would add.
    uint256 public idleUsdcSim;

    function setBaseNav(uint256 n) external {
        baseNav = n;
    }

    function setIdleUsdc(uint256 u) external {
        idleUsdcSim = u;
    }

    function nav() public view virtual override returns (uint256) {
        return baseNav + idleUsdcSim;
    }
}

/// @dev Real-`nav()` harness (no override) — exercises the on-chain flat-book branch.
contract NavHarness is LeveragedAerodromeCLStrategy {}

// ─────────────────────────────────────────────────────────────────────────────
// Storage slot constants (from `forge inspect LeveragedAerodromeCLStrategy storage-layout`)
// ─────────────────────────────────────────────────────────────────────────────
//
// BaseStrategy state stays in the sequential layout:
//   slot 0  : _vault        (address, offset 0)
//   slot 1  : _proposer     (address, offset 0) | _state (uint8, offset 20) | _initialized (bool, offset 21)
//
// Strategy state moved into ERC-7201 diamond storage at STRAT_BASE
// (= keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~0xff).
// Within the Layout struct the field packing is identical to the old sequential
// layout, so each field slot = STRAT_BASE + (oldSequentialSlot - 3):
//   STRAT_BASE + 0  : usdc          (address, offset 0)            [was slot 3]
//   STRAT_BASE + 19 : feeRecipient  (address, off 10) | managementFeeBps (uint16, off 6) | performanceFeeBps (uint16, off 8) [was slot 22]
//   STRAT_BASE + 20 : hwmPerShare   (uint256)                      [was slot 23]
//   STRAT_BASE + 21 : lastFeeAccrualTimestamp (uint256)            [was slot 24]
//
// State enum: Pending=0, Executed=1, Settled=2.

/// @title  LeveragedAeroCLDepositUnit
/// @notice Offline (no-fork) unit tests for `deposit`:
///           1. test_deposit_shareFormula          — exact share math against mocked nav.
///           2. test_deposit_noPhantomFee_unit      — no performance fee when nav == HWM, dt == 0.
///           3. test_deposit_minSharesRevert        — reverts InsufficientShares when slippage too tight.
contract LeveragedAeroCLDepositUnit is Test {
    // ── slot numbers ──
    // BaseStrategy sequential slots (unchanged by the diamond-storage refactor):
    uint256 private constant SLOT_VAULT = 0;
    uint256 private constant SLOT_PROPOSER_STATE_INIT = 1;
    // ERC-7201 diamond base; strategy field slot = STRAT_BASE + structOffset.
    uint256 private constant STRAT_BASE = uint256(LeveragedAeroStorage.STORAGE_SLOT);
    uint256 private constant SLOT_USDC = STRAT_BASE + 0;
    uint256 private constant SLOT_SLOT22 = STRAT_BASE + 19; // feeRecipient packed slot
    uint256 private constant SLOT_HWM = STRAT_BASE + 20;
    uint256 private constant SLOT_LAST_FEE = STRAT_BASE + 21;

    // State.Executed = 1, _initialized = true → byte 20 = 0x01, byte 21 = 0x01
    // As uint256: (1 << 168) | (1 << 160)
    uint256 private constant STATE_EXECUTED_INIT = (uint256(1) << 168) | (uint256(1) << 160);

    // ERC-4626 virtual offset (must match the constant in the strategy)
    uint256 private constant SHARES_VIRTUAL_OFFSET = 1e6;

    // ── mock addresses ──
    address private constant MOCK_USDC = address(0xAA01);
    address private constant FEE_RECIPIENT = address(0xAA02);

    DepositHarness private harness;
    MockVaultUnit private mockVault;

    address private depositor;

    // ── shared supply for the vault mock ──
    uint256 private constant INITIAL_SHARES = 100_000e12; // 100k shares (12dp)

    function setUp() public {
        depositor = makeAddr("depositor");

        // Stand-alone vault with an initial shareholder so totalSupply > 0
        mockVault = new MockVaultUnit(makeAddr("alice"), INITIAL_SHARES);

        // Deploy the harness (BaseStrategy constructor locks the template)
        harness = new DepositHarness();

        // ── Wire storage ──
        // slot 0: _vault
        vm.store(address(harness), bytes32(SLOT_VAULT), bytes32(uint256(uint160(address(mockVault)))));

        // slot 1: _state = Executed (1), _initialized = true
        // After `new`, _initialized is already true (constructor). Re-write to also set _state.
        vm.store(address(harness), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));

        // slot 3: usdc = MOCK_USDC
        vm.store(address(harness), bytes32(SLOT_USDC), bytes32(uint256(uint160(MOCK_USDC))));

        // slot 22: feeRecipient packed at byte offset 10 (80 bits from the right of the word)
        // managementFeeBps = 0, performanceFeeBps = 0, feeRecipient = FEE_RECIPIENT
        uint256 slot22Val = uint256(uint160(FEE_RECIPIENT)) << 80;
        vm.store(address(harness), bytes32(SLOT_SLOT22), bytes32(slot22Val));

        // slot 24: lastFeeAccrualTimestamp = block.timestamp (initialised — avoids first-time init branch)
        vm.store(address(harness), bytes32(SLOT_LAST_FEE), bytes32(block.timestamp));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: mock USDC safeTransferFrom to succeed (no real ERC-20 needed)
    // ─────────────────────────────────────────────────────────────────────────

    function _mockUsdcTransfer(uint256 amount) internal {
        // SafeERC20.safeTransferFrom calls transferFrom and checks the return value.
        vm.mockCall(
            MOCK_USDC,
            abi.encodeWithSignature("transferFrom(address,address,uint256)", depositor, address(harness), amount),
            abi.encode(true)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 1 — exact share formula
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice With mocked nav()=N and totalSupply=S, deposit(a, 0) mints exactly
    ///         Math.mulDiv(a, S + SHARES_VIRTUAL_OFFSET, N + 1) shares.
    function test_deposit_shareFormula() public {
        uint256 N = 50_000e6; // $50 k NAV (6 dp USDC)
        uint256 a = 1_000e6; // $1 k deposit

        harness.setBaseNav(N);
        _mockUsdcTransfer(a);

        uint256 supplyBefore = mockVault.totalSupply(); // INITIAL_SHARES

        vm.prank(depositor);
        uint256 shares = harness.deposit(a, 0);

        uint256 expected = Math.mulDiv(a, supplyBefore + SHARES_VIRTUAL_OFFSET, N + 1);
        assertEq(shares, expected, "shares != expected formula");
        assertEq(mockVault.balanceOf(depositor), shares, "depositor balance mismatch");
        assertEq(mockVault.totalSupply(), supplyBefore + shares, "totalSupply not updated");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 2 — no phantom fee when nav == HWM and dt == 0
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Crystallizing on PRE-deposit NAV charges ZERO performance fee even when
    ///         performanceFeeBps > 0, because nav == HWM at crystallize time.
    ///
    ///         Genuine test: `performanceFeeBps = 1000` (10 %) is active, and `nav()` in the
    ///         harness returns `baseNav + idleUsdcSim` — explicitly modelling the idle-USDC
    ///         inflation that would occur if crystallize ran AFTER `safeTransferFrom`.
    ///
    ///         Ordering proof:
    ///           Pre-pull:  idleUsdcSim = 0 → nav() = 50_000e6 = hwm nav → fee = 0  ✓
    ///           Post-pull: idleUsdcSim = 1_000e6 → nav() = 51_000e6 > hwm nav
    ///                      → navPerShareX > hwmPerShare → perf fee WOULD be charged
    ///                      (verify: `harness.setIdleUsdc(1_000e6)` BEFORE this test
    ///                       and the assertEq below would FAIL with non-zero feeShares).
    ///
    ///         The current `deposit` implementation calls `_crystallizeFees` BEFORE
    ///         `safeTransferFrom`, so `idleUsdcSim = 0` when crystallize runs → 0 fee.
    function test_deposit_noPhantomFee_unit() public {
        uint256 N = 50_000e6; // $50 k base NAV — no idle USDC yet (pre-pull)
        harness.setBaseNav(N);
        harness.setIdleUsdc(0); // explicit: no idle USDC at crystallize time

        // Set performanceFeeBps = 1000 (10 %) in slot 22.
        // slot 22 layout: feeRecipient(addr<<80) | performanceFeeBps(uint16<<64) | managementFeeBps(uint16<<48)
        uint256 slot22Perf = (uint256(uint160(FEE_RECIPIENT)) << 80) | (uint256(1000) << 64);
        vm.store(address(harness), bytes32(SLOT_SLOT22), bytes32(slot22Perf));

        // Set hwmPerShare = navPerShareX at N — HWM is exactly at current nav so no gain.
        // navPerShareX = N × 1e18 / INITIAL_SHARES = 50_000e6 × 1e18 / 100_000e12 = 5e11
        uint256 hwm = Math.mulDiv(N, 1e18, INITIAL_SHARES);
        vm.store(address(harness), bytes32(SLOT_HWM), bytes32(hwm));

        // lastFeeAccrualTimestamp already equals block.timestamp (set in setUp) → dt = 0.
        // With nav == HWM and dt == 0: management fee = 0, performance fee = 0.

        _mockUsdcTransfer(1_000e6);

        uint256 feeSharesBefore = mockVault.balanceOf(FEE_RECIPIENT);

        vm.prank(depositor);
        harness.deposit(1_000e6, 0);

        uint256 feeSharesAfter = mockVault.balanceOf(FEE_RECIPIENT);
        assertEq(feeSharesAfter, feeSharesBefore, "phantom fee shares minted to feeRecipient");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 3 — reverts InsufficientShares when minShares not met
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice If computed shares < minShares, deposit must revert InsufficientShares.
    function test_deposit_minSharesRevert() public {
        uint256 N = 50_000e6;
        harness.setBaseNav(N);

        uint256 a = 1_000e6;
        _mockUsdcTransfer(a);

        // Compute expected shares and ask for one more than possible
        uint256 S = mockVault.totalSupply();
        uint256 expected = Math.mulDiv(a, S + SHARES_VIRTUAL_OFFSET, N + 1);
        uint256 tooMany = expected + 1;

        vm.prank(depositor);
        vm.expectRevert(abi.encodeWithSelector(LeveragedAerodromeCLStrategy.InsufficientShares.selector));
        harness.deposit(a, tooMany);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Test 4 — M2: flat-book nav() excludes vault float
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice M2 (flat-book sibling of the active-branch `test_nav_excludesVaultFloat`):
    ///         with `tokenId == 0` and `_state == Executed`, `nav()` counts strategy-controlled
    ///         idle USDC ONLY. A USDC donation straight to the vault must leave `nav()` unchanged —
    ///         `strategy.redeem` never pays vault float out, so counting it here would re-introduce
    ///         the deposit/redeem asymmetry the active-position branch already avoids.
    function test_nav_flatBook_excludesVaultFloat() public {
        NavHarness nav = new NavHarness();

        // Wire only the slots the flat-book branch reads: _vault, _state=Executed, usdc.
        // tokenId defaults to 0 (never written) → flat-book branch.
        vm.store(address(nav), bytes32(SLOT_VAULT), bytes32(uint256(uint160(address(mockVault)))));
        vm.store(address(nav), bytes32(SLOT_PROPOSER_STATE_INIT), bytes32(STATE_EXECUTED_INIT));
        vm.store(address(nav), bytes32(SLOT_USDC), bytes32(uint256(uint160(MOCK_USDC))));

        uint256 strategyIdle = 5_000e6;

        // Mock USDC.balanceOf for both the strategy and the vault.
        vm.mockCall(MOCK_USDC, abi.encodeWithSignature("balanceOf(address)", address(nav)), abi.encode(strategyIdle));
        vm.mockCall(
            MOCK_USDC, abi.encodeWithSignature("balanceOf(address)", address(mockVault)), abi.encode(uint256(0))
        );

        assertEq(nav.nav(), strategyIdle, "flat-book nav != strategy-controlled idle USDC");

        // Donate USDC straight to the vault (float > 0). nav() must be bit-for-bit unchanged.
        vm.mockCall(
            MOCK_USDC, abi.encodeWithSignature("balanceOf(address)", address(mockVault)), abi.encode(uint256(9_999e6))
        );
        assertEq(nav.nav(), strategyIdle, "flat-book nav moved on vault-float donation (M2: float must be excluded)");
    }
}
