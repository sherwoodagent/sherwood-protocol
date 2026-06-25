// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";

/// @notice Exposes `_assertHealthy` (internal) for offline unit testing.
///         Deployed via `new HealthHarness()` — the BaseStrategy constructor sets
///         `_initialized = true` on the template, locking `initialize()`.
///         We bypass init entirely and write only the storage slots that
///         `_assertHealthy` reads.
contract HealthHarness is LeveragedAerodromeCLStrategy {
    function callAssertHealthy() external view {
        _assertHealthy();
    }
}

/// @title  LeveragedAeroCLHealthTest
/// @notice Offline (no-fork) unit tests for `_assertHealthy`:
///           – Happy path: 50 % LTV + zero Moonwell shortfall → no revert.
///           – Early-return path: both borrow balances zero → no oracle calls.
///           – LTV gate: 100 % LTV > 65 % maxLtvBps → reverts UnhealthyPosition(10_000, 6_500).
///           – Moonwell belt – shortfall > 0 → reverts UnhealthyPosition(5_000, 6_500).
///           – Moonwell belt – error code != 0 → reverts UnhealthyPosition(5_000, 6_500).
///
///         All external calls are intercepted by `vm.mockCall`.
///         Prices: BTC $100 k (1e13 8dp), ETH $2.5 k (250_000_000_000 8dp), USDC $1 (1e8 8dp).
///         Collateral: 50_000e6 mUSDC balance at 1e18 exchange rate → 50_000e6 USDC face.
contract LeveragedAeroCLHealthTest is Test {
    // ── storage slot numbers (from `forge inspect LeveragedAerodromeCLStrategy storageLayout`) ──
    //
    // Simple full-slot address fields:
    uint256 private constant SLOT_MUSDC = 4; // address, offset 0
    uint256 private constant SLOT_MCBBTC = 5; // address, offset 0
    uint256 private constant SLOT_MWETH = 6; // address, offset 0
    uint256 private constant SLOT_CBBTCFEED = 10; // address, offset 0
    uint256 private constant SLOT_WETHFEED = 11; // address, offset 0
    uint256 private constant SLOT_USDCFEED = 12; // address, offset 0
    uint256 private constant SLOT_SEQFEED = 13; // address, offset 0
    uint256 private constant SLOT_MAX_DELAY = 14; // uint256, full slot
    uint256 private constant SLOT_GRACE_PERIOD = 15; // uint256, full slot
    //
    // Packed slot 16:  calmDeviationTicks(uint16,off=0) + twapWindow(uint32,off=2)
    //                  + comptroller(address,off=6)
    // comptroller starts at byte offset 6 → bit offset 48.
    uint256 private constant SLOT_16 = 16;
    //
    // Packed slot 19:  swapRouter(address,off=0) + tickSpacing(int24,off=20)
    //                  + targetLtvBps(uint16,off=23) + maxLtvBps(uint16,off=25)
    //                  + minHealthBps(uint16,off=27) + maxSlippageBps(uint16,off=29)
    // maxLtvBps starts at byte offset 25 → bit offset 200.
    uint256 private constant SLOT_19 = 19;

    // ── mock contract addresses ──
    address private constant MUSDC_MOCK = address(0x1001);
    address private constant MCBBTC_MOCK = address(0x1002);
    address private constant MWETH_MOCK = address(0x1003);
    address private constant CBBTCFEED_MOCK = address(0x1004);
    address private constant WETHFEED_MOCK = address(0x1005);
    address private constant USDCFEED_MOCK = address(0x1006);
    address private constant SEQFEED_MOCK = address(0x1007);
    address private constant COMPTROLLER_MOCK = address(0x1008);

    // ── oracle prices (8dp Chainlink USD feeds) ──
    // BTC $100 k: 100_000 × 10^8 = 10^13
    uint256 private constant P_BTC = 10_000_000_000_000;
    // ETH $2.5 k: 2_500 × 10^8 = 2.5 × 10^11
    uint256 private constant P_ETH = 250_000_000_000;
    // USDC $1: 1 × 10^8
    uint256 private constant P_USDC = 100_000_000;

    // ── collateral: 50_000e6 mUSDC × 1e18 exchange rate / 1e18 = 50_000e6 USDC face ──
    uint256 private constant MTOKEN_BAL = 50_000e6;
    uint256 private constant EXCH_RATE = 1e18;

    // ── health cap ──
    uint16 private constant MAX_LTV_BPS = 6_500; // 65 %

    HealthHarness private harness;

    // ─────────────────────────────────────────────────────────────
    // setUp — wire storage + shared mocks
    // ─────────────────────────────────────────────────────────────

    function setUp() public {
        harness = new HealthHarness();

        // ── simple address slots ──
        _storeAddr(SLOT_MUSDC, MUSDC_MOCK);
        _storeAddr(SLOT_MCBBTC, MCBBTC_MOCK);
        _storeAddr(SLOT_MWETH, MWETH_MOCK);
        _storeAddr(SLOT_CBBTCFEED, CBBTCFEED_MOCK);
        _storeAddr(SLOT_WETHFEED, WETHFEED_MOCK);
        _storeAddr(SLOT_USDCFEED, USDCFEED_MOCK);
        _storeAddr(SLOT_SEQFEED, SEQFEED_MOCK);

        // maxDelay = type(uint256).max — feed staleness check never fires in tests.
        vm.store(address(harness), bytes32(SLOT_MAX_DELAY), bytes32(type(uint256).max));
        // gracePeriod = 0 — seqStartedAt=0, block.timestamp(1)-0=1 > 0 passes the gate.
        vm.store(address(harness), bytes32(SLOT_GRACE_PERIOD), bytes32(uint256(0)));

        // slot 16: comptroller at byte-offset 6 (bit-offset 48).
        // calmDeviationTicks=0 and twapWindow=0 are fine; _assertHealthy doesn't use them.
        vm.store(address(harness), bytes32(SLOT_16), bytes32(uint256(uint160(COMPTROLLER_MOCK)) << 48));

        // slot 19: maxLtvBps at byte-offset 25 (bit-offset 200).
        // swapRouter=0, tickSpacing=0, targetLtvBps=0 are fine; only maxLtvBps is read.
        vm.store(address(harness), bytes32(SLOT_19), bytes32(uint256(MAX_LTV_BPS) << 200));

        // ── default mocks (collateral) ──
        // mUsdc.balanceOf(harness) → MTOKEN_BAL
        vm.mockCall(
            MUSDC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(harness)),
            abi.encode(MTOKEN_BAL)
        );
        // mUsdc.exchangeRateStored() → EXCH_RATE
        vm.mockCall(
            MUSDC_MOCK, abi.encodeWithSelector(bytes4(keccak256("exchangeRateStored()"))), abi.encode(EXCH_RATE)
        );

        // ── default mocks (Chainlink) ──
        // Sequencer uptime feed: answer=0 (up), seqStartedAt=0 (old enough for gracePeriod=0).
        vm.mockCall(
            SEQFEED_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(0), uint256(0), uint256(block.timestamp), uint80(1))
        );
        // BTC/USD: $100 k
        vm.mockCall(
            CBBTCFEED_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(P_BTC), uint256(1), uint256(block.timestamp), uint80(1))
        );
        vm.mockCall(CBBTCFEED_MOCK, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
        // ETH/USD: $2.5 k
        vm.mockCall(
            WETHFEED_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(P_ETH), uint256(1), uint256(block.timestamp), uint80(1))
        );
        vm.mockCall(WETHFEED_MOCK, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
        // USDC/USD: $1
        vm.mockCall(
            USDCFEED_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("latestRoundData()"))),
            abi.encode(uint80(1), int256(P_USDC), uint256(1), uint256(block.timestamp), uint80(1))
        );
        vm.mockCall(USDCFEED_MOCK, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
    }

    // ─────────────────────────────────────────────────────────────
    // Tests
    // ─────────────────────────────────────────────────────────────

    /// @notice 50 % LTV + zero Moonwell shortfall → no revert.
    ///
    ///         Debt sizing (USDC 6dp face at mock prices):
    ///           cbBTC: 12_500_000 units (0.125 BTC) × $100 k = $12 500 → 12_500e6 USDC
    ///           WETH : 5e18 units (5 ETH)           × $2.5 k = $12 500 → 12_500e6 USDC
    ///           Total = 25_000e6. LTV = 25_000/50_000 = 50 % < 65 % ✓
    function test_healthy_noRevert() public {
        vm.mockCall(
            MCBBTC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(12_500_000)) // 0.125 cbBTC (8dp)
        );
        vm.mockCall(
            MWETH_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(5e18)) // 5 WETH (18dp)
        );
        // Moonwell: no error, excess liquidity, no shortfall.
        vm.mockCall(
            COMPTROLLER_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("getAccountLiquidity(address)")), address(harness)),
            abi.encode(uint256(0), uint256(50_000e6), uint256(0))
        );

        harness.callAssertHealthy(); // must NOT revert
    }

    /// @notice Both borrow balances are zero → early return, no oracle calls fired.
    function test_noDebt_noRevert() public {
        vm.mockCall(
            MCBBTC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(0))
        );
        vm.mockCall(
            MWETH_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(0))
        );
        // No Chainlink or Comptroller calls expected; early-return path.

        harness.callAssertHealthy(); // must NOT revert
    }

    /// @notice 100 % LTV > 65 % maxLtvBps → reverts UnhealthyPosition(10_000, 6_500).
    ///
    ///         Debt sizing (USDC 6dp face at mock prices):
    ///           cbBTC: 25_000_000 units (0.25 BTC) × $100 k = $25 000 → 25_000e6 USDC
    ///           WETH : 10e18 units (10 ETH)         × $2.5 k = $25 000 → 25_000e6 USDC
    ///           Total = 50_000e6. LTV = 50_000/50_000 = 100 % > 65 % → revert ✓
    function test_unhealthy_ltvExceedsMax() public {
        vm.mockCall(
            MCBBTC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(25_000_000)) // 0.25 cbBTC (8dp)
        );
        vm.mockCall(
            MWETH_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(10e18)) // 10 WETH (18dp)
        );
        // Comptroller not reached — LTV check fires first.

        vm.expectRevert(
            abi.encodeWithSelector(
                LeveragedAerodromeCLStrategy.UnhealthyPosition.selector, uint256(10_000), uint256(6_500)
            )
        );
        harness.callAssertHealthy();
    }

    /// @notice 50 % LTV but Moonwell reports shortfall > 0 → reverts UnhealthyPosition(5_000, 6_500).
    function test_unhealthy_moonwellShortfall() public {
        vm.mockCall(
            MCBBTC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(12_500_000))
        );
        vm.mockCall(
            MWETH_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(5e18))
        );
        // Moonwell signals shortfall.
        vm.mockCall(
            COMPTROLLER_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("getAccountLiquidity(address)")), address(harness)),
            abi.encode(uint256(0), uint256(0), uint256(1)) // err=0, liquidity=0, shortfall=1
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LeveragedAerodromeCLStrategy.UnhealthyPosition.selector, uint256(5_000), uint256(6_500)
            )
        );
        harness.callAssertHealthy();
    }

    /// @notice 50 % LTV but Moonwell returns error code 1 → reverts UnhealthyPosition(5_000, 6_500).
    function test_unhealthy_moonwellErrorCode() public {
        vm.mockCall(
            MCBBTC_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(12_500_000))
        );
        vm.mockCall(
            MWETH_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("borrowBalanceStored(address)")), address(harness)),
            abi.encode(uint256(5e18))
        );
        // Moonwell returns non-zero error code.
        vm.mockCall(
            COMPTROLLER_MOCK,
            abi.encodeWithSelector(bytes4(keccak256("getAccountLiquidity(address)")), address(harness)),
            abi.encode(uint256(1), uint256(0), uint256(0)) // err=1, liquidity=0, shortfall=0
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                LeveragedAerodromeCLStrategy.UnhealthyPosition.selector, uint256(5_000), uint256(6_500)
            )
        );
        harness.callAssertHealthy();
    }

    // ─────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────

    function _storeAddr(uint256 slot, address addr) private {
        vm.store(address(harness), bytes32(slot), bytes32(uint256(uint160(addr))));
    }
}
