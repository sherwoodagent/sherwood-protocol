// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  Vendored StonkBrokers Smart Launch pad interface
/// @notice PROVENANCE: transcribed from the verified `StonkSafeLaunchpadV2`
///         source on Robinhood Chain 4663 (compiler `v0.8.24`), fetched from
///         `robinhoodchain.blockscout.com`. Every selector, struct field order
///         and field width below is byte-identical to that source.
///
///         ONE ABI, SIXTEEN DEPLOYMENTS. Unlike Sushi's single launchpad, this
///         venue is a FLEET: eight V2 pads (mint launches, `createLaunch` with
///         `token == address(0)`) and eight V3 pads (bring-your-own token),
///         one per quote lane, every one of them this same ABI. The lane a pad
///         serves is not a parameter — it is `quote()`, fixed at that pad's
///         deployment. Verified live on 4663 (2026-08-28), reading `quote()`
///         on each:
///
///           V2 (mint) — WETH  `0xFCd61B25BbF3AbD6cf0070D6328E351cc30EEC9f`
///                       STONK `0x8f6782c5Aa37804d08a9b7bf3984Ff3245Fd6cD4`
///                       USDG  `0xd4F20033586977A2511f4A2DB4aF7C79a340D70a`
///                       GME   `0x4B9Dcd6CCFAeF0f6D23065Dd78E79d5E20ec8cFD`
///                       NVDA  `0xEe96d955d5634813374ecE4C74F2C0ff71B1F9FB`
///                       AAPL  `0xB0453A81Cbf963903409FFF18AD92941e1c7a864`
///                       SPCX  `0x0c3b4EDED41696eFF0ed70841f132B519d81c947`
///                       USO   `0xDb3C81C841ff88db6cDFbDDB0eE049D162A6053B`
///           V3 (BYO)  — WETH  `0x5BCEefBa6fDf437A7388aDC5c9056c827baca3B3`
///                       STONK `0x406fd0B957bb8cF1dd57C78540D009578e971131`
///                       USDG  `0xF0A06Ac7BBb0cc3049B68c257c3ee27CcEA40eeA`
///                       GME   `0x5b21F8a5Ef81586627B4725844aD447325d0992B`
///                       NVDA  `0xDf03953DCA8dB733345278A0c5fd2E81fa2A9B54`
///                       AAPL  `0xc522DfaE0D1a140257702392B665183a6De7657f`
///                       SPCX  `0xd82da1D8ef59959b170b59147283Ab1F2F1Ca86A`
///                       USO   `0x644b19512052A1b6d38d7B16C6c3Fb1d3F7270D2`
///
///         WOOD IS ABSENT AND STRUCTURALLY SO. There is no WOOD pad and no
///         owner action that adds a lane to an existing pad — a lane is a
///         deployment. That is why `StonkLaunchAdapter.quoteSupported(WOOD)`
///         is `false` forever, where the Sushi adapter's answer can flip on an
///         owner's feed registration.
///
///         REDUCED SURFACE — vendored is only what `StonkLaunchAdapter` calls,
///         plus the two views the deploy ceremony asserts identity with,
///         following the `ISushiLaunchpad` / `IMorpho` precedent of vendoring
///         the consumed surface and saying so. Deliberately NOT vendored:
///           - `sell(...)`          — the adapter NEVER sells. Design Decision 4
///                                    forbids selling the fund token into its own
///                                    launch pool at settle (an in-transaction,
///                                    attacker-movable price — the finding-#3
///                                    shape), and the venue would cap such a sell
///                                    at `boughtOf` (`SellExceedsCurve`) anyway.
///                                    Not vendoring it means no code path here can
///                                    grow one by accident.
///           - `boughtOf(id, who)`  — only meaningful to a seller.
///           - the owner/admin surface (fee bps setters, `bounds()` writers,
///             pausing, venue sweeps) — venue governance, not ours. Its effects
///             are read live through `launchFeeWei()` rather than mirrored.
///           - the events and launch enumeration views.
///
///         PRAGMA: upstream compiles under `v0.8.24`; this file declares
///         `0.8.28` to match the repo. Behaviour-preserving — an `interface`
///         emits no bytecode, and ABI encoding of these signatures is identical
///         across both compiler versions (no user-defined value types, no
///         transient storage, no custom-error layout changes between them).
///
///         VENUE ECONOMICS the adapter depends on (verified live on every pad,
///         2026-08-28, and the reason each member below is here):
///           - `launchFeeWei() == 0`. The adapter still reads it LIVE and
///             REFUSES to launch if it ever turns nonzero — see
///             `StonkLaunchAdapter.NativeFeeUnsupported`.
///           - `creatorFeeBps() == 1650`, `protocolFeeBps() == 1650`,
///             `lpFeeBps() == 5000` — the creator's 16.5% of the per-trade tax
///             accrues as `creatorQuoteOwed[id]` and is paid by the
///             PERMISSIONLESS `flushCreatorQuote` to the CREATOR, never to the
///             caller. That is why the adapter clones: the creator is pinned at
///             `createLaunch` and there is NO transfer.
///           - `bounds()`: `minStartMcapUsd8 = 1e11` ($1k),
///             `maxStartMcapUsd8 = 1e14` ($1M), `minGradMcapUsd8 = 5e12` ($50k),
///             `maxGradMcapUsd8 = 1e15` ($10M), `maxStartTaxBps = 9900`,
///             `minWindowSecs = 600`, `maxWindowSecs = 5940`.
///           - `createLaunch` ECONOMICS VALIDATION, enforced by the venue and
///             therefore NOT duplicated by the adapter (which passes the
///             proposal's economics through and lets the pad be the judge):
///               * `startTaxBps == 0` requires `taxDecayPerMinuteBps == 0` AND
///                 `openEnded == true`;
///               * `startTaxBps != 0` requires `taxDecayPerMinuteBps != 0`,
///                 `startTaxBps % taxDecayPerMinuteBps == 0`, and the derived
///                 `windowSecs = (startTaxBps / taxDecayPerMinuteBps) * 60`
///                 inside `[minWindowSecs, maxWindowSecs]`;
///               * `openEnded` requires `sellsEnabled` and
///                 `postTaxBps ∈ [100, 500]`; `!openEnded` requires
///                 `postTaxBps == 0`;
///               * `unsoldMode <= 1`; `maxBuyPpm <= 42069`.
///           - Reverts the adapter relies on rather than duplicating:
///             `NotEoa` (only when a launch set `eoaOnly` — the adapter NEVER
///             does, and could not function if it did: every later verb is a
///             contract call), `SellExceedsCurve`, `BuyCapExceeded`
///             (`maxBuyPpm`), `WindowClosed`, `NotGraduatable`, `StalePrice`
///             (the stock lanes, on weekend oracle gaps — surfaced UNCHANGED,
///             never bypassed or retried), `BadEconomics`,
///             `FeeOnTransferToken` (`arm` rejects a supply that does not
///             arrive in full), `TokenInUse`, `TokenIsQuoteAsset`.
interface IStonkSafeLaunchpadV2 {
    /// @notice The launch the creator is asking the pad to open.
    /// @param token                 Existing ERC-20 to launch (V3/BYO), or
    ///                              `address(0)` to have the pad MINT one (V2).
    ///                              The adapter always passes `address(0)`: the
    ///                              mint path is what puts the whole supply in
    ///                              the creator's hands, which is what makes the
    ///                              fund's reserve a free allocation rather than
    ///                              a dev buy.
    /// @param supply                Total supply, in wei of the launch token.
    /// @param vanitySalt            CREATE2 salt for a vanity token address.
    ///                              Always `bytes32(0)` here — a vanity address
    ///                              is cosmetic and a caller-chosen salt is one
    ///                              more attacker-influenced input on a path
    ///                              that mints.
    /// @param startMcapUsd8         Starting market cap, 8-decimal USD.
    /// @param gradMcapUsd8          Graduation market cap, 8-decimal USD.
    /// @param startTaxBps           Opening trade tax.
    /// @param taxDecayPerMinuteBps  Linear decay of that tax per minute; with
    ///                              `startTaxBps` it DERIVES the curve window.
    /// @param sellsEnabled          Whether the curve accepts sells.
    /// @param bufferSecs            Post-window buffer the venue applies.
    /// @param unsoldMode            What happens to unsold supply at
    ///                              graduation (`0`/`1`; burn or single-sided).
    /// @param eoaOnly               Restricts every trade to EOAs. The adapter
    ///                              NEVER sets this — see the header.
    /// @param openEnded             No closing deadline; requires
    ///                              `sellsEnabled` and a post-tax in [100, 500].
    /// @param postTaxBps            Tax after the decay schedule ends.
    /// @param bondVenue             Which AMM `bond()` mints the locked LP on.
    /// @param maxBuyPpm             Per-wallet buy cap, parts-per-million of
    ///                              supply; `<= 42069`.
    struct CreateParams {
        address token;
        string name;
        string symbol;
        uint256 supply;
        bytes32 vanitySalt;
        uint64 startMcapUsd8;
        uint64 gradMcapUsd8;
        uint16 startTaxBps;
        uint16 taxDecayPerMinuteBps;
        bool sellsEnabled;
        uint32 bufferSecs;
        uint8 unsoldMode;
        bool eoaOnly;
        bool openEnded;
        uint16 postTaxBps;
        uint8 bondVenue;
        uint32 maxBuyPpm;
    }

