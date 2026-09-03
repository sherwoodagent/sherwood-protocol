// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IProposalStatus} from "./interfaces/IProposalStatus.sol";
import {IStrategyDelivery} from "./interfaces/IStrategyDelivery.sol";
import {ICallSandbox} from "./interfaces/ICallSandbox.sol";
import {FeeConstants} from "./FeeConstants.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {IVaultWithdrawalQueue} from "./interfaces/IVaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {SyndicateVaultAdminLib} from "./SyndicateVaultAdminLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SyndicateVault
 * @notice ERC-4626 vault for agent-managed investment syndicates.
 *
 *   The vault is the onchain identity — it holds all positions (mTokens, borrows,
 *   swapped tokens) via delegatecall to a shared BatchExecutorLib. Deploy one
 *   executor lib, share it across all syndicates.
 *
 *   Strategy execution goes through the governor via proposals
 *   (executeGovernorBatch). Asset recovery uses dedicated rescueERC20 /
 *   rescueERC721 / rescueEth paths. The owner has no arbitrary-calldata entry
 *   point into the vault.
 *
 *   Inherits ERC20VotesUpgradeable to provide proper vote checkpointing for
 *   the governor's snapshot-based voting system.
 *
 *   Deployed as ERC-1967 UUPS proxy. Upgradeable only via the factory when upgrades are enabled.
 */
