// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchAdapter} from "../interfaces/ILaunchAdapter.sol";
import {ISushiLaunchpad, IWETH} from "../vendor/sushi/ISushiLaunchpad.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title SushiLaunchAdapter
 * @notice `ILaunchAdapter` over Sushi Launchpad V1 — a STATELESS SINGLETON.
 *
 *   WHY A SINGLETON IS ADMISSIBLE HERE. The interface's custody invariant bans
 *   an adapter that accumulates balances or creator roles; it does not ban a
 *   shared adapter. This venue makes the creator role TRANSFERABLE, so the
 *   adapter can be creator for a few opcodes and hand the role to the calling
 *   strategy inside the same transaction — it ends every call role-free and
 *   balance-free, and there is nothing left for a compromise of it to reach.
 *   The sibling StonkBrokers venue pins the creator at creation and therefore
 *   has to clone; the difference lives entirely in the venue, not the interface.
 *
 *   ZERO STORAGE, deliberately. Not a gas micro-optimisation: `launchRef` IS the
 *   token address and `launchInfo(token)` already distinguishes an issued launch
 *   from an unknown one, so per-launch bookkeeping here could only ever
 *   DISAGREE with the venue. Every verb re-derives from venue state.
 *
 *   REENTRANCY. No guard, and none is needed: the adapter holds no balance and
 *   no role across calls, its only state is immutable, and every state-changing
 *   venue entry point is `nonReentrant` upstream. A re-entrant callback would
 *   find an empty contract.
 *
 *   The caller approves this adapter for `p.quoteIn` of the quote, plus
 *   `nativeFeeSource().amount` of WETH, before calling `launch`.
 */
