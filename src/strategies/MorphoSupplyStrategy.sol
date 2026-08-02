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
    function _settle() internal override {
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;
        if (shares != 0) {
            morpho.withdraw(_marketParams, 0, shares, address(this), address(this));
        }
        _pushAllToVault(asset);
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

        MarketParams memory mp = _marketParams;
        (uint256 totalSupplyAssets, uint256 totalSupplyShares, uint256 totalBorrowAssets,) =
            morpho.expectedMarketBalances(mp);
        uint256 shares = morpho.position(marketId, address(this)).supplyShares;

        uint256 own = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);
        uint256 marketLiquidity = totalSupplyAssets > totalBorrowAssets ? totalSupplyAssets - totalBorrowAssets : 0;
        uint256 idleBalance = IERC20(asset).balanceOf(address(morpho));

        uint256 available = own < marketLiquidity ? own : marketLiquidity;
        if (idleBalance < available) available = idleBalance;

        uint256 kindCap = _instantKindCap();
        if (kindCap != 0 && kindCap < available) available = kindCap;
        return available;
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
