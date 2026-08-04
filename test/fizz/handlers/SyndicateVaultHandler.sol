// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with SyndicateVault
///
/// @dev Covers both LP lanes. The instant lane (`deposit`/`mint`/`withdraw`/
///      `redeem`) and the async lane (`requestDeposit`/`requestRedeem`, then
///      `VaultWithdrawalQueue.claim`) share one share-price denominator, and
///      I-17 says stamped-but-unclaimed queue shares must be excluded from it.
///      Interleaving the two lanes is what puts that under pressure.
abstract contract SyndicateVaultHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function syndicateVault_deposit_clamped(uint256 assets, address receiver) public {
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        assets = clampBetween(assets, 1, bal);
        syndicateVault_deposit(assets, toActor(receiver));
    }

    /// @dev Sub-unit deposits: the vault's decimals offset means assets below
    ///      the conversion scale can round to zero shares.
    function syndicateVault_deposit_dust(uint256 assets) public {
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        assets = clampBetween(assets, 1, bal < 1e6 ? bal : 1e6);
        syndicateVault_deposit(assets, actor);
    }

    function syndicateVault_mint_clamped(uint256 shares, address receiver) public {
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        uint256 maxShares = vault.convertToShares(bal);
        if (maxShares == 0) return;
        shares = clampBetween(shares, 1, maxShares);
        syndicateVault_mint(shares, toActor(receiver));
    }

    function syndicateVault_withdraw_clamped(uint256 assets, address receiver) public {
        uint256 maxA = vault.maxWithdraw(actor);
        if (maxA == 0) return;
        assets = clampBetween(assets, 1, maxA);
        syndicateVault_withdraw(assets, toActor(receiver), actor);
    }

    function syndicateVault_redeem_clamped(uint256 shares, address receiver) public {
        uint256 maxS = vault.maxRedeem(actor);
        if (maxS == 0) return;
        shares = clampBetween(shares, 1, maxS);
        syndicateVault_redeem(shares, toActor(receiver), actor);
    }

    /// @dev Full-balance exit — the path that can zero `totalSupply` and reset
    ///      the high-water mark (I-18).
    function syndicateVault_redeem_full() public {
        uint256 maxS = vault.maxRedeem(actor);
        if (maxS == 0) return;
        syndicateVault_redeem(maxS, actor, actor);
    }

    function syndicateVault_requestDeposit_clamped(uint256 assets, address receiver) public {
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        assets = clampBetween(assets, 1, bal);
        syndicateVault_requestDeposit(assets, toActor(receiver));
    }

    function syndicateVault_requestRedeem_clamped(uint256 shares) public {
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        shares = clampBetween(shares, 1, bal);
        syndicateVault_requestRedeem(shares, actor);
    }

    function syndicateVault_transfer_clamped(address to, uint256 value) public {
        uint256 bal = vault.balanceOf(actor);
        if (bal == 0) return;
        value = clampBetween(value, 1, bal);
        syndicateVault_transfer(toActor(to), value);
    }

    function syndicateVault_transferFrom_clamped(address from, address to, uint256 value) public {
        address f = toActor(from);
        uint256 bal = vault.balanceOf(f);
        uint256 allow = vault.allowance(f, actor);
        uint256 cap = bal < allow ? bal : allow;
        if (cap == 0) return;
        value = clampBetween(value, 1, cap);
        syndicateVault_transferFrom(f, toActor(to), value);
    }

    /// @dev Donation: pushes assets in without minting shares, the classic
    ///      share-price inflation lever against an ERC-4626 vault.
    function syndicateVault_donateERC20(uint256 amount) public {
        uint256 bal = asset.balanceOf(actor);
        if (bal == 0) return;
        amount = clampBetween(amount, 1, bal);
        vm.prank(actor);
        asset.transfer(address(vault), amount);
    }

    function syndicateVault_secondary(uint8 selector, uint256 arg0, address arg1) public {
        selector = uint8(selector % 12);
        if (selector == 0) _syndicateVault_approve(toActor(arg1), arg0);
        else if (selector == 1) _syndicateVault_approveDepositor(toActor(arg1));
        else if (selector == 2) _syndicateVault_removeDepositor(toActor(arg1));
        else if (selector == 3) _syndicateVault_delegate(toActor(arg1));
        else if (selector == 4) _syndicateVault_pause();
        else if (selector == 5) _syndicateVault_unpause();
        else if (selector == 6) _syndicateVault_setOpenDeposits(arg0 % 2 == 0);
        else if (selector == 7) _syndicateVault_setAgentFeeBps(clampBetween(arg0, 0, 3_000));
        else if (selector == 8) _syndicateVault_setMinBufferBps(uint16(clampBetween(arg0, 0, 10_000)));
        else if (selector == 9) _syndicateVault_registerAgent(arg0 % 1_000, toActor(arg1));
        else if (selector == 10) _syndicateVault_removeAgent(toActor(arg1));
        else _syndicateVault_rescueERC20(address(wood), toActor(arg1), arg0);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function syndicateVault_deposit(uint256 assets, address receiver) public asActor {
        vault.deposit(assets, receiver);
    }

    function syndicateVault_mint(uint256 shares, address receiver) public asActor {
        vault.mint(shares, receiver);
    }

    function syndicateVault_withdraw(uint256 assets, address receiver, address owner_) public asActor {
        vault.withdraw(assets, receiver, owner_);
    }

    function syndicateVault_redeem(uint256 shares, address receiver, address owner_) public asActor {
        vault.redeem(shares, receiver, owner_);
    }

    function syndicateVault_requestDeposit(uint256 assets, address receiver) public asActor {
        vault.requestDeposit(assets, receiver);
    }

    function syndicateVault_requestRedeem(uint256 shares, address owner_) public asActor {
        vault.requestRedeem(shares, owner_);
    }

    function syndicateVault_transfer(address to, uint256 value) public asActor {
        vault.transfer(to, value);
    }

    function syndicateVault_transferFrom(address from, address to, uint256 value) public asActor {
        vault.transferFrom(from, to, value);
    }

    // ── Secondary: holder actions ──

    function _syndicateVault_approve(address spender, uint256 value) internal asActor {
        vault.approve(spender, value);
    }

    function _syndicateVault_delegate(address delegatee) internal asActor {
        vault.delegate(delegatee);
    }

    // ── Secondary: owner-gated ──

    function _syndicateVault_approveDepositor(address depositor) internal asAdmin {
        vault.approveDepositor(depositor);
    }

    function _syndicateVault_removeDepositor(address depositor) internal asAdmin {
        vault.removeDepositor(depositor);
    }

    function _syndicateVault_pause() internal asAdmin {
        vault.pause();
    }

    function _syndicateVault_unpause() internal asAdmin {
        vault.unpause();
    }

    function _syndicateVault_setOpenDeposits(bool open) internal asAdmin {
        vault.setOpenDeposits(open);
    }

    function _syndicateVault_setAgentFeeBps(uint256 bps) internal asAdmin {
        vault.setAgentFeeBps(bps);
    }

    function _syndicateVault_setMinBufferBps(uint16 bps) internal asAdmin {
        vault.setMinBufferBps(bps);
    }

    function _syndicateVault_registerAgent(uint256 agentId, address agentAddress) internal asAdmin {
        vault.registerAgent(agentId, agentAddress);
    }

    function _syndicateVault_removeAgent(address agentAddress) internal asAdmin {
        vault.removeAgent(agentAddress);
    }

    /// @dev Rescue targets a non-vault token on purpose: rescuing the vault
    ///      asset itself is what the queue-reserve guard (G-16) must refuse.
    function _syndicateVault_rescueERC20(address token, address to, uint256 amount) internal asAdmin {
        vault.rescueERC20(token, to, amount);
    }
}
