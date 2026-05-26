// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OFT} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title WoodToken — LayerZero OFT + ERC20Permit with hard 1B supply cap
/// @notice Minting authority is the contract `owner` (the deployer / multisig).
///         The Minter contract has been removed; the owner mints the initial
///         supply once at deploy and is expected to renounce ownership (or hold
///         it in a multisig with internal delay). Minting gracefully caps at
///         MAX_SUPPLY.
///         WOOD is a pure value token. Vote/checkpoint logic lives in the
///         StakedWood (sWOOD) staking contract, not here.
contract WoodToken is OFT, ERC20Permit {
    uint256 public constant MAX_SUPPLY = 1_000_000_000e18; // 1B tokens

    /// @notice Cumulative WOOD ever minted on this chain. Independent of
    ///         `totalSupply()` (which OFT bridges decrement via `_burn`)
    ///         so the 1B cap stays load-bearing across cross-chain
    ///         round-trips. Counts both local `mint()` and inbound OFT
    ///         `_credit` calls — see `_credit` override below.
    uint256 private _totalEverMinted;

    /// @notice Thrown when a mint or credit would push `_totalEverMinted`
    ///         past `MAX_SUPPLY`. Closes Sherlock run #1 finding #5 — the
    ///         pre-fix OFT `_credit` path bypassed the cap, allowing
    ///         cross-chain total supply to exceed 1B via mint+bridge+remint.
    error MaxSupplyExceeded();

    /// @param _lzEndpoint LayerZero endpoint on this chain
    /// @param _delegate   LayerZero oApp delegate (usually deployer / multisig).
    ///                    Also becomes the contract's `Ownable` owner and the
    ///                    sole mint authority.
    constructor(address _lzEndpoint, address _delegate)
        OFT("Wood Token", "WOOD", _lzEndpoint, _delegate)
        ERC20Permit("Wood Token")
        Ownable(_delegate)
    {}

    /// @notice Mint `amount` tokens to `to`. If minting the full amount would exceed
    ///         MAX_SUPPLY, only the remaining mintable amount is minted (no revert).
    /// @return minted The actual number of tokens minted (may be less than `amount`).
    function mint(address to, uint256 amount) external onlyOwner returns (uint256 minted) {
        uint256 remaining = totalMintable();
        if (remaining == 0) return 0;

        minted = amount > remaining ? remaining : amount;
        _totalEverMinted += minted;
        _mint(to, minted);
    }

    /// @notice OFT inbound-credit hook. Pairs with `_debit` on the source
    ///         chain. Counts inbound credits against the local `_totalEverMinted`
    ///         high-water mark and reverts past `MAX_SUPPLY`.
    /// @dev Closes Sherlock run #1 finding #5. Pre-fix, the base OFT `_credit`
    ///      called `_mint(_to, _amountLD)` directly, bypassing both the cap
    ///      check and the HWM counter — a chain that local-minted up to the
    ///      cap, then burned via outbound bridges, could receive bridged-in
    ///      tokens AND then local-mint a full second 1B before its `mint()`
    ///      cap kicked in, doubling cross-chain supply. Tracking `_credit`
    ///      mints in `_totalEverMinted` closes that path.
    ///
    ///      Strict no-decrement HWM: `_debit` (bridge-out) does NOT decrement
    ///      `_totalEverMinted`. This deliberately forbids round-trips back to
    ///      a saturated chain — the alternative (debit-credit symmetric) would
    ///      let chain A mint 1B → bridge all to B → re-mint another 1B locally.
    ///      Single-origin deployment (one chain mints the initial 1B, others
    ///      are bridge-only sinks) naturally avoids the round-trip case.
    function _credit(address _to, uint256 _amountLD, uint32 _srcEid)
        internal
        override
        returns (uint256 amountReceivedLD)
    {
        _totalEverMinted += _amountLD;
        if (_totalEverMinted > MAX_SUPPLY) revert MaxSupplyExceeded();
        return super._credit(_to, _amountLD, _srcEid);
    }

    /// @notice Remaining mintable headroom against the lifetime mint cap.
    /// @dev Computed as `MAX_SUPPLY - _totalEverMinted`, NOT
    ///      `MAX_SUPPLY - totalSupply()`. Burns (including OFT bridge-out
    ///      `_burn`) do NOT replenish this counter — once a token is minted on
    ///      this chain it permanently consumes cap budget, so the 1B cap stays
    ///      load-bearing across cross-chain round-trips. Integrators looking
    ///      for circulating-supply headroom should compute that themselves
    ///      from `totalSupply()`.
    function totalMintable() public view returns (uint256) {
        return MAX_SUPPLY - _totalEverMinted;
    }

    /// @notice Cumulative WOOD ever minted on this chain (does not decrement
    ///         on OFT bridge-out / `_burn`). Cap reference for `mint`.
    function totalEverMinted() external view returns (uint256) {
        return _totalEverMinted;
    }

    // ─────────────────────────────────────────────────────────────────
    // Diamond resolution — OZ v5 composes the transfer hook through
    // `_update`; multi-inherit requires an explicit override with super-walk.
    // ─────────────────────────────────────────────────────────────────

    function _update(address from, address to, uint256 value) internal override(ERC20) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit) returns (uint256) {
        return super.nonces(owner);
    }
}
