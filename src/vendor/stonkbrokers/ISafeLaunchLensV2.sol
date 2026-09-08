// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Vendored StonkBrokers Smart Launch lens
/// @notice PROVENANCE: transcribed from the verified `SafeLaunchLensV2` source
///         at `0x25b5Df581f4b2Ed450203f375ad8A28b17F115B3` on Robinhood Chain
///         4663 (compiler `v0.8.24`), fetched from
///         `robinhoodchain.blockscout.com`. Selectors and argument order below
///         are byte-identical to that source.
///
///         WHY A LENS EXISTS AT ALL, and why this repo vendors it: the pads'
///         curve is a tax-decaying bonding curve whose price moves per MINUTE.
///         Anything that needs a number off that curve — a slippage floor, a
///         display price — has to ask the venue. The spec is explicit that
///         curve math SHALL NOT be reimplemented here, so this is the one
///         sanctioned source, and its address rides the counterparty allowlist
///         alongside the pads.
///
///         NOT CALLED ON-CHAIN BY THE ADAPTER, and that is deliberate rather
///         than an omission. `StonkLaunchAdapter` never derives a number from
///         the curve: its only trade is the optional dev buy, whose slippage
///         floor `minTokensOut` arrives from the PROPOSAL — quoted off-chain
///         through this lens, reviewed by voters, and then enforced by the pad.
///         An adapter that re-quoted at execute time would be enforcing a floor
///         nobody voted on, and would read a price movable inside the very
///         transaction it is protecting. So the adapter holds the lens address
///         (validated codeful at construction, exposed as `lens()`) for the
///         deploy ceremony and for off-chain quoting, and calls it nowhere.
///
///         REDUCED SURFACE — the three reads a quoting client needs. Every read
///         takes the PAD as its first argument, because the lens is a single
///         deployment serving all sixteen pads. Deliberately NOT vendored:
///           - the batch/enumeration views (paginated launch listings) — a UI
///             concern with no consumer in this repo;
///           - `viewLaunch`-style aggregates — the adapter reads launch state
///             from the pad's own `getLaunch`/`modesOf`, one hop closer to the
///             truth and with no second contract able to disagree about it.
///
///         PRAGMA: upstream compiles under `v0.8.24`; this file declares
///         `0.8.28` to match the repo. Behaviour-preserving — an `interface`
///         emits no bytecode and the ABI encoding of these signatures is
///         identical across both compiler versions.
interface ISafeLaunchLensV2 {
    /// @notice Tokens `quoteIn` would buy on `pad`'s launch `id` right now, and
    ///         the tax basis points applied at this instant.
    /// @dev The source of a proposal's `minTokensOut`. Time-sensitive by
    ///      construction: the tax decays per minute, so a quote taken at
    ///      propose time is a ceiling, not a promise — which is why the floor
    ///      travels in the proposal and the pad, not this lens, enforces it.
    function quoteBuy(address pad, uint256 id, uint256 quoteIn) external view returns (uint256 tokensOut, uint16 taxBps);

    /// @notice Quote a sell for `seller` (the venue caps a sell at what that
    ///         account bought — `SellExceedsCurve`).
    /// @dev Vendored for completeness of the quoting surface a client needs.
    ///      The adapter never sells; see the `sell` omission note in
    ///      `IStonkSafeLaunchpadV2`.
    function quoteSell(address pad, uint256 id, address seller, uint256 tokensIn)
        external
        view
        returns (uint256 quoteOut, uint16 taxBps);

    /// @notice Spot price of launch `id` on `pad`, in wei of the lane's quote.
    function priceWei(address pad, uint256 id) external view returns (uint256);
}
