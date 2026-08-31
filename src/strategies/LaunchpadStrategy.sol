// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IStrategyDelivery} from "../interfaces/IStrategyDelivery.sol";
import {ILaunchAdapter} from "../interfaces/ILaunchAdapter.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {ISyndicateGovernor} from "../interfaces/ISyndicateGovernor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice The hops walked to resolve the governance-owned adapter allowlist
///         from this strategy: `vault()` -> `governor()` -> `tierRegistry()` ->
///         `isAdapterAllowed(adapter)`.
/// @dev    Declared locally rather than imported, matching
///         `PortfolioStrategy.ITierBindingPath` and
///         `MorphoSupplyStrategy.ITierBindingPath`: every hop is a
///         length-checked raw staticcall, so the strategy takes on no type
///         dependency and no hop can revert `_initialize` undecodably. This
///         exists to generate selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
}

/// @notice The vault's ERC-5805 surface, which IS the claim's snapshot
///         machinery. `SyndicateVault` is `ERC20VotesUpgradeable` with
///         `clock() == block.timestamp` (`SyndicateVault.sol:1494`) and
///         auto-self-delegates every undelegated recipient, so past votes equal
///         past balance for anyone who never delegated.
/// @dev    Declared locally for selector generation, same reason as
///         `ITierBindingPath`. `clock()` is read through a LENGTH-CHECKED RAW
///         STATICCALL that REVERTS when unreadable (see `_vaultClock`); the two
///         vote reads are typed calls, because a vault that cannot answer them
///         must fail the claim closed rather than silently pay zero.
interface IVaultVotes {
    function clock() external view returns (uint48);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
}

/**
 * @title LaunchpadStrategy
 * @notice "IPO" a syndicate: launch a fund token on an allowlisted launch
 *         venue with vault capital, retain a reserve, and hand that reserve to
 *         the fund's own share holders pro-rata by a snapshot taken at the
 *         instant capital left the vault.
 *
 *   Execute: pull the vault-asset budget -> (optionally) swap into the launch
 *            quote -> acquire the venue's native launch fee in the token the
 *            adapter NAMES -> `ILaunchAdapter.launch` -> verify custody, verify
 *            the declared supply, freeze the snapshot, clamp the claim window,
 *            return the unspent remainder.
 *   Claim:   `claim()` / `claimFor(holder)` while `Executed` and at or before
 *            the clamped `windowEnd`. Dividend-in-kind: shares are NOT burned.
 *   Settle:  convert leftover quote to the vault asset when it can be done
 *            honestly, push everything vault-asset-denominated. NEVER sells the
 *            fund token into its own launch pool — that price is
 *            attacker-movable inside the settlement transaction, which is the
 *            finding-#3 shape.
 *   Sweep:   `onlyVault`, `Settled`-only, BALANCE-ONLY. Pushes the vault asset
 *            and warehouses the remaining fund tokens / leftover quote at the
 *            vault as UNPRICED inventory.
 *
 *   THE CREATOR FEE STREAM IS NOT THIS CONTRACT'S BUSINESS. `_execute` names
 *   the FUND'S VAULT as `LaunchParams.feeRecipient`, so the venue pays fees
 *   there from the first block and they never enter clone custody. There is no
 *   fee entry point here, no fee mode, and no settlement-time handoff: the
 *   adapter's own `collectFees(launchRef)` is permissionless and pays the vault
 *   directly, so anyone may push accrued fees without touching this strategy at
 *   all, and a later proposal decides what the vault does with them. The
 *   snapshot below is therefore doing exactly one job — the pro-rata claim on
 *   the launch RESERVE — and `launchRef` is public precisely so a keeper can
 *   drive that adapter call.
 *
 *   THE DEFINING CONSTRAINT: this template deliberately acquires an asset the
 *   protocol must refuse to price. Everything in the delivery views below
 *   exists to keep that asset out of the vault's NAV until it is either claimed
 *   or warehoused unpriced.
 */
