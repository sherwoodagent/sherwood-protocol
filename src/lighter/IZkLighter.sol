// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Minimal ZkLighter (Lighter perp DEX) entrypoints used by the
///         contract-owned-account harness and the future LighterPerpStrategy.
/// @dev    Verified against the deployed 4663 proxy
///         0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d. The venue compiles under
///         solc 0.8.33; our callers compile under 0.8.28 — only the ABI
///         (selectors + encoding) must match, and it does.
///
///         Enums are declared as plain uint8 here — a uint8 argument ABI-encodes
///         identically to the venue's uint8-backed enum params:
///           RouteType: Perps = 0, Spot = 1   (perp margin uses Perps = 0)
///           OrderType: Limit = 0, Market = 1
///           isAsk:     0 = bid/long, 1 = ask/sell
///
///         All mutating calls except withdrawPendingBalance are async priority
///         requests — poll between steps, do not chain synchronously.
interface IZkLighter {
    /// @notice Deposit `amount` of `assetIndex` into `to`'s margin account.
    /// @dev    Pulls ERC20 via safeTransferFrom(msg.sender, this, amount) — the
    ///         caller MUST approve the proxy first. For ERC20 deposits msg.value
    ///         must be 0. First deposit registers the account (see
    ///         addressToAccountIndex, which populates in this tx).
    function deposit(address to, uint16 assetIndex, uint8 routeType, uint256 amount) external payable;

    /// @notice Register / rotate an L2 trading (API) key for `accountIndex`.
    /// @param  apiKeyIndex 2..254 (0/1 reserved by the web app, 255 out of range).
    /// @param  pubKey      exactly 40 bytes, Goldilocks-canonical (5×uint64-LE,
    ///                     each nonzero and < 0xffffffff00000001).
    /// @dev    Auth: msg.sender must own the account; account must already exist.
    function changePubKey(uint48 accountIndex, uint8 apiKeyIndex, bytes calldata pubKey) external;

    /// @notice Place an order for `accountIndex`. baseAmount = 0 closes the full position.
    /// @param  price     protective bound in [1, 2^32-1]; market SELL close uses
    ///                   1, market BUY close uses 2^32-1.
    /// @dev    Auth: msg.sender. Perp markets only (marketIndex <= 254).
    function createOrder(
        uint48 accountIndex,
        uint16 marketIndex,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) external;

    /// @notice Cancel every resting order for `accountIndex`. Auth: msg.sender.
    function cancelAllOrders(uint48 accountIndex) external;

    /// @notice Queue a withdrawal priority request. baseAmount in asset ticks
    ///         (USDG: 1 USDG = 1_000_000 ticks). Auth: msg.sender. Funds mature
    ///         after ~withdrawalDelay, then getPendingBalance reports them.
    function withdraw(uint48 accountIndex, uint16 assetIndex, uint8 routeType, uint64 baseAmount) external;

    /// @notice Claim a matured pending withdrawal; sends `baseAmount` ticks of
    ///         `assetIndex` to `owner`. Permissionless + nonReentrant — pass the
    ///         account contract as `owner` so funds land back in it.
    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external;

    /// @notice Ticks owed to `owner` for `assetIndex` awaiting claim.
    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128);

    /// @notice Account index for `owner` (0 = unregistered; nonzero after first deposit).
    function addressToAccountIndex(address owner) external view returns (uint48);

    /// @notice Asset index for `token` (USDG => 3).
    function tokenToAssetIndex(address token) external view returns (uint16);
}
