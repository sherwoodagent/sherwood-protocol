// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, Id, MarketParams} from "../vendor/morpho/IMorpho.sol";
import {MarketParamsLib, MorphoBalancesLib, SharesMathLib} from "../vendor/morpho/MorphoLibs.sol";

/// @notice The hops walked to resolve the governance-owned adapter allowlist from
///         this strategy: `vault()` -> `governor()` -> `tierRegistry()` ->
///         `isAdapterAllowed(spender)`. The SAME registry, reached the same way,
///         that `SyndicateVault._guardBatchCalls` gates batch approvals against
///         and that `PortfolioStrategy` binds its swap adapter through.
/// @dev    Declared locally rather than imported, matching
///         `PortfolioStrategy.ITierBindingPath` (src/strategies/PortfolioStrategy.sol:36):
///         every hop is a length-checked raw staticcall, so the strategy takes on
///         no type dependency and no hop can revert `_initialize` undecodably.
///         This exists to generate selectors, not to type the responses.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isAdapterAllowed(address adapter) external view returns (bool);
}

/**
 * @title MorphoSupplyStrategy
 * @notice Supplies the vault asset to exactly one Morpho Blue lending
 *         market, fixed at initialization. Funds come back to the vault only
 *         through `settle()` (and `sweep()` for a post-settlement residue).
 *
 *   Execute: pull `supplyAmount` of the vault asset → supply to the market
 *            (onBehalf = this strategy).
 *   Settle:  withdraw the entire supply position by SHARES (so accrued
 *            interest is included) → push all held vault asset to the vault.
 *            When the market cannot currently deliver the whole position
 *            (utilization), settle takes the deliverable maximum, emits
 *            `SettlementIncomplete`, and the residue stays claimable by
 *            anyone through `sweep()` — see `_settle`.
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, supplyAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 *
 *   No tunable params — the market and amount are the whole proposal.
 */
