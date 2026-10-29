// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";

/// @notice Paxos-shaped (USDG) surface: global pause and per-address freeze. Like PaxosTokenV2,
///         a frozen `from` or `to` reverts, and pause blocks transfers. `pauseApprovals` models
///         Paxos's `whenNotPaused` on approve as an opt-in so the escrow path can be reached.
contract PaxosLikeMock is ERC20 {
    bool public paused;
    bool public pauseApprovals;
    mapping(address => bool) public frozen;

    error Paused();
    error Frozen(address who);

    constructor() ERC20("Global Dollar", "USDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setPauseApprovals(bool p) external {
        pauseApprovals = p;
    }

    function freeze(address who, bool f) external {
        frozen[who] = f;
    }

    /// Paxos `wipeFrozenAddress`: an asset-protection burn of a frozen balance.
    function wipeFrozen(address who) external {
        require(frozen[who], "not frozen");
        _burn(who, balanceOf(who));
    }

    function _update(address from, address to, uint256 value) internal override {
        // mint/burn are supply-controller paths and ignore pause/freeze here.
        if (from != address(0) && to != address(0)) {
            if (paused) revert Paused();
            if (frozen[from]) revert Frozen(from);
            if (frozen[to]) revert Frozen(to);
        }
        super._update(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value, bool emitEvent) internal override {
        if (pauseApprovals && paused) revert Paused();
        super._approve(owner, spender, value, emitEvent);
    }
}

/// @notice Takes `feeBps` from the recipient's credit (STA/PAXG shape).
contract FeeOnTransferMock is ERC20 {
    uint256 public constant FEE_BPS = 100;
    address public constant SINK = address(0xFEE);

    constructor() ERC20("FoT", "FOT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0)) return super._update(from, to, value);
        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, SINK, fee);
        super._update(from, to, value - fee);
    }
}

/// @notice Reverts on a zero-value transfer (LEND shape).
contract RevertOnZeroMock is ERC20 {
    constructor() ERC20("Zero", "ZERO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value != 0, "zero transfer");
        super._update(from, to, value);
    }
}

/// @notice No return value on transfer (USDT shape).
contract NoReturnMock {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice Returns false instead of reverting (ZRX/EURS shape), moving nothing.
contract ReturnsFalseMock {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @notice Balance rebases by a multiplier outside of transfers (AMPL/stETH shape).
contract RebasingMock {
    mapping(address => uint256) internal _shares;
    uint256 public index = 1e18;

    function mint(address to, uint256 amount) external {
        _shares[to] += (amount * 1e18) / index;
    }

    function rebase(uint256 newIndex) external {
        index = newIndex;
    }

    function balanceOf(address a) external view returns (uint256) {
        return (_shares[a] * index) / 1e18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 s = (amount * 1e18) / index;
        _shares[msg.sender] -= s;
        _shares[to] += s;
        return true;
    }
}

/// @notice Attacker-supplied token: lies about balanceOf and, on transfer, tries to re-enter the
///         router to move a REAL token. Swallows the failure so the outer call succeeds.
contract MaliciousToken {
    ProtocolFeeRouter public router;
    address public realToken;
    bool public reentrySucceeded;
    bytes public reentryRevert;

    constructor(ProtocolFeeRouter r, address real) {
        router = r;
        realToken = real;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1e30;
    }

    function transfer(address, uint256) external returns (bool) {
        address[] memory toks = new address[](1);
        toks[0] = realToken;
        try router.distributeMany(toks) {
            reentrySucceeded = true;
        } catch (bytes memory r) {
            reentryRevert = r;
        }
        try router.claimEscrowedFees(address(this), address(this), realToken) {
            reentrySucceeded = true;
        } catch {}
        try router.rescue(realToken, address(this), 1) {
            reentrySucceeded = true;
        } catch {}
        return true;
    }

    /// Doubles as a fake governor for `claimEscrowedFees`.
    function claimUnclaimedFees(address, address) external {
        try router.distribute(realToken) {
            reentrySucceeded = true;
        } catch (bytes memory r) {
            reentryRevert = r;
        }
    }
}
