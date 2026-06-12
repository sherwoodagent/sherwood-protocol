// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SyndicateVault} from "./SyndicateVault.sol";
import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "./interfaces/IGuardianRegistry.sol";
import {IStakedWood} from "./interfaces/IStakedWood.sol";
import {IL2Registrar} from "./interfaces/IL2Registrar.sol";
import {VaultWithdrawalQueue} from "./queue/VaultWithdrawalQueue.sol";

/**
 * @title SyndicateFactory
 * @notice Deploys new syndicate vaults as immutable ERC-1967 proxies. One tx = one syndicate.
 *
 *   All syndicates share the same executor lib (stateless, called via delegatecall)
 *   and vault implementation. Each vault proxy has its own storage: positions,
 *   agent registry, and depositor whitelist.
 *
 *   ENS subnames are registered atomically via Durin L2 Registrar, so each
 *   syndicate gets a <subdomain>.sherwoodagent.eth name resolving to its vault.
 *
 *   UUPS upgradeable — owner can update config (creation fee, governor, etc.)
 *   but deployed vaults are immutable (no upgradeTo on vaults).
 */
contract SyndicateFactory is Initializable, OwnableUpgradeable, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    // ── Errors ──
    error InvalidExecutorImpl();
    error InvalidVaultImpl();
    error InvalidENSRegistrar();
    error InvalidAgentRegistry();
    error NotAgentOwner();
    /// @notice Sherlock #32 — `rotateOwner` restricted to vault owner / creator.
    error NotVaultOwnerOrCreator();
    /// @notice Sherlock #28 — new registry doesn't recognize this factory.
    error RegistryFactoryMismatch();
    error SubdomainTooShort();
    error SubdomainTaken();
    error NotCreator();
    error InvalidGovernor();
    error InsufficientCreationFee();
    error InvalidFeeToken();
    error ManagementFeeTooHigh();
    error UpgradesDisabled();
    error VaultNotDeployed();
    error StrategyActive();
    error VaultImplMismatch();
    // ── Task 26: owner-stake binding + rotation errors ──
    error InvalidGuardianRegistry();
    error PreparedStakeNotFound();
    error VaultStillStaked();
    error RegistryMismatch();
    error ZeroAddress();
    error ProposalActive();
    error ProposalsOpen();
    error InvalidSyndicateConfig();

    struct SyndicateConfig {
        string metadataURI; // ipfs://Qm... (name, description, strategies)
        IERC20 asset; // Deposit asset (e.g., USDC)
        string name; // Vault token name
        string symbol; // Vault token symbol
        bool openDeposits; // If true, anyone can deposit. If false, depositor whitelist enforced.
        string subdomain; // ENS subdomain label (e.g. "alpha-seekers")
    }

    struct Syndicate {
        uint256 id;
        address vault; // ERC-4626 vault (proxy)
        address creator;
        string metadataURI; // ipfs://... via Pinata
        uint256 createdAt;
        bool active;
        string subdomain; // ENS subdomain registered
    }

    // ── Storage ──

    /// @notice Shared executor lib (deployed once, stateless)
    address public executorImpl;

    /// @notice Shared vault implementation (proxies are non-upgradeable)
    address public vaultImpl;

    /// @notice Durin L2 Registrar for ENS subnames
    IL2Registrar public ensRegistrar;

    /// @notice ERC-8004 agent identity registry (ERC-721)
    IERC721 public agentRegistry;

    /// @notice Shared governor contract.
    /// @dev Set once at `initialize` and never rewired. There is no setter —
    ///      `setGovernor` was removed to close V-H2, a factory-owner instant
    ///      global retroactive switch that would have orphaned in-flight
    ///      proposals across every registered vault (vaults read the governor
    ///      live via `_getGovernor()`, so a rewire would leave the old
    ///      governor unable to call `onlyGovernor` fns and the new governor
    ///      with no knowledge of the proposal). Governor upgrades must go
    ///      through a UUPS upgrade of the governor itself.
    address public governor;

    /// @notice Management fee for vault owners (bps of strategy profits)
    uint256 public managementFeeBps;

    /// @notice All syndicates
    mapping(uint256 => Syndicate) public syndicates;
    uint256 public syndicateCount;

    /// @notice Vault address → syndicate ID
    mapping(address => uint256) public vaultToSyndicate;

    /// @notice ENS subdomain → syndicate ID
    mapping(string => uint256) public subdomainToSyndicate;

    /// @notice ERC-20 token required for creation fee (e.g., USDC)
    IERC20 public creationFeeToken;

    /// @notice Amount of creationFeeToken required to create a syndicate (0 = free)
    uint256 public creationFee;

    /// @notice Recipient of creation fees
    address public creationFeeRecipient;

    /// @notice Whether vault upgrades are enabled (default: false)
    bool public upgradesEnabled;

    /// @notice Guardian registry used to gate vault creation on prepared owner stake
    ///         and to coordinate owner-stake slot transfers on `rotateOwner`.
    /// @dev Set once at `initialize` and never rewired. The governor and factory
    ///      MUST share the same registry — `rotateOwner` asserts this invariant.
    address public guardianRegistry;

    /// @dev Active-syndicate IDs for O(1) paginated enumeration (V-C4).
    ///      Added on `createSyndicate`, removed on `deactivate`. The legacy
    ///      `syndicates[id].active` flag remains the source of truth for
    ///      individual rows; this set is kept in lock-step.
    EnumerableSet.UintSet private _activeSyndicateIds;

    /// @notice Hard cap on the per-call page size for `getActiveSyndicates`.
    ///         Paginated reads above this cap silently clamp to `MAX_PAGE_LIMIT`.
    uint256 public constant MAX_PAGE_LIMIT = 100;

    /// @notice Maximum management fee a vault owner may charge (5% of post-strategy net).
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500;

    /// @dev Reserved for future storage — reduced by 1 for `guardianRegistry`,
    ///      reduced by 1 for `_activeSyndicateIds` (EnumerableSet.UintSet uses
    ///      a single storage slot for the Set struct).
    uint256[48] private __gap;

    // ── Events ──

    event SyndicateCreated(
        uint256 indexed id, address indexed vault, address indexed creator, string metadataURI, string subdomain
    );
    event MetadataUpdated(uint256 indexed id, string metadataURI);
    event SyndicateDeactivated(uint256 indexed id);
    event CreationFeeUpdated(address token, uint256 amount, address recipient);
    event VaultImplUpdated(address oldImpl, address newImpl);
    event ManagementFeeBpsUpdated(uint256 oldBps, uint256 newBps);
    event VaultUpgraded(address indexed vault, address indexed newImpl);
    event UpgradesEnabledUpdated(bool enabled);
    event OwnerRotated(address indexed vault, address indexed newOwner);
    event WithdrawalQueueDeployed(address indexed vault, address indexed queue);
    /// @notice PR #351 review #7: emitted when the ENS subname registration
    ///         in `createSyndicate` reverts (e.g. a mempool front-runner
    ///         registered the same label, or the registrar is paused). The
    ///         vault + queue + stake bind already landed; off-chain can
    ///         retry by calling the registrar directly.
    event EnsRegistrationFailed(address indexed vault, string subdomain);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event EnsRegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);

    struct InitParams {
        address owner;
        address executorImpl;
        address vaultImpl;
        address ensRegistrar;
        address agentRegistry;
        address governor;
        uint256 managementFeeBps;
        address guardianRegistry;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.executorImpl == address(0)) revert InvalidExecutorImpl();
        if (p.vaultImpl == address(0)) revert InvalidVaultImpl();
        // NOTE: ensRegistrar and agentRegistry can be address(0) on chains without ENS/ERC-8004
        if (p.governor == address(0)) revert InvalidGovernor();
        if (p.guardianRegistry == address(0)) revert InvalidGuardianRegistry();

        __Ownable_init(p.owner);

        executorImpl = p.executorImpl;
        vaultImpl = p.vaultImpl;
        ensRegistrar = IL2Registrar(p.ensRegistrar);
        agentRegistry = IERC721(p.agentRegistry);
        governor = p.governor;
        guardianRegistry = p.guardianRegistry;
        if (p.managementFeeBps > MAX_MANAGEMENT_FEE_BPS) revert ManagementFeeTooHigh();
        managementFeeBps = p.managementFeeBps;
    }

    // ==================== SYNDICATE CREATION ====================

    /// @notice Create a new syndicate — deploys vault proxy, registers ENS subname, stores everything
    /// @param creatorAgentId ERC-8004 agent ID of the creator (must be owned by msg.sender)
    /// @param config Syndicate configuration
    /// @return syndicateId The new syndicate's ID
    /// @return vault The deployed vault proxy address
    function createSyndicate(uint256 creatorAgentId, SyndicateConfig calldata config)
        external
        returns (uint256 syndicateId, address vault)
    {
        // V-M7: reject zero/empty config fields before any side effects. Without
        // these checks, `cfg.asset == 0` would only trip in `SyndicateVault.initialize`
        // (after ENS subdomain registration + registry stake bind), leaving stranded
        // state. Empty name / symbol / metadataURI would deploy a vault with blank
        // ERC-4626 metadata + no IPFS pointer. `subdomain.length < 3` is already
        // checked below (`SubdomainTooShort`) so we only assert non-empty here.
        if (address(config.asset) == address(0)) revert InvalidSyndicateConfig();
        if (bytes(config.name).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.symbol).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.subdomain).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.metadataURI).length == 0) revert InvalidSyndicateConfig();

        // Gate on prepared owner stake BEFORE any side effects (Task 26).
        // Owner bonds live on sWOOD post-split; the registry exposes its sWOOD
        // handle so the factory does not need a separate stored reference.
        IGuardianRegistry reg = IGuardianRegistry(guardianRegistry);
        IStakedWood sw = reg.swood();
        if (!sw.canCreateVault(msg.sender)) revert PreparedStakeNotFound();

        // Collect creation fee (if set)
        if (creationFee > 0) {
            if (address(creationFeeToken) == address(0)) revert InvalidFeeToken();
            creationFeeToken.safeTransferFrom(msg.sender, creationFeeRecipient, creationFee);
        }

        // Verify ERC-8004 identity (skipped on chains without agent registry)
        if (address(agentRegistry) != address(0)) {
            if (agentRegistry.ownerOf(creatorAgentId) != msg.sender) revert NotAgentOwner();
        }

        // Validate subdomain
        if (bytes(config.subdomain).length < 3) revert SubdomainTooShort();
        if (subdomainToSyndicate[config.subdomain] != 0) revert SubdomainTaken();

        syndicateId = ++syndicateCount;

        // Deploy vault as immutable proxy (no upgradeTo — locked to vaultImpl)
        ISyndicateVault.InitParams memory initParams = ISyndicateVault.InitParams({
            asset: address(config.asset),
            name: config.name,
            symbol: config.symbol,
            owner: msg.sender,
            executorImpl: executorImpl,
            openDeposits: config.openDeposits,
            agentRegistry: address(agentRegistry),
            managementFeeBps: managementFeeBps
        });
        bytes memory initData = abi.encodeCall(SyndicateVault.initialize, (initParams));

        vault = address(new ERC1967Proxy(vaultImpl, initData));

        // Deploy the per-vault async withdrawal queue and bind it. The vault checks
        // `msg.sender == _factory`, so we must call `setWithdrawalQueue` from this
        // (factory) context.
        VaultWithdrawalQueue queue = new VaultWithdrawalQueue(vault);
        ISyndicateVault(vault).setWithdrawalQueue(address(queue));
        emit WithdrawalQueueDeployed(vault, address(queue));

        // Register vault with the governor so it can receive proposals
        ISyndicateGovernor(governor).addVault(vault);

        // Bind the prepared owner stake to the newly deployed vault (Task 26).
        // Reverts roll back the whole creation tx — atomic.
        sw.bindOwnerStake(msg.sender, vault);

        // Register ENS subname — vault is both address record + NFT owner.
        //
        // PR #351 review #7: an external registrar revert (mempool front-runner
        // claims the label upstream, or the registrar is paused) must NOT undo
        // the fee transfer + vault/queue deploy + stake bind already done. The
        // syndicate is fully operational without ENS — chat discovery falls
        // back to subdomain name-match — and an operator can `register` later
        // via the registrar directly (see `setEnsRegistrar` natspec). So we
        // never revert `createSyndicate` for an ENS failure.
        //
        // PR #359 review #5: pre-check `available()` so a genuine label-taken
        // front-run is distinguished (in telemetry) from an unexpected
        // registrar fault, and the doomed `register` call is skipped. Either
        // way we emit `EnsRegistrationFailed` for monitors. We deliberately do
        // NOT bubble the non-front-run reverts (Ana's "scope + bubble"
        // suggestion): a paused/misconfigured registrar would then brick ALL
        // vault creation, which is worse than shipping ENS-less + an event.
        if (address(ensRegistrar) != address(0)) {
            // F4: the `available()` view is itself an external call into a
            // possibly-paused / misconfigured / non-conforming registrar. It
            // MUST be in try/catch too — otherwise a reverting view bricks ALL
            // vault creation, the exact DoS the `register` catch (and the note
            // above) is meant to prevent.
            try ensRegistrar.available(config.subdomain) returns (bool avail) {
                if (avail) {
                    try ensRegistrar.register(config.subdomain, vault) {}
                    catch {
                        emit EnsRegistrationFailed(vault, config.subdomain);
                    }
                } else {
                    // Label already taken upstream (front-run or prior external
                    // registration). Skip the doomed call; signal for retry/triage.
                    emit EnsRegistrationFailed(vault, config.subdomain);
                }
            } catch {
                // Registrar `available()` faulted — fail open, stay operational.
                emit EnsRegistrationFailed(vault, config.subdomain);
            }
        }

        syndicates[syndicateId] = Syndicate({
            id: syndicateId,
            vault: vault,
            creator: msg.sender,
            metadataURI: config.metadataURI,
            createdAt: block.timestamp,
            active: true,
            subdomain: config.subdomain
        });

        vaultToSyndicate[vault] = syndicateId;
        // PR #359 review #5: the subdomain → syndicate mapping is written
        // UNCONDITIONALLY (even if the ENS on-chain registration above failed)
        // BY DESIGN — the subdomain is the syndicate's logical name used for
        // chat discovery, and Sherwood reserves it locally regardless of ENS
        // state. The earlier `SubdomainTaken` guard prevents two syndicates
        // from claiming the same logical name. ENS is a best-effort on-chain
        // mirror, retryable out-of-band.
        subdomainToSyndicate[config.subdomain] = syndicateId;
        _activeSyndicateIds.add(syndicateId);

        emit SyndicateCreated(syndicateId, vault, msg.sender, config.metadataURI, config.subdomain);
    }

    // ==================== CREATOR FUNCTIONS ====================

    /// @notice Update syndicate metadata (creator only)
    function updateMetadata(uint256 syndicateId, string calldata metadataURI) external {
        Syndicate storage s = syndicates[syndicateId];
        if (s.creator != msg.sender) revert NotCreator();
        s.metadataURI = metadataURI;
        emit MetadataUpdated(syndicateId, metadataURI);
    }

    /// @notice Deactivate a syndicate (creator only)
    function deactivate(uint256 syndicateId) external {
        Syndicate storage s = syndicates[syndicateId];
        if (s.creator != msg.sender) revert NotCreator();
        s.active = false;
        _activeSyndicateIds.remove(syndicateId);
        emit SyndicateDeactivated(syndicateId);
    }

    // ==================== ADMIN (OWNER) ====================

    /// @notice Set creation fee parameters (0 amount = free creation)
    function setCreationFee(address token, uint256 amount, address recipient) external onlyOwner {
        if (amount > 0 && token == address(0)) revert InvalidFeeToken();
        if (amount > 0 && recipient == address(0)) revert InvalidFeeToken();
        creationFeeToken = IERC20(token);
        creationFee = amount;
        creationFeeRecipient = recipient;
        emit CreationFeeUpdated(token, amount, recipient);
    }

    /// @notice Update the vault implementation for new vaults (existing vaults unaffected)
    function setVaultImpl(address newVaultImpl) external onlyOwner {
        if (newVaultImpl == address(0)) revert InvalidVaultImpl();
        address old = vaultImpl;
        vaultImpl = newVaultImpl;
        emit VaultImplUpdated(old, newVaultImpl);
    }

    /// @notice Update management fee for new vaults (existing vaults unaffected)
    function setManagementFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > MAX_MANAGEMENT_FEE_BPS) revert ManagementFeeTooHigh();
        uint256 old = managementFeeBps;
        managementFeeBps = newBps;
        emit ManagementFeeBpsUpdated(old, newBps);
    }

    /// @notice Enable or disable vault upgrades (owner only)
    function setUpgradesEnabled(bool enabled) external onlyOwner {
        upgradesEnabled = enabled;
        emit UpgradesEnabledUpdated(enabled);
    }

    /// @notice Update the Durin L2 Registrar used for ENS subname registration on
    ///         new syndicates. Setting `newRegistrar` to the zero address disables
    ///         ENS registration on `createSyndicate` (the call is guarded by an
    ///         `address(0)` check at line 282). This setter only affects FUTURE
    ///         syndicates — existing syndicates that were created against a
    ///         misconfigured registrar (e.g. zero) keep their on-chain state and
    ///         must be backfilled per-syndicate by calling
    ///         `IL2Registrar(registrar).register(subdomain, vault)` directly
    ///         (the registrar's `register` is permissionless).
    function setEnsRegistrar(address newRegistrar) external onlyOwner {
        address old = address(ensRegistrar);
        ensRegistrar = IL2Registrar(newRegistrar);
        emit EnsRegistrarUpdated(old, newRegistrar);
    }

    /// @notice Re-point the factory at a new guardian registry. Used when WOOD
    ///         ships and the protocol migrates from the beta stub to the real
    ///         `GuardianRegistry`. The governor and factory MUST share the same
    ///         registry; flip both in the same multisig batch.
    /// @dev Sherlock #28: validate that the new registry's `factory()` view
    ///      reports this contract — otherwise the factory and registry are
    ///      misaligned and `bindOwnerStake` / `transferOwnerStakeSlot` will
    ///      revert with `NotFactory`. Pre-fix, this caused new vaults /
    ///      rotations to brick after a registry swap with no early signal.
    ///      Strict: any view-call failure (no `factory` selector, wrong
    ///      return shape, etc.) also reverts — fail-closed.
    function setGuardianRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert InvalidGuardianRegistry();
        // Sherlock #28: require the new registry to either advertise this
        // factory (alignment) or return address(0) (stateless beta stub).
        // Any other non-zero value is a misconfig — fail fast at swap time
        // instead of letting bindOwnerStake / transferOwnerStakeSlot revert
        // silently later.
        try IGuardianRegistry(newRegistry).factory() returns (address registryFactory) {
            if (registryFactory != address(0) && registryFactory != address(this)) {
                revert RegistryFactoryMismatch();
            }
        } catch {
            revert RegistryFactoryMismatch();
        }
        address old = guardianRegistry;
        guardianRegistry = newRegistry;
        emit GuardianRegistrySet(old, newRegistry);
    }

    /// @notice Transfer a vault's ownership to `newOwner` and rebind the owner-stake
    ///         slot in the guardian registry.
    /// @dev Auth: `msg.sender` must be the vault's current owner OR the original
    ///      syndicate creator (Sherlock #32 — factory-owner-only was the
    ///      pre-fix gate and presented a centralization risk). The factory
    ///      owner has no privileged path here.
    /// @dev Requires the old owner to have already unstaked (verified inline as
    ///      `reg.ownerStake(vault) > 0` — the `hasOwnerStake` external view was
    ///      dropped in the registry bytecode trim) — otherwise rotating would
    ///      strand the old stake.
    /// @dev Asserts the factory + governor point at the same registry to catch
    ///      misconfiguration. `newOwner` must have a prepared stake sized
    ///      ≥ `reg.minOwnerStake()` (the `requiredOwnerBond` view was a
    ///      passthrough to `minOwnerStake` and was dropped alongside the
    ///      registry trim); the registry's `transferOwnerStakeSlot` enforces
    ///      this at bind time.
    /// @dev Forbidden while any proposal binds the vault — the new owner would
    ///      otherwise inherit `pause()` and other owner-only powers mid-flight.
    function rotateOwner(address vault, address newOwner) external {
        if (newOwner == address(0)) revert ZeroAddress();
        uint256 syndicateId = vaultToSyndicate[vault];
        if (syndicateId == 0) revert VaultNotDeployed();

        // Sherlock #32: require current vault owner OR original creator
        // consent. Pre-fix, the factory owner could unilaterally rotate any
        // vault to an arbitrary address once the old stake was claimed —
        // the new owner inherited pause / agent-registration / strategy-
        // proposal rights with no prior approval from the vault's
        // operator. Factory-owner-only would be a centralization risk
        // even with an honest multisig.
        address currentOwner = SyndicateVault(payable(vault)).owner();
        if (msg.sender != currentOwner && msg.sender != syndicates[syndicateId].creator) {
            revert NotVaultOwnerOrCreator();
        }

        IGuardianRegistry reg = IGuardianRegistry(guardianRegistry);
        // Sherlock registry bytecode trim: `hasOwnerStake` (`ownerStake > 0`)
        // view dropped on the registry; inline the equivalent check here.
        if (reg.ownerStake(vault) > 0) revert VaultStillStaked();
        // Registry-consistency invariant: governor and factory must share one registry.
        ISyndicateGovernor gov = ISyndicateGovernor(governor);
        if (gov.guardianRegistry() != guardianRegistry) revert RegistryMismatch();
        // Forbid rotation while any proposal binds the vault — otherwise the
        // new owner inherits `pause()` and other owner-only powers mid-flight.
        if (gov.getActiveProposal(vault) != 0) revert ProposalActive();
        if (gov.openProposalCount(vault) != 0) revert ProposalsOpen();

        SyndicateVault(payable(vault)).rotateOwnership(newOwner);
        // Owner-stake slot lives on sWOOD post-split.
        reg.swood().transferOwnerStakeSlot(vault, newOwner);

        // Keep creator record in sync so downstream invariants (e.g. NotCreator
        // gates on updateMetadata / deactivate) follow the active owner.
        syndicates[vaultToSyndicate[vault]].creator = newOwner;

        emit OwnerRotated(vault, newOwner);
    }

    /// @notice Upgrade a vault to a new implementation. Callable by the syndicate owner (vault owner).
    /// @dev Factory must have upgrades enabled, and `vaultImpl` must equal `expectedImpl`.
    ///      The `expectedImpl` parameter closes V-H3: otherwise a factory owner
    ///      could call `setVaultImpl(newImpl)` between when the creator decides
    ///      to upgrade and when the upgrade tx lands, landing the vault on an
    ///      impl the creator did not opt into.
    /// @param vault The vault proxy to upgrade
    /// @param expectedImpl The vault implementation address the creator expects
    ///                     to be applied. Reverts with `VaultImplMismatch` if
    ///                     `vaultImpl` has changed since the caller observed it.
    function upgradeVault(address vault, address expectedImpl) external {
        if (!upgradesEnabled) revert UpgradesDisabled();
        uint256 syndicateId = vaultToSyndicate[vault];
        if (syndicateId == 0) revert VaultNotDeployed();
        if (syndicates[syndicateId].creator != msg.sender) revert NotCreator();
        if (vaultImpl != expectedImpl) revert VaultImplMismatch();
        // Sherlock run #2 #8: `getActiveProposal` is set only on the Executed
        // transition. Draft / Pending / GuardianReview / Approved keep
        // `openProposalCount > 0` while `getActiveProposal == 0`. Without the
        // `openProposalCount` gate, the creator could swap implementations
        // mid-vote — LPs would have approved strategy X against impl A but
        // execute under impl B. Mirrors the `rotateOwner` gate above —
        // split into two distinct errors per ana's PR #350 review so
        // off-chain tooling decoding the selector can tell which gate fired.
        if (governor != address(0)) {
            ISyndicateGovernor gov = ISyndicateGovernor(governor);
            if (gov.getActiveProposal(vault) != 0) revert StrategyActive();
            if (gov.openProposalCount(vault) != 0) revert ProposalsOpen();
        }
        UUPSUpgradeable(vault).upgradeToAndCall(vaultImpl, "");
        emit VaultUpgraded(vault, vaultImpl);
    }

    // ==================== VIEWS ====================

    /// @notice Check if a subdomain is available for registration
    function isSubdomainAvailable(string calldata subdomain) external view returns (bool) {
        return subdomainToSyndicate[subdomain] == 0
            && (address(ensRegistrar) == address(0) || ensRegistrar.available(subdomain));
    }

    /// @notice Get active syndicates with pagination (for dashboard).
    /// @dev    Backed by `_activeSyndicateIds` (EnumerableSet) so reads are
    ///         O(limit) instead of O(syndicateCount). `limit` is hard-capped at
    ///         `MAX_PAGE_LIMIT` to guarantee the call stays well below block
    ///         gas even as the set grows.
    /// @param offset Starting index (0-based) into the active-set
    /// @param limit  Maximum number of results to return; clamped to `MAX_PAGE_LIMIT`
    /// @return result Array of active syndicates (in insertion order with swap-pop gaps filled)
    /// @return total  Total count of active syndicates
    function getActiveSyndicates(uint256 offset, uint256 limit)
        external
        view
        returns (Syndicate[] memory result, uint256 total)
    {
        total = _activeSyndicateIds.length();

        if (offset >= total || limit == 0) {
            return (new Syndicate[](0), total);
        }
        if (limit > MAX_PAGE_LIMIT) {
            limit = MAX_PAGE_LIMIT;
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 outLen = end - offset;
        result = new Syndicate[](outLen);
        for (uint256 i = 0; i < outLen; i++) {
            result[i] = _syndicateAt(offset + i);
        }
    }

    /// @dev Memberwise copy of one syndicate from storage to memory. Extracted
    ///      from `getActiveSyndicates`'s loop so the legacy compiler pipeline
    ///      (forge coverage, no via_ir) doesn't trip stack-too-deep when
    ///      copying the 7-field struct (two of which are dynamic strings) on
    ///      each iteration. Pure pass-through — no bounds re-check; the
    ///      caller has already clamped against `_activeSyndicateIds.length()`.
    function _syndicateAt(uint256 indexInActiveSet) private view returns (Syndicate memory) {
        return syndicates[_activeSyndicateIds.at(indexInActiveSet)];
    }

    /// @notice Get ALL active syndicates. Clamped at `MAX_PAGE_LIMIT` per call;
    ///         callers that need every row must paginate via `getActiveSyndicates`.
    function getAllActiveSyndicates() external view returns (Syndicate[] memory) {
        (Syndicate[] memory result,) = this.getActiveSyndicates(0, MAX_PAGE_LIMIT);
        return result;
    }

    // ==================== UUPS ====================

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
