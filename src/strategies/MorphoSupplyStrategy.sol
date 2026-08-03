// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {Position} from "../interfaces/IPriceRouter.sol";
import {PositionKinds} from "../libraries/PositionKinds.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, Id, MarketParams} from "../vendor/morpho/IMorpho.sol";
import {MarketParamsLib, MorphoBalancesLib, SharesMathLib} from "../vendor/morpho/MorphoLibs.sol";

/**
 * @title MorphoSupplyStrategy
 * @notice Lane-A-capable strategy: supplies the vault asset to exactly one
 *         Morpho Blue lending market, fixed at initialization. The companion
 *         `MorphoSupplyAdapter` prices the supply position from market state
 *         alone (no external oracle), and the position is venue-liquid up to
 *         the market's unborrowed liquidity — so this strategy overrides the
 *         full instant-lane surface: `positions()`, `availableLiquidity()`,
 *         and `withdrawTo()`.
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
    /// @notice This strategy exposes nothing to tune between execute and
    ///         settle; `updateParams` always reverts.
    error NoTunableParams();
    /// @notice `sweep()` is the post-settlement recovery path only — before
    ///         settlement the position is unwound by `settle` / `withdrawTo`.
    error NotSettled();

    // ── Events ──
    /// @notice Settlement could not withdraw the whole supply position because
    ///         the market lacked deliverable liquidity; `sharesRemaining` are
    ///         still supplied and `assetsRemaining` is their redeemable value
    ///         at settle time. Loud on purpose: `_finishSettlement` measures
    ///         PnL from the vault's realized float, so the residue books as a
    ///         LOSS on this proposal and is later returned to the vault
    ///         untaxed by `sweep()`.
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
    ///           - `marketParams.loanToken` MUST equal the vault's asset —
    ///             see `LoanAssetMismatch`.
    ///           - the market MUST already exist on `morpho` (`lastUpdate != 0`
    ///             is the singleton's created-market sentinel) so a typo'd
    ///             params tuple fails here, not mid-batch at execute.
    function _initialize(bytes calldata data) internal override {
        (address morpho_, MarketParams memory mp, uint256 supplyAmount_) =
            abi.decode(data, (address, MarketParams, uint256));

        if (morpho_ == address(0)) revert ZeroAddress();
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
        _pullFromVault(asset, supplyAmount);
        IERC20(asset).forceApprove(address(morpho), supplyAmount);
        morpho.supply(_marketParams, supplyAmount, 0, address(this), "");
    }

    // ── Settle: full shares-based unwind ──

    /// @dev Withdraws by SHARES, not assets: the share balance is the exact
    ///      claim, so the withdrawal includes all interest accrued since
    ///      execute with no dust left behind (an assets-based withdraw of a
    ///      pre-read value would strand the accrual since the last read).
    ///      Then pushes the strategy's entire asset balance to the vault,
    ///      including any balance that arrived outside the supply position.
    ///      DELIVERABLE-MAXIMUM, NOT ALL-OR-REVERT. Morpho's `withdraw`
    ///      enforces `totalBorrowAssets <= totalSupplyAssets` after decrementing
    ///      supply, so a market at full utilization reverts a full-position
    ///      withdrawal. Doing that unconditionally handed any borrower a veto
    ///      over settlement: `redemptionsLocked()` would stay true, instant
    ///      exits stay shut and the queue cannot settle — vault-wide, for as
    ///      long as the borrower keeps utilization pinned, with no proposer
    ///      lever (`updateParams` reverts `NoTunableParams`). Adversary: a
    ///      borrower taking the market to ~100% utilization to hold a vault's
    ///      whole LP base hostage for the price of the borrow interest.
    ///
    ///      So settle takes what the market can deliver now and leaves the rest
    ///      supplied, loudly (`SettlementIncomplete`). The residue is NOT lost:
    ///      it stays this strategy's supply position and `sweep()` returns it to
    ///      the vault once utilization recedes. It does cost the proposal — the
    ///      governor measures PnL from the vault's realized float, so an
    ///      undelivered residue books as a loss on this proposal and returns
    ///      untaxed later. That asymmetry is deliberate: a proposer who parks
    ///      the vault in a market that cannot pay out at settlement should wear
    ///      the mark, and it is strictly better than the whole vault freezing.
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

    /// @notice Return any supply position left behind by an incomplete
    ///         settlement to the vault. Permissionless and post-settlement
    ///         only: it can move value in exactly one direction — out of this
    ///         strategy, into the vault it was always owed to — so there is
    ///         nothing to gate and anyone may unstick it once the market can
    ///         pay. Before settlement the position is unwound by `settle` /
    ///         `withdrawTo` instead.
    /// @dev    Idempotent and safe to call when there is nothing to move.
    ///         Takes the deliverable maximum on each call, so a market that
    ///         frees up gradually can be swept repeatedly.
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
    ///      can actually pay out right now). Shared core for `_settle`, `sweep`,
    ///      and `availableLiquidity` — deliberately WITHOUT a `_state` gate and
    ///      WITHOUT the router's per-kind instant cap, so each caller applies
    ///      only what belongs to it:
    ///        - `_settle`/`sweep` run in `State.Settled` (see `BaseStrategy.settle`,
    ///          which flips state BEFORE calling `_settle`), so a state gate here
    ///          would zero them out entirely.
    ///        - the per-kind cap bounds instant EXIT size against DEX depth; a
    ///          terminal unwind is not an instant exit, so `_settle`/`sweep` must
    ///          NOT be throttled by it — only `availableLiquidity` applies it.
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

    // ── Lane A surface ──

    /// @inheritdoc IStrategy
    /// @dev One Morpho supply position while shares are outstanding, else
    ///      empty. `ref` carries the market id so the adapter can bind the
    ///      valuation to this exact market's state.
    function positions() external view override returns (Position[] memory ps) {
        if (address(morpho) == address(0)) return ps;
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;
        if (shares == 0) return ps;
        ps = new Position[](1);
        ps[0] = Position({
            venue: address(morpho), kind: PositionKinds.MORPHO_BLUE_SUPPLY, ref: abi.encode(Id.unwrap(marketId))
        });
    }

    /// @inheritdoc IStrategy
    /// @dev min(own redeemable supply value, market unborrowed liquidity,
    ///      Morpho's actual idle loan-token balance, the router's per-kind
    ///      instant cap). The utilization cap is the spec's adversary guard: a
    ///      highly utilized market must not advertise liquidity Morpho cannot
    ///      pay out (the vault verifies delivery by balance diff and reverts
    ///      `UnwindShortfall` on a lying strategy). The token-balance cap is
    ///      belt-and-suspenders against accounting/balance divergence on the
    ///      singleton.
    ///
    ///      The per-kind cap is enforced HERE rather than in
    ///      `PriceRouter._priceOne`, which prices truthfully and never sees an
    ///      exit size: a cap applied at valuation could only bound the position,
    ///      and only by declaring it unpriceable — which closed the whole
    ///      vault's instant lane whenever a position outgrew it, griefable by
    ///      anyone able to inflate that position (see the note on `_priceOne`).
    ///      Unlike the spot side there is no per-token registry here, so this
    ///      per-kind bound is the only depth limit on a Morpho unwind. A cap of
    ///      0 means "no bound configured", matching the router's own
    ///      convention; the market and utilization caps above still apply.
    function availableLiquidity() external view override returns (uint256) {
        if (_state != State.Executed) return 0;
        (,, uint256 deliverable) = _deliverableNow();

        uint256 kindCap = _instantKindCap();
        if (kindCap != 0 && kindCap < deliverable) deliverable = kindCap;
        return deliverable;
    }

    /// @dev The router's per-kind instant cap for `MORPHO_BLUE_SUPPLY`, or 0
    ///      when unresolvable. Staticcall-safe at every hop: this feeds
    ///      `SyndicateVault.maxWithdraw`, so an unreachable factory or router
    ///      must degrade the bound, never revert the vault's view. An
    ///      unresolvable router also means the vault cannot price this strategy
    ///      at all, so Lane A is already shut and the bound is moot.
    function _instantKindCap() private view returns (uint256) {
        address factory_ = _readAddress(vault(), abi.encodeWithSignature("factory()"));
        if (factory_ == address(0)) return 0;
        address router = _readAddress(factory_, abi.encodeWithSignature("priceRouter()"));
        if (router == address(0)) return 0;
        (bool ok, bytes memory ret) =
            router.staticcall(abi.encodeWithSignature("instantCap(bytes32)", PositionKinds.MORPHO_BLUE_SUPPLY));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Staticcall-safe address read: codeless target, revert, short return
    ///      or dirty upper bits all resolve to `address(0)`.
    function _readAddress(address target, bytes memory data) private view returns (address) {
        if (target.code.length == 0) return address(0);
        (bool ok, bytes memory ret) = target.staticcall(data);
        if (!ok || ret.length < 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

    /// @inheritdoc IStrategy
    /// @dev Exact-assets withdraw straight to the vault (receiver = vault) in
    ///      the same transaction. Morpho itself reverts when the market lacks
    ///      the liquidity or this strategy lacks the position — all-or-revert,
    ///      never partial delivery.
    function withdrawTo(uint256 assets) external override onlyVault {
        if (_state != State.Executed) revert NotExecuted();
        if (assets == 0) revert InvalidAmount();
        morpho.withdraw(_marketParams, assets, 0, address(this), vault());
    }
}
