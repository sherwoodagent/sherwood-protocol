// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {ISyndicateFactory} from "./interfaces/ISyndicateFactory.sol";
import {IVaultWithdrawalQueue} from "./interfaces/IVaultWithdrawalQueue.sol";
import {IPriceRouter} from "./interfaces/IPriceRouter.sol";
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
    /// @notice PR #324 review R4: hard cap on agents per vault so the
    ///         `rotateOwnership` deactivation loop (Sherlock #38) has a
    ///         predictable upper bound and cannot OOG. 32 SSTOREs ~= 6.4k gas —
    ///         fits comfortably in any block. `removeAgent` frees a slot.
    uint256 public constant MAX_AGENTS_PER_VAULT = 32;

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

    /// @notice Lane A (instant) per-holder lockup: the proposal id whose Lane A
    ///         entry locked this holder's shares. The holder cannot exit (Lane A
    ///         redeem or Lane B requestRedeem) while that proposal is still the
    ///         active one — closes the deposit-low / exit-high intra-proposal MEV
    ///         (G1). Cleared implicitly when the proposal settles (active != pid).
    mapping(address holder => uint256 pid) private _laneALockPid;

    /// @dev Reserved storage for future upgrades.
    uint256[36] private __gap;

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
    /// @dev V-M3: paginated slice of the approved-depositor set. Full-list and
    ///      count getters were dropped to free EIP-170 budget. Iterate via this
    ///      paginated path; `limit` is hard-clamped to `MAX_PAGE_LIMIT`.
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

    // `getAgentConfig` dropped to fit MAX_AGENTS_PER_VAULT under EIP-170
    // (PR #324). Use `isAgent(addr)` for the auth check.

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
        // PR #324 review R4: bound `_agentSet` so `rotateOwnership`'s
        // deactivation loop (Sherlock #38) can't OOG. `removeAgent` frees a slot.
        if (_agentSet.length() >= MAX_AGENTS_PER_VAULT) revert AgentCapExceeded();

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
    ///      `isAgent(addr)` returns false, and a subsequent
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
    /// @dev Sherlock #38 v2 (PR #324 review): drain `_agentSet` entirely (full
    ///      `delete`, not flip-only) so an at-cap vault doesn't brick the new
    ///      owner — 32 dead entries could otherwise be neither re-registered
    ///      (R4 cap blocks) nor purged (`AgentNotActive` blocks `removeAgent`).
    ///      Snapshot via `.values()` first so the in-loop `remove` doesn't
    ///      invalidate iteration (OZ swap-and-pop on `at(i)`).
    function rotateOwnership(address newOwner) external {
        if (msg.sender != _factory) revert NotFactory();
        if (newOwner == address(0)) revert ZeroAddress();
        address[] memory snap = _agentSet.values();
        uint256 n = snap.length;
        for (uint256 i; i < n; ++i) {
            address a = snap[i];
            delete _agents[a];
            _agentSet.remove(a);
            emit AgentRemoved(a);
        }
        _transferOwnership(newOwner);
    }

    /// @notice Sherlock run #2 #3: block direct OwnableUpgradeable owner
    ///         rotation. The factory's `rotateOwner` is the only legal route —
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

        // Honor pending redemptions first: a strategy execution may not deploy
        // float reserved for already-settled, unclaimed redeem claims, so a
        // later proposal cannot strand them. Settle batches return float and
        // pass trivially; an execute batch that over-deploys reverts here.
        if (IERC20(asset()).balanceOf(address(this)) < reservedQueueAssets()) revert QueueReserveBreached();
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

    /// @dev Resolve diamond between ERC20Upgradeable and ERC20VotesUpgradeable.
    ///      G1: a Lane-A-locked holder cannot move shares out until the proposal
    ///      settles. Without this the per-holder lock is trivially bypassed by
    ///      transferring to a fresh (unlocked) address that then instant-redeems
    ///      at the higher mid-proposal NAV (spec #357 invariant 5). Mint
    ///      (`from == 0`) and burn (`to == 0`) are unaffected — burns are gated by
    ///      `maxRedeem` / `requestRedeem`. `_isLaneALocked` short-circuits on
    ///      `_laneALockPid[from] == 0`, so non-Lane-A holders pay only an SLOAD.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20VotesUpgradeable)
    {
        if (from != address(0) && to != address(0) && _isLaneALocked(from)) revert SharesLocked();
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

    /// @dev True while any non-terminal proposal binds the vault
    ///      (Pending..Executed). Used by `_deposit` to close the late-deposit
    ///      window where a depositor mid-vote would be silently pulled into a
    ///      strategy by `executeProposal`. Off-chain readers can call
    ///      `governor.openProposalCount(vault)` directly.
    function _depositsLocked() private view returns (bool) {
        return ISyndicateGovernor(_getGovernor()).openProposalCount(address(this)) != 0;
    }

    /// @dev Protocol PriceRouter (Lane A live-NAV), read live from the factory.
    ///      `address(0)` (unset) ⇒ Lane A off — the vault shows float-only NAV
    ///      and routes mid-proposal flow to the async (Lane B) queue.
    function _getPriceRouter() internal view returns (address) {
        return ISyndicateFactory(_factory).priceRouter();
    }

    /// @dev Lane A live valuation of the active strategy's positions, priced
    ///      vault-side by the PriceRouter (never the strategy's self-report).
    ///      Returns `(value, true)` only while locked AND the router proves every
    ///      position instant-eligible (kind enabled, fresh, within cap); every
    ///      other case is `(0, false)` (fail-closed) so the vault falls back to
    ///      float-only NAV + the async queue.
    function _liveNAV() private view returns (uint256 value, bool available) {
        if (!redemptionsLocked()) return (0, false);
        address pr = _getPriceRouter();
        if (pr == address(0)) return (0, false);
        address strat = _activeStrategy();
        if (strat == address(0)) return (0, false);
        try IPriceRouter(pr).valueStrategy(strat) returns (uint256 v, bool ok) {
            return ok ? (v, true) : (0, false);
        } catch {
            return (0, false);
        }
    }

    /// @dev True while `holder`'s shares are Lane-A-locked — a Lane A entry made
    ///      during the currently-active proposal. The lock lifts implicitly when
    ///      that proposal settles (the active proposal id changes / clears), so
    ///      no timestamp bookkeeping is needed. Bounds the deposit-low / exit-high
    ///      intra-proposal arb (G1) for both Lane A redeem and Lane B requestRedeem.
    function _isLaneALocked(address holder) private view returns (bool) {
        uint256 p = _laneALockPid[holder];
        return p != 0 && p == ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
    }

    /// @dev Shared instant-exit gate for `maxWithdraw` / `maxRedeem`: an exit
    ///      must route through the Lane B queue when the vault is locked without
    ///      a Lane A live-NAV term, or while the holder is under the G1 lockup.
    function _laneBOnly(address owner_) private view returns (bool) {
        (, bool laneA) = _liveNAV();
        return (redemptionsLocked() && !laneA) || _isLaneALocked(owner_);
    }

    // ── I-1: nonReentrant guard on the deposit / mint path ──
    //
    // The guard lives on the internal `_deposit` (both `deposit` and `mint`
    // route through it), so the public entry-points keep OZ's inherited bodies
    // and we don't pay for two wrapper overrides (EIP-170 headroom). Defence-in-
    // depth against cross-function reentrancy on the share-price path: a
    // reentrant deposit during another mint could mint against a transiently-
    // deflated NAV. The queue-side `claim` / `settleRedeem` take their own locks
    // and `requestRedeem` is already guarded.
    //
    // Sherlock run #3 #9 (off-report): the `withdraw` / `redeem` paths take no
    // nonReentrant — they were "for symmetry" only, never load-bearing.
    // Withdraw transfers the vault asset OUT to the receiver (no asset in flight
    // that could deflate NAV from the caller's view), the V2 design has no
    // live-withdraw adapter callback, and any reentry into deposit / mint is
    // still blocked by `_deposit`'s nonReentrant latch.

    /// @inheritdoc ERC4626Upgradeable
    /// @dev V2 live-NAV redesign: the vault never trusts a strategy's
    ///      self-reported value. NAV is the idle float PLUS, only when Lane A is
    ///      available, the active strategy's positions priced vault-side by the
    ///      PriceRouter (`_liveNAV`). When Lane A is unavailable the live term is
    ///      0, so during a proposal the vault shows float-only and mid-flight LP
    ///      flow goes through the async queue, settling at the realized price.
    function totalAssets() public view override returns (uint256) {
        (uint256 live,) = _liveNAV();
        return IERC20(asset()).balanceOf(address(this)) + live;
    }

    /// @dev Sherlock run #2 #12: return 0 when `paused()` so the EIP-4626 IMP-1
    ///      invariant holds (`deposit(maxDeposit(x), x)` MUST NOT revert when the
    ///      action is disabled). Active-proposal / whitelist cases stay reported
    ///      as `type(uint256).max` here (adding those checks busts EIP-170 and
    ///      under-reports valid Lane A deposit flows); frontends poll
    ///      `governor.getActiveProposal(vault)` + `isApprovedDepositor` directly.
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
        (, bool laneA) = _liveNAV();
        // During an open proposal (Pending..Executed) instant deposits are
        // closed unless Lane A is live — a depositor mid-lifecycle would
        // otherwise be pulled into a strategy they never voted on, or mint
        // against an unrealized NAV.
        if (_depositsLocked() && !laneA) revert DepositsLocked();
        if (!_openDeposits && !_approvedDepositors.contains(receiver)) revert NotApprovedDepositor();
        super._deposit(caller, receiver, assets, shares);

        // Auto-delegate: if receiver has no delegate, delegate to self
        if (delegates(receiver) == address(0)) {
            _delegate(receiver, receiver);
        }

        // G1: a Lane A entry locks the receiver's shares until this proposal
        // settles — closes the deposit-low / exit-high intra-proposal MEV.
        if (laneA) {
            _laneALockPid[receiver] = ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
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
    {
        if (caller != _withdrawalQueue) {
            uint256 reserve = reservedQueueAssets();
            uint256 float = IERC20(asset()).balanceOf(address(this));
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
        if (_laneBOnly(owner_)) return 0;
        uint256 userMax = super.maxWithdraw(owner_);
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 available = float > reserve ? float - reserve : 0;
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
        uint256 reserve = reservedQueueAssets();
        uint256 float = IERC20(asset()).balanceOf(address(this));
        uint256 backingAssets = float > reserve ? float - reserve : 0;
        // Sherlock run #3 #9 (off-report): no `backingAssets == 0` early return —
        // skip the floatShares cap entirely when the user's full balance fits
        // within `backingAssets` (covers the dust case where
        // `convertToAssets(userMax) == 0`, which pre-fix stranded tiny redeems
        // once float dropped to the queue reserve). `_withdraw`'s reserve check
        // still gates real asset draws.
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
        // G1: shares entered via Lane A this proposal are locked until it settles
        // (blocks the Lane A entry → Lane B exit bypass within one proposal).
        if (_isLaneALocked(owner_)) revert SharesLocked();
        if (msg.sender != owner_) {
            _spendAllowance(owner_, msg.sender, shares);
        }
        // Move shares into queue custody. Voting weight at the queue address is 0
        // (queue contract has no delegate). For proposals already open at request
        // time, the voter's checkpoint at `snapshotTimestamp` is frozen with the
        // pre-transfer weight, so vote power is preserved for in-flight proposals.
        // Queued shares forfeit voting power for any proposal opened after escrow.
        // Shares are burned later by `claim`.
        uint256 pid = ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
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
        if (!_openDeposits && !_approvedDepositors.contains(receiver)) revert NotApprovedDepositor();
        uint256 pid = ISyndicateGovernor(_getGovernor()).getActiveProposal(address(this));
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
    function settleDeposit(uint256 shares, address to) external {
        if (msg.sender != _withdrawalQueue) revert NotQueue();
        _mint(to, shares);
        if (delegates(to) == address(0)) _delegate(to, to);
    }

    /// @inheritdoc ISyndicateVault
    /// @notice Governor-only: stamp the realized settle price for `proposalId`
    ///         into the queue so every request tagged to it claims at one frozen
    ///         price. `num/den` carry the ERC-4626 virtual offsets so the queue
    ///         reproduces the vault's conversion rounding exactly.
    function onProposalSettled(uint256 proposalId) external onlyGovernor {
        address q = _withdrawalQueue;
        if (q == address(0)) return;
        uint256 num = totalAssets() + 1;
        uint256 den = totalSupply() + 10 ** _decimalsOffset();
        IVaultWithdrawalQueue(q).stampSettlement(proposalId, num, den);
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