contract LaunchpadStrategy is BaseStrategy {
    using SafeERC20 for IERC20;

    // ── Template constants ──

    /// @notice Hard ceiling on the fraction of the launch supply a proposal may
    ///         hold back as the claim reserve: 20%.
    /// @dev    NON-GAMEABLE ONLY BECAUSE `_execute` VERIFIES THE DECLARED
    ///         SUPPLY. The cap is enforced at init against `launchSupply`, a
    ///         PROPOSER-DECLARED number; without the execute-time
    ///         `totalSupply() == launchSupply` check a proposer would declare
    ///         an inflated supply, lift the cap arbitrarily, and hold back the
    ///         whole float. See `SupplyMismatch`.
    uint256 public constant MAX_RESERVE_BPS = 2_000;

    /// @notice The longest claim window a proposal may configure: 14 days.
    /// @dev    THIS IS THE CONTAINMENT BOUND FOR A CORRUPT GOVERNOR DECODE.
    ///         The window is normally clamped at execute against the proposal's
    ///         own `strategyDuration`, and `settle()`'s backstop is built from
    ///         the SAME `getProposal(pid)` struct decode — which
    ///         `ISyndicateGovernor` itself documents as upgrade-fragile. A
    ///         governor that reorders that struct therefore poisons clamp and
    ///         backstop identically, and the only bound left standing is this
    ///         one: `windowEnd <= executedAt + MAX_CLAIM_WINDOW`, capping a
    ///         settlement wedge at 14 days rather than forever.
    ///
    ///         14 days is chosen as the largest window that is still strictly
    ///         shorter than the vault's own residue horizon and than a typical
    ///         30-day `strategyDuration`, so the ordinary case never truncates
    ///         while the pathological case stays survivable: a wedge of at most
    ///         14 days on `openProposalCount() != 0` is recoverable by waiting,
    ///         which is exactly what "no permanent DoS" requires.
    uint256 public constant MAX_CLAIM_WINDOW = 14 days;

    /// @notice Slack left between the end of the claim window and the end of
    ///         the proposal, so settlement is always reachable inside the
    ///         proposal's own clock: 5 minutes.
    /// @dev    MUST BE BELOW THE GOVERNOR'S `ABSOLUTE_MIN_STRATEGY_DURATION`
    ///         (`GovernorParameters.sol:46`, 1 hour) OR NO PROPOSAL IS
    ///         EXECUTABLE AT ALL. `_execute` requires
    ///         `strategyDuration > CLAIM_SETTLE_BUFFER`; a buffer at or above
    ///         the governor's floor would reject every proposal that used that
    ///         floor, i.e. it would brick the template rather than protect it.
    ///         5 minutes is 1/12th of that floor — comfortably more than one
    ///         settlement transaction needs, comfortably less than the shortest
    ///         proposal the governor will accept.
    uint256 public constant CLAIM_SETTLE_BUFFER = 5 minutes;

    /// @notice Ceiling on the settle-time slippage tolerance, mirroring
    ///         `ConcentratedLiquidityStrategy.MAX_SLIPPAGE_BPS`.
    /// @dev    The floor of `!= 0` matters as much as the ceiling: a zero
    ///         tolerance would make the settle-time quote conversion revert on
    ///         any real venue, and this template answers that by LEAVING THE
    ///         QUOTE AS RESIDUE rather than reverting — so a zero tolerance
    ///         would silently convert every settlement into a residue
    ///         settlement.
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    uint256 private constant BPS = 10_000;

    // ── Errors ──

    /// @notice The `vault() -> governor() -> tierRegistry()` walk yielded no
    ///         registry at `_initialize`.
    /// @dev    INIT IS THE ONE PLACE THIS FAILS CLOSED, matching
    ///         `MorphoSupplyStrategy` and `PortfolioStrategy`. Adversary: a
    ///         governor with no registry wired makes the whole allowlist gate a
    ///         no-op, and this template hands a proposer-chosen contract both
    ///         the vault's budget and an unbounded approval one hop outside the
    ///         vault's batch gate. Refusing to BIND costs a re-proposal;
    ///         refusing at execute would cost deployed capital, which is why
    ///         `_execute` re-certifies but `_settle` never does.
    error TierRegistryUnresolved();

    /// @notice `launchAdapter` is not allowlisted in the `TierRegistry` the
    ///         vault's own governor gates batch approvals against.
    /// @dev    Adversary: an un-vouched launch adapter receives the entire
    ///         launch quote by approval and self-attests every answer this
    ///         strategy checks (`quoteSupported`, `reserveHeld`, the launched
    ///         token itself).
    error LaunchAdapterNotAllowed(address adapter, address registry);

    /// @notice `swapAdapter` is not allowlisted in the same registry.
    /// @dev    Adversary: the quote leg is where the vault asset actually
    ///         leaves. An un-vouched swap adapter takes the whole budget under
    ///         a proposer-chosen `minQuoteOut`.
    error SwapAdapterNotAllowed(address adapter, address registry);

    /// @notice The launch adapter reports it cannot pair a launch against the
    ///         configured quote token.
    /// @dev    Fails at INIT, before the clone can be attached to a proposal —
    ///         a venue-lane mismatch (WOOD on a Stonk lane, an unregistered
    ///         feed on Sushi) is a configuration error, not an execution
    ///         hazard, and finding it at execute would waste a whole vote.
    error QuoteNotSupported(address quoteToken);

    /// @notice `reserveAmount` is zero.
    /// @dev    Adversary: a zero reserve deploys vault capital on a launch
    ///         whose holders can claim nothing — all of the risk, none of the
    ///         product. The claim IS the reason this template may spend the
    ///         float, so a launch with no claim pot is not this template.
    error ZeroReserve();

    /// @notice `reserveAmount` exceeds `launchSupply * MAX_RESERVE_BPS / 10_000`.
    /// @dev    Adversary: a proposer holding back most of the float turns a
    ///         "fund IPO" into a treasury transfer to whoever the snapshot
    ///         favours, and leaves the public market with a supply overhang the
    ///         vault cannot price.
    error ReserveTooLarge(uint256 reserveAmount, uint256 maxReserve);

    /// @notice `claimWindow` is zero or above `MAX_CLAIM_WINDOW`.
    /// @dev    Zero is an empty claim window (capital deployed, claim
    ///         impossible); above the ceiling is the settlement-wedge surface
    ///         `MAX_CLAIM_WINDOW` exists to contain.
    error InvalidClaimWindow(uint256 claimWindow, uint256 maxWindow);

    /// @notice `settleSlippageBps` is zero or above `MAX_SLIPPAGE_BPS`.
    error InvalidSlippage(uint256 slippageBps);

    /// @notice `assetIn` is zero — there is no budget to deploy.
    error InvalidAmount();

    /// @notice `updateParams` was called outside `Pending`.
    /// @dev    A DELIBERATE REVERSAL OF `BaseStrategy.updateParams`, which
    ///         requires `Executed`. Everything tunable on this template is an
    ///         input to the ONE irreversible act it performs — the launch — so
    ///         "between execute and settle" is precisely when tuning is
    ///         meaningless and, for `minTokensOut`, actively misleading to
    ///         voters. The window that matters here is the public,
    ///         pre-execution one where voters can still react.
    error NotPending();

    /// @notice `updateParams` tried to loosen a bound instead of tightening it.
    /// @dev    THE STATED MEV MITIGATION. `minTokensOut` is visible to voters
    ///         before they vote and may only ratchet TOWARD depositors; a
    ///         proposer who could lower it after approval would have been
    ///         granted a sandwich budget by the vote itself.
    error NotTightening();

    /// @notice The adapter returned `reserveHeld < reserveAmount`, or the
    ///         strategy does not actually hold the reserve.
    /// @dev    BOTH LEGS ARE CHECKED because one is the adapter's own claim and
    ///         the other is the chain's. `ILaunchAdapter`'s custody invariant is
    ///         normative but self-reported; `balanceOf(address(this))` is not.
    error ReserveNotDelivered(uint256 reserveHeld, uint256 balance, uint256 required);

    /// @notice The launched token's real `totalSupply()` differs from the
    ///         `launchSupply` the proposer declared at init.
    /// @dev    THIS IS WHAT MAKES `MAX_RESERVE_BPS` MEAN ANYTHING. The 20% cap
    ///         is enforced at init against a number the proposer typed. Without
    ///         this check the proposer declares `launchSupply = 100x` the truth,
    ///         passes the cap trivially, and holds back the entire float while
    ///         the config reads as a compliant 20% reserve. Checked at execute
    ///         because that is the first moment the token exists.
    error SupplyMismatch(uint256 actualSupply, uint256 declaredSupply);

    /// @notice The vault's `clock()` could not be read.
    /// @dev    NO FALLBACK TO `block.timestamp`. The snapshot and every claim
    ///         are denominated in the VAULT's clock; substituting this chain's
    ///         clock for a vault whose clock is block-numbered (or simply
    ///         absent) would silently mis-key every `getPastVotes` read. A
    ///         snapshot that cannot be taken correctly must not be taken at all.
    error VaultClockUnreadable();

    /// @notice The proposal's `strategyDuration` is at or below
    ///         `CLAIM_SETTLE_BUFFER`.
    /// @dev    REVERTS RATHER THAN SATURATING, and that is the whole point. A
    ///         saturating clamp would floor `windowEnd` at `executedAt` — an
    ///         EMPTY claim window — and deploy vault capital on a launch whose
    ///         entire purpose can never happen. Reverting strands nothing: the
    ///         proposal simply never executes and expires at `executeBy`.
    error StrategyDurationTooShort(uint256 strategyDuration, uint256 buffer);

    /// @notice A claim arrived outside `Executed`.
    error NotClaimable();

    /// @notice A claim arrived after `windowEnd`.
    /// @dev    The unclaimed remainder is settlement inventory, warehoused
    ///         unpriced at the vault — never redistributed to the holders who
    ///         did claim, which would make the last claimant's share depend on
    ///         when everyone else showed up.
    error ClaimWindowClosed(uint256 nowTs, uint256 windowEnd);

    /// @notice A claim landed at `clock() <= snap`, i.e. in the execute block.
    /// @dev    THE TEMPLATE'S OWN ERROR, DELIBERATELY NOT OZ'S. `getPastVotes`
    ///         reverts `ERC5805FutureLookup` for `timepoint >= clock()` (`>=`,
    ///         not `>`), so a claim in the execute block would otherwise bubble
    ///         an OZ error from inside the vault — indistinguishable, to an
    ///         integrator, from the vault being broken. It is not broken; the
    ///         claim is simply too early.
    error SnapshotNotFinal(uint256 vaultClock, uint256 snapshot);

    /// @notice This holder already claimed.
    error AlreadyClaimed(address holder);

    /// @notice The holder's snapshot weight rounds to zero of the reserve.
    /// @dev    Covers both "acquired shares after `snap`" and "held a dust
    ///         balance that floors to zero" — a zero transfer would still burn
    ///         the one-shot claim flag, so it reverts instead.
    error ZeroEntitlement(address holder);

    /// @notice Defensive: the running claim total would exceed the recorded
    ///         reserve.
    /// @dev    UNREACHABLE BY THE MATH — every share is floor-divided out of the
    ///         same `getPastTotalSupply(snap)` denominator, so the sum is at
    ///         most the reserve. Kept because it is the invariant this whole
    ///         accounting exists to hold, and a silent breach would pay one
    ///         claimant out of another's pot.
    error ClaimExceedsReserve(uint256 wouldBe, uint256 reserve);

    /// @notice `settle()` came due while the claim window is still open and the
    ///         governor's anyone-settle predicate has not yet opened.
    /// @dev    THE ONLY GATE `_settle` HAS, and it is a DISJUNCTION on purpose:
    ///         `block.timestamp > windowEnd` OR `block.timestamp >=
    ///         anyoneSettleAt`. A window that could outlast the proposal would
    ///         keep `settle()` reverting forever, pinning `openProposalCount()
    ///         != 0` — the UNBOUNDED branch of `depositsLocked()` — with no
    ///         permissionless exit (`settleProposal` bubbles the strategy
    ///         revert; `unstick` and `emergencySettleWithCalls` are both
    ///         owner-gated). Deposits AND redemptions would stay locked
    ///         vault-wide, permanently.
    error ClaimWindowStillOpen(uint256 nowTs, uint256 windowEnd, uint256 anyoneSettleAt);

    /// @notice `sweep()` before settlement.
    error NotSettled();

    /// @notice The strategy could not acquire the venue's native launch fee in
    ///         the token `nativeFeeSource()` names.
    /// @dev    Read LIVE rather than pinned at init (the venue owner can
    ///         reprice between propose and execute), and acquired by swapping
    ///         the launch quote — never by assuming the quote IS the wrapped
    ///         native, which is exactly the assumption `ILaunchAdapter` was
    ///         shaped to remove.
    error FeeAcquisitionFailed(address feeToken, uint256 required, uint256 held);

    /// @notice The asset -> quote swap returned less than `minQuoteOut`, or the
    ///         adapter delivered nothing.
    error QuoteAcquisitionFailed(uint256 received, uint256 minQuoteOut);

    // ── Events ──

    /// @notice The launch happened; the snapshot and the claim window are now
    ///         immutable.
    event FundLaunched(
        address indexed token,
        bytes32 indexed launchRef,
        uint256 reserve,
        uint256 snapshot,
        uint256 windowEnd,
        uint256 anyoneSettleAt
    );

    /// @notice `holder` took their pro-rata slice of the reserve.
    event ReserveClaimed(address indexed holder, uint256 amount, uint256 totalClaimed);

    /// @notice Settlement finished. `assetDelivered` is what reached the vault
    ///         in vault-asset units; the other two are what stayed behind as
    ///         residue.
    event FundSettled(uint256 assetDelivered, uint256 tokenResidue, uint256 quoteResidue);

    /// @notice A settle-time leg that is allowed to fail did fail. Loud on
    ///         purpose: settlement completing is not the same as settlement
    ///         being complete.
    event SettlementLegSkipped(bytes32 indexed leg);

    /// @notice A `sweep()` moved balances to the vault.
    event ResidueSwept(uint256 assetAmount, uint256 tokenAmount, uint256 quoteAmount);

    /// @notice The unvalued-residue predicate was observed false after
    ///         settlement and is now permanently false.
    event UnvaluedResidueLatched();

    // ── Init params ──

    /// @notice One struct, decoded whole — the `ConcentratedLiquidityStrategy`
    ///         precedent. A tuple this wide is unreadable at the call site and
    ///         silently mis-orderable; a struct is neither.
    ///
    /// @dev    THERE IS DELIBERATELY NO `feeRecipient` MEMBER, even though
    ///         `ILaunchAdapter.LaunchParams` has one. `_execute` fills it with
    ///         `vault()` and with nothing else. Accepting it as proposer input
    ///         would let a proposer point the FUND'S creator fee stream at an
    ///         address that is not the fund — permanently, since the venue
    ///         binds the payee at launch and this template offers no way to
    ///         re-point it. The fee destination is not a parameter of the
    ///         launch; it is an identity, and the only identity that can be
    ///         right is the vault whose capital paid for it.
    /// @param launchAdapter     Allowlisted `ILaunchAdapter` implementation.
    /// @param swapAdapter       Allowlisted `ISwapAdapter` for the quote and
    ///                          fee legs.
    /// @param assetIn           Vault-asset budget pulled at execute.
    /// @param quoteToken        The asset the fund token is paired against.
    ///                          MUST satisfy `quoteSupported`.
    /// @param minQuoteOut       Floor on the asset -> quote swap. Ignored when
    ///                          the quote IS the vault asset.
    /// @param quoteSwapData     Routing for the quote leg, opaque here.
    /// @param feeSwapData       Routing for acquiring the adapter's native-fee
    ///                          token. Separate from `quoteSwapData` because it
    ///                          is a different pair.
    /// @param launchSupply      The total supply the proposer declares the
    ///                          venue will mint. VERIFIED at execute against
    ///                          `totalSupply()` — see `SupplyMismatch`.
    /// @param reserveAmount     Launch tokens held back as the holders' claim
    ///                          pot. Bounded by `MAX_RESERVE_BPS`.
    /// @param minTokensOut      Slippage floor on any same-transaction buy.
    ///                          May only be RAISED by `updateParams`.
    /// @param claimWindow       Configured claim duration, clamped at execute.
    /// @param deadline          Venue deadline for the launch transaction.
    /// @param settleSlippageBps Tolerance on the settle-time quote conversion.
    /// @param name              Launch token name.
    /// @param symbol            Launch token symbol.
    /// @param venueData         Venue-specific economics, opaque here.
    struct InitParams {
        address launchAdapter;
        address swapAdapter;
        uint256 assetIn;
        address quoteToken;
        uint256 minQuoteOut;
        bytes quoteSwapData;
        bytes feeSwapData;
        uint256 launchSupply;
        uint256 reserveAmount;
        uint256 minTokensOut;
        uint256 claimWindow;
        uint64 deadline;
        uint256 settleSlippageBps;
        string name;
        string symbol;
        bytes venueData;
    }

    /// @notice The tunable subset, decoded whole by `updateParams`.
    /// @dev    Every member is either monotonically tightening or the venue
    ///         deadline. Nothing else on this template is tunable, and nothing
    ///         here is tunable after execute.
    struct UpdateParams {
        uint256 minTokensOut;
        uint256 minQuoteOut;
        uint256 settleSlippageBps;
        uint64 deadline;
    }

    // ── Storage (per-clone) ──

    /// @notice The allowlisted launch venue adapter.
    ILaunchAdapter public launchAdapter;
    /// @notice The allowlisted swap adapter used for the quote and fee legs.
    ISwapAdapter public swapAdapter;

    /// @notice `IERC4626(vault()).asset()`, read ONCE at init and stored — the
    ///         `MorphoSupplyStrategy` precedent. Every later hop reads this
    ///         slot, so a vault that changed its asset mid-flight cannot
    ///         re-denominate a live proposal.
    address public asset;
    /// @notice The token the launch is paired against.
    address public quoteToken;
    /// @notice The launched ERC-20, written once at execute.
    address public launchToken;
    /// @notice Venue-scoped key for every post-launch verb. Opaque here.
    bytes32 public launchRef;

    uint256 public assetIn;
    uint256 public minQuoteOut;
    uint256 public launchSupply;
    uint256 public reserveAmount;
    uint256 public minTokensOut;
    uint256 public claimWindow;
    uint256 public settleSlippageBps;
    uint64 public deadline;

    /// @notice The claim pot actually recorded at execute.
    /// @dev    WRITTEN ONCE AND NEVER AGAIN. Nothing on this template can grow
    ///         it: fees are paid to the vault by the venue and never arrive
    ///         here, so the once-only claim below divides a fixed number and
    ///         every holder's slice is the same whenever they take it.
    uint256 public reserve;
    /// @notice The vault-clock timepoint every claim is priced against.
    /// @dev    EXECUTE-TIME, NOT INIT-TIME. Adversary the placement answers: an
    ///         init-time snapshot lets the proposer freeze the claimant set
    ///         BEFORE depositors can react to the public proposal. Execute-time
    ///         matches the instant capital actually leaves the vault.
    ///         Full-width `uint256` (not the `uint48` `clock()` returns) so the
    ///         slot is unpacked and the value feeds `getPastVotes` unwidened.
    uint256 public snap;
    /// @notice Last timestamp a claim is accepted, clamped at execute.
    uint256 public windowEnd;
    /// @notice `executedAt + strategyDuration`, cached at execute — the
    ///         governor's own anyone-settle predicate.
    /// @dev    CACHED, NOT RE-READ. `getActiveProposal()` reads 0 after
    ///         settlement, so a lazy read at settle time would find nothing.
    ///         The cache shares the execute-time `getProposal(pid)` decode with
    ///         `windowEnd`, so a governor that reorders that struct poisons
    ///         both identically — which is why `MAX_CLAIM_WINDOW`, not this
    ///         value, is the real containment bound.
    uint256 public anyoneSettleAt;

    /// @notice Reserve already paid out.
    uint256 public totalClaimed;
    /// @notice Per-holder claim record. One shot per holder.
    mapping(address => bool) public claimed;

    /// @notice Once set, `hasUnvaluedResidue()` is permanently false.
    /// @dev    See `hasUnvaluedResidue` for the full adversary.
    bool public residueLatched;

    string internal _tokenName;
    string internal _tokenSymbol;
    bytes internal _quoteSwapData;
    bytes internal _feeSwapData;
    bytes internal _venueData;

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Launchpad";
    }

    /// @notice The launch token's configured name/symbol.
    function tokenName() external view returns (string memory) {
        return _tokenName;
    }

    /// @notice The launch token's configured symbol.
    function tokenSymbol() external view returns (string memory) {
        return _tokenSymbol;
    }

    /// @notice Opaque venue economics handed to the adapter at launch.
    function venueData() external view returns (bytes memory) {
        return _venueData;
    }

    // ── Initialization ──

    /// @notice Decode: one `InitParams`.
    /// @dev    Init-time validation, IN ADVERSARY ORDER — each check is only
    ///         meaningful once the ones above it have passed:
    ///
    ///           1. The registry must RESOLVE. Init is the one place that fails
    ///              closed on resolution; see `TierRegistryUnresolved`.
    ///           2. BOTH adapters must be allowlisted, before any call is made
    ///              into either. `quoteSupported` below is a question asked OF
    ///              the launch adapter — an attacker-authored one answers
    ///              "yes" for free, so binding must come first.
    ///           3. `quoteSupported(quoteToken)`, the venue-lane check.
    ///           4. A nonzero reserve — the claim is the reason this template
    ///              may spend the float at all.
    ///           5. The reserve cap, against the DECLARED supply. Its teeth are
    ///              at execute (`SupplyMismatch`), not here.
    ///           6. The claim window ceiling — the corrupt-decode containment
    ///              bound.
    ///           7. Slippage bounds.
    ///           8. A nonzero budget.
    ///
    ///         NOT BOUND: `quoteToken` and the launch token itself. Neither
    ///         receives vault-fund movements as a CALLEE the way an adapter
    ///         does — the strategy holds them as inventory and never calls them
    ///         beyond ERC-20 — and routing them through `isAdapterAllowed`
    ///         would overload that flag into "this ERC20 may be a launch
    ///         quote", which no other consumer reads it as. The quote's
    ///         venue-suitability is answered by `quoteSupported` instead, which
    ///         is where the Sushi/Stonk asymmetry actually lives.
    function _initialize(bytes calldata data) internal override {
        InitParams memory p = abi.decode(data, (InitParams));

        if (p.launchAdapter == address(0) || p.swapAdapter == address(0) || p.quoteToken == address(0)) {
            revert ZeroAddress();
        }

        address registry = _resolveTierRegistry();
        if (registry == address(0)) revert TierRegistryUnresolved();
        if (!_isAdapterAllowed(registry, p.launchAdapter)) revert LaunchAdapterNotAllowed(p.launchAdapter, registry);
        if (!_isAdapterAllowed(registry, p.swapAdapter)) revert SwapAdapterNotAllowed(p.swapAdapter, registry);

        if (!ILaunchAdapter(p.launchAdapter).quoteSupported(p.quoteToken)) revert QuoteNotSupported(p.quoteToken);

        if (p.reserveAmount == 0) revert ZeroReserve();
        uint256 maxReserve = Math.mulDiv(p.launchSupply, MAX_RESERVE_BPS, BPS);
        if (p.reserveAmount > maxReserve) revert ReserveTooLarge(p.reserveAmount, maxReserve);

        if (p.claimWindow == 0 || p.claimWindow > MAX_CLAIM_WINDOW) {
            revert InvalidClaimWindow(p.claimWindow, MAX_CLAIM_WINDOW);
        }
        if (p.settleSlippageBps == 0 || p.settleSlippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage(p.settleSlippageBps);
        }
        if (p.assetIn == 0) revert InvalidAmount();

        launchAdapter = ILaunchAdapter(p.launchAdapter);
        swapAdapter = ISwapAdapter(p.swapAdapter);
        asset = IERC4626(vault()).asset();
        quoteToken = p.quoteToken;
        assetIn = p.assetIn;
        minQuoteOut = p.minQuoteOut;
        launchSupply = p.launchSupply;
        reserveAmount = p.reserveAmount;
        minTokensOut = p.minTokensOut;
        claimWindow = p.claimWindow;
        deadline = p.deadline;
        settleSlippageBps = p.settleSlippageBps;
        _tokenName = p.name;
        _tokenSymbol = p.symbol;
        _quoteSwapData = p.quoteSwapData;
        _feeSwapData = p.feeSwapData;
        _venueData = p.venueData;
    }

    // ── Tunable params: PRE-execute only, tightening only ──

    /// @inheritdoc IStrategy
    /// @dev    OVERRIDES `BaseStrategy.updateParams`, WHICH REQUIRES `Executed`.
    ///         The reversal is deliberate and is documented on `NotPending`:
    ///         every tunable on this template is an input to the single
    ///         irreversible act it performs. `onlyProposer` is preserved
    ///         unchanged, including its live `isAgent` re-check — a
    ///         de-registered agent loses this authority on already-deployed
    ///         clones.
    function updateParams(bytes calldata data) external override onlyProposer {
        if (_state != State.Pending) revert NotPending();
        _updateParams(data);
    }

    /// @dev Decode: one `UpdateParams`. Monotone tightening only:
    ///        - `minTokensOut` may only RISE. This is the normative MEV
    ///          mitigation: the floor was visible to voters before they voted
    ///          and may only ratchet toward depositors.
    ///        - `minQuoteOut` may only RISE, same argument for the quote leg.
    ///        - `settleSlippageBps` may only FALL (and never to zero — see
    ///          `MAX_SLIPPAGE_BPS`).
    ///        - `deadline` may move freely. It is not a value bound at all: a
    ///          deadline only ever decides whether the launch transaction
    ///          reverts, and the proposal's own `executeBy` already bounds when
    ///          execution may happen. Letting it move lets a proposer rescue a
    ///          proposal whose vote ran long, without touching a single number
    ///          a voter priced.
    function _updateParams(bytes calldata data) internal override {
        UpdateParams memory u = abi.decode(data, (UpdateParams));

        if (u.minTokensOut < minTokensOut) revert NotTightening();
        if (u.minQuoteOut < minQuoteOut) revert NotTightening();
        if (u.settleSlippageBps > settleSlippageBps) revert NotTightening();
        if (u.settleSlippageBps == 0) revert InvalidSlippage(u.settleSlippageBps);

        minTokensOut = u.minTokensOut;
        minQuoteOut = u.minQuoteOut;
        settleSlippageBps = u.settleSlippageBps;
        deadline = u.deadline;
    }

    // ── Execute ──

    /// @dev ORDER IS THE SECURITY ARGUMENT HERE, so it is spelled out:
    ///
    ///        1. RE-CERTIFY both adapters live. Blocking `execute()` strands
    ///           nothing — the proposal expires at `executeBy` with the vault
    ///           untouched — while blocking `settle()` would strand deployed
    ///           capital, which is why `_settle` NEVER consults the registry.
    ///           Without this, an adapter demoted between clone-init and
    ///           execute (reachable with NO governance action via the
    ///           permissionless `poke`/`demoteByChallenge`, or a metamorphic
    ///           redeploy) would still receive the whole budget by approval.
    ///        2. Pull the budget.
    ///        3. Acquire the quote.
    ///        4. Acquire the venue's native fee in the token the adapter NAMES.
    ///        5. Approve and launch.
    ///        6. Verify custody against the CHAIN, not the adapter's word.
    ///        7. Verify the declared supply — what makes `MAX_RESERVE_BPS`
    ///           non-gameable.
    ///        8. Freeze the snapshot from the VAULT's clock.
    ///        9. Clamp the claim window to the proposal's own clock.
    ///       10. Zero every approval and return the unspent remainder.
    function _execute() internal override {
        // 1 ── live re-certification
        _requireAllowedAdapters();

        // 2 ── budget
        _pullFromVault(asset, assetIn);

        // 3 ── the venue's native fee, in the token the adapter NAMES, read
        //      LIVE. Read BEFORE the quote leg on purpose: when the fee is
        //      denominated in the vault asset — the ordinary case, a WETH vault
        //      funding Sushi's ETH launch fee — swapping the whole budget into
        //      the quote and buying the fee back would cross the pair TWICE and
        //      pay slippage both ways. On the thin WOOD lane this template
        //      exists to enable, that round trip is the difference between a
        //      launch and a failed one. So hold the fee back instead.
        (address feeToken, uint256 feeAmount) = launchAdapter.nativeFeeSource();
        // A fee with NO NAMED SOURCE is unfundable, and must say so. A venue
        // that charges natively but names no token to charge it in — the shape
        // `StonkLaunchAdapter` reports if its pads ever start charging, since
        // it has no wrapped-native lane to name — would otherwise reach
        // `_acquireFeeToken` and revert inside `IERC20(address(0))` with no
        // returndata at all, which reads as a bug in this template rather than
        // as the venue changing its terms.
        if (feeAmount != 0 && feeToken == address(0)) revert FeeAcquisitionFailed(feeToken, feeAmount, 0);
        uint256 heldBack = (feeAmount != 0 && feeToken == asset) ? feeAmount : 0;

        // 4 ── quote leg
        address quote_ = quoteToken;
        if (quote_ != asset) {
            uint256 assetBal = IERC20(asset).balanceOf(address(this));
            // The budget must cover the fee AND leave something to launch with.
            if (assetBal <= heldBack) revert FeeAcquisitionFailed(feeToken, feeAmount, assetBal);
            uint256 amountIn = assetBal - heldBack;
            IERC20(asset).forceApprove(address(swapAdapter), amountIn);
            uint256 received = swapAdapter.swap(asset, quote_, amountIn, minQuoteOut, _quoteSwapData);
            IERC20(asset).forceApprove(address(swapAdapter), 0);
            if (received == 0 || received < minQuoteOut) revert QuoteAcquisitionFailed(received, minQuoteOut);
        }

        // 5 ── top the fee up only if the hold-back did not already cover it
        //      (a fee denominated in something that is neither the asset nor
        //      already held), then approve exactly it.
        if (feeAmount != 0) {
            _acquireFeeToken(feeToken, feeAmount, quote_);
            if (feeToken != quote_) IERC20(feeToken).forceApprove(address(launchAdapter), feeAmount);
        }

        // 6 ── approve exactly what the adapter may pull, and launch
        uint256 quoteBal = IERC20(quote_).balanceOf(address(this));
        uint256 feeFromQuote = (feeAmount != 0 && feeToken == quote_) ? feeAmount : 0;
        uint256 quoteIn = quoteBal > feeFromQuote ? quoteBal - feeFromQuote : 0;
        IERC20(quote_).forceApprove(address(launchAdapter), quoteIn + feeFromQuote);

        ILaunchAdapter.LaunchResult memory r = launchAdapter.launch(
            ILaunchAdapter.LaunchParams({
                name: _tokenName,
                symbol: _tokenSymbol,
                quoteToken: quote_,
                quoteIn: quoteIn,
                minTokensOut: minTokensOut,
                reserveAmount: reserveAmount,
                deadline: deadline,
                // THE FUND'S VAULT, ALWAYS — read here, never accepted as
                // proposer input (see `InitParams`). The venue binds the payee
                // at launch, so the creator fee stream is the fund's from the
                // first block and never enters this clone's custody.
                feeRecipient: vault(),
                venueData: _venueData
            })
        );

        // 7 ── custody, verified against the chain and not only the adapter's
        //      self-report. The interface's custody invariant is normative but
        //      it is still the adapter saying so.
        uint256 held = IERC20(r.token).balanceOf(address(this));
        if (r.reserveHeld < reserveAmount || held < reserveAmount) {
            revert ReserveNotDelivered(r.reserveHeld, held, reserveAmount);
        }

        // 8 ── the declared supply. See `SupplyMismatch`: without this the 20%
        //      reserve cap is a number the proposer chose the denominator of.
        uint256 actualSupply = IERC20(r.token).totalSupply();
        if (actualSupply != launchSupply) revert SupplyMismatch(actualSupply, launchSupply);

        launchToken = r.token;
        launchRef = r.launchRef;
        reserve = reserveAmount;

        // 9 ── the snapshot, from the VAULT's clock. Required, never inferred.
        uint256 snap_ = _vaultClock();
        snap = snap_;

        // 10 ── clamp the window to the proposal's own clock
        (uint256 windowEnd_, uint256 anyoneSettleAt_) = _clampWindow();
        windowEnd = windowEnd_;
        anyoneSettleAt = anyoneSettleAt_;

        // 11 ── leave no standing approval, return the remainder
        IERC20(quote_).forceApprove(address(launchAdapter), 0);
        if (feeAmount != 0 && feeToken != quote_) IERC20(feeToken).forceApprove(address(launchAdapter), 0);
        _pushAllToVault(asset);

        emit FundLaunched(r.token, r.launchRef, reserveAmount, snap_, windowEnd_, anyoneSettleAt_);
    }

    /// @dev Acquire `feeAmount` of `feeToken` by swapping the launch quote.
    ///
    ///      SIZED FROM A FORWARD QUOTE, because `ISwapAdapter` is exact-INPUT
    ///      only: probe the whole quote balance, derive the input that would
    ///      yield `need` at that rate, add `settleSlippageBps` of headroom, and
    ///      cap at what is actually held. The swap itself carries `need` as its
    ///      own floor, and the post-condition is re-read from the token, so a
    ///      lying quote costs a revert here rather than an under-funded launch.
    ///
    ///      No-ops when the strategy already holds enough — which is the common
    ///      case when the fee token IS the quote (a WETH-quoted Sushi launch),
    ///      and is why this never blindly swaps.
    function _acquireFeeToken(address feeToken, uint256 feeAmount, address quote_) private {
        uint256 held = IERC20(feeToken).balanceOf(address(this));
        if (held >= feeAmount) return;
        uint256 need = feeAmount - held;

        uint256 probe = IERC20(quote_).balanceOf(address(this));
        if (probe == 0) revert FeeAcquisitionFailed(feeToken, feeAmount, held);

        uint256 out = swapAdapter.quote(quote_, feeToken, probe, _feeSwapData);
        if (out == 0) revert FeeAcquisitionFailed(feeToken, feeAmount, held);

        uint256 amountIn = Math.mulDiv(need, probe, out, Math.Rounding.Ceil);
        amountIn = Math.mulDiv(amountIn, BPS + settleSlippageBps, BPS);
        if (amountIn > probe) amountIn = probe;

        IERC20(quote_).forceApprove(address(swapAdapter), amountIn);
        swapAdapter.swap(quote_, feeToken, amountIn, need, _feeSwapData);
        IERC20(quote_).forceApprove(address(swapAdapter), 0);

        uint256 after_ = IERC20(feeToken).balanceOf(address(this));
        if (after_ < feeAmount) revert FeeAcquisitionFailed(feeToken, feeAmount, after_);
    }

    /// @dev `windowEnd = min(executedAt + claimWindow, executedAt +
    ///      strategyDuration - CLAIM_SETTLE_BUFFER)`, plus the cached
    ///      anyone-settle backstop.
    ///
    ///      THE PID IS CACHED HERE AND ONLY HERE. `getActiveProposal()` names
    ///      the proposal only while it is `Executed` and reads 0 after
    ///      settlement, so a lazy read at settle time would find nothing — the
    ///      whole reason `anyoneSettleAt` is stored rather than derived.
    ///
    ///      An init-time static bound cannot do this job: `initialize` runs
    ///      before the proposal that will carry the clone exists, so the
    ///      strategy cannot know the `strategyDuration` it will run under.
    ///      `MAX_CLAIM_WINDOW` is the static bound that still holds when this
    ///      read is unusable.
    function _clampWindow() private view returns (uint256 windowEnd_, uint256 anyoneSettleAt_) {
        address gov = ITierBindingPath(vault()).governor();
        uint256 pid = ISyndicateGovernor(gov).getActiveProposal();
        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(gov).getProposal(pid);

        // REVERTS, never saturates — see `StrategyDurationTooShort`.
        if (p.strategyDuration <= CLAIM_SETTLE_BUFFER) {
            revert StrategyDurationTooShort(p.strategyDuration, CLAIM_SETTLE_BUFFER);
        }

        uint256 byConfig = p.executedAt + claimWindow;
        uint256 byProposal = p.executedAt + p.strategyDuration - CLAIM_SETTLE_BUFFER;
        windowEnd_ = byConfig < byProposal ? byConfig : byProposal;
        anyoneSettleAt_ = p.executedAt + p.strategyDuration;
    }

    // ── Claim ──

    /// @notice Take the caller's pro-rata slice of the reserve.
    function claim() external returns (uint256 amount) {
        return _claim(msg.sender);
    }

    /// @notice Take `holder`'s slice of the reserve, PAYING THE HOLDER.
    /// @dev    PERMISSIONLESS BY DESIGN, and safe because the payee is the
    ///         holder and never the caller: a keeper (or the syndicate itself)
    ///         can sweep every holder into their claim before the window
    ///         closes, and the worst a hostile caller achieves is paying gas to
    ///         give someone else their own tokens slightly earlier than they
    ///         asked. Making this proposer-gated would instead hand the
    ///         proposer a lever over WHOSE claim survives the window.
    function claimFor(address holder) external returns (uint256 amount) {
        return _claim(holder);
    }

    /// @notice What `holder` could claim right now, ignoring the time gates.
    /// @dev    View-only convenience for keepers/UIs. Returns 0 rather than
    ///         reverting for an already-claimed holder or an un-executed clone.
    function claimable(address holder) external view returns (uint256) {
        if (_state != State.Executed) return 0;
        if (claimed[holder]) return 0;
        uint256 total = IVaultVotes(vault()).getPastTotalSupply(snap);
        if (total == 0) return 0;
        return Math.mulDiv(reserve, IVaultVotes(vault()).getPastVotes(holder, snap), total);
    }

    /// @dev THE CLAIM IS A DIVIDEND IN KIND — shares are NOT burned. Burn-to-
    ///      redeem is rejected for v1: share supply is the governor's voting
    ///      base and the queue's pricing base, and burning mid-proposal
    ///      interacts with `VaultWithdrawalQueue`'s single-realized-price
    ///      invariant and the checkpointed vote balances.
    ///
    ///      The math relies on the vault's normative auto-self-delegation, so
    ///      past votes equal past balance for anyone who never delegated. Two
    ///      known divergences are ACCEPTED and documented rather than
    ///      corrected: queue-escrowed shares at the snapshot carry no claim
    ///      (the escrow contract never calls this, and its weight stays as
    ///      unpriced fund tokens warehoused at the vault), and an explicit
    ///      delegator's claim follows the vote — `ERC20Votes` has no historical
    ///      BALANCE checkpoint and adding one to the vault is out of scope.
    ///
    ///      GATE ORDER MATTERS: the clock check runs BEFORE either vote read,
    ///      so a claim in the execute block reverts with `SnapshotNotFinal`
    ///      instead of bubbling OZ's `ERC5805FutureLookup` out of the vault.
    ///
    ///      ONCE PER HOLDER, and `reserve` is immutable after execute, so
    ///      Σ(all claims) <= `reserve` holds by floor division: each share is
    ///      `floor(reserve * w_i / T)` out of the same denominator.
    ///      `ClaimExceedsReserve` stays as the assertion of it.
    function _claim(address holder) private returns (uint256 amount) {
        if (_state != State.Executed) revert NotClaimable();
        if (block.timestamp > windowEnd) revert ClaimWindowClosed(block.timestamp, windowEnd);

        uint256 nowClock = _vaultClock();
        // OZ reverts at `timepoint >= clock()`, so `>` here is exactly the
        // complement of the range OZ accepts — no gap, no overlap.
        if (nowClock <= snap) revert SnapshotNotFinal(nowClock, snap);

        if (claimed[holder]) revert AlreadyClaimed(holder);

        uint256 total = IVaultVotes(vault()).getPastTotalSupply(snap);
        if (total == 0) revert ZeroEntitlement(holder);
        amount = Math.mulDiv(reserve, IVaultVotes(vault()).getPastVotes(holder, snap), total);
        if (amount == 0) revert ZeroEntitlement(holder);

        uint256 claimedTotal = totalClaimed + amount;
        if (claimedTotal > reserve) revert ClaimExceedsReserve(claimedTotal, reserve);

        claimed[holder] = true;
        totalClaimed = claimedTotal;

        IERC20(launchToken).safeTransfer(holder, amount);
        emit ReserveClaimed(holder, amount, claimedTotal);
    }

    // ── Settle ──

    /// @dev THE WINDOW TRUNCATES; SETTLEMENT NEVER WAITS ON IT. The gate is a
    ///      disjunction — see `ClaimWindowStillOpen` for what a one-armed gate
    ///      would cost. The backstop arm needs no FRESH governor read (there is
    ///      none to have: `getActiveProposal()` reads 0 by now) but it does
    ///      share the execute-time struct decode with the clamp, so a governor
    ///      that reorders that struct poisons both. `MAX_CLAIM_WINDOW` is what
    ///      actually contains that case.
    ///
    ///      IT MAKES NO VENUE CALL AT ALL, and that is the simplification the
    ///      vault-direct fee routing bought. There is no fee to sweep here (the
    ///      venue has been paying `vault()` since the launch block) and no
    ///      creator role to hand over (the vault has held it since the launch
    ///      block), so the two tolerated-failure venue legs this hook used to
    ///      carry are gone rather than merely defended: settlement can no
    ///      longer be made to skip a leg by a paused pad, a reverting
    ///      `collectFees`, or a venue with no transfer entry point, because it
    ///      no longer asks a venue for anything. What remains is arithmetic on
    ///      balances this clone already holds.
    ///
    ///      Anyone who wants accrued fees pushed calls the ADAPTER's
    ///      `collectFees(launchRef)` directly — permissionless, paying the
    ///      vault, and available before, during and after settlement.
    ///
    ///      IT NEVER SELLS THE FUND TOKEN. Not into its own launch pool, not
    ///      anywhere — that price is attacker-movable inside this very
    ///      transaction, which is the finding-#3 shape verbatim. The fund token
    ///      leaves only as a claim, or as unpriced inventory via `sweep()`.
    ///
    ///      THE REGISTRY IS NEVER CONSULTED HERE. `_execute` re-certifies
    ///      because blocking it strands nothing; gating the EXIT would hand a
    ///      demotion — or a merely unreachable registry — the power to freeze
    ///      deployed capital.
    function _settle() internal override {
        if (block.timestamp <= windowEnd && block.timestamp < anyoneSettleAt) {
            revert ClaimWindowStillOpen(block.timestamp, windowEnd, anyoneSettleAt);
        }

        // ── convert quote -> vault asset, or leave it as declared residue
        address quote_ = quoteToken;
        if (quote_ != asset) _convertQuote(quote_);

        uint256 delivered = IERC20(asset).balanceOf(address(this));
        _pushAllToVault(asset);

        emit FundSettled(
            delivered,
            launchToken == address(0) ? 0 : _safeBalance(launchToken),
            quote_ == asset ? 0 : _safeBalance(quote_)
        );
    }

    /// @dev A FAILED OR UNQUOTABLE CONVERSION IS RESIDUE, NOT A REVERT. The
    ///      floor is derived from the adapter's own forward quote discounted by
    ///      `settleSlippageBps`; a quote that cannot be read, a quote of zero,
    ///      or a swap that reverts all leave the quote token in custody, where
    ///      `undeliveredValue()`/`hasUnvaluedResidue()` declare it and `sweep()`
    ///      warehouses it. Deliverable maximum: settle what is expressible,
    ///      declare the rest.
    function _convertQuote(address quote_) private {
        uint256 bal = _safeBalance(quote_);
        if (bal == 0) return;

        // solhint-disable-next-line avoid-low-level-calls
        (bool qOk, bytes memory qRet) =
            address(swapAdapter).call(abi.encodeCall(ISwapAdapter.quote, (quote_, asset, bal, _quoteSwapData)));
        if (!qOk || qRet.length != 32) {
            emit SettlementLegSkipped("quote");
            return;
        }
        uint256 expected = abi.decode(qRet, (uint256));
        if (expected == 0) {
            emit SettlementLegSkipped("quote");
            return;
        }
        uint256 floor_ = Math.mulDiv(expected, BPS - settleSlippageBps, BPS);

        IERC20(quote_).forceApprove(address(swapAdapter), bal);
        // solhint-disable-next-line avoid-low-level-calls
        (bool sOk,) =
            address(swapAdapter).call(abi.encodeCall(ISwapAdapter.swap, (quote_, asset, bal, floor_, _quoteSwapData)));
        IERC20(quote_).forceApprove(address(swapAdapter), 0);
        if (!sOk) emit SettlementLegSkipped("settleSwap");
    }

    // ── Delivery views (the split latch) ──

    /// @inheritdoc IStrategyDelivery
    /// @dev TRUE while the settled clone holds fund tokens (or, when the quote
    ///      differs from the vault asset, quote tokens) above `RESIDUE_DUST` —
    ///      the legs this template CANNOT price. The vault refuses to mint
    ///      while anything is unvalued, which is the one place a lock still
    ///      beats a price: there is no honest number to charge.
    ///
    ///      MONOTONE AFTER SETTLEMENT. The FIRST false observation after the
    ///      clone reached `Settled` — whether a clearing `sweep()` drove custody
    ///      below dust or custody was already below it at settlement — latches
    ///      this permanently false. It is a view, so the observation is recorded
    ///      by `sweep()` or by the permissionless `pokeResidueLatch()`; NEVER at
    ///      settlement itself, where the flag legitimately reads true because
    ///      custody is at its maximum before any sweep.
    ///
    ///      Adversary the latch closes: a clone is still `tracked` on
    ///      `_residueAmount != 0` alone, so a donation of `RESIDUE_DUST + 1`
    ///      fund tokens to a settled, already-clear clone flips this probe
    ///      false -> true, `_refreshUnvalued` marks it (never burned) and
    ///      `_bumpUnvalued` re-stamps `_unvaluedSince` for a FRESH 7-day deposit
    ///      lock — repeatable per donation, with `releaseUnconvertible` as the
    ///      zero-cost trigger. Monotonicity is sound because every vault-side
    ///      flow moves the flag true -> false only and a clone cannot settle
    ///      twice. The residual cost — a genuinely unvaluable residue arriving
    ///      later stops blocking mints — is the bounded-mispricing trade
    ///      `_unvaluedSince` already makes, and strictly narrower than
    ///      `_unvaluedBurned`'s permanent immunity.
    ///
    ///      NEVER REVERTS: every balance read is a length-checked staticcall
    ///      that resolves an uncooperative token to 0.
    function hasUnvaluedResidue() public view override returns (bool) {
        if (_state != State.Settled) return false;
        if (residueLatched) return false;
        return _unvaluedNow();
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev DELIBERATELY NOT LATCHED ON THE PREDICATE ABOVE. The two measure
    ///      DISJOINT legs and feed DISJOINT vault machinery: `depositsLocked()`
    ///      reads only the unvalued flag, while THIS figure feeds
    ///      `depositNav() = totalAssets() + _residueTotal` into
    ///      `previewDeposit`/`previewMint`. Latching a vault-asset figure to 0
    ///      on a FUND-TOKEN observation, with real vault-asset residue still
    ///      held, would under-price mints — and `IStrategyDelivery.sol:44-53`
    ///      names that outright: a report that is too low IS the finding-#3
    ///      skim, and bias-low is not safe here.
    ///
    ///      Reports honest vault-asset custody while `Settled`, reaching 0 only
    ///      when that custody is 0. A fund-token donation cannot inflate it at
    ///      all (it counts only the vault asset) and is a pure lock vector,
    ///      already closed by the latch; a vault-asset donation can inflate it
    ///      but is benign — clamped vault-side by `_residueCap = min(capital
    ///      snapshot, effective max capital)`, genuinely recoverable by
    ///      `sweep()`, and over-counting only over-charges that depositor.
    function undeliveredValue() public view override returns (uint256) {
        if (_state != State.Settled) return 0;
        return _safeBalance(asset);
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev TRACKS `undeliveredValue()`, NOT the unvalued flag — the split
    ///      above is the whole point, and wiring this to the latched predicate
    ///      would re-import the skim through the back door.
    ///
    ///      DUST-FLOORED, unlike the amount it tracks, matching
    ///      `MorphoSupplyStrategy` and `ConcentratedLiquidityStrategy`: a bool
    ///      keying on `!= 0` is the grief `RESIDUE_DUST` was introduced for
    ///      (see its natspec on `BaseStrategy`) — anyone can transfer 1 wei to
    ///      a long-settled clone, forever. The vault reads
    ///      `hasUnvaluedResidue()` and `undeliveredValue()` and does not
    ///      currently consult this at all, so today the floor is
    ///      defence-in-depth rather than a live fix; it costs nothing and stops
    ///      a future reader from inheriting the grief. The AMOUNT deliberately
    ///      keeps no floor — biasing it low is the skim.
    function hasUndeliveredValue() public view override returns (bool) {
        return undeliveredValue() > RESIDUE_DUST;
    }

    /// @notice Record the unvalued-residue latch when the predicate currently
    ///         reads false on a settled clone.
    /// @dev    PERMISSIONLESS AND IDEMPOTENT. `hasUnvaluedResidue()` is a view
    ///         and a latch needs a state write, so the arming observation has to
    ///         be someone's transaction. `sweep()` arms it too, but `sweep()` is
    ///         vault-only and a clone that settled ALREADY clear never gets one
    ///         — that clone is exactly the donation target the latch protects,
    ///         so the arming path must not require the vault to act.
    ///
    ///         Costs nothing to call and grants nothing: it can only move the
    ///         flag in the direction the vault already moves it, and only when
    ///         the flag is genuinely false at the moment of observation.
    function pokeResidueLatch() external returns (bool latched) {
        _armResidueLatch();
        return residueLatched;
    }

    /// @dev Arms the latch iff the clone is settled, not already latched, and
    ///      the predicate reads FALSE right now.
    function _armResidueLatch() private {
        if (residueLatched) return;
        if (_state != State.Settled) return;
        if (_unvaluedNow()) return;
        residueLatched = true;
        emit UnvaluedResidueLatched();
    }

    /// @dev The raw predicate, before the latch. Both legs are the ones this
    ///      template cannot price: the fund token (no honest, non-movable
    ///      price exists for it inside a settlement transaction) and — only
    ///      when it differs from the vault asset — the quote.
    function _unvaluedNow() private view returns (bool) {
        address token = launchToken;
        if (token != address(0) && _safeBalance(token) > RESIDUE_DUST) return true;
        address quote_ = quoteToken;
        if (quote_ != asset && _safeBalance(quote_) > RESIDUE_DUST) return true;
        return false;
    }

    // ── Sweep ──

    /// @notice Return everything this settled clone still holds to the vault.
    /// @dev    `onlyVault` and `Settled`-only. BALANCE-ONLY, BY CONSTRUCTION:
    ///         no venue call, no swap, no fee collection, no cross-clone flush.
    ///         The vault drives this under a hard `_SWEEP_GAS = 1_500_000` cap,
    ///         IGNORES the result, and measures recovery as a balance delta — so
    ///         an out-of-gas sweep silently recovers nothing while looking like
    ///         success. Three balance reads and three transfers fit that cap
    ///         with room to spare; a venue call would not, and its failure would
    ///         be invisible.
    ///
    ///         VAULT-ONLY even though value only ever moves the right way. The
    ///         PUSH is fine; the ACCOUNTING is what breaks — `collectResidue`
    ///         measures a balance delta across this call and pays the exited
    ///         redeem cohort their frozen fraction of it. Called directly, the
    ///         assets land outside that window: the cohort is credited nothing
    ///         and the arrival silently lifts the price for whoever STAYED.
    ///
    ///         The fund token and any leftover quote go to the vault as
    ///         UNPRICED INVENTORY, warehoused under the vault's existing
    ///         owner-gated rescue surface. The vault never counts them in NAV.
    ///
    ///         Arms the residue latch LAST, after the transfers, so the
    ///         observation it records is the post-sweep one.
    /// @return assets The vault-asset amount pushed this call.
    function sweep() external onlyVault returns (uint256 assets) {
        if (_state != State.Settled) revert NotSettled();

        assets = _safeBalance(asset);
        if (assets != 0) _pushToVault(asset, assets);

        address token = launchToken;
        uint256 tokenAmount;
        if (token != address(0)) {
            tokenAmount = _safeBalance(token);
            if (tokenAmount != 0) IERC20(token).safeTransfer(vault(), tokenAmount);
        }

        address quote_ = quoteToken;
        uint256 quoteAmount;
        if (quote_ != asset) {
            quoteAmount = _safeBalance(quote_);
            if (quoteAmount != 0) IERC20(quote_).safeTransfer(vault(), quoteAmount);
        }

        _armResidueLatch();
        emit ResidueSwept(assets, tokenAmount, quoteAmount);
    }

    // ── Reads that must not revert ──

    /// @dev `balanceOf(address(this))` through a length-checked staticcall.
    ///      A token that reverts, returns short, or has no code resolves to 0
    ///      rather than bricking a probe the vault reads under a gas cap and
    ///      treats as "no residue" on failure.
    function _safeBalance(address token) private view returns (uint256) {
        if (token.code.length == 0) return 0;
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || ret.length < 32) return 0;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word;
    }

    /// @dev The vault's ERC-5805 clock, REQUIRED rather than inferred. A
    ///      length-checked staticcall whose failure is a named revert — see
    ///      `VaultClockUnreadable` for why `block.timestamp` is not an
    ///      acceptable fallback.
    function _vaultClock() private view returns (uint256) {
        address v = vault();
        if (v.code.length == 0) revert VaultClockUnreadable();
        (bool ok, bytes memory ret) = v.staticcall(abi.encodeCall(IVaultVotes.clock, ()));
        if (!ok || ret.length < 32) revert VaultClockUnreadable();
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        // `clock()` is declared `uint48`; a word with dirty upper bits is not a
        // clock this template can key a snapshot to.
        if (word >> 48 != 0) revert VaultClockUnreadable();
        return word;
    }

    // ── Governance-allowlist binding ──

    /// @dev Re-certifies BOTH adapters. Called from `_initialize` (fail-closed
    ///      on an unresolved registry, see `TierRegistryUnresolved`) and from
    ///      `_execute`. NEVER from `_settle`/`sweep`/`claim`: those are the exit
    ///      paths, and gating them would hand a demotion the power to freeze
    ///      deployed capital and to strand the holders' claim.
    function _requireAllowedAdapters() private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, address(launchAdapter))) {
            revert LaunchAdapterNotAllowed(address(launchAdapter), registry);
        }
        if (!_isAdapterAllowed(registry, address(swapAdapter))) {
            revert SwapAdapterNotAllowed(address(swapAdapter), registry);
        }
    }

    /// @dev `vault() -> governor() -> tierRegistry()` walk. Returns
    ///      `address(0)` when unresolved. Byte-for-byte the walk
    ///      `PortfolioStrategy` and `MorphoSupplyStrategy` use; kept as a local
    ///      copy rather than pushed into `BaseStrategy` so that base gains no
    ///      new external-call surface every other template's test stand-ins
    ///      would have to answer.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev Staticcall-safe `isAdapterAllowed`. Unreadable -> `false`: a
    ///      registry that cannot vouch for an adapter has not vouched for it.
    ///
    ///      READS THE WORD, DOES NOT `abi.decode` IT. `abi.decode(ret, (bool))`
    ///      reverts on any returned word outside `{0, 1}`, and that revert
    ///      lands in THIS frame with nothing to catch it — so a registry
    ///      answering `2` would brick `_initialize` instead of resolving to
    ///      "not vouched for", defeating the point of the raw staticcall.
    function _isAdapterAllowed(address registry, address adapter) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) = registry.staticcall(abi.encodeCall(ITierBindingPath.isAdapterAllowed, (adapter)));
        if (!ok || ret.length != 32) return false;
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        return word != 0;
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short
    ///      return, or dirty upper bits all resolve to `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        // casting to `uint160` is safe because the dirty-high-bits check above
        // already rejected any word that would truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(word));
    }
}
