// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ILaunchAdapter} from "../interfaces/ILaunchAdapter.sol";
import {IStonkSafeLaunchpadV2} from "../vendor/stonkbrokers/IStonkSafeLaunchpadV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice The two reads the clone needs from the strategy that owns it.
/// @dev Deliberately NOT `IStrategy`: the clone must be able to ask these
///      questions of an owner that answers neither, and a typed import would
///      invite a typed call. Both are read by length-checked raw staticcall.
interface IOwningStrategy {
    /// @dev `BaseStrategy.State` — `0 Pending, 1 Executed, 2 Settled`.
    function state() external view returns (uint8);
    /// @dev The vault the owning strategy delivers to.
    function vault() external view returns (address);
}

/**
 * @title StonkLaunchAdapter
 * @notice `ILaunchAdapter` over the StonkBrokers Smart Launch pads — an
 *         IMPLEMENTATION plus one ERC-1167 CLONE PER LAUNCH, in one contract.
 *
 *   WHY A CLONE, WHERE SUSHI IS A SINGLETON. The interface's custody invariant
 *   bans an adapter that accumulates balances or creator roles. Sushi's creator
 *   role is TRANSFERABLE, so its adapter can be creator for a few opcodes and
 *   hand the role to the calling strategy in the same transaction. This venue
 *   PINS the creator at `createLaunch` and offers no transfer whatsoever. A
 *   shared singleton here would become the permanent creator of every fund's
 *   launch — one contract holding every fee stream and every `abort` lever,
 *   keyed by its own bookkeeping. That is precisely the shared-mutable-custody
 *   shape prior audit rounds kept removing from this codebase. So each launch
 *   gets its own clone, owned by the calling strategy, and a compromise of one
 *   reaches exactly one fund.
 *
 *   ONE CONTRACT, TWO ROLES. The implementation IS the clone logic;
 *   `Clones.clone(implementation)` mints instances of this same code.
 *     - IMPLEMENTATION ROLE (the address `TierRegistry` allowlists and
 *       certifies): `launch`, `phase`, `finalize`, `collectFees`,
 *       `quoteSupported`, `nativeFeeSource`, `launchTarget`, `lanes`. Its
 *       constructor writes the lane -> pad map and then LOCKS ITS OWN
 *       INITIALIZER (`BaseStrategy`'s template-lock precedent), so nobody can
 *       initialize the implementation itself and turn the certified address
 *       into somebody's clone.
 *     - CLONE ROLE (owned by one strategy): `initialize`, `executeLaunch`,
 *       `clonePhase`, `cloneFinalize`, `cloneCollectFees`, `abort`,
 *       `forwardToVault`.
 *   The roles do not overlap: a clone-role verb on the implementation finds
 *   `owner == address(0)` and fails closed, and `launch` on a clone finds
 *   `address(this) != implementation` and reverts.
 *
 *   IMMUTABLES CROSS THE PROXY, STORAGE DOES NOT. An ERC-1167 clone delegates
 *   into this code, so `implementation`, `lens` and `padSetHash` read the same
 *   from a clone (they live in the code). The lane map is STORAGE and is
 *   therefore the implementation's alone — which is why `quoteSupported` on a
 *   clone answers `false` for everything, and why the clone is handed its pad
 *   at `initialize` rather than looking one up.
 *
 *   THE PAD SET IS IMMUTABLE CONFIGURATION, AND `padSetHash` IS HOW THAT IS
 *   PROVED. `setAdapterAllowed` snapshots the implementation's CODEHASH, and a
 *   codehash cannot see storage at all — so a mutable lane map would be a
 *   routing lever living entirely outside the gate, able to redirect every
 *   future launch to an uncertified venue without changing anything the gate
 *   can observe. There is therefore no setter, anywhere, at any access level.
 *   "No setter exists" is still a claim a certifier would have to establish by
 *   reading the code, so the implementation also exposes an IMMUTABLE
 *   `padSetHash = keccak256(abi.encode(quotes, pads))` over the ordered pairs
 *   it was constructed with: the codehash pins the code, the pad-set hash pins
 *   the configuration that code was certified against, and `lanes()` returns
 *   the arrays to hash. Serving a new lane means a new implementation and a
 *   fresh certification.
 *
 *   REENTRANCY. No guard, deliberately. The implementation holds no balance and
 *   no role between calls and its only mutable state is constructor-written. A
 *   clone holds value only inside `executeLaunch`, which is callable exactly
 *   once (`launchToken == address(0)`) and only by the implementation; every
 *   other clone verb sends to a FIXED destination — the owner or the owner's
 *   vault — read before the transfer, so a re-entrant token cannot redirect it.
 *
 *   The caller approves the IMPLEMENTATION for `p.quoteIn` of the quote before
 *   calling `launch`; the implementation forwards it to the fresh clone. It
 *   cannot be approved to the clone, whose address does not exist yet.
 */
