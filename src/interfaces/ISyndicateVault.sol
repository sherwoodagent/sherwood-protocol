// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BatchExecutorLib} from "../BatchExecutorLib.sol";

interface ISyndicateVault {
    // ── Errors ──
    error InvalidOwner();
    error InvalidExecutorImpl();
    error NotActiveAgent();
    error SimulationFailed();
    error InvalidDepositor();
    error DepositorAlreadyApproved();
    error DepositorNotApproved();
    error NotApprovedDepositor();
    error AgentAlreadyRegistered();
    error AgentNotActive();
    /// @notice Registering this agent would push `_agentSet.length()` past
    ///         `MAX_AGENTS_PER_VAULT` — bound for the `rotateOwnership`
    ///         deactivation loop.
    error AgentCapExceeded();
    error InvalidAgentRegistry();
    error NotAgentOwner();
    error NotGovernor();
    error RedemptionsLocked();
    error DepositsLocked();
    error InvalidAgentAddress();
    error TransferFailed();
    error ZeroAddress();
    error CannotRescueAsset();
    error NotFactory();
    error GovernorNotSet();
    error ExecutorCodehashMismatch();
    error InvalidAsset();
    /// @notice `transferPerformanceFee` was called with an `amount` exceeding
    ///         the vault's balance of `asset_`.
    error AmountExceedsBalance();
    error WithdrawalQueueNotSet();
    error WithdrawalQueueAlreadySet();
    error InsufficientShares();
    error RedemptionsNotLocked();
    error QueueReserveBreached();
    error NotQueue();
    error ZeroAssets();
    error SharesLocked();
    /// @notice `setAgentFeeBps` was called with `bps > MAX_AGENT_FEE_BPS`.
    error AgentFeeTooHigh();
    /// @notice `setMinBufferBps` was called with `bps > 5_000` (50%).
    error BufferTooHigh();
    error InstantExitFeeTooHigh();
    /// @notice A governor batch left the vault below the idle floor
    ///         (`reservedQueueAssets + minBufferBps%` of the pre-batch float).
    error BufferBreached();
    /// @notice The active strategy's `withdrawTo` delivered fewer assets than
    ///         requested (balance-diff verified vault-side).
    error UnwindShortfall();
    /// @notice The batch's net asset outflow exceeded the proposal's declared
    ///         maxCapital.
    error MaxNetOutflowExceeded(uint256 netOutflow, uint256 cap);
    /// @notice A governor-batch call carries a value-moving ERC20 selector
    ///         (approve / increaseAllowance / transfer / transferFrom) whose
    ///         spender/recipient is neither the vault itself nor an adapter
    ///         allowlisted in the TierRegistry.
    error DisallowedTransferTarget(address target, bytes4 selector, address recipient);
    /// @notice A governor-batch call carries a guarded value-moving selector but
    ///         its calldata is too short to hold the spender/recipient argument.
    error MalformedCall();

    // ── Init Params ──
    struct InitParams {
        address asset;
        string name;
        string symbol;
        address owner;
        address executorImpl;
        bool openDeposits;
        address agentRegistry;
        uint256 managementFeeBps;
    }

    // ── Per-Agent Config ──
    struct AgentConfig {
        uint256 agentId; // ERC-8004 identity token ID
        address agentAddress;
        bool active;
    }

    // ── Depositor Whitelist ──
    function approveDepositor(address depositor) external;
    function removeDepositor(address depositor) external;
    function approveDepositors(address[] calldata depositors) external;
    function isApprovedDepositor(address depositor) external view returns (bool);
    function approvedDepositorsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
    function setOpenDeposits(bool open) external;
    function openDeposits() external view returns (bool);

