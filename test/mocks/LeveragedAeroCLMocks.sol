// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LeveragedAerodromeCLStrategy} from "../../src/strategies/LeveragedAerodromeCLStrategy.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Shared mocks / fixtures for the LeveragedAerodromeCLStrategy review test suites
// (LeveragedAeroCLReviewF13 / LeveragedAeroCLReviewR3). Consolidated so the two
// files stop re-declaring divergent copies of the same helpers.
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC-20 with test-only mint/burn.
contract MockToken {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n) {
        name = n;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function burn(address from, uint256 amt) external {
        balanceOf[from] -= amt;
        totalSupply -= amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockGovernor {
    uint256 public protocolFeeBps;
    address public protocolFeeRecipient;

    function setFee(uint256 bps, address recipient) external {
        protocolFeeBps = bps;
        protocolFeeRecipient = recipient;
    }
}

/// @dev Per-vault migration (#421): the strategy now resolves the protocol-fee params via
///      `vault.factory().protocolConfig()` instead of `vault.governor()`. This factory points
///      `protocolConfig()` back at the existing `MockGovernor` (which already exposes the
///      `protocolFeeBps()` / `protocolFeeRecipient()` IProtocolConfig read surface), so the
///      chain resolves without changing the fee mock's ctor or `setFee` call-sites.
contract MockFactory {
    address public protocolConfig;

    constructor(address pc) {
        protocolConfig = pc;
    }
}

/// @dev Vault whose `strategyMint` can be toggled to revert — modelling a PAUSED vault / de-whitelisted
///      feeRecipient (both make the fee-share mint revert). Two independent triggers, both honoured:
///        - `setMintReverts(true)`  → GLOBAL revert on every `strategyMint` (models a paused vault).
///        - `blockMintTo(to)`       → PER-ADDRESS revert (models `to` never `approveDepositor`'d, so the
///                                    fee mint to RECIPIENT reverts while the depositor's own mint succeeds).
///      `strategyMint(to,…)` reverts if EITHER trigger fires. `strategyBurn` always succeeds, mirroring the
///      real vault (burn is deliberately NOT `whenNotPaused`, so exits survive a pause).
contract MockVaultPausableMint {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public mintBlocked; // to => fee-mint reverts (un-whitelisted recipient)
    uint256 public totalSupply;
    address public governor;
    address public factory; // #421: strategy resolves protocol-fee params via factory().protocolConfig()
    bool public mintReverts; // global paused-vault flag

    constructor(address gov, address holder, uint256 shares) {
        governor = gov;
        // Wire the new resolution chain: factory().protocolConfig() → the same MockGovernor.
        // gov == address(0) → factory == address(0) preserves the "no protocol fee" case.
        factory = gov == address(0) ? address(0) : address(new MockFactory(gov));
        balanceOf[holder] = shares;
        totalSupply = shares;
    }

    /// @dev Toggle a GLOBAL mint revert (paused vault).
    function setMintReverts(bool v) external {
        mintReverts = v;
    }

    /// @dev Block `strategyMint(to, …)` — models `to` not being an approved depositor.
    function blockMintTo(address to) external {
        mintBlocked[to] = true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function strategyMint(address to, uint256 shares) external {
        require(!mintReverts, "PAUSED");
        require(!mintBlocked[to], "NOT_APPROVED_DEPOSITOR");
        balanceOf[to] += shares;
        totalSupply += shares;
    }

    function strategyBurn(uint256 shares) external {
        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;
    }
}

/// @dev mUSDC that funds the fast-path payout: `redeemUnderlying(amt)` burns `amt` face and delivers
///      `amt` USDC to the strategy. `cBal` = collateral face (must exceed the payout for the LTV gate).
contract MockCUsdcFunded {
    MockToken public usdc;
    address public strategy;
    uint256 public cBal;

    constructor(MockToken u, address s, uint256 c) {
        usdc = u;
        strategy = s;
        cBal = c;
    }

    function balanceOf(address) external view returns (uint256) {
        return cBal;
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18;
    }

    function redeemUnderlying(uint256 amt) external returns (uint256) {
        cBal -= amt;
        usdc.mint(strategy, amt);
        return 0;
    }
}

contract MockMarketZeroDebt {
    function borrowBalanceStored(address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Real-`nav()` harness (no override) → exercises the on-chain flat-book branch.
contract NavHarness is LeveragedAerodromeCLStrategy {}
