// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchAdapter} from "../interfaces/ILaunchAdapter.sol";
import {IPonsLaunchFactory, IPonsLaunchLocker, IWrappedNative} from "../vendor/pons/IPonsLaunch.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PonsLaunchAdapter
 * @notice `ILaunchAdapter` over the Pons launch venue (factory + locker) on
 *         Robinhood Chain 4663 — a STATELESS SINGLETON.
 *
 *   INERT ON MAINNET TODAY, and stated first because it is the most important
 *   operational fact about this contract. The factory's `launchToken` opens
 *   with `if (!launchEnabled && !whitelistedLaunchers[msg.sender]) revert
 *   NotWhitelisted();` and `launchEnabled()` is FALSE. Until Pons either flips
 *   that flag or whitelists THIS ADAPTER'S ADDRESS, every `launch` reverts at
 *   the venue — after the adapter has validated everything it can, and before
 *   the venue does anything. Nothing here can work around that, and nothing
 *   here should try: the gate is the venue's, and the deploy ceremony prints
 *   the adapter address to hand to Pons.
 *
 *   WHY A SINGLETON IS NOT MERELY ADMISSIBLE BUT FORCED. The whitelist is keyed
 *   BY ADDRESS. A per-launch clone would need a fresh whitelist entry from the
 *   venue owner for every fund — a manual, permissioned step in the middle of a
 *   governance execution, which is not a design so much as an outage. One
 *   certified singleton is whitelisted once and serves every fund. The custody
 *   argument for it is below.
 *
 *   THE CRUX: `feeWallet` DOES DOUBLE DUTY, AND WE NEED TWO DESTINATIONS.
 *   Inside `launchToken` the single `params.feeWallet` field decides BOTH:
 *     - `initialBuyRecipient = feeWallet == 0 ? msg.sender : feeWallet` — who
 *       receives the dev buy, and on this venue the dev buy IS the fund's
 *       reserve, because the whole supply goes into a one-sided V3 position
 *       that is handed to the locker and locked (the creator gets ZERO tokens,
 *       exactly as on Sushi);
 *     - `locker.setFeeRedirect(token, feeWallet)` — where LP fees are paid.
 *   Our template needs those to be DIFFERENT addresses: the RESERVE belongs to
 *   the calling STRATEGY (it is the pot holders claim pro-rata), the FEE STREAM
 *   belongs to the fund's VAULT (`p.feeRecipient`, named at launch so fees
 *   never enter strategy custody — see `ILaunchAdapter.LaunchParams`).
 *
 *   `launch` resolves that in ONE transaction, in this order and for these
 *   reasons:
 *     1. `launchToken` with `params.feeWallet = msg.sender`, THE STRATEGY, so
 *        the dev buy is delivered straight to the strategy and is never an
 *        adapter balance forwarded on afterwards. This half exists because the
 *        buy recipient cannot be named any other way.
 *     2. immediately after, `locker.setFeeRedirect(token, p.feeRecipient)`, so
 *        the fee stream is the VAULT's before this call returns. This half
 *        exists because step 1 left the redirect pointing at the strategy, and
 *        a fee stream in strategy custody is the exact lever
 *        `LaunchParams.feeRecipient` was introduced to delete. It is permitted
 *        because the locker authorises `launched.deployer`, and the deployer is
 *        this adapter.
 *   Get that order backwards — redirect first, launch second — and there is
 *   nothing to redirect yet; drop step 2 and the vault never sees a fee; drop
 *   step 1's `msg.sender` and the reserve lands on the vault, where holders
 *   cannot claim it.
 *
 *   THE RESIDUAL POWER, AND WHY THE CUSTODY INVARIANT STILL HOLDS. This adapter
 *   is `launched.deployer` for every launch it ever issues, FOREVER. The locker
 *   never lets that role be transferred or renounced. So the adapter
 *   permanently *could* re-point any of those fee streams — the venue would
 *   allow it. The invariant is satisfied not by giving the role away (Sushi's
 *   route, unavailable here) but by the adapter EXPOSING NO PATH TO USE IT:
 *   `setFeeRedirect` is called exactly once, from inside `launch`, with an
 *   argument the caller itself supplied, and there is no other caller-reachable
 *   route to the locker anywhere in this contract. `collectFees` calls
 *   `collectFees` and nothing else; there is no admin function, no owner, no
 *   arbitrary-call sink, no upgrade path, no `delegatecall`. A compromise of
 *   this contract is a compromise of its CODE, and its code is pinned by the
 *   `TierRegistry` codehash gate — which is the same assumption every other
 *   certified adapter in this repo already rests on. The narrower claim, and
 *   the one a test asserts: no external function of this adapter re-points a
 *   fee redirect after `launch` returns.
 *
 *   ZERO STORAGE, deliberately, for the same reason as the Sushi adapter:
 *   `launchRef` IS the token address and `getLaunchedToken(token).exists`
 *   already distinguishes an issued launch from an unknown one, so per-launch
 *   bookkeeping here could only ever DISAGREE with the venue. Every verb
 *   re-derives from venue state.
 *
 *   REENTRANCY. No guard, and none is needed: the adapter holds no balance and
 *   no token role across calls, its only state is immutable, and both venue
 *   contracts are `ReentrancyGuard`ed upstream. A re-entrant callback would
 *   find an empty contract.
 *
 *   HOW THIS DIFFERS FROM `SushiLaunchAdapter`, in the three places it matters:
 *     - BOTH the fee and the buy are funded in NATIVE here
 *       (`initialBuyAmount = msg.value - launchFee`), so the adapter pulls
 *       `p.quoteIn + launchFee()` of WETH and unwraps the lot. On Sushi only
 *       the fee was native and the quote was passed as an ERC-20 allowance.
 *       That is why this adapter requires the quote to BE the wrapped native.
 *     - THE VENUE ENFORCES NO SLIPPAGE FLOOR. The factory hardcodes
 *       `amountOutMinimum: 0` on the dev buy. The adapter's own post-launch
 *       balance check is therefore the ONLY enforcement of `p.minTokensOut`,
 *       not a belt-and-braces second opinion.
 *     - THE QUOTE GATE IS CONFIG-DRIVEN, not a feed registry: a pairing is
 *       supported only while some ENABLED `LaunchConfig` names it.
 *
 *   The caller approves this adapter for `p.quoteIn + nativeFeeSource().amount`
 *   of WETH before calling `launch`. Both legs are the same token here, so that
 *   is one allowance, not two.
 */
