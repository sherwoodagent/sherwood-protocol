// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IStonkSafeLaunchpadV2} from "../../src/vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockStonkPad
/// @notice Faithful-enough double for one `StonkSafeLaunchpadV2` pad on
///         Robinhood 4663. Each instance IS a lane: `quote()` is fixed at
///         construction, exactly as the sixteen live pads are.
///
///         It reproduces the behaviours `StonkLaunchAdapter` actually depends
///         on and nothing else:
///           - `createLaunch(token == 0)` MINTS the whole supply TO THE CREATOR
///             (the fact that makes the fund's reserve a free allocation rather
///             than a dev buy), and pins `creator = msg.sender` with NO
///             transfer;
///           - `arm` is creator-only and PULLS the loaded supply, so a launch
///             that withheld a reserve arms strictly less than it minted;
///           - `buy` delivers to `recipient` — never to `msg.sender` — bumps
///             `buyCount`, and accrues the creator's 16.5% as
///             `creatorQuoteOwed`;
///           - `flushCreatorQuote` is permissionless and pays THE CREATOR, so a
///             clone must forward afterwards;
///           - `abort` is creator-only and barred once `buyCount != 0`;
///           - `graduate`/`bond` are permissionless, `bond` requires
///             `graduated`, and `graduate` refuses with `NotGraduatable` until
///             the launch qualifies;
///           - the economics validation `createLaunch` performs, so a test
///             proves the adapter builds params the real venue accepts.
///
///         Test knobs (`setGraduatable`, `setStale`, `setRate`,
///         `setLaunchFeeWei`) drive the adapter's edges; the real pad derives
///         all four from its curve and its oracle.
contract MockStonkPad {
    /// @notice Live values on every pad (2026-08-28).
    uint16 public constant CREATOR_FEE_BPS = 1650;
    uint32 public constant MIN_WINDOW_SECS = 600;
    uint32 public constant MAX_WINDOW_SECS = 5940;

    /// @notice This pad's lane. Fixed at deployment, like the real fleet.
    address public immutable quote;

    uint256 public launchFeeWei;
    /// @notice Launch tokens delivered per 1e18 of quote on `buy`.
    uint256 public rate = 1e18;
    /// @notice When false, `graduate` refuses — the un-graduatable curve.
    bool public graduatable;
    /// @notice The stock lanes' weekend oracle gap.
    bool public stale;

    uint256 public nextId = 1;
    mapping(uint256 id => IStonkSafeLaunchpadV2.Launch launch) internal _launches;
    mapping(uint256 id => IStonkSafeLaunchpadV2.LaunchModes modes) internal _modes;
    mapping(uint256 id => uint256 owed) public creatorQuoteOwed;
    mapping(address token => uint256 id) public launchIdOfToken;
    mapping(uint256 id => mapping(address who => uint256 bought)) public boughtOf;

    error BadEconomics();
    error NotCreator();
    error UnknownLaunch();
    error NotArmed();
    error AlreadyArmed();
    error HasBuys();
    error Aborted();
    error NotGraduatable();
    error NotGraduated();
    error AlreadyBonded();
    error StalePrice();
    error InsufficientOutput();
    error WindowClosed();
    error InsufficientLaunchFee();

    constructor(address quote_) {
        quote = quote_;
    }

    // ── venue-owner / oracle knobs (test-side stand-ins) ──

    function setLaunchFeeWei(uint256 fee) external {
        launchFeeWei = fee;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setGraduatable(bool value) external {
        graduatable = value;
    }

    function setStale(bool value) external {
        stale = value;
    }

    // ── venue surface ──

    /// @dev Mirrors the live economics validation, so a test that launches
    ///      through the adapter proves the adapter builds ACCEPTABLE params —
    ///      not merely params this mock happens to tolerate.
    function createLaunch(IStonkSafeLaunchpadV2.CreateParams calldata p)
        external
        payable
        returns (uint256 id, address token)
    {
        if (msg.value < launchFeeWei) revert InsufficientLaunchFee();
        if (p.supply == 0) revert BadEconomics();
        if (p.unsoldMode > 1 || p.maxBuyPpm > 42_069) revert BadEconomics();

        uint32 windowSecs;
        if (p.startTaxBps == 0) {
            if (p.taxDecayPerMinuteBps != 0 || !p.openEnded) revert BadEconomics();
        } else {
            if (p.taxDecayPerMinuteBps == 0 || p.startTaxBps % p.taxDecayPerMinuteBps != 0) revert BadEconomics();
            windowSecs = uint32((uint256(p.startTaxBps) / p.taxDecayPerMinuteBps) * 60);
            if (windowSecs < MIN_WINDOW_SECS || windowSecs > MAX_WINDOW_SECS) revert BadEconomics();
        }
        if (p.openEnded) {
            if (!p.sellsEnabled || p.postTaxBps < 100 || p.postTaxBps > 500) revert BadEconomics();
        } else if (p.postTaxBps != 0) {
            revert BadEconomics();
        }

        id = nextId++;

        // The mint path: the pad deploys the token and mints the WHOLE supply
        // to the creator. `p.token != 0` (the V3/BYO path) is out of scope here
        // — the adapter never takes it.
        ERC20Mock minted = new ERC20Mock(p.name, p.symbol, 18);
        minted.mint(msg.sender, p.supply);
        token = address(minted);
        launchIdOfToken[token] = id;

        _launches[id] = IStonkSafeLaunchpadV2.Launch({
            token: token,
            creator: msg.sender,
            startMcapUsd8: p.startMcapUsd8,
            gradMcapUsd8: p.gradMcapUsd8,
            startTaxBps: p.startTaxBps,
            decayPerMinuteBps: p.taxDecayPerMinuteBps,
            creatorFeeBpsSnap: CREATOR_FEE_BPS,
            protocolFeeBpsSnap: CREATOR_FEE_BPS,
            windowSecs: windowSecs,
            startTime: uint64(block.timestamp),
            deadline: uint64(block.timestamp + windowSecs + p.bufferSecs),
            externalToken: false,
            sellsEnabled: p.sellsEnabled,
            armed: false,
            graduated: false,
            bonded: false,
            aborted: false,
            loadedSupply: 0,
            vQuote: 0,
            vToken: 0,
            realQuote: 0,
            buyCount: 0
        });
        _modes[id] = IStonkSafeLaunchpadV2.LaunchModes({
            unsoldMode: p.unsoldMode,
            eoaOnly: p.eoaOnly,
            openEnded: p.openEnded,
            postTaxBps: p.postTaxBps,
            bondVenue: p.bondVenue,
            maxBuyPpm: p.maxBuyPpm
        });
    }

    /// @dev Creator-only; pulls `supplyWei` and rejects a short arrival the way
    ///      the live pad's `FeeOnTransferToken` guard does.
    function arm(uint256 id, uint256 supplyWei) external {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        if (msg.sender != l.creator) revert NotCreator();
        if (l.armed) revert AlreadyArmed();
        uint256 before = IERC20(l.token).balanceOf(address(this));
        IERC20(l.token).transferFrom(msg.sender, address(this), supplyWei);
        if (IERC20(l.token).balanceOf(address(this)) - before != supplyWei) revert BadEconomics();
        l.armed = true;
        l.loadedSupply = supplyWei;
    }

    /// @dev Creator-only, and ONLY while `buyCount == 0`.
    function abort(uint256 id) external {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        if (msg.sender != l.creator) revert NotCreator();
        if (l.aborted) revert Aborted();
        if (l.buyCount != 0) revert HasBuys();
        l.aborted = true;
        uint256 held = l.loadedSupply;
        l.loadedSupply = 0;
        if (held != 0) IERC20(l.token).transfer(l.creator, held);
    }

    /// @dev Delivers to `recipient`, never to `msg.sender`.
    function buy(uint256 id, uint256 quoteIn, uint256 minTokensOut, bytes32, address recipient)
        external
        returns (uint256 tokensOut)
    {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        if (stale) revert StalePrice();
        if (l.aborted) revert Aborted();
        if (!l.armed) revert NotArmed();
        if (l.graduated) revert WindowClosed();

        IERC20(quote).transferFrom(msg.sender, address(this), quoteIn);
        tokensOut = (quoteIn * rate) / 1e18;
        if (tokensOut < minTokensOut) revert InsufficientOutput();

        l.loadedSupply -= tokensOut;
        l.realQuote += quoteIn;
        l.buyCount += 1;
        boughtOf[id][recipient] += tokensOut;
        creatorQuoteOwed[id] += (quoteIn * CREATOR_FEE_BPS) / 10_000;
        IERC20(l.token).transfer(recipient, tokensOut);
    }

    /// @dev Permissionless; refuses until the launch qualifies.
    function graduate(uint256 id) external {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        if (l.aborted) revert Aborted();
        if (!graduatable || l.graduated) revert NotGraduatable();
        l.graduated = true;
    }

    /// @dev Permissionless; requires `graduated`.
    function bond(uint256 id) external {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        if (!l.graduated) revert NotGraduated();
        if (l.bonded) revert AlreadyBonded();
        l.bonded = true;
    }

    /// @dev Permissionless, and it pays the CREATOR — which on a cloned adapter
    ///      is the clone, never the strategy and never the caller.
    function flushCreatorQuote(uint256 id) external {
        IStonkSafeLaunchpadV2.Launch storage l = _load(id);
        uint256 owed = creatorQuoteOwed[id];
        if (owed == 0) return;
        creatorQuoteOwed[id] = 0;
        IERC20(quote).transfer(l.creator, owed);
    }

    function getLaunch(uint256 id) external view returns (IStonkSafeLaunchpadV2.Launch memory) {
        return _launches[id];
    }

    function modesOf(uint256 id) external view returns (IStonkSafeLaunchpadV2.LaunchModes memory) {
        return _modes[id];
    }

    // ── test helper: award creator fees without simulating trades ──

    function creditCreatorQuote(uint256 id, uint256 amount) external {
        creatorQuoteOwed[id] += amount;
    }

    function _load(uint256 id) private view returns (IStonkSafeLaunchpadV2.Launch storage l) {
        l = _launches[id];
        if (l.token == address(0)) revert UnknownLaunch();
    }
}