contract MorphoSupplyStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    // ── Errors ──
    error InvalidAmount();
    /// @notice The configured market's loan asset differs from the vault
    ///         asset. Adversary: a proposer supplying vault funds into a
    ///         market whose loan token the vault cannot redeem — the position
    ///         would be denominated in (and unwound into) the wrong token.
    error LoanAssetMismatch();
    /// @notice The derived market id has never been created on the configured
    ///         Morpho contract — fail at init rather than at execute.
    error MarketNotCreated();
    /// @notice `morpho_` is not allowlisted in the `TierRegistry` the vault's own
    ///         governor gates batch approvals against. See
    ///         `_requireAllowedMorpho`.
    error MorphoNotAllowed(address morpho, address registry);
    /// @notice The `vault() -> governor() -> tierRegistry()` walk yielded no
    ///         registry at `_initialize`, so the proposer-supplied Morpho
    ///         singleton cannot be vouched for. Init fails CLOSED on this;
    ///         the per-call re-certification deliberately does not.
    error TierRegistryUnresolved();
    /// @notice This strategy exposes nothing to tune between execute and
    ///         settle; `updateParams` always reverts.
    error NoTunableParams();
    /// @notice `sweep()` is the post-settlement recovery path only — before
    ///         settlement the position is unwound by `settle`.
    error NotSettled();

    // Events
    /// @notice Settlement could not withdraw the whole supply position because the
    ///         market lacked deliverable liquidity; `sharesRemaining` are still
    ///         supplied and `assetsRemaining` is their redeemable value at settle
    ///         time. Loud on purpose: `_finishSettlement` measures PnL from the
    ///         vault's realized float, so the residue books as a LOSS on this
    ///         proposal and is later returned untaxed by `sweep()`.
    event SettlementIncomplete(uint256 sharesRemaining, uint256 assetsRemaining);
    /// @notice A post-settlement `sweep()` returned `assets` of the vault
    ///         asset to the vault.
    event ResidualSwept(uint256 assets);

    // ── Storage (per-clone) ──
    /// @notice The Morpho Blue singleton this strategy supplies to.
    IMorpho public morpho;
    /// @notice `keccak256(abi.encode(marketParams))`, fixed at initialize.
    Id public marketId;
    /// @notice The vault asset == the market's loan token (enforced at init).
    address public asset;
    /// @notice Amount of `asset` pulled and supplied at execute.
    uint256 public supplyAmount;

    MarketParams internal _marketParams;

    /// @inheritdoc IStrategy
    function name() external pure returns (string memory) {
        return "Morpho Supply";
    }

    /// @notice The full market params fixed at initialize.
    function marketParams() external view returns (MarketParams memory) {
        return _marketParams;
    }

    // ── Initialization ──

    /// @notice Decode: (address morpho, MarketParams marketParams, uint256 supplyAmount)
    /// @dev    Init-time validation, in adversary order:
    ///           - `morpho_` MUST be allowlisted in the governance-owned
    ///             `TierRegistry` — see `_requireAllowedMorpho`. THIS CHECK IS
    ///             FIRST AND IT IS LOAD-BEARING: everything after it is either a
    ///             comparison between two proposer-supplied struct fields or a
    ///             question asked of `morpho_` itself. `mp.loanToken !=
    ///             vaultAsset` compares proposer input against a real value and
    ///             is satisfied by simply naming the real asset, and
    ///             `market(id).lastUpdate` asks the singleton whether its own
    ///             market exists — an attacker-authored singleton answers "yes"
    ///             for free. Unbound, `_execute` then does
    ///             `_pullFromVault(asset, supplyAmount)` +
    ///             `forceApprove(morpho_, supplyAmount)` + `morpho_.supply(...)`
    ///             and the whole supply leaves; `_settle`/`sweep` read
    ///             `position`/`expectedMarketBalances` from that same contract,
    ///             so a zero `_deliverableNow` lets settlement complete
    ///             "cleanly" with the vault booking the full loss.
    ///           - `marketParams.loanToken` MUST equal the vault's asset —
    ///             see `LoanAssetMismatch`.
    ///           - the market MUST already exist on `morpho` (`lastUpdate != 0`
    ///             is the singleton's created-market sentinel) so a typo'd
    ///             params tuple fails here, not mid-batch at execute. Only
    ///             meaningful once `morpho_` is bound, which is why the binding
    ///             runs before it.
    ///
    ///         NOT BOUND: `mp.collateralToken`, `mp.oracle`, `mp.irm`, `mp.lltv`.
    ///         Deliberate, and consistent with `PortfolioStrategy`, which binds
    ///         the swap ADAPTER and the price SOURCES but not the basket tokens.
    ///         `isAdapterAllowed` answers "may this address receive vault-fund
    ///         movements"; the Morpho singleton is the only address here that
    ///         does. Once `morpho_` is the real singleton, the rest of the tuple
    ///         must name a market that genuinely exists on it, so those fields
    ///         stop being free-form attacker input and become a lending-RISK
    ///         choice (bad collateral -> bad debt -> supply loss) — the same
    ///         class of proposal-quality judgement as picking a bad basket
    ///         token, governed by the vote and the guardian review, not by the
    ///         adapter allowlist. Routing collateral tokens through
    ///         `isAdapterAllowed` would also overload that flag into "this ERC20
    ///         may be a Morpho collateral", which is not what any other consumer
    ///         reads it as.
    function _initialize(bytes calldata data) internal override {
        (address morpho_, MarketParams memory mp, uint256 supplyAmount_) =
            abi.decode(data, (address, MarketParams, uint256));

        if (morpho_ == address(0)) revert ZeroAddress();
        // INIT IS FAIL-CLOSED ON THE REGISTRY, AND ONLY INIT — matching
        // `PortfolioStrategy._initialize` and `ConcentratedLiquidityStrategy`,
        // whose note reads "Do not make these symmetric."
        //
        // `_requireAllowedMorpho` returns EARLY when the walk yields no
        // registry, which is right for the per-call re-certification at
        // `_execute` (blocking there would strand deployed capital) and wrong
        // here. `SyndicateFactory` documents a zero factory `tierRegistry` as
        // "Optional — address(0) means governors created by this factory keep
        // the safe tier-2 default", so every governor created before
        // `setTierRegistry`/`pushWiring` resolves to nothing — and for that
        // whole population the binding below would be a no-op, leaving the
        // finding unmitigated with no allowlist step required: a proposer inits
        // with a hostile singleton naming the real asset as `loanToken`,
        // `MarketNotCreated` is self-attested away by that same contract, and
        // `_execute` pulls the float and approves it away.
        //
        // Refusing at bind time costs a re-proposal. Refusing at execute would
        // cost the deployed capital.
        // Resolved ONCE and reused: `_requireAllowedMorpho` would otherwise
        // re-walk `vault() -> governor() -> tierRegistry()` immediately after
        // this line, four staticcalls where two do.
        address registry = _resolveTierRegistry();
        if (registry == address(0)) revert TierRegistryUnresolved();
        // Bind the proposer's Morpho singleton to the governance allowlist
        // before ANY call is made into it and before anything is written.
        if (!_isAdapterAllowed(registry, morpho_)) revert MorphoNotAllowed(morpho_, registry);
        if (supplyAmount_ == 0) revert InvalidAmount();

        address vaultAsset = IERC4626(vault()).asset();
        if (mp.loanToken != vaultAsset) revert LoanAssetMismatch();

        Id id = mp.id();
        if (IMorpho(morpho_).market(id).lastUpdate == 0) revert MarketNotCreated();

        morpho = IMorpho(morpho_);
        marketId = id;
        asset = vaultAsset;
        supplyAmount = supplyAmount_;
        _marketParams = mp;
    }

    // ── Execute: supply to the market ──

    /// @dev RE-CERTIFIES THE SINGLETON, unlike `_settle`/`sweep`. Same reasoning
    ///      as `PortfolioStrategy._execute`: blocking `execute()` strands
    ///      nothing — the proposal simply expires at `executeBy` with the vault
    ///      untouched — while blocking `settle()` would strand capital already
    ///      deployed. Without this, a singleton demoted between clone-init and
    ///      execute (reachable with NO governance action via the permissionless
    ///      `poke`/`demoteByChallenge`, or a metamorphic redeploy) would still
    ///      receive `forceApprove` of the whole supply, one hop outside the
    ///      vault's batch gate.
    function _execute() internal override {
        _requireAllowedMorpho(address(morpho));
        _pullFromVault(asset, supplyAmount);
        IERC20(asset).forceApprove(address(morpho), supplyAmount);
        morpho.supply(_marketParams, supplyAmount, 0, address(this), "");
    }

    // ── Settle: full shares-based unwind ──

    /// @dev Withdraws by SHARES, not assets: the share balance is the exact claim,
    ///      so the withdrawal includes all interest accrued since execute with no
    ///      dust left behind. Then pushes the strategy's entire asset balance to
    ///      the vault, including any that arrived outside the supply position.
    ///
    ///      DELIVERABLE-MAXIMUM, NOT ALL-OR-REVERT. Morpho's `withdraw` enforces
    ///      `totalBorrowAssets <= totalSupplyAssets` after decrementing supply, so
    ///      a market at full utilization reverts a full-position withdrawal. Doing
    ///      that unconditionally handed any borrower a veto over settlement:
    ///      `redemptionsLocked()` would stay true vault-wide for as long as the
    ///      borrower keeps utilization pinned, with no proposer lever. Adversary:
    ///      a borrower taking the market to ~100% utilization to hold a vault's
    ///      whole LP base hostage for the price of the borrow interest.
    ///
    ///      So settle takes what the market can deliver now and leaves the rest
    ///      supplied, loudly. The residue is NOT lost — `sweep()` returns it once
    ///      utilization recedes — but it does cost the proposal, since the
    ///      governor measures PnL from realized float. That asymmetry is
    ///      deliberate: a proposer who parks the vault in a market that cannot pay
    ///      out at settlement should wear the mark, and it is strictly better than
    ///      the whole vault freezing.
    function _settle() internal override {
        (uint256 shares, uint256 own, uint256 deliverable) = _deliverableNow();
        if (shares != 0) {
            if (deliverable >= own) {
                // Withdraw by SHARES: the exact claim, so every wei of accrued
                // interest comes out and no dust is stranded.
                morpho.withdraw(_marketParams, 0, shares, address(this), address(this));
            } else {
                // Partial: withdraw by ASSETS. Morpho converts assets→shares
                // rounding UP, which is why this branch is only taken when
                // `deliverable < own` — burning slightly more shares than the
                // proportional amount can never exceed the balance here.
                if (deliverable != 0) {
                    morpho.withdraw(_marketParams, deliverable, 0, address(this), address(this));
                }
                uint256 left = morpho.position(marketId, address(this)).supplyShares;
                emit SettlementIncomplete(left, own - deliverable);
            }
        }
        _pushAllToVault(asset);
    }

    /// @notice Return any supply position left behind by an incomplete settlement
    ///         to the vault. Permissionless and post-settlement only: it moves
    ///         value in exactly one direction — out of this strategy, into the
    ///         vault it was always owed to — so there is nothing to gate.
    /// @dev    Idempotent and safe to call when there is nothing to move. Takes the
    ///         deliverable maximum on each call, so a market that frees up
    ///         gradually can be swept repeatedly.
    /// @return assets The vault-asset amount pushed to the vault this call.
    function sweep() external returns (uint256 assets) {
        if (_state != State.Settled) revert NotSettled();
        (uint256 shares, uint256 own, uint256 deliverable) = _deliverableNow();
        if (shares != 0 && deliverable != 0) {
            if (deliverable >= own) {
                morpho.withdraw(_marketParams, 0, shares, address(this), address(this));
            } else {
                morpho.withdraw(_marketParams, deliverable, 0, address(this), address(this));
            }
        }
        assets = IERC20(asset).balanceOf(address(this));
        if (assets != 0) {
            _pushAllToVault(asset);
            emit ResidualSwept(assets);
        }
    }

    /// @dev (own supply shares, their redeemable value, the amount the market
    ///      can actually pay out right now). Shared core for `_settle` and
    ///      `sweep` — deliberately WITHOUT a `_state` gate: both run in
    ///      `State.Settled` (see `BaseStrategy.settle`, which flips state
    ///      BEFORE calling `_settle`), so a state gate here would zero them
    ///      out entirely.
    function _deliverableNow() private view returns (uint256 shares, uint256 own, uint256 deliverable) {
        MarketParams memory mp = _marketParams;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            morpho.expectedMarketBalances(mp);
        shares = morpho.position(marketId, address(this)).supplyShares;
        if (shares == 0) return (0, 0, 0);

        own = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 marketLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        uint256 idleBalance = IERC20(asset).balanceOf(address(morpho));

        deliverable = own < marketLiquidity ? own : marketLiquidity;
        if (idleBalance < deliverable) deliverable = idleBalance;
    }

    /// @dev Nothing is tunable between execute and settle.
    function _updateParams(bytes calldata) internal pure override {
        revert NoTunableParams();
    }

    // ── Governance-allowlist binding (see the binding notes on `_initialize`) ──

    /// @dev Reverts unless `morpho_` is allowlisted in the `TierRegistry` the
    ///      vault's own governor gates batch approvals against, resolved via
    ///      `vault() -> governor() -> tierRegistry()`. Skips only when that walk
    ///      yields no registry — the same condition under which
    ///      `SyndicateVault._guardBatchCalls` disables itself, and one the
    ///      proposer cannot steer because no hop is proposer input. A registry
    ///      that IS resolved but whose `isAdapterAllowed` is unreadable fails
    ///      CLOSED: a registry that cannot vouch for the singleton has not
    ///      vouched for it. Every hop is a length-checked raw staticcall.
    ///
    ///      Called from `_initialize` (certifies provenance once, at binding
    ///      time) and from `_execute` (re-certifies, since blocking execute
    ///      strands nothing). `_settle`/`sweep` deliberately do NOT: they are
    ///      the exit path, and gating them would hand a demotion — or an
    ///      unreachable registry — the power to freeze deployed capital.
    ///
    ///      Byte-for-byte the same walk as `PortfolioStrategy`'s
    ///      `_requireAllowedAdapter`; kept as a local copy rather than a shared
    ///      base so `BaseStrategy` gains no new external-call surface that every
    ///      other strategy's test stand-ins would have to answer.
    function _requireAllowedMorpho(address morpho_) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isAdapterAllowed(registry, morpho_)) revert MorphoNotAllowed(morpho_, registry);
    }

    /// @dev `vault() → governor() → tierRegistry()` walk. Returns `address(0)`
    ///      when unresolved (no `governor()` surface, a governor predating the
    ///      getter, or `tierRegistry() == 0`) — the condition under which
    ///      `_requireAllowedMorpho` skips its check entirely.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    /// @dev Staticcall-safe `isAdapterAllowed`. Unreadable → `false` (see the
    ///      fail-closed rationale on `_requireAllowedMorpho`).
    ///
    ///      READS THE WORD, DOES NOT `abi.decode` IT. `abi.decode(ret, (bool))`
    ///      REVERTS on any returned word outside `{0, 1}`, and that revert
    ///      lands in THIS frame with nothing to catch it — so a registry
    ///      answering `2` would brick `_initialize` instead of resolving to
    ///      "not vouched for", contradicting the line above and defeating the
    ///      point of writing this as a raw staticcall at all. Any non-zero word
    ///      is truthy, which is also what a well-behaved registry returns.
    ///      Mirrors `ConcentratedLiquidityStrategy._readAllowed`, and the
    ///      sibling `_readAddress` below already had the corrected shape.
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
        // Reads the first return word directly: `abi.decode` cannot express
        // "leading word of a longer payload".
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }
}
