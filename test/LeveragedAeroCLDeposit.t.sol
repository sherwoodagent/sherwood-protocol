// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";

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

    function strategyMint(address to, uint256 shares) external {
        balanceOf[to] += shares;
        totalSupply += shares;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Harness — overrides nav() to return a caller-supplied fixed value
// ─────────────────────────────────────────────────────────────────────────────

/// @dev `new DepositHarness()` runs BaseStrategy's constructor → sets `_initialized = true`
///      on the template instance.  We then write only the storage slots needed for
///      `deposit` via `vm.store`, bypassing the full initialisation path.
contract DepositHarness is LeveragedAerodromeCLStrategy {
    uint256 public fixedNav;

    function setFixedNav(uint256 n) external {
        fixedNav = n;
    }

    function nav() public view virtual override returns (uint256) {
        return fixedNav;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Storage slot constants (from `forge inspect LeveragedAerodromeCLStrategy storage-layout`)
// ─────────────────────────────────────────────────────────────────────────────
//
// slot 1  : _vault        (address, offset 0)
// slot 2  : _proposer     (address, offset 0) | _state (uint8, offset 20) | _initialized (bool, offset 21)
// slot 3  : usdc          (address, offset 0)
// slot 22 : feeRecipient  (address, offset 10) | managementFeeBps (uint16, off 6) | performanceFeeBps (uint16, off 8)
// slot 23 : hwmPerShare   (uint256)
// slot 24 : lastFeeAccrualTimestamp (uint256)
//
// State enum: Pending=0, Executed=1, Settled=2.

/// @title  LeveragedAeroCLDepositUnit
/// @notice Offline (no-fork) unit tests for `deposit`:
///           1. test_deposit_shareFormula          — exact share math against mocked nav.
///           2. test_deposit_noPhantomFee_unit      — no performance fee when nav == HWM, dt == 0.
///           3. test_deposit_minSharesRevert        — reverts InsufficientShares when slippage too tight.
contract LeveragedAeroCLDepositUnit is Test {
    // ── slot numbers ──
    uint256 private constant SLOT_VAULT = 1;
    uint256 private constant SLOT_PROPOSER_STATE_INIT = 2;
    uint256 private constant SLOT_USDC = 3;
    uint256 private constant SLOT_SLOT22 = 22; // feeRecipient packed slot
    uint256 private constant SLOT_HWM = 23;
    uint256 private constant SLOT_LAST_FEE = 24;

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
        // slot 1: _vault
        vm.store(address(harness), bytes32(SLOT_VAULT), bytes32(uint256(uint160(address(mockVault)))));

        // slot 2: _state = Executed (1), _initialized = true
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

        harness.setFixedNav(N);
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

    /// @notice When hwmPerShare encodes the current nav (no gain) and the same block
    ///         is used (dt == 0 → management fee = 0), crystallizeFees mints ZERO
    ///         performance-fee shares to feeRecipient.
    function test_deposit_noPhantomFee_unit() public {
        uint256 N = 50_000e6;
        harness.setFixedNav(N);

        // Set hwmPerShare = N * 1e18 / INITIAL_SHARES  (at-parity: nav == HWM)
        uint256 hwm = Math.mulDiv(N, 1e18, INITIAL_SHARES);
        vm.store(address(harness), bytes32(SLOT_HWM), bytes32(hwm));

        // lastFeeAccrualTimestamp already equals block.timestamp (set in setUp)
        // → dt = 0 → management fee = 0; nav at HWM → performance fee = 0.

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
        harness.setFixedNav(N);

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
}
