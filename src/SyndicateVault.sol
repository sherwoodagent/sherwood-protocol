// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ITierRegistry} from "./interfaces/ITierRegistry.sol";
import {IProposalStatus} from "./interfaces/IProposalStatus.sol";
import {ICallSandbox} from "./interfaces/ICallSandbox.sol";
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
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
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
    ///         governor batches. 0 = off.
    uint16 public minBufferBps;

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

    /// @notice The `CallSandbox` implementation this vault clones per proposal.
    ///         Factory-only and SET-ONCE, exactly like `_withdrawalQueue`.
    /// @dev    The adversary is an owner who re-points the code the vault mints
    ///         AFTER guardians have approved proposals on the strength of what
    ///         that code does — the sandbox's confinement properties are what
    ///         make an unreviewed target safe to call, so they must not be
    ///         swappable behind a review. Unrepeatable rather than merely
    ///         owner-gated; replacing it is a redeployment.
    ///
    ///         Zero is legal and means the sandbox path is simply absent, which
    ///         is the posture of any deployment that does not wire one.
    address private _sandboxImplementation;

    /// @notice The sandbox minted for a proposal, if any. One per proposal,
    ///         enforced at mint, so `sandboxOf(pid)` names the one that ran.
    mapping(uint256 pid => address) private _proposalSandbox;

    /// @dev Reserved storage for future upgrades; shrinks from the front when a
    ///      variable is appended above. 29: the residue slots were deleted (no
    ///      vault proxy is live, so the lineage restarts here).
    uint256[29] private __gap;

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

    /// @notice Bind the `CallSandbox` implementation this vault clones. Factory-only,
    ///         set-once, mirroring `setWithdrawalQueue` above.
    /// @dev    NO RE-POINTING PATH, deliberately. See `_sandboxImplementation`
    ///         for the adversary: swapping the minted code behind an already
    ///         reviewed proposal would invalidate the confinement argument that
    ///         lets a sandbox call targets nobody allowlisted.
    function setSandboxImplementation(address impl) external {
        if (msg.sender != _factory) revert NotFactory();
        if (impl == address(0)) revert ZeroAddress();
        if (_sandboxImplementation != address(0)) revert SandboxImplementationAlreadySet();
        _sandboxImplementation = impl;
        emit SandboxImplementationSet(impl);
    }

    /// @inheritdoc ISyndicateVault
    function sandboxImplementation() external view returns (address) {
        return _sandboxImplementation;
    }

    /// @inheritdoc ISyndicateVault
    function sandboxOf(uint256 pid) external view returns (address) {
        return _proposalSandbox[pid];
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

    /// @dev Id of the proposal currently binding the vault: the executing one, else
    ///      the latest (open from propose). Tags every queued request.
    function _openProposalPid() private view returns (uint256) {
        address gov = _getGovernor();
        uint256 active = IProposalStatus(gov).getActiveProposal();
        return active != 0 ? active : IProposalStatus(gov).proposalCount();
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
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > maxNetOutflow) revert MaxNetOutflowExceeded(netOutflow, maxNetOutflow);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        // Idle-liquidity floor: a batch may deploy at most (1 − minBufferBps)
        // of the pre-batch float. Inflow (settle) batches pass trivially.
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();
    }

    /// @notice Governor-only: mint this proposal's sandbox, fund it with exactly
    ///         `funding`, and dispatch its stored calls.
    /// @dev    THE SECOND ASSET-MOVING PATH THAT DOES NOT PASS `_guardBatchCalls`,
    ///         and it does not need to. The batch guard exists because a batch
    ///         runs under `delegatecall`, so a sub-call reaches its target AS THIS
    ///         VAULT — able to spend our allowances, move our position tokens, and
    ///         satisfy any `msg.sender == vault` gate. A sandbox call carries the
    ///         SANDBOX's identity and can spend only the balance handed to it
    ///         here, so the callee's identity stops being load-bearing and the
    ///         most a hostile call set costs is `funding` — precisely what
    ///         full-notional tier-2 coverage already charged for.
    ///
    ///         AUTHORIZATION IS `onlyGovernor` AND NOTHING ELSE, the same posture
    ///         `settleRedeem`/`settleDeposit` take toward the queue. The adversary
    ///         is any second caller: this moves vault assets to a fresh contract
    ///         without the callee gate, so it must be reachable only through a
    ///         proposal that cleared the vote, the guardian review period and the
    ///         coverage quorum.
    ///
    ///         PUSH, NEVER APPROVE-AND-PULL. An allowance would be a standing
    ///         authorization whose size proposer calldata could choose, which is
    ///         the "authorization meters zero" failure this whole mechanism
    ///         exists to avoid, reproduced at the funding step. Nothing here ever
    ///         grants the sandbox an allowance against this vault.
    ///
    ///         ONE SANDBOX PER PROPOSAL, so `sandboxOf(pid)` names the one that
    ///         ran the reviewed payload.
    /// @return sandbox The address minted for `pid`.
    function runSandbox(
        uint256 pid,
        ICallSandbox.Call[] calldata calls,
        address[] calldata declaredTokens,
        uint256 funding
    ) external onlyGovernor nonReentrant whenNotPaused returns (address sandbox) {
        address impl = _sandboxImplementation;
        if (impl == address(0)) revert SandboxNotConfigured();
        if (_proposalSandbox[pid] != address(0)) revert SandboxAlreadyMinted(pid);

        uint256 ceiling = (totalAssets() * ISyndicateGovernor(msg.sender).tier2CallCapBps()) / 10_000;
        if (funding > ceiling) revert SandboxFundingExceedsCeiling(funding, ceiling);

        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));

        // Deterministic so the address is derivable off-chain before execution —
        // guardians reviewing a payload can compute where it will run.
        sandbox = Clones.cloneDeterministic(impl, bytes32(pid));
        _proposalSandbox[pid] = sandbox;
        ICallSandbox(sandbox).init(address(this), calls, declaredTokens);
        if (funding != 0) IERC20(asset()).safeTransfer(sandbox, funding);
        ICallSandbox(sandbox).run();

        // SAME THREE CUSTODY CHECKS `executeGovernorBatch` applies, for the same
        // reasons. `run()` can return assets (a call that swaps back into the
        // vault asset and pushes), so the delta is measured rather than assumed
        // to equal `funding`.
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        uint256 netOutflow = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (netOutflow > funding) revert MaxNetOutflowExceeded(netOutflow, funding);
        uint256 reserve = reservedQueueAssets();
        if (balanceAfter < reserve) revert QueueReserveBreached();
        if (balanceAfter < reserve + (balanceBefore * minBufferBps) / 10_000) revert BufferBreached();

        emit SandboxRun(pid, sandbox, funding);
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

    function _guardBatchCalls(BatchExecutorLib.Call[] calldata calls) private view {
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
        // typed call) so a governor without the getter resolves to "unset"
        // HERE rather than reverting in this frame with empty returndata, which
        // would be indistinguishable from a bug in the guard itself. Either way
        // the outcome is the same refusal — only the error is legible.
        (bool ok, bytes memory ret) = msg.sender.staticcall(abi.encodeCall(ISyndicateGovernor.tierRegistry, ()));
        if (!ok || ret.length != 32) revert TierRegistryUnresolved();
        address registry = abi.decode(ret, (address));
        if (registry == address(0)) revert TierRegistryUnresolved();

        address asset_ = asset();
        for (uint256 i = 0; i < calls.length; i++) {
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
                    if (to == address(this)) continue;
                    if (!ITierRegistry(registry).isAdapterAllowed(to)) {
                        revert DisallowedTransferTarget(calls[i].target, sel, to);
                    }
                    _requireRecipientVaultBinding(registry, to);
                }
                continue;
            } else {
                if (target == asset_ && !_isBenignAssetRead(sel)) {
                    revert UnrecognizedAssetSelector(sel);
                }
                continue;
            }
            // Value landing on the vault itself needs no allowlist entry: the recipient is this contract.
            if (recipient == address(this)) continue;
            if (!ITierRegistry(registry).isAdapterAllowed(recipient)) {
                revert DisallowedTransferTarget(calls[i].target, sel, recipient);
            }
            _requireRecipientVaultBinding(registry, recipient);
        }
    }

    function _requireRecipientVaultBinding(address registry, address recipient) private view {
        if (ITierRegistry(registry).classOf(recipient) == bytes32(0)) return;
        if (_readVaultOf(recipient) != address(this)) revert AdapterVaultMismatch(recipient);
    }

    function _readVaultOf(address recipient) private view returns (address) {
        (bool ok, bytes memory ret) = recipient.staticcall(abi.encodeWithSignature("vault()"));
        if (!ok || ret.length < 32) return address(0);
        uint256 word;
        assembly ("memory-safe") {
            word := mload(add(ret, 0x20))
        }
        if (word >> 160 != 0) return address(0);
        return address(uint160(word));
    }

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
    /// @dev True from Draft creation to settle: no share is minted or burned while a
    ///      proposal is open, so the veto denominator cannot move.
    ///      Fail-closed on a missing governor.
    function redemptionsLocked() public view returns (bool) {
        address gov = _getGovernor();
        if (gov == address(0)) revert GovernorNotSet();
        return IProposalStatus(gov).openProposalCount() != 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Reads through the governor: the strategy is whatever address the
    ///      proposer set on the active proposal at propose time. Returns
    ///      `address(0)` outside the active window or for queue-only proposals
    ///      (proposer passed `address(0)` to `propose`).
    function activeStrategyAdapter() external view returns (address) {
        return _activeStrategy();
    }

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
        if (from == address(0) && _pricingSupply() == 0) {
            _highWaterPricePerShare = 0;
        }

        super._update(from, to, value);

        if (_pricingSupply() == 0) {
            _highWaterPricePerShare = 0;
        }

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

    /// @inheritdoc ISyndicateVault
    /// @dev Same predicate as `redemptionsLocked`: a proposal settles only when
    ///      its strategy and sandbox hold nothing, so no receivable is ever priced.
    function depositsLocked() public view returns (bool) {
        return redemptionsLocked();
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

    // `nonReentrant` lives on the internal `_deposit`, which both `deposit` and `mint` route
    // through; the public overrides below only re-check `depositsLocked` for a named error.
    // `withdraw`/`redeem` take no guard: the asset leaves, nothing calls back in.

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

    function _escrowedFeeLiability() private view returns (uint256) {
        address gov = _getGovernor();
        if (gov == address(0)) return 0;
        (bool ok, bytes memory ret) =
            gov.staticcall(abi.encodeCall(ISyndicateGovernor.outstandingEscrow, (address(this), asset())));
        return (ok && ret.length == 32) ? abi.decode(ret, (uint256)) : 0;
    }

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

    /// @dev 0 whenever `deposit(_, receiver)` would revert: paused, deposits
    ///      locked, or `receiver` not whitelisted in closed mode (EIP-4626).
    function maxDeposit(address receiver) public view override returns (uint256) {
        if (paused() || depositsLocked()) return 0;
        if (!_openDeposits && !_approvedDepositors.contains(receiver)) return 0;
        return type(uint256).max;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return maxDeposit(receiver);
    }

    /// @dev OZ's `deposit`/`mint` compare against `maxDeposit` first; re-check
    ///      here so a refused deposit keeps its named error.
    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        _requireDepositOpen(receiver);
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override returns (uint256) {
        _requireDepositOpen(receiver);
        return super.mint(shares, receiver);
    }

    function _requireDepositOpen(address receiver) private view {
        if (depositsLocked()) revert DepositsLocked();
        _requireApprovedDepositor(receiver);
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
        if (depositsLocked()) revert DepositsLocked();
        if (shares == 0 && assets != 0) revert ZeroShares();
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
        uint256 pid = _openProposalPid();
        _transfer(owner_, q, shares);
        requestId = IVaultWithdrawalQueue(q).queueRedeem(owner_, shares, pid);
        emit RedeemRequested(requestId, owner_, shares);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Mint-deferred deposit used while a strategy proposal is active.
    ///         Escrows `assets` in the queue (off-vault, so they never inflate
    ///         `totalAssets` nor get swept into the strategy) and records a claim
    ///         that mints shares at the realized settle price.
    /// @dev Gated on `openProposalCount() != 0`, the predicate instant deposit
    ///      closes on, so exactly one deposit path is always open.
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
        address q = _withdrawalQueue;
        if (q == address(0)) return;
        uint256 num = totalAssets() + 1;
        uint256 den = _pricingSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);
    }

    // ==================== MANAGEMENT-FEE ACCRUAL ====================

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
        if (_pricingSupply() == 0) return;
        uint256 pps = pricePerShare();
        if (pps > _highWaterPricePerShare) {
            _highWaterPricePerShare = pps;
            emit HighWaterMarkUpdated(pps);
        }
    }

    function _initHighWaterMarkIfUnset() private {
        if (_highWaterPricePerShare == 0 && _pricingSupply() != 0) {
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
