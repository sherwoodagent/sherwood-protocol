// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {LeveragedAeroStorage} from "../src/strategies/LeveragedAeroStorage.sol";

/// @dev Probe contracts: declaring the shared ERC-7201 `Layout` struct as a plain state
///      variable makes the compiler emit its full member slot/offset/type breakdown in
///      `forge inspect <probe> storageLayout` — consumed by `script/check-storage-parity.sh`.
///      Post-seam both probes resolve the SAME `LeveragedAeroStorage.Layout`, so the
///      strategy↔manager diff (script step 1) is empty by construction — the compiler owns
///      that identity. What the probes additionally feed is step 1b: the golden per-field
///      snapshot (`script/leveraged-aero-layout.golden.json`) that pins the layout the
///      DEPLOYED clone lineages already store, order-significant.
contract StrategyLayoutProbe {
    LeveragedAeroStorage.Layout internal l;
}

contract ManagerLayoutProbe {
    LeveragedAeroStorage.Layout internal l;
}

/// @notice Guards for the delegatecall-shared storage seam between
///         `LeveragedAerodromeCLStrategy` and `LeveragedAeroManager`. Three layers:
///         compiler = strategy↔manager identity (one shared struct); golden snapshot
///         (script/check-storage-parity.sh step 1b) = deployed-lineage compatibility,
///         field-by-field and order-significant; the raw-slot pins below = the same
///         order-sensitivity inside `forge test` (no ffi), so a reorder/insert fails the
///         unit suite even when the shell script isn't run.
contract LeveragedAeroLayoutParityTest is Test {
    /// @dev The live clones' ERC-7201 base slot. Frozen: changing it orphans every
    ///      deployed clone's storage.
    bytes32 internal constant EXPECTED_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @notice The pinned slot must equal its documented ERC-7201 derivation —
    ///         keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1))
    ///         & ~bytes32(uint256(0xff)). Fails loudly if anyone edits the hex or the
    ///         namespace string in one place only.
    function test_storageSlot_matchesErc7201Derivation() public pure {
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(derived, EXPECTED_SLOT);
        assertEq(LeveragedAeroStorage.STORAGE_SLOT, EXPECTED_SLOT);
    }

    function _raw(uint256 slotIndex) private view returns (bytes32) {
        return vm.load(address(this), bytes32(uint256(EXPECTED_SLOT) + slotIndex));
    }

    /// @notice Golden raw-slot pin: writes a distinct sentinel into EVERY `Layout` field
    ///         through the struct, then asserts each value lands at its HARDCODED
    ///         (slot, offset) — the assignment live clones already store. Order-sensitive
    ///         by construction: reordering / inserting / retyping a field moves at least
    ///         one sentinel to a different raw word and fails an `assertEq` below.
    ///         New fields are APPEND-ONLY: extend this test (and regenerate the shell
    ///         golden) without touching the existing pins.
    function test_layout_fieldsPinnedToFrozenRawSlots() public {
        LeveragedAeroStorage.Layout storage $ = LeveragedAeroStorage.layout();

        // ── valuation config ──
        $.usdc = address(0xA1);
        $.mUsdc = address(0xA2);
        $.mCbBTC = address(0xA3);
        $.mWeth = address(0xA4);
        $.cbBTC = address(0xA5);
        $.weth = address(0xA6);
        $.pool = address(0xA7);
        $.cbBTCFeed = address(0xA8);
        $.wethFeed = address(0xA9);
        $.usdcFeed = address(0xAA);
        $.sequencerFeed = address(0xAB);
        $.maxDelay = 111;
        $.gracePeriod = 222;
        $.calmDeviationTicks = 333;
        $.twapWindow = 444;
        // ── venue / protocol addresses ──
        $.comptroller = address(0xAC);
        $.npm = address(0xAD);
        $.gauge = address(0xAE);
        $.swapRouter = address(0xAF);
        $.tickSpacing = 55;
        // ── risk params ──
        $.targetLtvBps = 601;
        $.maxLtvBps = 602;
        $.minHealthBps = 603;
        $.maxSlippageBps = 604;
        $.usdcCollateralFactorBps = 605;
        // ── position state ──
        $.tokenId = 777;
        $.posTickLower = 71;
        $.posTickUpper = 72;
        // ── fee params + state ──
        $.managementFeeBps = 801;
        $.performanceFeeBps = 802;
        $.feeRecipient = address(0xB1);
        $.hwmPerShare = 901;
        $.lastFeeAccrualTimestamp = 902;
        $.protocolFeeOwed = 903;
        // ── appended fields ──
        $.aeroUsdFeed = address(0xB2);
        $.nextRedeemRequestId = 1001;
        $.redeemRequests[7] = LeveragedAeroStorage.RedeemRequest({
            owner: address(0xB3), shares: 1101, minAssetsOut: 1102, requestedAt: 1103, settled: true
        });

        // Full-word slots (one field each).
        assertEq(_raw(0), bytes32(uint256(uint160(address(0xA1)))), "slot 0: usdc");
        assertEq(_raw(1), bytes32(uint256(uint160(address(0xA2)))), "slot 1: mUsdc");
        assertEq(_raw(2), bytes32(uint256(uint160(address(0xA3)))), "slot 2: mCbBTC");
        assertEq(_raw(3), bytes32(uint256(uint160(address(0xA4)))), "slot 3: mWeth");
        assertEq(_raw(4), bytes32(uint256(uint160(address(0xA5)))), "slot 4: cbBTC");
        assertEq(_raw(5), bytes32(uint256(uint160(address(0xA6)))), "slot 5: weth");
        assertEq(_raw(6), bytes32(uint256(uint160(address(0xA7)))), "slot 6: pool");
        assertEq(_raw(7), bytes32(uint256(uint160(address(0xA8)))), "slot 7: cbBTCFeed");
        assertEq(_raw(8), bytes32(uint256(uint160(address(0xA9)))), "slot 8: wethFeed");
        assertEq(_raw(9), bytes32(uint256(uint160(address(0xAA)))), "slot 9: usdcFeed");
        assertEq(_raw(10), bytes32(uint256(uint160(address(0xAB)))), "slot 10: sequencerFeed");
        assertEq(_raw(11), bytes32(uint256(111)), "slot 11: maxDelay");
        assertEq(_raw(12), bytes32(uint256(222)), "slot 12: gracePeriod");
        assertEq(_raw(14), bytes32(uint256(uint160(address(0xAD)))), "slot 14: npm");
        assertEq(_raw(15), bytes32(uint256(uint160(address(0xAE)))), "slot 15: gauge");
        assertEq(_raw(17), bytes32(uint256(605)), "slot 17: usdcCollateralFactorBps");
        assertEq(_raw(18), bytes32(uint256(777)), "slot 18: tokenId");
        assertEq(_raw(20), bytes32(uint256(901)), "slot 20: hwmPerShare");
        assertEq(_raw(21), bytes32(uint256(902)), "slot 21: lastFeeAccrualTimestamp");
        assertEq(_raw(22), bytes32(uint256(903)), "slot 22: protocolFeeOwed");
        assertEq(_raw(23), bytes32(uint256(uint160(address(0xB2)))), "slot 23: aeroUsdFeed");
        assertEq(_raw(24), bytes32(uint256(1001)), "slot 24: nextRedeemRequestId");

        // Packed slot 13: calmDeviationTicks(u16 @0) | twapWindow(u32 @2) | comptroller(addr @6).
        assertEq(
            _raw(13),
            bytes32(uint256(333) | (uint256(444) << 16) | (uint256(uint160(address(0xAC))) << 48)),
            "slot 13: calmDeviationTicks|twapWindow|comptroller"
        );

        // Packed slot 16: swapRouter(addr @0) | tickSpacing(int24 @20) | targetLtvBps(u16 @23)
        //                 | maxLtvBps(u16 @25) | minHealthBps(u16 @27) | maxSlippageBps(u16 @29).
        assertEq(
            _raw(16),
            bytes32(
                uint256(uint160(address(0xAF))) | (uint256(55) << 160) | (uint256(601) << 184) | (uint256(602) << 200)
                    | (uint256(603) << 216) | (uint256(604) << 232)
            ),
            "slot 16: swapRouter|tickSpacing|ltv/health/slippage bps"
        );

        // Packed slot 19: posTickLower(int24 @0) | posTickUpper(int24 @3) | managementFeeBps(u16 @6)
        //                 | performanceFeeBps(u16 @8) | feeRecipient(addr @10).
        assertEq(
            _raw(19),
            bytes32(
                uint256(71) | (uint256(72) << 24) | (uint256(801) << 48) | (uint256(802) << 64)
                    | (uint256(uint160(address(0xB1))) << 80)
            ),
            "slot 19: posTicks|feeBps|feeRecipient"
        );

        // Mapping at slot 25: entry base keccak256(abi.encode(key, baseSlot + 25)); nested
        // RedeemRequest spans 4 words: owner @0 | shares @1 | minAssetsOut @2 |
        // (requestedAt u40 @+3/0, settled bool @+3/5).
        uint256 entry = uint256(keccak256(abi.encode(uint256(7), uint256(EXPECTED_SLOT) + 25)));
        assertEq(
            vm.load(address(this), bytes32(entry)),
            bytes32(uint256(uint160(address(0xB3)))),
            "redeemRequests[7] +0: owner"
        );
        assertEq(vm.load(address(this), bytes32(entry + 1)), bytes32(uint256(1101)), "redeemRequests[7] +1: shares");
        assertEq(
            vm.load(address(this), bytes32(entry + 2)), bytes32(uint256(1102)), "redeemRequests[7] +2: minAssetsOut"
        );
        assertEq(
            vm.load(address(this), bytes32(entry + 3)),
            bytes32(uint256(1103) | (uint256(1) << 40)),
            "redeemRequests[7] +3: requestedAt|settled"
        );
    }
}
