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
 *   adapter can be creator for a few opcodes and hand the role on inside the
 *   same transaction — it ends every call role-free and balance-free, and there
 *   is nothing left for a compromise of it to reach. The sibling StonkBrokers
 *   venue pins the creator at creation and therefore has to clone; the
 *   difference lives entirely in the venue, not the interface.
 *
 *   WHO IT HANDS THE ROLE TO: `p.feeRecipient`, the FUND'S VAULT, never the
 *   calling strategy. The reserve still goes to the strategy — that is the pot
 *   the fund's holders claim against — but the fee stream is pointed at the
 *   vault from the launch transaction, so creator fees never enter strategy
 *   custody and there is no settle-time handoff for anything to get wrong. See
 *   `launch`, and `ILaunchAdapter.LaunchParams.feeRecipient` for the lever that
 *   deletes.
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

    /// @notice The best-effort native sweep at the end of `launch` did not go
    ///         through, so `amount` stays on the adapter. Emitted instead of
    ///         reverting — see `_sweepNative` for why that direction is the
    ///         safe one. Nothing here is the launch's money.
    event NativeSweepSkipped(address indexed to, uint256 amount);

    /// @notice A TOLERATED VENUE CALL DID NOT GO THROUGH. Emitted where a
    ///         failed venue leg is otherwise INVISIBLE — `collectFees` reports
    ///         `(0, 0)`, which is also what an honest "nothing accrued" looks
    ///         like.
    ///
    /// @dev    Observed on Robinhood 4663: driven under `cast send`'s ESTIMATED
    ///         gas limit, `collectFees` returned status 1, moved nothing and
    ///         logged NOTHING AT ALL (224,428 gas); the identical call with
    ///         `--gas-limit 3000000` moved 8.391340 USDG (227,388 gas). EIP-150
    ///         forwards only 63/64 of the available gas, so the child can run
    ///         out while the parent succeeds — and a raw `call` cannot tell
    ///         that from a venue refusing service. Tolerating the failure is
    ///         right: a settlement path must not be hostage to a venue call.
    ///         Making it silent was not, and this is the only fix that does not
    ///         change the return contract.
    ///
    ///         Deliberately the SAME SIGNATURE as `StonkLaunchAdapter`'s event,
    ///         so one keeper subscription covers both venues. `reason` is
    ///         indexed: a starved child reverts with NO returndata
    ///         (`0x00000000`) and is therefore a different topic from any error
    ///         the venue names.
    ///
    /// @param  leg        Which venue call failed.
    /// @param  reason     The revert selector, or `0x00000000` for a revert
    ///                    with no returndata.
    /// @param  launchRef  The launch the call was made for — here, the token.
    /// @param  gasStarved The child consumed essentially all the gas the 63/64
    ///                    rule forwarded it. A heuristic, and the closest an
    ///                    EVM caller can get to observing a child's OOG.
    event VenueCallFailed(bytes32 indexed leg, bytes4 indexed reason, bytes32 launchRef, bool gasStarved);

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
    /// @notice `p.feeRecipient == address(0)`. The creator role is handed to
    ///         that address INSIDE `launch` and this venue's `transferCreator`
    ///         would accept the zero address, permanently orphaning the fee
    ///         stream of a launch that had otherwise succeeded. Checked before
    ///         any transfer, so a malformed proposal costs the vault nothing.
    error ZeroFeeRecipient();
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
    ///        2. `transferCreator(token, p.feeRecipient)` runs in this same
    ///           transaction, so the fee stream and every creator-only lever
    ///           belong to the fund's VAULT before this returns and the adapter
    ///           keeps no path back to the role;
    ///        3. the two token sweeps below leave the adapter holding zero
    ///           launch token and zero quote — asserted — and the native sweep
    ///           offers back any native balance.
    ///
    ///      TWO DESTINATIONS, AND THEY ARE NOT THE SAME ONE. This is the crux
    ///      of the fee routing and the easiest thing here to get backwards:
    ///        - the RESERVE goes to `msg.sender`, THE STRATEGY. The reserve is
    ///          the pot the fund's holders claim pro-rata, so it is the
    ///          strategy's to hold, snapshot and distribute. `recipient` on the
    ///          dev buy therefore stays the caller and is untouched by any of
    ///          this;
    ///        - the FEE STREAM goes to `p.feeRecipient`, THE FUND'S VAULT. Only
    ///          the creator ROLE moves; no reserve token, no quote and no fee
    ///          ever routes anywhere new.
    ///      Naming the vault at the venue in the launch transaction is what
    ///      deletes the settle-time handoff this adapter used to need: the
    ///      strategy was creator, so fees landed in strategy custody and the
    ///      role had to be re-pointed at settlement — a lane that could be got
    ///      wrong, a handoff that could fail, and (while a settled strategy held
    ///      fee tokens) a permissionless `collectResidue` that could re-stamp a
    ///      fresh deposit lock on the whole vault. Fees now never enter strategy
    ///      custody at all, so that lever has no state to exist in rather than
    ///      being guarded against. See `ILaunchAdapter.LaunchParams.feeRecipient`.
    ///
    ///      Sweeps go to `msg.sender` rather than being left in place because
    ///      residue on a SHARED contract belongs to whoever calls next: the
    ///      quote and the fee were pulled from this caller, so dust from a
    ///      rounding difference, a repriced fee, or value the caller attached
    ///      is theirs. Expect all three to be no-ops — the venue rejects a
    ///      partially-consumed buy (`PartialInitialBuy`), so `quoteSpent`
    ///      always equals `p.quoteIn`, and the fee is pulled exactly.
    ///
    ///      The two TOKEN sweeps assert their postcondition; the NATIVE sweep is
    ///      best-effort and never reverts the launch. That asymmetry is
    ///      deliberate and load-bearing: token residue can only come from a
    ///      lossy quote this launch itself moved, whereas native can be
    ///      force-sent to this address by anyone for one wei, and a shared
    ///      certified singleton that stops serving every fund because someone
    ///      gave it a wei has the wrong invariant. See `_sweepNative`.
    ///
    ///      `payable` is honoured but unnecessary: the fee is sourced by
    ///      unwrapping WETH pulled from the caller precisely so a governor batch
    ///      never has to carry value. Value sent anyway is offered straight
    ///      back, and stays here if the caller cannot receive it.
    function launch(LaunchParams calldata p) external payable override returns (LaunchResult memory) {
        // Ordered so every rejection happens before any transfer.
        if (p.feeRecipient == address(0)) revert ZeroFeeRecipient();
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
        // adapter as creator. Straight to the VAULT — not to the strategy and
        // not via it — so the fee stream is pointed at its final destination
        // from the first block and never needs re-pointing.
        launchpad.transferCreator(token, p.feeRecipient);

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
    ///      THE DESTINATION IS FIXED AT LAUNCH and cannot be re-pointed by
    ///      anything this adapter does. `launch` hands the creator role to
    ///      `p.feeRecipient` — the fund's VAULT — in the launch transaction, so
    ///      the creator this reads has been the vault since the first block:
    ///      one destination for the life of the launch, no settled-vs-live
    ///      branch, and no handoff whose failure could leave the deltas pointing
    ///      at the wrong address. The `launchInfo` read is kept anyway rather
    ///      than caching the recipient, because the venue — not this stateless
    ///      adapter — is the authority on who it just paid.
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
        uint256 gasBefore = gasleft();
        // solhint-disable-next-line avoid-low-level-calls
        (bool distributed,) = address(launchpad).call(abi.encodeCall(ISushiLaunchpad.distributeFees, (token)));
        // A failed call reverted its own state, so nothing moved: `(0, 0)` is
        // the honest report. It is no longer a SILENT one — see
        // `VenueCallFailed` for the 4663 trace that made "the venue refused"
        // and "there was nothing to collect" the same observation.
        if (!distributed) {
            emit VenueCallFailed("distributeFees", _revertSelector(), launchRef, gasleft() <= gasBefore / 63);
            return (0, 0);
        }

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
    /// @dev NAMES THE VENUE, AND NOTHING ELSE NOW. The deploy ceremony asserts
    ///      counterparty standing against this address; the interface also
    ///      offers it as the place a strategy would address a settle-time
    ///      creator handoff, and this adapter no longer has one to address.
    ///      `launch` makes `p.feeRecipient` the creator in the launch
    ///      transaction, so there is no later role to move: a settlement that
    ///      called `transferCreator` here would find neither the strategy nor
    ///      this adapter is the creator and be refused, which is why the
    ///      strategy must not make that call rather than merely tolerating it.
    ///      The adapter deliberately exposes no re-take path either.
    function launchTarget() external view override returns (address) {
        return address(launchpad);
    }

    /// @notice Accept native ONLY from `weth`.
    /// @dev The single legitimate inbound payment is the unwrap inside
    ///      `launch`. A shared, stateless contract that accepted native from
    ///      anyone would accumulate a balance belonging to no one, so anything
    ///      else is refused here.
    ///
    ///      This guard is not airtight and is not relied on to be: a
    ///      `selfdestruct` force-send reaches any address and cannot be refused
    ///      by this or any other contract. That case is handled downstream
    ///      instead of here — `_sweepNative` is best-effort, so a force-sent
    ///      balance CANNOT brick `launch`; it is offered to whoever launches
    ///      next, and if that caller cannot receive native it simply sits here
    ///      until one can. No accounting anywhere reads this balance, which is
    ///      why the sweep is bounded to whatever is present and asserts nothing
    ///      about provenance.
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

    /// @dev The revert selector of the call that JUST returned, read straight
    ///      out of the returndata buffer.
    ///
    ///      NEVER COPIES THE WHOLE RETURNDATA. `(bool ok,) = target.call(...)`
    ///      deliberately omits the bytes variable so Solidity skips
    ///      `RETURNDATACOPY` entirely; binding one here to read four bytes
    ///      would hand a hostile or merely verbose venue a returndata bomb on a
    ///      path whose entire contract is that it must not revert. Four bytes,
    ///      into scratch, or `0x00000000` when the callee returned less —
    ///      which is exactly what a child that ran out of gas returns.
    function _revertSelector() private pure returns (bytes4 sel) {
        assembly ("memory-safe") {
            if gt(returndatasize(), 3) {
                returndatacopy(0, 0, 4)
                sel := and(mload(0), 0xffffffff00000000000000000000000000000000000000000000000000000000)
            }
        }
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
    ///
    ///      Unlike native, this assert is NOT a griefing surface. Anyone may
    ///      dust this address with an ERC20, but a well-behaved `transfer` of
    ///      the whole balance clears it, so the dust is forwarded and the assert
    ///      passes. The only residue it can catch is a transfer that moves less
    ///      than it was asked to — fee-on-transfer, or a share-rounding rebase —
    ///      which is a property of the quote the fund itself chose, is scoped to
    ///      launches using THAT quote, and already breaks the venue's
    ///      exact-amount pull a few lines earlier. The launch token cannot be
    ///      pre-dusted at all: it does not exist until this transaction.
    function _sweepToken(address token, address to) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal != 0) IERC20(token).safeTransfer(to, bal);
        uint256 remaining = IERC20(token).balanceOf(address(this));
        if (remaining != 0) revert DustRemains(token, remaining);
    }

    /// @dev Native, and BEST-EFFORT on purpose: it attempts the send and, if the
    ///      send fails, leaves the balance where it is rather than reverting the
    ///      launch.
    ///
    ///      Why that is the right direction, and not a concession. By the time
    ///      this runs, native sitting here is provably not the launch's money:
    ///      the fee was pulled from the caller in WETH, unwrapped exactly, and
    ///      forwarded to the venue in full, and the strategy attaches no value of
    ///      its own. Any balance is therefore either value a caller attached
    ///      voluntarily or native force-sent by `selfdestruct`, which no contract
    ///      can refuse.
    ///
    ///      Reverting on a failed send would hand that force-send the power to
    ///      disable `launch` FOR EVERY FUND, permanently, for one wei: the caller
    ///      is a `BaseStrategy` clone, no strategy declares `receive` or
    ///      `fallback`, so the send to it can never succeed, and this is the only
    ///      path that moves native off this contract — recovery would mean a new
    ///      implementation plus re-certification. The invariant a SHARED,
    ///      CERTIFIED singleton has to hold is that it keeps working, and that
    ///      strictly dominates "it always returns dust". Leaving the balance
    ///      takes nothing from anyone with a claim on it, and the next caller
    ///      whose send DOES succeed sweeps it.
    ///
    ///      Expect this to move nothing in the ordinary case: the unwrap is exact
    ///      and the venue takes the whole fee.
    function _sweepNative(address to) private {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = to.call{value: bal}("");
        // Deliberately not a revert. The event is the whole handling.
        if (!ok) emit NativeSweepSkipped(to, bal);
    }
}
