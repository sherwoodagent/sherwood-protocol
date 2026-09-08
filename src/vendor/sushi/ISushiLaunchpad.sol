// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Vendored Sushi Launchpad V1 interface
/// @notice PROVENANCE: transcribed from the verified `SushiLaunchpad` source at
///         `0x104f1ab42674565ec3df0bfebccc4186f72fa7ed` on Robinhood Chain 4663
///         (compiler `v0.8.36`), fetched from `robinhoodchain.blockscout.com`.
///         Every selector, struct field order and field width below is
///         byte-identical to that source.
///
///         REDUCED SURFACE — vendored is only what `SushiLaunchAdapter` calls,
///         following the `ConcentratedLiquidityStrategy` / `IMorpho` precedent
///         of vendoring the consumed surface and saying so. Deliberately NOT
///         vendored, because nothing in this repo calls them:
///           - `launch(...)`            — the no-dev-buy variant. Unusable here:
///                                        the venue mints the whole fixed supply
///                                        to itself and the creator receives ZERO
///                                        tokens, so a launch without an initial
///                                        buy leaves the fund with no reserve.
///           - `launchAndBuyNative(...)`— the native-quote variant. The adapter
///                                        pairs against an ERC-20 quote chosen
///                                        per proposal, never raw ETH.
///           - the owner/admin setters  (`setQuoteTokenPriceFeed`,
///             fee and reserve knobs, pausing, sweeps) — venue governance, not
///             ours. Their effects are read live through `launchFee()` and
///             `quoteTokenPriceFeed()` rather than mirrored.
///           - the events, the launch enumeration views, and the
///             protocol-reserve withdrawal path.
///
///         PRAGMA: upstream compiles under `v0.8.36`; this file declares
///         `0.8.28` to match the repo. Behaviour-preserving — an `interface`
///         emits no bytecode, and ABI encoding of these signatures is identical
///         across both compiler versions (no user-defined value types, no
///         transient storage, no custom-error layout changes between them).
///
///         VENUE ECONOMICS the adapter depends on (verified live on 4663, and
///         the reason each member below is here):
///           - Fixed supply `1e9 * 1e18`, minted to the launchpad. The creator
///             receives NOTHING, so `launchAndBuy`'s initial buy IS the fund's
///             reserve — hence the adapter's insistence on a nonzero `quoteIn`.
///           - `launchFee()` is `5e14` wei of NATIVE ETH, taken from `msg.value`
///             (not from the quote), and the owner can reprice it — hence the
///             live read in `nativeFeeSource()`.
///           - `defaultSushiFeeBps = 3000`: the creator keeps 70% of LP fees,
///             paid out by the PERMISSIONLESS `distributeFees` in BOTH legs
///             (quote and launch token) straight to the CURRENT creator — hence
///             `collectFees` measuring the creator, never the caller.
///           - `protocolReserveBps = 300`, unlocked at `reserveUnlockAt`; the
///             adapter never touches it and surfaces it only through
///             `LaunchInfo`.
///           - Reverts the adapter relies on rather than duplicating:
///             `ZeroInitialBuyAmount` (amountIn == 0), `PartialInitialBuy` (the
///             buy was not fully consumed — so `quoteSpent == quoteIn` always),
///             `InsufficientInitialBuyOutput` (below `amountOutMinimum`),
///             `UnsupportedQuoteToken` (`quoteTokenPriceFeed[quote] == 0`),
///             `InvalidInitialBuyRecipient` (recipient is the launchpad),
///             `UnknownToken` (`launchInfo` on a token this venue never issued —
///             which is why `phase`/`quoteSupported` read it by raw staticcall).
///           - Every state-changing entry point is `nonReentrant` upstream.
interface ISushiLaunchpad {
    /// @notice Name/symbol of the token the venue will mint. The venue fixes
    ///         supply and initial price, so there is nothing else to state.
    struct TokenConfig {
        string name;
        string symbol;
    }

    /// @notice The same-transaction dev buy. On this venue it is the ONLY way
    ///         to obtain launch tokens at creation.
    /// @param amountIn          Quote pulled from the caller and spent on the
    ///                          buy. Must be nonzero and fully consumable.
    /// @param amountOutMinimum  Venue-enforced slippage floor on the buy.
    /// @param recipient         Who receives the bought tokens — the launchpad
    ///                          itself is rejected.
    struct InitialBuy {
        uint256 amountIn;
        uint256 amountOutMinimum;
        address recipient;
    }

    /// @notice Per-launch venue state. `creator` is the transferable role that
    ///         earns the LP fee share; `address(0)` is never a live creator, so
    ///         a zero here reads as "not a launch this venue issued".
    struct LaunchInfo {
        address creator;
        address quoteToken;
        address pool;
        uint64 reserveUnlockAt;
        bool reserveWithdrawn;
        uint256 reserveAmount;
    }

    /// @notice Mint the token, seed the one-sided V3 position, and execute the
    ///         initial buy — all in this one transaction, which is why the
    ///         adapter reports `Live` immediately and makes `finalize` a no-op.
    /// @dev The native launch fee comes from `msg.value`; the quote comes from
    ///      an ERC-20 allowance on `msg.sender`. Caller becomes `creator`.
    function launchAndBuy(
        TokenConfig calldata tokenConfig,
        address quoteToken,
        uint64 deadline,
        InitialBuy calldata initialBuy
    ) external payable returns (address token, address pool, uint256 positionId, uint256 amountOut);

    /// @notice Permissionless: collect the LP fees and pay the creator share to
    ///         whoever currently holds the creator role — NOT to the caller.
    function distributeFees(address token)
        external
        returns (uint256 quoteCollected, uint256 tokenCollected, uint256 quoteToSushi, uint256 tokenToSushi);

    /// @notice Hand the creator role on. Callable only by the current creator,
    ///         which is what lets a stateless singleton adapter satisfy the
    ///         custody invariant: it is creator for a few opcodes and hands the
    ///         role to the calling strategy before `launch` returns.
    function transferCreator(address token, address newCreator) external;

    /// @notice Per-launch state. REVERTS `UnknownToken` for a token this venue
    ///         never issued — never call it typed from a must-not-revert view.
    function launchInfo(address token) external view returns (LaunchInfo memory);

    /// @notice The registered price aggregator for a quote asset; `address(0)`
    ///         means the venue will not pair against it. Owner-managed, so the
    ///         answer changes without any code change here.
    function quoteTokenPriceFeed(address quoteToken) external view returns (address);

    /// @notice Native-ETH launch fee, in wei. Repriceable by the venue owner.
    function launchFee() external view returns (uint256);

    /// @notice The venue's wrapped-native token — the adapter's fee source.
    function WETH() external view returns (address);

    /// @notice The SushiSwap V3 factory this venue seeds its one-sided launch
    ///         position through.
    /// @dev    Vendored for the DEPLOY CEREMONY, not for the adapter, and the
    ///         distinction matters on this chain: canonical DEX addresses here
    ///         can hold unrelated bytecode, so a `code.length != 0` check
    ///         passes on the wrong address. The ceremony asserts IDENTITY by
    ///         round-tripping this against the position manager's own
    ///         `factory()` — a graph a squatter would have to reproduce whole.
    function v3Factory() external view returns (address);

    /// @notice The position manager holding every launch's LP position — the
    ///         creator never custodies one. Vendored for the same identity
    ///         assertion as `v3Factory`.
    function positionManager() external view returns (address);
}

/// @notice Minimal wrapped-native surface. The repo carries no `IWETH` in
///         `src/` (only a script-local copy), so the two members the adapter
///         needs are declared here alongside the venue that names the token.
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}
