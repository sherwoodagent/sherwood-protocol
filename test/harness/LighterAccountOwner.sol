// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IZkLighter} from "../../src/lighter/IZkLighter.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title  LighterAccountOwner
/// @notice Canary harness proving a SMART CONTRACT can own a Lighter (zkLighter)
///         perp account and run the full lifecycle: deposit USDG -> get a
///         contract-owned account -> register an agent L2 trading key ->
///         (agent trades via API) -> contract force-closes -> contract
///         withdraws USDG back to itself. Every mutation is onlyOwner so only
///         the deployer key drives the account.
/// @dev    Robinhood-mainnet (4663) canary only — NOT the production strategy.
///         USDG asset index = 3; RouteType Perps = 0; OrderType Market = 1.
contract LighterAccountOwner is Ownable {
    using SafeERC20 for IERC20;

    uint16 internal constant USDG_ASSET_INDEX = 3;
    uint8 internal constant ROUTE_PERPS = 0;
    uint8 internal constant ORDER_MARKET = 1;

    IZkLighter public immutable zkLighter;
    IERC20 public immutable usdg;

    error EthRescueFailed();

    constructor(address owner_, IZkLighter zk_, IERC20 usdg_) Ownable(owner_) {
        zkLighter = zk_;
        usdg = usdg_;
    }

    // ── Lifecycle (onlyOwner) ──

    /// @notice Approve + deposit `amount` USDG (6dp) into this contract's margin account.
    function depositUSDG(uint256 amount) external onlyOwner {
        usdg.forceApprove(address(zkLighter), amount);
        zkLighter.deposit(address(this), USDG_ASSET_INDEX, ROUTE_PERPS, amount);
    }

    /// @notice Register an agent L2 trading key (40-byte Goldilocks pubKey) at apiKeyIndex 2..254.
    function registerKey(uint8 apiKeyIndex, bytes calldata pubKey) external onlyOwner {
        zkLighter.changePubKey(accountIndex(), apiKeyIndex, pubKey);
    }

    /// @notice Open a market order (orderType = Market). `price` is the protective bound.
    function openOrder(uint16 market, uint48 baseAmount, uint32 price, uint8 isAsk) external onlyOwner {
        zkLighter.createOrder(accountIndex(), market, baseAmount, price, isAsk, ORDER_MARKET);
    }

    /// @notice On-chain kill switch: full market close (baseAmount = 0). Market SELL uses price = 1.
    function closeMarket(uint16 market, uint32 price, uint8 isAsk) external onlyOwner {
        zkLighter.createOrder(accountIndex(), market, 0, price, isAsk, ORDER_MARKET);
    }

    /// @notice Cancel all resting orders.
    function cancelAll() external onlyOwner {
        zkLighter.cancelAllOrders(accountIndex());
    }

    /// @notice Queue a USDG withdrawal (baseTicks: 1 USDG = 1e6 ticks).
    function initiateWithdraw(uint64 baseTicks) external onlyOwner {
        zkLighter.withdraw(accountIndex(), USDG_ASSET_INDEX, ROUTE_PERPS, baseTicks);
    }

    /// @notice Claim matured pending USDG back to this contract.
    function claim(uint128 baseTicks) external onlyOwner {
        zkLighter.withdrawPendingBalance(address(this), USDG_ASSET_INDEX, baseTicks);
    }

    // ── Views ──

    /// @notice This contract's Lighter account index (0 until the first deposit).
    function accountIndex() public view returns (uint48) {
        return zkLighter.addressToAccountIndex(address(this));
    }

    /// @notice USDG ticks matured and awaiting claim().
    function pendingBalance() external view returns (uint128) {
        return zkLighter.getPendingBalance(address(this), USDG_ASSET_INDEX);
    }

    /// @notice USDG (6dp) currently held by this contract.
    function usdgBalance() external view returns (uint256) {
        return usdg.balanceOf(address(this));
    }

    // ── Safety hatch (onlyOwner) ──

    function rescueERC20(IERC20 token, address to, uint256 amt) external onlyOwner {
        token.safeTransfer(to, amt);
    }

    function rescueETH(address to, uint256 amt) external onlyOwner {
        (bool ok,) = to.call{value: amt}("");
        if (!ok) revert EthRescueFailed();
    }

    receive() external payable {}
}