contract SyndicateVault is
    ISyndicateVault,
    Initializable,
    ERC4626Upgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ERC721Holder,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ==================== CONSTANTS ====================

    /// @notice Maximum rows returned by any paginated view in a single call.
    ///         Prevents unbounded iteration from out-of-gassing a page fetch
    ///         even when the underlying set is large.
    uint256 public constant MAX_PAGE_LIMIT = 100;
    /// @notice Hard cap on agents per vault so the `rotateOwnership`
    ///         deactivation loop has a predictable upper bound and cannot OOG.
    ///         32 SSTOREs ~= 6.4k gas — fits comfortably in any block.
    ///         `removeAgent` frees a slot.
    uint256 public constant MAX_AGENTS_PER_VAULT = 32;

    /// @notice Hard cap on the vault-owner-set agent performance fee (25%), equal
    ///         to the protocol ceiling on the governor's `maxPerformanceFeeBps`.
    ///         The governor additionally clamps the realized fee to its own,
    ///         lower, configured value at settlement, so a stored value above the
    ///         live param is never charged; capping here keeps `agentFeeBps()`
    ///         from advertising a rate that can never be realized.
    /// @dev A backstop, not the headline rate: a factory-created vault starts at a
    ///      per-vault `maxPerformanceFeeBps` of 20%.
    uint256 public constant MAX_AGENT_FEE_BPS = FeeConstants.MAX_PERFORMANCE_FEE_BPS;

    /// @notice Cap on the owner-set idle-liquidity floor (50%).
    uint256 private constant MAX_MIN_BUFFER_BPS = 5_000;

    /// @notice How long an unvalued-residue mark may hold the deposit gate shut.
    /// @dev    Long enough that a conforming strategy's `sweep()` /
    ///         `releaseUnconvertible` window is never cut short by it — those
    ///         are permissionless and callable the instant a proposal settles —
    ///         and short enough that a hostile label cannot brick a vault's
    ///         deposits for its lifetime. See `_unvaluedSince`.
    uint256 private constant UNVALUED_MAX_LOCK = 7 days;

    // ── Value-moving ERC20 selectors guarded in governor batches ──
    // (see `_guardBatchCalls`)
    bytes4 private constant _SEL_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _SEL_INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)
    bytes4 private constant _SEL_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)

    // Alternate-signature pull/push-via-delegated-allowance selectors: the same
    // guarded CAPABILITY as the four legacy-ERC20 selectors above, exposed under
    // different 4-byte selectors by non-legacy allowance routers. Permit2's
    // AllowanceTransfer singleton — deployed at the same address on nearly every
    // EVM chain, with huge numbers of standing LP allowances — and
    // DSToken-lineage `pull`/`move` wrappers reproduce the exact
    // LP-allowance-confiscation and poison-then-drain shapes Part 1b/Part 2 close,
    // invisible to both because neither matched any legacy selector. Each decodes
    // with the SAME argument layout as its legacy counterpart (source at bytes
    // 4:36; destination, where present, at 36:68).
    bytes4 private constant _SEL_PERMIT2_TRANSFER_FROM = 0x36c78516; // Permit2 AllowanceTransfer.transferFrom(address from,address to,uint160,address token)
    bytes4 private constant _SEL_PERMIT2_APPROVE = 0x87517c45; // Permit2 AllowanceTransfer.approve(address token,address spender,uint160,uint48)
    bytes4 private constant _SEL_DSTOKEN_PULL = 0xf2d5d56b; // DSToken pull(address usr, uint256 wad) — pulls TO msg.sender (the vault)
    bytes4 private constant _SEL_DSTOKEN_MOVE = 0xbb35783b; // DSToken move(address src, address dst, uint256 wad)

    // Four MORE sibling selectors on the exact routers/standards above, missed by
    // the same enumeration approach — the evidence that motivated the
    // target-based callee gate (PART 2a). These selectors, and everything below,
    // remain the INNER boundary — still load-bearing for e.g. `approve(attacker)`
    // on an otherwise-allowlisted token — but they are no longer the outer
    // boundary against an unenumerated selector on an arbitrary target.
    bytes4 private constant _SEL_DSTOKEN_PUSH = 0xb753a98c; // DSToken push(address dst, uint256 wad) — transfer-lineage sibling of guarded pull/move; internally transfer(dst, wad)
    bytes4 private constant _SEL_ERC1363_TRANSFER_FROM_AND_CALL = 0xd8fbe994; // ERC1363 transferFromAndCall(address from,address to,uint256)
    bytes4 private constant _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA = 0xc1d34b89; // ERC1363 transferFromAndCall(address from,address to,uint256,bytes) — trailing bytes arg does not shift the leading from/to offsets
    bytes4 private constant _SEL_ERC1363_APPROVE_AND_CALL = 0x3177029f; // ERC1363 approveAndCall(address spender,uint256)
    bytes4 private constant _SEL_ERC1363_APPROVE_AND_CALL_DATA = 0xcae9ca51; // ERC1363 approveAndCall(address spender,uint256,bytes)
    bytes4 private constant _SEL_PERMIT2_BATCH_TRANSFER_FROM = 0x0d58b1db; // Permit2 AllowanceTransfer.transferFrom(AllowanceTransferDetails[]) — dynamic-array batch sibling of the guarded single-transfer overload; decoded via `_Permit2BatchDetail`, NOT the fixed-offset slices the other selectors share

    // ERC4626 withdraw/redeem: a THIRD allowance-pull shape. `owner` (the debited
    // source, analogous to `transferFrom`'s `from`) sits at arg 2 (bytes 68:100),
    // not arg 0 — every other guarded selector assumes the source is at bytes
    // 4:36, so these need their own branch.
    bytes4 private constant _SEL_ERC4626_WITHDRAW = 0xb460af94; // withdraw(uint256 assets, address receiver, address owner)
    bytes4 private constant _SEL_ERC4626_REDEEM = 0xba087652; // redeem(uint256 shares, address receiver, address owner) — same arg shape as withdraw
    // ERC1363 transferAndCall: push-with-callback sibling of the guarded
    // `transfer`/`push`/`approveAndCall` — recipient at arg 0, same offset.
    bytes4 private constant _SEL_ERC1363_TRANSFER_AND_CALL = 0x1296ee62; // transferAndCall(address to, uint256 value)
    bytes4 private constant _SEL_ERC1363_TRANSFER_AND_CALL_DATA = 0x4000aea0; // transferAndCall(address to, uint256 value, bytes data)

    /// @dev Decode-only mirror of Permit2's `AllowanceTransferDetails` struct —
    ///      never used to call Permit2, only to `abi.decode` a batch
    ///      `transferFrom` call's calldata so `_guardBatchCalls` can inspect every
    ///      element's `from`/`to`. All fields are static, so the array decodes as
    ///      tightly-packed 128-byte elements with no per-element dynamic pointer.
    struct _Permit2BatchDetail {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    // ==================== STORAGE ====================

    /// @notice Agent address => agent config
    mapping(address => AgentConfig) private _agents;

    /// @notice Set of all registered agent addresses
    EnumerableSet.AddressSet private _agentSet;

    /// @notice Shared executor lib (stateless, called via delegatecall)
    address private _executorImpl;

    /// @notice Approved depositor addresses (whitelist for deposits)
    EnumerableSet.AddressSet private _approvedDepositors;

    /// @notice If true, anyone can deposit (skip whitelist check)
    bool private _openDeposits;

    /// @notice ERC-8004 agent identity registry (ERC-721)
    IERC721 private _agentRegistry;

    // ── Governor / Factory storage ──

    /// @notice Vault owner's management fee on strategy profits (basis points, set at init)
    uint256 private _managementFeeBps;

    /// @notice Factory that deployed this vault (controls upgrades, provides governor address)
    address private _factory;

    /// @notice Expected bytecode hash of `_executorImpl`, stamped at init.
    ///         Re-verified on every delegatecall so a swapped-in library cannot
    ///         impersonate `BatchExecutorLib` without matching its bytecode.
    bytes32 private _expectedExecutorCodehash;

    /// @notice Cached `asset.decimals()` used as the ERC-4626 virtual-shares
    ///         offset. Stamped once at `initialize` so `_decimalsOffset()` is
    ///         a pure storage read on the hot share-conversion path (no
    ///         external call to the asset on every `previewDeposit` /
    ///         `convertTo*` / `_deposit` / `_withdraw`).
    uint8 private _cachedDecimalsOffset;

    /// @notice Per-vault async withdrawal queue (set-once at deploy by the factory).
    address private _withdrawalQueue;

    /// @notice Vault-owner-set agent performance fee, stored offset-by-one so a
    ///         single slot doubles as the is-it-set flag: 0 means never set, and
    ///         `agentFeeBps()` returns the 20% default; otherwise the stored value
    ///         is `fee + 1`, so an explicit 0% stays distinct from unset.
    ///         Snapshotted onto a proposal at propose, clamped to the governor's
    ///         `maxPerformanceFeeBps`.
    uint256 private _agentFeeBpsPlusOne;

    /// @notice Idle-liquidity floor (bps of pre-batch float) enforced against
    ///         governor batches. 0 = off. Packed with `minHoldingPeriod`.
    uint16 public minBufferBps;

    /// @notice Seconds an account must hold after a deposit before instant
    ///         exit (anti flash-arb, GLP-cooldown pattern). Lane B is exempt.
    /// @dev Not yet exposed via ISyndicateVault; kept non-public to stay under
    ///      the EIP-170 runtime size limit. Storage slot/type reserved for
    ///      future instant-exit logic.
    uint32 internal minHoldingPeriod;

    /// @notice Timestamp of each account's most recent instant deposit
    ///         (receiver-side). Gates instant exit via `minHoldingPeriod`.
    /// @dev Not yet exposed via ISyndicateVault; kept non-public to stay under
    ///      the EIP-170 runtime size limit. Storage slot/type reserved for
    ///      future instant-exit logic.
    mapping(address => uint40) internal lastDepositAt;

    // ── Two-number fee model (management + performance) ──

    /// @notice Integral of fund assets over time for the live proposal, in
    ///         asset-seconds. The management fee is this figure annualized:
    ///         `fee = assetSeconds * rate / (BPS_DENOMINATOR * 365 days)`.
    /// @dev Exact under arbitrary mid-proposal flows because the integral is
    ///      piecewise-constant: every base-changing event closes off the
    ///      elapsed interval at the base that applied during it, then restamps.
    uint256 private _mgmtAssetSeconds;

    /// @notice Fund assets in force since `_mgmtLastUpdate` — the height of the
    ///         current rectangle in the integral above.
    uint192 private _mgmtBase;

    /// @notice When `_mgmtBase` was last restamped. Zero means "not accruing":
    ///         no proposal is live, so no management fee is owed. This is the
    ///         gate that keeps capital idle between proposals free, and it also
    ///         keeps `totalAssets()` (an external call for live NAV) off the
    ///         ordinary deposit path.
    uint64 private _mgmtLastUpdate;

    /// @notice Highest price per share this fund has ever been charged a
    ///         performance fee at, carrying the ERC-4626 virtual offsets.
    ///         Performance fee applies only above this mark, so a fund that
    ///         falls and recovers is not charged twice on the same dollars.
    uint256 private _highWaterPricePerShare;

    /// @notice Last known undelivered value per settled strategy that still owes.
    ///         Written at `onProposalSettled` and refreshed by the permissionless
    ///         `collectResidue`; nonzero IS membership.
    ///
    ///         PRICED, NOT LOCKED. An earlier version of this gate refused
    ///         deposits while any strategy still owed. That is a bet on an
    ///         unanswerable question — will the value come back? — and it pays
    ///         nothing in the branch where it is wrong: if the residue never
    ///         arrives, the residue-free price was correct all along and the
    ///         vault was frozen for nothing, potentially forever, since a market
    ///         that never refills never clears. Charging the depositor as though
    ///         it WILL arrive is safe in both branches instead: if it does they
    ///         paid fairly, if it never does they overpaid and the incumbents
    ///         are unharmed either way. The depositor carries the risk of value
    ///         they can see on chain before choosing to enter, which is the
    ///         right person to carry it.
    ///
    ///         DEPOSIT SIDE ONLY, and that asymmetry is the whole safety
    ///         argument. On a mint, counting this makes the depositor receive
    ///         FEWER shares — over-counting costs only them. On a redeem it
    ///         would pay out assets the vault does not hold, which over-pays
    ///         early exiters and strands the tail. Counting it on both sides is
    ///         what made the "widen totalAssets()" direction unsafe; this counts
    ///         it on the safe side only, so `totalAssets()`, the settle stamp,
    ///         every redeem path, the fee bases and the governor's sizing reads
    ///         are all untouched. ERC-4626 explicitly permits deposit and redeem
    ///         to price differently — that is how a vault expresses an entry
    ///         fee, and this is one: the depositor's share of value not yet home.
    ///
    ///         A SET, NOT A POINTER, AND THAT IS THE WHOLE POINT. This was one
    ///         `_lastSettledStrategy` slot, overwritten at every settlement —
    ///         which silently stopped watching the previous strategy even when
    ///         it was still holding a residue. That reopened the finding-#3 skim
    ///         one proposal later: settle N dirty (deposits locked, correctly),
    ///         then settle N+1 clean, and the pin moves to N+1, `depositsLocked`
    ///         reads "nothing outstanding", deposits open — while N's clone
    ///         still holds `R` and `sweep()` is permissionless. Deposit cheap,
    ///         sweep N, skim. The gate has to watch EVERY strategy that still
    ///         owes, not the most recent one.
    ///
    ///         NEEDED BECAUSE THE ORDINARY POINTER IS GONE BY THE TIME IT WOULD
    ///         BE READ: `_activeStrategy()` resolves through
    ///         `getActiveProposal()`, which `_finishSettlement` zeroes
    ///         IMMEDIATELY AFTER calling this vault — the ordering is CEI and
    ///         load-bearing, see the note on `_activeProposal = 0` there. So the
    ///         pointer is still live during `onProposalSettled` and gone by the
    ///         time `depositsLocked` runs. Recording membership here is what
    ///         survives that gap.
    mapping(address strategy => uint256) private _residueAmount;

    /// @notice Sum of `_residueAmount` across every strategy that still owes —
    ///         the figure DEPOSITS are priced against, on top of `totalAssets()`.
    ///
    ///         A RUNNING TOTAL, NOT AN ITERATION. It sits on every deposit
    ///         preview, so summing a set there would be both a gas cost and an
    ///         unbounded-growth hazard. Maintained by `_recordResidue` and
    ///         `collectResidue`, which are the only two writers of
    ///         `_residueAmount`.
    uint256 private _residueTotal;

    /// @notice Upper bound on what each strategy may contribute to
    ///         `_residueTotal`, pinned at settlement from the proposal's capital
    ///         snapshot — the vault's own asset balance immediately before the
    ///         execute batch.
    ///
    ///         A SELF-REPORTED NUMBER THAT PRICES MINTS MUST BE BOUNDED. The
    ///         figure comes from a proposer-chosen contract and `propose`
    ///         validates nothing about it, so an uncapped report is a deposit
    ///         brick with no exit: near `type(uint256).max` the addition in
    ///         `depositNav()` overflows and every mint path reverts, and merely
    ///         large floors `previewDeposit` to zero, which without the guard in
    ///         `_deposit` would take a depositor's assets and mint nothing. The
    ///         cap is the honest bound rather than an arbitrary one: a strategy
    ///         cannot owe back more PRINCIPAL than the capital its proposal was
    ///         permitted to move.
    ///
    ///         TRUE OF PRINCIPAL, NOT OF PRINCIPAL PLUS YIELD, and the gap is
    ///         deliberate. A strategy that deployed its full ceiling and earned
    ///         on it owes slightly more than that ceiling, and this clamp cuts
    ///         the excess — so the recorded figure runs under, never over. That
    ///         is the same direction as every other approximation on this path:
    ///         an under-count costs the depositor a sliver, an over-count would
    ///         let a hostile clone tax every entrant or brick the mint entirely.
    mapping(address strategy => uint256) private _residueCap;

    /// @notice Strategies reporting residue they CANNOT value in vault-asset
    ///         terms — a live LP position, a volatile leg, a non-asset
    ///         collateral. Set and refreshed alongside `_residueAmount`.
    mapping(address strategy => bool) private _residueUnvalued;

    /// @notice How many strategies are in `_residueUnvalued`. Deposits are
    ///         REFUSED while this is nonzero, and that narrow lock is the one
    ///         place pricing cannot substitute for blocking.
    ///
    ///         WHY A LOCK SURVIVES HERE AT ALL. `undeliveredValue()` is
    ///         deliberately partial on `ConcentratedLiquidityStrategy`: it
    ///         reports only what the template can value WITHOUT consulting a
    ///         price an attacker could move, and excludes the LP position, the
    ///         volatile leg, and a non-asset collateral. Under-reporting was the
    ///         safe direction while a BOOLEAN lock covered every residue shape —
    ///         but once the number sets the price, "biased low" IS the skim:
    ///         a depositor mints against a price missing the LP leg, sweeps it
    ///         in, and takes the difference. Pricing can only replace the lock
    ///         where the value is knowable, so the lock is kept exactly where it
    ///         is not, and nowhere else.
    ///
    ///         Bounded, unlike the lock this replaced: every unvaluable shape is
    ///         unwindable by the permissionless `sweep()` (burning an LP
    ///         position always returns its tokens — there is no illiquid market
    ///         to wait on), and `releaseUnconvertible` hands off whatever cannot
    ///         be swapped, after which the strategy holds nothing and the flag
    ///         clears.
    uint256 private _unvaluedCount;

    /// @notice The proposal a settled strategy belongs to, so a late arrival can
    ///         be routed to the redeem cohort that exited at its stamp.
    /// @dev    Recorded at settlement, where the id is in hand.
    ///         `collectResidue` is keyed by STRATEGY (the address it must sweep)
    ///         while the cohort is keyed by PROPOSAL (the stamp it was priced
    ///         at), and this is the only place both are known at once.
    mapping(address strategy => uint256) private _residuePid;

    /// @notice What each strategy currently contributes to `_residueTotal` — its
    ///         outstanding value LESS the exiting cohort's share of it.
    ///
    ///         `_residueTotal` prices MINTS, and after a cohort is owed part of
    ///         a residue only the remainder will ever reach the pool a new
    ///         depositor is buying into. Pricing the gross figure would charge
    ///         them for value routed to somebody else — finding #3's shape
    ///         flipped, an over-charged depositor instead of an under-paid
    ///         redeemer.
    ///
    ///         Stored rather than recomputed so a clear subtracts EXACTLY what a
    ///         record added. Re-deriving the cohort fraction at clear time would
    ///         drift if the queue read ever degraded in between, and a drifting
    ///         subtraction on the figure that prices every mint is not a bug
    ///         anyone would find quickly.
    mapping(address strategy => uint256) private _residueNet;

    /// @notice When `_unvaluedCount` last went from zero to nonzero, or 0 while
    ///         it is zero. Read by `depositsLocked` to bound the lock in time.
    ///
    ///         WHY THE LOCK NEEDS AN EXPIRY. Every other probe result here fails
    ///         OPEN precisely because a permanent lock is worse than the
    ///         suppression it guards — `_recordResidue`'s own natspec spells
    ///         that out for a CODELESS label. The unvalued flag was the one
    ///         exception, and the codeless short-circuit does not cover the case
    ///         that matters: a label WITH code that simply answers
    ///         `hasUnvaluedResidue() -> 1` forever. `_refreshUnvalued` only ever
    ///         clears on a truthful zero, `collectResidue` force-clears only for
    ///         a codeless address, and the count is vault-wide so no later
    ///         settlement displaces it the way `_lastSettledStrategy` did. That
    ///         is a permanent, vault-wide deposit DoS with no permissionless
    ///         exit and no owner override — reachable by any registered agent
    ///         who can carry one proposal to Settled, since `propose` stores
    ///         `strategy` unvalidated.
    ///
    ///         WHY EXPIRY IS THE RIGHT SHAPE, and cheap. A CONFORMING strategy
    ///         clears this flag quickly: as `_unvaluedCount` documents, every
    ///         unvaluable shape is unwindable by the permissionless `sweep()`
    ///         and `releaseUnconvertible` hands off the rest. A flag still
    ///         standing after `UNVALUED_MAX_LOCK` therefore means the label is
    ///         not conforming — broken or hostile — which is exactly the case
    ///         where holding the lock forever buys nothing. The trade is stated,
    ///         not hidden: past the deadline a genuinely unvaluable residue
    ///         stops blocking mints, so a depositor could enter against a NAV
    ///         missing it. Bounded mispricing beats an unliftable lock, which is
    ///         this contract's stated doctrine everywhere else, and it is the
    ///         "timeout backstop" issue #233 already points at.
    ///
    ///         EARLIEST MARK WINS. One slot rather than per-strategy expiry: the
    ///         count is almost always 0 or 1, and an attacker who can mark once
    ///         can mark repeatedly, so per-strategy deadlines would let a
    ///         sequence of labels hold the lock indefinitely anyway. Dating the
    ///         lock from its first mark bounds the whole episode.
    uint256 private _unvaluedSince;

    /// @notice Strategies whose unvalued mark has already been pruned after
    ///         lapsing, and which may therefore never set it again.
    ///
    ///         WITHOUT THIS, THE PRUNE IS A RENEWABLE LOCK. `_refreshUnvalued`
    ///         re-reads the label on every `collectResidue` and every
    ///         settlement, and a hostile label keeps answering TRUE forever. So
    ///         a prune that only cleared the flag would hand ANYONE a lever:
    ///         call `collectResidue(liar)`, the mark returns as a fresh 0 -> 1,
    ///         `_unvaluedSince` re-stamps, and the vault is shut for another
    ///         `UNVALUED_MAX_LOCK` — permissionlessly, for free, forever. That
    ///         is strictly worse than the DoS the expiry was added to bound.
    ///
    ///         ONE STRATEGY GETS ONE EPISODE, which is the whole rule. A label
    ///         that held the gate for its full window has spent its claim on
    ///         the vault's trust; if it really still holds unvaluable value,
    ///         that is now a priced-at-zero receivable like any other, not a
    ///         reason to keep refusing deposits. A conforming strategy never
    ///         reaches a prune at all, since `sweep()` and
    ///         `releaseUnconvertible` clear it inside the window.
    ///
    ///         PER STRATEGY, NOT VAULT-WIDE, so an attacker burning its own
    ///         label cannot disarm the gate for anyone else's: the next
    ///         strategy to mark is a genuine 0 -> 1 with a fresh deadline. A
    ///         clone cannot settle twice (`BaseStrategy.execute` requires
    ///         `State.Pending`), so repeating the grief costs a fresh clone and
    ///         a fresh proposal carried to Settled, every window, forever.
    mapping(address strategy => bool) private _unvaluedBurned;

    /// @notice When each strategy's own unvalued mark was set, or 0 while it
    ///         carries none. Read ONLY by `pruneUnvaluedMark`.
    ///
    ///         TWO CLOCKS, BECAUSE THERE ARE TWO QUESTIONS. `_unvaluedSince`
    ///         answers "how long may the vault stay shut", and dating it from
    ///         the episode's FIRST mark is what stops a sequence of hostile
    ///         labels from holding the gate indefinitely. This one answers "has
    ///         THIS label spent its episode", and it has to be per-strategy
    ///         because the prune it authorizes is per-strategy and permanent.
    ///
    ///         READING THE GLOBAL CLOCK FOR A PER-STRATEGY BURN WAS THE BUG. A
    ///         strategy that marks late inside somebody else's episode inherits
    ///         that episode's deadline — correctly, for the deposit gate — and
    ///         the prune then treated the inherited deadline as proof that THIS
    ///         label had had its window. An honest strategy marking one second
    ///         before the running deadline was burnable two seconds later,
    ///         having had three seconds. Since `_refreshUnvalued` refuses to
    ///         re-mark a burned label, its genuinely unvaluable residue then
    ///         stops gating deposits for the vault's life — which is finding
    ///         #3's skim made permanent, reachable with no attacker at all by
    ///         two strategies settling inside one window.
    ///
    ///         So the deposit lock keeps the earliest-mark-wins rule and the
    ///         burn does not. An attacker can still truncate how long the vault
    ///         stays SHUT (that is the deliberate anti-restart trade), but can
    ///         no longer use their own expiry to spend someone else's episode.
    ///
    ///         FALLS BACK TO `_unvaluedSince` when unset, so a mark that
    ///         predates this field is governed by the episode clock rather than
    ///         by zero — the difference between "prunable on the old rule" and
    ///         "prunable immediately". Unreachable today (no vault proxy is
    ///         live; see `__gap`), and cheap insurance if that ever changes.
    mapping(address strategy => uint256) private _unvaluedMarkedAt;

    /// @notice The `CallSandbox` implementation this vault clones per proposal.
    ///         Factory-only and SET-ONCE, exactly like `_withdrawalQueue`.
    /// @dev    The adversary is an owner who re-points the code the vault mints
    ///         AFTER guardians have approved proposals on the strength of what
    ///         that code does — the sandbox's confinement properties are what
    ///         make an unreviewed target safe to call, so they must not be
    ///         swappable behind a review. Unrepeatable rather than merely
    ///         owner-gated; replacing it is a redeployment.
    ///
    ///         Zero is legal and means the sandbox path is simply absent, which
    ///         is the posture of any deployment that does not wire one.
    address private _sandboxImplementation;

    /// @notice The sandbox minted for a proposal, if any. Recorded so the
    ///         residue machinery can reach it after settlement.
    /// @dev    One per proposal, enforced at mint: a second sandbox for the same
    ///         id would overwrite the first while it still held capital, orphan
    ///         it from `collectResidue`, and strand whatever it holds.
    mapping(uint256 pid => address) private _proposalSandbox;

    /// @dev Reserved storage for future upgrades. Shrinks whenever a new state
    ///      variable is added above. Grown from 28 → 31 slots: this deletion
    ///      frees `_laneALockPid` (1), `_interimNetFlow` (1), and
    ///      `_crystallizedMgmt`+`_crystallizedPerf` (1, shared) — legal only
    ///      because no vault proxy is live (see design.md "Deployment reality").
    ///      Back to 24: `_residueAmount`, `_residueTotal`, `_residueCap`,
    ///      `_residueUnvalued`, `_unvaluedCount`, `_residuePid` and `_residueNet`
    ///      take one each, replacing the single `_lastSettledStrategy` slot.
    ///      23: `_unvaluedSince` takes one more.
    ///      22: `_unvaluedBurned` takes one more.
    ///      21: `_unvaluedMarkedAt` takes one more.
    ///      Now 19: `_sandboxImplementation` and `_proposalSandbox` take one each.
    uint256[19] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams memory p) external initializer {
        if (p.owner == address(0)) revert InvalidOwner();
        if (p.executorImpl == address(0)) revert InvalidExecutorImpl();
        // NOTE: agentRegistry can be address(0) on chains without ERC-8004

        __ERC4626_init(IERC20(p.asset));
        __ERC20_init(p.name, p.symbol);
        __EIP712_init(p.name, "1");
        __Ownable_init(p.owner);
        __Pausable_init();

        _executorImpl = p.executorImpl;
        _expectedExecutorCodehash = p.executorImpl.codehash;
        _openDeposits = p.openDeposits;
        _agentRegistry = IERC721(p.agentRegistry);
        _managementFeeBps = p.managementFeeBps;
        // _agentFeeBpsPlusOne left 0 (unset) → agentFeeBps() returns the
        // FeeConstants.DEFAULT_AGENT_FEE_BPS (20%) default until the owner calls
        // setAgentFeeBps (no init SSTORE needed).
        _factory = msg.sender;
        _cachedDecimalsOffset = IERC20Metadata(p.asset).decimals();
    }

    // ==================== DEPOSITOR WHITELIST ====================

    /// @inheritdoc ISyndicateVault
    /// @dev Body delegatecalled to `SyndicateVaultAdminLib` for EIP-170 headroom;
    ///      `onlyOwner` stays on the wrapper so access control is unchanged.
    function approveDepositor(address depositor) external onlyOwner {
        SyndicateVaultAdminLib.approveDepositor(_approvedDepositors, depositor);
    }

    /// @inheritdoc ISyndicateVault
    function removeDepositor(address depositor) external onlyOwner {
        SyndicateVaultAdminLib.removeDepositor(_approvedDepositors, depositor);
    }

    /// @inheritdoc ISyndicateVault
    function approveDepositors(address[] calldata depositors) external onlyOwner {
        SyndicateVaultAdminLib.approveDepositors(_approvedDepositors, depositors);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Whether `depositor` may receive shares while the vault is in
    ///         closed-deposit mode.
    /// @dev The whitelist check in `_deposit` runs against `receiver` — the share
    ///      holder — NOT `caller`, the asset payer. A whitelisted user can
    ///      therefore receive shares funded by a non-whitelisted party
    ///      (pay-on-behalf), intentional for KYC flows where compliance attaches
    ///      to the share holder. Checking both sides would break subsidised
    ///      onboarding, so it is not the default.
    function isApprovedDepositor(address depositor) external view returns (bool) {
        return _approvedDepositors.contains(depositor);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Paginated slice of the approved-depositor set; `limit` is
    ///      hard-clamped to `MAX_PAGE_LIMIT`.
    function approvedDepositorsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return SyndicateVaultAdminLib.pageAddresses(_approvedDepositors, offset, limit);
    }

    /// @inheritdoc ISyndicateVault
    function setOpenDeposits(bool open) external onlyOwner {
        _openDeposits = open;
        emit OpenDepositsUpdated(open);
    }

    /// @inheritdoc ISyndicateVault
    function openDeposits() external view returns (bool) {
        return _openDeposits;
    }

    // ==================== VIEWS ====================

    /// @inheritdoc ISyndicateVault
    function getAgentCount() external view returns (uint256) {
        return _agentSet.length();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Paginated slice of the registered-agent set. `limit` is
    ///      hard-clamped to `MAX_PAGE_LIMIT` so the call always fits in a
    ///      block regardless of how many agents are registered. Callers
    ///      iterate: start at `offset = 0`, advance by `limit` each call
    ///      until the returned array is shorter than `limit`.
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return SyndicateVaultAdminLib.pageAddresses(_agentSet, offset, limit);
    }

    /// @inheritdoc ISyndicateVault
    function isAgent(address agentAddress) external view returns (bool) {
        return _agents[agentAddress].active;
    }

    /// @inheritdoc ISyndicateVault
    function factory() external view returns (address) {
        return _factory;
    }

    // ==================== ADMIN ====================

    /// @inheritdoc ISyndicateVault
    /// @dev ERC-8004 NFT ownership is verified AT REGISTRATION TIME ONLY. If the
    ///      `agentId` NFT is later transferred, the registered `agentAddress`
    ///      retains its privileges until the owner calls `removeAgent`.
    ///      Re-querying on every execution would add a per-call external view to
    ///      the hot path and hard-couple the vault to an external registry;
    ///      off-chain monitoring should trigger `removeAgent` instead.
    function registerAgent(uint256 agentId, address agentAddress) external onlyOwner {
        SyndicateVaultAdminLib.registerAgent(_agents, _agentSet, agentId, agentAddress, _agentRegistry, owner());
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fully deletes the `_agents[agentAddress]` struct rather than flipping
    ///      `active = false`, so stale `agentId`/`agentAddress` fields cannot be
    ///      silently reused if `registerAgent` is later called for the same slot.
    function removeAgent(address agentAddress) external onlyOwner {
        SyndicateVaultAdminLib.removeAgent(_agents, _agentSet, agentAddress);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Freezes LP flow (`deposit` / `mint` / `withdraw` / `redeem`) AND
    ///         strategy execution (`executeGovernorBatch`). Owner rescue paths
    ///         (`rescueEth` / `rescueERC20` / `rescueERC721`) remain callable so
    ///         the owner can respond to incidents. Rescues are still blocked by
    ///         `redemptionsLocked()` whenever a proposal is active.
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc ISyndicateVault
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Transfers vault ownership to `newOwner` via the factory.
    /// @dev Factory-only, used by `SyndicateFactory.rotateOwner` alongside the
    ///      registry's `transferOwnerStakeSlot`, so the old owner's slashed or
    ///      unstaked position can be rebound to a fresh operator without
    ///      redeploying the vault.
    /// @dev Drains `_agentSet` entirely so an at-cap vault does not brick the new
    ///      owner — 32 dead entries could otherwise be neither re-registered (cap
    ///      blocks) nor purged (`AgentNotActive` blocks `removeAgent`). Snapshots
    ///      via `.values()` first so the in-loop `remove` does not invalidate
    ///      iteration.
    function rotateOwnership(address newOwner) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newOwner == address(0)) revert ZeroAddress();
        SyndicateVaultAdminLib.drainAgents(_agents, _agentSet);
        _transferOwnership(newOwner);
    }

    /// @notice Blocks direct `OwnableUpgradeable` owner rotation. The factory's
    ///         `rotateOwner` is the only legal route — it enforces no active or
    ///         open proposal, owner-stake clear and registry alignment, then calls
    ///         `rotateOwnership` here. The inherited setters would desync factory
    ///         and registry records and, via `renounceOwnership`, permanently
    ///         orphan the vault.
    function transferOwnership(address) public pure override {
        revert NotFactory();
    }

    function renounceOwnership() public pure override {
        revert NotFactory();
    }

    // ==================== WITHDRAWAL QUEUE BINDING ====================

    /// @notice Bind the per-vault `VaultWithdrawalQueue`. Factory-only, set-once.
    /// @dev Called once by `SyndicateFactory.createSyndicate` immediately after init.
    function setWithdrawalQueue(address q) external {
        if (msg.sender != _factory) revert NotFactory();
        if (q == address(0)) revert ZeroAddress();
        if (_withdrawalQueue != address(0)) revert WithdrawalQueueAlreadySet();
        _withdrawalQueue = q;
        emit WithdrawalQueueSet(q);
    }

    /// @inheritdoc ISyndicateVault
    function withdrawalQueue() external view returns (address) {
        return _withdrawalQueue;
    }

    /// @notice Bind the `CallSandbox` implementation this vault clones. Factory-only,
    ///         set-once, mirroring `setWithdrawalQueue` above.
    /// @dev    NO RE-POINTING PATH, deliberately. See `_sandboxImplementation`
    ///         for the adversary: swapping the minted code behind an already
    ///         reviewed proposal would invalidate the confinement argument that
    ///         lets a sandbox call targets nobody allowlisted.
    function setSandboxImplementation(address impl) external {
        if (msg.sender != _factory) revert NotFactory();
        if (impl == address(0)) revert ZeroAddress();
        if (_sandboxImplementation != address(0)) revert SandboxImplementationAlreadySet();
        _sandboxImplementation = impl;
        emit SandboxImplementationSet(impl);
    }

    /// @inheritdoc ISyndicateVault
    function sandboxImplementation() external view returns (address) {
        return _sandboxImplementation;
    }

    /// @inheritdoc ISyndicateVault
    function sandboxOf(uint256 pid) external view returns (address) {
        return _proposalSandbox[pid];
    }

    // ==================== GOVERNOR ====================

    modifier onlyGovernor() {
        if (msg.sender != _getGovernor()) revert NotGovernor();
        _;
    }

    /// @dev Read governor address from factory
    function _getGovernor() internal view returns (address) {
        return ISyndicateFactory(_factory).governorOf(address(this));
    }

    /// @dev Active proposal id binding this vault, read through the governor (0
    ///      when none active). Shared body for the Lane-A lock + async request
    ///      paths. Distinct from `redemptionsLocked` / `_activeStrategy`, which
    ///      additionally guard a zero governor — those keep their own reads.
    function _activePid() private view returns (uint256) {
        return IProposalStatus(_getGovernor()).getActiveProposal();
    }

    /// @dev Proposal id to tag a queued `requestDeposit` with. `_activePid()`
    ///      reads 0 until EXECUTE, but `requestDeposit` opens as soon as ANY
    ///      non-terminal proposal exists, which is earlier. Exactly one top-level
    ///      proposal is ever open on this vault at a time, so the governor's
    ///      monotonic `proposalCount()` already names that open proposal in the
    ///      gap; from EXECUTE onward the two agree.
    /// @dev Deliberately a low-level staticcall, same reasoning as
    ///      `_pricingSupply()`: `proposalCount()` is selector-stable but is not
    ///      declared on `IProposalStatus`, which is intentionally narrowed. A
    ///      missing selector degrades to pid 0 rather than reverting, so a
    ///      nonstandard governor can never brick `requestDeposit`.
    function _openProposalPid() private view returns (uint256) {
        address gov = _getGovernor();
        uint256 active = IProposalStatus(gov).getActiveProposal();
        if (active != 0) return active;
        (bool ok, bytes memory ret) = gov.staticcall(abi.encodeWithSignature("proposalCount()"));
        return (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Every delegatecall re-verifies that `_executorImpl`'s bytecode still
    ///      matches the hash stamped at init, so a factory misconfig or a swapped
    ///      executor address cannot deflect the delegatecall elsewhere. Gated by
    ///      `whenNotPaused`: pausing halts strategy execution alongside LP flow.
    function executeGovernorBatch(
        BatchExecutorLib.Call[] calldata calls,
        uint256[] calldata callCaps,
        uint256 maxNetOutflow
    ) external onlyGovernor nonReentrant whenNotPaused {
        if (_executorImpl.codehash != _expectedExecutorCodehash) {
            revert ExecutorCodehashMismatch();
        }
        _guardBatchCalls(calls);
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        // The lib's unmetered 1-arg `executeBatch(Call[])` overload was
        // deleted in issue #43 §5 — the metered 3-arg signature is the only
        // one left, so `abi.encodeCall` resolves it unambiguously again.
        (bool success, bytes memory returnData) =
            _executorImpl.delegatecall(abi.encodeCall(BatchExecutorLib.executeBatch, (calls, asset(), callCaps)));
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        // First-class vault-level execution marker. Emitted after the
        // delegatecall succeeds so indexers only see confirmed executions.
        emit GovernorBatchExecuted(msg.sender, calls.length);

        // Honor pending redemptions first: a strategy execution may not deploy
        // float reserved for already-settled, unclaimed redeem claims, so a
        // later proposal cannot strand them. Settle batches return float and
        // pass trivially; an execute batch that over-deploys reverts here.
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        // Custody-level net-outflow ceiling. Inflow batches (settle) pass
        // trivially; the governor passes the proposal's maxCapital on execute,
        // settlement and emergency paths, and honest unwinds are net-inflow, so
        // the finite cap never binds them.
        //
        // This is a COARSE custody cap — it meters the vault's own `asset()`
        // balance delta, so capital deployed INTO an allowlisted adapter counts as
        // outflow the same as an extraction. What it GUARANTEES holds only
        // TOGETHER with `_guardBatchCalls`: the meter bounds the `asset()` a
        // single batch moves out of custody, and the guard closes the
        // balance-invisible exfiltration routes — the callee gate (any target that
        // is neither `asset()` nor allowlisted is refused) plus the retained
        // selector checks beneath it. The precise extractable bound is the tier
        // system's per-call coverage.
        //
        // TWO LAYERS, finest to coarsest:
        //   1. `BatchExecutorLib.executeBatch`'s per-call meter: each call's gross
        //      outflow against its proposer-declared `caps[i]`.
        //   2. This function's `netOutflow` check: a batch-wide backstop against
        //      `maxCapital`. When caps cover every moving call, layer 1 is
        //      strictly tighter, so layer 2 only binds when caps are empty (the
        //      emergency-rescue escape valve) or sum right up to `maxCapital`.
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > maxNetOutflow) revert MaxNetOutflowExceeded(netOutflow, maxNetOutflow);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        // Idle-liquidity floor: a batch may deploy at most (1 − minBufferBps)
        // of the pre-batch float. Inflow (settle) batches pass trivially.
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();
    }

    /// @notice Governor-only: mint this proposal's sandbox, fund it with exactly
    ///         `funding`, and dispatch its stored calls.
    /// @dev    THE SECOND ASSET-MOVING PATH THAT DOES NOT PASS `_guardBatchCalls`,
    ///         and it does not need to. The batch guard exists because a batch
    ///         runs under `delegatecall`, so a sub-call reaches its target AS THIS
    ///         VAULT — able to spend our allowances, move our position tokens, and
    ///         satisfy any `msg.sender == vault` gate. A sandbox call carries the
    ///         SANDBOX's identity and can spend only the balance handed to it
    ///         here, so the callee's identity stops being load-bearing and the
    ///         most a hostile call set costs is `funding` — precisely what
    ///         full-notional tier-2 coverage already charged for.
    ///
    ///         AUTHORIZATION IS `onlyGovernor` AND NOTHING ELSE, the same posture
    ///         `settleRedeem`/`settleDeposit` take toward the queue. The adversary
    ///         is any second caller: this moves vault assets to a fresh contract
    ///         without the callee gate, so it must be reachable only through a
    ///         proposal that cleared the vote, the guardian review period and the
    ///         coverage quorum.
    ///
    ///         PUSH, NEVER APPROVE-AND-PULL. An allowance would be a standing
    ///         authorization whose size proposer calldata could choose, which is
    ///         the "authorization meters zero" failure this whole mechanism
    ///         exists to avoid, reproduced at the funding step. Nothing here ever
    ///         grants the sandbox an allowance against this vault.
    ///
    ///         ONE SANDBOX PER PROPOSAL. A second mint for the same id would
    ///         overwrite the recorded address while the first still held capital,
    ///         orphaning it from `collectResidue`.
    /// @return sandbox The address minted for `pid`.
    function runSandbox(
        uint256 pid,
        ICallSandbox.Call[] calldata calls,
        address[] calldata declaredTokens,
        uint256 funding
    ) external onlyGovernor nonReentrant whenNotPaused returns (address sandbox) {
        address impl = _sandboxImplementation;
        if (impl == address(0)) revert SandboxNotConfigured();
        if (_proposalSandbox[pid] != address(0)) revert SandboxAlreadyMinted(pid);

        // THE CEILING IS READ LIVE, not captured at propose. A ceiling tightened
        // between propose and execute must bind, and this is the only read that
        // can see it. Typed call on `msg.sender`, which `onlyGovernor` has
        // already established IS the governor: fail closed, because a governor
        // that cannot price its own tier-2 bound must not be funding arbitrary
        // calldata. The failure is recoverable (the proposal expires with the
        // capital never having left); what it prevents is not.
        uint256 ceiling = (totalAssets() * ISyndicateGovernor(msg.sender).tier2CallCapBps()) / 10_000;
        if (funding > ceiling) revert SandboxFundingExceedsCeiling(funding, ceiling);

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

        // Deterministic so the address is derivable off-chain before execution —
        // guardians reviewing a payload can compute where it will run.
        sandbox = Clones.cloneDeterministic(impl, bytes32(pid));
        _proposalSandbox[pid] = sandbox;
        ICallSandbox(sandbox).init(address(this), calls, declaredTokens);
        if (funding != 0) IERC20(asset()).safeTransfer(sandbox, funding);
        ICallSandbox(sandbox).run();

        // SAME THREE CUSTODY CHECKS `executeGovernorBatch` applies, for the same
        // reasons. `run()` can return assets (a call that swaps back into the
        // vault asset and pushes), so the delta is measured rather than assumed
        // to equal `funding`.
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > funding) revert MaxNetOutflowExceeded(netOutflow, funding);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();

        emit SandboxRun(pid, sandbox, funding);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Wraps `_isPrivilegedBatchTarget` — the same predicate
    ///      `_guardBatchCalls` enforces. Exposed so the governor's
    ///      propose-time validation answers through this one implementation
    ///      instead of restating the address set (vault, bound queue).
    function isPrivilegedBatchTarget(address target) external view returns (bool) {
        return _isPrivilegedBatchTarget(target);
    }

    /// @notice Re-point the shared `BatchExecutorLib` and re-stamp its expected
    ///         codehash, atomically. Reached only through the factory's
    ///         lifecycle-gated `pushExecutor`.
    /// @dev Factory-only. Rejects zero and codeless targets — a swapped-in address
    ///      with no code would pass every future `codehash` check vacuously and
    ///      the next delegatecall would no-op against it, silently disabling batch
    ///      execution instead of failing loudly here.
    function setExecutorImpl(address newImpl) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newImpl == address(0) || newImpl.code.length == 0) revert InvalidExecutorImpl();
        address old = _executorImpl;
        _executorImpl = newImpl;
        _expectedExecutorCodehash = newImpl.codehash;
        emit ExecutorImplSet(old, newImpl);
    }

    /// @dev Two-part batch gate: a privileged-TARGET denylist (Part 1, always
    ///      runs), then the value-moving-SELECTOR allowlist (Part 2,
    ///      registry-dependent). The two are independent — do not collapse them,
    ///      and do not move Part 1 below Part 2's registry lookup.
    ///
    ///      PART 1: PRIVILEGED-TARGET DENYLIST. Selector-guarding is not enough,
    ///      because this adversary needs no value-moving selector at all. The
    ///      batch runs via delegatecall, so every sub-call reaches its target
    ///      carrying `msg.sender == vault` — exactly what the withdrawal queue's
    ///      `onlyVault` gate checks. `queue.queueRedeem(attacker, victimShares,
    ///      pid)` therefore clears that gate and mints the attacker a claim on
    ///      shares the queue already escrows for someone else, while every other
    ///      guard reads it as harmless: the queue's entrypoints move ZERO vault
    ///      `asset()` in-tx (the value leaves later via `queue.claim`), so the
    ///      net-outflow meter, the queue-reserve floor and the buffer floor all
    ///      see nothing, and coverage prices an uncertified target at tier 2 — a
    ///      price a 1-wei proposal buys. Blocked as a target CLASS rather than a
    ///      selector list, so the next privileged queue function is covered by
    ///      default. UNCONDITIONAL, above Part 2's registry staticcall and both of
    ///      its degrade-open returns: a queue steal is not priced, it is theft.
    ///      SCOPE is exactly two addresses — the vault and its bound queue — not a
    ///      target allowlist; adapters' own `onlyVault` entrypoints stay open.
    ///
    ///      PART 1b: transferFrom SOURCE GUARD (LP-ALLOWANCE CONFISCATION). Same
    ///      loop, same unconditional posture, different adversary:
    ///      `asset.transferFrom(victim, vault, victimBal)` spends
    ///      `allowance[victim][vault]` — the very allowance every LP grants to
    ///      deposit, which UIs routinely set to `type(uint256).max`. Every other
    ///      meter is blind: net-outflow reads 0 because the vault's OWN balance
    ///      rises, coverage prices the target against the vault's own maxCapital
    ///      rather than a third party's wallet, and Part 2's
    ///      `to == vault -> continue` exemption passes it outright. `from`
    ///      (calldata bytes 4:36) is decoded here and MUST equal the vault itself.
    ///
    ///      `isAdapterAllowed` is DELIBERATELY NOT CONSULTED as a source
    ///      allowlist: it encodes DESTINATION consent, not permission to spend an
    ///      address's allowances to the vault. No honest batch pulls FROM a
    ///      non-vault address — capital deploys via `approve(adapter)` plus the
    ///      adapter pulling in its own code, and returns are pushes.
    ///      `from == address(this)` stays permitted: it is semantically
    ///      `transfer(x, amt)`, and `x` remains destination-guarded by Part 2.
    ///
    ///      PART 2a: THE CALLEE GATE (outer boundary). Runs on every call, before
    ///      any selector is examined, and refuses any callee that is neither
    ///      `asset()` nor TierRegistry-allowlisted — closing the
    ///      unenumerable-selector class that repeated rounds of selector
    ///      enumeration kept failing to cover.
    ///
    ///      PART 2b: VALUE-MOVING-SELECTOR ALLOWLIST (inner boundary). The
    ///      net-outflow meter only sees the vault's own `asset()` balance delta,
    ///      so `token.approve(attacker, max)` meters zero while the attacker
    ///      drains via `transferFrom` in a later tx. Gating the spender/recipient
    ///      of the guarded selectors bounds ERC20 exfiltration over the
    ///      now-finite set of allowlisted callees: for approve /
    ///      increaseAllowance / transfer the guarded address is arg 1 (bytes
    ///      4:36); for transferFrom (legacy and Permit2) and DSToken `move` it is
    ///      `to`, arg 2 (bytes 36:68); for Permit2 `approve` it is `spender`, ALSO
    ///      arg 2, since Permit2's extra leading `token` arg shifts it one slot
    ///      right of legacy `approve`. The address must be the vault itself (with
    ///      the `asset()` exception below) or a TierRegistry-allowlisted adapter.
    ///      Runs on every governor batch, settlement included.
    ///
    ///      SELF-TRANSFER FAST-PATH SCOPED TO `asset()`: `recipient ==
    ///      address(this) -> continue` would otherwise skip the registry check for
    ///      ANY token whose destination decodes to the vault, not only the one
    ///      token the outer balance-diff meter independently verifies — letting a
    ///      non-standard token execute arbitrary logic under
    ///      `transferFrom(vault, vault, amount)` with zero verification anywhere.
    ///      The fast-path therefore additionally requires
    ///      `calls[i].target == asset()`.
    ///
    ///      RESIDUALS. (a) Exotic assets — ERC721 `setApprovalForAll`, ERC1155,
    ///      LP-position NFTs — are refused as callees by default under PART 2a,
    ///      closing the whole class including standards never enumerated here. If
    ///      one is ever allowlisted anyway its non-ERC20 selectors pass this
    ///      switch unexamined, so the operator invariant is: exotic-asset
    ///      contracts MUST NOT be allowlisted as batch callees. (b) Coverage is
    ///      PER-SELECTOR, NOT PER-ROUTER — do not read Permit2/DSToken/ERC1363 as
    ///      guarded routers; only the enumerated selectors are, within the set of
    ///      callees PART 2a admits. ERC-777 `operatorSend` and any other
    ///      unenumerated router shape still pass unexamined on an allowlisted
    ///      target. (c) Both parts trust calldata pattern-matching over verified
    ///      balance movement for every token except `asset()`. (d) The
    ///      self-transfer fast-path is structurally unreachable for
    ///      Permit2-routed selectors, since a Permit2 call's target is the Permit2
    ///      singleton — this fails CLOSED, so it is a possible over-restriction,
    ///      not a fund-safety gap.
    ///
    ///      UNSET REGISTRY — FAILS CLOSED (pashov finding #1). With no registry
    ///      wired (or a governor predating the getter), PART 2 cannot run. This
    ///      used to RETURN, dropping the callee allowlist, the spender/recipient
    ///      gate and the `UnrecognizedAssetSelector` branch — not a pricing-only
    ///      degradation and not "by design": `asset.approve(attacker, max)` moves
    ///      zero balance, so every meter reads zero, and licenses an unbounded
    ///      pull in a LATER transaction. It now reverts
    ///      `TierRegistryUnresolved`, matching `PortfolioStrategy`,
    ///      `MorphoSupplyStrategy` and `ConcentratedLiquidityStrategy`, which
    ///      already fail closed on the same walk.
    ///
    ///      LIVENESS COST, ACCEPTED: a governor that IS registry-less has its
    ///      batches — `settleProposal` / `unstick` / every exit — reverting until
    ///      the factory owner calls `pushWiring(governor)`. That state is
    ///      unreachable for anything this factory deploys (mandatory
    ///      `SyndicateFactory.InitParams.tierRegistry`, mandatory
    ///      `SyndicateGovernor.initialize` arg, and `setTierRegistry` refusing
    ///      zero and codeless), so only governors predating those checks can hit
    ///      it, and for them a one-call rewire is preferable to running the
    ///      allowlist-free window the finding describes.
    ///
    ///      PART 1 IS NOT AFFECTED: it needs no registry and sits above the
    ///      resolve. Pinned by `test_targetGate_bitesEvenWithNoTierRegistryWired`
    ///      and `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter`, so
    ///      relocating Part 1 below the resolve converts a privileged-callee
    ///      rejection into the registry error and fails a test.
    function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
        // PRIVILEGED-CALLEE GATE, ahead of everything else.
        //
        // The batch runs under delegatecall, so every call carries
        // `msg.sender == vault`. For the QUEUE that is decisive: its `onlyVault`
        // gate is satisfied by a batch that merely names it as a target.
        //
        // For the VAULT the reason is different, and worth stating precisely so
        // nobody re-permits it on a wrong premise. `msg.sender == vault` does NOT
        // open this contract's self-gated functions — `settleRedeem`/
        // `settleDeposit` require the queue, and it satisfies neither `onlyOwner`,
        // `onlyGovernor` nor the factory gate. The exposure is the PERMISSIONLESS
        // surface instead, chiefly `requestDeposit`: a batch naming the vault can
        // escrow the vault's own float into the queue while directing the
        // resulting deposit claim to an attacker. That one IS metered — the float
        // genuinely leaves — so blocking the vault is defense-in-depth rather than
        // a second live hole; it removes the standing dependency on no
        // permissionless entrypoint ever becoming dangerous to call as ourselves.
        //
        // No other meter catches the queue case. `queue.queueRedeem(attacker,
        // victimShares, pid)` mints a redeem claim against shares another owner
        // escrowed while moving ZERO `asset()`, the value leaves in a LATER
        // transaction via `queue.claim` which nothing meters, and coverage prices
        // an uncertified target at tier 2 — a 1-wei proposal any single approver
        // clears.
        //
        // BEFORE THE REGISTRY LOOKUP, DELIBERATELY. The selector guard below
        // returns early for a governor with no registry, and that exemption is a
        // documented default for PRICING a call — not for refusing a capability.
        //
        // A TARGET CLASS, NOT A SELECTOR LIST: enumerating today's privileged
        // functions would leave the next one unprotected, and nothing a batch
        // legitimately does names these two addresses. `stampSettlement` shows why
        // breadth matters — it is one-shot per pid, so one batch can pre-burn the
        // settlement slot of proposals that have not happened yet.
        for (uint256 i = 0; i < calls.length; i++) {
            address target = calls[i].target;
            if (_isPrivilegedBatchTarget(target)) {
                revert DisallowedBatchTarget(target);
            }
            // `transferFrom` SOURCE guard — unconditional, same pass, same
            // rationale as the target denylist. Covers legacy `transferFrom` AND
            // every alternate-signature pull-via-delegated-allowance selector this
            // guard recognizes; all place the debited source at bytes 4:36.
            bytes calldata data = calls[i].data;
            if (data.length >= 4) {
                bytes4 sel = bytes4(data[0:4]);
                if (
                    sel == _SEL_TRANSFER_FROM || sel == _SEL_PERMIT2_TRANSFER_FROM || sel == _SEL_DSTOKEN_PULL
                        || sel == _SEL_DSTOKEN_MOVE || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL
                        || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA
                ) {
                    if (data.length < 68) revert MalformedCall();
                    address from = address(uint160(uint256(bytes32(data[4:36]))));
                    if (from != address(this)) revert DisallowedTransferFromSource(target, from);
                } else if (sel == _SEL_PERMIT2_BATCH_TRANSFER_FROM) {
                    // Dynamic array, not a fixed-offset slice: decode every element
                    // and require each one's `from` to be the vault, per-element
                    // instead of once. `abi.decode` always returns memory for
                    // dynamic types, which is fine here since it is only read.
                    if (data.length < 36) revert MalformedCall();
                    _Permit2BatchDetail[] memory details = abi.decode(data[4:], (_Permit2BatchDetail[]));
                    for (uint256 j = 0; j < details.length; j++) {
                        if (details[j].from != address(this)) {
                            revert DisallowedTransferFromSource(target, details[j].from);
                        }
                    }
                } else if (sel == _SEL_ERC4626_WITHDRAW || sel == _SEL_ERC4626_REDEEM) {
                    // `owner` (the debited source) is arg 2 (bytes 68:100),
                    // not arg 0 like every other guarded selector above —
                    // OZ's ERC4626 `_withdraw` spends `owner`'s allowance to
                    // `caller` (the vault) exactly like `transferFrom` spends
                    // `from`'s.
                    if (data.length < 100) revert MalformedCall();
                    address ownerArg = address(uint160(uint256(bytes32(data[68:100]))));
                    if (ownerArg != address(this)) revert DisallowedTransferFromSource(target, ownerArg);
                }
            }
        }

        // onlyGovernor holds, so msg.sender IS the governor. staticcall (not a
        // typed call) so a governor without the getter resolves to "unset"
        // HERE rather than reverting in this frame with empty returndata, which
        // would be indistinguishable from a bug in the guard itself. Either way
        // the outcome is the same refusal — only the error is legible.
        (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
        if (!ok || ret.length != 32) revert TierRegistryUnresolved();
        address registry = abi.decode(ret, (address));
        if (registry == address(0)) revert TierRegistryUnresolved();

        address asset_ = asset();
        for (uint256 i = 0; i < calls.length; i++) {
            // ── PART 2a: target-based callee gate (issue #166, Option B) ──
            // Runs on EVERY call — before the short-calldata continue below, so
            // empty-calldata and native-`value` calls are gated too. asset() is
            // the sole exemption (design.md Decision 2); everything else must be
            // an allowlisted, codehash-current adapter.
            //
            // READS THE CALLEE AXIS (`isCallableTarget`), NOT `isAdapterAllowed`
            // (pashov finding #14). The two used to be one registry bit, so a
            // demotion — reachable permissionlessly, since `ChallengeGame.file`
            // only needs the pair to appear in the executed proposal's calldata,
            // and every execute batch names `(clone, execute.selector)` — revoked
            // the vault's ability to CALL the very clone holding its capital.
            // `settleProposal`, `unstick` and `finalizeEmergencySettle` all
            // reverted here, the proposal pinned in `Executed`, and every LP exit
            // shut. The recipient/spender checks in PART 2b still read
            // `isAdapterAllowed`, so a demoted clone remains reclaimable but
            // unfundable. No lifecycle state is grandfathered: this stays one
            // unconditional rule, evaluated per call, exactly as before.
            address target = calls[i].target;
            if (target != asset_ && !ITierRegistry(registry).isCallableTarget(target)) {
                revert DisallowedBatchCallee(target);
            }
            bytes calldata data = calls[i].data;
            // ── PART 2b: value-moving-selector checks (retained, unchanged) ──
            if (data.length < 4) continue;
            bytes4 sel = bytes4(data[0:4]);
            address recipient;
            if (
                sel == _SEL_APPROVE || sel == _SEL_INCREASE_ALLOWANCE || sel == _SEL_TRANSFER
                    || sel == _SEL_DSTOKEN_PUSH || sel == _SEL_ERC1363_APPROVE_AND_CALL
                    || sel == _SEL_ERC1363_APPROVE_AND_CALL_DATA || sel == _SEL_ERC1363_TRANSFER_AND_CALL
                    || sel == _SEL_ERC1363_TRANSFER_AND_CALL_DATA
            ) {
                // DSToken push(dst, wad) is transfer's sibling — dst at arg 1
                // (bytes 4:36), same as _SEL_TRANSFER. ERC1363 approveAndCall
                // (+data) is approve's sibling, and transferAndCall(+data) is
                // transfer's sibling — spender/to at arg 1, same offset,
                // trailing args (amount/bytes) unread and irrelevant.
                if (data.length < 36) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[4:36]))));
            } else if (
                sel == _SEL_TRANSFER_FROM || sel == _SEL_PERMIT2_TRANSFER_FROM || sel == _SEL_DSTOKEN_MOVE
                    || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA
            ) {
                // Legacy/Permit2 transferFrom, DSToken move, and ERC1363
                // transferFromAndCall (+data) all place `to`/`dst` at arg 2
                // (bytes 36:68) — ERC1363's trailing `bytes` overload adds a
                // 4th arg AFTER `amount`, so it does not shift this offset.
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_PERMIT2_APPROVE) {
                // Permit2's `approve(token, spender, uint160, uint48)` carries
                // an extra leading `token` arg vs legacy `approve(spender,
                // amount)`, shifting the guarded `spender` to arg 2 (bytes
                // 36:68) instead of arg 1 (bytes 4:36).
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_ERC4626_WITHDRAW || sel == _SEL_ERC4626_REDEEM) {
                // `receiver` is arg 1 (bytes 36:68); `owner` (already
                // source-checked in Part 1b above) is arg 2 and irrelevant
                // here — same offset as the transferFrom-shaped group above,
                // kept as its own branch since the source check that landed
                // it here uses a different offset (arg 2, not arg 0).
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_PERMIT2_BATCH_TRANSFER_FROM) {
                // Dynamic array: apply the exact same per-element fast-path
                // and registry check the single-recipient path below applies
                // once, but once per element, then fall through to the next
                // batch call — this selector never sets the shared
                // `recipient` local.
                if (data.length < 36) revert MalformedCall();
                _Permit2BatchDetail[] memory details = abi.decode(data[4:], (_Permit2BatchDetail[]));
                for (uint256 j = 0; j < details.length; j++) {
                    address to = details[j].to;
                    if (to == address(this) && calls[i].target == asset_) continue;
                    if (!ITierRegistry(registry).isAdapterAllowed(to)) {
                        revert DisallowedTransferTarget(calls[i].target, sel, to);
                    }
                }
                continue;
            } else {
                // UNRECOGNIZED SELECTOR ON THE ONE EXEMPT TARGET.
                //
                // PART 2a lets `asset()` through without an allowlist check, on
                // the premise that the outer `netOutflow` meter independently
                // verifies it via a balance diff. A balance diff sees VALUE
                // MOVEMENT; it does not see an AUTHORIZATION grant. ERC-777
                // `authorizeOperator` — and any allowance-delegation shape not
                // enumerated above — moves zero balance in-batch and licenses an
                // unbounded pull in a LATER transaction, after every meter here
                // has passed. Nothing downstream catches it either: declared at
                // cap 0, `requiredCoverage` prices to 0, so no guardian books
                // coverage, no proposer bond is locked, and `ChallengeGame.file`
                // reverts on the empty approver set — the proposal is
                // unchallengeable.
                //
                // Scoped deliberately to `asset()`: every other target already
                // cleared PART 2a's allowlist, and the terminal `continue` is
                // load-bearing for them, since ordinary batch calls carry
                // selectors this switch should not enumerate. The standard ERC-20
                // READS are carved out: a closed, enumerable set that grants
                // nothing and that batches legitimately call on `asset()`.
                if (target == asset_ && !_isBenignAssetRead(sel)) {
                    revert UnrecognizedAssetSelector(sel);
                }
                continue;
            }
            // Self-transfer fast-path is scoped to asset() ONLY: it is the
            // one token the outer `netOutflow` meter in `executeGovernorBatch`
            // independently verifies via a balance diff. Any other token
            // whose destination decodes to the vault still routes through the
            // TierRegistry check below — see the "SELF-TRANSFER FAST-PATH
            // SCOPED TO asset()" note above.
            if (recipient == address(this) && calls[i].target == asset_) continue;
            if (!ITierRegistry(registry).isAdapterAllowed(recipient)) {
                revert DisallowedTransferTarget(calls[i].target, sel, recipient);
            }
        }
    }

    /// @dev The standard ERC-20 view selectors, which a governor batch may
    ///      legitimately call on `asset()` and which cannot grant, move or
    ///      delegate anything. An explicit carve-out from the
    ///      unrecognized-selector rejection above, so that rejection stays pointed
    ///      at state-changing selectors on the one target that skips PART 2a.
    ///      Deliberately excludes `approve`/`transfer`/`transferFrom` and their
    ///      siblings, which are gated on their spender/recipient above.
    function _isBenignAssetRead(bytes4 sel) private pure returns (bool) {
        return sel == 0x70a08231 // balanceOf(address)
            || sel == 0x313ce567 // decimals()
            || sel == 0x18160ddd // totalSupply()
            || sel == 0xdd62ed3e // allowance(address,address)
            || sel == 0x95d89b41 // symbol()
            || sel == 0x06fdde03; // name()
    }

    /// @dev The single implementation of the privileged-batch-target
    ///      predicate — the vault itself, or the bound withdrawal queue.
    ///      `_guardBatchCalls`'s Part 1 loop and the external
    ///      `isPrivilegedBatchTarget` view are its only two callers; neither
    ///      may restate the address set (see the class-not-list rationale in
    ///      `_guardBatchCalls`'s doc comment above).
    function _isPrivilegedBatchTarget(address target) private view returns (bool) {
        address q = _withdrawalQueue;
        return target == address(this) || (q != address(0) && target == q);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev THE QUEUE RESERVE IS NOT SPENDABLE HERE. This was the one
    ///      asset-outflow path that checked only the raw balance, so a settlement
    ///      fee — or a later `claimUnclaimedFees` — could spend float already
    ///      frozen against stamped-unclaimed redeems, leaving the second
    ///      claimant's `settleRedeem` to revert with no `cancel` available to it.
    ///      Reverting is the safe direction, not a lost fee: the governor's
    ///      `_payFee` already treats a failure here as escrow-it-instead.
    function transferPerformanceFee(address asset_, address to, uint256 amount) external onlyGovernor {
        if (asset_ != asset()) revert InvalidAsset();
        if (to == address(0)) revert ZeroAddress();
        uint256 spendable = IERC20(asset_).balanceOf(address(this));
        // BOTH LIABILITIES, not just the queue's (pashov 2026-08 finding #23).
        // `totalAssets()` already treats the vault as owing
        // `reservedQueueAssets() + _escrowedFeeLiability()`; this guard counted
        // only the first, so a later settlement's fee could spend float already
        // booked as an earlier recipient's escrow — after which THEIR
        // `claimUnclaimedFees` reverts `AmountExceedsBalance` with no recovery
        // path, since `_payFee`'s escrow-on-failure is one-shot per settlement.
        //
        // THE CLAIM PATH EXEMPTS ITSELF, STRUCTURALLY — there is no special
        // case here and there must not be one. `claimUnclaimedFees` decrements
        // `_escrowedFees[vault][token]` BEFORE calling this
        // (`SyndicateGovernor.claimUnclaimedFees`), so by the time this runs the
        // liability no longer includes the amount being claimed and the
        // subtraction below leaves exactly enough. Reordering that decrement to
        // after the transfer would brick every escrowed claim.
        //
        // The LP paths (`_availableFloat`, `_withdraw`) deliberately do NOT
        // subtract escrow: `totalAssets()` nets it already, so an LP's share
        // entitlement is reduced by it rather than reserved against it, and
        // double-counting there would refuse withdrawals no liability requires.
        //
        // `_escrowedFeeLiability()` degrades to 0 on an unreadable governor.
        // Stated as a decision: that is the LIVENESS direction on a path whose
        // own failure mode is a lost fee, and it reproduces exactly the
        // pre-existing behaviour rather than inventing a stricter one.
        uint256 reserve = reservedQueueAssets() + _escrowedFeeLiability();
        spendable = spendable > reserve ? spendable - reserve : 0;
        if (amount > spendable) revert AmountExceedsBalance();
        IERC20(asset_).safeTransfer(to, amount);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev The SAME quantity `transferPerformanceFee` tests `amount` against,
    ///      exposed as a view so the governor can size an escrow it is about to
    ///      book instead of discovering the ceiling by reverting.
    ///
    ///      WHY THIS EXISTS. `SyndicateGovernor._payFee` escrows the full
    ///      requested amount on ANY revert, and one legitimate revert reason is
    ///      `AmountExceedsBalance` — the vault saying "I do not have this." A
    ///      liability booked for that reason is unbacked by construction: it
    ///      flows into `_escrowedFeeLiability()`, which `totalAssets()` subtracts,
    ///      so an escrow exceeding the float pins `totalAssets()` to 0 (zeroing
    ///      every LP's conversion and stamping the settle price at `num == 1`),
    ///      and `claimUnclaimedFees` — which re-requests the SAME full amount —
    ///      then fails the same comparison forever, with `rescueERC20` unable to
    ///      touch the vault asset. A fee cannot exceed the assets it is charged
    ///      against; letting the governor read the ceiling is what keeps the
    ///      distinction between "recipient cannot receive" and "vault cannot pay"
    ///      visible at book time, when it is still actionable.
    function spendableFee(address asset_) external view returns (uint256) {
        if (asset_ != asset()) return 0;
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        uint256 reserve = reservedQueueAssets() + _escrowedFeeLiability();
        return bal > reserve ? bal - reserve : 0;
    }

    /// @inheritdoc ISyndicateVault
    function governor() external view returns (address) {
        return _getGovernor();
    }

    /// @inheritdoc ISyndicateVault
    function owner() public view override(OwnableUpgradeable, ISyndicateVault) returns (address) {
        return super.owner();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fail-closed on missing governor: if the factory is misconfigured
    ///      and `governor() == address(0)`, deposits / withdrawals / rescues
    ///      must NOT silently unlock. Revert instead.
    function redemptionsLocked() public view returns (bool) {
        address gov = _getGovernor();
        if (gov == address(0)) revert GovernorNotSet();
        return IProposalStatus(gov).getActiveProposal() != 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Reads through the governor: the strategy is whatever address the
    ///      proposer set on the active proposal at propose time. Returns
    ///      `address(0)` outside the active window or for queue-only proposals
    ///      (proposer passed `address(0)` to `propose`).
    function activeStrategyAdapter() external view returns (address) {
        return _activeStrategy();
    }

    /// @dev Reads the active proposal's strategy through the governor's scalar
    ///      `strategyOf` getter. Returns `address(0)` when no proposal is active
    ///      OR when the active proposal opted out. Still wrapped in try/catch: an
    ///      `address` return says nothing about EXISTENCE, and the vault (UUPS)
    ///      and governor (beacon) upgrade on independent paths, so a vault impl
    ///      calling `strategyOf` can go live before the governor beacon carries
    ///      it. The only consumer is an off-chain-facing view.
    function _activeStrategy() internal view returns (address) {
        address gov = _getGovernor();
        if (gov == address(0)) return address(0);
        uint256 pid = IProposalStatus(gov).getActiveProposal();
        if (pid == 0) return address(0);
        try IProposalStatus(gov).strategyOf(pid) returns (address strategy) {
            return strategy;
        } catch {
            return address(0);
        }
    }

    /// @inheritdoc ISyndicateVault
    function managementFeeBps() external view returns (uint256) {
        return _managementFeeBps;
    }

    /// @inheritdoc ISyndicateVault
    function agentFeeBps() public view returns (uint256) {
        // One SLOAD: 0 = never set → the 20% default (agent never silently
        // unpaid); otherwise the stored value is fee+1, so an explicit 0%
        // (stored 1) stays distinct from unset.
        uint256 stored = _agentFeeBpsPlusOne;
        return stored == 0 ? FeeConstants.DEFAULT_AGENT_FEE_BPS : stored - 1;
    }

    /// @inheritdoc ISyndicateVault
    function setAgentFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_AGENT_FEE_BPS) revert AgentFeeTooHigh();
        // Offset-by-one: stored = fee+1 marks "set" and keeps an explicit 0%
        // distinct from the unset sentinel (0).
        _agentFeeBpsPlusOne = bps + 1;
        emit AgentFeeUpdated(bps);
    }

    /// @inheritdoc ISyndicateVault
    function setMinBufferBps(uint16 bps) external onlyOwner {
        if (bps > MAX_MIN_BUFFER_BPS) revert BufferTooHigh();
        minBufferBps = bps;
        emit MinBufferUpdated(bps);
    }

    // ==================== OVERRIDES ====================

    /// @dev Resolve diamond between ERC20Upgradeable and ERC20VotesUpgradeable.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);

        // HIGH-WATER MARK RESET ON FULL DRAIN.
        //
        // `_highWaterPricePerShare` is seeded once, at the first mint, and
        // otherwise only ever advances. It was NEVER reset when `totalSupply()`
        // returns to zero, while the ERC-4626 share/asset SCALE is independently
        // re-derived from `(residualAssets + 1)` on the very next deposit. The
        // result: a re-seeding deposit's price-per-share can land at
        // `(residualAssets + 1)x` the STALE mark, and `aboveHighWaterMark` then
        // reads almost the entire new principal as performance-fee base on a
        // zero-P&L re-seed — charged against brand-new capital that never earned a
        // cent. Reaching `totalSupply() == 0 && totalAssets() > 0` is not exotic:
        // redeem-flooring dust, the queue's deliberate dust release,
        // `_unclaimedFees` escrow, or a bare ERC20 donation all leave residual
        // assets behind an empty share supply.
        //
        // Zeroing here, on EVERY burn/mint/transfer that empties supply (this hook
        // is the single OZ chokepoint for all of them), makes the next mint treat
        // the fund as freshly created. A mint in the SAME call as the draining
        // burn is impossible for a single ERC20 `_update`; sequential
        // burn-then-mint across two calls is exactly the case this closes.
        if (totalSupply() == 0) {
            _highWaterPricePerShare = 0;
        }

        // AUTO-DELEGATE ON EVERY RECEIPT. Runs AFTER `super._update` so the
        // recipient's post-receipt balance is what checkpoints. Holders that
        // explicitly delegated away keep their choice.
        //
        // The behaviour is kept because `getPastVotes == balance` is what makes
        // this vault's OWN governance readable: a holder who never calls
        // `delegate` still carries weight, which every snapshot-based read here
        // assumes. Removing it would silently zero the voting weight of every
        // non-delegating holder.
        //
        // The heal is permissionless and needs no action from the holder: it also
        // runs on a zero-value transfer, so anyone can arm a stranded undelegated
        // holder by sending it 0 shares.
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /// @dev Use timestamp-based voting checkpoints instead of block numbers
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev EIP-6372: declare timestamp-based clock
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @dev Resolve decimals diamond between ERC20Upgradeable and ERC4626Upgradeable
    function decimals() public view override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /// @dev Virtual shares offset = asset decimals → mitigates ERC-4626 inflation/donation attack.
    ///      With USDC (6 decimals) this gives 12-decimal shares, making the attack economically infeasible.
    /// @dev Cached at init — no external `asset().decimals()` call on the hot
    ///      share-conversion path. Asset decimals are immutable in practice for the
    ///      underlying USDC/ERC-20, so pinning once at init is safe.
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return _cachedDecimalsOffset;
    }

    /// @dev True while any non-terminal proposal binds the vault
    ///      (Pending..Executed). Used by `_deposit` to close the late-deposit
    ///      window where a depositor mid-vote would be silently pulled into a
    ///      strategy by `executeProposal`. Off-chain readers can call
    ///      `governor.openProposalCount(vault)` directly.
    /// @dev AND WHILE THE LAST SETTLEMENT STILL HAS VALUE IN FLIGHT.
    ///      `openProposalCount() != 0` covers the window where capital is
    ///      deployed, on the reasoning that `totalAssets()` reads only
    ///      `balanceOf(this)` and so under-reports while a strategy holds funds.
    ///      That reasoning does not stop at settlement: strategy settlement is
    ///      DELIVERABLE-MAXIMUM, not all-or-revert (`MorphoSupplyStrategy` caps
    ///      at the market's idle balance and emits `SettlementIncomplete`), so a
    ///      settled proposal can leave a residue on the clone while
    ///      `_finishSettlement` has already cleared the open count.
    ///
    ///      In that gap `totalAssets()` under-reports by the residue and
    ///      deposits are open, so a depositor mints against a price missing
    ///      value that is still coming back. The permissionless `sweep()` then
    ///      returns it into the enlarged share pool, and the difference —
    ///      `A * R / (float + A)` for a deposit `A` against residue `R` — comes
    ///      out of the LPs who were already in. No privileged action, repeatable
    ///      per proposal, and an attacker can induce the residue rather than
    ///      wait for it: `_deliverableNow` caps at Morpho's idle balance, which
    ///      a fee-free `flashLoan` removes for one callback frame.
    ///
    ///      NOBODY IS WEDGED BY THIS. `sweep()` is permissionless and untaxed,
    ///      so the very depositor this refuses can call it and then deposit at
    ///      the correct price. That is the property that makes locking safe
    ///      here, where blocking SETTLEMENT itself would not be — an illiquid
    ///      market must never trap the vault, which is why the deliverable-
    ///      maximum design exists and why this guard is on deposits only.
    ///
    ///      DEGRADES OPEN, STATED. A strategy that cannot answer is never
    ///      marked, so deposits stay unlocked. Failing closed was tried and is
    ///      unsafe here for a specific structural reason rather than a
    ///      preference: the mark would be unremovable, and any registered agent
    ///      can reach it by naming an EOA as the proposal's strategy — see
    ///      `_recordResidue` for the full trace. A permanent,
    ///      unrecoverable deposit brick is worse than the suppression it would
    ///      be guarding, which is the same trade `_PROBE_GAS` documents.
    ///
    ///      Bounded, not unbounded: only a strategy that DEFINITELY reported a
    ///      residue is ever counted, `collectResidue` is the permissionless and
    ///      untaxed exit, and the very depositor this refuses can call it and
    ///      then deposit at the corrected price.
    ///
    ///      This closes the MINT side only. Queued redeemers stamped in the same
    ///      `onProposalSettled` call are still priced at the float-only figure
    ///      and remain underpaid by the residue — that is the FAIRNESS half of
    ///      finding #3 (issue #233), deliberately not closed here; see
    ///      `docs/nav-residue-design.md`. This PR closes the ATTACK half.
    /// @notice Public because the withdrawal queue reads it: a queued deposit
    ///         claim mints at the live price and must be refused on exactly the
    ///         same predicate as an instant one, or the gate has a hole the
    ///         width of the async path.
    function depositsLocked() public view returns (bool) {
        if (IProposalStatus(_getGovernor()).openProposalCount() != 0) return true;
        // The ONLY residue that still blocks rather than prices: value no
        // template can express in vault-asset units without an oracle. See
        // `_unvaluedCount`.
        if (_unvaluedCount == 0) return false;
        // ...and even that blocks only for a bounded window. See
        // `_unvaluedSince` for why an unliftable lock is the worse failure.
        return block.timestamp < _unvaluedSince + UNVALUED_MAX_LOCK;
    }

    /// @notice Assets the vault is worth FOR PRICING A MINT: idle float plus the
    ///         value settled strategies still owe it.
    /// @dev    Deliberately not `totalAssets()`. See `_residueAmount` for why
    ///         this figure is safe on the deposit side and unsafe on the redeem
    ///         side; nothing but `previewDeposit` / `previewMint` reads it.
    function depositNav() public view returns (uint256) {
        return totalAssets() + _residueTotal;
    }

    /// @notice Sweep a settled strategy's residue back into the vault and, once
    ///         it reports nothing outstanding, stop counting it against the
    ///         deposit gate.
    /// @dev    PERMISSIONLESS AND UNTAXED BY DESIGN — it is the exit from the
    ///         lock, and the party most motivated to call it is the depositor
    ///         being refused. That is what keeps the fail-closed gate from being
    ///         a wedge: whoever wants in can clear the residue and then deposit,
    ///         at the corrected price.
    ///
    ///         THE SWEEP IS A LOW-LEVEL CALL WITH THE RESULT IGNORED. The
    ///         address is proposer-chosen (a clone of an allowlisted template,
    ///         but still), so a typed call would let a reverting clone brick the
    ///         only exit from the lock. A failed sweep simply recovers nothing
    ///         and leaves the strategy counted, which is the honest outcome.
    ///
    ///         CLEARS ON A DEFINITE "NOTHING OUTSTANDING", OR ON CODELESSNESS.
    ///         An unreadable probe on a live contract leaves the strategy
    ///         counted — deposits stay shut, the safe direction, and the honest
    ///         one since the vault genuinely cannot tell whether value is still
    ///         out. That state is only ever entered from a definite readable
    ///         "yes" (see `_recordResidue`), so it means a strategy
    ///         that DID owe has stopped answering, not that an arbitrary address
    ///         was marked. The codeless arm covers a strategy that has since
    ///         self-destructed: it can hold nothing and answer nothing, so
    ///         counting it forever would be a wedge with no upside.
    ///
    ///         A CONFORMING STRATEGY WHOSE MARKET NEVER REFILLS still holds the
    ///         gate — `hasUndeliveredValue` stays true while `own` exceeds the
    ///         dust floor even when `deliverable` is zero. That is a real,
    ///         accepted liveness cost of the lock and the reason the round
    ///         ledger's timeout/guardian backstop exists (issue #233); it is
    ///         deliberately not improvised here.
    function collectResidue(address strategy) external nonReentrant returns (uint256 collected) {
        return _recoverResidueVia(strategy, _SEL_SWEEP);
    }

    /// @notice Drive a settled strategy's last-resort hatch: convert what it
    ///         still can, hand the vault whatever it never will be able to, and
    ///         split any vault-asset arrival with the exited redeem cohort.
    /// @dev    THE TWIN OF `collectResidue`, AND FOR THE SAME REASON. The
    ///         template's `releaseUnconvertible` attempts a conversion before it
    ///         releases, so it can push VAULT ASSET home — which makes it a
    ///         second door onto the balance delta `_payCohortShare` splits, and
    ///         a delta is a complete measurement only while there is one door.
    ///         Called directly it credited the cohort nothing and lifted the
    ///         stayers' price instead, unrepairably, exactly as a direct
    ///         `sweep()` did.
    ///
    ///         So the hatch is vault-only on the template and this is its
    ///         permissionless entry point. The capital-hostage property that
    ///         made it permissionless in the first place is preserved intact:
    ///         anyone may still call it, at any time, with no privilege.
    ///
    ///         KEPT SEPARATE FROM `collectResidue` ON PURPOSE. The hatch
    ///         FORECLOSES a conversion — it ships a token the clone can no
    ///         longer sell — so folding it into the routine sweep path would
    ///         release residues that a later retry would have converted. The
    ///         template makes that argument for itself; this preserves it by
    ///         keeping the two callable independently.
    function releaseUnconvertible(address strategy) external nonReentrant returns (uint256 collected) {
        return _recoverResidueVia(strategy, _SEL_RELEASE);
    }

    /// @notice Drop an unvalued mark whose lock window has already lapsed, so
    ///         the deposit gate can arm again for the next one.
    ///
    /// @dev    WHAT THIS EXISTS FOR: `UNVALUED_MAX_LOCK` bounds how long a mark
    ///         SHUTS deposits, but on its own it does not bound how long a mark
    ///         SURVIVES. A hostile label never stops answering TRUE, so its mark
    ///         is permanent, so `_unvaluedCount` never returns to zero, so the
    ///         0 -> 1 transition that stamps `_unvaluedSince` can never happen
    ///         again. The deadline stays frozen at the attacker's timestamp and
    ///         `depositsLocked()` reads FALSE for the rest of the vault's life —
    ///         including for every future HONEST mark, which is then priced
    ///         against a NAV that structurally cannot include it. One label,
    ///         once, and the guard is off permanently. That is the same
    ///         permanence the expiry was added to remove, pointed the other way.
    ///
    ///         PERMISSIONLESS, AND HARMLESS BY CONSTRUCTION. It only ever
    ///         removes a mark that is ALREADY past its deadline and therefore
    ///         already blocking nothing — `depositsLocked` ignores it either
    ///         way, so no depositor's access changes at the instant this runs.
    ///         What changes is the FUTURE: with the count back at zero, the next
    ///         mark is a real 0 -> 1 with a fresh window, and the gate works.
    ///
    ///         REFUSES INSIDE THE WINDOW rather than no-opping, so a caller
    ///         cannot mistake "too early" for "nothing to do" — the two differ
    ///         by whether deposits are currently shut.
    ///
    ///         The strategy is burned as it is pruned; see `_unvaluedBurned` for
    ///         why the pair is inseparable.
    ///
    ///         MEASURED ON THIS STRATEGY'S OWN CLOCK, not the episode's. The
    ///         deposit gate runs on `_unvaluedSince` so that a later mark cannot
    ///         restart the lock; reading that same figure here would let one
    ///         label's expiry authorize a PERMANENT burn of another label that
    ///         had barely marked. See `_unvaluedMarkedAt`.
    function pruneUnvaluedMark(address strategy) external {
        if (!_residueUnvalued[strategy]) return; // idempotent: nothing marked
        if (block.timestamp < _markStartOf(strategy) + UNVALUED_MAX_LOCK) revert UnvaluedLockStillActive();

        _residueUnvalued[strategy] = false;
        _unvaluedBurned[strategy] = true;
        _bumpUnvalued(strategy, false);
        emit ResidueUnvalued(strategy, false);
    }

    /// @dev When `strategy`'s own mark was set. Falls back to the episode clock
    ///      for a mark predating `_unvaluedMarkedAt`; see that field for why the
    ///      fallback is the episode figure and not zero.
    function _markStartOf(address strategy) private view returns (uint256) {
        uint256 own = _unvaluedMarkedAt[strategy];
        return own != 0 ? own : _unvaluedSince;
    }

    /// @dev The one measured door onto a settled strategy. `selector` picks the
    ///      recovery the template should attempt; everything else — the delta,
    ///      the cohort split, and the residue bookkeeping — is identical and
    ///      must stay that way, since the invariant being protected is that
    ///      NOTHING moves vault asset out of a strategy without being measured
    ///      here.
    function _recoverResidueVia(address strategy, bytes4 selector) private returns (uint256 collected) {
        uint256 known = _residueAmount[strategy];
        // RECOVER FIRST, ASK ABOUT THE BOOKS AFTER. This used to return early
        // when nothing was recorded, which was safe only while `sweep()` was
        // itself permissionless — a strategy holding assets the vault never
        // recorded (an unreadable probe, a zero cap) could still be emptied by
        // calling it directly. Now that the templates' recovery entry points are
        // vault-only, that escape route runs through here, so an early return
        // would strand those assets permanently. The call below is a no-op
        // against an address with nothing to give, including an EOA.
        bool tracked = known != 0 || _residueUnvalued[strategy];

        uint256 before = IERC20(asset()).balanceOf(address(this));
        // solhint-disable-next-line avoid-low-level-calls
        (bool swept,) = strategy.call{gas: _SWEEP_GAS}(abi.encodeWithSelector(selector));
        swept; // result deliberately unused — see the note above
        collected = IERC20(asset()).balanceOf(address(this)) - before;
        _payCohortShare(strategy, collected);

        // Nothing on the books to reconcile. Anything that DID arrive has
        // already been through `_payCohortShare` above, which is the whole
        // reason that runs before the bookkeeping rather than after it — and
        // it is a real split precisely when this strategy has a settlement
        // behind it, i.e. `_residuePid` survives an amount that went to zero.
        // For an address that never settled the pid is 0, `_cohortFractionOf`
        // declines, and the arrival belongs to the stayers in full; there is
        // no cohort to owe.
        if (!tracked) return collected;

        // A CODELESS STRATEGY OWES NOTHING. It can hold nothing and answer
        // nothing, so carrying its last known figure forever would over-price
        // every future deposit against value that provably cannot exist.
        if (strategy.code.length == 0) {
            if (known != 0) _setResidue(strategy, 0);
            if (_residueUnvalued[strategy]) {
                _residueUnvalued[strategy] = false;
                _bumpUnvalued(strategy, false);
                emit ResidueUnvalued(strategy, false);
            }
            emit ResidueCleared(strategy, collected);
            return collected;
        }

        _refreshUnvalued(strategy);
        if (known == 0) return collected;

        (bool ok, uint256 outstanding) = _readUndeliveredValue(strategy);
        // UNREADABLE KEEPS THE LAST KNOWN FIGURE, deliberately. Delivery only
        // ever shrinks what is owed, so a stale reading is stale-HIGH — the
        // direction that over-prices a deposit rather than under-pricing it.
        // Refusing to update is therefore the safe response to silence, and it
        // is why a strategy that stops answering can never wedge this vault:
        // there is no lock to hold, only a price that stays conservative.
        if (!ok) return collected;

        uint256 cap = _residueCap[strategy];
        if (outstanding > cap) outstanding = cap; // the same bound the record honoured
        if (outstanding != known) _setResidue(strategy, outstanding);
        if (outstanding == 0) emit ResidueCleared(strategy, collected);
    }

    /// @dev Amount-returning sibling of the probes above. Returns `ok == false`
    ///      when the strategy cannot be read at all, which callers MUST
    ///      distinguish from a readable zero — the two mean opposite things
    ///      (`unknown` vs `nothing owed`).
    function _readUndeliveredValue(address strategy) private view returns (bool ok, uint256 value) {
        bytes memory ret;
        (ok, ret) = strategy.staticcall{gas: _PROBE_GAS}(abi.encodeCall(IStrategyDelivery.undeliveredValue, ()));
        if (!ok || ret.length != 32) return (false, 0);
        value = abi.decode(ret, (uint256));
    }

    /// @dev Record `strategy` as still owing, if it says so. Called at
    ///      settlement, once, for the strategy that just settled.
    ///      Idempotent on the count: a strategy already in the set is not
    ///      double-counted, which matters because the same clone could in
    ///      principle be named by two proposals.
    ///
    ///      MARKS ONLY ON A DEFINITE, READABLE "YES". An unreadable probe leaves
    ///      the strategy unmarked — deposits stay OPEN — and that direction is
    ///      forced, not preferred.
    ///
    ///      Marking fail-closed was tried and is UNSAFE, because the mark would
    ///      be unremovable: `collectResidue` can only clear on a definite
    ///      readable zero, so an address that can never answer is marked once
    ///      and never cleared, and `depositsLocked()` returns true for the rest
    ///      of the vault's life with no permissionless exit. That is reachable
    ///      by any registered agent, not theoretical: `SyndicateGovernor.propose`
    ///      stores `strategy` unvalidated and explicitly skips its own probe for
    ///      codeless addresses (see the `strategy.code.length != 0` guard there
    ///      and `test_propose_eoaStrategySucceedsAtPropose`), nothing ever calls
    ///      the field, and a staticcall to a codeless address succeeds with
    ///      empty returndata — so an EOA label settles normally and then bricks
    ///      every deposit path, instant and queued, permanently.
    ///
    ///      A PERMANENT DoS IS WORSE THAN THE SUPPRESSION IT GUARDS, which is
    ///      the same trade `_PROBE_GAS` already documents and the same doctrine
    ///      `IStrategyDelivery.hasUndeliveredValue` and both templates state. A
    ///      proposer who degrades the probe suppresses a MITIGATION — the
    ///      recoverable direction — and the answer to that is a measured gas
    ///      bound, not a lock nobody can lift. The codeless short-circuit below
    ///      is the same treatment `address(0)` gets and the same rule
    ///      `propose` applies: a guard that only makes sense for a CONTRACT must
    ///      establish there is one first.
    function _recordResidue(address strategy, uint256 pid, uint256 cap) private {
        if (strategy == address(0) || strategy.code.length == 0) return;

        _refreshUnvalued(strategy);

        (bool ok, uint256 outstanding) = _readUndeliveredValue(strategy);
        if (!ok || outstanding == 0) return;
        // BOUNDED BY THE CAPITAL THE VAULT HELD, see `_residueCap`. A zero cap
        // (an unreadable governor) records nothing, matching every other probe
        // here: unreadable means not recorded, never recorded-at-face-value.
        if (cap == 0) return;
        if (outstanding > cap) outstanding = cap;
        _residueCap[strategy] = cap;

        uint256 known = _residueAmount[strategy];
        // FIRST COHORT KEEPS THE CLAIM. Re-pointing this at a later proposal
        // while the strategy still owes for an earlier one would route the older
        // cohort's arrivals to the newer cohort — real money, misallocated
        // between two sets of exited LPs.
        //
        // That is unreachable today, but only because of an invariant in ANOTHER
        // contract: `BaseStrategy.execute` requires `State.Pending`, so a settled
        // clone cannot be executed again, cannot reach Settled again, and so
        // never returns here. This repo has been bitten before by a local branch
        // silently depending on a cross-contract invariant (see
        // `VaultWithdrawalQueue`'s stamp-monotonicity note), so the guard is made
        // local rather than argued. A second cohort simply goes unrecorded,
        // which leaves it exactly where it is today: paid the float-only floor.
        if (known == 0) _residuePid[strategy] = pid;
        if (outstanding == known) return;
        // ONLY THE STAYERS' PART PRICES A MINT — see `_residueNet`.
        _setResidue(strategy, outstanding);
        emit ResidueOutstanding(strategy, outstanding);
    }

    /// @dev THE ONE PLACE `_residueTotal` MOVES. Every caller states the new
    ///      gross figure; this derives the stayers' part of it and swaps the
    ///      strategy's stored contribution for the new one, so a clear always
    ///      removes exactly what a record added. Routing all three sites through
    ///      here is what makes double-release and drift unrepresentable rather
    ///      than merely tested-for.
    function _setResidue(address strategy, uint256 outstanding) private {
        uint256 net = _stayerShareOf(outstanding, _residuePid[strategy]);
        _residueTotal = _residueTotal - _residueNet[strategy] + net;
        _residueNet[strategy] = net;
        _residueAmount[strategy] = outstanding;
    }

    /// @dev The exiting cohort's fraction of `pid`, frozen by the queue at its
    ///      stamp. `(0, 0)` means "no cohort, or cannot be read", and every
    ///      caller treats that as the whole amount belonging to the pool.
    ///
    ///      RAW STATICCALL, DEGRADING TO ZERO. The queue is not a proxy and can
    ///      never gain a selector, so a vault paired with a queue deployed
    ///      before this function existed would revert on a typed call — and this
    ///      sits on `collectResidue`, which is the ONLY exit from the
    ///      unvaluable-residue deposit lock. A typed call there turns an
    ///      incoherent pairing into bricked deposits; degrading skips the junior
    ///      leg instead, leaving redeemers exactly where they are today. Same
    ///      doctrine as `_pricingSupply` and `ExposureLedger._feedPriceX8`: fail
    ///      OPEN on a liveness path.
    function _cohortFractionOf(uint256 pid) private view returns (uint256 shares, uint256 den) {
        address q = _withdrawalQueue;
        if (q == address(0) || pid == 0) return (0, 0);
        (bool ok, bytes memory ret) = q.staticcall(abi.encodeCall(IVaultWithdrawalQueue.cohortOf, (pid)));
        if (!ok || ret.length != 64) return (0, 0);
        (shares, den) = abi.decode(ret, (uint256, uint256));
        if (den == 0) return (0, 0);
    }

    /// @dev The part of `amount` that will actually reach the pool: everything
    ///      the exiting cohort is not owed. Rounds the COHORT's slice down, the
    ///      same direction `_payCohortShare` routes it, so the two can never
    ///      disagree by more than the dust that stays with the stayers.
    function _stayerShareOf(uint256 amount, uint256 pid) private view returns (uint256) {
        if (amount == 0) return 0;
        (uint256 shares, uint256 den) = _cohortFractionOf(pid);
        if (shares == 0) return amount;
        return amount - Math.mulDiv(amount, shares, den);
    }

    /// @dev Hand the exiting cohort their share of an arrival, and leave the
    ///      rest where it landed.
    ///
    ///      THE FAIRNESS HALF OF FINDING #3. The settle stamp is computed from
    ///      float alone, so a redeemer claiming against it is paid as though the
    ///      residue were worth zero — and when it later comes home it lifts the
    ///      price for whoever STAYED. The money is not lost; it goes to the
    ///      wrong people. This pays it to the right ones.
    ///
    ///      SPLIT BY THE COHORT'S FRACTION AT THE STAMP, `shares / den`, both
    ///      frozen by the queue when it stamped. If the exiting cohort held 30%
    ///      of the vault at that instant, they are owed 30% of everything that
    ///      arrives afterwards for that proposal. Rounds DOWN, so the cohort is
    ///      never handed more than arrived and the dust stays with the stayers.
    ///
    ///      REAL ASSETS ONLY — `arrival` is a measured balance delta, never an
    ///      estimate, so nothing here can pay out against value that has not
    ///      turned up. That is what makes the junior leg unable to strand
    ///      anyone: with no arrival there is simply nothing to split, and the
    ///      redeemer keeps the floor they were already paid.
    ///
    ///      CUSTODIED BY THE QUEUE, not reserved here. Assets sent there leave
    ///      `totalAssets()`, so they stop lifting the stayers' price the instant
    ///      they are earmarked — which is correct, they are not the stayers' —
    ///      and the junior leg never touches `reservedQueueAssets()`, the figure
    ///      that gates instant exits and the next proposal's float.
    function _payCohortShare(address strategy, uint256 arrival) private {
        if (arrival == 0) return;
        address q = _withdrawalQueue;
        if (q == address(0)) return;

        uint256 pid = _residuePid[strategy];
        // No queued redeems at that settlement, or a queue that cannot answer:
        // the whole arrival belongs to the stayers either way.
        (uint256 shares, uint256 den) = _cohortFractionOf(pid);
        if (shares == 0) return;

        uint256 cohortShare = Math.mulDiv(arrival, shares, den);
        if (cohortShare == 0) return;

        IERC20(asset()).safeTransfer(q, cohortShare);
        IVaultWithdrawalQueue(q).creditCohort(pid, cohortShare);
        emit CohortShareRouted(strategy, pid, cohortShare);
    }

    /// @dev The tighter of the two bounds the governor already keeps on how much
    ///      a proposal could have moved out: the vault's whole float before the
    ///      batch (`getCapitalSnapshot`) and the coverage-scaled ceiling the
    ///      batch was actually held to (`getEffectiveMaxCapital`). The ceiling is
    ///      the real bound — the snapshot admits a self-report of up to the
    ///      entire vault — so a hostile clone cannot impose an entry tax larger
    ///      than the capital its proposal was permitted to touch.
    ///
    ///      Either read failing yields zero, which records nothing: unreadable
    ///      means not recorded here as everywhere else on this path.
    function _residueBound(uint256 proposalId) private view returns (uint256) {
        (bool okC, bytes memory retC) =
            msg.sender.staticcall(abi.encodeCall(IProposalStatus.getCapitalSnapshot, (proposalId)));
        if (!okC || retC.length != 32) return 0;
        uint256 bound = abi.decode(retC, (uint256));

        (bool okE, bytes memory retE) =
            msg.sender.staticcall(abi.encodeCall(IProposalStatus.getEffectiveMaxCapital, (proposalId)));
        if (!okE || retE.length != 32) return 0;
        uint256 ceiling = abi.decode(retE, (uint256));

        return ceiling < bound ? ceiling : bound;
    }

    /// @dev Re-read whether `strategy` holds residue it cannot value, and keep
    ///      `_unvaluedCount` in step. Unreadable keeps the last known flag, for
    ///      the same reason the amount does: silence must not be read as
    ///      permission to mint.
    function _refreshUnvalued(address strategy) private {
        bool was = _residueUnvalued[strategy];
        bool now_;
        if (strategy.code.length != 0) {
            (bool ok, bytes memory ret) =
                strategy.staticcall{gas: _PROBE_GAS}(abi.encodeCall(IStrategyDelivery.hasUnvaluedResidue, ()));
            if (!ok || ret.length != 32) return; // unreadable: keep the last known flag
            now_ = abi.decode(ret, (uint256)) != 0;
        }
        if (now_ == was) return;
        // A BURNED LABEL CANNOT MARK AGAIN. Its one episode already ran to the
        // deadline and was pruned; honouring a fresh TRUE here would let anyone
        // re-shut the vault on demand by calling `collectResidue` on it. See
        // `_unvaluedBurned`. Only the marking direction is refused — a burned
        // strategy that somehow still carried a mark must always be able to
        // clear it.
        if (now_ && _unvaluedBurned[strategy]) return;
        _residueUnvalued[strategy] = now_;
        _bumpUnvalued(strategy, now_);
        emit ResidueUnvalued(strategy, now_);
    }

    /// @dev The ONLY place `_unvaluedCount` and EITHER clock move, so neither
    ///      deadline can drift from the marks it governs.
    ///
    ///      THE EPISODE CLOCK, `_unvaluedSince`, is dated from the FIRST mark
    ///      (0 -> 1) and cleared on the last (1 -> 0): the window
    ///      `depositsLocked` honours is therefore the whole episode, not a fresh
    ///      grace period per strategy. Per-strategy deposit deadlines would let
    ///      a sequence of hostile labels hold the gate shut indefinitely, which
    ///      is the exact failure `_unvaluedSince` exists to rule out.
    ///
    ///      THE PER-STRATEGY CLOCK, `_unvaluedMarkedAt`, is dated from THIS
    ///      label's own mark and cleared when it drops, because the only thing
    ///      that reads it — `pruneUnvaluedMark` — burns one strategy forever.
    ///      Sharing the episode clock with the burn is what let one label's
    ///      expiry spend another's window; see `_unvaluedMarkedAt`.
    function _bumpUnvalued(address strategy, bool marked) private {
        if (marked) {
            if (_unvaluedCount == 0) _unvaluedSince = block.timestamp;
            _unvaluedMarkedAt[strategy] = block.timestamp;
            _unvaluedCount += 1;
        } else {
            // HYGIENE, NOT BEHAVIOUR, and stated as such because a test that
            // claimed otherwise was vacuous. Nothing can observe this reset:
            // `_markStartOf` is read only by `pruneUnvaluedMark`, which returns
            // early unless a mark is standing, and every mark re-stamps in the
            // arm above. It is kept so a stale timestamp cannot become load
            // bearing for a future reader — if one ever does read it outside a
            // live mark, that reader needs a test, since this line has none.
            _unvaluedMarkedAt[strategy] = 0;
            _unvaluedCount -= 1;
            if (_unvaluedCount == 0) _unvaluedSince = 0;
        }
    }

    /// @dev Float available for instant exits = vault asset balance minus the
    ///      queue's reserved (already-settled, unclaimed) redeem float. Shared by
    ///      `maxWithdraw` / `maxRedeem`. Floors at 0 when float < reserve.
    function _availableFloat() private view returns (uint256) {
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        return float > reserve ? float - reserve : 0;
    }

    /// @dev Closed-deposit gate: reverts unless deposits are open OR `who` is
    ///      whitelisted. Shared by `_deposit` / `requestDeposit`.
    function _requireApprovedDepositor(address who) private view {
        if (!_openDeposits && !_approvedDepositors.contains(who)) revert NotApprovedDepositor();
    }

    /// @inheritdoc ERC4626Upgradeable
    // The `nonReentrant` guard lives on the internal `_deposit` (both `deposit`
    // and `mint` route through it), so the public entrypoints keep OZ's inherited
    // bodies and we do not pay for two wrapper overrides (EIP-170 headroom).
    // Defence-in-depth against cross-function reentrancy on the share-price path:
    // a reentrant deposit during another mint could mint against a
    // transiently-deflated NAV.
    //
    // The `withdraw`/`redeem` paths take no `nonReentrant` — not load-bearing.
    // Withdraw transfers the asset OUT to the receiver, there is no live-withdraw
    // adapter callback, and any reentry into deposit/mint is still blocked by
    // `_deposit`'s latch.

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Idle float minus the queue reserve, floored at zero.
    ///      `stampSettlement` froze the reserved assets against a `num/den` that
    ///      can no longer move, so they are owed in a fixed amount and are no
    ///      longer part of what a residual share is a claim on.
    ///
    ///      NEVER ALONE. The matching shares must leave the pricing supply in the
    ///      same breath — see `_pricingSupply`. Subtracting assets without their
    ///      shares would understate the price as badly as double-counting them
    ///      would overstate it.
    ///      THE QUEUE RESERVE IS NOT THE ONLY LIABILITY (pashov review finding
    ///      #3). A fee whose transfer failed is escrowed by
    ///      `SyndicateGovernor._payFee` and LEFT HERE — owed exactly like a
    ///      queue reserve, but previously counted as LP equity, so redeemers in
    ///      the post-settle window took a slice of the fee recipient's money.
    function totalAssets() public view override returns (uint256) {
        uint256 gross = IERC20(asset()).balanceOf(address(this));
        uint256 owed = reservedQueueAssets() + _escrowedFeeLiability();
        // Cannot legitimately underflow — the reserve tracks assets the vault
        // holds — but under-reporting beats inventing value if it ever did.
        return gross > owed ? gross - owed : 0;
    }

    /// @dev Escrowed fee liability this vault owes, read from its governor.
    ///      Low-level staticcall degrading to zero on any failure, matching
    ///      `_openProposalPid` and `_pricingSupply`: `totalAssets()` sits on
    ///      every pricing path in this contract, so a governor predating
    ///      `outstandingEscrow` — or any nonstandard implementation — must not
    ///      brick deposits, redemptions and settlement. Degrading to zero
    ///      reproduces exactly the previous behaviour, never anything worse.
    /// @dev COST, measured (PR #195 review, minor 4): ~5,535 gas the first time
    ///      the governor is touched in a transaction (cold account access) and
    ///      ~896 gas on every subsequent `totalAssets()` in that same
    ///      transaction, once the address is warm. Since `totalAssets()` sits
    ///      on the deposit / redeem / preview / settle paths, the realistic
    ///      per-transaction cost is one cold hit plus warm repeats — the
    ///      governor is already touched by most of those flows for other
    ///      reasons, so in practice this is usually the warm figure.
    function _escrowedFeeLiability() private view returns (uint256) {
        address gov = _getGovernor();
        if (gov == address(0)) return 0;
        (bool ok, bytes memory ret) =
            gov.staticcall(abi.encodeCall(ISyndicateGovernor.outstandingEscrow, (address(this), asset())));
        return (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @dev The supply a price is actually taken against: circulating shares LESS
    ///      the escrowed redeem shares whose settle price is already stamped.
    ///      Those shares are still in `totalSupply()` — the vault burns them at
    ///      `claim`, not at the stamp — but they are no longer a claim on the pool.
    ///
    ///      PAIRED WITH `totalAssets`, INSEPARABLY: both legs of the same claim
    ///      leave together, so a `claim` moves neither the price nor anyone else's
    ///      position. PRE-STAMP ESCROW STAYS IN — a queued-but-unsettled redeem
    ///      has no frozen price yet and still floats with the pool, which is why
    ///      this reads `stampedUnclaimedShares()` rather than `pendingShares()`.
    ///      FLOORED AT ZERO defensively; the counter is a subset of the balance
    ///      the queue holds, so the branch is unreachable today.
    ///
    ///      Deliberately a low-level staticcall rather than a typed call:
    ///      `VaultWithdrawalQueue` is not a proxy, so a queue deployed before this
    ///      function existed can never gain the selector. A typed call would
    ///      revert for that legacy pairing, and this sits on the conversion path,
    ///      so the revert would brick every deposit, withdraw, preview and fee
    ///      calc. A missing selector degrades to 0 instead; full remediation for
    ///      an existing syndicate requires redeploying the vault/queue pair.
    function _pricingSupply() internal view returns (uint256) {
        address q = _withdrawalQueue;
        uint256 supply = totalSupply();
        if (q == address(0)) return supply;
        (bool ok, bytes memory ret) = q.staticcall(abi.encodeCall(IVaultWithdrawalQueue.stampedUnclaimedShares, ()));
        uint256 stamped = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
        return supply > stamped ? supply - stamped : 0;
    }

    /// @dev Overridden solely to divide by `_pricingSupply()` instead of
    ///      `totalSupply()`; the rounding and virtual-offset arithmetic is
    ///      OpenZeppelin's, unchanged.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, _pricingSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @dev Mirror of `_convertToShares` above, same single change.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, _pricingSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev PRICED OFF `depositNav()`, NOT `totalAssets()` — a mint pays for the
    ///      value settled strategies still owe the vault as well as the float.
    ///      Rounds DOWN, so the depositor never receives more than the figure
    ///      implies. This is the finding-#3 gate in its final form: minting
    ///      against a price that excludes a residue is the skim, and there is
    ///      nothing left to skim once the price includes it.
    ///
    ///      `convertToShares` deliberately keeps reading `totalAssets()`: it is
    ///      the symmetric, fee-free figure ERC-4626 defines, and the spread
    ///      between it and this is exactly the entry fee described on
    ///      `_residueAmount`.
    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        return Math.mulDiv(assets, _pricingSupply() + 10 ** _decimalsOffset(), depositNav() + 1, Math.Rounding.Floor);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev The `previewDeposit` inverse, rounding UP so the assets demanded for
    ///      a given share count never undercharge.
    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        return Math.mulDiv(shares, depositNav() + 1, _pricingSupply() + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @dev Returns 0 when `paused()` so the EIP-4626 IMP-1 invariant holds
    ///      (`deposit(maxDeposit(x), x)` MUST NOT revert when the action is
    ///      disabled). Active-proposal / whitelist cases stay reported
    ///      as `type(uint256).max` here (adding those checks busts EIP-170 and
    ///      under-reports valid Lane A deposit flows); frontends poll
    ///      the per-vault governor's `getActiveProposal()` + `isApprovedDepositor` directly.
    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    /// @dev Instant deposit is allowed only outside an open proposal. During an
    ///      open proposal (Pending..Executed) it reverts and LPs use the async
    ///      deposit queue (`requestDeposit`), entering at the realized settle
    ///      price. Auto-delegate to self so shareholders get voting power.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (depositsLocked()) revert DepositsLocked();
        // NEVER TAKE ASSETS FOR ZERO SHARES. `previewDeposit` floors, so a
        // large enough denominator rounds a real deposit down to nothing and
        // `super._deposit` would transfer the assets and mint none — a silent
        // total loss for the depositor. The queue's claim path has always had
        // this guard; the instant path did not.
        //
        // Scoped to `assets != 0` so a zero-asset deposit stays the harmless
        // no-op ERC-4626 allows: nothing in, nothing out, nobody worse off. The
        // loss this guards is assets-in-shares-out, not zero-in-zero-out.
        if (shares == 0 && assets != 0) revert ZeroShares();
        _requireApprovedDepositor(receiver);
        super._deposit(caller, receiver, assets, shares);
        // The fund's first shares establish the high-water mark. Cannot be done
        // at `initialize` — before any shares exist there is no price.
        _initHighWaterMarkIfUnset();

        // Auto-delegation happens in `_update` (every receipt path).
    }

    /// @dev `maxWithdraw` / `maxRedeem` are the canonical lock gate (OZ ERC4626
    ///      invokes them before `_withdraw`) — they return 0 while
    ///      `redemptionsLocked()`, so instant exits are closed during a proposal
    ///      and LPs use the async redeem queue (`requestRedeem`). The bound
    ///      queue (`caller == _withdrawalQueue`) bypasses the reserve guard
    ///      because the reserved float belongs to it.
    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (caller != _withdrawalQueue) {
            uint256 reserve = reservedQueueAssets();
            uint256 float = IERC20(asset()).balanceOf(address(this));
            // A shortfall beyond idle float has nowhere to come from — there is
            // no strategy pull without Lane A. Same error surface as the old
            // `_pullFromStrategy` path for a non-Lane-A vault.
            if (assets + reserve > float) revert QueueReserveBreached();
        }

        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    /// @dev Cap visible to integrators so they don't propose withdrawals that
    ///      would breach the queue's reservation. Returns 0 while
    ///      `redemptionsLocked()` (instant withdraw is closed during a proposal;
    ///      LPs use `requestRedeem`). The bound queue bypasses the reserve cap
    ///      because the reserved float belongs to it.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxWithdraw(owner_);
        if (redemptionsLocked()) return 0;
        uint256 userMax = super.maxWithdraw(owner_);
        uint256 available = _availableFloat();
        return userMax > available ? available : userMax;
    }

    /// @dev Cap visible to integrators so they don't propose redeems that would
    ///      breach the queue's reservation. Returns 0 while `redemptionsLocked()`.
    ///      The bound queue bypasses the reserve cap (see `maxWithdraw`).
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxRedeem(owner_);
        if (redemptionsLocked()) return 0;
        uint256 userMax = super.maxRedeem(owner_);
        uint256 reserveShares = pendingQueueShares();
        uint256 ts = totalSupply();
        if (ts == 0 || reserveShares >= ts) return 0;
        uint256 availableShares = ts - reserveShares;
        uint256 backingAssets = _availableFloat();
        // No `backingAssets == 0` early return — skip the floatShares cap
        // entirely when the user's full balance fits within `backingAssets`
        // (covers the dust case where `convertToAssets(userMax) == 0`, which
        // would otherwise strand tiny redeems once float dropped to the queue
        // reserve). `_withdraw`'s reserve check still gates real asset draws.
        if (convertToAssets(userMax) > backingAssets) {
            uint256 floatShares = convertToShares(backingAssets);
            if (floatShares < availableShares) availableShares = floatShares;
        }
        return userMax > availableShares ? availableShares : userMax;
    }

    // ==================== ASYNC REDEEM ====================

    /// @inheritdoc ISyndicateVault
    /// @notice Burn-deferred redemption used while a strategy proposal is active.
    ///         Transfers `shares` from `owner_` into the queue and records a claim
    ///         anyone can settle once `redemptionsLocked() == false`.
    /// @dev `whenNotPaused` blocks queueing while the vault is paused. LPs are not
    ///      trapped — the queue's `cancel` path is unpaused and returns escrowed
    ///      shares to the owner at any time.
    /// @return requestId Always > 0 — the queue uses index 0 as a sentinel.
    function requestRedeem(uint256 shares, address owner_)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        address q = _withdrawalQueue;
        if (q == address(0)) revert WithdrawalQueueNotSet();
        if (!redemptionsLocked()) revert RedemptionsNotLocked();
        if (shares == 0) revert InsufficientShares();
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }
        // Move shares into queue custody. `_update` auto-delegates the queue to
        // itself, so custody shares keep checkpointed voting weight AT THE QUEUE —
        // now merely consistent rather than load-bearing, since nothing is
        // apportioned and the queue has no governance surface. For proposals
        // already open at request time, the voter's checkpoint at
        // `snapshotTimestamp` is frozen with the pre-transfer weight, so vote
        // power is preserved for in-flight proposals; queued shares forfeit voting
        // power for any proposal opened after escrow.
        uint256 pid = _activePid();
        _transfer(owner_, q, shares);
        requestId = IVaultWithdrawalQueue(q).queueRedeem(owner_, shares, pid);
        emit RedeemRequested(requestId, owner_, shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Mint-deferred deposit used while a strategy proposal is active.
    ///         Escrows `assets` in the queue (off-vault, so they never inflate
    ///         `totalAssets` nor get swept into the strategy) and records a claim
    ///         that mints shares at the realized settle price.
    /// @dev Gated on `openProposalCount() != 0` — the SAME predicate the instant
    ///      path closes on — not `redemptionsLocked()`, which is true only from
    ///      EXECUTE onward. Those two diverge for the whole
    ///      Pending/GuardianReview/Approved window: instant deposit is already
    ///      closed there, so gating on `redemptionsLocked()` left NO path to
    ///      deposit at all for that window. `openProposalCount()` covers exactly
    ///      the window instant deposit is closed for, so exactly one path is
    ///      always open.
    /// @return requestId Always > 0 (the queue uses index 0 as a sentinel).
    function requestDeposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        address q = _withdrawalQueue;
        if (q == address(0)) revert WithdrawalQueueNotSet();
        if (IProposalStatus(_getGovernor()).openProposalCount() == 0) revert NoOpenProposal();
        if (assets == 0) revert ZeroAssets();
        _requireApprovedDepositor(receiver);
        // Tag with the currently open proposal's id (see `_openProposalPid`) —
        // NOT `_activePid()`, which is still 0 for any request placed before
        // EXECUTE.
        uint256 pid = _openProposalPid();
        // Escrow assets in the queue (off-vault custody — never counted in
        // totalAssets, never swept into the strategy).
        IERC20(asset()).safeTransferFrom(msg.sender, q, assets);
        requestId = IVaultWithdrawalQueue(q).queueDeposit(receiver, assets, pid);
        emit DepositRequested(requestId, receiver, assets);
    }

    /// @inheritdoc ISyndicateVault
    function pendingQueueShares() public view returns (uint256) {
        address q = _withdrawalQueue;
        if (q == address(0)) return 0;
        return IVaultWithdrawalQueue(q).pendingShares();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev The queue tracks the exact frozen asset amount owed to already-
    ///      settled, unclaimed redeem requests. Instant withdrawals and strategy
    ///      executions must leave this float in the vault so queued claims are
    ///      always honorable.
    function reservedQueueAssets() public view returns (uint256) {
        address q = _withdrawalQueue;
        if (q == address(0)) return 0;
        return IVaultWithdrawalQueue(q).reservedAssets();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Queue-only: burn `shares` escrowed in the queue and pay `assets`
    ///         to `to` at the proposal's frozen settle price. The queue computes
    ///         `assets` from the stamped price; the vault trusts it (the queue is
    ///         set-once at deploy by the factory).
    function settleRedeem(uint256 shares, uint256 assets, address to) external nonReentrant {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _burn(_withdrawalQueue, shares);
        IERC20(asset()).safeTransfer(to, assets);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Queue-only: mint `shares` to `to` at the proposal's frozen settle
    ///         price. The queue pushes the escrowed assets to the vault
    ///         immediately before this call.
    /// @dev No `nonReentrant`: the only state-mutating call here is the mint.
    ///      `_initHighWaterMarkIfUnset` reads `pricePerShare()`, which makes only
    ///      STATICCALLs, and the sole caller — the queue's `claim` — is itself
    ///      `nonReentrant`.
    /// @dev Queue-originated deposits bypass `_deposit` entirely, so this is the
    ///      ONLY other mint entrypoint and must seed the high-water mark itself,
    ///      or a queue-only first mint would settle its first performance fee
    ///      against an unset mark. Also the re-seed path for the zero-to-nonzero
    ///      supply transition zeroed in `_update`.
    function settleDeposit(uint256 shares, address to) external {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _mint(to, shares);
        _initHighWaterMarkIfUnset();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: stamp the realized settle price for `proposalId`
    ///         into the queue so every request tagged to it claims at one frozen
    ///         price. `num/den` carry the ERC-4626 virtual offsets so the queue
    ///         reproduces the vault's conversion rounding exactly.
    /// @dev `den` MUST divide by `_pricingSupply()`, not raw `totalSupply()` — the
    ///      same rule every other conversion here follows. `num` already excludes
    ///      assets reserved against prior stamped-but-unclaimed redeems, so
    ///      leaving their shares in a raw denominator deflates this stamp by the
    ///      exact shares-without-matching-assets gap `_pricingSupply()` closes.
    ///      SAFE FOR THIS PROPOSAL'S OWN REDEEM SHARES BY ORDERING: below,
    ///      `stampSettlement` increments the queue's counter only AFTER receiving
    ///      `num`/`den`, so the read here excludes only PRIOR stamps.
    function onProposalSettled(uint256 proposalId) external onlyGovernor {
        // Pin the settling strategy BEFORE anything can return early — this is
        // the last moment the governor still names it, and `depositsLocked`
        // needs it to ask whether a residue is still in flight. Read from the
        // caller (the governor), which is `onlyGovernor`-authenticated, via a
        // length-checked staticcall: a governor that cannot answer leaves the
        // pin at zero, which `depositsLocked` reads as nothing outstanding —
        // the pre-existing behaviour, not a stricter one.
        (bool okS, bytes memory retS) = msg.sender.staticcall(abi.encodeCall(IProposalStatus.strategyOf, (proposalId)));
        // NOT SWEPT HERE, AND THAT IS MEASURED RATHER THAN ASSUMED. An earlier
        // plan called for a best-effort `sweep()` of the settling strategy at
        // this point, to clear the residue before the stamp. It recovers
        // nothing: `MorphoSupplyStrategy.sweep()` computes `_deliverableNow()`
        // exactly as `_settle()` just did, and `_settle` has already withdrawn
        // that maximum in this same transaction — the market's idle balance is
        // drained by that withdraw, so a second call in the same frame resolves
        // `deliverable == 0`. The residue of the proposal being settled is
        // recoverable only in a LATER transaction, once the market refills,
        // which is what `collectResidue` is for.
        address strat = (okS && retS.length == 32) ? abi.decode(retS, (address)) : address(0);
        uint256 bound = _residueBound(proposalId);

        address q = _withdrawalQueue;
        if (q == address(0)) {
            // No queue, so no cohort can be owed anything and nothing is
            // stamped -- but the residue must still be recorded, or a mint
            // would be priced as though the strategy owed nothing.
            _recordResidue(strat, proposalId, bound);
            _recordResidue(_proposalSandbox[proposalId], proposalId, bound);
            return;
        }
        // THE STAMP COUNTS UNDELIVERED VALUE; `totalAssets()` DELIBERATELY DOES
        // NOT. `totalAssets()` is the LIVE figure every conversion reads, and
        // teaching it to count strategy-held value would price the vault against
        // an unrealized, strategy-influenced NAV — the exact lever the frozen
        // settle price exists to remove (see `VaultWithdrawalQueue`'s header).
        //
        // At THIS point the position is already unwound, so what the strategy
        // still holds is realized-but-undelivered value: a receivable, not a
        // mark to market. Excluding it stamped a price below what the vault
        // actually owned, and a queued depositor claiming at that frozen number
        // minted against the shortfall — then swept it in. Freezing the price is
        // what made it unfixable after the fact: a third party sweeping first
        // did not repair the stamp, and the attacker carried no directional
        // risk, since no residue simply meant a fair-price deposit.
        //
        // Degrades to 0 on any failure, i.e. to the pre-fix stamp, never to a
        // higher one — an over-count is the only direction that could mint
        // against value that never arrives.
        // STAMPED FROM FLOAT ALONE, DELIBERATELY — the residue correction was
        // attempted here and REVERTED, because it cannot be made safe at this
        // site. `stampSettlement` derives the queue reserve as
        // `mulDiv(redeemShares, num, den)`, and `_availableFloat` is
        // `balanceOf - reserve`. Raising `num` therefore reserves assets the
        // vault does not hold: instant `maxWithdraw`/`maxRedeem` floor to zero
        // for EVERY LP, and a queued `claim` reverts outright if the residue
        // never frees.
        //
        // Capping `num` does NOT fix that. The reserve scales with
        // `redeemShares / den`, a ratio this call does not control, so no bound
        // on `num` alone keeps the reserve payable — a 90%-queued vault still
        // over-reserves by ~1.8x at the cap. The float-only stamp is
        // under-priced but ALWAYS PAYABLE, and payable is the property the
        // queue's solvency rests on.
        //
        // WHAT IS STILL OPEN HERE IS THE REDEEMER, NOT THE DEPOSITOR. The
        // queued-DEPOSIT mispricing is closed, but not from this site: a mint no
        // longer reads any stamp at all, it converts live against
        // `depositNav()`, which counts what settled strategies still owe. A
        // queued REDEEMER is still paid from this float-only stamp, so they
        // leave their share of the residue behind and it accrues to the LPs who
        // stayed. That is a fairness gap, not an attack — no adversary, no loss
        // to the protocol, a transfer between LPs — and closing it means paying
        // them a floor now plus a share of arrivals later, NOT correcting this
        // number. See `docs/nav-residue-design.md` and issue #233; do not
        // re-derive it here.
        //
        // NOTE the skip-stamp-plus-`restamp(pid)` shape is NOT the plan: it does
        // not survive the queue. `claim` requires `_lastStampedPid >= r.pid`, so
        // skipping strands every queued request for that pid including
        // redeemers; `stampSettlement` reverts `StampOutOfOrder` once a later
        // proposal settles, which would strand them permanently; and
        // restamping a stamped pid needs `_reservedAssets` and
        // `_stampedUnclaimedShares` unwound first. Strictly worse than the
        // mispricing.
        uint256 num = totalAssets() + 1;
        uint256 den = _pricingSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);

        // RECORDED AFTER THE STAMP, DELIBERATELY. `_recordResidue` nets out the
        // exiting cohort's share of the residue so a mint is priced only for
        // what will actually reach the pool -- and that fraction does not exist
        // until the `stampSettlement` above freezes it. Recording first read a
        // cohort of zero and quietly priced the gross figure, over-charging
        // every depositor in the settle-to-arrival window.
        //
        // Safe in this order: the stamp reads `totalAssets()` and
        // `_pricingSupply()`, neither of which the residue record touches, so
        // moving the record later cannot move the price it stamped at.
        _recordResidue(strat, proposalId, bound);
        // THE SANDBOX IS A SECOND HOLDER OF THIS PROPOSAL'S VALUE, and it must
        // reach the same machinery or the vault would price mints against float
        // alone while a sandbox still held assets — finding #3's shape
        // reintroduced through a new path. Recording it here also keys it to
        // THIS pid, so a late arrival is split with the cohort that exited at
        // this settlement rather than accruing entirely to the stayers.
        //
        // Bounded by the same proposal envelope: the sandbox's funding was
        // carved from it, so `bound` is a true ceiling on what it can owe.
        _recordResidue(_proposalSandbox[proposalId], proposalId, bound);
    }

    /// @dev Gas ceiling for both strategy probes. The address is
    ///      proposer-chosen, so an uncapped staticcall lets a gas-burning
    ///      callee eat 63/64 of the forwarded gas: on `_deposit` that is a
    ///      permanent deposit DoS with no permissionless clear, and on
    ///      `onProposalSettled` the probe sits inside the settle path and can
    ///      OOG settlement itself. The degrade-to-false/0 semantics already
    ///      handle a truncated result correctly.
    ///
    ///      ACCEPTED TRADE, stated rather than implied, and NAMING THE RIGHT
    ///      TEMPLATE. `MorphoSupplyStrategy` was moved onto raw stored totals
    ///      (`_ownRaw`) precisely to get off this hook, so it no longer routes
    ///      through an IRM. The exposure lives in
    ///      `ConcentratedLiquidityStrategy.undeliveredValue`, which still takes
    ///      the ACCRUING read (`expectedMarketBalances` -> `borrowRateView`)
    ///      with the IRM supplied in the proposer's `MarketParams`.
    ///
    ///      WHY CL IS NOT SIMPLY MOVED TO RAW TOTALS TOO. It subtracts `owed`
    ///      from collateral, and a raw `morpho.market` read excludes interest
    ///      since `lastUpdate` — which UNDERSTATES `owed` and pushes
    ///      `collateral - owed` HIGH. That is the one direction this stamp must
    ///      never err in, so copying the Morpho fix here would trade a
    ///      suppression risk for a systematic over-report. The templates differ
    ///      because their arithmetic differs, not by oversight.
    ///
    ///      WHAT BOUNDS THE RISK INSTEAD: Morpho Blue's `createMarket` requires
    ///      a governance-enabled IRM and `p.morpho` is counterparty-allowlisted,
    ///      so an arbitrary gas-burner cannot be introduced. The realistic
    ///      failure is the AdaptiveCurveIrm's own view cost drifting past this
    ///      cap over time — silently, since a suppressed report means the
    ///      residue is never recorded and deposits are priced residue-free
    ///      (finding #3, for that proposal). Pinned by
    ///      `test_residueProbes_surviveAGasGriefingIrm` on both templates.
    ///
    ///      The round number below still needs a measured worst-case bound
    ///      across the shipped templates, tracked with the rest of the residue
    ///      work in issue #233.
    uint256 private constant _PROBE_GAS = 150_000;

    /// @dev Gas ceiling for the `sweep()` call inside `collectResidue`. Unlike
    ///      the probes above this is a STATE-CHANGING call into a
    ///      proposer-chosen clone, so it needs room for a real withdraw + swap +
    ///      transfer while still being bounded: `collectResidue` is
    ///      permissionless, and an uncapped call would let a gas-burning clone
    ///      eat 63/64 of whatever the caller forwards. The result is ignored, so
    ///      a clone that exhausts this simply recovers nothing and stays counted.
    uint256 private constant _SWEEP_GAS = 1_500_000;

    /// @dev `bytes4(keccak256("sweep()"))`. Encoded by selector rather than
    ///      through a typed interface on purpose: the call must stay low-level
    ///      so a reverting or non-conforming clone cannot brick the only exit
    ///      from the deposit lock.
    bytes4 private constant _SEL_SWEEP = 0x35faa416;

    /// @dev `bytes4(keccak256("releaseUnconvertible()"))`. Low-level for the
    ///      same reason as `_SEL_SWEEP`, and additionally because not every
    ///      template has the hatch at all — a typed call would revert against
    ///      the ones that do not, rather than recovering nothing.
    bytes4 private constant _SEL_RELEASE = 0x0ee7f80b;

    // ==================== MANAGEMENT-FEE ACCRUAL ====================

    /// @dev Close off the elapsed interval at the base that applied during it,
    ///      then restamp the base from live fund assets. Called on every
    ///      mid-proposal event that can move the base and once more at settlement.
    ///      Proposal execute opens the accrual rather than closing an interval, so
    ///      it stamps the base directly through `startManagementAccrual`.
    ///
    ///      Restamping from `totalAssets()` rather than applying a per-event delta
    ///      is deliberate: the base is read from truth, so it stays correct for
    ///      any caller regardless of whether that caller can express its own
    ///      effect as an asset delta.
    ///
    ///      The `_mgmtLastUpdate == 0` early return is load-bearing twice: it is
    ///      the no-live-proposal-no-fee rule, and it keeps `totalAssets()` off the
    ///      ordinary deposit path entirely.
    function _accrueManagementFee() private {
        uint256 last = _mgmtLastUpdate;
        if (last == 0) return;
        uint256 nowTs = block.timestamp;
        if (nowTs > last) {
            _mgmtAssetSeconds += uint256(_mgmtBase) * (nowTs - last);
            _mgmtLastUpdate = uint64(nowTs);
        }
        _stampMgmtBase();
    }

    /// @dev Restamp the accrual base from live fund assets, falling back to idle
    ///      float if the valuation is unavailable. A fee accrual must never be the
    ///      reason `executeProposal` or a settlement reverts, so the try/catch
    ///      degrades the BASE rather than the transaction — the fund is valued at
    ///      its raw float for that interval and the fee comes out conservative,
    ///      never inflated. Kept as the backstop should `totalAssets()` ever grow
    ///      an external dependency again. Routed through an external self-call
    ///      because `try` cannot wrap an internal one.
    function _stampMgmtBase() private {
        uint256 base;
        try this.totalAssets() returns (uint256 a) {
            base = a;
        } catch {
            base = IERC20(asset()).balanceOf(address(this));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _mgmtBase = uint192(base > type(uint192).max ? type(uint192).max : base);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: begin management-fee accrual for a newly executed
    ///         proposal.
    /// @dev Starts from zero rather than carrying anything forward, which is
    ///      what makes the gap between proposals free: nothing accrued while no
    ///      proposal was live, and nothing stale survives into this one.
    function startManagementAccrual() external onlyGovernor {
        _mgmtAssetSeconds = 0;
        _mgmtLastUpdate = uint64(block.timestamp);
        _stampMgmtBase();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: settle up the accrual and hand back the integral,
    ///         then stop accruing.
    /// @dev Consume-and-reset. Zeroing `_mgmtLastUpdate` is what stops the
    ///      clock between proposals; without it the idle gap would accrue.
    function consumeManagementAccrual() external onlyGovernor returns (uint256 assetSeconds) {
        _accrueManagementFee();
        assetSeconds = _mgmtAssetSeconds;
        _mgmtAssetSeconds = 0;
        _mgmtBase = 0;
        _mgmtLastUpdate = 0;
    }

    /// @inheritdoc ISyndicateVault
    function managementAssetSeconds() public view returns (uint256) {
        uint256 last = _mgmtLastUpdate;
        if (last == 0 || block.timestamp <= last) return _mgmtAssetSeconds;
        return _mgmtAssetSeconds + uint256(_mgmtBase) * (block.timestamp - last);
    }

    /// @inheritdoc ISyndicateVault
    function isAccruingManagementFee() external view returns (bool) {
        return _mgmtLastUpdate != 0;
    }

    // ==================== HIGH-WATER MARK ====================

    /// @notice AT LEAST one whole share, in this vault's OWN decimals — never a
    ///         smaller, arbitrary `1e18`. Share decimals are
    ///         `2 * assetDecimals` here, so a literal `1e18` is one whole share
    ///         only at `assetDecimals == 9`; at 18 it was `1e-18` of a share, and
    ///         `convertToAssets` of that quantized to whole-integer steps of
    ///         `pps`, so `aboveHighWaterMark` read a fund up 99% as sitting AT the
    ///         mark and charged zero performance fee.
    /// @dev    `max(1e18, 10 ** decimals())`, NOT bare `10 ** decimals()`. Always
    ///         converting against exactly one share is wrong for LOW-decimal
    ///         assets: at `assetDecimals == 6`, `10 ** decimals() = 1e12`, a
    ///         SMALLER unit than `1e18`. `convertToAssets` floors, and the
    ///         absolute floor error in `pps` is bounded by <1 unit of this
    ///         constant, so a smaller unit means that same error represents more
    ///         real value once multiplied back out by `totalSupply()` — measured
    ///         at ~$1 of drift on a $200,000 fee base for a 6-decimal asset. The
    ///         `max` floors at exactly `1e18` for every `assetDecimals <= 9`, so
    ///         those vaults keep identical numerics; only `assetDecimals > 9`
    ///         switches to the larger, decimals-scaled unit.
    /// @dev    Computed, not cached: `decimals()` reads only pinned state, so this
    ///         costs one `EXP` and one comparison, not an external call.
    function _pricePerShareUnit() private view returns (uint256) {
        uint256 wholeShare = 10 ** decimals();
        return wholeShare > 1e18 ? wholeShare : 1e18;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Routed through `convertToAssets` rather than computing
    ///      `totalAssets() / totalSupply()` by hand, so the mark inherits the
    ///      ERC-4626 virtual-offset rounding the vault uses for every other
    ///      conversion. A hand-rolled ratio would drift from real share pricing
    ///      and the drift would land in the fee.
    function pricePerShare() public view returns (uint256) {
        return convertToAssets(_pricePerShareUnit());
    }

    /// @inheritdoc ISyndicateVault
    function highWaterPricePerShare() external view returns (uint256) {
        return _highWaterPricePerShare;
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Value above the mark, in assets — the performance-fee base.
    /// @dev Zero when the fund sits at or below its previous peak, which is the
    ///      whole point: a fund that falls and recovers is not charged twice on
    ///      the same dollars. Callers must read this AFTER the management fee
    ///      has been taken, since that fee lowers the price per share.
    function aboveHighWaterMark() external view returns (uint256) {
        uint256 mark = _highWaterPricePerShare;
        uint256 pps = pricePerShare();
        if (pps <= mark) return 0;
        return (pps - mark) * _pricingSupply() / _pricePerShareUnit();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: advance the mark to the current post-fee price per
    ///         share.
    /// @dev Monotonic by construction — a loss leaves the mark where it was, which
    ///      is what makes the recovery free. Called at settlement only; a partial
    ///      exit must NOT ratchet, or the holders who stayed would start measuring
    ///      from a peak the fund never banked.
    function ratchetHighWaterMark() external onlyGovernor {
        uint256 pps = pricePerShare();
        if (pps > _highWaterPricePerShare) {
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    /// @dev Seed the mark at the fund's first deposit so the first proposal's
    ///      gains above it are chargeable. Before any shares exist the price is
    ///      meaningless, so this cannot be done at `initialize`.
    function _initHighWaterMarkIfUnset() private {
        if (_highWaterPricePerShare == 0 && totalSupply() != 0) {
            uint256 pps = pricePerShare();
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    // ==================== RESCUE ====================

    /// @notice Rescue ETH accidentally sent to the vault.
    ///         Blocked during active proposals so the owner cannot siphon
    ///         ETH mid-strategy (e.g. an mWETH redemption that transiently
    ///         parks native ETH here before wrapping).
    function rescueEth(address payable to, uint256 amount) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        Address.sendValue(to, amount);
    }

    /// @notice Rescue ERC-20 tokens accidentally sent to the vault (not the vault asset).
    ///         Blocked during active proposals to protect strategy position tokens.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        address asset = asset();
        if (token == asset) revert CannotRescueAsset();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Rescue ERC-721 tokens accidentally sent to the vault.
    ///         Blocked during active proposals to protect strategy position NFTs (e.g., Uniswap V3 LP).
    function rescueERC721(address token, uint256 tokenId, address to) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    // ==================== UUPS ====================

    /// @dev Only the factory can authorize upgrades.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != _factory) revert NotFactory();
    }

    // ==================== RECEIVE ====================

    /// @dev No `receive()` / `fallback()`. The vault's ERC-4626 asset
    ///      is USDC; raw ETH has no accounting slot and would strand forever.
    ///      Any legitimate mid-batch native ETH (e.g. Moonwell mWETH redeem)
    ///      is caught by the strategy's own `receive()` at its own address
    ///      and wrapped to WETH before being pushed back via `safeTransfer`.
}
