// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IProposalStatus} from "./interfaces/IProposalStatus.sol";
import {FeeConstants} from "./FeeConstants.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {IVaultWithdrawalQueue} from "./interfaces/IVaultWithdrawalQueue.sol";
import {IPriceRouter} from "./interfaces/IPriceRouter.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
import {SyndicateVaultAdminLib} from "./SyndicateVaultAdminLib.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {
    ERC20VotesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SyndicateVault
 * @notice ERC-4626 vault for agent-managed investment syndicates.
 *
 *   The vault is the onchain identity — it holds all positions (mTokens, borrows,
 *   swapped tokens) via delegatecall to a shared BatchExecutorLib. Deploy one
 *   executor lib, share it across all syndicates.
 *
 *   Strategy execution goes through the governor via proposals
 *   (executeGovernorBatch). Asset recovery uses dedicated rescueERC20 /
 *   rescueERC721 / rescueEth paths. The owner has no arbitrary-calldata entry
 *   point into the vault.
 *
 *   Inherits ERC20VotesUpgradeable to provide proper vote checkpointing for
 *   the governor's snapshot-based voting system.
 *
 *   Deployed as ERC-1967 UUPS proxy. Upgradeable only via the factory when upgrades are enabled.
 */
contract SyndicateVault is
    ISyndicateVault,
    Initializable,
    ERC4626Upgradeable,
    ERC20VotesUpgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ERC721Holder,
    ReentrancyGuardTransient
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // ==================== CONSTANTS ====================

    /// @notice Maximum rows returned by any paginated view in a single call.
    ///         Prevents unbounded iteration from out-of-gassing a page fetch
    ///         even when the underlying set is large.
    uint256 public constant MAX_PAGE_LIMIT = 100;
    /// @notice Hard cap on agents per vault so the `rotateOwnership`
    ///         deactivation loop has a predictable upper bound and cannot OOG.
    ///         32 SSTOREs ~= 6.4k gas — fits comfortably in any block.
    ///         `removeAgent` frees a slot.
    uint256 public constant MAX_AGENTS_PER_VAULT = 32;

    /// @notice Hard cap on the vault-owner-set agent performance fee (30%),
    ///         equal to the governor's `MAX_PERFORMANCE_FEE_CAP` — the protocol
    ///         ceiling on `maxPerformanceFeeBps`. The governor additionally
    ///         clamps the realized fee to its (lower, tunable) configured
    ///         `maxPerformanceFeeBps` at settlement, so a stored value above the
    ///         live param is never charged. Capping here at the same ceiling
    ///         keeps `agentFeeBps()` from advertising a rate that can never be
    ///         realized.
    /// @dev This ceiling is a backstop, not the headline rate. A vault created
    ///      through the factory starts with a per-vault `maxPerformanceFeeBps`
    ///      of `FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS` (20%), so setting
    ///      above the headline here is legal but clamped at settlement until
    ///      governance raises that param.
    uint256 public constant MAX_AGENT_FEE_BPS = FeeConstants.MAX_PERFORMANCE_FEE_BPS;

    /// @notice Cap on the owner-set idle-liquidity floor (50%).
    uint256 private constant MAX_MIN_BUFFER_BPS = 5_000;

    /// @notice Cap on the early-exit penalty (2%).
    uint256 public constant MAX_INSTANT_EXIT_FEE_BPS = 200;

    // ── Value-moving ERC20 selectors guarded in governor batches ──
    // (see `_guardBatchCalls`)
    bytes4 private constant _SEL_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _SEL_INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)
    bytes4 private constant _SEL_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)

    // ==================== STORAGE ====================

    /// @notice Agent address => agent config
    mapping(address => AgentConfig) private _agents;

    /// @notice Set of all registered agent addresses
    EnumerableSet.AddressSet private _agentSet;

    /// @notice Shared executor lib (stateless, called via delegatecall)
    address private _executorImpl;

    /// @notice Approved depositor addresses (whitelist for deposits)
    EnumerableSet.AddressSet private _approvedDepositors;

    /// @notice If true, anyone can deposit (skip whitelist check)
    bool private _openDeposits;

    /// @notice ERC-8004 agent identity registry (ERC-721)
    IERC721 private _agentRegistry;

    // ── Governor / Factory storage ──

    /// @notice Vault owner's management fee on strategy profits (basis points, set at init)
    uint256 private _managementFeeBps;

    /// @notice Factory that deployed this vault (controls upgrades, provides governor address)
    address private _factory;

    /// @notice Expected bytecode hash of `_executorImpl`, stamped at init.
    ///         Re-verified on every delegatecall so a swapped-in library cannot
    ///         impersonate `BatchExecutorLib` without matching its bytecode.
    bytes32 private _expectedExecutorCodehash;

    /// @notice Cached `asset.decimals()` used as the ERC-4626 virtual-shares
    ///         offset. Stamped once at `initialize` so `_decimalsOffset()` is
    ///         a pure storage read on the hot share-conversion path (no
    ///         external call to the asset on every `previewDeposit` /
    ///         `convertTo*` / `_deposit` / `_withdraw`).
    uint8 private _cachedDecimalsOffset;

    /// @notice Per-vault async withdrawal queue (set-once at deploy by the factory).
    address private _withdrawalQueue;

    /// @notice Lane A (instant) per-holder lockup: the proposal id whose Lane A
    ///         entry locked this holder's shares. The holder cannot exit (Lane A
    ///         redeem or Lane B requestRedeem) while that proposal is still the
    ///         active one — closes the deposit-low / exit-high intra-proposal MEV.
    ///         Cleared implicitly when the proposal settles (active != pid).
    mapping(address holder => uint256 pid) private _laneALockPid;

    /// @notice Vault-owner-set agent performance fee, stored offset-by-one so a
    ///         single slot doubles as the "is it set?" flag: 0 = never set →
    ///         `agentFeeBps()` returns `FeeConstants.DEFAULT_AGENT_FEE_BPS` (5%);
    ///         otherwise the stored value is `fee + 1`, so an explicit 0% (a
    ///         stored 1) stays distinct from unset. One SLOAD on the propose
    ///         hot path. Snapshotted onto a proposal at propose (clamped to the
    ///         governor's `maxPerformanceFeeBps`); set via `setAgentFeeBps`.
    uint256 private _agentFeeBpsPlusOne;

    /// @notice Idle-liquidity floor (bps of pre-batch float) enforced against
    ///         governor batches. 0 = off. Packed with `minHoldingPeriod`.
    uint16 public minBufferBps;

    /// @notice Seconds an account must hold after a deposit before instant
    ///         exit (anti flash-arb, GLP-cooldown pattern). Lane B is exempt.
    /// @dev Not yet exposed via ISyndicateVault; kept non-public to stay under
    ///      the EIP-170 runtime size limit. Storage slot/type reserved for
    ///      future instant-exit logic.
    uint32 internal minHoldingPeriod;

    /// @notice Early-exit penalty on a Lane A instant exit, in basis points of
    ///         the portion that had to be pulled back from the strategy.
    /// @dev Accrues to the VAULT — the depositors who stay — not to any fee
    ///      recipient. It is an anti-mercenary redemption term compensating
    ///      them for the forced unwind, not revenue, which is why it is
    ///      deliberately NOT excluded from `totalAssets()` the way crystallized
    ///      fees are. Packs into the slot above (16 + 32 + 16 bits), so the
    ///      linear layout is unchanged and no `__gap` slot is consumed.
    uint16 public instantExitFeeBps;

    /// @notice Net LP asset flow (deposits − instant exits) accumulated while
    ///         the current proposal is active. Read by the governor at
    ///         settlement so mid-proposal flows don't corrupt strategy PnL;
    ///         reset in `onProposalSettled`.
    int256 private _interimNetFlow;

    /// @notice Timestamp of each account's most recent instant deposit
    ///         (receiver-side). Gates instant exit via `minHoldingPeriod`.
    /// @dev Not yet exposed via ISyndicateVault; kept non-public to stay under
    ///      the EIP-170 runtime size limit. Storage slot/type reserved for
    ///      future instant-exit logic.
    mapping(address => uint40) internal lastDepositAt;

    // ── Two-number fee model (management + performance) ──

    /// @notice Integral of fund assets over time for the live proposal, in
    ///         asset-seconds. The management fee is this figure annualized:
    ///         `fee = assetSeconds * rate / (BPS_DENOMINATOR * 365 days)`.
    /// @dev Exact under arbitrary mid-proposal flows because the integral is
    ///      piecewise-constant: every base-changing event closes off the
    ///      elapsed interval at the base that applied during it, then restamps.
    uint256 private _mgmtAssetSeconds;

    /// @notice Fund assets in force since `_mgmtLastUpdate` — the height of the
    ///         current rectangle in the integral above.
    uint192 private _mgmtBase;

    /// @notice When `_mgmtBase` was last restamped. Zero means "not accruing":
    ///         no proposal is live, so no management fee is owed. This is the
    ///         gate that keeps capital idle between proposals free, and it also
    ///         keeps `totalAssets()` (an external call for live NAV) off the
    ///         ordinary deposit path.
    uint64 private _mgmtLastUpdate;

    /// @notice Highest price per share this fund has ever been charged a
    ///         performance fee at, carrying the ERC-4626 virtual offsets.
    ///         Performance fee applies only above this mark, so a fund that
    ///         falls and recovers is not charged twice on the same dollars.
    uint256 private _highWaterPricePerShare;

    /// @notice Management fee already collected from exiting shares on the Lane
    ///         A instant path, awaiting distribution at the next settlement.
    ///         Netted out of the settlement charge so nothing is billed twice.
    uint128 private _crystallizedMgmt;

    /// @notice Performance fee already collected from exiting shares, same
    ///         deferral. Excluded from `totalAssets()` alongside the above, so
    ///         retaining it does not move the remaining holders' share price.
    uint128 private _crystallizedPerf;

    /// @dev Reserved storage for future upgrades. Shrinks whenever a new state
    ///      variable is added above.
    uint256[28] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams memory p) external initializer {
        if (p.owner == address(0)) revert InvalidOwner();
        if (p.executorImpl == address(0)) revert InvalidExecutorImpl();
        // NOTE: agentRegistry can be address(0) on chains without ERC-8004

        __ERC4626_init(IERC20(p.asset));
        __ERC20_init(p.name, p.symbol);
        __EIP712_init(p.name, "1");
        __Ownable_init(p.owner);
        __Pausable_init();

        _executorImpl = p.executorImpl;
        _expectedExecutorCodehash = p.executorImpl.codehash;
        _openDeposits = p.openDeposits;
        _agentRegistry = IERC721(p.agentRegistry);
        _managementFeeBps = p.managementFeeBps;
        // _agentFeeBpsPlusOne left 0 (unset) → agentFeeBps() returns the 5%
        // default until the owner calls setAgentFeeBps (no init SSTORE needed).
        _factory = msg.sender;
        _cachedDecimalsOffset = IERC20Metadata(p.asset).decimals();
    }

    // ==================== DEPOSITOR WHITELIST ====================

    /// @inheritdoc ISyndicateVault
    /// @dev Body delegatecalled to `SyndicateVaultAdminLib` for EIP-170 headroom;
    ///      `onlyOwner` stays on the wrapper so access control is unchanged.
    function approveDepositor(address depositor) external onlyOwner {
        SyndicateVaultAdminLib.approveDepositor(_approvedDepositors, depositor);
    }

    /// @inheritdoc ISyndicateVault
    function removeDepositor(address depositor) external onlyOwner {
        SyndicateVaultAdminLib.removeDepositor(_approvedDepositors, depositor);
    }

    /// @inheritdoc ISyndicateVault
    function approveDepositors(address[] calldata depositors) external onlyOwner {
        SyndicateVaultAdminLib.approveDepositors(_approvedDepositors, depositors);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Whether `depositor` is allowed to receive shares when the vault
    ///         is in closed-deposit mode (`_openDeposits == false`).
    /// @dev The whitelist check in `_deposit` runs against `receiver` — the
    ///      share holder — **not** `caller` (the asset payer). A whitelisted
    ///      user can therefore receive shares funded by a non-whitelisted party
    ///      (pay-on-behalf semantics), intentional for KYC flows where
    ///      compliance attaches to the share holder (residency / accreditation
    ///      attestations travel with the shares, not the USDC).
    ///
    ///      To check both sides, extend `_deposit` to also assert
    ///      `isApprovedDepositor(caller)`. Not the default because it would
    ///      break subsidised onboarding flows.
    function isApprovedDepositor(address depositor) external view returns (bool) {
        return _approvedDepositors.contains(depositor);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Paginated slice of the approved-depositor set; `limit` is
    ///      hard-clamped to `MAX_PAGE_LIMIT`.
    function approvedDepositorsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return SyndicateVaultAdminLib.pageAddresses(_approvedDepositors, offset, limit);
    }

    /// @inheritdoc ISyndicateVault
    function setOpenDeposits(bool open) external onlyOwner {
        _openDeposits = open;
        emit OpenDepositsUpdated(open);
    }

    /// @inheritdoc ISyndicateVault
    function openDeposits() external view returns (bool) {
        return _openDeposits;
    }

    // ==================== VIEWS ====================

    /// @inheritdoc ISyndicateVault
    function getAgentCount() external view returns (uint256) {
        return _agentSet.length();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Paginated slice of the registered-agent set. `limit` is
    ///      hard-clamped to `MAX_PAGE_LIMIT` so the call always fits in a
    ///      block regardless of how many agents are registered. Callers
    ///      iterate: start at `offset = 0`, advance by `limit` each call
    ///      until the returned array is shorter than `limit`.
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return SyndicateVaultAdminLib.pageAddresses(_agentSet, offset, limit);
    }

    /// @inheritdoc ISyndicateVault
    function isAgent(address agentAddress) external view returns (bool) {
        return _agents[agentAddress].active;
    }

    /// @inheritdoc ISyndicateVault
    function factory() external view returns (address) {
        return _factory;
    }

    // ==================== ADMIN ====================

    /// @inheritdoc ISyndicateVault
    /// @dev ERC-8004 NFT ownership is verified **at registration time only**.
    ///      If the `agentId` NFT is later transferred to a different wallet,
    ///      the registered `agentAddress` retains its privileges on this vault
    ///      until the owner calls `removeAgent`. Intentional trade-off:
    ///      re-querying NFT ownership on every execution would add a per-call
    ///      external view to the hot path, and the ERC-8004 registry is an
    ///      external dependency the vault should not hard-couple to. Off-chain
    ///      reputation / guardian systems should monitor NFT transfers and
    ///      trigger `removeAgent` when an identity moves.
    function registerAgent(uint256 agentId, address agentAddress) external onlyOwner {
        SyndicateVaultAdminLib.registerAgent(_agents, _agentSet, agentId, agentAddress, _agentRegistry, owner());
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fully deletes the `_agents[agentAddress]` struct (not just flips
    ///      `active = false`). This prevents stale `agentId` /
    ///      `agentAddress` fields from being silently reused if `registerAgent`
    ///      is later called for the same slot. After `removeAgent`,
    ///      `isAgent(addr)` returns false, and a subsequent
    ///      `registerAgent(newId, addr)` writes a fresh entry.
    function removeAgent(address agentAddress) external onlyOwner {
        SyndicateVaultAdminLib.removeAgent(_agents, _agentSet, agentAddress);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Freezes LP flow (`deposit` / `mint` / `withdraw` / `redeem`) AND
    ///         strategy execution (`executeGovernorBatch`). Owner rescue paths
    ///         (`rescueEth` / `rescueERC20` / `rescueERC721`) remain callable so
    ///         the owner can respond to incidents. Rescues are still blocked by
    ///         `redemptionsLocked()` whenever a proposal is active.
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc ISyndicateVault
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Transfers vault ownership to `newOwner` via the factory.
    /// @dev Factory-only. Used by `SyndicateFactory.rotateOwner` alongside the
    ///      registry's `transferOwnerStakeSlot`, so the old owner's slashed /
    ///      unstaked position can be rebound to a fresh operator without
    ///      redeploying the vault.
    /// @dev Drains `_agentSet` entirely (full `delete`, not flip-only) so an
    ///      at-cap vault doesn't brick the new owner — 32 dead entries could
    ///      otherwise be neither re-registered (cap blocks) nor purged
    ///      (`AgentNotActive` blocks `removeAgent`). Snapshots via `.values()`
    ///      first so the in-loop `remove` doesn't invalidate iteration (OZ
    ///      swap-and-pop on `at(i)`).
    function rotateOwnership(address newOwner) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newOwner == address(0)) revert ZeroAddress();
        SyndicateVaultAdminLib.drainAgents(_agents, _agentSet);
        _transferOwnership(newOwner);
    }

    /// @notice Blocks direct OwnableUpgradeable owner rotation. The factory's
    ///         `rotateOwner` is the only legal route —
    ///         it enforces `getActiveProposal == 0`, `openProposalCount == 0`,
    ///         owner-stake clear, registry alignment, then calls
    ///         `rotateOwnership` here. Allowing the inherited setters would
    ///         desync factory / registry records and (via `renounceOwnership`)
    ///         permanently orphan the vault.
    function transferOwnership(address) public pure override {
        revert NotFactory();
    }

    function renounceOwnership() public pure override {
        revert NotFactory();
    }

    // ==================== WITHDRAWAL QUEUE BINDING ====================

    /// @notice Bind the per-vault `VaultWithdrawalQueue`. Factory-only, set-once.
    /// @dev Called once by `SyndicateFactory.createSyndicate` immediately after init.
    function setWithdrawalQueue(address q) external {
        if (msg.sender != _factory) revert NotFactory();
        if (q == address(0)) revert ZeroAddress();
        if (_withdrawalQueue != address(0)) revert WithdrawalQueueAlreadySet();
        _withdrawalQueue = q;
        emit WithdrawalQueueSet(q);
    }

    /// @inheritdoc ISyndicateVault
    function withdrawalQueue() external view returns (address) {
        return _withdrawalQueue;
    }

    // ==================== GOVERNOR ====================

    modifier onlyGovernor() {
        if (msg.sender != _getGovernor()) revert NotGovernor();
        _;
    }

    /// @dev Read governor address from factory
    function _getGovernor() internal view returns (address) {
        return ISyndicateFactory(_factory).governorOf(address(this));
    }

    /// @dev Active proposal id binding this vault, read through the governor (0
    ///      when none active). Shared body for the Lane-A lock + async request
    ///      paths. Distinct from `redemptionsLocked` / `_activeStrategy`, which
    ///      additionally guard a zero governor — those keep their own reads.
    function _activePid() private view returns (uint256) {
        return IProposalStatus(_getGovernor()).getActiveProposal();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Every delegatecall re-verifies that `_executorImpl`'s bytecode
    ///      still matches the hash stamped at init. A factory misconfig or a
    ///      swapped executor address cannot deflect the delegatecall to a
    ///      different library.
    /// @dev Gated by `whenNotPaused`. When the owner pauses the vault,
    ///      strategy execution is halted alongside LP flow.
    function executeGovernorBatch(BatchExecutorLib.Call[] calldata calls, uint256 maxNetOutflow)
        external
        onlyGovernor
        nonReentrant
        whenNotPaused
    {
        if (_executorImpl.codehash != _expectedExecutorCodehash) revert ExecutorCodehashMismatch();
        _guardBatchCalls(calls);
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        (bool success, bytes memory returnData) =
            _executorImpl.delegatecall(abi.encodeCall(BatchExecutorLib.executeBatch, (calls)));
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        // First-class vault-level execution marker. Emitted after the
        // delegatecall succeeds so indexers only see confirmed executions.
        emit GovernorBatchExecuted(msg.sender, calls.length);

        // Honor pending redemptions first: a strategy execution may not deploy
        // float reserved for already-settled, unclaimed redeem claims, so a
        // later proposal cannot strand them. Settle batches return float and
        // pass trivially; an execute batch that over-deploys reverts here.
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        // Custody-level net-outflow ceiling. Inflow batches (settle) pass
        // trivially; the governor passes the proposal's maxCapital on
        // execute, settlement, and emergency paths — honest unwinds are
        // net-inflow, so the finite cap never binds them.
        // NOTE: this is a COARSE custody cap — it meters the vault's own
        // asset() balance delta, so capital deployed INTO an allowlisted
        // adapter counts as outflow the same as an extraction (conservative
        // over-count). What the meter GUARANTEES holds only TOGETHER with the
        // selector guard above (`_guardBatchCalls`): the meter bounds the
        // asset() a single batch moves out of custody to maxCapital, and the
        // guard closes the balance-invisible exfiltration routes (approve /
        // transfer of ANY ERC20 to a non-allowlisted address). What they do
        // NOT cover: exotic assets — ERC721/ERC1155 approvals and LP-position
        // NFTs — which rely on tier-2 full-notional pricing until their
        // selectors join the guarded set (see `_guardBatchCalls` RESIDUAL).
        // The precise extractable bound is the tier system's per-call
        // coverage (requiredCoverage).
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > maxNetOutflow) revert MaxNetOutflowExceeded(netOutflow, maxNetOutflow);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        // Idle-liquidity floor: a batch may deploy at most (1 − minBufferBps)
        // of the pre-batch float. Inflow (settle) batches pass trivially.
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();
    }

    /// @dev Two-part batch gate: a privileged-TARGET denylist (Part 1, always
    ///      runs), then the value-moving-SELECTOR allowlist (Part 2, registry-
    ///      dependent). The two are independent — do not collapse them, and do
    ///      not move Part 1 below Part 2's registry lookup. See the block
    ///      comments in the body for the adversary each part answers.
    ///
    ///      ── PART 1: privileged-target denylist ──
    ///
    ///      WHY TARGETS TOO: selector-guarding is not enough, because this
    ///      adversary needs no value-moving selector at all. The batch runs via
    ///      delegatecall, so every sub-call reaches its target carrying
    ///      msg.sender == vault — exactly what the withdrawal queue's
    ///      `onlyVault` gate checks. `queue.queueRedeem(attacker, victimShares,
    ///      pid)` therefore clears that gate and mints the attacker a claim on
    ///      shares the queue already escrows for someone else, while every other
    ///      guard reads it as harmless: the queue's entrypoints move ZERO vault
    ///      asset() in-tx (the value leaves later via `queue.claim`), so the
    ///      net-outflow meter, the queue-reserve floor and the buffer floor all
    ///      see nothing, and coverage prices an uncertified target at tier 2 —
    ///      requiredCoverage == maxCapital, a price a 1-wei proposal buys.
    ///      Blocked as a target CLASS rather than a selector list, so the next
    ///      privileged queue function is covered by default.
    ///
    ///      UNCONDITIONAL: Part 1 runs above Part 2's registry staticcall and
    ///      above BOTH of its degrade-open returns. That is deliberate and is
    ///      the point of the fix: a queue steal is not priced, it is theft, so
    ///      a registry-less governor must not be able to skip it.
    ///
    ///      SCOPE: exactly two addresses — the vault and its bound queue. NOT a
    ///      target allowlist. Strategy adapters' own `onlyVault` entrypoints
    ///      (`BaseStrategy.execute/settle/withdrawTo`) are the LEGITIMATE batch
    ///      surface and stay open, bounded by Part 2, the outflow meter and tier
    ///      pricing as before.
    ///
    ///      ── PART 2: value-moving-selector allowlist gate ──
    ///
    ///      WHY: the net-outflow meter above only sees the vault's own asset()
    ///      balance delta. `token.approve(attacker, max)` moves no balance, so
    ///      it meters zero while the attacker can drain via `transferFrom` in a
    ///      later tx — for the vault asset and any other ERC20 the vault holds.
    ///
    ///      WHAT: the batch runs via delegatecall, so external targets see
    ///      msg.sender == vault; a plain call to an arbitrary target cannot
    ///      exfiltrate ERC20 funds unless the vault approves it or transfers to
    ///      it. Gating the spender/recipient of the four value-moving ERC20
    ///      selectors is a complete bound on ERC20 exfiltration without a full
    ///      target allowlist: for approve / increaseAllowance / transfer the
    ///      guarded address is arg 1 (calldata bytes 4..36); for transferFrom
    ///      it is `to`, arg 2 (bytes 36..68) — pulling INTO the vault
    ///      (to == vault) is an inflow and always passes. The address must be
    ///      the vault itself or an adapter allowlisted in the TierRegistry
    ///      (resolved through the calling governor). Runs on every governor
    ///      batch — execute, settlement, and both emergency paths — since
    ///      settlement calls are arbitrary, pre-committed calldata too.
    ///
    ///      RESIDUAL: exotic assets are not yet guarded — ERC721
    ///      `setApprovalForAll` (0xa22cb465) / `approve`, ERC1155, and
    ///      LP-position NFTs. Add their selectors here as those adapters are
    ///      onboarded; until then such holdings rely on tier-2 full-notional
    ///      pricing. A selector-colliding non-ERC20 function on some adapter is
    ///      gated (or reverts `MalformedCall`) conservatively.
    ///
    ///      UNSET REGISTRY: if the governor has no tier registry wired (or
    ///      predates the getter), PART 2 cannot run and that half is skipped by
    ///      design — the default is tier-2 / full-notional pricing anyway, and
    ///      hard-reverting would brick vaults deployed without a registry.
    ///      PART 1 IS NOT AFFECTED: it needs no registry, sits above both early
    ///      returns, and still rejects the vault and its queue. Pinned by
    ///      `test_targetGate_bitesEvenWithNoTierRegistryWired` (unset registry)
    ///      and `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter` (missing
    ///      getter) — one per degrade-open branch, so relocating Part 1 below
    ///      either return fails a test instead of silently re-opening the hole.
    function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
        // ── PRIVILEGED-CALLEE GATE, ahead of everything else ──
        //
        // The batch runs under delegatecall, so every call carries
        // `msg.sender == vault`. For the QUEUE that is decisive: its `onlyVault`
        // gate is satisfied by a batch that merely names it as a target.
        //
        // For the VAULT the reason is different, and worth stating precisely so
        // nobody re-permits it on a wrong premise. `msg.sender == vault` does
        // NOT open this contract's self-gated functions: `settleRedeem` /
        // `settleDeposit` require `msg.sender == _withdrawalQueue`, which the
        // vault is not, and it satisfies neither `onlyOwner`, `onlyGovernor` nor
        // the factory gate. The exposure is the PERMISSIONLESS surface instead —
        // chiefly `requestDeposit`, which anyone may call: a batch naming the
        // vault can escrow the vault's own float into the queue while directing
        // the resulting deposit claim to an attacker (it self-approves first,
        // which Part 2 permits, since `recipient == address(this)` is treated as
        // an inflow). That one IS metered — the float genuinely leaves, so the
        // net-outflow ceiling bounds it to maxCapital — which is why blocking
        // the vault is defense-in-depth rather than a second live hole. It
        // removes the standing dependency on "no permissionless entrypoint ever
        // becomes dangerous to call as ourselves".
        //
        // No other meter catches it. `queue.queueRedeem(attacker, victimShares,
        // pid)` mints a redeem claim against shares another owner escrowed
        // while moving ZERO `asset()`: `netOutflow == 0` clears any
        // `maxNetOutflow`, the reserve and buffer checks compare balances that
        // never moved, and the selector is none of the four guarded below. The
        // value leaves in a LATER transaction via `queue.claim`, which nothing
        // meters. Coverage does not price it either — an uncertified target is
        // tier 2, so `maxCapital = 1 wei` asks for ~$0.000002 of coverage, and
        // any single approver clears that.
        //
        // BEFORE THE REGISTRY LOOKUP, DELIBERATELY. The selector guard below
        // returns early for a governor with no `tierRegistry()` getter or an
        // unset registry, and being unguarded there is a documented, accepted
        // default. This check must not inherit that exemption: it is not
        // pricing a call, it is refusing a capability, and a vault deployed
        // without a registry needs it most.
        //
        // A TARGET CLASS, NOT A SELECTOR LIST. Enumerating today's reachable
        // privileged functions would leave the next one added unprotected, and
        // nothing a batch legitimately does names these two addresses as a
        // target. `stampSettlement` shows why breadth matters — it is one-shot
        // per pid, so one batch can pre-burn the settlement slot of proposals
        // that have not happened yet and make `onProposalSettled` revert
        // forever.
        address q = _withdrawalQueue;
        for (uint256 i = 0; i < calls.length; i++) {
            address target = calls[i].target;
            if (target == address(this) || (q != address(0) && target == q)) {
                revert DisallowedBatchTarget(target);
            }
        }

        // onlyGovernor holds, so msg.sender IS the governor. staticcall (not a
        // typed call) so a governor without the getter degrades to "unset".
        (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
        if (!ok || ret.length != 32) return;
        address registry = abi.decode(ret, (address));
        if (registry == address(0)) return;

        for (uint256 i = 0; i < calls.length; i++) {
            bytes calldata data = calls[i].data;
            if (data.length < 4) continue;
            bytes4 sel = bytes4(data[0:4]);
            address recipient;
            if (sel == _SEL_APPROVE || sel == _SEL_INCREASE_ALLOWANCE || sel == _SEL_TRANSFER) {
                if (data.length < 36) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[4:36]))));
            } else if (sel == _SEL_TRANSFER_FROM) {
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else {
                continue;
            }
            if (recipient == address(this)) continue;
            if (!ITierRegistry(registry).isAdapterAllowed(recipient)) {
                revert DisallowedTransferTarget(calls[i].target, sel, recipient);
            }
        }
    }

    /// @inheritdoc ISyndicateVault
    /// @dev THE QUEUE RESERVE IS NOT SPENDABLE HERE (issue #92). This was the
    ///      one asset-outflow path that checked only the raw balance, so a
    ///      settlement fee — or a later `claimUnclaimedFees` — could spend float
    ///      already frozen against stamped-unclaimed redeems, leaving the second
    ///      claimant's `settleRedeem` to revert with no `cancel` available to it
    ///      (`cancel` refuses a stamped pid).
    ///
    ///      REVERTING IS THE SAFE DIRECTION, not a lost fee: the governor's
    ///      `_payFee` already treats a failure here as "escrow it instead", so
    ///      the fee is deferred rather than dropped. Paying it out of a
    ///      redeemer's reserved assets would not be.
    function transferPerformanceFee(address asset_, address to, uint256 amount) external onlyGovernor {
        if (asset_ != asset()) revert InvalidAsset();
        if (to == address(0)) revert ZeroAddress();
        uint256 spendable = IERC20(asset_).balanceOf(address(this));
        uint256 reserve = reservedQueueAssets();
        spendable = spendable > reserve ? spendable - reserve : 0;
        if (amount > spendable) revert AmountExceedsBalance();
        IERC20(asset_).safeTransfer(to, amount);
    }

    /// @inheritdoc ISyndicateVault
    function governor() external view returns (address) {
        return _getGovernor();
    }

    /// @inheritdoc ISyndicateVault
    function owner() public view override(OwnableUpgradeable, ISyndicateVault) returns (address) {
        return super.owner();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fail-closed on missing governor: if the factory is misconfigured
    ///      and `governor() == address(0)`, deposits / withdrawals / rescues
    ///      must NOT silently unlock. Revert instead.
    function redemptionsLocked() public view returns (bool) {
        address gov = _getGovernor();
        if (gov == address(0)) revert GovernorNotSet();
        return IProposalStatus(gov).getActiveProposal() != 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Reads through the governor: the strategy is whatever address the
    ///      proposer set on the active proposal at propose time. Returns
    ///      `address(0)` outside the active window or for queue-only proposals
    ///      (proposer passed `address(0)` to `propose`).
    function activeStrategyAdapter() external view returns (address) {
        return _activeStrategy();
    }

    /// @dev Reads the active proposal's strategy through the governor's scalar
    ///      `strategyOf` getter. Returns `address(0)` when no proposal is active
    ///      OR when the active proposal opted out of live NAV (proposer passed
    ///      `strategy=0`). Still wrapped in try/catch: a simple `address` return
    ///      says nothing about EXISTENCE. The vault is a UUPS proxy and the
    ///      governor is a BEACON proxy — they upgrade on independent paths, so a
    ///      vault impl that calls `strategyOf` can go live before the governor
    ///      beacon carries it, and the call then reverts with no data.
    ///      `_activeStrategy` feeds `_laneState`, hence `maxWithdraw`/
    ///      `maxRedeem`, so an uncaught revert here is a vault-wide brick
    ///      rather than a degradation.
    function _activeStrategy() internal view returns (address) {
        address gov = _getGovernor();
        if (gov == address(0)) return address(0);
        uint256 pid = IProposalStatus(gov).getActiveProposal();
        if (pid == 0) return address(0);
        try IProposalStatus(gov).strategyOf(pid) returns (address strategy) {
            return strategy;
        } catch {
            return address(0);
        }
    }

    /// @inheritdoc ISyndicateVault
    function managementFeeBps() external view returns (uint256) {
        return _managementFeeBps;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev `public` rather than `external`: `_exitFees` reads it internally to
    ///      price an instant exiter's performance fee at the same rate
    ///      settlement would charge.
    function agentFeeBps() public view returns (uint256) {
        // One SLOAD: 0 = never set → the 5% default (agent never silently
        // unpaid); otherwise the stored value is fee+1, so an explicit 0%
        // (stored 1) stays distinct from unset.
        uint256 stored = _agentFeeBpsPlusOne;
        return stored == 0 ? FeeConstants.DEFAULT_AGENT_FEE_BPS : stored - 1;
    }

    /// @inheritdoc ISyndicateVault
    function setAgentFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_AGENT_FEE_BPS) revert AgentFeeTooHigh();
        // Offset-by-one: stored = fee+1 marks "set" and keeps an explicit 0%
        // distinct from the unset sentinel (0).
        _agentFeeBpsPlusOne = bps + 1;
        emit AgentFeeUpdated(bps);
    }

    /// @inheritdoc ISyndicateVault
    function setMinBufferBps(uint16 bps) external onlyOwner {
        if (bps > MAX_MIN_BUFFER_BPS) revert BufferTooHigh();
        minBufferBps = bps;
        emit MinBufferUpdated(bps);
    }

    /// @inheritdoc ISyndicateVault
    function setInstantExitFeeBps(uint16 bps) external onlyOwner {
        if (bps > MAX_INSTANT_EXIT_FEE_BPS) revert InstantExitFeeTooHigh();
        instantExitFeeBps = bps;
        emit InstantExitFeeUpdated(bps);
    }

    // ==================== OVERRIDES ====================

    /// @dev Resolve diamond between ERC20Upgradeable and ERC20VotesUpgradeable.
    ///      A Lane-A-locked holder cannot move shares out until the proposal
    ///      settles. Without this the per-holder lock is trivially bypassed by
    ///      transferring to a fresh (unlocked) address that then instant-redeems
    ///      at the higher mid-proposal NAV. Mint (`from == 0`) and burn
    ///      (`to == 0`) are unaffected — burns are gated by `maxRedeem` /
    ///      `requestRedeem`. `_isLaneALocked` short-circuits on
    ///      `_laneALockPid[from] == 0`, so non-Lane-A holders pay only an SLOAD.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (from != address(0) && to != address(0) && _isLaneALocked(from)) revert SharesLocked();
        super._update(from, to, value);
        // AUTO-DELEGATE ON EVERY RECEIPT. Runs AFTER `super._update` so the
        // recipient's post-receipt balance is what checkpoints. Holders that
        // explicitly delegated away keep their choice (`delegates(to) != 0`).
        //
        // KEPT DELIBERATELY, ON A NEW JUSTIFICATION. This was introduced for
        // The compensation escrow apportioned on
        // `getPastVotes`, so an undelegated holder — a secondary buyer, or a
        // queued exiter whose shares moved by plain transfer — was silently
        // written out of victim compensation while still counted in its
        // denominator. That consumer is gone; slash proceeds burn and nothing
        // is apportioned against this vault at all.
        //
        // The behaviour stays because `getPastVotes == balance` is what makes
        // this vault's OWN governance readable: a holder who never calls
        // `delegate` still carries weight, which is the property every
        // snapshot-based read here assumes. Removing it would silently zero
        // the voting weight of every non-delegating holder — a much larger
        // change than deleting a dead dependency, and not this one's business.
        //
        // The heal is permissionless and needs no action from the holder: it
        // also runs on a zero-value transfer (ERC20 permits `value == 0`), so
        // anyone can arm a stranded undelegated holder by sending it 0 shares
        // — a keeper can walk the holder set and heal all of it.
        if (to != address(0) && delegates(to) == address(0)) {
            _delegate(to, to);
        }
    }

    /// @dev Use timestamp-based voting checkpoints instead of block numbers
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev EIP-6372: declare timestamp-based clock
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @dev Resolve decimals diamond between ERC20Upgradeable and ERC4626Upgradeable
    function decimals() public view override(ERC4626Upgradeable, ERC20Upgradeable) returns (uint8) {
        return super.decimals();
    }

    /// @dev Virtual shares offset = asset decimals → mitigates ERC-4626 inflation/donation attack.
    ///      With USDC (6 decimals) this gives 12-decimal shares, making the attack economically infeasible.
    /// @dev Cached at init — no external `asset().decimals()` call on the hot
    ///      share-conversion path. Asset decimals are immutable in practice for the
    ///      underlying USDC/ERC-20, so pinning once at init is safe.
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return _cachedDecimalsOffset;
    }

    /// @dev True while any non-terminal proposal binds the vault
    ///      (Pending..Executed). Used by `_deposit` to close the late-deposit
    ///      window where a depositor mid-vote would be silently pulled into a
    ///      strategy by `executeProposal`. Off-chain readers can call
    ///      `governor.openProposalCount(vault)` directly.
    function _depositsLocked() private view returns (bool) {
        return IProposalStatus(_getGovernor()).openProposalCount() != 0;
    }

    /// @dev Protocol PriceRouter (Lane A live-NAV), read live from the factory.
    ///      `address(0)` (unset) ⇒ Lane A off — the vault shows float-only NAV
    ///      and routes mid-proposal flow to the async (Lane B) queue.
    function _getPriceRouter() internal view returns (address) {
        return ISyndicateFactory(_factory).priceRouter();
    }

    /// @dev The single home of the lane-eligibility rule: everything the
    ///      instant lane needs to decide "can LPs enter/exit at live NAV right
    ///      now" in one derivation.
    ///        locked  — an active proposal binds the vault (Executed window)
    ///        strat   — the active strategy IF pullable: nonzero AND has code.
    ///                  Codeless is zeroed here because a high-level call to a
    ///                  codeless address reverts on the extcodesize check
    ///                  BEFORE try/catch can trap it (would brick maxWithdraw).
    ///        liveNav — the strategy's positions priced vault-side by the
    ///                  PriceRouter (never the strategy's self-report)
    ///        laneA   — instant lane open: locked AND the router proves every
    ///                  position instant-eligible. Fail-closed: any missing
    ///                  precondition or router failure ⇒ laneA=false, liveNav=0.
    ///      Every lane predicate (`_laneBOnly`, `totalAssets`, `_deposit`,
    ///      `_strategyLiquidity`, `_pullFromStrategy`) consumes this — a new
    ///      gating condition (e.g. minHoldingPeriod) lands here once, not
    ///      threaded through five predicates. Stack tuple (not a
    ///      struct) deliberately: a memory struct costs ~130 bytes of zero-init
    ///      + copies across the call sites — over the EIP-170 budget.
    function _laneState() private view returns (bool locked, address strat, uint256 liveNav, bool laneA) {
        locked = redemptionsLocked();
        if (!locked) return (locked, strat, liveNav, laneA);
        address active = _activeStrategy();
        if (active == address(0)) return (locked, strat, liveNav, laneA);
        // Pullable only with code (extcodesize revert on a codeless address
        // escapes try/catch and would brick maxWithdraw/maxRedeem); Lane A
        // pricing itself is the router's call.
        if (active.code.length != 0) strat = active;
        address pr = _getPriceRouter();
        if (pr == address(0)) return (locked, strat, liveNav, laneA);
        try IPriceRouter(pr).valueStrategy(active) returns (uint256 v, bool ok) {
            if (ok) {
                liveNav = v;
                laneA = true;
            }
        } catch {} // fail-closed: laneA stays false
    }

    /// @dev True while `holder`'s shares are Lane-A-locked — a Lane A entry made
    ///      during the currently-active proposal. The lock lifts implicitly when
    ///      that proposal settles (the active proposal id changes / clears), so
    ///      no timestamp bookkeeping is needed. Bounds the deposit-low / exit-high
    ///      intra-proposal arb for both Lane A redeem and Lane B requestRedeem.
    function _isLaneALocked(address holder) private view returns (bool) {
        uint256 p = _laneALockPid[holder];
        return p != 0 && p == _activePid();
    }

    /// @dev Shared instant-exit gate for `maxWithdraw` / `maxRedeem`: an exit
    ///      must route through the Lane B queue when the vault is locked without
    ///      a Lane A live-NAV term, or while the holder is under the per-holder lockup.
    function _laneBOnly(address owner_) private view returns (bool) {
        (bool locked,,, bool laneA) = _laneState();
        return (locked && !laneA) || _isLaneALocked(owner_);
    }

    /// @dev Float available for instant exits = vault asset balance minus the
    ///      queue's reserved (already-settled, unclaimed) redeem float. Shared by
    ///      `maxWithdraw` / `maxRedeem`. Floors at 0 when float < reserve.
    function _availableFloat() private view returns (uint256) {
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        return float > reserve ? float - reserve : 0;
    }

    /// @dev On-demand liquidity the active strategy can return mid-lifecycle,
    ///      counted toward instant-exit capacity ONLY while Lane A is available
    ///      (no pricing ⇒ no instant exit, regardless of serviceability).
    ///      try/catch + fail-to-0 so a strategy without the interface can never
    ///      brick `maxWithdraw` / `maxRedeem`.
    function _strategyLiquidity() private view returns (uint256) {
        // `strat` is already zeroed for a codeless strategy (see _laneState);
        // try/catch still guards a coded strat that reverts or lacks the selector.
        (, address strat,, bool laneA) = _laneState();
        if (!laneA || strat == address(0)) return 0;
        try IStrategy(strat).availableLiquidity() returns (uint256 l) {
            return l;
        } catch {
            return 0;
        }
    }

    /// @dev Pull `shortfall` of the vault asset from the active strategy for an
    ///      in-flight instant exit. All-or-revert: delivery is verified by
    ///      balance-diff so a lying `availableLiquidity` cannot under-fund the
    ///      exit. Reverts `QueueReserveBreached` when there is no pullable
    ///      strategy (preserves the pre-existing error surface for float-only
    ///      exits).
    function _pullFromStrategy(uint256 shortfall) private {
        // `strat` is zeroed for a codeless strategy (defense-in-depth on this
        // fund-moving path; unreachable honestly — maxWithdraw caps at float
        // when strategy liquidity is 0).
        (, address strat,, bool laneA) = _laneState();
        if (strat == address(0) || !laneA) revert QueueReserveBreached();
        IERC20 asset_ = IERC20(asset());
        uint256 balBefore = asset_.balanceOf(address(this));
        IStrategy(strat).withdrawTo(shortfall);
        if (asset_.balanceOf(address(this)) < balBefore + shortfall) revert UnwindShortfall();
    }

    /// @dev Closed-deposit gate: reverts unless deposits are open OR `who` is
    ///      whitelisted. Shared by `_deposit` / `requestDeposit`.
    function _requireApprovedDepositor(address who) private view {
        if (!_openDeposits && !_approvedDepositors.contains(who)) revert NotApprovedDepositor();
    }

    // ── nonReentrant guard on the deposit / mint path ──
    //
    // The guard lives on the internal `_deposit` (both `deposit` and `mint`
    // route through it), so the public entry-points keep OZ's inherited bodies
    // and we don't pay for two wrapper overrides (EIP-170 headroom). Defence-in-
    // depth against cross-function reentrancy on the share-price path: a
    // reentrant deposit during another mint could mint against a transiently-
    // deflated NAV. The queue-side `claim` / `settleRedeem` take their own locks
    // and `requestRedeem` is already guarded.
    //
    // The `withdraw` / `redeem` paths take no nonReentrant — not load-bearing.
    // Withdraw transfers the vault asset OUT to the receiver (no asset in flight
    // that could deflate NAV from the caller's view), the vault has no
    // live-withdraw adapter callback, and any reentry into deposit / mint is
    // still blocked by `_deposit`'s nonReentrant latch.

    /// @inheritdoc ERC4626Upgradeable
    /// @dev V2 live-NAV redesign: the vault never trusts a strategy's
    ///      self-reported value. NAV is the idle float PLUS, only when Lane A is
    ///      available, the active strategy's positions priced vault-side by the
    ///      PriceRouter (`_laneState`). When Lane A is unavailable the live term is
    ///      0, so during a proposal the vault shows float-only and mid-flight LP
    ///      flow goes through the async queue, settling at the realized price.
    /// @dev Crystallized fees are physically in the vault's balance but are no
    ///      longer the fund's money — they belong to the split recipients and
    ///      are paid out at the next settlement. Excluding them here is what
    ///      makes an instant exit invisible to the holders who stay: their
    ///      price per share is the same before and after, and the payout at
    ///      settle moves nothing. Since price per share, the high-water mark
    ///      and the management-fee base ALL read this function, the exclusion
    ///      has to live here and only here.
    function totalAssets() public view override returns (uint256) {
        (,, uint256 liveNav,) = _laneState();
        uint256 gross = IERC20(asset()).balanceOf(address(this)) + liveNav;
        // THREE KINDS OF CLAIM, ALL SUBTRACTED. Crystallized fees are money the
        // vault holds but no longer owns. The queue reserve is the same kind of
        // claim and is subtracted for the same reason: `stampSettlement` froze
        // those assets against a `num/den` that can no longer move, so they are
        // owed in a fixed amount and are no longer part of what a residual share
        // is a claim on (issue #92).
        //
        // NEVER ALONE. The matching shares must leave the pricing supply in the
        // same breath — see `_pricingSupply`. Subtracting assets without their
        // shares would understate the price as badly as the original blend
        // overstated it.
        uint256 owed = uint256(_crystallizedMgmt) + _crystallizedPerf + reservedQueueAssets();
        // Cannot legitimately underflow — the counters track assets the vault
        // holds — but under-reporting beats inventing value if it ever did.
        return gross > owed ? gross - owed : 0;
    }

    /// @dev The supply a price is actually taken against: circulating shares
    ///      LESS the escrowed redeem shares whose settle price is already
    ///      stamped. Those shares are still in `totalSupply()` — the vault burns
    ///      them at `claim`, not at the stamp — but they are no longer a claim on
    ///      the pool, so pricing must not divide by them.
    ///
    ///      PAIRED WITH `totalAssets`, INSEPARABLY. Both legs of the same claim
    ///      leave together, so a `claim` moves neither the price nor anyone
    ///      else's position: `settleRedeem` removes `shares` from supply and
    ///      `assets` from float at the same instant the queue's two counters
    ///      drop by the same amounts.
    ///
    ///      PRE-STAMP ESCROW STAYS IN. A queued-but-unsettled redeem has no
    ///      frozen price yet, so it still floats with the pool and still belongs
    ///      in the denominator. That is why this reads
    ///      `stampedUnclaimedShares()` rather than `pendingShares()`.
    ///
    ///      FLOORED AT ZERO defensively; the counter is a subset of the balance
    ///      the queue holds, so the branch is unreachable today.
    ///
    ///      Deliberately a low-level staticcall rather than a typed interface
    ///      call: `VaultWithdrawalQueue` is not a proxy (plain constructor, no
    ///      `initialize`, no upgradeability), so a queue deployed before this
    ///      function existed can never gain the `stampedUnclaimedShares()`
    ///      selector. A typed call would revert for that legacy pairing, and
    ///      this sits on `_convertToShares`/`_convertToAssets`, so the revert
    ///      would brick every deposit, withdraw, preview and fee calc. Missing
    ///      selector degrades to 0 (today's pre-#92 blended pricing) instead —
    ///      full remediation for an existing syndicate requires redeploying the
    ///      vault/queue pair.
    function _pricingSupply() internal view returns (uint256) {
        address q = _withdrawalQueue;
        uint256 supply = totalSupply();
        if (q == address(0)) return supply;
        (bool ok, bytes memory ret) = q.staticcall(abi.encodeCall(IVaultWithdrawalQueue.stampedUnclaimedShares, ()));
        uint256 stamped = (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
        return supply > stamped ? supply - stamped : 0;
    }

    /// @dev Overridden solely to divide by `_pricingSupply()` instead of
    ///      `totalSupply()`; the rounding and virtual-offset arithmetic is
    ///      OpenZeppelin's, unchanged.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(assets, _pricingSupply() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /// @dev Mirror of `_convertToShares` above, same single change.
    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return Math.mulDiv(shares, totalAssets() + 1, _pricingSupply() + 10 ** _decimalsOffset(), rounding);
    }

    /// @dev Returns 0 when `paused()` so the EIP-4626 IMP-1 invariant holds
    ///      (`deposit(maxDeposit(x), x)` MUST NOT revert when the action is
    ///      disabled). Active-proposal / whitelist cases stay reported
    ///      as `type(uint256).max` here (adding those checks busts EIP-170 and
    ///      under-reports valid Lane A deposit flows); frontends poll
    ///      the per-vault governor's `getActiveProposal()` + `isApprovedDepositor` directly.
    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    /// @dev Instant deposit is allowed outside any open proposal, OR during an
    ///      Executed proposal when Lane A live-NAV is available (positions priced
    ///      vault-side by the PriceRouter). Otherwise it reverts and LPs use the
    ///      async deposit queue (`requestDeposit`), entering at the realized
    ///      settle price. Auto-delegate to self so shareholders get voting power.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        (,,, bool laneA) = _laneState();
        // During an open proposal (Pending..Executed) instant deposits are
        // closed unless Lane A is live — a depositor mid-lifecycle would
        // otherwise be pulled into a strategy they never voted on, or mint
        // against an unrealized NAV.
        if (_depositsLocked() && !laneA) revert DepositsLocked();
        _requireApprovedDepositor(receiver);
        super._deposit(caller, receiver, assets, shares);
        // The fund's first shares establish the high-water mark. Cannot be done
        // at `initialize` — before any shares exist there is no price.
        _initHighWaterMarkIfUnset();

        // Auto-delegation happens in `_update` (every receipt path).

        // A Lane A entry locks the receiver's shares until this proposal
        // settles — closes the deposit-low / exit-high intra-proposal MEV.
        if (laneA) {
            _laneALockPid[receiver] = _activePid();
            // Mid-proposal principal in — excluded from settlement PnL so
            // performance fees are never charged on depositor principal.
            _interimNetFlow += int256(assets);
            // The management fee IS charged on it, for the time it is present:
            // close the interval at the old base, restamp at the new one. A late
            // depositor therefore pays only for the days their capital was in
            // the fund.
            _accrueManagementFee();
        }
    }

    /// @dev `maxWithdraw` / `maxRedeem` are the canonical lock gate (OZ ERC4626
    ///      invokes them before `_withdraw`) — they return 0 while
    ///      `redemptionsLocked()`, so instant exits are closed during a proposal
    ///      and LPs use the async redeem queue (`requestRedeem`). The bound
    ///      queue (`caller == _withdrawalQueue`) bypasses the reserve guard
    ///      because the reserved float belongs to it.
    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (caller != _withdrawalQueue) {
            uint256 reserve = reservedQueueAssets();
            uint256 float = IERC20(asset()).balanceOf(address(this));
            // Shortfall beyond idle float is pulled from the active strategy in
            // the same tx (Yearn default_queue pattern, queue length 1). The
            // pull happens BEFORE the burn/transfer; value moves position →
            // float, so live NAV (and thus this exit's share pricing) is
            // unchanged.
            if (assets + reserve > float) {
                _pullFromStrategy(assets + reserve - float);
            }
        }
        // Crystallize the exiting shares' fees BEFORE the burn, while the
        // pro-rata denominator still includes them. `assets` arriving here is
        // already net of these fees (see `previewRedeem`), so the fee portion
        // simply stays behind in the vault — no transfer, no recipient lookup,
        // no external call on the ERC-4626 hot path. The exiter pays the fees
        // they owe at the moment they leave, so exit timing is fee-neutral.
        (,,, bool laneAExit) = _laneState();
        if (caller != _withdrawalQueue && laneAExit) {
            (uint256 mgmtFee, uint256 perfFee) = _exitFees(shares);
            if (mgmtFee != 0 || perfFee != 0) {
                // forge-lint: disable-next-line(unsafe-typecast)
                _crystallizedMgmt += uint128(mgmtFee);
                // forge-lint: disable-next-line(unsafe-typecast)
                _crystallizedPerf += uint128(perfFee);
                emit ExitFeesCrystallized(_owner, shares, mgmtFee, perfFee);
            }
        }

        super._withdraw(caller, receiver, _owner, assets, shares);
        // Mid-proposal principal out — excluded from settlement PnL. Queue
        // settlements post-date the PnL read, so only live instant exits count.
        if (caller != _withdrawalQueue && redemptionsLocked()) {
            _interimNetFlow -= int256(assets);
            // Accrual continues on the reduced base from this moment; the
            // withdrawn capital accrues nothing for the remainder of the
            // proposal. The high-water mark is deliberately NOT ratcheted here:
            // it advances only at settlement, so the holders who stayed keep
            // measuring from the same mark.
            _accrueManagementFee();
        }
    }

    /// @dev Cap visible to integrators so they don't propose withdrawals that
    ///      would breach the queue's reservation. Returns 0 while
    ///      `redemptionsLocked()` (instant withdraw is closed during a proposal;
    ///      LPs use `requestRedeem`). The bound queue bypasses the reserve cap
    ///      because the reserved float belongs to it.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxWithdraw(owner_);
        if (_laneBOnly(owner_)) return 0;
        uint256 userMax = super.maxWithdraw(owner_);
        uint256 available = _availableFloat() + _strategyLiquidity();
        return userMax > available ? available : userMax;
    }

    /// @dev Cap visible to integrators so they don't propose redeems that would
    ///      breach the queue's reservation. Returns 0 while `redemptionsLocked()`.
    ///      The bound queue bypasses the reserve cap (see `maxWithdraw`).
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxRedeem(owner_);
        if (_laneBOnly(owner_)) return 0;
        uint256 userMax = super.maxRedeem(owner_);
        uint256 reserveShares = pendingQueueShares();
        uint256 ts = totalSupply();
        if (ts == 0 || reserveShares >= ts) return 0;
        uint256 availableShares = ts - reserveShares;
        uint256 backingAssets = _availableFloat() + _strategyLiquidity();
        // No `backingAssets == 0` early return — skip the floatShares cap
        // entirely when the user's full balance fits within `backingAssets`
        // (covers the dust case where `convertToAssets(userMax) == 0`, which
        // would otherwise strand tiny redeems once float dropped to the queue
        // reserve). `_withdraw`'s reserve check still gates real asset draws.
        if (convertToAssets(userMax) > backingAssets) {
            uint256 floatShares = convertToShares(backingAssets);
            if (floatShares < availableShares) availableShares = floatShares;
        }
        return userMax > availableShares ? availableShares : userMax;
    }

    // ==================== ASYNC REDEEM ====================

    /// @inheritdoc ISyndicateVault
    /// @notice Burn-deferred redemption used while a strategy proposal is active.
    ///         Transfers `shares` from `owner_` into the queue and records a claim
    ///         that anyone can settle once `redemptionsLocked() == false`. Standard
    ///         `redeem`/`withdraw` should be used outside the lock window.
    /// @dev `whenNotPaused` blocks queueing while the vault is paused (mirrors
    ///      `_deposit` / `executeGovernorBatch`). LPs are not trapped — the
    ///      queue's `cancel` path is unpaused and lets the owner withdraw
    ///      escrowed shares back to themselves at any time.
    /// @return requestId Always > 0 — the queue uses index 0 as a sentinel.
    ///         Off-chain integrators may treat 0 as "no request".
    function requestRedeem(uint256 shares, address owner_)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        address q = _withdrawalQueue;
        if (q == address(0)) revert WithdrawalQueueNotSet();
        if (!redemptionsLocked()) revert RedemptionsNotLocked();
        if (shares == 0) revert InsufficientShares();
        // Shares entered via Lane A this proposal are locked until it settles
        // (blocks the Lane A entry → Lane B exit bypass within one proposal).
        if (_isLaneALocked(owner_)) revert SharesLocked();
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }
        // Move shares into queue custody. `_update` auto-delegates the queue to
        // itself, so custody shares keep checkpointed voting weight AT THE
        // QUEUE. That weight used to be load-bearing — it was how the
        // compensation escrow counted queued exiters at a pre-drain snapshot —
        // and is now merely consistent: nothing is apportioned, and the queue
        // never votes because it has no governance surface. For proposals already
        // open at request time, the voter's checkpoint at `snapshotTimestamp` is
        // frozen with the pre-transfer weight, so vote power is preserved for
        // in-flight proposals. Queued shares forfeit voting power for any
        // proposal opened after escrow. Shares are burned later by `claim`.
        uint256 pid = _activePid();
        _transfer(owner_, q, shares);
        requestId = IVaultWithdrawalQueue(q).queueRedeem(owner_, shares, pid);
        emit RedeemRequested(requestId, owner_, shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Mint-deferred deposit used while a strategy proposal is active.
    ///         Escrows `assets` in the queue (off-vault, so they never inflate
    ///         `totalAssets` nor are swept into the strategy) and records a claim
    ///         that mints shares at the realized settle price once the proposal
    ///         settles. Standard `deposit`/`mint` is used outside the lock window.
    /// @return requestId Always > 0 (queue uses index 0 as a sentinel).
    function requestDeposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        address q = _withdrawalQueue;
        if (q == address(0)) revert WithdrawalQueueNotSet();
        if (!redemptionsLocked()) revert RedemptionsNotLocked();
        if (assets == 0) revert ZeroAssets();
        _requireApprovedDepositor(receiver);
        uint256 pid = _activePid();
        // Escrow assets in the queue (off-vault custody — never counted in
        // totalAssets, never swept into the strategy).
        IERC20(asset()).safeTransferFrom(msg.sender, q, assets);
        requestId = IVaultWithdrawalQueue(q).queueDeposit(receiver, assets, pid);
        emit DepositRequested(requestId, receiver, assets);
    }

    /// @inheritdoc ISyndicateVault
    function pendingQueueShares() public view returns (uint256) {
        address q = _withdrawalQueue;
        if (q == address(0)) return 0;
        return IVaultWithdrawalQueue(q).pendingShares();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev The queue tracks the exact frozen asset amount owed to already-
    ///      settled, unclaimed redeem requests. Instant withdrawals and strategy
    ///      executions must leave this float in the vault so queued claims are
    ///      always honorable.
    function reservedQueueAssets() public view returns (uint256) {
        address q = _withdrawalQueue;
        if (q == address(0)) return 0;
        return IVaultWithdrawalQueue(q).reservedAssets();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Queue-only: burn `shares` escrowed in the queue and pay `assets`
    ///         to `to` at the proposal's frozen settle price. The queue computes
    ///         `assets` from the stamped price; the vault trusts it (the queue is
    ///         set-once at deploy by the factory).
    function settleRedeem(uint256 shares, uint256 assets, address to) external nonReentrant {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _burn(_withdrawalQueue, shares);
        IERC20(asset()).safeTransfer(to, assets);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Queue-only: mint `shares` to `to` at the proposal's frozen settle
    ///         price. The queue pushes the escrowed assets to the vault
    ///         immediately before this call. Auto-delegates for voting power.
    /// @dev No `nonReentrant`: there is no external call (mint + delegate only),
    ///      and the only caller — the queue's `claim` — is itself `nonReentrant`.
    ///      Auto-delegation happens in `_update`.
    function settleDeposit(uint256 shares, address to) external {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _mint(to, shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: stamp the realized settle price for `proposalId`
    ///         into the queue so every request tagged to it claims at one frozen
    ///         price. `num/den` carry the ERC-4626 virtual offsets so the queue
    ///         reproduces the vault's conversion rounding exactly.
    function onProposalSettled(uint256 proposalId) external onlyGovernor {
        // Reset the interim-flow accumulator for the next proposal. MUST precede
        // the no-queue early-return below so a queueless vault still resets.
        delete _interimNetFlow;
        address q = _withdrawalQueue;
        if (q == address(0)) return;
        uint256 num = totalAssets() + 1;
        uint256 den = totalSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);
    }

    /// @inheritdoc ISyndicateVault
    function interimNetFlow() external view returns (int256) {
        return _interimNetFlow;
    }

    // ==================== MANAGEMENT-FEE ACCRUAL ====================

    /// @dev Close off the elapsed interval at the base that applied during it,
    ///      then restamp the base from live fund assets. Called on every
    ///      mid-proposal event that can move the base — Lane A deposit and Lane
    ///      A instant exit — and once more at settlement, via
    ///      `consumeManagementAccrual`. Proposal execute opens the accrual
    ///      rather than closing an interval, so it stamps the base directly
    ///      through `startManagementAccrual`.
    ///
    ///      Restamping from `totalAssets()` rather than applying a per-event
    ///      delta is deliberate: the base is read from truth, so it stays
    ///      correct for any caller regardless of whether that caller can
    ///      express its own effect as an asset delta.
    ///
    ///      The `_mgmtLastUpdate == 0` early return is load-bearing twice over:
    ///      it is the "no live proposal, no fee" rule, and it keeps
    ///      `totalAssets()` — an external call for live NAV — off the ordinary
    ///      deposit path entirely.
    function _accrueManagementFee() private {
        uint256 last = _mgmtLastUpdate;
        if (last == 0) return;
        uint256 nowTs = block.timestamp;
        if (nowTs > last) {
            _mgmtAssetSeconds += uint256(_mgmtBase) * (nowTs - last);
            _mgmtLastUpdate = uint64(nowTs);
        }
        _stampMgmtBase();
    }

    /// @dev Restamp the accrual base from live fund assets, falling back to
    ///      idle float if the valuation is unavailable.
    ///
    ///      `totalAssets()` resolves live NAV through `factory.priceRouter()`.
    ///      A fee accrual must never be the reason `executeProposal` or a
    ///      settlement reverts, so a router that is unwired or reverting
    ///      degrades the BASE rather than the transaction — the fund is valued
    ///      at its float for that interval and the fee comes out conservative
    ///      (too low), never inflated. Routed through an external self-call
    ///      because `try` cannot wrap an internal one.
    function _stampMgmtBase() private {
        uint256 base;
        try this.totalAssets() returns (uint256 a) {
            base = a;
        } catch {
            base = IERC20(asset()).balanceOf(address(this));
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        _mgmtBase = uint192(base > type(uint192).max ? type(uint192).max : base);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: begin management-fee accrual for a newly executed
    ///         proposal.
    /// @dev Starts from zero rather than carrying anything forward, which is
    ///      what makes the gap between proposals free: nothing accrued while no
    ///      proposal was live, and nothing stale survives into this one.
    function startManagementAccrual() external onlyGovernor {
        _mgmtAssetSeconds = 0;
        _mgmtLastUpdate = uint64(block.timestamp);
        _stampMgmtBase();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: settle up the accrual and hand back the integral,
    ///         then stop accruing.
    /// @dev Consume-and-reset. Zeroing `_mgmtLastUpdate` is what stops the
    ///      clock between proposals; without it the idle gap would accrue.
    function consumeManagementAccrual() external onlyGovernor returns (uint256 assetSeconds) {
        _accrueManagementFee();
        assetSeconds = _mgmtAssetSeconds;
        _mgmtAssetSeconds = 0;
        _mgmtBase = 0;
        _mgmtLastUpdate = 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev `public` rather than `external`: `_exitFees` reads it internally to
    ///      size an exiter's pro-rata slice of the accrual so far.
    function managementAssetSeconds() public view returns (uint256) {
        uint256 last = _mgmtLastUpdate;
        if (last == 0 || block.timestamp <= last) return _mgmtAssetSeconds;
        return _mgmtAssetSeconds + uint256(_mgmtBase) * (block.timestamp - last);
    }

    /// @inheritdoc ISyndicateVault
    function isAccruingManagementFee() external view returns (bool) {
        return _mgmtLastUpdate != 0;
    }

    // ==================== HIGH-WATER MARK ====================

    /// @notice AT LEAST one whole share, in this vault's OWN decimals — never
    ///         a smaller, arbitrary `1e18` (issue #97). Share decimals are
    ///         `assetDecimals + _decimalsOffset()`, and this vault sets
    ///         `_decimalsOffset()` to the asset's own decimals, so share
    ///         decimals are `2 * assetDecimals`. A literal `1e18` is "one
    ///         whole share" only at `assetDecimals == 9`; at 18 (WETH-like) it
    ///         was `1e-18` of a share, and `convertToAssets` of that quantized
    ///         to whole-integer steps of `pps` at 100% NAV moves —
    ///         `aboveHighWaterMark` read a fund up 99% as sitting AT the mark,
    ///         charging zero performance fee.
    /// @dev    `max(1e18, 10 ** decimals())`, NOT bare `10 ** decimals()`. The
    ///         obvious fix — always convert against exactly one share — is
    ///         wrong for LOW-decimal assets: at `assetDecimals == 6` (USDC),
    ///         `10 ** decimals() = 1e12`, a SMALLER unit than the `1e18` this
    ///         vault always used. `convertToAssets` floors, and the absolute
    ///         floor error in `pps` is bounded by <1 unit of THIS constant; a
    ///         smaller unit means that same <1-unit error represents more real
    ///         value once multiplied back out by `totalSupply()` in
    ///         `aboveHighWaterMark`/`_exitFees`. Measured: a bare
    ///         `10 ** decimals()` reintroduced ~$1 of drift on a $200,000 fee
    ///         base for a 6-decimal asset (`test/fees/HighWaterMark.t.sol`),
    ///         precision the OLD `1e18` constant never lost. The `max` floors
    ///         at exactly `1e18` for every `assetDecimals <= 9` — which is
    ///         every asset this protocol has ever tested against — so those
    ///         vaults get the IDENTICAL constant, and identical numerics, they
    ///         always had. Only `assetDecimals > 9`, where `1e18` genuinely
    ///         stops being close to one real share, switches to the larger,
    ///         decimals-scaled unit.
    /// @dev    Computed, not cached: `decimals()` itself reads only cached
    ///         immutable-like state (`_cachedDecimalsOffset` + the asset's own
    ///         decimals, pinned at init), so this costs one `EXP` by a small
    ///         constant and one comparison, not an external call.
    function _pricePerShareUnit() private view returns (uint256) {
        uint256 wholeShare = 10 ** decimals();
        return wholeShare > 1e18 ? wholeShare : 1e18;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Routed through `convertToAssets` rather than computing
    ///      `totalAssets() / totalSupply()` by hand, so the mark inherits the
    ///      ERC-4626 virtual-offset rounding the vault uses for every other
    ///      conversion. A hand-rolled ratio would drift from real share pricing
    ///      and the drift would land in the fee.
    function pricePerShare() public view returns (uint256) {
        return convertToAssets(_pricePerShareUnit());
    }

    /// @inheritdoc ISyndicateVault
    function highWaterPricePerShare() external view returns (uint256) {
        return _highWaterPricePerShare;
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Value above the mark, in assets — the performance-fee base.
    /// @dev Zero when the fund sits at or below its previous peak, which is the
    ///      whole point: a fund that falls and recovers is not charged twice on
    ///      the same dollars. Callers must read this AFTER the management fee
    ///      has been taken, since that fee lowers the price per share.
    function aboveHighWaterMark() external view returns (uint256) {
        uint256 mark = _highWaterPricePerShare;
        uint256 pps = pricePerShare();
        if (pps <= mark) return 0;
        return (pps - mark) * _pricingSupply() / _pricePerShareUnit();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: advance the mark to the current (post-fee) price
    ///         per share.
    /// @dev Monotonic by construction — a loss leaves the mark where it was,
    ///      which is what makes the recovery free. Called at settlement only;
    ///      a partial exit must NOT ratchet, or the holders who stayed would
    ///      start measuring from a peak the fund never actually banked.
    function ratchetHighWaterMark() external onlyGovernor {
        uint256 pps = pricePerShare();
        if (pps > _highWaterPricePerShare) {
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    /// @dev Seed the mark at the fund's first deposit so the first proposal's
    ///      gains above it are chargeable. Before any shares exist the price is
    ///      meaningless, so this cannot be done at `initialize`.
    function _initHighWaterMarkIfUnset() private {
        if (_highWaterPricePerShare == 0 && totalSupply() != 0) {
            uint256 pps = pricePerShare();
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    // ==================== EXIT-TIME FEE CRYSTALLIZATION ====================

    /// @inheritdoc ISyndicateVault
    function crystallizedMgmt() external view returns (uint256) {
        return _crystallizedMgmt;
    }

    /// @inheritdoc ISyndicateVault
    function crystallizedPerf() external view returns (uint256) {
        return _crystallizedPerf;
    }

    /// @dev The fees `shares` owe if they leave right now: their pro-rata slice
    ///      of the management fee accrued-but-uncollected so far, plus their
    ///      per-share performance fee above the high-water mark.
    ///
    ///      This is what makes exit timing fee-neutral. Without it an instant
    ///      exiter walks away mid-proposal at a live price having paid nothing,
    ///      and the fees they owed land on the depositors who stayed.
    ///
    ///      The performance rate is clamped to the governor's per-vault ceiling
    ///      exactly as settlement clamps it. Reading the vault's own
    ///      `agentFeeBps()` unclamped would let an over-configured vault charge
    ///      an exiter more than a hold-to-settle depositor pays — breaking the
    ///      neutrality this function exists to provide.
    function _exitFees(uint256 shares) private view returns (uint256 mgmtFee, uint256 perfFee) {
        uint256 supply = _pricingSupply();
        if (shares == 0 || supply == 0) return (0, 0);

        // ── Management: pro-rata of the fund-level accrual to now ──
        uint256 rate = _managementFeeBps;
        if (rate != 0) {
            uint256 owedNow = (managementAssetSeconds() * rate) / (10_000 * 365 days);
            uint256 collected = _crystallizedMgmt;
            if (owedNow > collected) {
                mgmtFee = ((owedNow - collected) * shares) / supply;
            }
        }

        // ── Performance: per-share, above the mark, on the shares leaving ──
        uint256 mark = _highWaterPricePerShare;
        uint256 pps = pricePerShare();
        if (pps > mark) {
            uint256 bps = agentFeeBps();
            uint256 cap = _governorPerformanceCap();
            if (bps > cap) bps = cap;
            perfFee = (((pps - mark) * shares) / _pricePerShareUnit()) * bps / 10_000;
        }
    }

    /// @dev The governor's per-vault performance-fee ceiling. Falls back to the
    ///      protocol constant when the governor is unwired, has no code, or
    ///      returns something undecodable — a quoting view on the ERC-4626
    ///      withdraw path must never revert.
    ///
    ///      Deliberately a low-level staticcall rather than `try`/`catch`:
    ///      `try` catches a REVERT, but a call that succeeds and returns short
    ///      or empty data fails while decoding the return value, and that
    ///      failure is not catchable. Checking `returndata.length` first is the
    ///      only form that survives an EOA or a stubbed governor.
    function _governorPerformanceCap() private view returns (uint256) {
        address gov = _getGovernor();
        if (gov == address(0) || gov.code.length == 0) return FeeConstants.MAX_PERFORMANCE_FEE_BPS;
        (bool ok, bytes memory ret) =
            gov.staticcall(abi.encodeWithSelector(ISyndicateGovernor.getGovernorParams.selector));
        // GovernorParams is nine words; anything shorter is not one.
        if (!ok || ret.length < 9 * 32) return FeeConstants.MAX_PERFORMANCE_FEE_BPS;
        ISyndicateGovernor.GovernorParams memory p = abi.decode(ret, (ISyndicateGovernor.GovernorParams));
        return p.maxPerformanceFeeBps;
    }

    /// @dev The early-exit penalty on `netAssets` leaving now.
    ///
    ///      Charged on the PULLED portion only — the part of the exit that idle
    ///      float cannot absorb and that therefore forces the strategy to
    ///      unwind early. That matches what the penalty is compensating the
    ///      remaining depositors for. An exit small enough to be served from
    ///      float causes no unwind and pays nothing.
    ///
    ///      This makes the fee function kinked at the float boundary, so
    ///      `previewWithdraw` cannot invert it in closed form; it grosses up and
    ///      rounds conservatively instead. `previewRedeem` stays exact and
    ///      monotone either side of the kink (d(net)/d(assets) = 1 - bps/1e4 > 0),
    ///      which is what EIP-4626 actually requires.
    ///
    ///      Known trade-off: because the charge depends on float, the first
    ///      exiters in a rush pay nothing and the
    ///      last pays full — which adds a little pressure to run early, the
    ///      opposite of what an anti-mercenary term wants. Kept because it
    ///      matches the fee's stated purpose and instant-exit capacity is
    ///      already bounded by `availableLiquidity()` regardless.
    function _exitPenalty(uint256 netAssets) private view returns (uint256) {
        uint256 bps = instantExitFeeBps;
        if (bps == 0 || netAssets == 0) return 0;
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 reserve = reservedQueueAssets();
        uint256 absorbable = float > reserve ? float - reserve : 0;
        if (netAssets <= absorbable) return 0;
        return ((netAssets - absorbable) * bps) / 10_000;
    }

    /// @notice Assets an instant exit of `shares` would release, net of the
    ///         fees those shares owe and the early-exit penalty.
    /// @dev Only the Lane A instant path is charged. A Lane B queue exit claims
    ///      at the frozen post-settlement price and has therefore already borne
    ///      its share — charging it here would double-bill.
    ///
    ///      Order is fixed and the two charges are independent: crystallization
    ///      first, against the exiting shares' value (it goes to the fee
    ///      recipients — fees the exiter owed anyway), then the penalty on what
    ///      remains (it goes to the vault — compensation for the early unwind).
    function previewRedeem(uint256 shares) public view override returns (uint256) {
        uint256 gross = super.previewRedeem(shares);
        (,,, bool laneA) = _laneState();
        if (!laneA) return gross;

        (uint256 mgmtFee, uint256 perfFee) = _exitFees(shares);
        uint256 fees = mgmtFee + perfFee;
        uint256 net = gross > fees ? gross - fees : 0;

        return net - _exitPenalty(net);
    }

    /// @notice Shares to burn for `assets` out of an instant exit.
    /// @dev The fee function is kinked at the float boundary (see
    ///      `_exitPenalty`) and concave above it, so it has no closed-form
    ///      inverse and a single linear correction lands short — grossing up
    ///      pushes more of the exit past the boundary, which the first estimate
    ///      did not price. Iterate instead, rounding UP each time: the caller
    ///      burns marginally more shares than strictly necessary rather than
    ///      receiving less than they asked for. Erring the other way would
    ///      break the EIP-4626 guarantee that `withdraw` delivers the requested
    ///      assets.
    ///
    ///      Convergence is quadratic in the penalty rate (each round leaves a
    ///      residual of order `bps^(n+1)`), so at the 200 bps ceiling three
    ///      rounds are exact to well under one wei. The bound also makes this
    ///      view unconditionally terminating.
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 shares = super.previewWithdraw(assets);
        (,,, bool laneA) = _laneState();
        if (!laneA || shares == 0) return shares;

        uint256 bps = instantExitFeeBps;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 net = previewRedeem(shares);
            if (net >= assets) break;
            // Top up by what the shortfall is worth in shares — but gross the
            // shortfall up by the penalty first. Shares added to cover a
            // deficit are themselves charged on the way out, so closing on the
            // raw deficit only ever recovers `(1 - bps)` of it and the estimate
            // creeps toward the target from below without reaching it.
            // Grossing up makes each round overshoot instead, which terminates.
            uint256 deficit = assets - net;
            if (bps != 0) deficit = (deficit * 10_000) / (10_000 - bps) + 1;
            shares += convertToShares(deficit) + 1;
        }
        return shares;
    }

    /// @inheritdoc ISyndicateVault
    function previewExitFees(uint256 shares) external view returns (uint256 mgmtFee, uint256 perfFee) {
        (,,, bool laneA) = _laneState();
        if (!laneA) return (0, 0);
        return _exitFees(shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: release the parked management fees for payout.
    /// @dev The assets never left the vault — this only moves them from
    ///      "parked, excluded from `totalAssets`" to "payable", which is why
    ///      the two legs are released separately. Releasing raises
    ///      `totalAssets()`, so the performance leg must read its base BEFORE
    ///      `consumeCrystallizedPerf` is called or it would charge a fee on
    ///      money that already belongs to the recipients.
    function consumeCrystallizedMgmt() external onlyGovernor returns (uint256 amount) {
        amount = _crystallizedMgmt;
        _crystallizedMgmt = 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: release the parked performance fees for payout.
    ///         Call only after the above-mark base has been read.
    function consumeCrystallizedPerf() external onlyGovernor returns (uint256 amount) {
        amount = _crystallizedPerf;
        _crystallizedPerf = 0;
    }

    // ==================== RESCUE ====================

    /// @notice Rescue ETH accidentally sent to the vault.
    ///         Blocked during active proposals so the owner cannot siphon
    ///         ETH mid-strategy (e.g. an mWETH redemption that transiently
    ///         parks native ETH here before wrapping).
    function rescueEth(address payable to, uint256 amount) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        Address.sendValue(to, amount);
    }

    /// @notice Rescue ERC-20 tokens accidentally sent to the vault (not the vault asset).
    ///         Blocked during active proposals to protect strategy position tokens.
    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        address asset = asset();
        if (token == asset) revert CannotRescueAsset();
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Rescue ERC-721 tokens accidentally sent to the vault.
    ///         Blocked during active proposals to protect strategy position NFTs (e.g., Uniswap V3 LP).
    function rescueERC721(address token, uint256 tokenId, address to) external onlyOwner {
        if (redemptionsLocked()) revert RedemptionsLocked();
        if (to == address(0)) revert ZeroAddress();
        IERC721(token).safeTransferFrom(address(this), to, tokenId);
    }

    // ==================== UUPS ====================

    /// @dev Only the factory can authorize upgrades.
    function _authorizeUpgrade(address) internal view override {
        if (msg.sender != _factory) revert NotFactory();
    }

    // ==================== RECEIVE ====================

    /// @dev No `receive()` / `fallback()`. The vault's ERC-4626 asset
    ///      is USDC; raw ETH has no accounting slot and would strand forever.
    ///      Any legitimate mid-batch native ETH (e.g. Moonwell mWETH redeem)
    ///      is caught by the strategy's own `receive()` at its own address
    ///      and wrapped to WETH before being pushed back via `safeTransfer`.
}