contract PonsLaunchAdapter is ILaunchAdapter {
    using SafeERC20 for IERC20;

    /// @notice Venue economics the proposal must state, carried in
    ///         `ILaunchAdapter.LaunchParams.venueData`.
    ///
    /// @dev PROPOSER-VISIBLE RATHER THAN PINNED, and the choice is deliberate.
    ///      There is exactly one launch config and one dex config on 4663
    ///      today, so pinning `(0, 0)` would work — right up until Pons adds a
    ///      second pairing, at which point a pinned adapter would have to be
    ///      redeployed and RE-CERTIFIED to reach it, and the new pairing would
    ///      read to an agent as "the venue does not support this" rather than
    ///      "our adapter was frozen at one config". Naming the ids in the
    ///      proposal puts the choice where the vote can see it and lets the
    ///      venue grow without touching certified code. Every field is
    ///      validated in `launch` before any capital moves — see
    ///      `_validateVenue`.
    ///
    /// @param launchConfigId The pairing/economics preset. Must be in range,
    ///                       `enabled`, and its `pairToken` must equal
    ///                       `p.quoteToken`.
    /// @param dexId          The V3 deployment to pool into. Must be in range,
    ///                       `enabled`, and carry a nonzero `swapRouter` (the
    ///                       venue reverts `RouterNotSet` otherwise, and it
    ///                       does so only AFTER minting the token).
    /// @param salt           Proposer-chosen CREATE2 entropy.
    ///
    ///                       WHY THIS IS NOT OPTIONAL. The venue mints via
    ///                       CREATE2 over an init code hash covering the
    ///                       metadata, the config, and the DEPLOYER — which for
    ///                       a shared singleton is one constant address. Two
    ///                       funds launching the same name/symbol under the
    ///                       same salt would therefore predict the SAME token
    ///                       address, and the second would revert
    ///                       `PoolAlreadyExists`. The adapter additionally
    ///                       namespaces this by `msg.sender` (see `launch`), so
    ///                       one fund can never collide with another's
    ///                       whatever its proposer picks; this field only has
    ///                       to distinguish a fund's own retries.
    struct VenueData {
        uint256 launchConfigId;
        uint256 dexId;
        bytes32 salt;
    }

    /// @dev `abi.encode` of `VenueData` — three static words. An exact length
    ///      check is the whole validation a raw `abi.decode` cannot do for
    ///      itself, and a mis-sized blob is a malformed proposal, not a value.
    uint256 private constant _VENUE_DATA_LENGTH = 96;

    /// @dev Upper bound on the `quoteSupported` config scan. The count is
    ///      OWNER-CONTROLLED, and `quoteSupported` must not revert — including
    ///      by running out of gas in a caller's `staticcall` budget. A venue
    ///      that grows past this reports `false` for pairings beyond the bound,
    ///      which fails closed: a launch that would have worked is refused,
    ///      rather than a `true` we could not finish reading sending funds at a
    ///      venue that will reject them. One config exists today.
    uint256 private constant _MAX_CONFIG_SCAN = 256;

    /// @notice The Pons launch factory this adapter fronts.
    IPonsLaunchFactory public immutable factory;

    /// @notice The factory's locker — READ OFF THE FACTORY at construction,
    ///         never passed in, so the two halves of the venue cannot be
    ///         mis-wired relative to each other. The locker is where the fee
    ///         redirect lives, and pointing at the wrong one would silently
    ///         orphan every fund's fee stream.
    IPonsLaunchLocker public immutable locker;

    /// @notice The chain's wrapped native token — the adapter's fee source AND,
    ///         on this venue, the only quote it can fund a dev buy with.
    /// @dev Passed in rather than read off the venue, because the venue exposes
    ///      no wrapped-native getter. The constructor validates it against the
    ///      venue instead of trusting it: some ENABLED launch config must pair
    ///      against exactly this address. That is a stronger check than
    ///      `code.length != 0` on a chain where canonical addresses hold
    ///      unrelated bytecode.
    address public immutable weth;

    /// @notice The best-effort native sweep at the end of `launch` did not go
    ///         through, so `amount` stays on the adapter. Emitted instead of
    ///         reverting — see `_sweepNative`. Nothing here is the launch's
    ///         money.
    event NativeSweepSkipped(address indexed to, uint256 amount);

    /// @notice The constructor's factory is not a contract, or does not answer
    ///         `locker()`. Fail at deploy rather than at the first launch,
    ///         where a mis-wired venue would already hold funds.
    error InvalidFactory();
    /// @notice `factory.locker()` answered zero or a codeless address, or that
    ///         locker disowns this factory. The redirect lane — half of the
    ///         fee routing — would be unusable or would point at a different
    ///         venue's locker.
    error InvalidLocker();
    /// @notice The constructor's wrapped native is zero, codeless, or is not
    ///         the `pairToken` of any enabled launch config. Both the fee and
    ///         the dev buy are funded by unwrapping this token, so a wrong
    ///         address here breaks every launch — and does so only after the
    ///         vault's capital has been pulled.
    error InvalidWeth();
    /// @notice No enabled launch config pairs against this quote, or the quote
    ///         is not the wrapped native. Checked FIRST, before any transfer,
    ///         so a proposal naming a pairing the venue does not offer fails
    ///         without ever moving the vault's capital.
    error UnsupportedQuote(address quoteToken);
    /// @notice `p.feeRecipient == address(0)`. The locker treats a zero
    ///         redirect as "fall back to the deployer" — which is THIS ADAPTER
    ///         — so a zero here would not merely orphan the fee stream, it
    ///         would aim it at a shared contract that has no way to pay it out.
    ///         Checked before any transfer, so a malformed proposal costs the
    ///         vault nothing.
    error ZeroFeeRecipient();
    /// @notice `p.quoteIn == 0`. The venue locks the entire supply in the LP
    ///         position and mints the creator nothing, so the dev buy IS the
    ///         reserve — a zero buy is a launch the fund holds no part of.
    error ZeroQuoteIn();
    /// @notice `p.minTokensOut < p.reserveAmount`. The floor is what makes the
    ///         reserve enforceable; accepting a lower one would let a
    ///         sandwiched buy return fewer tokens than the fund promised its
    ///         holders and still succeed. Adversary: a proposer who states a
    ///         nominal reserve and a floor of zero, then front-runs the launch.
    error ReserveFloorBelowReserve(uint256 minTokensOut, uint256 reserveAmount);
    /// @notice The dev buy delivered less than `p.minTokensOut`.
    ///
    ///         THE ONLY SLIPPAGE ENFORCEMENT THAT EXISTS on this venue. The
    ///         factory hardcodes `amountOutMinimum: 0` on the router call, so
    ///         unlike Sushi there is no venue-side floor behind this check.
    ///         Adversary: a sandwich around the launch transaction, which the
    ///         venue would happily settle at any price.
    error SlippageFloorNotMet(uint256 delivered, uint256 required);
    /// @notice The dev buy delivered less than `p.reserveAmount`. Unreachable
    ///         given the floor check above, since `minTokensOut >=
    ///         reserveAmount` is enforced up front — kept so the custody
    ///         invariant is asserted by THIS contract in its own terms and not
    ///         merely inferred from another of its checks.
    error ReserveNotDelivered(uint256 delivered, uint256 required);
    /// @notice `p.venueData` is not an `abi.encode`d `VenueData`. Rejected on
    ///         length rather than decoded leniently: a short blob would make
    ///         `abi.decode` read past the end, and a long one means the
    ///         proposal was built against a different adapter.
    error InvalidVenueData(uint256 length);
    /// @notice The named launch config is out of range or disabled. The venue
    ///         would reject it too (`InvalidLaunchConfigId` /
    ///         `LaunchConfigDisabled`), but only after the adapter had already
    ///         pulled and unwrapped the vault's capital.
    error LaunchConfigUnusable(uint256 launchConfigId);
    /// @notice The named launch config pairs against a different asset than the
    ///         proposal's quote. Adversary: a proposal voted through naming
    ///         WETH that executes against a config the venue owner has since
    ///         re-pointed — the fund would be paired against an asset nobody
    ///         approved.
    error LaunchConfigQuoteMismatch(uint256 launchConfigId, address pairToken, address quoteToken);
    /// @notice The named dex config is out of range, disabled, or has no swap
    ///         router. The venue's own `RouterNotSet` fires only AFTER the
    ///         token has been minted and the position locked, which would leave
    ///         a half-built launch behind on a revert-free venue upgrade.
    error DexConfigUnusable(uint256 dexId);
    /// @notice `setFeeRedirect` did not take: the locker still reports someone
    ///         other than `p.feeRecipient`. The postcondition assert for the
    ///         crux of this adapter — the fee stream must belong to the vault
    ///         before `launch` returns, and the strategy must not be left
    ///         holding it by an unnoticed venue behaviour change.
    error FeeRedirectNotApplied(address token, address got, address want);
    /// @notice A postcondition sweep left a nonzero balance on the adapter, so
    ///         the "retains no token balance" half of the custody invariant
    ///         could not be established. Unreachable with a well-behaved WETH;
    ///         it fires rather than letting residue accumulate on a shared
    ///         contract.
    error DustRemains(address token, uint256 amount);
    /// @notice Native value arrived from something other than `weth`. The only
    ///         legitimate inbound native payment is the unwrap that funds the
    ///         fee and the buy; anything else is either a mistake or an attempt
    ///         to pre-fund a shared contract, and both are refused.
    error UnexpectedNativePayment(address sender);

    /// @param factory_ `PonsLaunchFactory` (`0xA5aA…1feB` v2 on Robinhood 4663).
    /// @param weth_    The chain's wrapped native (`0x0Bd7…AD73` on 4663).
    constructor(address factory_, address weth_) {
        if (factory_ == address(0) || factory_.code.length == 0) revert InvalidFactory();
        factory = IPonsLaunchFactory(factory_);

        // Read the locker OFF the factory, then make it name the factory back.
        // A one-way check would accept a locker bound to some other factory,
        // whose `setFeeRedirect` would reject every call this adapter makes —
        // and would do so only after a launch had already happened.
        (bool ok, bytes memory ret) = factory_.staticcall(abi.encodeCall(IPonsLaunchFactory.locker, ()));
        if (!ok || ret.length < 32) revert InvalidFactory();
        address locker_ = abi.decode(ret, (address));
        if (locker_ == address(0) || locker_.code.length == 0) revert InvalidLocker();
        if (IPonsLaunchLocker(locker_).factory() != factory_) revert InvalidLocker();
        locker = IPonsLaunchLocker(locker_);

        // The venue names no wrapped native, so validate the one we were given
        // AGAINST the venue: it must be a live pairing. This is the closest
        // available equivalent of `SushiLaunchAdapter` reading `WETH()` off its
        // launchpad.
        if (weth_ == address(0) || weth_.code.length == 0) revert InvalidWeth();
        if (!_isConfiguredPair(weth_)) revert InvalidWeth();
        weth = weth_;
    }

    /// @inheritdoc ILaunchAdapter
    ///
    /// @dev HOW THE CUSTODY INVARIANT IS MET, in order:
    ///        1. `params.feeWallet = msg.sender`, so the venue delivers the dev
    ///           buy — the reserve — to the STRATEGY directly. It is never an
    ///           adapter balance forwarded afterwards, so there is no window in
    ///           which a shared contract holds a fund's tokens;
    ///        2. `locker.setFeeRedirect(token, p.feeRecipient)` runs in this
    ///           same transaction, so the fee stream belongs to the fund's
    ///           VAULT before this returns, and is asserted to;
    ///        3. the token sweeps leave the adapter holding zero launch token
    ///           and zero WETH — asserted — and the native sweep offers back
    ///           any native balance.
    ///      The role the adapter cannot shed is `launched.deployer`; see the
    ///      contract header for why that is contained rather than transferred.
    ///
    ///      THE SALT IS NAMESPACED BY THE CALLER. The venue mints by CREATE2
    ///      over an init code hash that covers the metadata and the deployer,
    ///      and for a singleton the deployer is one constant. Two funds
    ///      launching "Fund Token"/"FUND" under the proposer's identical salt
    ///      would predict the same address and the second would revert
    ///      `PoolAlreadyExists`. Hashing `msg.sender` in gives every strategy
    ///      its own salt space, so no fund can collide with — or deliberately
    ///      squat — another's. Within one fund the proposer's `v.salt` still
    ///      distinguishes retries. Note this makes the token address depend on
    ///      the calling strategy, which is correct: it is that fund's token.
    ///
    ///      BOTH LEGS ARE UNWRAPPED, which is the sharpest difference from the
    ///      Sushi adapter. There, only the fee was native and the quote went to
    ///      the venue as an ERC-20 allowance. Here `initialBuyAmount =
    ///      msg.value - launchFee`, so the buy is native too: the adapter pulls
    ///      `p.quoteIn + fee` of WETH, unwraps the whole amount, and forwards
    ///      it as one `msg.value`. That is also why `p.quoteToken` must BE the
    ///      wrapped native — the adapter has no route from an arbitrary ERC-20
    ///      to the native the venue insists on, and inventing one (an internal
    ///      swap) would price the fund's entry inside the transaction meant to
    ///      execute it.
    ///
    ///      Sweeps go to `msg.sender` rather than being left in place because
    ///      residue on a SHARED contract belongs to whoever calls next: the
    ///      WETH was pulled from this caller, so dust from a repriced fee or
    ///      value the caller attached is theirs. The TOKEN sweeps assert their
    ///      postcondition; the NATIVE sweep is best-effort and never reverts
    ///      the launch. That asymmetry is deliberate: native can be force-sent
    ///      to this address by anyone for one wei, and a shared certified
    ///      singleton that stops serving every fund because someone gave it a
    ///      wei has the wrong invariant. See `_sweepNative`.
    ///
    ///      `payable` is honoured but unnecessary: everything is sourced by
    ///      unwrapping WETH pulled from the caller precisely so a governor
    ///      batch never has to carry value. Value sent anyway is offered
    ///      straight back, and stays here if the caller cannot receive it.
    function launch(LaunchParams calldata p) external payable override returns (LaunchResult memory) {
        // Ordered so every rejection happens before any transfer.
        if (p.feeRecipient == address(0)) revert ZeroFeeRecipient();
        if (!quoteSupported(p.quoteToken)) revert UnsupportedQuote(p.quoteToken);
        if (p.quoteIn == 0) revert ZeroQuoteIn();
        if (p.minTokensOut < p.reserveAmount) revert ReserveFloorBelowReserve(p.minTokensOut, p.reserveAmount);
        VenueData memory v = _validateVenue(p);

        // Both legs are the same token — the quote IS the wrapped native here —
        // so this is one allowance drawn twice, kept as two pulls because they
        // are two different obligations and a reader should be able to tell
        // which is which.
        uint256 fee = factory.launchFee();
        IERC20(weth).safeTransferFrom(msg.sender, address(this), p.quoteIn);
        if (fee != 0) IERC20(weth).safeTransferFrom(msg.sender, address(this), fee);
        IWrappedNative(weth).withdraw(p.quoteIn + fee);

        address token = factory.launchToken{value: p.quoteIn + fee}(
            IPonsLaunchFactory.TokenParams({
                name: p.name,
                symbol: p.symbol,
                logo: "",
                description: "",
                socials: IPonsLaunchFactory.Socials({
                    twitter: "", telegram: "", discord: "", website: "", farcaster: ""
                }),
                // THE STRATEGY, so the dev buy — the reserve — is delivered to
                // it directly. Step 2 immediately below moves the fee half of
                // this same field's duty to the vault.
                feeWallet: msg.sender
            }),
            v.launchConfigId,
            v.dexId,
            keccak256(abi.encode(msg.sender, v.salt))
        );

        // STEP 2, and it is the first thing after the launch on purpose: until
        // it lands, `feeRedirects[token]` is the STRATEGY — the exact custody
        // shape `LaunchParams.feeRecipient` exists to avoid. Permitted because
        // the locker authorises `launched.deployer`, which is this adapter.
        locker.setFeeRedirect(token, p.feeRecipient);
        address redirect = locker.feeRedirects(token);
        if (redirect != p.feeRecipient) revert FeeRedirectNotApplied(token, redirect, p.feeRecipient);

        // The token did not exist before this transaction (fresh CREATE2), so
        // its balance IS the delivery. Read from the chain rather than from a
        // venue return value: `launchToken` returns only the address, and the
        // router's output is not surfaced anywhere.
        uint256 delivered = IERC20(token).balanceOf(msg.sender);
        // The venue passes `amountOutMinimum: 0`, so THIS is the slippage
        // guard, not a second opinion on one.
        if (delivered < p.minTokensOut) revert SlippageFloorNotMet(delivered, p.minTokensOut);
        if (delivered < p.reserveAmount) revert ReserveNotDelivered(delivered, p.reserveAmount);

        _sweepToken(token, msg.sender);
        _sweepToken(weth, msg.sender);
        _sweepNative(msg.sender);

        return LaunchResult({
            token: token,
            // The ref IS the token: this venue keys every verb by token
            // address, so the adapter needs no map and `phase` can answer for a
            // ref it has no record of.
            launchRef: bytes32(uint256(uint160(token))),
            reserveHeld: delivered,
            // The venue spends `msg.value - launchFee` on the buy in full: the
            // router is given the whole amount and nothing is refunded to the
            // factory, so the buy consumed exactly `p.quoteIn`. The native
            // sweep below would return any counter-example to the caller.
            quoteSpent: p.quoteIn
        });
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Two phases only. The factory deploys the token, seeds and
    ///      initialises the V3 pool, mints the position, hands it to the locker
    ///      and executes the buy — all inside `launchToken` — so an issued
    ///      launch is `Live` from the first block and there is no curve,
    ///      closing or failed state to report.
    ///
    ///      GRADUATION IS NOT A PHASE, and the venue's `graduationStatus` is
    ///      deliberately not consulted. It reports whether the locked
    ///      position's paired principal has crossed `graduationThreshold`
    ///      (4.2 WETH on config 0) — a Pons-side marketing milestone. It
    ///      changes nothing this interface models: the pool was tradable
    ///      before it and is tradable after, the position stays locked either
    ///      way, the reserve is already the strategy's, and the fee stream is
    ///      already the vault's. Mapping it onto `Closing` would tell
    ///      settlement to wait for something that never has to happen, and
    ///      mapping it onto `Live` would make `Live` conditional on a threshold
    ///      the owner can move. It is also a REVERTING, pool-reading call
    ///      (`TokenNotFound`, `slot0`, `positions`) inside a view that must not
    ///      revert. So: not a phase, by argument rather than by omission.
    ///
    ///      MUST NOT REVERT. `getLaunchedToken` happens not to revert for an
    ///      unknown token — it returns a zero struct, the opposite of Sushi's
    ///      `launchInfo` — but that is the venue's current behaviour, not a
    ///      guarantee this contract may lean on, so the read is a
    ///      length-checked raw staticcall anyway. Unknown, unreadable,
    ///      short-returning, dirty-high-bits, `exists == false`, or a launch
    ///      some OTHER deployer made all resolve to `None`.
    ///
    ///      The `deployer == address(this)` condition is the stricter answer
    ///      the venue makes available and Sushi did not: this reports on
    ///      launches THIS ADAPTER issued, so a Pons token launched by anyone
    ///      else is `None` here rather than being claimed.
    function phase(bytes32 launchRef) external view override returns (LaunchPhase) {
        address token = _refToToken(launchRef);
        if (token == address(0)) return LaunchPhase.None;
        (bool known,,) = _readLaunched(token);
        if (!known) return LaunchPhase.None;
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
    /// @dev PERMISSIONLESS ON OUR SIDE, THOUGH NOT AT THE VENUE. The locker's
    ///      `collectFees` admits only its owner, the launch's `deployer`, the
    ///      current recipient, or an allowlisted collector. This adapter IS the
    ///      deployer, so it may always call — and since the adapter itself
    ///      imposes no caller check and the payee is fixed in the locker's
    ///      storage, anyone may drive it and nobody can steer it. That is the
    ///      interface's "permissionless" delivered through a venue that is not.
    ///
    ///      REPORTS THE RECIPIENT'S DELTAS, never the caller's and never the
    ///      locker's return tuple. Two independent reasons, both live:
    ///        - the locker returns the GROSS `collect`, then keeps
    ///          `tokenProtocolFeeShares[token]` percent (30 today) before
    ///          paying the recipient. Reporting the return value would
    ///          overstate what the vault received by exactly the protocol's cut;
    ///        - the payee is the locker's `feeRedirects[token]` — the vault,
    ///          set in `launch` — so measuring `msg.sender` would report zero
    ///          for a keeper driving fees to the fund, which reads to a
    ///          settlement path as "nothing accrued".
    ///
    ///      The legs are named from the launch's own record: `quoteOut` is the
    ///      `pairedToken` leg, `tokenOut` the launch token leg.
    ///
    ///      REFUSES TO PAY ITSELF. If the redirect ever read back as zero or as
    ///      this adapter, the locker would pay the DEPLOYER — a shared contract
    ///      with no payout path, where the fund's fees would be stranded. That
    ///      case returns `(0, 0)` without calling, so the fees stay claimable
    ///      once the redirect is right rather than being swept somewhere they
    ///      cannot be recovered from. It is unreachable through `launch`, which
    ///      asserts the redirect landed.
    ///
    ///      Returns `(0, 0)` rather than reverting on an unknown launch or a
    ///      venue call that fails — `NoFeesToCollect()` being the ordinary
    ///      case, and the interface's whole reason for this rule: settlement
    ///      calls this unconditionally, and a revert here would strand a
    ///      settlement, not merely a fee. A failed venue call reverts its own
    ///      state, so the deltas below are then genuinely zero.
    function collectFees(bytes32 launchRef) external override returns (uint256 quoteOut, uint256 tokenOut) {
        address token = _refToToken(launchRef);
        if (token == address(0)) return (0, 0);
        (bool known,, address pairedToken) = _readLaunched(token);
        if (!known) return (0, 0);

        address recipient = _safeFeeRedirect(token);
        if (recipient == address(0) || recipient == address(this)) return (0, 0);

        uint256 quoteBefore = _balanceOf(pairedToken, recipient);
        uint256 tokenBefore = _balanceOf(token, recipient);

        // Raw call: a venue revert must not propagate (see above). Not
        // `try/catch` — the return tuple is the GROSS and is deliberately
        // unused, so there is nothing to decode on the success path either.
        (bool collected,) = address(locker).call(abi.encodeCall(IPonsLaunchLocker.collectFees, (token)));
        // A failed call reverted its own state, so nothing moved: `(0, 0)` is
        // the honest report, not a swallowed error.
        if (!collected) return (0, 0);

        uint256 quoteAfter = _balanceOf(pairedToken, recipient);
        uint256 tokenAfter = _balanceOf(token, recipient);
        quoteOut = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        tokenOut = tokenAfter > tokenBefore ? tokenAfter - tokenBefore : 0;
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev TWO GATES, AND THEY ARE NOT THE SAME KIND OF LIMIT. Stated apart
    ///      because conflating them would misattribute the constraint:
    ///
    ///        1. VENUE CONFIGURATION. A pairing is supported only while some
    ///           ENABLED `LaunchConfig` names it as `pairToken`. This is not an
    ///           allowlist of ours — it is the venue's own gate, read live, so
    ///           the answer changes the moment the Pons owner adds, enables or
    ///           disables a config, with no change, redeploy or
    ///           re-certification here. WETH is the only pairing configured
    ///           today (`launchConfigCount() == 1`), so WETH is the only true
    ///           answer today. USDG, WOOD or a stock token would become true by
    ///           a Pons configuration change alone.
    ///
    ///        2. THIS ADAPTER'S OWN LIMIT: the quote must BE the wrapped
    ///           native. The venue funds the dev buy from `msg.value`
    ///           (`initialBuyAmount = msg.value - launchFee`) and hands it to
    ///           the router as native against `tokenIn = pairToken`, so a
    ///           non-wrapped-native pairing has no way to be funded from a
    ///           strategy's ERC-20 holdings — not by this adapter, and not by
    ///           the venue itself. If Pons ever configures such a pairing, this
    ///           answers `false` and the honest fix is a new adapter, not a
    ///           silent internal swap that would price the fund's entry inside
    ///           the transaction meant to execute it.
    ///
    ///      MUST NOT REVERT, so every read below is a length-checked raw
    ///      staticcall and the scan is bounded by `_MAX_CONFIG_SCAN`.
    ///      Unreadable resolves to `false` (fail closed — a launch that would
    ///      have worked is merely refused, whereas a `true` we could not read
    ///      would send funds at a venue that will reject them).
    function quoteSupported(address quoteToken) public view override returns (bool) {
        if (quoteToken == address(0) || quoteToken != weth) return false;
        return _isConfiguredPair(quoteToken);
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev WETH, always. The venue charges its fee in NATIVE and takes it out
    ///      of `msg.value`, and the strategy has to source that from tokens it
    ///      holds. Naming the token here lets the strategy acquire it through
    ///      its own allowlisted swap adapter.
    ///
    ///      REPORTS THE FEE ONLY, NOT THE BUY. On this venue the same
    ///      unwrapping lane also funds `p.quoteIn`, but that is the launch
    ///      quote and the strategy already knows to hold it — this getter
    ///      exists to name the EXTRA charge the interface's callers would not
    ///      otherwise know about. A caller must approve
    ///      `p.quoteIn + this amount`; because the quote and the fee source are
    ///      the same token here, that is one allowance.
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
    /// @dev NAMES THE FACTORY. The deploy ceremony asserts counterparty
    ///      standing against this address, and the locker's standing is derived
    ///      from it — `factory.locker()` is read in the constructor and the
    ///      locker names the factory back, so vouching for one vouches for the
    ///      pair.
    ///
    ///      NOT A HANDOFF ADDRESS, and here the point is sharper than on Sushi.
    ///      This venue offers no creator-role transfer at all: `deployer` is
    ///      written once by the factory and is immutable thereafter. A
    ///      settlement that tried to move it would find no such function. The
    ///      fee stream is already the vault's, named at launch; there is
    ///      nothing left to hand over, and the adapter deliberately exposes no
    ///      route to re-point it.
    function launchTarget() external view override returns (address) {
        return address(factory);
    }

    /// @notice Accept native ONLY from `weth`.
    /// @dev The single legitimate inbound payment is the unwrap inside
    ///      `launch`. A shared, stateless contract that accepted native from
    ///      anyone would accumulate a balance belonging to no one, so anything
    ///      else is refused here.
    ///
    ///      This guard is not airtight and is not relied on to be: a
    ///      `selfdestruct` force-send reaches any address and cannot be refused
    ///      by this or any other contract. That case is handled downstream —
    ///      `_sweepNative` is best-effort, so a force-sent balance CANNOT brick
    ///      `launch`; it is offered to whoever launches next, and if that
    ///      caller cannot receive native it simply sits here until one can. No
    ///      accounting anywhere reads this balance.
    receive() external payable {
        if (msg.sender != weth) revert UnexpectedNativePayment(msg.sender);
    }

    // ── internals ──

    /// @dev Decode and validate `p.venueData` against the LIVE venue, before
    ///      any capital moves. Every one of these would also be caught by the
    ///      venue — but `LaunchConfigDisabled` and friends fire only after the
    ///      adapter has pulled and unwrapped the vault's WETH, and
    ///      `RouterNotSet` fires only after the token has been minted. Failing
    ///      here keeps a stale or re-pointed config from costing anything.
    ///
    ///      The quote match is the one check that is ours rather than the
    ///      venue's: the venue would happily pair against whatever the config
    ///      says, including an asset the proposal never named.
    function _validateVenue(LaunchParams calldata p) private view returns (VenueData memory v) {
        if (p.venueData.length != _VENUE_DATA_LENGTH) revert InvalidVenueData(p.venueData.length);
        v = abi.decode(p.venueData, (VenueData));

        if (v.launchConfigId >= factory.launchConfigCount()) revert LaunchConfigUnusable(v.launchConfigId);
        IPonsLaunchFactory.LaunchConfig memory config = factory.getLaunchConfig(v.launchConfigId);
        if (!config.enabled) revert LaunchConfigUnusable(v.launchConfigId);
        if (config.pairToken != p.quoteToken) {
            revert LaunchConfigQuoteMismatch(v.launchConfigId, config.pairToken, p.quoteToken);
        }

        if (v.dexId >= factory.dexConfigCount()) revert DexConfigUnusable(v.dexId);
        IPonsLaunchFactory.DexConfig memory dex = factory.getDexConfig(v.dexId);
        if (!dex.enabled || dex.swapRouter == address(0)) revert DexConfigUnusable(v.dexId);
    }

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

    /// @dev Length-checked raw read of `getLaunchedToken(token)`, returning only
    ///      what the verbs here need. `LaunchedToken` is a fully static struct,
    ///      so the payload is exactly thirteen in-place words — `token` at word
    ///      0, `deployer` at word 1, `pairedToken` at word 2, `exists` at word
    ///      11. Anything shorter, a revert, a codeless target, dirty high bits,
    ///      `exists == false`, a self-inconsistent record, or a deployer other
    ///      than this adapter all answer `known = false`.
    function _readLaunched(address token) private view returns (bool known, address deployer, address pairedToken) {
        address target = address(factory);
        if (target.code.length == 0) return (false, address(0), address(0));
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(IPonsLaunchFactory.getLaunchedToken, (token)));
        if (!ok || ret.length < 416) return (false, address(0), address(0));

        uint256 tokenWord;
        uint256 deployerWord;
        uint256 pairedWord;
        uint256 existsWord;
        assembly ("memory-safe") {
            tokenWord := mload(add(ret, 0x20))
            deployerWord := mload(add(ret, 0x40))
            pairedWord := mload(add(ret, 0x60))
            existsWord := mload(add(ret, 0x180))
        }
        if (existsWord == 0) return (false, address(0), address(0));
        if (tokenWord >> 160 != 0 || deployerWord >> 160 != 0 || pairedWord >> 160 != 0) {
            return (false, address(0), address(0));
        }
        // All three casts are safe: the guard above rejects any word carrying
        // set bits above 160, so none can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (address(uint160(tokenWord)) != token) return (false, address(0), address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        deployer = address(uint160(deployerWord));
        // Launches this adapter did not issue are not this adapter's to report
        // on — and it holds no `deployer` power over them either.
        if (deployer != address(this)) return (false, address(0), address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return (true, deployer, address(uint160(pairedWord)));
    }

    /// @dev Non-reverting scan for an ENABLED launch config pairing against
    ///      `quoteToken`. `LaunchConfig` is fully static — ten in-place words,
    ///      `pairToken` at word 0 and `enabled` at word 8 — so it reads the two
    ///      it needs without decoding the rest. Used by `quoteSupported` and by
    ///      the constructor's WETH validation, which is why it lives here
    ///      rather than inline.
    function _isConfiguredPair(address quoteToken) private view returns (bool) {
        address target = address(factory);
        if (target.code.length == 0) return false;

        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(IPonsLaunchFactory.launchConfigCount, ()));
        if (!ok || ret.length < 32) return false;
        uint256 count = abi.decode(ret, (uint256));
        if (count > _MAX_CONFIG_SCAN) count = _MAX_CONFIG_SCAN;

        for (uint256 i; i < count; ++i) {
            (ok, ret) = target.staticcall(abi.encodeCall(IPonsLaunchFactory.getLaunchConfig, (i)));
            if (!ok || ret.length < 320) continue;
            uint256 pairWord;
            uint256 enabledWord;
            assembly ("memory-safe") {
                pairWord := mload(add(ret, 0x20))
                enabledWord := mload(add(ret, 0x120))
            }
            if (enabledWord == 0 || pairWord >> 160 != 0) continue;
            // Safe: the guard above rejects any word with set bits above 160.
            // forge-lint: disable-next-line(unsafe-typecast)
            if (address(uint160(pairWord)) == quoteToken) return true;
        }
        return false;
    }

    /// @dev Safe-read of the locker's current fee destination for one launch;
    ///      unreadable → `address(0)`, which `collectFees` treats as "do not
    ///      drive a collection that might pay this adapter".
    function _safeFeeRedirect(address token) private view returns (address) {
        address target = address(locker);
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(IPonsLaunchLocker.feeRedirects, (token)));
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        // Safe: the guard above rejects any word with set bits above 160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }

    /// @dev Safe-read of the fee for `nativeFeeSource`; unreadable → 0.
    function _safeLaunchFee() private view returns (uint256) {
        address target = address(factory);
        if (target.code.length == 0) return 0;
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeCall(IPonsLaunchFactory.launchFee, ()));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Non-reverting balance read, so `collectFees` cannot be turned into
    ///      a revert by a launch whose paired token has since become
    ///      unreadable.
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
    ///      the whole balance clears it, so the dust is forwarded and the
    ///      assert passes. The only residue it can catch is a transfer that
    ///      moves less than it was asked to — fee-on-transfer, or a rebase —
    ///      which for the WETH leg would already have broken the exact unwrap a
    ///      few lines earlier. The launch token cannot be pre-dusted at all: it
    ///      does not exist until this transaction.
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
    ///      the fee and the buy were pulled from the caller in WETH, unwrapped
    ///      exactly, and forwarded to the venue in full as one `msg.value`, and
    ///      the strategy attaches no value of its own. Any balance is therefore
    ///      either value a caller attached voluntarily or native force-sent by
    ///      `selfdestruct`, which no contract can refuse.
    ///
    ///      Reverting on a failed send would hand that force-send the power to
    ///      disable `launch` FOR EVERY FUND, permanently, for one wei: the
    ///      caller is a `BaseStrategy` clone, no strategy declares `receive` or
    ///      `fallback`, so the send to it can never succeed, and this is the
    ///      only path that moves native off this contract — recovery would mean
    ///      a new implementation plus re-certification, and on this venue also
    ///      a fresh whitelist entry from Pons. The invariant a SHARED,
    ///      CERTIFIED singleton has to hold is that it keeps working, and that
    ///      strictly dominates "it always returns dust". Leaving the balance
    ///      takes nothing from anyone with a claim on it, and the next caller
    ///      whose send DOES succeed sweeps it.
    ///
    ///      Expect this to move nothing in the ordinary case: the unwrap is
    ///      exact and the venue takes the whole amount.
    function _sweepNative(address to) private {
        uint256 bal = address(this).balance;
        if (bal == 0) return;
        (bool ok,) = to.call{value: bal}("");
        // Deliberately not a revert. The event is the whole handling.
        if (!ok) emit NativeSweepSkipped(to, bal);
    }
}