contract StonkLaunchAdapter is ILaunchAdapter {
    using SafeERC20 for IERC20;

    /// @notice The venue economics `ILaunchAdapter.LaunchParams.venueData`
    ///         carries on this venue, decoded inside the clone.
    ///
    /// @dev PASSED THROUGH, NOT RE-VALIDATED. The pad enforces a dense set of
    ///      economics rules (tax/decay divisibility, the derived window against
    ///      `bounds()`, `openEnded` implying sells and a post-tax in [100, 500],
    ///      `unsoldMode <= 1`, `maxBuyPpm <= 42069`) and reverts `BadEconomics`
    ///      otherwise. Re-implementing those here would be a second copy of a
    ///      rule set the venue owner can change — a copy that would start
    ///      rejecting launches the venue accepts, or worse, accepting ones it
    ///      does not. The three fields NOT taken from the caller are the ones
    ///      whose safety is ours, not the venue's: see `executeLaunch`.
    /// @param supply               Total supply to mint, in wei.
    /// @param startMcapUsd8        Starting market cap, 8-decimal USD.
    /// @param gradMcapUsd8         Graduation market cap, 8-decimal USD.
    /// @param startTaxBps          Opening trade tax.
    /// @param taxDecayPerMinuteBps Per-minute decay; with `startTaxBps` this
    ///                             DERIVES the curve window at the venue.
    /// @param sellsEnabled         Whether the curve accepts sells.
    /// @param bufferSecs           Post-window buffer the venue applies.
    /// @param unsoldMode           Unsold-supply disposition at graduation.
    /// @param openEnded            No closing deadline (see `clonePhase`).
    /// @param postTaxBps           Tax after the decay schedule ends.
    /// @param bondVenue            AMM `bond()` mints the locked LP on.
    /// @param maxBuyPpm            Per-wallet buy cap, ppm of supply.
    struct VenueData {
        uint256 supply;
        uint64 startMcapUsd8;
        uint64 gradMcapUsd8;
        uint16 startTaxBps;
        uint16 taxDecayPerMinuteBps;
        bool sellsEnabled;
        uint32 bufferSecs;
        uint8 unsoldMode;
        bool openEnded;
        uint16 postTaxBps;
        uint8 bondVenue;
        uint32 maxBuyPpm;
    }

    /// @dev The lifecycle flags `clonePhase` reads out of the pad's `Launch`
    ///      struct. A local shape, so the raw read decodes five words and not
    ///      twenty-two.
    struct LaunchFlags {
        uint64 deadline;
        bool armed;
        bool graduated;
        bool bonded;
        bool aborted;
    }

    // ── ERC-1167 introspection constants ──

    /// @dev The 45-byte ERC-1167 runtime is
    ///      `363d3d373d3d3d363d73 <20-byte implementation> 5af43d82803e903d91602b57fd5bf3`.
    ///      These are its two fixed halves; the 20 bytes between them are what
    ///      `_isOurClone` compares against `implementation`.
    uint256 private constant _CLONE_RUNTIME_LENGTH = 45;
    bytes10 private constant _CLONE_PREFIX = 0x363d3d373d3d3d363d73;
    uint120 private constant _CLONE_SUFFIX = 0x5af43d82803e903d91602b57fd5bf3;

    /// @dev `BaseStrategy.State.Settled`. The value, not the type, because the
    ///      owner is read by raw staticcall and may not be a `BaseStrategy`.
    uint256 private constant _STATE_SETTLED = 2;

    // ── shared immutables (live in code, so a clone reads them identically) ──

    /// @notice This code's implementation address — the one `TierRegistry`
    ///         allowlists, the one embedded in every clone's runtime, and the
    ///         one `launch` clones.
    /// @dev Baked in at construction, so inside a clone this is still the
    ///      implementation while `address(this)` is the clone. That difference
    ///      is what separates the two roles.
    address public immutable implementation;

    /// @notice `SafeLaunchLensV2` — the venue's only sanctioned source of curve
    ///         numbers, and a counterparty the deploy ceremony vouches for.
    /// @dev Held, exposed, and NEVER CALLED on-chain. The adapter derives no
    ///      number from the curve: `minTokensOut` arrives from the proposal,
    ///      quoted through this lens off-chain and voted on. Re-quoting at
    ///      execute would enforce a floor nobody approved, read off a price
    ///      movable inside the transaction it is meant to protect.
    address public immutable lens;

    /// @notice `keccak256(abi.encode(quotes, pads))` over the ordered lane set
    ///         this implementation was constructed with.
    /// @dev See the contract header: this is what makes the certified lane set
    ///      verifiable on-chain, because the codehash gate cannot see storage.
    ///      Compare it against `keccak256(abi.encode(lanes()))`-shaped data, or
    ///      against the arrays recorded in the deploy ceremony.
    bytes32 public immutable padSetHash;

    // ── implementation-role storage (constructor-written; no setter, ever) ──

    /// @notice Lane -> pad. `address(0)` means this venue cannot pair against
    ///         that quote — permanently, since a lane here is a DEPLOYMENT.
    mapping(address quoteToken => address pad) public padOf;

    address[] private _laneQuotes;
    address[] private _lanePads;

    // ── clone-role storage (zero on the implementation, and stays that way) ──

    /// @notice The strategy that owns this clone. `address(0)` on the
    ///         implementation, which is what makes every clone verb fail closed
    ///         there.
    address public owner;

    /// @dev One-shot init flag. Set `true` in the constructor so the
    ///      IMPLEMENTATION can never be initialized (the `BaseStrategy`
    ///      template-lock precedent); a fresh clone starts `false`.
    bool private _initialized;

    /// @notice The pad this clone launched on.
    address public pad;

    /// @notice The pad's lane quote asset, pinned at `initialize` from the pair
    ///         the constructor already proved matches `pad.quote()`.
    address public laneQuote;

    /// @notice The launched ERC-20. Nonzero IFF this clone has launched — the
    ///         sentinel every clone verb keys off, deliberately NOT `launchId`,
    ///         which the venue is free to number from zero.
    address public launchToken;

    /// @notice The pad-scoped launch id.
    uint256 public launchId;

    // ── events ──

    /// @notice A launch was opened by a fresh clone.
    event LaunchCloned(
        address indexed clone, address indexed strategy, address indexed padAddress, uint256 launchId, address token
    );
    /// @notice A venue call was refused and TOLERATED. Not an error: a curve
    ///         that cannot graduate yet, or a launch with no fees accrued, is
    ///         the normal case, and both `finalize` and `collectFees` are safe
    ///         to call in any phase. A refused leg reverted its own state, so
    ///         nothing moved and anyone may retry it forever.
    event VenueLegSkipped(bytes32 indexed leg);
    /// @notice Creator fees that landed on the owning strategy.
    event FeesCollected(address indexed owner, uint256 quoteOut, uint256 tokenOut);
    /// @notice The post-settlement lane: everything the clone held, delivered
    ///         to the owning strategy's vault.
    event ForwardedToVault(address indexed vault, uint256 quoteOut, uint256 tokenOut);
    /// @notice The owner pulled the venue's zero-trades recovery lever.
    event LaunchAborted(address indexed owner, uint256 returned);

    // ── errors ──

    /// @notice Constructor lane arrays were empty or of unequal length. A lane
    ///         set is the configuration this implementation is certified
    ///         against; a mismatched one would certify a map nobody wrote.
    error InvalidLaneSet(uint256 quotesLength, uint256 padsLength);
    /// @notice A lane's quote or pad was zero, or the pad held no code. Fail at
    ///         deploy rather than at the first launch on that lane.
    error InvalidLane(uint256 index, address quoteToken, address padAddress);
    /// @notice Two lanes named the same quote. Silently keeping the last would
    ///         make `padSetHash` describe a map the contract does not have.
    error DuplicateQuote(address quoteToken);
    /// @notice The pad does not itself claim the lane it was paired with.
    ///         IDENTITY, not presence — the same doctrine the Sushi deploy
    ///         script applies to canonical DEX addresses on this chain, where a
    ///         `code.length != 0` check passes on a squatted address. A pad
    ///         that disagrees about its own quote would route a fund's capital
    ///         into the wrong lane.
    error PadQuoteMismatch(address padAddress, address expected, address actual);
    /// @notice The lens was zero or codeless.
    error InvalidLens();
    /// @notice This venue cannot pair against `quoteToken` — no pad serves that
    ///         lane, and none ever will without a new implementation. Checked
    ///         FIRST, before any transfer, so a WOOD-quoted proposal fails
    ///         without moving the vault's capital.
    error UnsupportedQuote(address quoteToken);
    /// @notice A clone-role verb was reached on the implementation, or an
    ///         implementation-role verb on a clone.
    error WrongRole(address self, address expected);
    /// @notice `initialize` / `executeLaunch` was not called by the
    ///         implementation that minted this clone. An attacker who clones
    ///         this code directly therefore gets a clone that can never be
    ///         initialized: `owner` stays zero and every verb fails closed.
    error NotImplementation(address caller);
    /// @notice `initialize` ran twice, or ran on the implementation (whose
    ///         constructor locks it).
    error AlreadyInitialized();
    /// @notice A clone verb was reached before `initialize`.
    error NotInitialized();
    /// @notice A clone verb needing a launch was reached before `executeLaunch`.
    error NotLaunched();
    /// @notice `executeLaunch` ran twice on one clone.
    error AlreadyLaunched(address token);
    /// @notice An owner-only verb was called by somebody else. `abort` is a
    ///         recovery lever whose whole value is that nobody else can pull
    ///         it; `forwardToVault` is owner-only until the owner settles.
    error NotOwner(address caller, address expectedOwner);
    /// @notice The venue started charging a native launch fee. This adapter has
    ///         no lane to fund one from — see `nativeFeeSource` — so it REFUSES
    ///         rather than calling `createLaunch` with `msg.value == 0` and
    ///         reverting deep inside the venue, or worse, succeeding
    ///         under-funded. Stated limitation, to revisit if this ever fires.
    error NativeFeeUnsupported(address padAddress, uint256 feeWei);
    /// @notice Native value was attached to `launch`. The venue charges nothing
    ///         and this contract has no `receive()`, so attached value could
    ///         only sit on a SHARED contract belonging to whoever swept next.
    error NativeValueRejected(uint256 value);
    /// @notice `p.reserveAmount >= supply`: there would be nothing left to arm,
    ///         so the "launch" would be a mint with no curve behind it.
    error ReserveExceedsSupply(uint256 reserveAmount, uint256 supply);
    /// @notice `p.quoteIn == 0` but `p.minTokensOut != 0`. A slippage floor
    ///         with no trade under it is a floor that cannot be enforced — the
    ///         params contradict each other, and silently ignoring one half is
    ///         how a fund ends up with a reserve nobody checked.
    error MinOutWithoutBuy(uint256 minTokensOut);
    /// @notice `block.timestamp > p.deadline`. This venue's `createLaunch`
    ///         takes no deadline of its own, so the adapter enforces the
    ///         caller's locally rather than dropping it — a proposal executed
    ///         weeks late would otherwise launch at economics nobody re-read.
    error DeadlineExpired(uint64 deadline, uint256 nowTimestamp);
    /// @notice The pad did not mint the declared supply to this clone. Guards
    ///         the arm arithmetic below against a venue whose mint path changed.
    error SupplyNotDelivered(uint256 delivered, uint256 supply);
    /// @notice The clone finished a launch still holding launch tokens. The
    ///         custody invariant says the clone keeps the creator role and
    ///         NOTHING ELSE; this fires on a fee-on-transfer or rebasing token
    ///         rather than letting a balance sit on the clone.
    error DustRemains(address token, uint256 amount);
    /// @notice The owning strategy's `vault()` could not be read, so
    ///         `forwardToVault` had no destination. Reverting is the point: the
    ///         alternative is sending a fund's fees to an address derived from
    ///         an unreadable call.
    error VaultUnresolved(address ownerStrategy);

    /// @notice Wire the immutable lane set.
    /// @param quotes Ordered lane quote assets.
    /// @param pads   Ordered pads, `pads[i]` serving `quotes[i]`.
    /// @param lens_  `SafeLaunchLensV2`.
    ///
    /// @dev Every pair is checked for IDENTITY (`pad.quote() == quotes[i]`),
    ///      not presence. A typed call is right here and nowhere else in this
    ///      contract: a pad that cannot answer `quote()` must abort the DEPLOY,
    ///      loudly, and there is no fund's capital in flight to strand.
    ///
    ///      Duplicate PADS need no separate check: `quote()` is single-valued,
    ///      so one pad cannot pass the identity assertion for two distinct
    ///      lanes, and two identical lanes are caught by `DuplicateQuote`.
    ///
    ///      The last two statements are the template lock: `_initialized = true`
    ///      means `initialize` can never run on the implementation, so the
    ///      certified address cannot be turned into somebody's clone and made
    ///      to hold a launch.
    constructor(address[] memory quotes, address[] memory pads, address lens_) {
        uint256 n = quotes.length;
        if (n == 0 || n != pads.length) revert InvalidLaneSet(n, pads.length);
        if (lens_ == address(0) || lens_.code.length == 0) revert InvalidLens();

        for (uint256 i; i < n; ++i) {
            address q = quotes[i];
            address padAddress = pads[i];
            if (q == address(0) || padAddress == address(0) || padAddress.code.length == 0) {
                revert InvalidLane(i, q, padAddress);
            }
            if (padOf[q] != address(0)) revert DuplicateQuote(q);
            address claimed = IStonkSafeLaunchpadV2(padAddress).quote();
            if (claimed != q) revert PadQuoteMismatch(padAddress, q, claimed);
            padOf[q] = padAddress;
            _laneQuotes.push(q);
            _lanePads.push(padAddress);
        }

        lens = lens_;
        padSetHash = keccak256(abi.encode(quotes, pads));
        implementation = address(this);
        _initialized = true;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // implementation role — ILaunchAdapter
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILaunchAdapter
    ///
    /// @dev HOW THE CUSTODY INVARIANT IS MET, in order:
    ///        1. a FRESH CLONE is minted and initialized with
    ///           `owner = msg.sender` before it touches the venue, so the
    ///           creator role this launch pins is pinned to an instance the
    ///           calling strategy exclusively owns — never to this shared,
    ///           certified implementation;
    ///        2. the clone transfers `p.reserveAmount` to the OWNER before it
    ///           arms anything, and any dev buy is delivered by the pad
    ///           DIRECTLY to the owner (`recipient = owner`), so the reserve is
    ///           never a shared-contract balance forwarded afterwards;
    ///        3. `executeLaunch` asserts the clone ends holding zero launch
    ///           token, and returns any unspent quote to the owner.
    ///      The implementation itself never holds a balance at all: the quote
    ///      it pulls goes straight to the clone in the same statement.
    ///
    ///      `payable` is honoured by the interface and REFUSED in fact. The
    ///      venue's fee is zero and this contract exposes no `receive()`;
    ///      attached value would sit on a shared contract belonging to whoever
    ///      swept next, so it is rejected outright.
    function launch(LaunchParams calldata p) external payable override returns (LaunchResult memory) {
        if (address(this) != implementation) revert WrongRole(address(this), implementation);
        if (msg.value != 0) revert NativeValueRejected(msg.value);

        // Ordered so every rejection happens before any transfer.
        address padAddress = padOf[p.quoteToken];
        if (padAddress == address(0)) revert UnsupportedQuote(p.quoteToken);

        // Read the fee LIVE and typed. It is zero on every pad today; if the
        // venue ever starts charging, this reverts rather than under-funding.
        uint256 feeWei = IStonkSafeLaunchpadV2(padAddress).launchFeeWei();
        if (feeWei != 0) revert NativeFeeUnsupported(padAddress, feeWei);

        address clone = Clones.clone(implementation);
        StonkLaunchAdapter(clone).initialize(msg.sender, padAddress, p.quoteToken);

        // The caller could not have approved an address that did not exist, so
        // the quote is pulled here and forwarded in one move; this contract is
        // never the resting place for it.
        if (p.quoteIn != 0) IERC20(p.quoteToken).safeTransferFrom(msg.sender, clone, p.quoteIn);

        (address token, uint256 id, uint256 reserveHeld, uint256 quoteSpent) =
            StonkLaunchAdapter(clone).executeLaunch(p);

        emit LaunchCloned(clone, msg.sender, padAddress, id, token);

        // The ref IS the clone. No ref -> clone map exists to disagree with
        // reality, and a forged ref is caught by ERC-1167 introspection rather
        // than by a lookup an attacker could seed. The widening cast is
        // lossless by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 ref = bytes32(uint256(uint160(clone)));

        return LaunchResult({token: token, launchRef: ref, reserveHeld: reserveHeld, quoteSpent: quoteSpent});
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev MUST NOT REVERT, and this one is two hops from a venue that does.
    ///      Both hops are defended: the ref is resolved by ERC-1167
    ///      introspection (a forged ref never becomes a call), and the clone is
    ///      then read by length-checked raw staticcall, so an unreadable,
    ///      short-returning or out-of-range answer resolves to `None`.
    ///      `LaunchPhase` is decoded as a word and bounded rather than through
    ///      `abi.decode(..., (LaunchPhase))`, which REVERTS on an out-of-range
    ///      value — exactly the contract settlement depends on this not doing.
    function phase(bytes32 launchRef) external view override returns (LaunchPhase) {
        address clone = _refToClone(launchRef);
        if (clone == address(0)) return LaunchPhase.None;
        (bool ok, bytes memory ret) = clone.staticcall(abi.encodeCall(this.clonePhase, ()));
        if (!ok || ret.length < 32) return LaunchPhase.None;
        uint256 word = abi.decode(ret, (uint256));
        if (word > uint256(type(LaunchPhase).max)) return LaunchPhase.None;
        return LaunchPhase(word);
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Permissionless, because both legs are permissionless AT THE VENUE
    ///      and neither pays the caller. A keeper driving a fund's launch to
    ///      bond is a service the fund wants; gating it owner-only would add
    ///      friction and no safety. A forged ref is a silent no-op — it must
    ///      not reach the supplied address, and it must not revert a settlement
    ///      path that calls this unconditionally.
    function finalize(bytes32 launchRef) external override {
        address clone = _refToClone(launchRef);
        if (clone == address(0)) return;
        StonkLaunchAdapter(clone).cloneFinalize();
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev Routes to the clone, which pays its OWNER and nobody else. A forged
    ///      ref answers `(0, 0)` without calling the supplied address.
    ///      Typed rather than raw, unlike the Sushi adapter's venue call: the
    ///      callee here is THIS CODE, written not to revert when nothing has
    ///      accrued, so a revert would be a bug worth surfacing rather than a
    ///      venue refusing service. (`TokenizeFundStrategy._settle` wraps this
    ///      in a tolerated raw call regardless, so a settlement is never
    ///      stranded by it.)
    function collectFees(bytes32 launchRef) external override returns (uint256 quoteOut, uint256 tokenOut) {
        address clone = _refToClone(launchRef);
        if (clone == address(0)) return (0, 0);
        return StonkLaunchAdapter(clone).cloneCollectFees();
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev A pure storage read: cannot revert. Answers from the lane set this
    ///      implementation was constructed with, which no one can change.
    ///
    ///      WOOD ANSWERS FALSE, AND ALWAYS WILL. Unlike Sushi — where the venue
    ///      owner registering a WOOD/USD aggregator flips the answer with no
    ///      change here — a lane on this venue is a PAD DEPLOYMENT. There are
    ///      sixteen, none of them WOOD, and no owner action adds a lane to an
    ///      existing pad. The asymmetry between the two adapters lives here.
    ///
    ///      On a CLONE this answers `false` for everything: the lane map is
    ///      implementation storage and does not cross the proxy. Consumers ask
    ///      the certified implementation, which is the address they hold anyway.
    function quoteSupported(address quoteToken) public view override returns (bool) {
        return padOf[quoteToken] != address(0);
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev `(address(0), 0)` — this venue charges no native launch fee, so
    ///      there is nothing for the strategy to acquire and no reason for a
    ///      governor batch to carry value.
    ///
    ///      READ LIVE ANYWAY, and across EVERY configured pad. `nativeFeeSource`
    ///      takes no quote argument, so it cannot know which lane a proposal
    ///      will use; reporting the MAXIMUM over the lane set means a fee
    ///      appearing on any single pad shows up here instead of hiding behind
    ///      a lane nobody queried. Each read is a length-checked staticcall so
    ///      this cannot revert; an unreadable pad contributes zero.
    ///
    ///      STATED LIMITATION. If that maximum is ever nonzero, `launch`
    ///      REVERTS `NativeFeeUnsupported` rather than silently under-funding
    ///      the venue call. The honest report here is `(address(0), fee)` —
    ///      "the venue wants this much native, and I name no token that can pay
    ///      it" — which fails the strategy closed at `_acquireFeeToken` before
    ///      any capital moves. Revisit if the venue starts charging: the fix is
    ///      a wrapped-native lane on this adapter, like the Sushi one, and it
    ///      is a new implementation either way.
    function nativeFeeSource() external view override returns (address token, uint256 amount) {
        uint256 n = _lanePads.length;
        uint256 maxFee;
        for (uint256 i; i < n; ++i) {
            uint256 fee = _safeLaunchFee(_lanePads[i]);
            if (fee > maxFee) maxFee = fee;
        }
        return (address(0), maxFee);
    }

    /// @inheritdoc ILaunchAdapter
    /// @dev `address(0)`, AND THAT IS THE ANSWER, not a stub.
    ///
    ///      There is no single venue contract to name. This adapter fronts
    ///      SIXTEEN pads, one per lane, and which one a launch used is a
    ///      property of the launch — recoverable from the ref, never from a
    ///      nullary getter. Returning the implementation's own address would be
    ///      a lie about what the deploy ceremony vouched for (it vouches for
    ///      each pad and the lens, individually); returning the lens would name
    ///      a contract this adapter never calls.
    ///
    ///      WHAT THE ZERO DOES DOWNSTREAM, and why zero beats the lens.
    ///      `TokenizeFundStrategy._settle` reads this and, if nonzero, calls
    ///      `transferCreator(token, vault())` on it with tolerated failure.
    ///      This venue HAS no creator transfer — that is the whole reason this
    ///      adapter clones — so the call must not happen. Zero makes `_settle`
    ///      skip it and emit `SettlementLegSkipped("launchTarget")`, which is
    ///      the truthful record. The lens would also "work" (no such selector,
    ///      so the call reverts and is tolerated), but it would spend the gas
    ///      and log a FAILED transfer against a contract that has nothing to do
    ///      with creator roles. The post-settlement lane on this venue is the
    ///      clone's `forwardToVault()`, which goes permissionless once the
    ///      owning strategy settles.
    ///
    ///      Consumers wanting the pad set can read `lanes()`; the lens is at
    ///      `lens()`.
    function launchTarget() external pure override returns (address) {
        return address(0);
    }

    /// @notice The ordered lane set this implementation was constructed with.
    /// @dev The preimage of `padSetHash`: a certifier reads these, hashes
    ///      `abi.encode(quotes, pads)`, and compares. Empty on a clone — the
    ///      arrays are implementation storage.
    function lanes() external view returns (address[] memory quotes, address[] memory pads) {
        return (_laneQuotes, _lanePads);
    }

    /// @notice Whether `target` is an ERC-1167 clone of THIS implementation.
    /// @dev Exposed so the strategy, the registry tooling and a reviewer can
    ///      run the same check the ref-taking verbs run, without re-deriving
    ///      the minimal-proxy layout in three places.
    function isClone(address target) external view returns (bool) {
        return _isOurClone(target);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // clone role
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Bind a fresh clone to its owning strategy and its pad.
    /// @dev ONE-SHOT, AND IMPLEMENTATION-ONLY. Both halves matter:
    ///        - one-shot stops an owner change, which would be a creator-role
    ///          transfer this venue deliberately does not have;
    ///        - implementation-only means a clone minted by anyone ELSE (this
    ///          code is public; `Clones.clone` is one call) can NEVER be
    ///          initialized. It passes ERC-1167 introspection but has
    ///          `owner == address(0)` and `launchToken == address(0)`, so every
    ///          verb on it is a fail-closed no-op. That is the difference
    ///          between "looks like our clone" and "is one of ours".
    ///      The implementation locks itself in its constructor, so this can
    ///      never run there.
    function initialize(address owner_, address pad_, address laneQuote_) external {
        if (msg.sender != implementation) revert NotImplementation(msg.sender);
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        owner = owner_;
        pad = pad_;
        laneQuote = laneQuote_;
    }

    /// @notice Open the launch, withhold the reserve, arm the remainder, and
    ///         optionally dev-buy for the owner.
    ///
    /// @dev THREE FIELDS ARE NOT THE CALLER'S TO CHOOSE, and each is a hazard
    ///      the proposal layer cannot see:
    ///        - `token = address(0)` pins the MINT path. The BYO path would
    ///          launch a token of unknown provenance whose supply the fund's
    ///          20% reserve cap is measured against.
    ///        - `vanitySalt = bytes32(0)`. A vanity address is cosmetic, and a
    ///          caller-chosen CREATE2 salt is one more attacker-influenced
    ///          input on a path that mints.
    ///        - `eoaOnly = false`, ALWAYS, and it is not even exposed. A
    ///          contract-gated launch would brick every later verb: the clone
    ///          is a contract, so `buy` here, and every keeper-driven
    ///          `graduate`/`bond`, would revert `NotEoa`. The fund would own a
    ///          creator role it could not exercise.
    ///
    ///      ORDER IS THE CUSTODY ARGUMENT. `createLaunch` mints the whole
    ///      supply to this clone; the reserve leaves for the OWNER before
    ///      `arm` sees anything, so the withheld amount is never at risk of
    ///      being loaded onto the curve. The dev buy — when there is one — is
    ///      delivered by the pad straight to the owner, so no bought token is
    ///      ever a clone balance. The closing assert proves what is left: the
    ///      creator role, and nothing else.
    ///
    ///      `p.quoteIn` was forwarded here by the implementation before this
    ///      call, because the owner could not approve an address that did not
    ///      exist yet.
    function executeLaunch(LaunchParams calldata p)
        external
        returns (address token, uint256 id, uint256 reserveHeld, uint256 quoteSpent)
    {
        if (msg.sender != implementation) revert NotImplementation(msg.sender);
        address owner_ = owner;
        if (owner_ == address(0)) revert NotInitialized();
        if (launchToken != address(0)) revert AlreadyLaunched(launchToken);
        if (p.deadline != 0 && block.timestamp > p.deadline) revert DeadlineExpired(p.deadline, block.timestamp);
        if (p.quoteIn == 0 && p.minTokensOut != 0) revert MinOutWithoutBuy(p.minTokensOut);

        VenueData memory v = abi.decode(p.venueData, (VenueData));
        if (p.reserveAmount >= v.supply) revert ReserveExceedsSupply(p.reserveAmount, v.supply);

        IStonkSafeLaunchpadV2 padContract = IStonkSafeLaunchpadV2(pad);
        (id, token) = padContract.createLaunch(
            IStonkSafeLaunchpadV2.CreateParams({
                token: address(0),
                name: p.name,
                symbol: p.symbol,
                supply: v.supply,
                vanitySalt: bytes32(0),
                startMcapUsd8: v.startMcapUsd8,
                gradMcapUsd8: v.gradMcapUsd8,
                startTaxBps: v.startTaxBps,
                taxDecayPerMinuteBps: v.taxDecayPerMinuteBps,
                sellsEnabled: v.sellsEnabled,
                bufferSecs: v.bufferSecs,
                unsoldMode: v.unsoldMode,
                eoaOnly: false,
                openEnded: v.openEnded,
                postTaxBps: v.postTaxBps,
                bondVenue: v.bondVenue,
                maxBuyPpm: v.maxBuyPpm
            })
        );
        launchId = id;
        launchToken = token;

        uint256 minted = IERC20(token).balanceOf(address(this));
        if (minted < v.supply) revert SupplyNotDelivered(minted, v.supply);

        uint256 ownerBefore = IERC20(token).balanceOf(owner_);
        if (p.reserveAmount != 0) IERC20(token).safeTransfer(owner_, p.reserveAmount);

        uint256 armAmount = v.supply - p.reserveAmount;
        IERC20(token).forceApprove(address(padContract), armAmount);
        padContract.arm(id, armAmount);
        IERC20(token).forceApprove(address(padContract), 0);

        if (p.quoteIn != 0) {
            IERC20(p.quoteToken).forceApprove(address(padContract), p.quoteIn);
            // Delivered to the OWNER, not here: a curve dev buy that lands
            // straight on the strategy. A `StalePrice` on a stock lane
            // propagates from here UNCHANGED — no retry, no bypass.
            padContract.buy(id, p.quoteIn, p.minTokensOut, bytes32(0), owner_);
            IERC20(p.quoteToken).forceApprove(address(padContract), 0);
        }

        // Reserve AND dev buy, measured where the invariant says they must be.
        reserveHeld = IERC20(token).balanceOf(owner_) - ownerBefore;

        // Unspent quote belongs to the owner it was pulled from. Normally zero:
        // the pad consumes the buy in full.
        uint256 leftover = IERC20(p.quoteToken).balanceOf(address(this));
        if (leftover != 0) IERC20(p.quoteToken).safeTransfer(owner_, leftover);
        quoteSpent = leftover >= p.quoteIn ? 0 : p.quoteIn - leftover;

        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) revert DustRemains(token, dust);
    }

    /// @notice This clone's lifecycle position.
    ///
    /// @dev MUST NOT REVERT: the implementation's `phase` routes here, and
    ///      settlement branches on the answer. Both venue reads are
    ///      length-checked raw staticcalls; an unreadable pad answers `None`.
    ///
    ///      THE MAPPING:
    ///        `aborted`                  -> `Failed`  (terminal, supply returned)
    ///        `bonded`                   -> `Live`    (the locked LP exists)
    ///        `graduated && !bonded`     -> `Closing` (curve done, LP pending)
    ///        `!armed`                   -> `Curve`   (created, not yet loaded)
    ///        `armed && openEnded`       -> `Curve`   (no closing deadline at all)
    ///        `armed && now <= deadline` -> `Curve`
    ///        otherwise                  -> `Failed`  <-- PROVISIONAL
    ///
    ///      THE PROVISIONAL BRANCH IS THE LAST ONE, and only that one: a curve
    ///      whose window closed without graduating. It is reported `Failed`
    ///      because the spec fixes that mapping pending verification, and
    ///      because `Failed` is the conservative direction — it sends
    ///      settlement down the deliverable-maximum path instead of waiting on
    ///      a graduation that may never come.
    ///
    ///      WHAT TASK 0.1 MUST CONFIRM (design Open Question 3): on a 4663
    ///      fork, run a launch through a closed window below `gradMcapUsd8`
    ///      WITH BUYS PRESENT and record whether `graduate()` still succeeds
    ///      inside `bufferSecs`, and whether the creator can recover the armed
    ///      supply or the realized quote (`abort` is barred once `buyCount != 0`).
    ///      If a post-deadline graduation is possible, this branch should split
    ///      into `Closing` while that window is open and `Failed` after it —
    ///      which needs a graduatability predicate the venue does not currently
    ///      expose, so it would arrive with a lens read or a pad view. Until
    ///      then: `cloneFinalize()` is safe to call in this state and will flip
    ///      the answer to `Closing`/`Live` if the venue does permit it, so the
    ///      provisional reading is self-correcting rather than sticky.
    function clonePhase() public view returns (LaunchPhase) {
        address padAddress = pad;
        if (padAddress == address(0) || launchToken == address(0)) return LaunchPhase.None;

        (bool ok, LaunchFlags memory f) = _readLaunchFlags(padAddress, launchId);
        if (!ok) return LaunchPhase.None;

        if (f.aborted) return LaunchPhase.Failed;
        if (f.bonded) return LaunchPhase.Live;
        if (f.graduated) return LaunchPhase.Closing;
        if (!f.armed) return LaunchPhase.Curve;

        (bool modesOk, bool openEnded) = _readOpenEnded(padAddress, launchId);
        if (!modesOk) return LaunchPhase.None;
        if (openEnded) return LaunchPhase.Curve;
        if (block.timestamp <= f.deadline) return LaunchPhase.Curve;
        return LaunchPhase.Failed;
    }

    /// @notice Drive this launch's lifecycle as far as the venue permits.
    ///
    /// @dev PERMISSIONLESS. `graduate` and `bond` are permissionless at the pad
    ///      itself and neither pays the caller, so gating them owner-only would
    ///      add friction and no safety — a keeper driving a fund's launch to
    ///      bond is a service the fund wants.
    ///
    ///      VENUE REVERTS ARE TOLERATED HERE, and only here. `NotGraduatable`
    ///      on a curve that has not reached its graduation cap is the NORMAL
    ///      case, not an error, and `ILaunchAdapter` says this is safe to call
    ///      in any phase — a settlement path calling it unconditionally must
    ///      not be stranded by it. Tolerance costs nothing in safety because
    ///      neither leg moves value to anyone: a refused leg reverted its own
    ///      state and is retryable by anyone, forever. This is NOT the
    ///      stale-oracle scenario, which concerns a pad TRADE: the only trade
    ///      this adapter makes is the dev buy inside `executeLaunch`, and there
    ///      `StalePrice` propagates unchanged.
    ///
    ///      Raw `call`, not `try/catch`: neither leg returns anything, so there
    ///      is nothing to decode on the success path either.
    function cloneFinalize() external {
        address padAddress = pad;
        if (padAddress == address(0) || launchToken == address(0)) return;
        uint256 id = launchId;

        (bool ok, LaunchFlags memory f) = _readLaunchFlags(padAddress, id);
        if (!ok || f.aborted) return;

        if (!f.graduated) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool graduated,) = padAddress.call(abi.encodeCall(IStonkSafeLaunchpadV2.graduate, (id)));
            if (graduated) f.graduated = true;
            else emit VenueLegSkipped("graduate");
        }
        if (f.graduated && !f.bonded) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool bonded,) = padAddress.call(abi.encodeCall(IStonkSafeLaunchpadV2.bond, (id)));
            if (!bonded) emit VenueLegSkipped("bond");
        }
    }

    /// @notice Sweep accrued creator fees to the OWNING STRATEGY.
    ///
    /// @dev PERMISSIONLESS, and it pays the owner whoever calls — the payee is
    ///      fixed in storage, so there is no version of this that pays a keeper.
    ///
    ///      WHY THE FORWARD IS NECESSARY, unlike on Sushi. The venue's
    ///      `flushCreatorQuote` pays THE CREATOR, and the creator is this
    ///      CLONE, not the strategy. Sushi's `distributeFees` pays a creator
    ///      that IS the strategy, so its adapter only has to measure. Here the
    ///      value physically lands on the clone and has to be moved on, which
    ///      is why the deltas below are measured on the OWNER: what actually
    ///      arrived, not what the venue said it paid.
    ///
    ///      `(0, 0)` RATHER THAN A REVERT when nothing accrued: the venue call
    ///      is tolerated (a paused pad, a launch with no trades) and the
    ///      forwards are skipped entirely on a zero balance, so the
    ///      nothing-accrued path touches no token at all and cannot revert. A
    ///      failed venue call reverted its own state, so nothing moved and
    ///      `(0, 0)` is the honest report rather than a swallowed error.
    function cloneCollectFees() external returns (uint256 quoteOut, uint256 tokenOut) {
        address owner_ = owner;
        address padAddress = pad;
        address token = launchToken;
        if (owner_ == address(0) || padAddress == address(0) || token == address(0)) return (0, 0);

        address quoteAsset = laneQuote;
        uint256 quoteBefore = _balanceOf(quoteAsset, owner_);
        uint256 tokenBefore = _balanceOf(token, owner_);

        // solhint-disable-next-line avoid-low-level-calls
        (bool flushed,) = padAddress.call(abi.encodeCall(IStonkSafeLaunchpadV2.flushCreatorQuote, (launchId)));
        if (!flushed) emit VenueLegSkipped("flushCreatorQuote");

        _forward(quoteAsset, owner_);
        if (token != quoteAsset) _forward(token, owner_);

        uint256 quoteAfter = _balanceOf(quoteAsset, owner_);
        uint256 tokenAfter = _balanceOf(token, owner_);
        quoteOut = quoteAfter > quoteBefore ? quoteAfter - quoteBefore : 0;
        tokenOut = tokenAfter > tokenBefore ? tokenAfter - tokenBefore : 0;
        emit FeesCollected(owner_, quoteOut, tokenOut);
    }

    /// @notice Cancel the launch and take the armed supply back.
    ///
    /// @dev OWNER-ONLY, and the one clone verb that is. The venue allows
    ///      `abort` only while `buyCount == 0`, which makes it a RECOVERY
    ///      LEVER whose whole value is that nobody else can pull it: a
    ///      permissionless abort would let any passer-by cancel a fund's launch
    ///      in the seconds before its first trade. Value routing is not the
    ///      question here — nothing lands on a caller either way — so the
    ///      "gate by where value goes" rule that makes `finalize` and
    ///      `collectFees` permissionless does not reach this one.
    ///
    ///      Typed, so a venue refusal (`buyCount != 0`) SURFACES. The owner is
    ///      asking a direct question and deserves the venue's answer, not a
    ///      silent no-op that leaves them believing the launch was cancelled.
    function abort() external {
        address owner_ = owner;
        if (owner_ == address(0)) revert NotInitialized();
        if (msg.sender != owner_) revert NotOwner(msg.sender, owner_);
        address token = launchToken;
        if (token == address(0)) revert NotLaunched();

        IStonkSafeLaunchpadV2(pad).abort(launchId);

        uint256 returned = IERC20(token).balanceOf(address(this));
        if (returned != 0) IERC20(token).safeTransfer(owner_, returned);
        emit LaunchAborted(owner_, returned);
    }

    /// @notice Flush creator fees and send everything this clone holds to the
    ///         owning strategy's VAULT.
    ///
    /// @dev THE POST-SETTLEMENT FEE LANE, and it exists because of a gap
    ///      nothing else covers: this clone is the venue's creator, it is NOT
    ///      the strategy, and what it holds is therefore invisible to the
    ///      vault's residue machinery. Value that accrues here after the fund
    ///      has settled would otherwise sit unreachable forever.
    ///
    ///      IT GOES TO THE VAULT, NOT THROUGH THE STRATEGY, and that is
    ///      deliberate (design Decision 4). Post-settlement value landing in
    ///      STRATEGY custody is a lever: permissionless `collectResidue`
    ///      re-marks the strategy and re-stamps a fresh 7-day vault deposit
    ///      lock on every arrival. Delivering vault-direct skips that entirely.
    ///
    ///      OWNER-ONLY BEFORE SETTLEMENT, PERMISSIONLESS AFTER. Before the fund
    ///      settles, fees are the strategy's to account for and pulling them
    ///      past it would break its books; after, there are no books left to
    ///      break and a keeper doing the sweep is a service. The owner's state
    ///      is read by LENGTH-CHECKED RAW STATICCALL and an unreadable answer
    ///      means NOT SETTLED — fail closed to owner-only. Adversary: an owner
    ///      contract that reverts, self-destructs or returns short from
    ///      `state()` would, under a typed read, either brick this verb or
    ///      (worse, if the failure were read as "settled") open it to anyone
    ///      mid-fund.
    ///
    ///      `vault()` is read the same way but is REQUIRED: an unresolvable
    ///      vault reverts rather than picking a fallback destination.
    function forwardToVault() external {
        address owner_ = owner;
        if (owner_ == address(0)) revert NotInitialized();
        if (msg.sender != owner_ && !_ownerSettled(owner_)) revert NotOwner(msg.sender, owner_);

        address vaultAddress = _readVault(owner_);
        if (vaultAddress == address(0)) revert VaultUnresolved(owner_);

        address padAddress = pad;
        address token = launchToken;
        if (padAddress != address(0) && token != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool flushed,) = padAddress.call(abi.encodeCall(IStonkSafeLaunchpadV2.flushCreatorQuote, (launchId)));
            if (!flushed) emit VenueLegSkipped("flushCreatorQuote");
        }

        address quoteAsset = laneQuote;
        uint256 quoteOut = _forward(quoteAsset, vaultAddress);
        uint256 tokenOut = (token != address(0) && token != quoteAsset) ? _forward(token, vaultAddress) : 0;
        emit ForwardedToVault(vaultAddress, quoteOut, tokenOut);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // internals
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Resolve a ref to a clone THIS implementation minted, or to
    ///      `address(0)`. Never calls the supplied address: a dirty-high-bit
    ///      ref, a non-clone, or a clone of some other implementation all
    ///      resolve to zero on `EXTCODECOPY` alone.
    function _refToClone(bytes32 launchRef) private view returns (address) {
        uint256 word = uint256(launchRef);
        if (word >> 160 != 0) return address(0);
        // Casting to `uint160` is safe: the guard above rejects any word with
        // set bits above 160, so nothing can truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        address target = address(uint160(word));
        return _isOurClone(target) ? target : address(0);
    }

    /// @dev ERC-1167 TARGET INTROSPECTION — the whole reason this adapter needs
    ///      no ref -> clone map. A minimal proxy's runtime is exactly 45 bytes
    ///      with the implementation address sitting at bytes 10..29:
    ///
    ///        363d3d373d3d3d363d73 <implementation> 5af43d82803e903d91602b57fd5bf3
    ///        \___ 10 bytes ____/  \_ 20 bytes _/  \____ 15 bytes ___________/
    ///
    ///      All three parts are checked. Matching only the length, or only the
    ///      embedded address, would accept a hand-written 45-byte contract that
    ///      merely CONTAINS our address; matching the prefix and suffix pins the
    ///      delegatecall semantics, and matching the middle pins WHOSE code runs.
    ///      Together they mean the target runs this exact contract, so trusting
    ///      its answers is trusting our own code.
    ///
    ///      The registry consequence the spec names: the gate binds the
    ///      IMPLEMENTATION, ephemeral clones need no per-clone registry writes,
    ///      and demoting the implementation demotes every clone at once.
    function _isOurClone(address target) private view returns (bool) {
        if (target == address(0) || target.code.length != _CLONE_RUNTIME_LENGTH) return false;
        bytes memory runtime = target.code;

        bytes32 head;
        bytes32 tail;
        address embedded;
        assembly ("memory-safe") {
            // bytes 0..31 — carries the 10-byte prefix.
            head := mload(add(runtime, 0x20))
            // bytes 13..44 — its low 15 bytes are the suffix.
            tail := mload(add(runtime, 0x2d))
            // bytes 10..29 — the embedded implementation address.
            embedded := shr(96, mload(add(runtime, 0x2a)))
        }
        // Narrowing to the leading 10 bytes IS the prefix extraction; the
        // bytes discarded are the address and suffix checked on their own.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (bytes10(head) != _CLONE_PREFIX) return false;
        // Narrowing to the low 120 bits is the suffix extraction itself, not a
        // lossy cast: the discarded high bytes are the address just checked.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint120(uint256(tail)) != _CLONE_SUFFIX) return false;
        return embedded == implementation;
    }

    /// @dev Length-checked raw read of `getLaunch(id)`, returning only the five
    ///      fields `clonePhase` needs. `Launch` is a fully static struct, so the
    ///      payload is exactly 22 in-place words: `deadline` at word 10,
    ///      `armed`/`graduated`/`bonded`/`aborted` at words 13..16. A revert, a
    ///      codeless pad, or a short return all answer `ok = false`.
    function _readLaunchFlags(address padAddress, uint256 id) private view returns (bool ok, LaunchFlags memory f) {
        if (padAddress.code.length == 0) return (false, f);
        (bool called, bytes memory ret) = padAddress.staticcall(abi.encodeCall(IStonkSafeLaunchpadV2.getLaunch, (id)));
        if (!called || ret.length < 22 * 32) return (false, f);

        uint256 deadlineWord;
        uint256 armedWord;
        uint256 graduatedWord;
        uint256 bondedWord;
        uint256 abortedWord;
        assembly ("memory-safe") {
            let base := add(ret, 0x20)
            deadlineWord := mload(add(base, mul(10, 0x20)))
            armedWord := mload(add(base, mul(13, 0x20)))
            graduatedWord := mload(add(base, mul(14, 0x20)))
            bondedWord := mload(add(base, mul(15, 0x20)))
            abortedWord := mload(add(base, mul(16, 0x20)))
        }
        // A `uint64` field arrives zero-padded in its word; anything above 64
        // bits means the payload is not the struct we expect, so fail closed
        // rather than truncate to a deadline that never expires.
        if (deadlineWord >> 64 != 0) return (false, f);
        // forge-lint: disable-next-line(unsafe-typecast)
        f.deadline = uint64(deadlineWord);
        f.armed = armedWord != 0;
        f.graduated = graduatedWord != 0;
        f.bonded = bondedWord != 0;
        f.aborted = abortedWord != 0;
        return (true, f);
    }

    /// @dev Same treatment for `modesOf(id)`: a static 6-word struct with
    ///      `openEnded` at word 2. Read separately because `Launch` does not
    ///      carry it, and without it `deadline` cannot distinguish a closed
    ///      window from a curve that never had one.
    function _readOpenEnded(address padAddress, uint256 id) private view returns (bool ok, bool openEnded) {
        if (padAddress.code.length == 0) return (false, false);
        (bool called, bytes memory ret) = padAddress.staticcall(abi.encodeCall(IStonkSafeLaunchpadV2.modesOf, (id)));
        if (!called || ret.length < 6 * 32) return (false, false);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, add(0x20, mul(2, 0x20))))
        }
        return (true, word != 0);
    }

    /// @dev Safe-read of one pad's launch fee for `nativeFeeSource`;
    ///      unreadable -> 0, so a single unreachable pad cannot revert a
    ///      planning read.
    function _safeLaunchFee(address padAddress) private view returns (uint256) {
        if (padAddress.code.length == 0) return 0;
        (bool ok, bytes memory ret) = padAddress.staticcall(abi.encodeCall(IStonkSafeLaunchpadV2.launchFeeWei, ()));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Non-reverting balance read, so `cloneCollectFees` cannot be turned
    ///      into a revert by a token that has since become unreadable.
    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0) || token.code.length == 0) return 0;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (who)));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Move this clone's whole balance of `token` to `to`, or do nothing.
    ///      The zero-balance short-circuit is what makes the nothing-accrued
    ///      path of `cloneCollectFees` touch no token at all.
    function _forward(address token, address to) private returns (uint256 moved) {
        if (token == address(0) || token.code.length == 0) return 0;
        moved = IERC20(token).balanceOf(address(this));
        if (moved != 0) IERC20(token).safeTransfer(to, moved);
    }

    /// @dev `state() == Settled`, read defensively. UNREADABLE MEANS NOT
    ///      SETTLED: this gate only ever WIDENS access, so every failure mode
    ///      must resolve to the narrow answer.
    function _ownerSettled(address owner_) private view returns (bool) {
        if (owner_.code.length == 0) return false;
        (bool ok, bytes memory ret) = owner_.staticcall(abi.encodeCall(IOwningStrategy.state, ()));
        if (!ok || ret.length < 32) return false;
        return abi.decode(ret, (uint256)) == _STATE_SETTLED;
    }

    /// @dev `vault()`, read defensively. Unreadable or dirty answers zero and
    ///      the caller reverts — a destination is not something to guess at.
    function _readVault(address owner_) private view returns (address) {
        if (owner_.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = owner_.staticcall(abi.encodeCall(IOwningStrategy.vault, ()));
        if (!ok || ret.length < 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word >> 160 != 0) return address(0);
        // Safe: the guard above rejects any word with set bits above 160.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }
}