    // ── Views ──
    // Use `isAgent(addr)` for the auth check; there is no per-agent config getter.
    function getAgentCount() external view returns (uint256);
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory);
    function isAgent(address agentAddress) external view returns (bool);

    // ── Factory ──
    function factory() external view returns (address);

    // ── Governor ──
    function executeGovernorBatch(BatchExecutorLib.Call[] calldata calls, uint256 maxNetOutflow) external;
    function owner() external view returns (address);
    function transferPerformanceFee(address asset, address to, uint256 amount) external;
    function governor() external view returns (address);
    function redemptionsLocked() external view returns (bool);
    function managementFeeBps() external view returns (uint256);
    /// @notice Vault-owner-set agent performance fee (basis points). Defaults
    ///         to 5% (500) at vault creation. Snapshotted onto a proposal at
    ///         propose time and clamped to `maxPerformanceFeeBps` at settlement.
    function agentFeeBps() external view returns (uint256);
    /// @notice Set the agent performance fee (owner only). Capped at
    ///         `MAX_AGENT_FEE_BPS` (15%). Reverts with `AgentFeeTooHigh` above.
    function setAgentFeeBps(uint256 bps) external;
    /// @notice Idle-liquidity floor in basis points of the pre-batch float.
    ///         `executeGovernorBatch` reverts if a batch would leave less than
    ///         this fraction (plus the queue reserve) in the vault. 0 = off.
    function minBufferBps() external view returns (uint16);
    /// @notice Set the idle-liquidity floor (owner only, max 5_000 = 50%).
    function setMinBufferBps(uint16 bps) external;
    /// @notice Convenience view that resolves the active strategy through the
    ///         governor (`getProposal(activePid).strategy`). Returns
    ///         `address(0)` when no proposal is active or when the active
    ///         proposal opted out of live NAV.
    function activeStrategyAdapter() external view returns (address);

    // ── Async Withdrawal Queue ──
    function setWithdrawalQueue(address queue) external; // factory-only, set-once
    function withdrawalQueue() external view returns (address);
    function requestRedeem(uint256 shares, address owner_) external returns (uint256 requestId);
    function requestDeposit(uint256 assets, address receiver) external returns (uint256 requestId);
    function pendingQueueShares() external view returns (uint256);
    function reservedQueueAssets() external view returns (uint256);
    function settleRedeem(uint256 shares, uint256 assets, address to) external; // queue-only
    function settleDeposit(uint256 shares, address to) external; // queue-only
    function onProposalSettled(uint256 proposalId) external; // governor-only
    /// @notice Signed LP asset flow (Lane A deposits − instant exits) accrued
    ///         while the current proposal is active. The governor subtracts this
    ///         from the settlement float delta so mid-proposal flows don't
    ///         corrupt strategy PnL (and fees aren't charged on principal).
    function interimNetFlow() external view returns (int256);

    // ── Management-fee accrual (two-number fee model) ──

    /// @notice Governor-only: begin management-fee accrual for a newly executed
    ///         proposal, starting from zero.
    function startManagementAccrual() external;

    /// @notice Governor-only: settle up and return the accrued integral in
    ///         asset-seconds, then stop accruing.
    /// @return assetSeconds Fund assets integrated over time for this proposal.
    ///         The fee is `assetSeconds * rate / (BPS_DENOMINATOR * 365 days)`.
    function consumeManagementAccrual() external returns (uint256 assetSeconds);

    /// @notice Accrued asset-seconds including the interval still in progress.
    /// @dev View-only; does not restamp. Returns the stored figure unchanged
    ///      when no proposal is live.
    function managementAssetSeconds() external view returns (uint256);

    /// @notice Whether a management fee is currently accruing — true only while
    ///         a proposal is live. Capital idle between proposals accrues
    ///         nothing.
    function isAccruingManagementFee() external view returns (bool);

    // ── High-water mark (two-number fee model) ──

    /// @notice Emitted when the high-water mark is seeded or advanced.
    event HighWaterMarkUpdated(uint256 pricePerShare);

    /// @notice Assets per 1e18 shares, using the vault's own ERC-4626
    ///         conversion (and therefore its virtual-offset rounding).
    function pricePerShare() external view returns (uint256);

    /// @notice Highest price per share a performance fee has been charged at.
    function highWaterPricePerShare() external view returns (uint256);

    /// @notice Value above the mark, in assets — the performance-fee base.
    ///         Zero at or below the mark. Read it AFTER the management fee has
    ///         been taken, since that fee lowers the price per share.
    function aboveHighWaterMark() external view returns (uint256);

    /// @notice Governor-only: advance the mark to the current price per share.
    ///         Monotonic — a loss leaves it unchanged.
    function ratchetHighWaterMark() external;

    // ── Exit-time fee crystallization ──

    /// @notice Emitted when an instant exit pays its accrued fees on the way out.
    event ExitFeesCrystallized(address indexed owner, uint256 shares, uint256 mgmtFee, uint256 perfFee);

    /// @notice Management fees taken from instant exiters, awaiting payout at
    ///         the next settlement. Excluded from `totalAssets()`.
    function crystallizedMgmt() external view returns (uint256);

    /// @notice Performance fees taken from instant exiters, awaiting payout.
    ///         Excluded from `totalAssets()`.
    function crystallizedPerf() external view returns (uint256);

    /// @notice Fees `shares` would owe on an instant exit right now. Zero
    ///         outside a Lane A window — a queue exit bears its share through
    ///         the post-settlement price instead.
    function previewExitFees(uint256 shares) external view returns (uint256 mgmtFee, uint256 perfFee);

    /// @notice Governor-only: release parked management fees for payout.
    function consumeCrystallizedMgmt() external returns (uint256 amount);

    /// @notice Governor-only: release parked performance fees for payout. Call
    ///         only after `aboveHighWaterMark()` has been read — releasing
    ///         raises `totalAssets()` and would inflate that base.
    function consumeCrystallizedPerf() external returns (uint256 amount);

    // ── Early-exit penalty ──

    /// @notice Emitted when the owner changes the early-exit penalty rate.
    event InstantExitFeeUpdated(uint16 bps);

    /// @notice Early-exit penalty in basis points of the portion of an instant
    ///         exit that had to be pulled back from the strategy. Accrues to
    ///         the vault — the depositors who stay — never to a fee recipient.
    function instantExitFeeBps() external view returns (uint16);

    /// @notice Owner-only: set the early-exit penalty. Bounded by
    ///         `MAX_INSTANT_EXIT_FEE_BPS`.
    function setInstantExitFeeBps(uint16 bps) external;

    // ── Rescue ──
    function rescueEth(address payable to, uint256 amount) external;
    function rescueERC20(address token, address to, uint256 amount) external;
    function rescueERC721(address token, uint256 tokenId, address to) external;

    // ── Admin (syndicate creator) ──
    function registerAgent(uint256 agentId, address agentAddress) external;
    function removeAgent(address agentAddress) external;
    function pause() external;
    function unpause() external;

    // ── Events ──
    event AgentRegistered(uint256 indexed agentId, address indexed agentAddress);
    event AgentRemoved(address indexed agentAddress);
    event DepositorApproved(address indexed depositor);
    event DepositorRemoved(address indexed depositor);
    event OpenDepositsUpdated(bool open);
    /// @notice Emitted when the vault owner updates the agent performance fee.
    event AgentFeeUpdated(uint256 bps);
    /// @notice Emitted when the vault owner updates the idle-liquidity floor.
    event MinBufferUpdated(uint16 bps);
    /// @notice Emitted whenever the governor drives a strategy batch into the
    ///         vault via `executeGovernorBatch`. `callCount` is the number of
    ///         sub-calls fanned out by `BatchExecutorLib.executeBatch`.
    event GovernorBatchExecuted(address indexed governor, uint256 callCount);
    event WithdrawalQueueSet(address indexed queue);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event DepositRequested(uint256 indexed requestId, address indexed receiver, uint256 assets);
}
