// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IProposalStatus} from "./interfaces/IProposalStatus.sol";
import {IStrategyDelivery} from "./interfaces/IStrategyDelivery.sol";
import {FeeConstants} from "./FeeConstants.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {IVaultWithdrawalQueue} from "./interfaces/IVaultWithdrawalQueue.sol";
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

    /// @notice Hard cap on the vault-owner-set agent performance fee (30%), equal
    ///         to the protocol ceiling on the governor's `maxPerformanceFeeBps`.
    ///         The governor additionally clamps the realized fee to its own,
    ///         lower, configured value at settlement, so a stored value above the
    ///         live param is never charged; capping here keeps `agentFeeBps()`
    ///         from advertising a rate that can never be realized.
    /// @dev A backstop, not the headline rate: a factory-created vault starts at a
    ///      per-vault `maxPerformanceFeeBps` of 20%.
    uint256 public constant MAX_AGENT_FEE_BPS = FeeConstants.MAX_PERFORMANCE_FEE_BPS;

    /// @notice Cap on the owner-set idle-liquidity floor (50%).
    uint256 private constant MAX_MIN_BUFFER_BPS = 5_000;

    // ── Value-moving ERC20 selectors guarded in governor batches ──
    // (see `_guardBatchCalls`)
    bytes4 private constant _SEL_APPROVE = 0x095ea7b3; // approve(address,uint256)
    bytes4 private constant _SEL_INCREASE_ALLOWANCE = 0x39509351; // increaseAllowance(address,uint256)
    bytes4 private constant _SEL_TRANSFER = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant _SEL_TRANSFER_FROM = 0x23b872dd; // transferFrom(address,address,uint256)

    // Alternate-signature pull/push-via-delegated-allowance selectors: the same
    // guarded CAPABILITY as the four legacy-ERC20 selectors above, exposed under
    // different 4-byte selectors by non-legacy allowance routers. Permit2's
    // AllowanceTransfer singleton — deployed at the same address on nearly every
    // EVM chain, with huge numbers of standing LP allowances — and
    // DSToken-lineage `pull`/`move` wrappers reproduce the exact
    // LP-allowance-confiscation and poison-then-drain shapes Part 1b/Part 2 close,
    // invisible to both because neither matched any legacy selector. Each decodes
    // with the SAME argument layout as its legacy counterpart (source at bytes
    // 4:36; destination, where present, at 36:68).
    bytes4 private constant _SEL_PERMIT2_TRANSFER_FROM = 0x36c78516; // Permit2 AllowanceTransfer.transferFrom(address from,address to,uint160,address token)
    bytes4 private constant _SEL_PERMIT2_APPROVE = 0x87517c45; // Permit2 AllowanceTransfer.approve(address token,address spender,uint160,uint48)
    bytes4 private constant _SEL_DSTOKEN_PULL = 0xf2d5d56b; // DSToken pull(address usr, uint256 wad) — pulls TO msg.sender (the vault)
    bytes4 private constant _SEL_DSTOKEN_MOVE = 0xbb35783b; // DSToken move(address src, address dst, uint256 wad)

    // Four MORE sibling selectors on the exact routers/standards above, missed by
    // the same enumeration approach — the evidence that motivated the
    // target-based callee gate (PART 2a). These selectors, and everything below,
    // remain the INNER boundary — still load-bearing for e.g. `approve(attacker)`
    // on an otherwise-allowlisted token — but they are no longer the outer
    // boundary against an unenumerated selector on an arbitrary target.
    bytes4 private constant _SEL_DSTOKEN_PUSH = 0xb753a98c; // DSToken push(address dst, uint256 wad) — transfer-lineage sibling of guarded pull/move; internally transfer(dst, wad)
    bytes4 private constant _SEL_ERC1363_TRANSFER_FROM_AND_CALL = 0xd8fbe994; // ERC1363 transferFromAndCall(address from,address to,uint256)
    bytes4 private constant _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA = 0xc1d34b89; // ERC1363 transferFromAndCall(address from,address to,uint256,bytes) — trailing bytes arg does not shift the leading from/to offsets
    bytes4 private constant _SEL_ERC1363_APPROVE_AND_CALL = 0x3177029f; // ERC1363 approveAndCall(address spender,uint256)
    bytes4 private constant _SEL_ERC1363_APPROVE_AND_CALL_DATA = 0xcae9ca51; // ERC1363 approveAndCall(address spender,uint256,bytes)
    bytes4 private constant _SEL_PERMIT2_BATCH_TRANSFER_FROM = 0x0d58b1db; // Permit2 AllowanceTransfer.transferFrom(AllowanceTransferDetails[]) — dynamic-array batch sibling of the guarded single-transfer overload; decoded via `_Permit2BatchDetail`, NOT the fixed-offset slices the other selectors share

    // ERC4626 withdraw/redeem: a THIRD allowance-pull shape. `owner` (the debited
    // source, analogous to `transferFrom`'s `from`) sits at arg 2 (bytes 68:100),
    // not arg 0 — every other guarded selector assumes the source is at bytes
    // 4:36, so these need their own branch.
    bytes4 private constant _SEL_ERC4626_WITHDRAW = 0xb460af94; // withdraw(uint256 assets, address receiver, address owner)
    bytes4 private constant _SEL_ERC4626_REDEEM = 0xba087652; // redeem(uint256 shares, address receiver, address owner) — same arg shape as withdraw
    // ERC1363 transferAndCall: push-with-callback sibling of the guarded
    // `transfer`/`push`/`approveAndCall` — recipient at arg 0, same offset.
    bytes4 private constant _SEL_ERC1363_TRANSFER_AND_CALL = 0x1296ee62; // transferAndCall(address to, uint256 value)
    bytes4 private constant _SEL_ERC1363_TRANSFER_AND_CALL_DATA = 0x4000aea0; // transferAndCall(address to, uint256 value, bytes data)

    /// @dev Decode-only mirror of Permit2's `AllowanceTransferDetails` struct —
    ///      never used to call Permit2, only to `abi.decode` a batch
    ///      `transferFrom` call's calldata so `_guardBatchCalls` can inspect every
    ///      element's `from`/`to`. All fields are static, so the array decodes as
    ///      tightly-packed 128-byte elements with no per-element dynamic pointer.
    struct _Permit2BatchDetail {
        address from;
        address to;
        uint160 amount;
        address token;
    }

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

    /// @notice Vault-owner-set agent performance fee, stored offset-by-one so a
    ///         single slot doubles as the is-it-set flag: 0 means never set, and
    ///         `agentFeeBps()` returns the 20% default; otherwise the stored value
    ///         is `fee + 1`, so an explicit 0% stays distinct from unset.
    ///         Snapshotted onto a proposal at propose, clamped to the governor's
    ///         `maxPerformanceFeeBps`.
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

    /// @notice The strategy of the most recently settled proposal, pinned at
    ///         `onProposalSettled` so `_depositsLocked` can ask whether it still
    ///         holds undelivered value.
    ///
    ///         NEEDED BECAUSE THE ORDINARY POINTER IS GONE BY THE TIME IT WOULD
    ///         BE READ: `_activeStrategy()` resolves through
    ///         `getActiveProposal()`, which `_finishSettlement` zeroes
    ///         IMMEDIATELY AFTER calling this vault — the ordering is CEI and
    ///         load-bearing, see the note on `_activeProposal = 0` there. So the
    ///         pointer is still live during `onProposalSettled` and gone by the
    ///         time `_depositsLocked` runs, leaving no path back to the strategy
    ///         that just settled. Pinning here is what survives that gap. Zero
    ///         when unresolvable, which reads as "nothing outstanding" — see
    ///         `_depositsLocked`.
    address private _lastSettledStrategy;

    /// @dev Reserved storage for future upgrades. Shrinks whenever a new state
    ///      variable is added above. Grown from 28 → 31 slots: this deletion
    ///      frees `_laneALockPid` (1), `_interimNetFlow` (1), and
    ///      `_crystallizedMgmt`+`_crystallizedPerf` (1, shared) — legal only
    ///      because no vault proxy is live (see design.md "Deployment reality").
    ///      Back to 30: `_lastSettledStrategy` takes one.
    uint256[30] private __gap;

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
        // _agentFeeBpsPlusOne left 0 (unset) → agentFeeBps() returns the
        // FeeConstants.DEFAULT_AGENT_FEE_BPS (20%) default until the owner calls
        // setAgentFeeBps (no init SSTORE needed).
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
    /// @notice Whether `depositor` may receive shares while the vault is in
    ///         closed-deposit mode.
    /// @dev The whitelist check in `_deposit` runs against `receiver` — the share
    ///      holder — NOT `caller`, the asset payer. A whitelisted user can
    ///      therefore receive shares funded by a non-whitelisted party
    ///      (pay-on-behalf), intentional for KYC flows where compliance attaches
    ///      to the share holder. Checking both sides would break subsidised
    ///      onboarding, so it is not the default.
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
    /// @dev ERC-8004 NFT ownership is verified AT REGISTRATION TIME ONLY. If the
    ///      `agentId` NFT is later transferred, the registered `agentAddress`
    ///      retains its privileges until the owner calls `removeAgent`.
    ///      Re-querying on every execution would add a per-call external view to
    ///      the hot path and hard-couple the vault to an external registry;
    ///      off-chain monitoring should trigger `removeAgent` instead.
    function registerAgent(uint256 agentId, address agentAddress) external onlyOwner {
        SyndicateVaultAdminLib.registerAgent(_agents, _agentSet, agentId, agentAddress, _agentRegistry, owner());
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fully deletes the `_agents[agentAddress]` struct rather than flipping
    ///      `active = false`, so stale `agentId`/`agentAddress` fields cannot be
    ///      silently reused if `registerAgent` is later called for the same slot.
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
    /// @dev Factory-only, used by `SyndicateFactory.rotateOwner` alongside the
    ///      registry's `transferOwnerStakeSlot`, so the old owner's slashed or
    ///      unstaked position can be rebound to a fresh operator without
    ///      redeploying the vault.
    /// @dev Drains `_agentSet` entirely so an at-cap vault does not brick the new
    ///      owner — 32 dead entries could otherwise be neither re-registered (cap
    ///      blocks) nor purged (`AgentNotActive` blocks `removeAgent`). Snapshots
    ///      via `.values()` first so the in-loop `remove` does not invalidate
    ///      iteration.
    function rotateOwnership(address newOwner) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newOwner == address(0)) revert ZeroAddress();
        SyndicateVaultAdminLib.drainAgents(_agents, _agentSet);
        _transferOwnership(newOwner);
    }

    /// @notice Blocks direct `OwnableUpgradeable` owner rotation. The factory's
    ///         `rotateOwner` is the only legal route — it enforces no active or
    ///         open proposal, owner-stake clear and registry alignment, then calls
    ///         `rotateOwnership` here. The inherited setters would desync factory
    ///         and registry records and, via `renounceOwnership`, permanently
    ///         orphan the vault.
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

    /// @dev Proposal id to tag a queued `requestDeposit` with. `_activePid()`
    ///      reads 0 until EXECUTE, but `requestDeposit` opens as soon as ANY
    ///      non-terminal proposal exists, which is earlier. Exactly one top-level
    ///      proposal is ever open on this vault at a time, so the governor's
    ///      monotonic `proposalCount()` already names that open proposal in the
    ///      gap; from EXECUTE onward the two agree.
    /// @dev Deliberately a low-level staticcall, same reasoning as
    ///      `_pricingSupply()`: `proposalCount()` is selector-stable but is not
    ///      declared on `IProposalStatus`, which is intentionally narrowed. A
    ///      missing selector degrades to pid 0 rather than reverting, so a
    ///      nonstandard governor can never brick `requestDeposit`.
    function _openProposalPid() private view returns (uint256) {
        address gov = _getGovernor();
        uint256 active = IProposalStatus(gov).getActiveProposal();
        if (active != 0) return active;
        (bool ok, bytes memory ret) = gov.staticcall(abi.encodeWithSignature("proposalCount()"));
        return (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Every delegatecall re-verifies that `_executorImpl`'s bytecode still
    ///      matches the hash stamped at init, so a factory misconfig or a swapped
    ///      executor address cannot deflect the delegatecall elsewhere. Gated by
    ///      `whenNotPaused`: pausing halts strategy execution alongside LP flow.
    function executeGovernorBatch(
        BatchExecutorLib.Call[] calldata calls,
        uint256[] calldata callCaps,
        uint256 maxNetOutflow
    ) external onlyGovernor nonReentrant whenNotPaused {
        if (_executorImpl.codehash != _expectedExecutorCodehash) {
            revert ExecutorCodehashMismatch();
        }
        _guardBatchCalls(calls);
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        // The lib's unmetered 1-arg `executeBatch(Call[])` overload was
        // deleted in issue #43 §5 — the metered 3-arg signature is the only
        // one left, so `abi.encodeCall` resolves it unambiguously again.
        (bool success, bytes memory returnData) =
            _executorImpl.delegatecall(abi.encodeCall(BatchExecutorLib.executeBatch, (calls, asset(), callCaps)));
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
        // trivially; the governor passes the proposal's maxCapital on execute,
        // settlement and emergency paths, and honest unwinds are net-inflow, so
        // the finite cap never binds them.
        //
        // This is a COARSE custody cap — it meters the vault's own `asset()`
        // balance delta, so capital deployed INTO an allowlisted adapter counts as
        // outflow the same as an extraction. What it GUARANTEES holds only
        // TOGETHER with `_guardBatchCalls`: the meter bounds the `asset()` a
        // single batch moves out of custody, and the guard closes the
        // balance-invisible exfiltration routes — the callee gate (any target that
        // is neither `asset()` nor allowlisted is refused) plus the retained
        // selector checks beneath it. The precise extractable bound is the tier
        // system's per-call coverage.
        //
        // TWO LAYERS, finest to coarsest:
        //   1. `BatchExecutorLib.executeBatch`'s per-call meter: each call's gross
        //      outflow against its proposer-declared `caps[i]`.
        //   2. This function's `netOutflow` check: a batch-wide backstop against
        //      `maxCapital`. When caps cover every moving call, layer 1 is
        //      strictly tighter, so layer 2 only binds when caps are empty (the
        //      emergency-rescue escape valve) or sum right up to `maxCapital`.
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > maxNetOutflow) revert MaxNetOutflowExceeded(netOutflow, maxNetOutflow);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        // Idle-liquidity floor: a batch may deploy at most (1 − minBufferBps)
        // of the pre-batch float. Inflow (settle) batches pass trivially.
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Wraps `_isPrivilegedBatchTarget` — the same predicate
    ///      `_guardBatchCalls` enforces. Exposed so the governor's
    ///      propose-time validation answers through this one implementation
    ///      instead of restating the address set (vault, bound queue).
    function isPrivilegedBatchTarget(address target) external view returns (bool) {
        return _isPrivilegedBatchTarget(target);
    }

    /// @notice Re-point the shared `BatchExecutorLib` and re-stamp its expected
    ///         codehash, atomically. Reached only through the factory's
    ///         lifecycle-gated `pushExecutor`.
    /// @dev Factory-only. Rejects zero and codeless targets — a swapped-in address
    ///      with no code would pass every future `codehash` check vacuously and
    ///      the next delegatecall would no-op against it, silently disabling batch
    ///      execution instead of failing loudly here.
    function setExecutorImpl(address newImpl) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newImpl == address(0) || newImpl.code.length == 0) revert InvalidExecutorImpl();
        address old = _executorImpl;
        _executorImpl = newImpl;
        _expectedExecutorCodehash = newImpl.codehash;
        emit ExecutorImplSet(old, newImpl);
    }

    /// @dev Two-part batch gate: a privileged-TARGET denylist (Part 1, always
    ///      runs), then the value-moving-SELECTOR allowlist (Part 2,
    ///      registry-dependent). The two are independent — do not collapse them,
    ///      and do not move Part 1 below Part 2's registry lookup.
    ///
    ///      PART 1: PRIVILEGED-TARGET DENYLIST. Selector-guarding is not enough,
    ///      because this adversary needs no value-moving selector at all. The
    ///      batch runs via delegatecall, so every sub-call reaches its target
    ///      carrying `msg.sender == vault` — exactly what the withdrawal queue's
    ///      `onlyVault` gate checks. `queue.queueRedeem(attacker, victimShares,
    ///      pid)` therefore clears that gate and mints the attacker a claim on
    ///      shares the queue already escrows for someone else, while every other
    ///      guard reads it as harmless: the queue's entrypoints move ZERO vault
    ///      `asset()` in-tx (the value leaves later via `queue.claim`), so the
    ///      net-outflow meter, the queue-reserve floor and the buffer floor all
    ///      see nothing, and coverage prices an uncertified target at tier 2 — a
    ///      price a 1-wei proposal buys. Blocked as a target CLASS rather than a
    ///      selector list, so the next privileged queue function is covered by
    ///      default. UNCONDITIONAL, above Part 2's registry staticcall and both of
    ///      its degrade-open returns: a queue steal is not priced, it is theft.
    ///      SCOPE is exactly two addresses — the vault and its bound queue — not a
    ///      target allowlist; adapters' own `onlyVault` entrypoints stay open.
    ///
    ///      PART 1b: transferFrom SOURCE GUARD (LP-ALLOWANCE CONFISCATION). Same
    ///      loop, same unconditional posture, different adversary:
    ///      `asset.transferFrom(victim, vault, victimBal)` spends
    ///      `allowance[victim][vault]` — the very allowance every LP grants to
    ///      deposit, which UIs routinely set to `type(uint256).max`. Every other
    ///      meter is blind: net-outflow reads 0 because the vault's OWN balance
    ///      rises, coverage prices the target against the vault's own maxCapital
    ///      rather than a third party's wallet, and Part 2's
    ///      `to == vault -> continue` exemption passes it outright. `from`
    ///      (calldata bytes 4:36) is decoded here and MUST equal the vault itself.
    ///
    ///      `isAdapterAllowed` is DELIBERATELY NOT CONSULTED as a source
    ///      allowlist: it encodes DESTINATION consent, not permission to spend an
    ///      address's allowances to the vault. No honest batch pulls FROM a
    ///      non-vault address — capital deploys via `approve(adapter)` plus the
    ///      adapter pulling in its own code, and returns are pushes.
    ///      `from == address(this)` stays permitted: it is semantically
    ///      `transfer(x, amt)`, and `x` remains destination-guarded by Part 2.
    ///
    ///      PART 2a: THE CALLEE GATE (outer boundary). Runs on every call, before
    ///      any selector is examined, and refuses any callee that is neither
    ///      `asset()` nor TierRegistry-allowlisted — closing the
    ///      unenumerable-selector class that repeated rounds of selector
    ///      enumeration kept failing to cover.
    ///
    ///      PART 2b: VALUE-MOVING-SELECTOR ALLOWLIST (inner boundary). The
    ///      net-outflow meter only sees the vault's own `asset()` balance delta,
    ///      so `token.approve(attacker, max)` meters zero while the attacker
    ///      drains via `transferFrom` in a later tx. Gating the spender/recipient
    ///      of the guarded selectors bounds ERC20 exfiltration over the
    ///      now-finite set of allowlisted callees: for approve /
    ///      increaseAllowance / transfer the guarded address is arg 1 (bytes
    ///      4:36); for transferFrom (legacy and Permit2) and DSToken `move` it is
    ///      `to`, arg 2 (bytes 36:68); for Permit2 `approve` it is `spender`, ALSO
    ///      arg 2, since Permit2's extra leading `token` arg shifts it one slot
    ///      right of legacy `approve`. The address must be the vault itself (with
    ///      the `asset()` exception below) or a TierRegistry-allowlisted adapter.
    ///      Runs on every governor batch, settlement included.
    ///
    ///      SELF-TRANSFER FAST-PATH SCOPED TO `asset()`: `recipient ==
    ///      address(this) -> continue` would otherwise skip the registry check for
    ///      ANY token whose destination decodes to the vault, not only the one
    ///      token the outer balance-diff meter independently verifies — letting a
    ///      non-standard token execute arbitrary logic under
    ///      `transferFrom(vault, vault, amount)` with zero verification anywhere.
    ///      The fast-path therefore additionally requires
    ///      `calls[i].target == asset()`.
    ///
    ///      RESIDUALS. (a) Exotic assets — ERC721 `setApprovalForAll`, ERC1155,
    ///      LP-position NFTs — are refused as callees by default under PART 2a,
    ///      closing the whole class including standards never enumerated here. If
    ///      one is ever allowlisted anyway its non-ERC20 selectors pass this
    ///      switch unexamined, so the operator invariant is: exotic-asset
    ///      contracts MUST NOT be allowlisted as batch callees. (b) Coverage is
    ///      PER-SELECTOR, NOT PER-ROUTER — do not read Permit2/DSToken/ERC1363 as
    ///      guarded routers; only the enumerated selectors are, within the set of
    ///      callees PART 2a admits. ERC-777 `operatorSend` and any other
    ///      unenumerated router shape still pass unexamined on an allowlisted
    ///      target. (c) Both parts trust calldata pattern-matching over verified
    ///      balance movement for every token except `asset()`. (d) The
    ///      self-transfer fast-path is structurally unreachable for
    ///      Permit2-routed selectors, since a Permit2 call's target is the Permit2
    ///      singleton — this fails CLOSED, so it is a possible over-restriction,
    ///      not a fund-safety gap.
    ///
    ///      UNSET REGISTRY: with no tier registry wired (or a governor predating
    ///      the getter), PART 2 cannot run and is skipped by design — the default
    ///      is tier-2 / full-notional pricing anyway, and hard-reverting would
    ///      brick registry-less vaults. PART 1 IS NOT AFFECTED: it needs no
    ///      registry and sits above both early returns. Pinned by
    ///      `test_targetGate_bitesEvenWithNoTierRegistryWired` and
    ///      `test_targetGate_bitesEvenWhenGovernorHasNoTierGetter`, one per
    ///      degrade-open branch, so relocating Part 1 below either return fails a
    ///      test rather than silently re-opening the hole.
    function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
        // PRIVILEGED-CALLEE GATE, ahead of everything else.
        //
        // The batch runs under delegatecall, so every call carries
        // `msg.sender == vault`. For the QUEUE that is decisive: its `onlyVault`
        // gate is satisfied by a batch that merely names it as a target.
        //
        // For the VAULT the reason is different, and worth stating precisely so
        // nobody re-permits it on a wrong premise. `msg.sender == vault` does NOT
        // open this contract's self-gated functions — `settleRedeem`/
        // `settleDeposit` require the queue, and it satisfies neither `onlyOwner`,
        // `onlyGovernor` nor the factory gate. The exposure is the PERMISSIONLESS
        // surface instead, chiefly `requestDeposit`: a batch naming the vault can
        // escrow the vault's own float into the queue while directing the
        // resulting deposit claim to an attacker. That one IS metered — the float
        // genuinely leaves — so blocking the vault is defense-in-depth rather than
        // a second live hole; it removes the standing dependency on no
        // permissionless entrypoint ever becoming dangerous to call as ourselves.
        //
        // No other meter catches the queue case. `queue.queueRedeem(attacker,
        // victimShares, pid)` mints a redeem claim against shares another owner
        // escrowed while moving ZERO `asset()`, the value leaves in a LATER
        // transaction via `queue.claim` which nothing meters, and coverage prices
        // an uncertified target at tier 2 — a 1-wei proposal any single approver
        // clears.
        //
        // BEFORE THE REGISTRY LOOKUP, DELIBERATELY. The selector guard below
        // returns early for a governor with no registry, and that exemption is a
        // documented default for PRICING a call — not for refusing a capability.
        //
        // A TARGET CLASS, NOT A SELECTOR LIST: enumerating today's privileged
        // functions would leave the next one unprotected, and nothing a batch
        // legitimately does names these two addresses. `stampSettlement` shows why
        // breadth matters — it is one-shot per pid, so one batch can pre-burn the
        // settlement slot of proposals that have not happened yet.
        for (uint256 i = 0; i < calls.length; i++) {
            address target = calls[i].target;
            if (_isPrivilegedBatchTarget(target)) {
                revert DisallowedBatchTarget(target);
            }
            // `transferFrom` SOURCE guard — unconditional, same pass, same
            // rationale as the target denylist. Covers legacy `transferFrom` AND
            // every alternate-signature pull-via-delegated-allowance selector this
            // guard recognizes; all place the debited source at bytes 4:36.
            bytes calldata data = calls[i].data;
            if (data.length >= 4) {
                bytes4 sel = bytes4(data[0:4]);
                if (
                    sel == _SEL_TRANSFER_FROM || sel == _SEL_PERMIT2_TRANSFER_FROM || sel == _SEL_DSTOKEN_PULL
                        || sel == _SEL_DSTOKEN_MOVE || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL
                        || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA
                ) {
                    if (data.length < 68) revert MalformedCall();
                    address from = address(uint160(uint256(bytes32(data[4:36]))));
                    if (from != address(this)) revert DisallowedTransferFromSource(target, from);
                } else if (sel == _SEL_PERMIT2_BATCH_TRANSFER_FROM) {
                    // Dynamic array, not a fixed-offset slice: decode every element
                    // and require each one's `from` to be the vault, per-element
                    // instead of once. `abi.decode` always returns memory for
                    // dynamic types, which is fine here since it is only read.
                    if (data.length < 36) revert MalformedCall();
                    _Permit2BatchDetail[] memory details = abi.decode(data[4:], (_Permit2BatchDetail[]));
                    for (uint256 j = 0; j < details.length; j++) {
                        if (details[j].from != address(this)) {
                            revert DisallowedTransferFromSource(target, details[j].from);
                        }
                    }
                } else if (sel == _SEL_ERC4626_WITHDRAW || sel == _SEL_ERC4626_REDEEM) {
                    // `owner` (the debited source) is arg 2 (bytes 68:100),
                    // not arg 0 like every other guarded selector above —
                    // OZ's ERC4626 `_withdraw` spends `owner`'s allowance to
                    // `caller` (the vault) exactly like `transferFrom` spends
                    // `from`'s.
                    if (data.length < 100) revert MalformedCall();
                    address ownerArg = address(uint160(uint256(bytes32(data[68:100]))));
                    if (ownerArg != address(this)) revert DisallowedTransferFromSource(target, ownerArg);
                }
            }
        }

        // onlyGovernor holds, so msg.sender IS the governor. staticcall (not a
        // typed call) so a governor without the getter degrades to "unset".
        (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
        if (!ok || ret.length != 32) return;
        address registry = abi.decode(ret, (address));
        if (registry == address(0)) return;

        address asset_ = asset();
        for (uint256 i = 0; i < calls.length; i++) {
            // ── PART 2a: target-based callee gate (issue #166, Option B) ──
            // Runs on EVERY call — before the short-calldata continue below, so
            // empty-calldata and native-`value` calls are gated too. asset() is
            // the sole exemption (design.md Decision 2); everything else must be
            // an allowlisted, codehash-current adapter.
            //
            // READS THE CALLEE AXIS (`isCallableTarget`), NOT `isAdapterAllowed`
            // (pashov finding #14). The two used to be one registry bit, so a
            // demotion — reachable permissionlessly, since `ChallengeGame.file`
            // only needs the pair to appear in the executed proposal's calldata,
            // and every execute batch names `(clone, execute.selector)` — revoked
            // the vault's ability to CALL the very clone holding its capital.
            // `settleProposal`, `unstick` and `finalizeEmergencySettle` all
            // reverted here, the proposal pinned in `Executed`, and every LP exit
            // shut. The recipient/spender checks in PART 2b still read
            // `isAdapterAllowed`, so a demoted clone remains reclaimable but
            // unfundable. No lifecycle state is grandfathered: this stays one
            // unconditional rule, evaluated per call, exactly as before.
            address target = calls[i].target;
            if (target != asset_ && !ITierRegistry(registry).isCallableTarget(target)) {
                revert DisallowedBatchCallee(target);
            }
            bytes calldata data = calls[i].data;
            // ── PART 2b: value-moving-selector checks (retained, unchanged) ──
            if (data.length < 4) continue;
            bytes4 sel = bytes4(data[0:4]);
            address recipient;
            if (
                sel == _SEL_APPROVE || sel == _SEL_INCREASE_ALLOWANCE || sel == _SEL_TRANSFER
                    || sel == _SEL_DSTOKEN_PUSH || sel == _SEL_ERC1363_APPROVE_AND_CALL
                    || sel == _SEL_ERC1363_APPROVE_AND_CALL_DATA || sel == _SEL_ERC1363_TRANSFER_AND_CALL
                    || sel == _SEL_ERC1363_TRANSFER_AND_CALL_DATA
            ) {
                // DSToken push(dst, wad) is transfer's sibling — dst at arg 1
                // (bytes 4:36), same as _SEL_TRANSFER. ERC1363 approveAndCall
                // (+data) is approve's sibling, and transferAndCall(+data) is
                // transfer's sibling — spender/to at arg 1, same offset,
                // trailing args (amount/bytes) unread and irrelevant.
                if (data.length < 36) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[4:36]))));
            } else if (
                sel == _SEL_TRANSFER_FROM || sel == _SEL_PERMIT2_TRANSFER_FROM || sel == _SEL_DSTOKEN_MOVE
                    || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL || sel == _SEL_ERC1363_TRANSFER_FROM_AND_CALL_DATA
            ) {
                // Legacy/Permit2 transferFrom, DSToken move, and ERC1363
                // transferFromAndCall (+data) all place `to`/`dst` at arg 2
                // (bytes 36:68) — ERC1363's trailing `bytes` overload adds a
                // 4th arg AFTER `amount`, so it does not shift this offset.
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_PERMIT2_APPROVE) {
                // Permit2's `approve(token, spender, uint160, uint48)` carries
                // an extra leading `token` arg vs legacy `approve(spender,
                // amount)`, shifting the guarded `spender` to arg 2 (bytes
                // 36:68) instead of arg 1 (bytes 4:36).
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_ERC4626_WITHDRAW || sel == _SEL_ERC4626_REDEEM) {
                // `receiver` is arg 1 (bytes 36:68); `owner` (already
                // source-checked in Part 1b above) is arg 2 and irrelevant
                // here — same offset as the transferFrom-shaped group above,
                // kept as its own branch since the source check that landed
                // it here uses a different offset (arg 2, not arg 0).
                if (data.length < 68) revert MalformedCall();
                recipient = address(uint160(uint256(bytes32(data[36:68]))));
            } else if (sel == _SEL_PERMIT2_BATCH_TRANSFER_FROM) {
                // Dynamic array: apply the exact same per-element fast-path
                // and registry check the single-recipient path below applies
                // once, but once per element, then fall through to the next
                // batch call — this selector never sets the shared
                // `recipient` local.
                if (data.length < 36) revert MalformedCall();
                _Permit2BatchDetail[] memory details = abi.decode(data[4:], (_Permit2BatchDetail[]));
                for (uint256 j = 0; j < details.length; j++) {
                    address to = details[j].to;
                    if (to == address(this) && calls[i].target == asset_) continue;
                    if (!ITierRegistry(registry).isAdapterAllowed(to)) {
                        revert DisallowedTransferTarget(calls[i].target, sel, to);
                    }
                }
                continue;
            } else {
                // UNRECOGNIZED SELECTOR ON THE ONE EXEMPT TARGET.
                //
                // PART 2a lets `asset()` through without an allowlist check, on
                // the premise that the outer `netOutflow` meter independently
                // verifies it via a balance diff. A balance diff sees VALUE
                // MOVEMENT; it does not see an AUTHORIZATION grant. ERC-777
                // `authorizeOperator` — and any allowance-delegation shape not
                // enumerated above — moves zero balance in-batch and licenses an
                // unbounded pull in a LATER transaction, after every meter here
                // has passed. Nothing downstream catches it either: declared at
                // cap 0, `requiredCoverage` prices to 0, so no guardian books
                // coverage, no proposer bond is locked, and `ChallengeGame.file`
                // reverts on the empty approver set — the proposal is
                // unchallengeable.
                //
                // Scoped deliberately to `asset()`: every other target already
                // cleared PART 2a's allowlist, and the terminal `continue` is
                // load-bearing for them, since ordinary batch calls carry
                // selectors this switch should not enumerate. The standard ERC-20
                // READS are carved out: a closed, enumerable set that grants
                // nothing and that batches legitimately call on `asset()`.
                if (target == asset_ && !_isBenignAssetRead(sel)) {
                    revert UnrecognizedAssetSelector(sel);
                }
                continue;
            }
            // Self-transfer fast-path is scoped to asset() ONLY: it is the
            // one token the outer `netOutflow` meter in `executeGovernorBatch`
            // independently verifies via a balance diff. Any other token
            // whose destination decodes to the vault still routes through the
            // TierRegistry check below — see the "SELF-TRANSFER FAST-PATH
            // SCOPED TO asset()" note above.
            if (recipient == address(this) && calls[i].target == asset_) continue;
            if (!ITierRegistry(registry).isAdapterAllowed(recipient)) {
                revert DisallowedTransferTarget(calls[i].target, sel, recipient);
            }
        }
    }

    /// @dev The standard ERC-20 view selectors, which a governor batch may
    ///      legitimately call on `asset()` and which cannot grant, move or
    ///      delegate anything. An explicit carve-out from the
    ///      unrecognized-selector rejection above, so that rejection stays pointed
    ///      at state-changing selectors on the one target that skips PART 2a.
    ///      Deliberately excludes `approve`/`transfer`/`transferFrom` and their
    ///      siblings, which are gated on their spender/recipient above.
    function _isBenignAssetRead(bytes4 sel) private pure returns (bool) {
        return sel == 0x70a08231 // balanceOf(address)
            || sel == 0x313ce567 // decimals()
            || sel == 0x18160ddd // totalSupply()
            || sel == 0xdd62ed3e // allowance(address,address)
            || sel == 0x95d89b41 // symbol()
            || sel == 0x06fdde03; // name()
    }

    /// @dev The single implementation of the privileged-batch-target
    ///      predicate — the vault itself, or the bound withdrawal queue.
    ///      `_guardBatchCalls`'s Part 1 loop and the external
    ///      `isPrivilegedBatchTarget` view are its only two callers; neither
    ///      may restate the address set (see the class-not-list rationale in
    ///      `_guardBatchCalls`'s doc comment above).
    function _isPrivilegedBatchTarget(address target) private view returns (bool) {
        address q = _withdrawalQueue;
        return target == address(this) || (q != address(0) && target == q);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev THE QUEUE RESERVE IS NOT SPENDABLE HERE. This was the one
    ///      asset-outflow path that checked only the raw balance, so a settlement
    ///      fee — or a later `claimUnclaimedFees` — could spend float already
    ///      frozen against stamped-unclaimed redeems, leaving the second
    ///      claimant's `settleRedeem` to revert with no `cancel` available to it.
    ///      Reverting is the safe direction, not a lost fee: the governor's
    ///      `_payFee` already treats a failure here as escrow-it-instead.
    function transferPerformanceFee(address asset_, address to, uint256 amount) external onlyGovernor {
        if (asset_ != asset()) revert InvalidAsset();
        if (to == address(0)) revert ZeroAddress();
        uint256 spendable = IERC20(asset_).balanceOf(address(this));
        // BOTH LIABILITIES, not just the queue's (pashov 2026-08 finding #23).
        // `totalAssets()` already treats the vault as owing
        // `reservedQueueAssets() + _escrowedFeeLiability()`; this guard counted
        // only the first, so a later settlement's fee could spend float already
        // booked as an earlier recipient's escrow — after which THEIR
        // `claimUnclaimedFees` reverts `AmountExceedsBalance` with no recovery
        // path, since `_payFee`'s escrow-on-failure is one-shot per settlement.
        //
        // THE CLAIM PATH EXEMPTS ITSELF, STRUCTURALLY — there is no special
        // case here and there must not be one. `claimUnclaimedFees` decrements
        // `_escrowedFees[vault][token]` BEFORE calling this
        // (`SyndicateGovernor.claimUnclaimedFees`), so by the time this runs the
        // liability no longer includes the amount being claimed and the
        // subtraction below leaves exactly enough. Reordering that decrement to
        // after the transfer would brick every escrowed claim.
        //
        // The LP paths (`_availableFloat`, `_withdraw`) deliberately do NOT
        // subtract escrow: `totalAssets()` nets it already, so an LP's share
        // entitlement is reduced by it rather than reserved against it, and
        // double-counting there would refuse withdrawals no liability requires.
        //
        // `_escrowedFeeLiability()` degrades to 0 on an unreadable governor.
        // Stated as a decision: that is the LIVENESS direction on a path whose
        // own failure mode is a lost fee, and it reproduces exactly the
        // pre-existing behaviour rather than inventing a stricter one.
        uint256 reserve = reservedQueueAssets() + _escrowedFeeLiability();
        spendable = spendable > reserve ? spendable - reserve : 0;
        if (amount > spendable) revert AmountExceedsBalance();
        IERC20(asset_).safeTransfer(to, amount);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev The SAME quantity `transferPerformanceFee` tests `amount` against,
    ///      exposed as a view so the governor can size an escrow it is about to
    ///      book instead of discovering the ceiling by reverting.
    ///
    ///      WHY THIS EXISTS. `SyndicateGovernor._payFee` escrows the full
    ///      requested amount on ANY revert, and one legitimate revert reason is
    ///      `AmountExceedsBalance` — the vault saying "I do not have this." A
    ///      liability booked for that reason is unbacked by construction: it
    ///      flows into `_escrowedFeeLiability()`, which `totalAssets()` subtracts,
    ///      so an escrow exceeding the float pins `totalAssets()` to 0 (zeroing
    ///      every LP's conversion and stamping the settle price at `num == 1`),
    ///      and `claimUnclaimedFees` — which re-requests the SAME full amount —
    ///      then fails the same comparison forever, with `rescueERC20` unable to
    ///      touch the vault asset. A fee cannot exceed the assets it is charged
    ///      against; letting the governor read the ceiling is what keeps the
    ///      distinction between "recipient cannot receive" and "vault cannot pay"
    ///      visible at book time, when it is still actionable.
    function spendableFee(address asset_) external view returns (uint256) {
        if (asset_ != asset()) return 0;
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        uint256 reserve = reservedQueueAssets() + _escrowedFeeLiability();
        return bal > reserve ? bal - reserve : 0;
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
    ///      OR when the active proposal opted out. Still wrapped in try/catch: an
    ///      `address` return says nothing about EXISTENCE, and the vault (UUPS)
    ///      and governor (beacon) upgrade on independent paths, so a vault impl
    ///      calling `strategyOf` can go live before the governor beacon carries
    ///      it. The only consumer is an off-chain-facing view.
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
    function agentFeeBps() public view returns (uint256) {
        // One SLOAD: 0 = never set → the 20% default (agent never silently
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

    // ==================== OVERRIDES ====================

    /// @dev Resolve diamond between ERC20Upgradeable and ERC20VotesUpgradeable.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);

        // HIGH-WATER MARK RESET ON FULL DRAIN.
        //
        // `_highWaterPricePerShare` is seeded once, at the first mint, and
        // otherwise only ever advances. It was NEVER reset when `totalSupply()`
        // returns to zero, while the ERC-4626 share/asset SCALE is independently
        // re-derived from `(residualAssets + 1)` on the very next deposit. The
        // result: a re-seeding deposit's price-per-share can land at
        // `(residualAssets + 1)x` the STALE mark, and `aboveHighWaterMark` then
        // reads almost the entire new principal as performance-fee base on a
        // zero-P&L re-seed — charged against brand-new capital that never earned a
        // cent. Reaching `totalSupply() == 0 && totalAssets() > 0` is not exotic:
        // redeem-flooring dust, the queue's deliberate dust release,
        // `_unclaimedFees` escrow, or a bare ERC20 donation all leave residual
        // assets behind an empty share supply.
        //
        // Zeroing here, on EVERY burn/mint/transfer that empties supply (this hook
        // is the single OZ chokepoint for all of them), makes the next mint treat
        // the fund as freshly created. A mint in the SAME call as the draining
        // burn is impossible for a single ERC20 `_update`; sequential
        // burn-then-mint across two calls is exactly the case this closes.
        if (totalSupply() == 0) {
            _highWaterPricePerShare = 0;
        }

        // AUTO-DELEGATE ON EVERY RECEIPT. Runs AFTER `super._update` so the
        // recipient's post-receipt balance is what checkpoints. Holders that
        // explicitly delegated away keep their choice.
        //
        // The behaviour is kept because `getPastVotes == balance` is what makes
        // this vault's OWN governance readable: a holder who never calls
        // `delegate` still carries weight, which every snapshot-based read here
        // assumes. Removing it would silently zero the voting weight of every
        // non-delegating holder.
        //
        // The heal is permissionless and needs no action from the holder: it also
        // runs on a zero-value transfer, so anyone can arm a stranded undelegated
        // holder by sending it 0 shares.
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
    /// @dev AND WHILE THE LAST SETTLEMENT STILL HAS VALUE IN FLIGHT.
    ///      `openProposalCount() != 0` covers the window where capital is
    ///      deployed, on the reasoning that `totalAssets()` reads only
    ///      `balanceOf(this)` and so under-reports while a strategy holds funds.
    ///      That reasoning does not stop at settlement: strategy settlement is
    ///      DELIVERABLE-MAXIMUM, not all-or-revert (`MorphoSupplyStrategy` caps
    ///      at the market's idle balance and emits `SettlementIncomplete`), so a
    ///      settled proposal can leave a residue on the clone while
    ///      `_finishSettlement` has already cleared the open count.
    ///
    ///      In that gap `totalAssets()` under-reports by the residue and
    ///      deposits are open, so a depositor mints against a price missing
    ///      value that is still coming back. The permissionless `sweep()` then
    ///      returns it into the enlarged share pool, and the difference —
    ///      `A * R / (float + A)` for a deposit `A` against residue `R` — comes
    ///      out of the LPs who were already in. No privileged action, repeatable
    ///      per proposal, and an attacker can induce the residue rather than
    ///      wait for it: `_deliverableNow` caps at Morpho's idle balance, which
    ///      a fee-free `flashLoan` removes for one callback frame.
    ///
    ///      NOBODY IS WEDGED BY THIS. `sweep()` is permissionless and untaxed,
    ///      so the very depositor this refuses can call it and then deposit at
    ///      the correct price. That is the property that makes locking safe
    ///      here, where blocking SETTLEMENT itself would not be — an illiquid
    ///      market must never trap the vault, which is why the deliverable-
    ///      maximum design exists and why this guard is on deposits only.
    ///
    ///      DEGRADES OPEN, STATED. A strategy that cannot answer leaves deposits
    ///      unlocked — the pre-existing behaviour — rather than locked. Failing
    ///      closed here would let one non-conforming clone brick deposits for
    ///      the vault's whole remaining life, with no permissionless way out,
    ///      which is a worse and less reversible failure than the mispricing it
    ///      would be guarding against. Same doctrine as `_escrowedFeeLiability`.
    ///
    ///      This closes the MINT side only. Queued redeemers stamped in the same
    ///      `onProposalSettled` call are still priced at the float-only figure
    ///      and remain underpaid by the residue; that half needs `totalAssets()`
    ///      itself to count strategy-held value and is deliberately not done
    ///      here.
    function _depositsLocked() private view returns (bool) {
        if (IProposalStatus(_getGovernor()).openProposalCount() != 0) return true;
        address s = _lastSettledStrategy;
        if (s == address(0)) return false;
        (bool ok, bytes memory ret) =
            s.staticcall{gas: _PROBE_GAS}(abi.encodeCall(IStrategyDelivery.hasUndeliveredValue, ()));
        if (!ok || ret.length != 32) return false;
        return abi.decode(ret, (uint256)) != 0;
    }

    /// @dev Float available for instant exits = vault asset balance minus the
    ///      queue's reserved (already-settled, unclaimed) redeem float. Shared by
    ///      `maxWithdraw` / `maxRedeem`. Floors at 0 when float < reserve.
    function _availableFloat() private view returns (uint256) {
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        return float > reserve ? float - reserve : 0;
    }

    /// @dev Closed-deposit gate: reverts unless deposits are open OR `who` is
    ///      whitelisted. Shared by `_deposit` / `requestDeposit`.
    function _requireApprovedDepositor(address who) private view {
        if (!_openDeposits && !_approvedDepositors.contains(who)) revert NotApprovedDepositor();
    }

    /// @inheritdoc ERC4626Upgradeable
    // The `nonReentrant` guard lives on the internal `_deposit` (both `deposit`
    // and `mint` route through it), so the public entrypoints keep OZ's inherited
    // bodies and we do not pay for two wrapper overrides (EIP-170 headroom).
    // Defence-in-depth against cross-function reentrancy on the share-price path:
    // a reentrant deposit during another mint could mint against a
    // transiently-deflated NAV.
    //
    // The `withdraw`/`redeem` paths take no `nonReentrant` — not load-bearing.
    // Withdraw transfers the asset OUT to the receiver, there is no live-withdraw
    // adapter callback, and any reentry into deposit/mint is still blocked by
    // `_deposit`'s latch.

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Idle float minus the queue reserve, floored at zero.
    ///      `stampSettlement` froze the reserved assets against a `num/den` that
    ///      can no longer move, so they are owed in a fixed amount and are no
    ///      longer part of what a residual share is a claim on.
    ///
    ///      NEVER ALONE. The matching shares must leave the pricing supply in the
    ///      same breath — see `_pricingSupply`. Subtracting assets without their
    ///      shares would understate the price as badly as double-counting them
    ///      would overstate it.
    ///      THE QUEUE RESERVE IS NOT THE ONLY LIABILITY (pashov review finding
    ///      #3). A fee whose transfer failed is escrowed by
    ///      `SyndicateGovernor._payFee` and LEFT HERE — owed exactly like a
    ///      queue reserve, but previously counted as LP equity, so redeemers in
    ///      the post-settle window took a slice of the fee recipient's money.
    function totalAssets() public view override returns (uint256) {
        uint256 gross = IERC20(asset()).balanceOf(address(this));
        uint256 owed = reservedQueueAssets() + _escrowedFeeLiability();
        // Cannot legitimately underflow — the reserve tracks assets the vault
        // holds — but under-reporting beats inventing value if it ever did.
        return gross > owed ? gross - owed : 0;
    }

    /// @dev Escrowed fee liability this vault owes, read from its governor.
    ///      Low-level staticcall degrading to zero on any failure, matching
    ///      `_openProposalPid` and `_pricingSupply`: `totalAssets()` sits on
    ///      every pricing path in this contract, so a governor predating
    ///      `outstandingEscrow` — or any nonstandard implementation — must not
    ///      brick deposits, redemptions and settlement. Degrading to zero
    ///      reproduces exactly the previous behaviour, never anything worse.
    /// @dev COST, measured (PR #195 review, minor 4): ~5,535 gas the first time
    ///      the governor is touched in a transaction (cold account access) and
    ///      ~896 gas on every subsequent `totalAssets()` in that same
    ///      transaction, once the address is warm. Since `totalAssets()` sits
    ///      on the deposit / redeem / preview / settle paths, the realistic
    ///      per-transaction cost is one cold hit plus warm repeats — the
    ///      governor is already touched by most of those flows for other
    ///      reasons, so in practice this is usually the warm figure.
    function _escrowedFeeLiability() private view returns (uint256) {
        address gov = _getGovernor();
        if (gov == address(0)) return 0;
        (bool ok, bytes memory ret) =
            gov.staticcall(abi.encodeCall(ISyndicateGovernor.outstandingEscrow, (address(this), asset())));
        return (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

    /// @dev The supply a price is actually taken against: circulating shares LESS
    ///      the escrowed redeem shares whose settle price is already stamped.
    ///      Those shares are still in `totalSupply()` — the vault burns them at
    ///      `claim`, not at the stamp — but they are no longer a claim on the pool.
    ///
    ///      PAIRED WITH `totalAssets`, INSEPARABLY: both legs of the same claim
    ///      leave together, so a `claim` moves neither the price nor anyone else's
    ///      position. PRE-STAMP ESCROW STAYS IN — a queued-but-unsettled redeem
    ///      has no frozen price yet and still floats with the pool, which is why
    ///      this reads `stampedUnclaimedShares()` rather than `pendingShares()`.
    ///      FLOORED AT ZERO defensively; the counter is a subset of the balance
    ///      the queue holds, so the branch is unreachable today.
    ///
    ///      Deliberately a low-level staticcall rather than a typed call:
    ///      `VaultWithdrawalQueue` is not a proxy, so a queue deployed before this
    ///      function existed can never gain the selector. A typed call would
    ///      revert for that legacy pairing, and this sits on the conversion path,
    ///      so the revert would brick every deposit, withdraw, preview and fee
    ///      calc. A missing selector degrades to 0 instead; full remediation for
    ///      an existing syndicate requires redeploying the vault/queue pair.
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

    /// @dev Instant deposit is allowed only outside an open proposal. During an
    ///      open proposal (Pending..Executed) it reverts and LPs use the async
    ///      deposit queue (`requestDeposit`), entering at the realized settle
    ///      price. Auto-delegate to self so shareholders get voting power.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
        nonReentrant
    {
        if (_depositsLocked()) revert DepositsLocked();
        _requireApprovedDepositor(receiver);
        super._deposit(caller, receiver, assets, shares);
        // The fund's first shares establish the high-water mark. Cannot be done
        // at `initialize` — before any shares exist there is no price.
        _initHighWaterMarkIfUnset();

        // Auto-delegation happens in `_update` (every receipt path).
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
            // A shortfall beyond idle float has nowhere to come from — there is
            // no strategy pull without Lane A. Same error surface as the old
            // `_pullFromStrategy` path for a non-Lane-A vault.
            if (assets + reserve > float) revert QueueReserveBreached();
        }

        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    /// @dev Cap visible to integrators so they don't propose withdrawals that
    ///      would breach the queue's reservation. Returns 0 while
    ///      `redemptionsLocked()` (instant withdraw is closed during a proposal;
    ///      LPs use `requestRedeem`). The bound queue bypasses the reserve cap
    ///      because the reserved float belongs to it.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxWithdraw(owner_);
        if (redemptionsLocked()) return 0;
        uint256 userMax = super.maxWithdraw(owner_);
        uint256 available = _availableFloat();
        return userMax > available ? available : userMax;
    }

    /// @dev Cap visible to integrators so they don't propose redeems that would
    ///      breach the queue's reservation. Returns 0 while `redemptionsLocked()`.
    ///      The bound queue bypasses the reserve cap (see `maxWithdraw`).
    function maxRedeem(address owner_) public view override returns (uint256) {
        if (paused()) return 0;
        if (owner_ == _withdrawalQueue) return super.maxRedeem(owner_);
        if (redemptionsLocked()) return 0;
        uint256 userMax = super.maxRedeem(owner_);
        uint256 reserveShares = pendingQueueShares();
        uint256 ts = totalSupply();
        if (ts == 0 || reserveShares >= ts) return 0;
        uint256 availableShares = ts - reserveShares;
        uint256 backingAssets = _availableFloat();
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
    ///         anyone can settle once `redemptionsLocked() == false`.
    /// @dev `whenNotPaused` blocks queueing while the vault is paused. LPs are not
    ///      trapped — the queue's `cancel` path is unpaused and returns escrowed
    ///      shares to the owner at any time.
    /// @return requestId Always > 0 — the queue uses index 0 as a sentinel.
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
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }
        // Move shares into queue custody. `_update` auto-delegates the queue to
        // itself, so custody shares keep checkpointed voting weight AT THE QUEUE —
        // now merely consistent rather than load-bearing, since nothing is
        // apportioned and the queue has no governance surface. For proposals
        // already open at request time, the voter's checkpoint at
        // `snapshotTimestamp` is frozen with the pre-transfer weight, so vote
        // power is preserved for in-flight proposals; queued shares forfeit voting
        // power for any proposal opened after escrow.
        uint256 pid = _activePid();
        _transfer(owner_, q, shares);
        requestId = IVaultWithdrawalQueue(q).queueRedeem(owner_, shares, pid);
        emit RedeemRequested(requestId, owner_, shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Mint-deferred deposit used while a strategy proposal is active.
    ///         Escrows `assets` in the queue (off-vault, so they never inflate
    ///         `totalAssets` nor get swept into the strategy) and records a claim
    ///         that mints shares at the realized settle price.
    /// @dev Gated on `openProposalCount() != 0` — the SAME predicate the instant
    ///      path closes on — not `redemptionsLocked()`, which is true only from
    ///      EXECUTE onward. Those two diverge for the whole
    ///      Pending/GuardianReview/Approved window: instant deposit is already
    ///      closed there, so gating on `redemptionsLocked()` left NO path to
    ///      deposit at all for that window. `openProposalCount()` covers exactly
    ///      the window instant deposit is closed for, so exactly one path is
    ///      always open.
    /// @return requestId Always > 0 (the queue uses index 0 as a sentinel).
    function requestDeposit(uint256 assets, address receiver)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        address q = _withdrawalQueue;
        if (q == address(0)) revert WithdrawalQueueNotSet();
        if (IProposalStatus(_getGovernor()).openProposalCount() == 0) revert NoOpenProposal();
        if (assets == 0) revert ZeroAssets();
        _requireApprovedDepositor(receiver);
        // Tag with the currently open proposal's id (see `_openProposalPid`) —
        // NOT `_activePid()`, which is still 0 for any request placed before
        // EXECUTE.
        uint256 pid = _openProposalPid();
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
    ///         immediately before this call.
    /// @dev No `nonReentrant`: the only state-mutating call here is the mint.
    ///      `_initHighWaterMarkIfUnset` reads `pricePerShare()`, which makes only
    ///      STATICCALLs, and the sole caller — the queue's `claim` — is itself
    ///      `nonReentrant`.
    /// @dev Queue-originated deposits bypass `_deposit` entirely, so this is the
    ///      ONLY other mint entrypoint and must seed the high-water mark itself,
    ///      or a queue-only first mint would settle its first performance fee
    ///      against an unset mark. Also the re-seed path for the zero-to-nonzero
    ///      supply transition zeroed in `_update`.
    function settleDeposit(uint256 shares, address to) external {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _mint(to, shares);
        _initHighWaterMarkIfUnset();
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: stamp the realized settle price for `proposalId`
    ///         into the queue so every request tagged to it claims at one frozen
    ///         price. `num/den` carry the ERC-4626 virtual offsets so the queue
    ///         reproduces the vault's conversion rounding exactly.
    /// @dev `den` MUST divide by `_pricingSupply()`, not raw `totalSupply()` — the
    ///      same rule every other conversion here follows. `num` already excludes
    ///      assets reserved against prior stamped-but-unclaimed redeems, so
    ///      leaving their shares in a raw denominator deflates this stamp by the
    ///      exact shares-without-matching-assets gap `_pricingSupply()` closes.
    ///      SAFE FOR THIS PROPOSAL'S OWN REDEEM SHARES BY ORDERING: below,
    ///      `stampSettlement` increments the queue's counter only AFTER receiving
    ///      `num`/`den`, so the read here excludes only PRIOR stamps.
    function onProposalSettled(uint256 proposalId) external onlyGovernor {
        // Pin the settling strategy BEFORE anything can return early — this is
        // the last moment the governor still names it, and `_depositsLocked`
        // needs it to ask whether a residue is still in flight. Read from the
        // caller (the governor), which is `onlyGovernor`-authenticated, via a
        // length-checked staticcall: a governor that cannot answer leaves the
        // pin at zero, which `_depositsLocked` reads as nothing outstanding —
        // the pre-existing behaviour, not a stricter one.
        (bool okS, bytes memory retS) = msg.sender.staticcall(abi.encodeCall(IProposalStatus.strategyOf, (proposalId)));
        _lastSettledStrategy = (okS && retS.length == 32) ? abi.decode(retS, (address)) : address(0);

        address q = _withdrawalQueue;
        if (q == address(0)) return;
        // THE STAMP COUNTS UNDELIVERED VALUE; `totalAssets()` DELIBERATELY DOES
        // NOT. `totalAssets()` is the LIVE figure every conversion reads, and
        // teaching it to count strategy-held value would price the vault against
        // an unrealized, strategy-influenced NAV — the exact lever the frozen
        // settle price exists to remove (see `VaultWithdrawalQueue`'s header).
        //
        // At THIS point the position is already unwound, so what the strategy
        // still holds is realized-but-undelivered value: a receivable, not a
        // mark to market. Excluding it stamped a price below what the vault
        // actually owned, and a queued depositor claiming at that frozen number
        // minted against the shortfall — then swept it in. Freezing the price is
        // what made it unfixable after the fact: a third party sweeping first
        // did not repair the stamp, and the attacker carried no directional
        // risk, since no residue simply meant a fair-price deposit.
        //
        // Degrades to 0 on any failure, i.e. to the pre-fix stamp, never to a
        // higher one — an over-count is the only direction that could mint
        // against value that never arrives.
        // STAMPED FROM FLOAT ALONE, DELIBERATELY — the residue correction was
        // attempted here and REVERTED, because it cannot be made safe at this
        // site. `stampSettlement` derives the queue reserve as
        // `mulDiv(redeemShares, num, den)`, and `_availableFloat` is
        // `balanceOf - reserve`. Raising `num` therefore reserves assets the
        // vault does not hold: instant `maxWithdraw`/`maxRedeem` floor to zero
        // for EVERY LP, and a queued `claim` reverts outright if the residue
        // never frees.
        //
        // Capping `num` does NOT fix that. The reserve scales with
        // `redeemShares / den`, a ratio this call does not control, so no bound
        // on `num` alone keeps the reserve payable — a 90%-queued vault still
        // over-reserves by ~1.8x at the cap. The float-only stamp is
        // under-priced but ALWAYS PAYABLE, and payable is the property the
        // queue's solvency rests on.
        //
        // The queued-deposit mispricing is therefore still open. The design for
        // closing it lives in `docs/nav-residue-design.md` and issue #233 — do
        // not re-derive it here.
        //
        // NOTE the skip-stamp-plus-`restamp(pid)` shape is NOT the plan: it does
        // not survive the queue. `claim` requires `_lastStampedPid >= r.pid`, so
        // skipping strands every queued request for that pid including
        // redeemers; `stampSettlement` reverts `StampOutOfOrder` once a later
        // proposal settles, which would strand them permanently; and
        // restamping a stamped pid needs `_reservedAssets` and
        // `_stampedUnclaimedShares` unwound first. Strictly worse than the
        // mispricing.
        uint256 num = totalAssets() + 1;
        uint256 den = _pricingSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);
    }

    /// @dev Vault-asset value a settled strategy still holds. Length-checked
    ///      raw staticcall for the same reason the sibling bool probe is one:
    ///      the address is proposer-chosen, so a typed call would let it revert
    ///      settlement. Any failure — no code, revert, short return — reads as
    ///      0, which reproduces the pre-fix stamp exactly.
    function _undeliveredValueOf(address s) private view returns (uint256) {
        if (s == address(0) || s.code.length == 0) return 0;
        (bool ok, bytes memory ret) =
            s.staticcall{gas: _PROBE_GAS}(abi.encodeCall(IStrategyDelivery.undeliveredValue, ()));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @dev Gas ceiling for both strategy probes. The address is
    ///      proposer-chosen, so an uncapped staticcall lets a gas-burning
    ///      callee eat 63/64 of the forwarded gas: on `_deposit` that is a
    ///      permanent deposit DoS with no permissionless clear, and on
    ///      `onProposalSettled` the probe sits inside the settle path and can
    ///      OOG settlement itself. The degrade-to-false/0 semantics already
    ///      handle a truncated result correctly.
    ///
    ///      ACCEPTED TRADE, stated rather than implied: the Morpho probe now
    ///      routes through `_deliverableNow` -> `expectedMarketBalances` ->
    ///      `borrowRateView`, and the IRM is part of the proposer-supplied
    ///      `MarketParams`. A proposer can therefore pick an IRM whose view
    ///      burns more than this cap, degrade the probe to `false`, and
    ///      SUPPRESS the deposit lock. That is a suppression of a mitigation,
    ///      not a DoS — the recoverable direction, and the same direction the
    ///      probe already degrades in when a strategy cannot answer at all.
    ///      Raising the cap trades it back against the OOG risk above; if the
    ///      lock ever becomes load-bearing rather than defence-in-depth, this
    ///      needs a measured worst-case bound instead of a round number.
    uint256 private constant _PROBE_GAS = 150_000;

    // ==================== MANAGEMENT-FEE ACCRUAL ====================

    /// @dev Close off the elapsed interval at the base that applied during it,
    ///      then restamp the base from live fund assets. Called on every
    ///      mid-proposal event that can move the base and once more at settlement.
    ///      Proposal execute opens the accrual rather than closing an interval, so
    ///      it stamps the base directly through `startManagementAccrual`.
    ///
    ///      Restamping from `totalAssets()` rather than applying a per-event delta
    ///      is deliberate: the base is read from truth, so it stays correct for
    ///      any caller regardless of whether that caller can express its own
    ///      effect as an asset delta.
    ///
    ///      The `_mgmtLastUpdate == 0` early return is load-bearing twice: it is
    ///      the no-live-proposal-no-fee rule, and it keeps `totalAssets()` off the
    ///      ordinary deposit path entirely.
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

    /// @dev Restamp the accrual base from live fund assets, falling back to idle
    ///      float if the valuation is unavailable. A fee accrual must never be the
    ///      reason `executeProposal` or a settlement reverts, so the try/catch
    ///      degrades the BASE rather than the transaction — the fund is valued at
    ///      its raw float for that interval and the fee comes out conservative,
    ///      never inflated. Kept as the backstop should `totalAssets()` ever grow
    ///      an external dependency again. Routed through an external self-call
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

    /// @notice AT LEAST one whole share, in this vault's OWN decimals — never a
    ///         smaller, arbitrary `1e18`. Share decimals are
    ///         `2 * assetDecimals` here, so a literal `1e18` is one whole share
    ///         only at `assetDecimals == 9`; at 18 it was `1e-18` of a share, and
    ///         `convertToAssets` of that quantized to whole-integer steps of
    ///         `pps`, so `aboveHighWaterMark` read a fund up 99% as sitting AT the
    ///         mark and charged zero performance fee.
    /// @dev    `max(1e18, 10 ** decimals())`, NOT bare `10 ** decimals()`. Always
    ///         converting against exactly one share is wrong for LOW-decimal
    ///         assets: at `assetDecimals == 6`, `10 ** decimals() = 1e12`, a
    ///         SMALLER unit than `1e18`. `convertToAssets` floors, and the
    ///         absolute floor error in `pps` is bounded by <1 unit of this
    ///         constant, so a smaller unit means that same error represents more
    ///         real value once multiplied back out by `totalSupply()` — measured
    ///         at ~$1 of drift on a $200,000 fee base for a 6-decimal asset. The
    ///         `max` floors at exactly `1e18` for every `assetDecimals <= 9`, so
    ///         those vaults keep identical numerics; only `assetDecimals > 9`
    ///         switches to the larger, decimals-scaled unit.
    /// @dev    Computed, not cached: `decimals()` reads only pinned state, so this
    ///         costs one `EXP` and one comparison, not an external call.
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
    /// @notice Governor-only: advance the mark to the current post-fee price per
    ///         share.
    /// @dev Monotonic by construction — a loss leaves the mark where it was, which
    ///      is what makes the recovery free. Called at settlement only; a partial
    ///      exit must NOT ratchet, or the holders who stayed would start measuring
    ///      from a peak the fund never banked.
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
