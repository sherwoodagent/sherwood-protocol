// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, Id, MarketParams} from "../vendor/morpho/IMorpho.sol";
import {MarketParamsLib} from "../vendor/morpho/MorphoLibs.sol";

/// @notice The `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed(x)` walk.
/// @dev    Declared locally: every hop is a length-checked raw staticcall. Generates selectors only.
interface ITierBindingPath {
    function governor() external view returns (address);
    function tierRegistry() external view returns (address);
    function isCounterpartyAllowed(address counterparty) external view returns (bool);
}

/**
 * @title MorphoSupplyStrategy
 * @notice Supplies the vault asset to exactly one Morpho Blue lending market, fixed at
 *         initialization. Funds come back to the vault only through `settle()`.
 *
 *   Execute: pull `supplyAmount` of the vault asset → supply to the market.
 *   Settle:  withdraw the entire supply position by SHARES → push everything to the vault.
 *            All-or-revert: an illiquid market reverts the settlement, which is retried.
 *
 *   Batch calls from governor:
 *     Execute: [asset.approve(strategy, supplyAmount), strategy.execute()]
 *     Settle:  [strategy.settle()]
 */
contract MorphoSupplyStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using MarketParamsLib for MarketParams;

    // ── Errors ──
    error InvalidAmount();
    /// @notice The configured market's loan asset differs from the vault asset.
    error LoanAssetMismatch();
    /// @notice The derived market id has never been created on the configured Morpho contract.
    error MarketNotCreated();
    /// @notice `morpho_` is not a counterparty in the `TierRegistry` the vault's governor names.
    error MorphoNotAllowed(address morpho, address registry);
    /// @notice The `vault() -> governor() -> tierRegistry()` walk yielded no registry at `_initialize`.
    error TierRegistryUnresolved();
    /// @notice Nothing is tunable between execute and settle; `updateParams` always reverts.
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

    function _initialize(bytes calldata data) internal override {
        (address morpho_, MarketParams memory mp, uint256 supplyAmount_) =
            abi.decode(data, (address, MarketParams, uint256));

        if (morpho_ == address(0)) revert ZeroAddress();
        address registry = _resolveTierRegistry();
        if (registry == address(0)) revert TierRegistryUnresolved();
        // Bind the proposer's Morpho singleton before any call is made into it.
        if (!_isCounterpartyAllowed(registry, morpho_)) revert MorphoNotAllowed(morpho_, registry);
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

    // ── Settle: full shares-based unwind, all-or-revert ──

    /// @dev Withdraw by SHARES so accrued interest comes out and no dust is stranded.
    ///      Morpho's own liquidity check reverts when the market cannot pay in full.
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

    // ── Counterparty binding (see the binding notes on `_initialize`) ──

    function _requireAllowedMorpho(address morpho_) private view {
        address registry = _resolveTierRegistry();
        if (registry == address(0)) return;
        if (!_isCounterpartyAllowed(registry, morpho_)) revert MorphoNotAllowed(morpho_, registry);
    }

    /// @dev `vault() → governor() → tierRegistry()` walk; `address(0)` when unresolved.
    function _resolveTierRegistry() private view returns (address registry) {
        address governor_ = _readAddress(vault(), abi.encodeCall(ITierBindingPath.governor, ()));
        if (governor_ == address(0)) return address(0);
        registry = _readAddress(governor_, abi.encodeCall(ITierBindingPath.tierRegistry, ()));
    }

    function _isCounterpartyAllowed(address registry, address venue) private view returns (bool) {
        if (registry.code.length == 0) return false;
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ITierBindingPath.isCounterpartyAllowed, (venue)));
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
