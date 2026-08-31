// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsLaunchFactory} from "../../src/vendor/pons/IPonsLaunch.sol";
import {MockPonsLocker} from "./MockPonsLocker.sol";
import {ERC20Mock} from "./ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title  MockPonsFactory
/// @notice Faithful-enough double for `PonsLaunchFactory` v2 (`0xA5aA…1feB` on
///         Robinhood 4663). It reproduces the behaviours `PonsLaunchAdapter`
///         depends on and nothing else:
///           - THE GATE: `if (!launchEnabled && !whitelistedLaunchers[msg.sender])
///             revert NotWhitelisted();`, which is `false`/empty on mainnet and
///             is the live blocker the adapter is written against;
///           - a NATIVE launch fee taken from `msg.value` and forwarded to the
///             locker's `protocolFeeRecipient`, with the REMAINDER
///             (`msg.value - launchFee`) funding the dev buy — so both legs are
///             native, unlike Sushi;
///           - NO SLIPPAGE FLOOR on that buy. Upstream hardcodes
///             `amountOutMinimum: 0`, so this mock enforces nothing either:
///             the adapter's own post-launch balance check is the only guard,
///             and a test that lowers `rate` proves it;
///           - `feeWallet` DOING DOUBLE DUTY — it is the buy's recipient AND
///             the locker redirect the factory sets — which is the exact knot
///             `PonsLaunchAdapter.launch` unties in one transaction;
///           - the whole supply locked in the position (modelled as "held by
///             this contract"), so the creator receives ZERO tokens;
///           - a CREATE2 COLLISION on identical metadata under one salt and
///             deployer, which is what the adapter's per-caller salt
///             namespacing exists to avoid;
///           - `getLaunchedToken` RETURNING A ZERO STRUCT for an unissued
///             token (it does not revert — the opposite of Sushi), while
///             `graduationStatus` DOES revert `TokenNotFound`.
///         Test knobs (`setRate`, `setLaunchFee`, `setLaunchEnabled`,
///         `setWhitelistedLauncher`, config setters) drive the adapter's edges;
///         the real venue prices the buy off a fresh V3 pool instead.
contract MockPonsFactory {
    /// @notice Launch tokens delivered per 1e18 of native spent on the dev buy.
    ///         Lower it to stage an under-delivery the venue would happily
    ///         settle.
    uint256 public rate = 1e18;

    address public immutable locker;
    uint256 public launchFee;
    bool public launchEnabled;

    mapping(address => bool) public whitelistedLaunchers;
    mapping(address => IPonsLaunchFactory.LaunchedToken) internal _launched;
    mapping(bytes32 => bool) internal _usedInitCode;

    IPonsLaunchFactory.LaunchConfig[] internal _launchConfigs;
    IPonsLaunchFactory.DexConfig[] internal _dexConfigs;

    error NotWhitelisted();
    error LaunchFeeNotPaid();
    error FeeTransferFailed();
    error InvalidDexId();
    error InvalidLaunchConfigId();
    error DexDisabled();
    error LaunchConfigDisabled();
    error InvalidTokenParams();
    error PoolAlreadyExists();
    error RouterNotSet();
    error TokenNotFound();

    constructor(address locker_) {
        locker = locker_;
    }

    // ── venue-owner knobs ──

    function setLaunchFee(uint256 fee) external {
        launchFee = fee;
    }

    function setLaunchEnabled(bool enabled) external {
        launchEnabled = enabled;
    }

    function setWhitelistedLauncher(address launcher, bool enabled) external {
        whitelistedLaunchers[launcher] = enabled;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function addLaunchConfig(IPonsLaunchFactory.LaunchConfig calldata config) external returns (uint256 id) {
        id = _launchConfigs.length;
        _launchConfigs.push(config);
    }

    function addDexConfig(IPonsLaunchFactory.DexConfig calldata config) external returns (uint256 id) {
        id = _dexConfigs.length;
        _dexConfigs.push(config);
    }

    function setLaunchConfigEnabled(uint256 id, bool enabled) external {
        _launchConfigs[id].enabled = enabled;
    }

    function setLaunchConfigPairToken(uint256 id, address pairToken) external {
        _launchConfigs[id].pairToken = pairToken;
    }

    function setDexEnabled(uint256 id, bool enabled) external {
        _dexConfigs[id].enabled = enabled;
    }

    function setDexSwapRouter(uint256 id, address router) external {
        _dexConfigs[id].swapRouter = router;
    }

    // ── venue surface ──

    function launchConfigCount() external view returns (uint256) {
        return _launchConfigs.length;
    }

    function dexConfigCount() external view returns (uint256) {
        return _dexConfigs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (IPonsLaunchFactory.LaunchConfig memory) {
        if (id >= _launchConfigs.length) revert InvalidLaunchConfigId();
        return _launchConfigs[id];
    }

    function getDexConfig(uint256 id) external view returns (IPonsLaunchFactory.DexConfig memory) {
        if (id >= _dexConfigs.length) revert InvalidDexId();
        return _dexConfigs[id];
    }

    /// @dev Zero struct for an unissued token — no revert. This is the venue
    ///      behaviour that makes `exists` (and not call success) the thing
    ///      `phase` keys off.
    function getLaunchedToken(address token) external view returns (IPonsLaunchFactory.LaunchedToken memory) {
        return _launched[token];
    }

    /// @dev REVERTS for an unissued token, unlike `getLaunchedToken`.
    function graduationStatus(address token) external view returns (uint256, uint256, bool) {
        if (!_launched[token].exists) revert TokenNotFound();
        uint256 threshold = _launchConfigs[_launched[token].launchConfigId].graduationThreshold;
        return (0, threshold, false);
    }

    function launchToken(
        IPonsLaunchFactory.TokenParams calldata params,
        uint256 launchConfigId,
        uint256 dexId,
        bytes32 salt
    ) external payable returns (address token) {
        if (!launchEnabled && !whitelistedLaunchers[msg.sender]) revert NotWhitelisted();
        if (msg.value < launchFee) revert LaunchFeeNotPaid();
        if (dexId >= _dexConfigs.length) revert InvalidDexId();
        if (launchConfigId >= _launchConfigs.length) revert InvalidLaunchConfigId();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTokenParams();

        IPonsLaunchFactory.DexConfig memory dex = _dexConfigs[dexId];
        IPonsLaunchFactory.LaunchConfig memory config = _launchConfigs[launchConfigId];
        if (!dex.enabled) revert DexDisabled();
        if (!config.enabled) revert LaunchConfigDisabled();

        // Stands in for the CREATE2 init-code-hash collision: upstream hashes
        // the metadata, the config/dex parameters and the DEPLOYER, so the same
        // launch twice under one salt predicts one address.
        bytes32 initKey = keccak256(abi.encode(params.name, params.symbol, launchConfigId, dexId, msg.sender, salt));
        if (_usedInitCode[initKey]) revert PoolAlreadyExists();
        _usedInitCode[initKey] = true;

        address initialBuyRecipient = params.feeWallet == address(0) ? msg.sender : params.feeWallet;
        _payLaunchFee();

        ERC20Mock launchedToken = new ERC20Mock(params.name, params.symbol, 18);
        token = address(launchedToken);
        // The whole float goes into the position that is handed to the locker;
        // the creator receives nothing.
        launchedToken.mint(address(this), config.supply);

        uint256 initialBuyAmount = msg.value - launchFee;
        _launched[token] = IPonsLaunchFactory.LaunchedToken({
            token: token,
            deployer: msg.sender,
            pairedToken: config.pairToken,
            positionManager: dex.positionManager,
            positionId: uint256(uint160(token)),
            dexId: dexId,
            launchConfigId: launchConfigId,
            restrictionsEndBlock: block.number + config.restrictionBlocks,
            supply: config.supply,
            isToken0: token < config.pairToken,
            poolFee: dex.poolFee,
            exists: true,
            initialBuyAmount: initialBuyAmount
        });

        MockPonsLocker(locker).lockPosition(token);
        if (params.feeWallet != address(0)) {
            MockPonsLocker(locker).setFeeRedirect(token, params.feeWallet);
        }

        if (initialBuyAmount != 0) {
            if (dex.swapRouter == address(0)) revert RouterNotSet();
            // NO `amountOutMinimum`: upstream passes 0, so nothing here checks
            // the output either.
            uint256 amountOut = (initialBuyAmount * rate) / 1e18;
            if (amountOut > config.supply) amountOut = config.supply;
            launchedToken.transfer(initialBuyRecipient, amountOut);
        }
    }

    /// @dev Forwarded to the locker's protocol fee recipient, exactly as
    ///      upstream — so a test can assert the native actually left.
    function _payLaunchFee() private {
        if (launchFee == 0) return;
        address recipient = MockPonsLocker(locker).protocolFeeRecipient();
        (bool sent,) = payable(recipient).call{value: launchFee}("");
        if (!sent) revert FeeTransferFailed();
    }

    /// @dev Moves part of the locked float out of the "position" so a test can
    ///      stage collectable launch-token fees as a REAL locker balance. The
    ///      pair-token leg is funded by the test directly, since this venue's
    ///      factory never holds the pair token.
    function sendLockedTokens(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }
}
