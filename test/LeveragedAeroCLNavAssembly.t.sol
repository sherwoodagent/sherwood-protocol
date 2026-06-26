// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {INonfungiblePositionManager} from "../src/interfaces/ISlipstream.sol";

/// @notice Exposes `_npmPositionData` (internal after the visibility change) for testing.
///         Deployed via `new NavHarness()` — the BaseStrategy constructor runs and sets
///         `_initialized = true`, locking `initialize()`.  We bypass init entirely and write
///         only the two diamond-storage slots that `_npmPositionData` reads: `npm`
///         (STRAT_BASE + 14) and `tokenId` (STRAT_BASE + 18).
contract NavHarness is LeveragedAerodromeCLStrategy {
    function exposeNpmPositionData() external view returns (int24, int24, uint128) {
        return _npmPositionData();
    }
}

/// @title LeveragedAeroCLNavAssemblyTest
/// @notice Offline (no-fork) unit tests that lock in the assembly offsets and
///         int24 sign-extension inside `LeveragedAerodromeCLStrategy._npmPositionData`.
///
///         The NPM is mocked via `vm.mockCall` so no RPC is required.
///         We use `vm.store` to write `npm` and `tokenId` into the harness contract's
///         storage without calling `initialize` (which would require a full param set).
contract LeveragedAeroCLNavAssemblyTest is Test {
    // ── Storage slot constants ──
    // Strategy state lives in ERC-7201 diamond storage at STRAT_BASE
    // (= keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~0xff).
    // Field slot = STRAT_BASE + (oldSequentialSlot - 3); packing within the Layout struct
    // matches the old sequential layout.
    //   STRAT_BASE + 14 = npm     (address, offset 0)  [was slot 17]
    //   STRAT_BASE + 18 = tokenId (uint256, full slot) [was slot 21]
    uint256 private constant STRAT_BASE = uint256(0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900);
    uint256 private constant SLOT_NPM = STRAT_BASE + 14;
    uint256 private constant SLOT_TOKEN_ID = STRAT_BASE + 18;

    address private constant NPM_MOCK = address(0xABCD);

    NavHarness private harness;

    function setUp() public {
        harness = new NavHarness();
        // Wire up the npm address into the harness's storage.
        vm.store(address(harness), bytes32(SLOT_NPM), bytes32(uint256(uint160(NPM_MOCK))));
    }

    /// @notice Builds the 12-field ABI-encoded returndata for `positions(tokenId)`.
    ///         Field order (Slipstream NPM):
    ///           [0] nonce  [1] operator  [2] token0  [3] token1  [4] tickSpacing
    ///           [5] tickLower  [6] tickUpper  [7] liquidity
    ///           [8] fgRow0  [9] fgRow1  [10] owed0  [11] owed1
    function _mockPositionsReturn(int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        pure
        returns (bytes memory)
    {
        return abi.encode(
            uint96(0), // nonce
            address(0), // operator
            address(0), // token0
            address(0), // token1
            int24(100), // tickSpacing
            tickLower, // [5]
            tickUpper, // [6]
            liquidity, // [7]
            uint256(0), // feeGrowthInside0LastX128
            uint256(0), // feeGrowthInside1LastX128
            uint128(0), // tokensOwed0
            uint128(0) // tokensOwed1
        );
    }

    // ─────────────────────────────────────────────────────────────
    // Test 1: full-range negative tickLower (-887220) with 1e15 liquidity
    // ─────────────────────────────────────────────────────────────

    function test_npmPositionData_negativeTickLower_fullRange() public {
        int24 expectedTickLower = -887220;
        int24 expectedTickUpper = 887220;
        uint128 expectedLiquidity = 1_000_000_000_000_000;

        vm.store(address(harness), bytes32(SLOT_TOKEN_ID), bytes32(uint256(1)));

        vm.mockCall(
            NPM_MOCK,
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, uint256(1)),
            _mockPositionsReturn(expectedTickLower, expectedTickUpper, expectedLiquidity)
        );

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = harness.exposeNpmPositionData();

        assertEq(tickLower, expectedTickLower, "tickLower sign-extension failed");
        assertEq(tickUpper, expectedTickUpper, "tickUpper mismatch");
        assertEq(liquidity, expectedLiquidity, "liquidity mismatch");
    }

    // ─────────────────────────────────────────────────────────────
    // Test 2: narrow negative range (-100 / +100) confirms a different
    //         negative tick still round-trips correctly through the assembly.
    // ─────────────────────────────────────────────────────────────

    function test_npmPositionData_negativeTickLower_narrowRange() public {
        int24 expectedTickLower = -100;
        int24 expectedTickUpper = 100;
        uint128 expectedLiquidity = 5_000_000;

        vm.store(address(harness), bytes32(SLOT_TOKEN_ID), bytes32(uint256(2)));

        vm.mockCall(
            NPM_MOCK,
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, uint256(2)),
            _mockPositionsReturn(expectedTickLower, expectedTickUpper, expectedLiquidity)
        );

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = harness.exposeNpmPositionData();

        assertEq(tickLower, expectedTickLower, "tickLower sign-extension failed (narrow)");
        assertEq(tickUpper, expectedTickUpper, "tickUpper mismatch (narrow)");
        assertEq(liquidity, expectedLiquidity, "liquidity mismatch (narrow)");
    }

    // ─────────────────────────────────────────────────────────────
    // Test 3: revert on staticcall failure
    // ─────────────────────────────────────────────────────────────

    function test_npmPositionData_revertsOnCallFailure() public {
        vm.store(address(harness), bytes32(SLOT_TOKEN_ID), bytes32(uint256(99)));

        // vm.mockCallRevert makes the mock revert; the harness should then surface InvalidNpmReturn.
        vm.mockCallRevert(
            NPM_MOCK,
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, uint256(99)),
            "forced failure"
        );

        vm.expectRevert(LeveragedAerodromeCLStrategy.InvalidNpmReturn.selector);
        harness.exposeNpmPositionData();
    }

    // ─────────────────────────────────────────────────────────────
    // Test 4: revert on short returndata (< 0x120 bytes)
    // ─────────────────────────────────────────────────────────────

    function test_npmPositionData_revertsOnShortReturndata() public {
        vm.store(address(harness), bytes32(SLOT_TOKEN_ID), bytes32(uint256(3)));

        // Return only 4 words (128 bytes < 0x120) — truncated response.
        bytes memory shortRet = abi.encode(uint256(0), uint256(0), uint256(0), uint256(0));

        vm.mockCall(
            NPM_MOCK, abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, uint256(3)), shortRet
        );

        vm.expectRevert(LeveragedAerodromeCLStrategy.InvalidNpmReturn.selector);
        harness.exposeNpmPositionData();
    }
}
