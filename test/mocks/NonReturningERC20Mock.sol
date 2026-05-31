// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ERC-20 mock that mimics USDT on Ethereum mainnet — `transfer` and
///         `transferFrom` execute the state change and return WITHOUT pushing
///         a bool. The ABI decoder reverts on empty returndata trying to
///         decode `bool`, breaking naive `try IERC20(asset).transfer(...)
///         returns (bool r)` patterns.
///
///         Used to regression-test `GuardianRegistry._safeRewardTransfer`'s
///         SafeERC20-style success check (Sherlock run #3 #2).
contract NonReturningERC20Mock {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory n_, string memory s_, uint8 d_) {
        name = n_;
        symbol = s_;
        decimals = d_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    /// @dev USDT-style: no return value. Reverts on insufficient balance.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        unchecked {
            balanceOf[msg.sender] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        // NO `return true;` — that's the whole point.
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "insufficient");
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            unchecked {
                allowance[from][msg.sender] = allowed - amount;
            }
        }
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
}
