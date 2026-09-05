// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IStrategyDelivery} from "../interfaces/IStrategyDelivery.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, Id, MarketParams, Market} from "../vendor/morpho/IMorpho.sol";
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

    function _initialize(bytes calldata data) internal override {
        (address morpho_, MarketParams memory mp, uint256 supplyAmount_) =
            abi.decode(data, (address, MarketParams, uint256));

        if (morpho_ == address(0)) revert ZeroAddress();
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

    function _execute() internal override {
        _requireAllowedMorpho(address(morpho));
        _pullFromVault(asset, supplyAmount);
        IERC20(asset).forceApprove(address(morpho), supplyAmount);
        morpho.supply(_marketParams, supplyAmount, 0, address(this), "");
    }

    // ── Settle: full shares-based unwind ──

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
    ///         to the vault.
    /// @dev    VAULT-ONLY, THOUGH THE VALUE ONLY EVER MOVES THE RIGHT WAY. This
    ///         was permissionless on the reasoning that a one-directional push
    ///         needs no gate. The push is fine; the ACCOUNTING is what breaks.
    ///
    ///         `SyndicateVault.collectResidue` measures what arrives as a
    ///         balance delta across this call and hands the exited redeem cohort
    ///         their frozen fraction of it (`_payCohortShare`). A delta is only
    ///         a complete measurement if it is the ONLY way value arrives.
    ///         Called directly, the assets land outside that window: the cohort
    ///         is credited nothing, and the arrival silently lifts the price for
    ///         whoever STAYED — the exact misallocation the junior leg was
    ///         written to correct. Unrepairable too, since the delta is spent:
    ///         a later `collectResidue` measures zero and pays zero.
    ///
    ///         Not an attack that needs an attacker. Any keeper calling the
    ///         function on its own does it, which is why the fix is to remove
    ///         the second door rather than document around it. The public entry
    ///         point is `collectResidue`, still permissionless, which calls this.
    ///
    ///         Idempotent and safe to call when there is nothing to move. Takes
    ///         the deliverable maximum on each call, so a market that frees up
    ///         gradually can be swept repeatedly.
    /// @return assets The vault-asset amount pushed to the vault this call.
    function sweep() external onlyVault returns (uint256 assets) {
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

    /// @inheritdoc IStrategyDelivery
    /// @dev True while a settled proposal still has a supply position or idle
    ///      asset on this clone — exactly what `sweep()` above would move. The
    ///      vault reads this to keep deposits shut over that window, because
    ///      `totalAssets()` prices anything held here at zero and a depositor
    ///      would otherwise mint against a NAV missing the residue.
    ///
    ///      MEASURED ON WHAT THE POSITION IS WORTH, NEVER ON WHAT THE MARKET
    ///      CAN PAY OUT RIGHT NOW. Both come from `_deliverableNow()`, and the
    ///      distinction is which element is read: `own` is this clone's claim,
    ///      a function of its own shares and the supply index. `deliverable` is
    ///      that claim clamped to the market's idle balance, which is exactly
    ///      the quantity a flash loan moves — so it is never consulted here. A
    ///      residue that cannot be withdrawn this instant is still value the
    ///      vault does not count, and must still hold deposits.
    ///
    ///      Only meaningful once Settled: before that the vault is already
    ///      gated by `openProposalCount() != 0`, and answering true early would
    ///      be redundant rather than wrong.
    function hasUndeliveredValue() public view override returns (bool) {
        if (_state != State.Settled) return false;
        if (_ownRaw() > RESIDUE_DUST) return true;
        return IERC20(asset).balanceOf(address(this)) > RESIDUE_DUST;
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev Loan token IS the vault asset for this template (`_initialize`
    ///      pins `marketParams.loanToken == asset`), so the supply position is
    ///      already denominated in vault-asset units — no oracle, and nothing
    ///      an attacker can move inside the settlement transaction. `own` is
    ///      the redeemable value of the remaining shares; the idle balance is
    ///      whatever a partial withdrawal already pulled but has not pushed.
    function undeliveredValue() public view override returns (uint256) {
        if (_state != State.Settled) return 0;
        return _ownRaw() + IERC20(asset).balanceOf(address(this));
    }

    function _ownRaw() private view returns (uint256) {
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;
        if (shares == 0) return 0;
        Market memory m = morpho.market(marketId);
        return shares.toAssetsDown(m.totalSupplyAssets, m.totalSupplyShares);
    }

    /// @inheritdoc IStrategyDelivery
    /// @dev Always FALSE, and by construction rather than by policy: this
    ///      template's only position is a Morpho supply whose loan token IS the
    ///      vault asset, so `undeliveredValue()` expresses everything it holds
    ///      in vault-asset units with no price conversion anywhere. There is no
    ///      leg it cannot value.
    function hasUnvaluedResidue() public pure override returns (bool) {
        return false;
    }

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
