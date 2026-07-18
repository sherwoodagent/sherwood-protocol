// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {FeeConstants} from "./FeeConstants.sol";

/**
 * @title GovernorParameters
 * @notice Abstract contract managing governance parameter setters and bounds
 *         validation. Extracted from SyndicateGovernor to keep separation of
 *         concerns and relieve bytecode pressure.
 *
 *         Per-vault governor (beacon): each vault owns a governor instance.
 *         Setters are **vault-owner-instant** and gated behind
 *         `whenNoActiveProposal` so parameters cannot shift under in-flight
 *         proposals. The vault owner is expected to be a multisig.
 *
 *         All setters validate bounds at call time, apply immediately, and
 *         emit a uniform `ParameterChangeFinalized(paramKey, old, new)` event
 *         so indexers can subscribe to a single topic regardless of which
 *         parameter changed.
 */
abstract contract GovernorParameters is ISyndicateGovernor {
    // ── Safety bounds (hardcoded) ──

    // Per-deployment timing floors are constructor-set immutables (see constructor).
    // Mainnet impls deploy with the historical values (`votingPeriod` >= 24h,
    // `cooldownPeriod` >= 1h); a testnet impl can deploy with lower floors to
    // compress fund lifecycles. Immutables live in bytecode (not storage), so the
    // storage layout is UNCHANGED vs. the prior `constant` form and reads resolve
    // correctly through the beacon proxy. The absolute floor-of-floors below caps
    // how low a deploy may set them, so a misconfigured impl fails loudly.
    uint256 internal constant ABSOLUTE_MIN_TIMING_FLOOR = 1 minutes;

    /// @notice Hard floor for `votingPeriod` (per-deployment; mainnet 24h).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MIN_VOTING_PERIOD;
    uint256 public constant MAX_VOTING_PERIOD = 30 days;
    uint256 public constant MIN_EXECUTION_WINDOW = 1 hours;
    uint256 public constant MAX_EXECUTION_WINDOW = 7 days;
    uint256 public constant MIN_VETO_THRESHOLD_BPS = 2000; // 20%
    uint256 public constant MAX_VETO_THRESHOLD_BPS = 5000; // 50%
    uint256 public constant MAX_PERFORMANCE_FEE_CAP = FeeConstants.MAX_PERFORMANCE_FEE_BPS; // 15%
    uint256 public constant ABSOLUTE_MIN_STRATEGY_DURATION = 1 hours;
    // ~10y: supports indefinitely-lived strategies (e.g. leveraged Aerodrome CL). Params freeze and
    // the owner bond stays locked only WHILE a proposal is open — the proposer can self-settle 1h
    // after execute (MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE); only a non-proposer settle waits the
    // full duration, so the long tail binds only an abandoned proposal on a vault whose owner ≠ proposer.
    uint256 public constant ABSOLUTE_MAX_STRATEGY_DURATION = 3650 days;
    /// @notice Hard floor for `cooldownPeriod` (per-deployment; mainnet 1h).
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable MIN_COOLDOWN_PERIOD;
    uint256 public constant MAX_COOLDOWN_PERIOD = 30 days;
    /// @notice 100% in basis points. Centralized so SyndicateGovernor and
    ///         GuardianRegistry both reference one constant.
    /// @dev `internal` to avoid emitting an auto-getter (would add ~39 bytes
    ///      to SyndicateGovernor; this constant is for internal arithmetic only).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    // ── Collaborative proposal constants ──

    uint256 public constant MIN_SPLIT_BPS = 100; // 1%
    uint256 public constant MIN_COLLABORATION_WINDOW = 1 hours;
    uint256 public constant MAX_COLLABORATION_WINDOW = 7 days;
    uint256 public constant ABSOLUTE_MAX_CO_PROPOSERS = 10;

    // ── Parameter keys (event topic discriminators) ──

    bytes32 public constant PARAM_VOTING_PERIOD = keccak256("votingPeriod");
    bytes32 public constant PARAM_EXECUTION_WINDOW = keccak256("executionWindow");
    bytes32 public constant PARAM_VETO_THRESHOLD_BPS = keccak256("vetoThresholdBps");
    bytes32 public constant PARAM_MAX_PERF_FEE = keccak256("maxPerformanceFeeBps");
    bytes32 public constant PARAM_MIN_STRATEGY_DURATION = keccak256("minStrategyDuration");
    bytes32 public constant PARAM_MAX_STRATEGY_DURATION = keccak256("maxStrategyDuration");
    bytes32 public constant PARAM_COOLDOWN = keccak256("cooldownPeriod");
    bytes32 public constant PARAM_COLLAB_WINDOW = keccak256("collaborationWindow");
    bytes32 public constant PARAM_MAX_CO_PROPOSERS = keccak256("maxCoProposers");

    // ── Storage ──

    /// @notice The one vault this governor serves (set at initialize).
    address public vault;

    /// @notice ProtocolConfig reference — read at propose time for fee snapshots.
    address public protocolConfig;

    /// @notice Authorized factory that can call `forceSetParams` and `setProtocolConfig`.
    address public factory;

    /// @notice Packed governance parameters (voting/execution windows, veto,
    ///         fee caps, strategy duration bounds, collaboration window).
    GovernorParams internal _params;

    /// @notice Bootstrap owner used when `vault == address(0)` (protocol-level governor
    ///         that has not yet been assigned a vault). Set at initialize time.
    /// @dev    Allows `onlyVaultOwner` to function before the vault association is wired,
    ///         enabling deploy-script and test setups that follow the predict-then-deploy
    ///         pattern. In production, `vault` is always non-zero and `_bootstrapOwner`
    ///         is the deployer multisig until the factory wires the vault via `addVault`.
    address internal _bootstrapOwner;

    /// @dev Reserved storage slots at the `GovernorParameters` layer so future
    ///      param additions here don't shift `SyndicateGovernor`'s layout.
    uint256[8] private __paramsGap;

    // ── Constructor (impl-time; sets per-deployment timing floors) ──

    /// @param minVotingPeriod_   Hard floor for `votingPeriod` (mainnet 24h; a
    ///                           testnet impl may deploy lower to compress cycles).
    /// @param minCooldownPeriod_ Hard floor for `cooldownPeriod` (mainnet 1h).
    /// @dev Runs at implementation-deploy time; the values bake into bytecode and
    ///      are read through every per-vault BeaconProxy. Bounded so a fat-fingered
    ///      or arg-less deploy reverts rather than silently seating a 0 floor.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(uint256 minVotingPeriod_, uint256 minCooldownPeriod_) {
        if (minVotingPeriod_ < ABSOLUTE_MIN_TIMING_FLOOR || minVotingPeriod_ > MAX_VOTING_PERIOD) {
            revert InvalidVotingPeriod();
        }
        if (minCooldownPeriod_ < ABSOLUTE_MIN_TIMING_FLOOR || minCooldownPeriod_ > MAX_COOLDOWN_PERIOD) {
            revert InvalidCooldownPeriod();
        }
        MIN_VOTING_PERIOD = minVotingPeriod_;
        MIN_COOLDOWN_PERIOD = minCooldownPeriod_;
    }

    // ── Access control modifiers ──

    modifier onlyVaultOwner() {
        address _owner = vault != address(0) ? ISyndicateVault(vault).owner() : _bootstrapOwner;
        if (msg.sender != _owner) revert NotVaultOwner();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    modifier whenNoActiveProposal() {
        if (openProposalCount() > 0) revert ParamsFrozenDuringProposal();
        _;
    }

    // ── Bounds validator ──

    function _validateParamBounds(GovernorParams memory p) internal view {
        if (p.votingPeriod < MIN_VOTING_PERIOD || p.votingPeriod > MAX_VOTING_PERIOD) revert InvalidVotingPeriod();
        if (p.executionWindow < MIN_EXECUTION_WINDOW || p.executionWindow > MAX_EXECUTION_WINDOW) {
            revert InvalidExecutionWindow();
        }
        if (p.vetoThresholdBps < MIN_VETO_THRESHOLD_BPS || p.vetoThresholdBps > MAX_VETO_THRESHOLD_BPS) {
            revert InvalidVetoThresholdBps();
        }
        if (p.maxPerformanceFeeBps > MAX_PERFORMANCE_FEE_CAP) revert InvalidMaxPerformanceFeeBps();
        if (p.cooldownPeriod < MIN_COOLDOWN_PERIOD || p.cooldownPeriod > MAX_COOLDOWN_PERIOD) {
            revert InvalidCooldownPeriod();
        }
        if (
            p.minStrategyDuration < ABSOLUTE_MIN_STRATEGY_DURATION
                || p.maxStrategyDuration > ABSOLUTE_MAX_STRATEGY_DURATION
                || p.minStrategyDuration > p.maxStrategyDuration
        ) revert InvalidStrategyDurationBounds();
        // I2 (review): the individual setters bound these, so the rescue path
        // (initialize / forceSetParams) must too, or setParamsOverride could
        // seat an out-of-range value the setters would reject.
        if (p.collaborationWindow < MIN_COLLABORATION_WINDOW || p.collaborationWindow > MAX_COLLABORATION_WINDOW) {
            revert InvalidCollaborationWindow();
        }
        if (p.maxCoProposers == 0 || p.maxCoProposers > ABSOLUTE_MAX_CO_PROPOSERS) revert InvalidMaxCoProposers();
    }

    // ── Parameter setters (vault-owner-instant, frozen during proposals) ──

    /// @inheritdoc ISyndicateGovernor
    function setVotingPeriod(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        _validateVotingPeriod(newValue);
        uint256 old = _params.votingPeriod;
        _params.votingPeriod = newValue;
        emit ParameterChangeFinalized(PARAM_VOTING_PERIOD, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setExecutionWindow(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        _validateExecutionWindow(newValue);
        uint256 old = _params.executionWindow;
        _params.executionWindow = newValue;
        emit ParameterChangeFinalized(PARAM_EXECUTION_WINDOW, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setVetoThresholdBps(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        _validateVetoThresholdBps(newValue);
        uint256 old = _params.vetoThresholdBps;
        _params.vetoThresholdBps = newValue;
        emit ParameterChangeFinalized(PARAM_VETO_THRESHOLD_BPS, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setMaxPerformanceFeeBps(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        _validateMaxPerformanceFeeBps(newValue);
        uint256 old = _params.maxPerformanceFeeBps;
        _params.maxPerformanceFeeBps = newValue;
        emit ParameterChangeFinalized(PARAM_MAX_PERF_FEE, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setMinStrategyDuration(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        if (newValue < ABSOLUTE_MIN_STRATEGY_DURATION || newValue > _params.maxStrategyDuration) {
            revert InvalidStrategyDurationBounds();
        }
        uint256 old = _params.minStrategyDuration;
        _params.minStrategyDuration = newValue;
        emit ParameterChangeFinalized(PARAM_MIN_STRATEGY_DURATION, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setMaxStrategyDuration(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        if (newValue > ABSOLUTE_MAX_STRATEGY_DURATION || newValue < _params.minStrategyDuration) {
            revert InvalidStrategyDurationBounds();
        }
        uint256 old = _params.maxStrategyDuration;
        _params.maxStrategyDuration = newValue;
        emit ParameterChangeFinalized(PARAM_MAX_STRATEGY_DURATION, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setCooldownPeriod(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        _validateCooldownPeriod(newValue);
        uint256 old = _params.cooldownPeriod;
        _params.cooldownPeriod = newValue;
        emit ParameterChangeFinalized(PARAM_COOLDOWN, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setCollaborationWindow(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        if (newValue < MIN_COLLABORATION_WINDOW || newValue > MAX_COLLABORATION_WINDOW) {
            revert InvalidCollaborationWindow();
        }
        uint256 old = _params.collaborationWindow;
        _params.collaborationWindow = newValue;
        emit ParameterChangeFinalized(PARAM_COLLAB_WINDOW, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function setMaxCoProposers(uint256 newValue) external onlyVaultOwner whenNoActiveProposal {
        if (newValue == 0 || newValue > ABSOLUTE_MAX_CO_PROPOSERS) revert InvalidMaxCoProposers();
        uint256 old = _params.maxCoProposers;
        _params.maxCoProposers = newValue;
        emit ParameterChangeFinalized(PARAM_MAX_CO_PROPOSERS, old, newValue);
    }

    /// @inheritdoc ISyndicateGovernor
    function getGovernorParams() external view returns (GovernorParams memory) {
        return _params;
    }

    // ── Abstract view (implemented by SyndicateGovernor) ──

    function openProposalCount() public view virtual returns (uint256);

    // ── Validation helpers ──

    function _validateVotingPeriod(uint256 value) internal view {
        if (value < MIN_VOTING_PERIOD || value > MAX_VOTING_PERIOD) revert InvalidVotingPeriod();
    }

    function _validateExecutionWindow(uint256 value) internal pure {
        if (value < MIN_EXECUTION_WINDOW || value > MAX_EXECUTION_WINDOW) revert InvalidExecutionWindow();
    }

    function _validateVetoThresholdBps(uint256 value) internal pure {
        if (value < MIN_VETO_THRESHOLD_BPS || value > MAX_VETO_THRESHOLD_BPS) revert InvalidVetoThresholdBps();
    }

    function _validateMaxPerformanceFeeBps(uint256 value) internal pure {
        if (value > MAX_PERFORMANCE_FEE_CAP) revert InvalidMaxPerformanceFeeBps();
    }

    function _validateCooldownPeriod(uint256 value) internal view {
        if (value < MIN_COOLDOWN_PERIOD || value > MAX_COOLDOWN_PERIOD) revert InvalidCooldownPeriod();
    }
}