    /// @notice Per-launch venue state. The five booleans are the whole
    ///         lifecycle the adapter's `phase` reads: `aborted` and `bonded`
    ///         are terminal, `graduated` means the curve is done but the LP is
    ///         not minted yet, and `armed` distinguishes a created launch from
    ///         a trading one.
    /// @dev `creator` is PINNED here at `createLaunch` and there is no
    ///      transfer — the single fact that forces the per-launch clone.
    struct Launch {
        address token;
        address creator;
        uint64 startMcapUsd8;
        uint64 gradMcapUsd8;
        uint16 startTaxBps;
        uint16 decayPerMinuteBps;
        uint16 creatorFeeBpsSnap;
        uint16 protocolFeeBpsSnap;
        uint32 windowSecs;
        uint64 startTime;
        uint64 deadline;
        bool externalToken;
        bool sellsEnabled;
        bool armed;
        bool graduated;
        bool bonded;
        bool aborted;
        uint256 loadedSupply;
        uint256 vQuote;
        uint256 vToken;
        uint256 realQuote;
        uint256 buyCount;
    }

    /// @notice The launch's mode flags, kept separate from `Launch` upstream.
    /// @dev `openEnded` is the field `phase` needs and `Launch` does not carry:
    ///      an open-ended curve has NO closing deadline, so `deadline` alone
    ///      cannot distinguish "still trading" from "window closed".
    struct LaunchModes {
        uint8 unsoldMode;
        bool eoaOnly;
        bool openEnded;
        uint16 postTaxBps;
        uint8 bondVenue;
        uint32 maxBuyPpm;
    }

