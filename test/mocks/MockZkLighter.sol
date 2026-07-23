// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IZkLighter} from "../../src/lighter/IZkLighter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Mock zkLighter for unit tests. Registration is synchronous by default
///         (matches the deployed 4663 proxy + the fork); flip `asyncRegister` to
///         simulate a venue that defers account assignment. Records priority-
///         request calls for assertions; `withdrawPendingBalance` transfers real
///         mock-USDG. No constructor-set storage so it survives `vm.etch` at the
///         constant venue address (only the `usdg` immutable is baked into code).
contract MockZkLighter is IZkLighter {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdg;

    // Storage (all zero-initialized — etch-safe, no constructor writes).
    bool public asyncRegister; // false ⇒ synchronous (default)
    uint48 internal _accountCounter; // first assigned index = 623 (canary-flavored)
    mapping(address => uint48) internal _accountIndex;
    mapping(bytes32 => uint128) internal _pending;

    // Call recorders for assertions.
    uint256 public depositCount;
    uint256 public changePubKeyCount;
    uint256 public createOrderCount;
    uint256 public cancelAllCount;
    uint256 public withdrawCount;
    uint256 public claimCount;
    uint64 public lastWithdrawTicks;
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
        if (!asyncRegister && _accountIndex[to] == 0) {
            _accountCounter++;
            _accountIndex[to] = 622 + _accountCounter;
        }
    }

    function changePubKey(uint48, uint8, bytes calldata pubKey) external {
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
        createOrderCount++;
        lastOrder = Order(accountIndex_, market, baseAmount, price, isAsk, orderType);
    }

    function cancelAllOrders(uint48) external {
        cancelAllCount++;
    }

    function withdraw(uint48, uint16, uint8, uint64 baseAmount) external {
        withdrawCount++;
        lastWithdrawTicks = baseAmount;
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

    /// @notice Simulate a withdrawal maturing into `owner`'s claimable USDG balance.
    function setPendingBalance(address owner, uint128 ticks) external {
        _pending[_key(owner, 3)] = ticks;
    }

    function setAsyncRegister(bool v) external {
        asyncRegister = v;
    }

    /// @notice Manually register an account (simulates async registration landing).
    function registerAccount(address owner) external {
        if (_accountIndex[owner] == 0) {
            _accountCounter++;
            _accountIndex[owner] = 622 + _accountCounter;
        }
    }

    function _key(address owner, uint16 assetIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, assetIndex));
    }
}
