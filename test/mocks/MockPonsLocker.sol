// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsLaunchFactory} from "../../src/vendor/pons/IPonsLaunch.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockPonsLocker
/// @notice Faithful-enough double for `PonsLaunchLocker` (`0x736D…7F35` on
///         Robinhood 4663). It reproduces the behaviours `PonsLaunchAdapter`
///         depends on and nothing else:
///           - a `factory` bound once by `initialize`, and reported back by
///             `factory()` — the round trip the adapter's constructor makes;
///           - `setFeeRedirect` authorised for the launch's DEPLOYER or the
///             factory, which is the permission the whole one-transaction
///             reserve/fee split rests on;
///           - `collectFees` GATED (owner | deployer | current recipient |
///             allowlisted collector), reverting `NoFeesToCollect()` when
///             nothing accrued, and paying the recipient the gross MINUS the
///             protocol share — so a test can prove the adapter reports the
///             recipient's deltas and not the locker's return tuple;
///           - `feeRedirects` readable, and falling back to the deployer when
///             unset, exactly as upstream.
///         Test knobs (`setFeesOwed`, `setCollectReverts`, `setProtocolFeeShare`)
///         drive the adapter's edges; the real locker collects from a live V3
///         position instead.
contract MockPonsLocker {
    /// @notice The live locker's `protocolFeeShare()` is 30 (percent).
    uint256 public constant DEFAULT_PROTOCOL_FEE_SHARE = 30;

    address public owner;
    address public factory;
    address public protocolFeeRecipient;
    uint256 public protocolFeeShare = DEFAULT_PROTOCOL_FEE_SHARE;
    bool public collectReverts;

    mapping(address => address) public feeRedirects;
    mapping(address => bool) public feeCollectors;
    mapping(address => bool) public locked;
    /// @notice Pending fees, split by leg: `pairedOwed` is the pair-token leg,
    ///         `tokenOwed` the launch-token leg.
    mapping(address => uint256) public pairedOwed;
    mapping(address => uint256) public tokenOwed;

    error NotFactory();
    error NotAuthorized();
    error NotDeployer();
    error TokenNotFound();
    error NoFeesToCollect();
    error AlreadyInitialized();
    error CollectFailed();

    constructor(address protocolFeeRecipient_) {
        owner = msg.sender;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    // ── venue-owner knobs (test-side stand-ins for the real setters) ──

    function initialize(address factory_) external {
        if (factory != address(0)) revert AlreadyInitialized();
        factory = factory_;
    }

    function setProtocolFeeShare(uint256 share) external {
        protocolFeeShare = share;
    }

    function setFeeCollector(address collector, bool enabled) external {
        feeCollectors[collector] = enabled;
    }

    function setCollectReverts(bool value) external {
        collectReverts = value;
    }

    /// @dev Stages fees as REAL balances on this contract, so `collectFees`
    ///      moves actual tokens and the adapter's deltas are measured against
    ///      transfers rather than bookkeeping.
    function setFeesOwed(address token, uint256 pairedAmount, uint256 tokenAmount) external {
        pairedOwed[token] = pairedAmount;
        tokenOwed[token] = tokenAmount;
    }

    // ── venue surface ──

    function lockPosition(address token) external {
        if (msg.sender != factory) revert NotFactory();
        locked[token] = true;
    }

    /// @dev Callable by the launch DEPLOYER or the factory — the authorisation
    ///      that lets a singleton adapter re-point the fee stream in the launch
    ///      transaction.
    function setFeeRedirect(address token, address newFeeWallet) external {
        IPonsLaunchFactory.LaunchedToken memory launched = IPonsLaunchFactory(factory).getLaunchedToken(token);
        if (!launched.exists) revert TokenNotFound();
        if (msg.sender != launched.deployer && msg.sender != factory) revert NotDeployer();
        feeRedirects[token] = newFeeWallet;
    }

    /// @dev NOT permissionless: the real locker admits only the owner, the
    ///      deployer, the current recipient, or an allowlisted collector.
    ///      Returns the GROSS while paying the recipient the net.
    function collectFees(address token) external returns (uint256 amount0, uint256 amount1) {
        IPonsLaunchFactory.LaunchedToken memory launched = IPonsLaunchFactory(factory).getLaunchedToken(token);
        if (!launched.exists || !locked[token]) revert TokenNotFound();

        address recipient = feeRedirects[token];
        if (recipient == address(0)) recipient = launched.deployer;
        if (
            msg.sender != owner && msg.sender != launched.deployer && msg.sender != recipient
                && !feeCollectors[msg.sender]
        ) {
            revert NotAuthorized();
        }
        if (collectReverts) revert CollectFailed();

        amount0 = pairedOwed[token];
        amount1 = tokenOwed[token];
        if (amount0 == 0 && amount1 == 0) revert NoFeesToCollect();
        pairedOwed[token] = 0;
        tokenOwed[token] = 0;

        uint256 protocol0 = (amount0 * protocolFeeShare) / 100;
        uint256 protocol1 = (amount1 * protocolFeeShare) / 100;
        _pay(launched.pairedToken, protocolFeeRecipient, protocol0);
        _pay(token, protocolFeeRecipient, protocol1);
        _pay(launched.pairedToken, recipient, amount0 - protocol0);
        _pay(token, recipient, amount1 - protocol1);
    }

    function _pay(address token, address to, uint256 amount) private {
        if (amount != 0) IERC20(token).transfer(to, amount);
    }
}
