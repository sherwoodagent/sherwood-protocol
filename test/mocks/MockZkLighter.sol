// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IZkLighter} from "../../src/lighter/IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock zkLighter for unit tests.
///
///         Models the venue's THREE-STAGE fund lifecycle so failure modes are
///         expressible (the previous version validated nothing, which made
///         under-withdraw and premature-settle bugs untestable):
///
///           l2Balance  --withdraw(ticks)-->  queued  --mature()-->  pending
///                                                    --withdrawPendingBalance()--> ERC20
///
///         - `deposit` credits `l2Balance` (the margin account) and, unless
///           `asyncRegister` is set, registers the account synchronously
///           (matches the deployed 4663 proxy + the fork).
///         - `withdraw` REVERTS above `l2Balance` and moves ticks to `queued`.
///           It never matures in the same call — that is the async priority
///           request the two-phase settle exists for.
///         - `mature` / `maturePartial` are the test hooks that advance queued
///           ticks into `pending`. Nothing can mature that was not queued.
///         - `withdrawPendingBalance` is permissionless and transfers real
///           mock-USDG to the account owner.
///
///         Trading PnL is simulated with `creditL2` / `debitL2`. `creditL2`
///         only moves the venue's internal accounting — fund the venue's ERC20
///         balance separately (mint to this address) so the eventual claim can
///         actually pay out.
///
///         No constructor-set storage so it survives `vm.etch` at the constant
///         venue address (only the `usdg` immutable is baked into code).
contract MockZkLighter is IZkLighter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;

    // Storage (all zero-initialized — etch-safe, no constructor writes).
    bool public asyncRegister; // false ⇒ synchronous (default)
    uint48 internal _accountCounter; // first assigned index = 623 (canary-flavored)
    mapping(address => uint48) internal _accountIndex;
    mapping(uint48 => address) public accountOwner;
    mapping(bytes32 => uint128) internal _pending;

    /// @notice On-venue margin balance, in ticks (1 tick == 1 USDG base unit).
    mapping(address => uint256) public l2Balance;
    /// @notice Ticks requested via `withdraw` but not yet matured into `pending`.
    mapping(address => uint256) public queued;

    // Call recorders for assertions.
    uint256 public depositCount;
    uint256 public changePubKeyCount;
    uint256 public createOrderCount;
    uint256 public cancelAllCount;
    uint256 public withdrawCount;
    uint256 public claimCount;
    uint64 public lastWithdrawTicks;
    uint256 public totalWithdrawTicks;
    bytes public lastPubKey;

    struct Order {
        uint48 accountIndex;
        uint16 market;
        uint48 baseAmount;
        uint32 price;
        uint8 isAsk;
        uint8 orderType;
    }

    Order public lastOrder;

    constructor(IERC20 usdg_) {
        usdg = usdg_;
    }

    // ── IZkLighter ──

    function deposit(address to, uint16, uint8, uint256 amount) external payable {
        depositCount++;
        usdg.safeTransferFrom(msg.sender, address(this), amount);
        l2Balance[to] += amount;
        if (!asyncRegister && _accountIndex[to] == 0) {
            _accountCounter++;
            uint48 idx = 622 + _accountCounter;
            _accountIndex[to] = idx;
            accountOwner[idx] = to;
        }
    }

    function changePubKey(uint48 accountIndex_, uint8, bytes calldata pubKey) external {
        require(accountOwner[accountIndex_] != address(0), "unknown account");
        changePubKeyCount++;
        lastPubKey = pubKey;
    }

    function createOrder(
        uint48 accountIndex_,
        uint16 market,
        uint48 baseAmount,
        uint32 price,
        uint8 isAsk,
        uint8 orderType
    ) external {
        require(accountOwner[accountIndex_] != address(0), "unknown account");
        createOrderCount++;
        lastOrder = Order(accountIndex_, market, baseAmount, price, isAsk, orderType);
    }

    function cancelAllOrders(uint48 accountIndex_) external {
        require(accountOwner[accountIndex_] != address(0), "unknown account");
        cancelAllCount++;
    }

    /// @dev Queues an async priority request. Reverts above the on-venue margin
    ///      balance (the real venue rejects an over-withdraw too) and does NOT
    ///      mature in this call.
    function withdraw(uint48 accountIndex_, uint16, uint8, uint64 baseAmount) external {
        address owner = accountOwner[accountIndex_];
        require(owner != address(0), "unknown account");
        require(l2Balance[owner] >= baseAmount, "insufficient L2 balance");
        l2Balance[owner] -= baseAmount;
        queued[owner] += baseAmount;
        withdrawCount++;
        lastWithdrawTicks = baseAmount;
        totalWithdrawTicks += baseAmount;
    }

    function withdrawPendingBalance(address owner, uint16 assetIndex, uint128 baseAmount) external {
        claimCount++;
        bytes32 k = _key(owner, assetIndex);
        require(_pending[k] >= baseAmount, "insufficient pending");
        _pending[k] -= baseAmount;
        usdg.safeTransfer(owner, baseAmount); // 1 tick == 1 USDG base unit (6dp)
    }

    function getPendingBalance(address owner, uint16 assetIndex) external view returns (uint128) {
        return _pending[_key(owner, assetIndex)];
    }

    function addressToAccountIndex(address owner) external view returns (uint48) {
        return _accountIndex[owner];
    }

    function tokenToAssetIndex(address token) external view returns (uint16) {
        return token == address(usdg) ? 3 : 0;
    }

    // ── Test hooks ──

    /// @notice Mature EVERY queued tick for `owner` into the claimable pending balance.
    function mature(address owner) external {
        _mature(owner, queued[owner]);
    }

    /// @notice Mature only `ticks` of `owner`'s queued withdrawal (partial batch).
    function maturePartial(address owner, uint256 ticks) external {
        _mature(owner, ticks);
    }

    /// @notice Simulate on-venue trading profit (or an external credit). Fund this
    ///         contract's USDG balance separately so the claim can pay out.
    function creditL2(address owner, uint256 ticks) external {
        l2Balance[owner] += ticks;
    }

    /// @notice Simulate on-venue trading loss / fees.
    function debitL2(address owner, uint256 ticks) external {
        l2Balance[owner] -= ticks;
    }

    function setAsyncRegister(bool v) external {
        asyncRegister = v;
    }

    /// @notice Manually register an account (simulates async registration landing).
    function registerAccount(address owner) external {
        if (_accountIndex[owner] == 0) {
            _accountCounter++;
            uint48 idx = 622 + _accountCounter;
            _accountIndex[owner] = idx;
            accountOwner[idx] = owner;
        }
    }

    function _mature(address owner, uint256 ticks) internal {
        require(queued[owner] >= ticks, "not queued");
        queued[owner] -= ticks;
        _pending[_key(owner, 3)] += uint128(ticks);
    }

    function _key(address owner, uint16 assetIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, assetIndex));
    }
}
