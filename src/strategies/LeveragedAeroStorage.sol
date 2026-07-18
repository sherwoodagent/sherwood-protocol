// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAeroValuation} from "./LeveragedAeroValuation.sol";

/// @title  LeveragedAeroStorage
/// @notice SINGLE SOURCE OF TRUTH for the delegatecall-shared ERC-7201 storage seam between
///         `LeveragedAerodromeCLStrategy` (the ERC-1167 clone) and `LeveragedAeroManager`
///         (the deployed venue library it delegatecalls). Both import `Layout`,
///         `RedeemRequest`, `STORAGE_SLOT`, the `layout()` slot accessor, and the shared
///         `buildConfig()` valuation-config builder from here — the compiler now enforces
///         the slot discipline the old hand-copied duplicates enforced by comment only.
///
/// @dev    Library choice (vs shared abstract contract): everything here is compile-time
///         (struct/constant definitions) or `internal` (inlined into each caller), so a
///         library adds no deployed code, no linkage, and no inheritance/storage-layout
///         side effects — and unlike an abstract contract it can be used by BOTH a
///         contract (the strategy) and a library (the manager). Under delegatecall the
///         manager runs in the clone's context and the inlined assembly slot load is
///         byte-identical in both callers — semantics are exactly the old duplicated
///         code's.
///
///         CORRUPTION-CRITICAL: live clones store state at `STORAGE_SLOT` with this exact
///         field ORDER. Never change the slot value; never reorder or remove `Layout`
///         fields — new fields are APPEND-ONLY. Three guard layers, each covering what the
///         previous cannot: the COMPILER enforces strategy↔manager identity (both import
///         this one struct); the GOLDEN SNAPSHOT (`script/leveraged-aero-layout.golden.json`,
///         diffed field-by-field, order-significant, by `script/check-storage-parity.sh`
///         step 1b in CI, mirrored by the raw-slot pins in
///         `test/LeveragedAeroLayoutParity.t.sol`) enforces compatibility with the
///         already-deployed clone lineages — i.e. it is what catches a reorder/insert in
///         THIS struct; and the script's step-4 backstops reject a local re-declaration
///         (hand-copied struct / slot constant / slot assembly) creeping back into the
///         strategy or manager.
library LeveragedAeroStorage {
    /// @dev cbBTC is 8dp wrapped Bitcoin; WETH9 on Base is 18dp. Compile-time constants
    ///      consumed by `buildConfig` (the valuation Config carries them explicitly).
    uint8 internal constant CBBTC_DECIMALS = 8;
    uint8 internal constant WETH_DECIMALS = 18;

    /// @dev Escrowed async-redeem request (Lane-B-style, but NO price freeze — shares keep bearing
    ///      PnL until execution, so `cancelRedeem` is not a free look-back option).
    struct RedeemRequest {
        address owner; // request creator; the only address that can cancel / emergency-redeem it
        uint256 shares; // vault shares escrowed in the strategy at request time
        uint256 minAssetsOut; // slippage floor enforced at fulfill (fresh arg at emergencyRedeem)
        uint40 requestedAt; // request timestamp; FULFILL_WINDOW deadman clock anchor
        bool settled; // set once fulfilled / cancelled / emergency-redeemed (double-spend guard)
    }

    /// @custom:storage-location erc7201:leveraged.aero.cl.storage
    struct Layout {
        // valuation config: token / venue / feed addresses
        address usdc;
        address mUsdc;
        address mCbBTC; // LeveragedAeroValuation.Config.cbBTCMarket
        address mWeth; // LeveragedAeroValuation.Config.wethMarket
        address cbBTC;
        address weth;
        address pool;
        address cbBTCFeed;
        address wethFeed;
        address usdcFeed;
        address sequencerFeed;
        uint256 maxDelay;
        uint256 gracePeriod;
        uint16 calmDeviationTicks;
        uint32 twapWindow;
        // venue / protocol addresses (not in Config)
        address comptroller;
        address npm;
        address gauge;
        address swapRouter;
        int24 tickSpacing;
        // risk params
        uint16 targetLtvBps;
        uint16 maxLtvBps;
        uint16 minHealthBps;
        uint16 maxSlippageBps;
        uint16 usdcCollateralFactorBps; // USDC collateral factor from Moonwell at init (8800 = 88%)
        // position state (all zero pre-deploy / post-settle)
        uint256 tokenId; // active CL position; 0 == flat book
        int24 posTickLower;
        int24 posTickUpper;
        // fee params + state
        uint16 managementFeeBps;
        uint16 performanceFeeBps;
        address feeRecipient;
        uint256 hwmPerShare; // HWM nav-per-share (1e18 WAD), 0 until first deposit
        uint256 lastFeeAccrualTimestamp;
        uint256 protocolFeeOwed; // accrued protocol-fee USDC liability (6dp); discharged in redeem/compound/settle
        // ── appended for the L9 compound oracle floor ──
        address aeroUsdFeed; // AERO/USD aggregator (8dp) — floors compound()'s AERO→USDC swap
        // ── LAST fields: appended for the escrowed async-redeem queue ──
        uint256 nextRedeemRequestId; // monotonic id cursor for `redeemRequests`
        mapping(uint256 => RedeemRequest) redeemRequests; // id → escrowed async redeem
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("leveraged.aero.cl.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant STORAGE_SLOT = 0x405ae0b144079093e970849fdffdcb2a514e44968598c6c5c73444496e844900;

    /// @dev ERC-7201 diamond-storage accessor. Inlined (internal) into strategy and manager,
    ///      so the delegatecalled manager resolves the CLONE's storage — same as before.
    function layout() internal pure returns (Layout storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /// @dev Build the `LeveragedAeroValuation.Config` from stored state — the shared body of
    ///      the strategy's and manager's `_config()`. Field-by-field (not struct-literal) so
    ///      the Yul IR emits one sload→mstore per field, avoiding the 18-live-variable
    ///      overflow struct-literals trigger under via_ir.
    /// @param vaultAddr The strategy passes its `vault()` (NAV excludes vault float — M2);
    ///                  the manager passes `address(0)` (calm-gate ignores the vault term).
    function buildConfig(address vaultAddr) internal view returns (LeveragedAeroValuation.Config memory c) {
        Layout storage $ = layout();
        c.usdc = $.usdc;
        c.vault = vaultAddr;
        c.mUsdc = $.mUsdc;
        c.cbBTCMarket = $.mCbBTC;
        c.wethMarket = $.mWeth;
        c.cbBTC = $.cbBTC;
        c.weth = $.weth;
        c.cbBTCDecimals = CBBTC_DECIMALS;
        c.wethDecimals = WETH_DECIMALS;
        c.pool = $.pool;
        c.cbBTCFeed = $.cbBTCFeed;
        c.wethFeed = $.wethFeed;
        c.usdcFeed = $.usdcFeed;
        c.sequencerFeed = $.sequencerFeed;
        c.maxDelay = $.maxDelay;
        c.gracePeriod = $.gracePeriod;
        c.calmDeviationTicks = $.calmDeviationTicks;
        c.twapWindow = $.twapWindow;
    }
}