contract SushiLaunchAdapter is ILaunchAdapter {
    using SafeERC20 for IERC20;

    /// @notice The Sushi Launchpad V1 singleton this adapter fronts.
    ISushiLaunchpad public immutable launchpad;

    /// @notice The venue's wrapped native token — read from the venue at
    ///         construction rather than passed in, so the fee source cannot be
    ///         mis-wired relative to the launchpad it funds.
    address public immutable weth;

    /// @notice The constructor's launchpad is not a contract, or exposes no
    ///         readable `WETH()`. Fail at deploy rather than at the first
    ///         launch, where a mis-wired singleton would already hold funds.
    error InvalidLaunchpad();
    /// @notice `launchpad.WETH()` answered zero or a codeless address, so the
    ///         fee-unwrap lane would be unusable.
    error InvalidWeth();
    /// @notice The venue has no registered price feed for this quote, so
    ///         `launchAndBuy` would revert `UnsupportedQuoteToken`. Checked
    ///         first, BEFORE any transfer, so a WOOD-quoted proposal submitted
    ///         ahead of the venue owner's feed registration fails without ever
    ///         moving the vault's capital.
    error UnsupportedQuote(address quoteToken);
    /// @notice `p.quoteIn == 0`. The venue mints the creator nothing, so the
    ///         dev buy IS the reserve — a zero buy is a launch the fund holds
    ///         no part of (and the venue would reject it as
    ///         `ZeroInitialBuyAmount` anyway).
    error ZeroQuoteIn();
    /// @notice `p.minTokensOut < p.reserveAmount`. The slippage floor is the
    ///         only thing that makes the reserve ENFORCEABLE at the venue;
    ///         accepting a lower floor would let a sandwiched buy return fewer
    ///         tokens than the fund promised its holders and still succeed.
    ///         Adversary: a proposer who sets a nominal reserve and a floor of
    ///         zero, then front-runs the launch.
    error ReserveFloorBelowReserve(uint256 minTokensOut, uint256 reserveAmount);
    /// @notice The initial buy delivered less than `p.reserveAmount`. Redundant
    ///         with the venue's own `InsufficientInitialBuyOutput` given the
    ///         floor check above — kept as belt-and-braces so the custody
    ///         invariant is asserted by THIS contract and not merely inherited
    ///         from a venue upgrade's continued good behaviour.
    error ReserveNotDelivered(uint256 delivered, uint256 required);
    /// @notice A postcondition sweep left a nonzero balance on the adapter, so
    ///         the "retains no token balance" half of the custody invariant
    ///         could not be established. Unreachable with a well-behaved quote;
    ///         it fires on a fee-on-transfer or rebasing quote rather than
    ///         letting residue accumulate on a shared contract.
    error DustRemains(address token, uint256 amount);
    /// @notice The native dust sweep back to the caller failed.
    error NativeSweepFailed();
    /// @notice Native value arrived from something other than `weth`. The only
    ///         legitimate inbound native payment is the WETH unwrap that funds
    ///         the launch fee; anything else is either a mistake or an attempt
    ///         to pre-fund a shared contract, and both are refused.
    error UnexpectedNativePayment(address sender);

    /// @param launchpad_ Sushi Launchpad V1 (`0x104f…a7ed` on Robinhood 4663).
    constructor(address launchpad_) {
        if (launchpad_ == address(0) || launchpad_.code.length == 0) revert InvalidLaunchpad();
        launchpad = ISushiLaunchpad(launchpad_);
        address weth_ = ISushiLaunchpad(launchpad_).WETH();
        if (weth_ == address(0) || weth_.code.length == 0) revert InvalidWeth();
        weth = weth_;
    }

    /// @inheritdoc ILaunchAdapter
    ///
    /// @dev HOW THE CUSTODY INVARIANT IS MET, in order:
    ///        1. the initial buy's `recipient` is `msg.sender`, so the reserve
    ///           is minted-to-market and delivered to the strategy DIRECTLY —
    ///           it is never an adapter balance forwarded afterwards, so there
    ///           is no window in which a shared contract holds a fund's tokens;
    ///        2. `transferCreator(token, msg.sender)` runs in this same
    ///           transaction, so the fee stream and every creator-only lever
    ///           belong to the strategy before this returns and the adapter
    ///           keeps no path back to the role;
    ///        3. the three postcondition sweeps below leave the adapter holding
    ///           zero launch token, zero quote and zero native.
    ///
    ///      Sweeps go to `msg.sender` rather than being left in place because
    ///      residue on a SHARED contract belongs to whoever calls next: the
    ///      quote and the fee were pulled from this caller, so dust from a
    ///      rounding difference, a repriced fee, or value the caller attached
    ///      is theirs. Expect all three to be no-ops — the venue rejects a
    ///      partially-consumed buy (`PartialInitialBuy`), so `quoteSpent`
    ///      always equals `p.quoteIn`, and the fee is pulled exactly.
    ///
    ///      `payable` is honoured but unnecessary: the fee is sourced by
    ///      unwrapping WETH pulled from the caller precisely so a governor batch
    ///      never has to carry value. Value sent anyway is swept straight back.
    function launch(LaunchParams calldata p) external payable override returns (LaunchResult memory) {
        // Ordered so every rejection happens before any transfer.
        if (!quoteSupported(p.quoteToken)) revert UnsupportedQuote(p.quoteToken);
        if (p.quoteIn == 0) revert ZeroQuoteIn();
        if (p.minTokensOut < p.reserveAmount) revert ReserveFloorBelowReserve(p.minTokensOut, p.reserveAmount);

        IERC20(p.quoteToken).safeTransferFrom(msg.sender, address(this), p.quoteIn);

        // Read the fee LIVE and pull exactly it: the venue owner can reprice
        // between propose and execute, and a pinned figure would either
        // under-fund the launch or over-pull from the vault.
        uint256 fee = launchpad.launchFee();
        if (fee != 0) {
            IERC20(weth).safeTransferFrom(msg.sender, address(this), fee);
            IWETH(weth).withdraw(fee);
        }

        IERC20(p.quoteToken).forceApprove(address(launchpad), p.quoteIn);
        (address token,,, uint256 amountOut) = launchpad.launchAndBuy{value: fee}(
            ISushiLaunchpad.TokenConfig({name: p.name, symbol: p.symbol}),
            p.quoteToken,
            p.deadline,
            ISushiLaunchpad.InitialBuy({amountIn: p.quoteIn, amountOutMinimum: p.minTokensOut, recipient: msg.sender})
        );
        // Leave no standing allowance on the venue.
        IERC20(p.quoteToken).forceApprove(address(launchpad), 0);

        if (amountOut < p.reserveAmount) revert ReserveNotDelivered(amountOut, p.reserveAmount);

        // Same transaction, before any external call that could observe the
        // adapter as creator.
        launchpad.transferCreator(token, msg.sender);

        _sweepToken(token, msg.sender);
        if (p.quoteToken != token) _sweepToken(p.quoteToken, msg.sender);
        _sweepNative(msg.sender);

        return LaunchResult({
            token: token,
            // The ref IS the token: this venue keys every verb by token address,
            // so the adapter needs no map and `phase` can answer for a ref it
            // has no record of.
            launchRef: bytes32(uint256(uint160(token))),
            reserveHeld: amountOut,
            // The venue consumes the buy in full or reverts `PartialInitialBuy`.
            quoteSpent: p.quoteIn
        });
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Two phases only. This venue mints the token, seeds the V3 position
    ///      and trades inside `launch`, so an issued launch is `Live` from the
    ///      first block and there is no curve, closing or failed state to
    ///      report — `Curve`/`Closing`/`Failed` exist in the enum for the
    ///      StonkBrokers venue.
    ///
    ///      MUST NOT REVERT, and the venue's `launchInfo` DOES revert
    ///      (`UnknownToken`) for a token it never issued — a typed call would
    ///      therefore break exactly the contract settlement depends on. Hence
    ///      the length-checked raw staticcall, the `PortfolioStrategy.
    ///      _readAddress` / `_isAdapterAllowed` pattern: unknown, unreadable,
    ///      short-returning, dirty-high-bits or `creator == 0` all resolve to
    ///      `None`.
    function phase(bytes32 launchRef) external view override returns (LaunchPhase) {
        address token = _refToToken(launchRef);
        if (token == address(0)) return LaunchPhase.None;
        (bool known, address creator,) = _readLaunch(token);
        if (!known || creator == address(0)) return LaunchPhase.None;
        return LaunchPhase.Live;
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev No-op, and deliberately not a revert: this venue completes the
    ///      launch in one transaction, so there is no lifecycle left to drive.
    ///      A settlement path that calls `finalize` unconditionally — because
    ///      the StonkBrokers venue needs it — must not be forced to branch on
    ///      which venue it is talking to.
    function finalize(bytes32) external override {}

    /// @inheritdoc ILaunchAdapter
    /// @dev The venue's `distributeFees` is PERMISSIONLESS and pays the CURRENT
    ///      CREATOR whoever calls, so this reports deltas measured on that
    ///      creator — read from `launchInfo` — and never on `msg.sender`.
    ///      Measuring the caller would report zero for a permissionless keeper
    ///      driving fees to the fund, and, worse, would read as "nothing
    ///      accrued" to a settlement path deciding whether it can finish.
    ///
    ///      This is also what makes the settle-time handoff work unchanged:
    ///      once the strategy transfers the creator role onward to the vault,
    ///      the deltas reported here are the VAULT's, because that is who the
    ///      venue paid.
    ///
    ///      Returns `(0, 0)` rather than reverting on an unknown launch or a
    ///      venue call that fails (nothing accrued, a paused venue): the
    ///      interface lets settlement call this unconditionally, and a revert
    ///      here would strand a settlement, not merely a fee. A failed venue
    ///      call reverts its own state, so the deltas below are then genuinely
    ///      zero — this reports what moved, it does not assume it.
    function collectFees(bytes32 launchRef) external override returns (uint256 quoteOut, uint256 tokenOut) {
        address token = _refToToken(launchRef);
        if (token == address(0)) return (0, 0);
        (bool known, address creator, address quoteToken) = _readLaunch(token);
        if (!known || creator == address(0)) return (0, 0);

        uint256 quoteBefore = _balanceOf(quoteToken, creator);
        uint256 tokenBefore = _balanceOf(token, creator);

        // Raw call: a venue revert must not propagate (see above). Not
        // `try/catch` — the venue's return tuple is unused, only the deltas are
        // trusted, so there is nothing to decode on the success path either.
        (bool distributed,) = address(launchpad).call(abi.encodeCall(ISushiLaunchpad.distributeFees, (token)));
        // A failed call reverted its own state, so nothing moved: `(0, 0)` is
        // the honest report, not a swallowed error.
        if (!distributed) return (0, 0);

        uint256 quoteAfter = _balanceOf(quoteToken, creator);
        uint256 tokenAfter = _balanceOf(token, creator);
        quoteOut = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        tokenOut = tokenAfter > tokenBefore ? tokenAfter - tokenBefore : 0;
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Mirrors the venue's own gate exactly — `quoteTokenPriceFeed(q) != 0`
    ///      — rather than an allowlist of our own, so the asymmetry stays where
    ///      the interface says it lives. Consequence worth stating: WOOD answers
    ///      FALSE today and TRUE the moment the venue owner registers a WOOD/USD
    ///      aggregator, with no change, redeploy or re-certification here.
    ///
    ///      MUST NOT REVERT, so this is a length-checked raw staticcall even
    ///      though the venue's mapping getter would not revert on its own: the
    ///      launchpad address is immutable but its code is not this repo's, and
    ///      an unreadable answer resolves to `false` (fail closed — a launch
    ///      that would have worked is merely refused, whereas a `true` we could
    ///      not read would send funds at a venue that will reject them).
    function quoteSupported(address quoteToken) public view override returns (bool) {
        if (quoteToken == address(0)) return false;
        address target = address(launchpad);
        if (target.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeCall(ISushiLaunchpad.quoteTokenPriceFeed, (quoteToken)));
        if (!ok || ret.length < 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return false;
        return word != 0;
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev WETH, always — the interface's whole point. The venue charges its
    ///      fee in NATIVE ETH, and the obvious funding source (unwrap some of
    ///      the launch quote) silently assumes the quote IS the wrapped native.
    ///      It is not: the pair is the agent's choice, so a launch quoted in a
    ///      stable, a stock token or WOOD would revert at execute under that
    ///      assumption — on exactly the pairings the template exists to enable.
    ///      Naming WETH here lets the strategy acquire it through its own
    ///      allowlisted swap adapter.
    ///
    ///      Read live: the owner can reprice between propose and execute. An
    ///      unreadable fee answers `(weth, 0)` rather than reverting — this is
    ///      a planning read, and `launch` re-reads the fee typed, so a venue
    ///      that cannot be read fails there, where it strands one call, rather
    ///      than here, where it would strand the proposal's construction.
    function nativeFeeSource() external view override returns (address token, uint256 amount) {
        return (weth, _safeLaunchFee());
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Also the settle-time handoff mechanism: the venue pins
    ///      `transferCreator` to the CURRENT creator — the strategy, after
    ///      `launch` — so the adapter supplies the address and the keying
    ///      (`launchRef` is the token) and the strategy makes the call itself.
    ///      The adapter deliberately exposes no re-take path.
    function launchTarget() external view override returns (address) {
        return address(launchpad);
    }

    /// @notice Accept native ONLY from `weth`.
    /// @dev The single legitimate inbound payment is the unwrap inside
    ///      `launch`. A shared, stateless contract that accepted native from
    ///      anyone would accumulate a balance belonging to no one, which the
    ///      next caller's sweep would collect — so anything else is refused.
    ///      (Force-sends via `selfdestruct` cannot be refused by any contract;
    ///      such a balance is swept to the next launcher, which is why the
    ///      sweep is bounded to the current balance and asserts nothing about
    ///      provenance.)
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedNativePayment(msg.sender);
    }

    // ── internals ──

    /// @dev `launchRef` is the token address widened to 32 bytes. A ref with
    ///      dirty high bits was never issued by this adapter, so it resolves to
    ///      the zero address and every verb treats it as unknown.
    function _refToToken(bytes32 launchRef) private pure returns (address) {
        uint256 word = uint256(launchRef);
        if (word >> 160 != 0) return address(0);
        // Casting to `uint160` is safe: the guard above rejects any word with
        // set bits above 160, so nothing can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @dev Length-checked raw read of `launchInfo(token)`, returning only the
    ///      two fields any verb here needs. `LaunchInfo` is a fully static
    ///      struct, so the return payload is exactly six in-place words —
    ///      `creator` at word 0, `quoteToken` at word 1. Anything shorter, a
    ///      revert (`UnknownToken`), a codeless target or dirty high bits all
    ///      answer `known = false`.
    function _readLaunch(address token) private view returns (bool known, address creator, address quoteToken) {
        address target = address(launchpad);
        if (target.code.length == 0) return (false, address(0), address(0));
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(ISushiLaunchpad.launchInfo, (token)));
        if (!ok || ret.length < 192) return (false, address(0), address(0));
        uint256 creatorWord;
        uint256 quoteWord;
        assembly ("memory-safe") {
            creatorWord := mload(add(ret, 0x20))
            quoteWord := mload(add(ret, 0x40))
        }
        if (creatorWord >> 160 != 0 || quoteWord >> 160 != 0) return (false, address(0), address(0));
        // Both casts are safe: the guard above rejects either word carrying set
        // bits above 160, so neither can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, address(uint160(creatorWord)), address(uint160(quoteWord)));
    }

    /// @dev Safe-read of the fee for `nativeFeeSource`; unreadable → 0.
    function _safeLaunchFee() private view returns (uint256) {
        address target = address(launchpad);
        if (target.code.length == 0) return 0;
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(ISushiLaunchpad.launchFee, ()));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Non-reverting balance read, so `collectFees` cannot be turned into
    ///      a revert by a launch whose quote token has since become unreadable.
    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0) || token.code.length == 0) return 0;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Send any residual balance of `token` to `to`, then assert none is
    ///      left. The assert is the invariant; the transfer is how it is met.
    function _sweepToken(address token, address to) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) IERC20(token).safeTransfer(to, bal);
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert DustRemains(token, remaining);
    }

    /// @dev Same for native: the unwrap is exact and the venue takes the whole
    ///      fee, so this normally moves nothing — it exists so that a repriced
    ///      fee, a refund, or value the caller attached to `launch` leaves with
    ///      the caller instead of sitting on a shared contract.
    function _sweepNative(address to) private {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = to.call{value: bal}("");
        if (!ok) revert NativeSweepFailed();
    }
}