    /// @notice Open a launch. Caller becomes the creator — FOREVER.
    /// @dev On the mint path (`p.token == address(0)`) the pad deploys the
    ///      ERC-20 and mints `p.supply` TO THE CALLER; nothing is loaded onto
    ///      the curve until `arm`. That gap is where the adapter withholds the
    ///      fund's reserve.
    function createLaunch(CreateParams calldata p) external payable returns (uint256 id, address token);

    /// @notice Load `supplyWei` of the launch token onto the curve.
    /// @dev Creator-only; pulls `supplyWei` from the creator and reverts
    ///      `FeeOnTransferToken` if less than that arrives.
    function arm(uint256 id, uint256 supplyWei) external;

    /// @notice Cancel a launch and return the loaded supply to the creator.
    /// @dev Creator-only, and ONLY while `buyCount == 0` — the recovery lever
    ///      whose whole value is that nobody else can pull it, which is why the
    ///      clone gates it to its owner.
    function abort(uint256 id) external;

    /// @notice Buy off the curve, delivering to `recipient`.
    /// @dev The adapter's only trade: an optional same-transaction dev buy with
    ///      `recipient = the owning strategy`, so bought tokens are never an
    ///      adapter balance forwarded afterwards.
    function buy(uint256 id, uint256 quoteIn, uint256 minTokensOut, bytes32 ref, address recipient)
        external
        returns (uint256 tokensOut);

    /// @notice Close the curve once the graduation market cap is reached.
    /// @dev PERMISSIONLESS at the venue, which is why the clone's `finalize` is
    ///      permissionless too — gating it would add friction and no safety.
    ///      Reverts `NotGraduatable` when the launch has not qualified.
    function graduate(uint256 id) external;

    /// @notice Mint the locked LP for a graduated launch.
    /// @dev PERMISSIONLESS; requires `graduated`.
    function bond(uint256 id) external;

    /// @notice Pay `creatorQuoteOwed[id]` to the CREATOR.
    /// @dev Permissionless, and it pays the creator — the CLONE — not the
    ///      caller. That is exactly why the clone must forward afterwards: the
    ///      venue's payee is not the strategy.
    function flushCreatorQuote(uint256 id) external;

    /// @notice Creator quote accrued and not yet flushed.
    function creatorQuoteOwed(uint256 id) external view returns (uint256);

    /// @notice Full launch state.
    function getLaunch(uint256 id) external view returns (Launch memory);

    /// @notice Mode flags for a launch.
    function modesOf(uint256 id) external view returns (LaunchModes memory);

    /// @notice Reverse index: which launch on this pad issued `token`.
    /// @dev Vendored for the DEPLOY CEREMONY and for consumers reconciling a
    ///      token back to its pad, not for the adapter — the clone stores its
    ///      own id and never needs to look one up.
    function launchIdOfToken(address token) external view returns (uint256);

    /// @notice The quote asset this pad's lane is fixed to.
    /// @dev The IDENTITY the adapter's constructor asserts each `(quote, pad)`
    ///      pair against. Presence (`code.length != 0`) is not enough on this
    ///      chain, where canonical-looking addresses can hold unrelated
    ///      bytecode; a pad that does not itself claim the lane is refused.
    function quote() external view returns (address);

    /// @notice Native launch fee, in wei. `0` on every pad today.
    /// @dev Read LIVE, never pinned: the venue owner can reprice between
    ///      propose and execute. The adapter refuses to launch if it is ever
    ///      nonzero rather than silently under-funding the call.
    function launchFeeWei() external view returns (uint256);
}
