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
    /// @notice `requestDeposit` was called with no non-terminal proposal open
    ///         on the vault (`openProposalCount() == 0`) — the async path is
    ///         only for entering while the instant `deposit`/`mint` path is
    ///         closed by an open proposal; use those instead.
    error NoOpenProposal();
    error QueueReserveBreached();
    error NotQueue();
    error ZeroAssets();
    /// @notice `setAgentFeeBps` was called with `bps > MAX_AGENT_FEE_BPS`.
    error AgentFeeTooHigh();
    /// @notice `setMinBufferBps` was called with `bps > 5_000` (50%).
    error BufferTooHigh();
    /// @notice A governor batch left the vault below the idle floor
    ///         (`reservedQueueAssets + minBufferBps%` of the pre-batch float).
    error BufferBreached();
    /// @notice The batch's net asset outflow exceeded the proposal's declared
    ///         maxCapital.
    error MaxNetOutflowExceeded(uint256 netOutflow, uint256 cap);
    /// @notice A governor-batch call carries a value-moving ERC20 selector
    ///         (approve / increaseAllowance / transfer / transferFrom) whose
    ///         spender/recipient is neither the vault itself nor an adapter
    ///         allowlisted in the TierRegistry.
    error DisallowedTransferTarget(address target, bytes4 selector, address recipient);
    /// @notice A governor batch named the vault or its withdrawal queue as a
    ///         call target. Rejected as a class, whatever the selector: the
    ///         batch executes under `delegatecall`, so `msg.sender == vault`
    ///         would satisfy those contracts' own trust gates.
    error DisallowedBatchTarget(address target);
    /// @notice A governor-batch call named a target that is neither the vault's
    ///         underlying `asset()` nor an adapter allowlisted in the TierRegistry.
    ///         Refused regardless of selector or calldata length — the callee gate
    ///         is what closes the unenumerable-selector class, and the selector
    ///         checks beneath it are defense-in-depth on allowlisted callees. Only
    ///         raised when the calling governor resolves a nonzero TierRegistry.
    error DisallowedBatchCallee(address target);
    /// @notice The calling governor resolved no TierRegistry — no `tierRegistry()`
    ///         getter, or one returning `address(0)`. The batch guard's callee
    ///         allowlist and spender/recipient gate cannot be evaluated without
    ///         it, so the batch is REFUSED rather than run unguarded (pashov
    ///         finding #1). Unreachable for governors this factory deploys;
    ///         `SyndicateFactory.pushWiring(governor)` rescues a pre-fix one.
    error TierRegistryUnresolved();
    /// @notice A governor-batch call carries a guarded value-moving selector but
    ///         its calldata is too short to hold the spender/recipient argument.
    error MalformedCall();
    /// @notice A governor-batch call targets the vault's own `asset()` with a
    ///         selector the batch guard does not recognize.
    /// @dev    `asset()` is the sole target exempted from the callee allowlist, on
    ///         the premise that the outer `netOutflow` balance diff independently
    ///         verifies it. That premise covers selectors which MOVE balance; it
    ///         does not cover a standing AUTHORIZATION grant (ERC-777
    ///         `authorizeOperator`, and any unenumerated allowance-delegation
    ///         shape), which moves nothing in-batch and is invisible to a balance
    ///         diff while the extraction it licenses lands in a later transaction.
    ///         Such a call also prices to zero coverage and zero proposer bond and
    ///         cannot be challenged. Non-`asset()` targets are already bounded by
    ///         the callee gate, so this rejection is scoped to `asset()` alone.
    error UnrecognizedAssetSelector(bytes4 selector);
    /// @notice A governor-batch call carries `transferFrom` whose `from` is not
    ///         the vault itself. Unconditional: pulling a third party's ERC20
    ///         allowance (e.g. an LP's deposit allowance) is not a capability
    ///         the tier system prices, so this is refused regardless of the
    ///         TierRegistry's presence or the `to` recipient.
    error DisallowedTransferFromSource(address target, address from);

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
    /// @notice Whether `target` is a privileged batch target — the vault
    ///         itself or its bound withdrawal queue — the SAME predicate
    ///         `executeGovernorBatch`'s `_guardBatchCalls` enforces. Exposed so
    ///         the governor's propose-time validation can consume this single
    ///         implementation instead of restating the address set; consumers
    ///         must never duplicate the check, only call through this view.
    function isPrivilegedBatchTarget(address target) external view returns (bool);
    /// @notice Run a governor-approved batch of calls, metering each call's
    ///         gross outflow of `asset()` against its declared `callCaps[i]`
    ///         (issue #43) and the whole batch's net outflow against
    ///         `maxNetOutflow`. `callCaps.length == 0` skips per-call
    ///         metering (the emergency-rescue escape valve); a non-empty
    ///         array whose length differs from `calls` reverts inside the
    ///         library (`CapsLengthMismatch`).
    function executeGovernorBatch(
        BatchExecutorLib.Call[] calldata calls,
        uint256[] calldata callCaps,
        uint256 maxNetOutflow
    ) external;
    /// @notice Factory-only: re-point the shared executor library and
    ///         re-stamp its expected codehash atomically. Reached through
    ///         `SyndicateFactory.pushExecutor`, which lifecycle-gates the
    ///         call (no open or executing proposal).
    function setExecutorImpl(address newImpl) external;
    function owner() external view returns (address);
    function transferPerformanceFee(address asset, address to, uint256 amount) external;
    /// @notice The ceiling `transferPerformanceFee` tests `amount` against —
    ///         asset balance less the queue reserve and the existing fee escrow.
    ///         Read by `SyndicateGovernor._payFee` so a failed transfer is
    ///         escrowed only up to what the vault can actually back; see the
    ///         implementation note for why an unbacked escrow is unrecoverable.
    function spendableFee(address asset) external view returns (uint256);
    function governor() external view returns (address);
    function redemptionsLocked() external view returns (bool);
    function managementFeeBps() external view returns (uint256);
    /// @notice Vault-owner-set agent performance fee (basis points). Defaults
    ///         to `FeeConstants.DEFAULT_AGENT_FEE_BPS` (2000 = 20%) while unset.
    ///         Snapshotted onto a proposal at propose time and clamped to
    ///         `maxPerformanceFeeBps` at settlement.
    function agentFeeBps() external view returns (uint256);
    /// @notice Set the agent performance fee (owner only). Capped at
    ///         `MAX_AGENT_FEE_BPS`, which aliases
    ///         `FeeConstants.MAX_PERFORMANCE_FEE_BPS` (3000 = 30%). Reverts with
    ///         `AgentFeeTooHigh` above.
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
    /// @notice Emitted by `setExecutorImpl` (factory-only, via
    ///         `SyndicateFactory.pushExecutor`) whenever the shared executor
    ///         library is re-pointed and its expected codehash re-stamped.
    event ExecutorImplSet(address oldImpl, address newImpl);
    event WithdrawalQueueSet(address indexed queue);
    event RedeemRequested(uint256 indexed requestId, address indexed owner, uint256 shares);
    event DepositRequested(uint256 indexed requestId, address indexed receiver, uint256 assets);
}
