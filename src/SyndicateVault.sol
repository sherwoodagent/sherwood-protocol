// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {IVaultWithdrawalQueue} from "./interfaces/IVaultWithdrawalQueue.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {BatchExecutorLib} from "./BatchExecutorLib.sol";
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
    ///         V-M3: prevents unbounded iteration from out-of-gassing a page
    ///         fetch even when the underlying set is large.
    uint256 public constant MAX_PAGE_LIMIT = 100;

    // ==================== STORAGE ====================

    /// @notice Agent address => agent config
    mapping(address => AgentConfig) private _agents;

    /// @notice Set of all registered agent addresses
    EnumerableSet.AddressSet private _agentSet;

    // ── New storage (appended after existing slots) ──

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

    /// @notice Per-proposal sum of asset principal forwarded to the live
    ///         adapter during the proposal's Executed window. Subtracted from
    ///         PnL at `_finishSettlement` so live-deposit principal is not
    ///         counted as strategy profit.
    mapping(uint256 proposalId => uint256) public liveAdapterPrincipal;

    /// @notice Per-proposal sum of asset principal pulled back from the live
    ///         adapter to fund LP withdrawals during the proposal's Executed
    ///         window. Added to the PnL snapshot at `_finishSettlement` so a
    ///         mid-flight LP exit doesn't masquerade as a strategy loss.
    mapping(uint256 proposalId => uint256) public liveAdapterWithdrawn;

    /// @dev Reserved storage for future upgrades.
    uint256[35] private __gap;

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
        _factory = msg.sender;
        _cachedDecimalsOffset = IERC20Metadata(p.asset).decimals();
    }

    // ==================== DEPOSITOR WHITELIST ====================

    /// @inheritdoc ISyndicateVault
    function approveDepositor(address depositor) external onlyOwner {
        if (depositor == address(0)) revert InvalidDepositor();
        if (!_approvedDepositors.add(depositor)) revert DepositorAlreadyApproved();
        emit DepositorApproved(depositor);
    }

    /// @inheritdoc ISyndicateVault
    function removeDepositor(address depositor) external onlyOwner {
        if (!_approvedDepositors.remove(depositor)) revert DepositorNotApproved();
        emit DepositorRemoved(depositor);
    }

    /// @inheritdoc ISyndicateVault
    function approveDepositors(address[] calldata depositors) external onlyOwner {
        for (uint256 i = 0; i < depositors.length; i++) {
            if (depositors[i] == address(0)) revert InvalidDepositor();
            _approvedDepositors.add(depositors[i]);
            emit DepositorApproved(depositors[i]);
        }
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Whether `depositor` is allowed to receive shares when the vault
    ///         is in closed-deposit mode (`_openDeposits == false`).
    /// @dev V-M4: the whitelist check in `_deposit` runs against `receiver` —
    ///      the share holder — **not** `caller` (the asset payer). A whitelisted
    ///      user can therefore receive shares funded by a non-whitelisted party
    ///      (pay-on-behalf semantics), which is intentional for KYC flows where
    ///      compliance attaches to the share holder (residency / accreditation
    ///      attestations travel with the shares, not the USDC).
    ///
    ///      If a deployment needs **both** sides checked, extend `_deposit` to
    ///      assert `isApprovedDepositor(caller)` in addition to the existing
    ///      `isApprovedDepositor(receiver)` check. This is deliberately not the
    ///      default because doing so would break subsidised onboarding flows.
    function isApprovedDepositor(address depositor) external view returns (bool) {
        return _approvedDepositors.contains(depositor);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev V-M3: paginated slice of the approved-depositor set. Full-list
    ///      and count getters were dropped to free EIP-170 budget for the
    ///      NAV-floor guard in `_lpFlowGate`. Iterate via this paginated
    ///      path; `limit` is hard-clamped to `MAX_PAGE_LIMIT`.
    function approvedDepositorsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _pageAddresses(_approvedDepositors, offset, limit);
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
    function getAgentConfig(address agentAddress) external view returns (AgentConfig memory) {
        return _agents[agentAddress];
    }

    /// @inheritdoc ISyndicateVault
    function getAgentCount() external view returns (uint256) {
        return _agentSet.length();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev V-M3: paginated slice of the registered-agent set. `limit` is
    ///      hard-clamped to `MAX_PAGE_LIMIT` so the call always fits in a
    ///      block regardless of how many agents are registered. Callers
    ///      iterate: start at `offset = 0`, advance by `limit` each call
    ///      until the returned array is shorter than `limit`.
    function agentsPaginated(uint256 offset, uint256 limit) external view returns (address[] memory) {
        return _pageAddresses(_agentSet, offset, limit);
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
    /// @dev V-M6: ERC-8004 NFT ownership is verified **at registration time
    ///      only**. If the `agentId` NFT is subsequently transferred to a
    ///      different wallet, the registered `agentAddress` retains its
    ///      privileges on this vault until the owner explicitly calls
    ///      `removeAgent`. This is an intentional trade-off: re-querying NFT
    ///      ownership on every execution would add a per-call external view to
    ///      the hot path, and the ERC-8004 registry is an external dependency
    ///      whose operational posture (upgrade cadence, pause semantics) the
    ///      vault should not hard-couple to. Off-chain reputation / guardian
    ///      systems should monitor NFT transfers and trigger `removeAgent` via
    ///      the owner when an identity moves. See CLAUDE.md "Agent Identity
    ///      (ERC-8004)" for the full model.
    function registerAgent(uint256 agentId, address agentAddress) external onlyOwner {
        if (agentAddress == address(0)) revert ZeroAddress();
        if (_agents[agentAddress].active) revert AgentAlreadyRegistered();

        // Verify ERC-8004 identity (skipped on chains without agent registry)
        if (address(_agentRegistry) != address(0)) {
            address nftOwner = _agentRegistry.ownerOf(agentId);
            if (nftOwner != agentAddress && nftOwner != owner()) revert NotAgentOwner();
        }

        _agents[agentAddress] = AgentConfig({agentId: agentId, agentAddress: agentAddress, active: true});

        _agentSet.add(agentAddress);

        emit AgentRegistered(agentId, agentAddress);
    }

    /// @inheritdoc ISyndicateVault
    /// @dev V-M5: fully delete the `_agents[agentAddress]` struct (not just
    ///      flip `active = false`). This prevents stale `agentId` /
    ///      `agentAddress` fields from being silently reused if `registerAgent`
    ///      is later called for the same slot. After `removeAgent`,
    ///      `getAgentConfig(addr)` returns the zero struct, and a subsequent
    ///      `registerAgent(newId, addr)` writes a fresh entry.
    function removeAgent(address agentAddress) external onlyOwner {
        if (!_agents[agentAddress].active) revert AgentNotActive();

        delete _agents[agentAddress];
        _agentSet.remove(agentAddress);

        emit AgentRemoved(agentAddress);
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
    function rotateOwnership(address newOwner) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newOwner == address(0)) revert ZeroAddress();
        _transferOwnership(newOwner);
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
        return ISyndicateFactory(_factory).governor();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev V-C2: every delegatecall re-verifies that `_executorImpl`'s bytecode
    ///      still matches the hash stamped at init. A factory misconfig or a
    ///      swapped executor address cannot deflect the delegatecall to a
    ///      different library.
    /// @dev I-11: gated by `whenNotPaused`. When the owner pauses the vault,
    ///      strategy execution is halted alongside LP flow.
    function executeGovernorBatch(BatchExecutorLib.Call[] calldata calls)
        external
        onlyGovernor
        nonReentrant
        whenNotPaused
    {
        if (_executorImpl.codehash != _expectedExecutorCodehash) revert ExecutorCodehashMismatch();
        (bool success, bytes memory returnData) =
            _executorImpl.delegatecall(abi.encodeCall(BatchExecutorLib.executeBatch, (calls)));
        if (!success) {
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        // V-M9: first-class vault-level execution marker. Emitted after the
        // delegatecall succeeds so indexers only see confirmed executions.
        emit GovernorBatchExecuted(msg.sender, calls.length);
    }

    /// @inheritdoc ISyndicateVault
    function transferPerformanceFee(address asset_, address to, uint256 amount) external onlyGovernor {
        if (asset_ != asset()) revert InvalidAsset();
        if (to == address(0)) revert ZeroAddress();
        if (amount > IERC20(asset_).balanceOf(address(this))) revert AmountExceedsBalance();
        IERC20(asset_).safeTransfer(to, amount);
    }

    /// @inheritdoc ISyndicateVault
    function governor() external view returns (address) {
        return _getGovernor();
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Fail-closed on missing governor: if the factory is misconfigured
    ///      and `governor() == address(0)`, deposits / withdrawals / rescues
    ///      must NOT silently unlock. Revert instead.
    function redemptionsLocked() public view returns (bool) {
        address gov = _getGovernor();
        if (gov == address(0)) revert GovernorNotSet();
        return ISyndicateGovernor(gov).getActiveProposal(address(this)) != 0;
    }

    /// @inheritdoc ISyndicateVault
    /// @dev Reads through the governor: the strategy is whatever address the
    ///      proposer set on the active proposal at propose time. Returns
    ///      `address(0)` outside the active window or for queue-only proposals
    ///      (proposer passed `address(0)` to `propose`).
    function activeStrategyAdapter() external view returns (address) {
        return _activeStrategy();
    }

    /// @dev Reads the active proposal's `strategy` field through the governor.
    ///      Returns `address(0)` when no proposal is active OR when the active
    ///      proposal opted out of live NAV (proposer passed `strategy=0`).
    ///      Wrapped in try/catch for `getProposal` because struct-shape drift
    ///      across pre-V1.5 governors must not brick LP flow.
    function _activeStrategy() internal view returns (address) {
        address gov = _getGovernor();
        if (gov == address(0)) return address(0);
        uint256 pid = ISyndicateGovernor(gov).getActiveProposal(address(this));
        if (pid == 0) return address(0);
        try ISyndicateGovernor(gov).getProposal(pid) returns (ISyndicateGovernor.StrategyProposal memory p) {
            return p.strategy;
        } catch {
            return address(0);
        }
    }

    /// @inheritdoc ISyndicateVault
    function managementFeeBps() external view returns (uint256) {
        return _managementFeeBps;
    }

    // ==================== PAGINATION ====================

    /// @dev V-M3: shared pager for `EnumerableSet.AddressSet`. Returns a
    ///      slice `[offset, offset + min(limit, MAX_PAGE_LIMIT))` clipped to
    ///      the set's length. Returns an empty array when `offset >= length`.
    function _pageAddresses(EnumerableSet.AddressSet storage set, uint256 offset, uint256 limit)
        private
        view
        returns (address[] memory out)
    {
        uint256 total = set.length();
        if (offset >= total) return new address[](0);
        if (limit > MAX_PAGE_LIMIT) limit = MAX_PAGE_LIMIT;
        uint256 end = offset + limit;
        if (end > total) end = total;
        out = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            out[i - offset] = set.at(i);
        }
    }

    // ==================== OVERRIDES ====================

    /// @dev Resolve diamond between ERC20Upgradeable and ERC20VotesUpgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
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
    /// @dev V-M1: cached at init — no external `asset().decimals()` call on the hot
    ///      share-conversion path. Asset decimals are immutable in practice for the
    ///      underlying USDC/ERC-20, so pinning once at init is safe.
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return _cachedDecimalsOffset;
    }

    /// @dev Combined LP-flow gate. Returns:
    ///        - `blocked = true` when LP flow must revert (active proposal AND
    ///          no valid live-NAV adapter).
    ///        - `liveAdapter` set to the adapter address whenever LP flow is
    ///          unlocked *because* a live-NAV adapter is reporting valid NAV.
    ///          The `_deposit` path uses this to forward the new capital into
    ///          the adapter so it starts earning yield immediately. Outside
    ///          the active window or when the adapter is invalid this is
    ///          `address(0)` so the caller skips the forward.
    /// @dev I-3: a reverting `positionValue()` (e.g. EOA bound, buggy adapter)
    ///      is treated as `blocked=true` so a malicious/broken adapter can't
    ///      brick LP flow with an unhandled revert. Pairs with the `totalAssets`
    ///      try/catch fallback below.
    function _lpFlowGate() private view returns (bool blocked, address liveAdapter, uint256 adapterValue) {
        if (!redemptionsLocked()) return (false, address(0), 0);
        address adapter = _activeStrategy();
        if (adapter == address(0)) return (true, address(0), 0);
        try IStrategy(adapter).positionValue() returns (uint256 v, bool valid) {
            if (!valid) return (true, address(0), 0);
            // NAV-floor guard: suspend live NAV when reported value falls below
            // `principal / 2` (50% floor, hardcoded as `>> 1`). Defeats the
            // share-inflation attack where an under-reporting strategy
            // (positionValue ≈ 0 with non-zero supply) lets a new depositor
            // mint cheap shares against the deflated NAV.
            //
            // I-3: the snapshot read uses a low-level staticcall + assembly
            // decode so a governor without `getCapitalSnapshot` (e.g. UUPS
            // upgrade misconfig) can't brick LP flow with an unhandled revert.
            // Fail-closed: a missing / malformed return blocks the live path
            // (queue still works). Fail-open here would silently zero the
            // floor and re-enable the share-inflation attack.
            // Assembly is used over high-level `(bool ok, bytes memory ret)`
            // tuple to fit under the EIP-170 cap.
            address gov_ = _getGovernor();
            uint256 pid = ISyndicateGovernor(gov_).getActiveProposal(address(this));
            bytes memory cd = abi.encodeCall(ISyndicateGovernor.getCapitalSnapshot, (pid));
            uint256 snapshot;
            bool snapOk;
            assembly {
                snapOk := and(staticcall(gas(), gov_, add(cd, 0x20), mload(cd), 0, 0x20), eq(returndatasize(), 0x20))
                if snapOk { snapshot := mload(0) }
            }
            if (!snapOk) return (true, address(0), 0);
            if (v < (snapshot + liveAdapterPrincipal[pid]) >> 1) return (true, address(0), 0);
            return (false, adapter, v);
        } catch {}
        return (true, address(0), 0);
    }

    /// @dev True while any non-terminal proposal binds the vault
    ///      (Pending..Executed). Used by `_deposit` to close the late-deposit
    ///      window where a depositor mid-vote would be silently pulled into a
    ///      strategy by `executeProposal`. Off-chain readers can call
    ///      `governor.openProposalCount(vault)` directly.
    function _depositsLocked() private view returns (bool) {
        return ISyndicateGovernor(_getGovernor()).openProposalCount(address(this)) != 0;
    }

    // ── I-1: nonReentrant guards on the public 4626 entry-points ──
    //
    // `_deposit` forwards capital into the active adapter via `safeTransfer`
    // followed by `IStrategy.onLiveDeposit`. A malicious adapter could re-enter
    // `vault.deposit` between the transfer and the adapter accounting the
    // assets — at that recursive moment `positionValue()` undercounts the
    // in-flight assets, letting the recursive deposit mint shares against a
    // deflated NAV. `nonReentrant` on the public deposit/mint paths closes the
    // window. `withdraw`/`redeem` get the same modifier for symmetry: the
    // queue-side `claim` already takes its own lock and `requestRedeem` is
    // already guarded, so a no-cost defence-in-depth here is cheap once
    // `ReentrancyGuardTransient` is wired in.

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    /// @inheritdoc ERC4626Upgradeable
    /// @dev Aggregates the vault's idle float with the active strategy
    ///      adapter's `positionValue()` when the adapter reports `valid=true`
    ///      AND clears the NAV floor. Delegates to `_lpFlowGate` so the
    ///      preview surface (`previewDeposit`/`previewWithdraw`) and the
    ///      on-chain entry/exit gate agree byte-for-byte: any case that
    ///      blocks LP flow (unbound adapter, invalid value, sub-floor NAV,
    ///      governor staticcall failure, reverting `positionValue`) falls
    ///      back to float-only here, so the quoted NAV is exactly what
    ///      a deposit/withdraw would mint/burn against.
    function totalAssets() public view override returns (uint256) {
        uint256 float = IERC20(asset()).balanceOf(address(this));
        (, address liveAdapter, uint256 adapterValue) = _lpFlowGate();
        return liveAdapter == address(0) ? float : float + adapterValue;
    }

    /// @dev Block deposits when paused or depositor not approved.
    ///      Auto-delegate to self on first deposit so shareholders get voting power.
    ///      When a live-NAV adapter is bound, forward the new capital so it
    ///      starts earning yield immediately instead of sitting as idle float.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        // Close the late-deposit window: a depositor during Pending /
        // GuardianReview / Approved would otherwise be silently pulled into a
        // strategy they never voted on by the next `executeProposal`. The
        // `liveAdapter == 0` precondition preserves the live-NAV unlock
        // during Executed when the adapter accepts inbound deposits.
        (bool blocked, address liveAdapter,) = _lpFlowGate();
        if (liveAdapter == address(0) && (blocked || _depositsLocked())) revert DepositsLocked();
        if (!_openDeposits && !_approvedDepositors.contains(receiver)) revert NotApprovedDepositor();
        super._deposit(caller, receiver, assets, shares);

        // Auto-delegate: if receiver has no delegate, delegate to self
        if (delegates(receiver) == address(0)) {
            _delegate(receiver, receiver);
        }

        // Forward live deposits to the adapter so capital starts earning
        // immediately. `_lpFlowGate` already validated `valid=true` when it
        // returned a non-zero adapter, so no extra positionValue check is
        // needed here. Push model: transfer the assets to the adapter then
        // call the hook — avoids needing an approve + transferFrom.
        // try/catch around `onLiveDeposit`: a transient revert (paused
        // upstream pool, max-deposit cap, momentary oracle staleness, or a
        // bespoke adapter that didn't implement the hook) must not brick
        // every LP deposit until settle. The assets were already pushed to
        // the adapter; track them under principal so they're returned at
        // settle and not counted as profit. Symmetric with the runtime
        // try/catches on `positionValue` (totalAssets / _lpFlowGate) and
        // `onLiveWithdraw` (_withdraw partial-unwind path).
        if (liveAdapter != address(0)) {
            IERC20(asset()).safeTransfer(liveAdapter, assets);
            uint256 pid = ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
            try IStrategy(liveAdapter).onLiveDeposit(assets) {
            // Hook accepted — capital is now earning yield.
            }
            catch {
                // Hook unavailable / reverted — capital sits idle on the
                // adapter, recoverable at settle via `liveAdapterPrincipal`.
                emit LiveDepositForwardFailed(pid, liveAdapter, assets);
            }
            liveAdapterPrincipal[pid] += assets;
        }
    }

    /// @dev `maxWithdraw` / `maxRedeem` are the canonical lock gate (OZ
    ///      ERC4626 invokes them before `_withdraw`). The redundant
    ///      `redemptionsLocked()` check here was dropped to fit live-NAV
    ///      logic under the bytecode budget.
    /// @dev Live-NAV partial-unwind: when float is short and a live adapter
    ///      is bound + reporting valid NAV, the vault asks the adapter to
    ///      free `deficit` of underlying via `onLiveWithdraw`. The
    ///      authoritative measure is the balance delta — strategies cannot
    ///      lie about how much they returned. All-or-nothing: anything less
    ///      than `deficit` reverts and the LP must use the async-redeem
    ///      queue. The pulled amount is recorded per-proposal so the
    ///      governor's settlement PnL formula can credit it back into the
    ///      snapshot (see `liveAdapterWithdrawn` natspec).
    function _withdraw(address caller, address receiver, address _owner, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        // Queue bypasses the reserve check — it owns the reserved float.
        if (caller != _withdrawalQueue) {
            uint256 reserve = reservedQueueAssets();
            uint256 float = IERC20(asset()).balanceOf(address(this));
            if (assets + reserve > float) {
                if (!_pullFromLiveAdapter(assets + reserve - float)) revert QueueReserveBreached();
            }
        }
        super._withdraw(caller, receiver, _owner, assets, shares);
    }

    /// @dev Best-effort pull from the bound live-NAV adapter. Returns true
    ///      iff exactly `needed` (or more) of asset arrived. Records the
    ///      delta against the active proposal so settlement PnL stays
    ///      neutral on LP flow. Falls back to false on: not locked, no
    ///      adapter, adapter reverting, partial fill.
    function _pullFromLiveAdapter(uint256 needed) private returns (bool) {
        (bool blocked, address adapter,) = _lpFlowGate();
        if (blocked || adapter == address(0)) return false;
        uint256 before = IERC20(asset()).balanceOf(address(this));
        try IStrategy(adapter).onLiveWithdraw(needed) returns (uint256) {}
        catch {
            return false;
        }
        uint256 received = IERC20(asset()).balanceOf(address(this)) - before;
        if (received < needed) return false;
        uint256 pid = ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
        liveAdapterWithdrawn[pid] += received;
        return true;
    }

    /// @dev Cap visible to integrators so they don't propose withdrawals that
    ///      would breach the queue's reservation. Returns 0 while
    ///      `redemptionsLocked()` is true (regular withdraw is closed).
    ///      The bound withdrawal queue bypasses the reserve cap because the
    ///      reserved float belongs to it — capping the queue would block
    ///      `claim()` whenever pending shares dominate supply.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        (bool blocked, address adapter, uint256 adapterValue) = _lpFlowGate();
        if (paused() || blocked) return 0;
        if (owner_ == _withdrawalQueue) return super.maxWithdraw(owner_);
        uint256 userMax = super.maxWithdraw(owner_);
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 available = float > reserve ? float - reserve : 0;
        // Live-NAV branch: cap also includes the adapter's reported position
        // value (already fetched by `_lpFlowGate` via the same staticcall —
        // reuse it instead of issuing a second positionValue call).
        if (adapter != address(0)) available += adapterValue;
        return userMax > available ? available : userMax;
    }

    /// @dev Cap visible to integrators so they don't propose redeems that would
    ///      breach the queue's reservation. Returns 0 while
    ///      `redemptionsLocked()` is true (regular redeem is closed).
    ///      The bound withdrawal queue bypasses the reserve cap (see
    ///      `maxWithdraw`).
    /// @dev IMP-2: caps by both the queue-share reserve AND available float.
    ///      During live-NAV the vault forwards new deposits into the adapter
    ///      so float can be near-zero while `totalSupply()` is large. Without
    ///      the float cap, `redeem(maxRedeem(user), ...)` would revert with
    ///      `QueueReserveBreached` inside `_withdraw` — an EIP-4626 conformance
    ///      bug. The float-share conversion uses `convertToShares(float - reserve)`
    ///      so the returned share count corresponds to assets actually backable
    ///      by float at the current NAV.
    function maxRedeem(address owner_) public view override returns (uint256) {
        (bool blocked, address adapter, uint256 adapterValue) = _lpFlowGate();
        if (paused() || blocked) return 0;
        if (owner_ == _withdrawalQueue) return super.maxRedeem(owner_);
        uint256 userMax = super.maxRedeem(owner_);
        uint256 reserveShares = pendingQueueShares();
        uint256 ts = totalSupply();
        if (ts == 0 || reserveShares >= ts) return 0;
        uint256 availableShares = ts - reserveShares;
        // EIP-4626 conformance: redeem(maxRedeem(user), ...) must succeed
        // even when float has been forwarded to the live-NAV adapter. Cap
        // by float plus the adapter's already-fetched positionValue (reused
        // from `_lpFlowGate` — no second staticcall).
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 backingAssets = float > reserve ? float - reserve : 0;
        if (adapter != address(0)) backingAssets += adapterValue;
        if (backingAssets == 0) return 0;
        uint256 floatShares = convertToShares(backingAssets);
        if (floatShares < availableShares) availableShares = floatShares;
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
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }
        // Move shares into queue custody. Voting weight at the queue address is 0
        // (queue contract has no delegate). For proposals already open at request
        // time, the voter's checkpoint at `snapshotTimestamp` is frozen with the
        // pre-transfer weight, so vote power is preserved for in-flight proposals.
        // Queued shares forfeit voting power for any proposal opened after escrow.
        // Shares are burned later by `claim`.
        _transfer(owner_, q, shares);
        requestId = IVaultWithdrawalQueue(q).queueRequest(owner_, shares);
        emit RedeemRequested(requestId, owner_, shares);
    }

    /// @inheritdoc ISyndicateVault
    function pendingQueueShares() public view returns (uint256) {
        address q = _withdrawalQueue;
        if (q == address(0)) return 0;
        return IVaultWithdrawalQueue(q).pendingShares();
    }

    /// @inheritdoc ISyndicateVault
    function reservedQueueAssets() public view returns (uint256) {
        return convertToAssets(pendingQueueShares());
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

    /// @dev V-H6: No `receive()` / `fallback()`. The vault's ERC-4626 asset
    ///      is USDC; raw ETH has no accounting slot and would strand forever.
    ///      Any legitimate mid-batch native ETH (e.g. Moonwell mWETH redeem)
    ///      is caught by the strategy's own `receive()` at its own address
    ///      and wrapped to WETH before being pushed back via `safeTransfer`.
}
