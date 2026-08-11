// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";
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
import {FeeConstants} from "./FeeConstants.sol";

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
    /// @notice No real tier registry where one is mandatory (pashov finding #1):
    ///         a governor without one is permanently registry-less, and
    ///         `SyndicateVault._guardBatchCalls` degrades OPEN.
    error TierRegistryNotWired();
    error InvalidExecutorImpl();
    error InvalidVaultImpl();
    error InvalidENSRegistrar();
    error InvalidAgentRegistry();
    error NotAgentOwner();
    /// @notice `rotateOwner` restricted to vault owner / creator.
    error NotVaultOwnerOrCreator();
    /// @notice New registry doesn't recognize this factory.
    error RegistryFactoryMismatch();
    error SubdomainTooShort();
    error SubdomainTaken();
    error NotCreator();
    error InvalidBeacon();
    error InvalidProtocolConfig();
    error InsufficientCreationFee();
    error InvalidFeeToken();
    error ManagementFeeTooHigh();
    error UpgradesDisabled();
    error VaultNotDeployed();
    error StrategyActive();
    error VaultImplMismatch();
    // ── Owner-stake binding + rotation errors ──
    error InvalidGuardianRegistry();
    error PreparedStakeNotFound();
    error VaultStillStaked();
    error ZeroAddress();
    error ProposalActive();
    error ProposalsOpen();
    error InvalidSyndicateConfig();
    /// @dev `pushWiring` target is not a governor this factory deployed.
    error NotFactoryGovernor();

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

    /// @notice GovernorBeacon — every per-vault governor proxy reads its
    ///         implementation from this beacon. A protocol-wide governor upgrade
    ///         is a single `beacon.upgradeTo(newImpl)` by the beacon owner (a
    ///         multisig), atomically re-pointing all live governors.
    /// @dev Owner-settable via `setBeacon` (for a future beacon migration).
    address public beacon;

    /// @notice ProtocolConfig — global fee parameters (protocol/guardian fee bps
    ///         + recipients). Each governor reads it at propose time to snapshot
    ///         the fees onto the proposal. Owner-settable via `setProtocolConfig`.
    address public protocolConfig;

    /// @notice Per-vault governor proxy address, deployed at `createSyndicate`.
    ///         `vault → governor`. Read externally via `governorOf(vault)`.
    mapping(address vault => address governor) private _governorOf;

    /// @dev Deprecated. Formerly the protocol PriceRouter for Lane A live-NAV
    ///      pricing, now retired (issue #54). Slot 7 stays occupied — same
    ///      slot, same type — because the factory is deployed and its layout
    ///      is golden-pinned (`script/syndicate-factory-layout.golden.json`);
    ///      only the label changes, which the EVM never sees.
    address private __deprecated_priceRouter;

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

    /// @dev Active-syndicate IDs for O(1) paginated enumeration. Added on
    ///      `createSyndicate`, removed on `deactivate`. `syndicates[id].active`
    ///      remains the source of truth for individual rows; this set is kept
    ///      in lock-step.
    EnumerableSet.UintSet private _activeSyndicateIds;

    /// @notice Hard cap on the per-call page size for `getActiveSyndicates`.
    ///         Paginated reads above this cap silently clamp to `MAX_PAGE_LIMIT`.
    uint256 public constant MAX_PAGE_LIMIT = 100;

    /// @notice Maximum management fee a vault owner may charge (5% of post-strategy net).
    uint256 public constant MAX_MANAGEMENT_FEE_BPS = 500;

    /// @notice Adapter-selector tier registry (guardian economic-security model).
    ///         Optional — `address(0)` means governors created by this factory
    ///         keep the safe tier-2 default (full-notional coverage). Set
    ///         post-deploy by the owner via `setTierRegistry`, then pushed into
    ///         each per-vault governor at `createSyndicate`.
    address public tierRegistry;

    /// @notice Aggregate-exposure ledger (guardian economic-security model).
    ///         Optional — `address(0)` means governors created by this factory
    ///         skip the covered-TVL cap and the risk-scaled proposer bond. Set
    ///         post-deploy by the owner via `setExposureLedger`, then pushed
    ///         into each per-vault governor at `createSyndicate` — or into an
    ///         already-created governor via `pushWiring`.
    address public exposureLedger;

    /// @notice Proposer-bond escrow (guardian economic-security model).
    ///         Optional — `address(0)` means governors created by this factory
    ///         lock no proposer bond at `propose`. Set post-deploy by the owner
    ///         via `setBondEscrow`, then pushed into each per-vault governor at
    ///         `createSyndicate` — or into an already-created governor via
    ///         `pushWiring`.
    address public bondEscrow;

    /// @dev Reserved for future storage. Shrinks as named slots are carved off the
    ///      FRONT of the gap, so every field behind it keeps its slot. One slot was
    ///      RESTORED when `compensationEscrow` was removed rather than deprecated
    ///      — legal only pre-mainnet, with the layout golden regenerated in the
    ///      same change; from the first mainnet deploy onward that slot would have
    ///      to stay.
    uint256[43] private __gap;

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
    /// @notice Emitted when the ENS subname registration in `createSyndicate`
    ///         reverts (e.g. a mempool front-runner registered the same label,
    ///         or the registrar is paused). The vault + queue + stake bind
    ///         already landed; off-chain can retry by calling the registrar
    ///         directly.
    event EnsRegistrationFailed(address indexed vault, string subdomain);
    event GuardianRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event TierRegistrySet(address indexed oldRegistry, address indexed newRegistry);
    event ExposureLedgerSet(address indexed oldLedger, address indexed newLedger);
    event BondEscrowSet(address indexed oldEscrow, address indexed newEscrow);
    /// @notice Emitted when `pushWiring` re-pushes the factory's current
    ///         tierRegistry / exposureLedger / bondEscrow into an existing governor.
    event WiringPushed(address indexed governor);
    /// @notice Emitted by `setExecutorImpl` — the shared `BatchExecutorLib`
    ///         new syndicates are wired to at `createSyndicate` (issue #43).
    event ExecutorImplUpdated(address oldImpl, address newImpl);
    /// @notice Emitted when `pushExecutor` re-points an existing vault at the
    ///         factory's current `executorImpl` (issue #43).
    event ExecutorPushed(address indexed vault, address indexed executorImpl);
    event GovernorDeployed(address indexed vault, address indexed governor);
    event BeaconUpdated(address indexed oldBeacon, address indexed newBeacon);
    event ProtocolConfigUpdated(address indexed oldConfig, address indexed newConfig);
    event EnsRegistrarUpdated(address indexed oldRegistrar, address indexed newRegistrar);

    struct InitParams {
        address owner;
        address executorImpl;
        address vaultImpl;
        address ensRegistrar;
        address agentRegistry;
        address beacon;
        address protocolConfig;
        uint256 managementFeeBps;
        address guardianRegistry;
        /// @dev MANDATORY (pashov finding #1) — here rather than in a follow-up
        ///      `setTierRegistry` so a live-but-unwired factory cannot exist.
        address tierRegistry;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata p) external initializer {
        if (p.executorImpl == address(0)) revert InvalidExecutorImpl();
        if (p.vaultImpl == address(0)) revert InvalidVaultImpl();
        // NOTE: ensRegistrar and agentRegistry can be address(0) on chains without ENS/ERC-8004
        if (p.beacon == address(0)) revert InvalidBeacon();
        if (p.protocolConfig == address(0)) revert InvalidProtocolConfig();
        if (p.guardianRegistry == address(0)) revert InvalidGuardianRegistry();
        // Codeless subsumes zero. An EOA would be stamped into every governor
        // this factory creates and brick each one's `executeGovernorBatch`.
        if (p.tierRegistry.code.length == 0) revert TierRegistryNotWired();

        __Ownable_init(p.owner);

        executorImpl = p.executorImpl;
        vaultImpl = p.vaultImpl;
        ensRegistrar = IL2Registrar(p.ensRegistrar);
        agentRegistry = IERC721(p.agentRegistry);
        beacon = p.beacon;
        protocolConfig = p.protocolConfig;
        guardianRegistry = p.guardianRegistry;
        tierRegistry = p.tierRegistry;
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
        // Reject zero/empty config fields before any side effects — otherwise
        // `cfg.asset == 0` would only trip in `SyndicateVault.initialize` (after
        // ENS subdomain registration + registry stake bind), leaving stranded
        // state, and empty name / symbol / metadataURI would deploy a vault
        // with blank ERC-4626 metadata + no IPFS pointer. `subdomain.length < 3`
        // is checked below (`SubdomainTooShort`) so we only assert non-empty here.
        if (address(config.asset) == address(0)) revert InvalidSyndicateConfig();
        if (bytes(config.name).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.symbol).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.subdomain).length == 0) revert InvalidSyndicateConfig();
        if (bytes(config.metadataURI).length == 0) revert InvalidSyndicateConfig();
        // Registry-less vaults are born unguarded (finding #1 — rationale at
        // the governor init site below). `initialize` requires one, so this only
        // fires after an owner zeroed the slot as a kill switch. Reads factory
        // storage only, so it belongs with the pre-flight rejects.
        if (tierRegistry == address(0)) revert TierRegistryNotWired();

        // Gate on prepared owner stake before any side effects. Owner bonds
        // live on sWOOD; the registry exposes its sWOOD handle so the factory
        // does not need a separate stored reference.
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

        // Deploy the per-vault governor as a BeaconProxy. The governor's
        // `onlyVaultOwner` resolves the owner live from the vault, and the vault
        // resolves its governor back through `factory.governorOf(vault)` (read
        // from `_governorOf` below) — so recording the mapping here is what wires
        // the vault ↔ governor link (no separate vault setter needed).
        // `addGovernor` authorizes the new governor on the shared registry.
        // The tier registry goes in the INIT CALL, not a follow-up
        // `setTierRegistry` (pashov finding #1). This used to skip the push when
        // the factory's own pointer was unset, on the premise that the governor
        // "keeps its safe tier-2 default". That is a PRICING default; what a
        // missing registry removes is a CAPABILITY gate.
        // `SyndicateVault._guardBatchCalls` resolving no registry used to RETURN,
        // dropping the callee allowlist, the spender/recipient gate and the
        // `UnrecognizedAssetSelector` branch on the way out — after which one
        // batch instruction, `asset.approve(attacker, max)`, moves ZERO balance,
        // so the net-outflow meter, the per-call cap and `requiredCoverage` all
        // read zero, and the vault is drained in a LATER transaction no meter
        // watches. A vault created in that window stayed registry-less
        // permanently, so the window was inherited, not transient.
        //
        // Three layers now, cheapest first: mandatory `InitParams.tierRegistry`
        // on this factory, the pre-flight reject at the top of this function,
        // and the governor's own `initialize` refusing a codeless registry —
        // after which the guard itself fails closed rather than open.
        bytes memory govInitData = abi.encodeCall(
            ISyndicateGovernor.initialize,
            (vault, guardianRegistry, protocolConfig, address(this), tierRegistry, _defaultGovernorParams())
        );
        address govProxy = address(new BeaconProxy(beacon, govInitData));
        _governorOf[vault] = govProxy;
        IGuardianRegistry(guardianRegistry).addGovernor(govProxy, vault);
        // The exposure-ledger and bond-escrow wiring slots keep the push idiom:
        // `setExposureLedger` / `setBondEscrow` are onlyFactory, so this is the
        // sole wiring point at creation. Unset ⇒ skip the call, leaving the
        // governor at its pre-ledger / no-bond default rather than writing zero.
        if (exposureLedger != address(0)) {
            ISyndicateGovernor(govProxy).setExposureLedger(exposureLedger);
        }
        if (bondEscrow != address(0)) {
            ISyndicateGovernor(govProxy).setBondEscrow(bondEscrow);
        }
        emit GovernorDeployed(vault, govProxy);

        // Bind the prepared owner stake to the newly deployed vault. Reverts
        // roll back the whole creation tx — atomic.
        sw.bindOwnerStake(msg.sender, vault);

        // Register the ENS subname — the vault is both address record and NFT
        // owner. An external registrar revert (a mempool front-runner claiming the
        // label, or a paused registrar) must NOT undo the fee transfer, vault and
        // queue deploy, and stake bind already done: the syndicate is fully
        // operational without ENS, and an operator can `register` later via the
        // registrar directly. So `createSyndicate` never reverts for an ENS
        // failure.
        //
        // Pre-check `available()` so a genuine label-taken front-run is
        // distinguished in telemetry from an unexpected registrar fault, and the
        // doomed `register` call is skipped. Non-front-run reverts are
        // deliberately not bubbled either: a paused or misconfigured registrar
        // would then brick ALL vault creation.
        if (address(ensRegistrar) != address(0)) {
            // The `available()` view is itself an external call into a
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
        // Written unconditionally (even if the ENS on-chain registration above
        // failed) — the subdomain is the syndicate's logical name used for
        // chat discovery, and Sherwood reserves it locally regardless of ENS
        // state. The earlier `SubdomainTaken` guard prevents two syndicates
        // from claiming the same logical name. ENS is a best-effort on-chain
        // mirror, retryable out-of-band.
        subdomainToSyndicate[config.subdomain] = syndicateId;
        _activeSyndicateIds.add(syndicateId);

        emit SyndicateCreated(syndicateId, vault, msg.sender, config.metadataURI, config.subdomain);
    }

    /// @dev Default governance parameters stamped onto each new per-vault governor
    ///      at deploy. Vault owners tune them post-creation via the governor's
    ///      owner-instant setters. All values sit within `GovernorParameters`
    ///      bounds so the governor's validation at `initialize` accepts them.
    /// @dev `maxPerformanceFeeBps` starts at the advertised headline (20%), not at
    ///      the protocol ceiling (30%): the settle-time clamp resolves an
    ///      over-ceiling rate silently, so a permissive default would fail open and
    ///      let an owner quietly charge above the headline. Named constant, not a
    ///      literal, so it cannot drift from `FeeConstants`.
    function _defaultGovernorParams() private pure returns (ISyndicateGovernor.GovernorParams memory) {
        return ISyndicateGovernor.GovernorParams({
            votingPeriod: 24 hours,
            executionWindow: 24 hours,
            vetoThresholdBps: 2000,
            maxPerformanceFeeBps: FeeConstants.DEFAULT_MAX_PERFORMANCE_FEE_BPS,
            cooldownPeriod: 1 hours,
            collaborationWindow: 24 hours,
            maxCoProposers: 10,
            minStrategyDuration: 1 hours,
            maxStrategyDuration: 30 days
        });
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

    /// @notice Update the shared `BatchExecutorLib` new syndicates are wired to
    ///         at `createSyndicate` (issue #43, design.md D5 migration
    ///         primitive #1). Existing vaults are untouched — re-point them
    ///         individually via `pushExecutor`.
    function setExecutorImpl(address newExecutorImpl) external onlyOwner {
        if (newExecutorImpl == address(0)) revert InvalidExecutorImpl();
        address old = executorImpl;
        executorImpl = newExecutorImpl;
        emit ExecutorImplUpdated(old, newExecutorImpl);
    }

    /// @notice Re-point an EXISTING factory-deployed vault at the factory's CURRENT
    ///         `executorImpl`, re-stamping its expected codehash atomically.
    /// @dev Mirrors `pushWiring`'s factory-deployed check — here applied to the
    ///      VAULT, by resolving its governor through `_governorOf`, which only ever
    ///      holds proxies this factory deployed — plus `rotateOwner`'s lifecycle
    ///      gates: a re-point under a live proposal would swap the metering library
    ///      out from under stored, coverage-priced calls.
    function pushExecutor(address vault) external onlyOwner {
        uint256 syndicateId = vaultToSyndicate[vault];
        if (syndicateId == 0) revert VaultNotDeployed();
        ISyndicateGovernor gov = ISyndicateGovernor(_governorOf[vault]);
        if (gov.getActiveProposal() != 0) revert ProposalActive();
        if (gov.openProposalCount() != 0) revert ProposalsOpen();
        ISyndicateVault(vault).setExecutorImpl(executorImpl);
        emit ExecutorPushed(vault, executorImpl);
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
    ///         new syndicates. Zero disables ENS registration on
    ///         `createSyndicate`. Only affects FUTURE syndicates — existing ones
    ///         created against a misconfigured registrar keep their on-chain state
    ///         and must be backfilled per-syndicate by calling the registrar's
    ///         permissionless `register` directly.
    function setEnsRegistrar(address newRegistrar) external onlyOwner {
        address old = address(ensRegistrar);
        ensRegistrar = IL2Registrar(newRegistrar);
        emit EnsRegistrarUpdated(old, newRegistrar);
    }

    /// @notice Re-point the beacon that new governor proxies read their impl from.
    /// @dev Does NOT touch already-deployed proxies' target (they read the beacon
    ///      live) — this only matters if the whole beacon contract is swapped.
    ///      A routine governor-impl upgrade is `beacon.upgradeTo(newImpl)`.
    function setBeacon(address newBeacon) external onlyOwner {
        if (newBeacon == address(0)) revert InvalidBeacon();
        address old = beacon;
        beacon = newBeacon;
        emit BeaconUpdated(old, newBeacon);
    }

    /// @notice Re-point the ProtocolConfig that new governors snapshot fees from.
    /// @dev Existing governors keep their own `protocolConfig` reference set at
    ///      their `initialize`; this only affects governors deployed afterwards.
    function setProtocolConfig(address newConfig) external onlyOwner {
        if (newConfig == address(0)) revert InvalidProtocolConfig();
        address old = protocolConfig;
        protocolConfig = newConfig;
        emit ProtocolConfigUpdated(old, newConfig);
    }

    /// @notice Factory-owner rescue: overwrite a vault's governor params,
    ///         bypassing the governor's `whenNoActiveProposal` freeze. Still
    ///         subject to the governor's bounds validation (`forceSetParams`
    ///         calls `_validateParamBounds`). For unsticking a vault whose owner
    ///         key is lost or whose params trap it mid-lifecycle.
    function setParamsOverride(address vault, ISyndicateGovernor.GovernorParams calldata params) external onlyOwner {
        address gov = _governorOf[vault];
        if (gov == address(0)) revert VaultNotDeployed();
        ISyndicateGovernor(gov).forceSetParams(params);
    }

    /// @notice Re-point the factory at a new guardian registry. The governor and
    ///         factory MUST share the same registry; flip both in the same multisig
    ///         batch.
    /// @dev Validates that the new registry's `factory()` view reports this
    ///      contract — otherwise the two are misaligned and the owner-stake binds
    ///      revert `NotFactory`. Strict: any view-call failure also reverts.
    function setGuardianRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert InvalidGuardianRegistry();
        // Require the new registry to either advertise this factory
        // (alignment) or return address(0) (stateless beta stub). Any other
        // non-zero value is a misconfig — fail fast at swap time instead of
        // letting bindOwnerStake / transferOwnerStakeSlot revert silently later.
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

    /// @notice RE-POINT the adapter-selector tier registry pushed into governors
    ///         at `createSyndicate`. The initial value is mandatory and comes
    ///         from `InitParams`, so this is a migration step, not a deploy one.
    ///         Only affects governors created AFTER this call; existing ones are
    ///         rewired via `pushWiring(governor)`.
    /// @dev `address(0)` is legal HERE and nowhere else, and no longer means
    ///      "later governors keep the safe tier-2 default" — since pashov
    ///      finding #1 `createSyndicate` reverts while this is unset, so it is a
    ///      fail-CLOSED kill switch on new syndicates that cannot un-wire an
    ///      existing governor. Codeless is refused: an EOA passes every
    ///      zero-check, then reverts the batch guard's typed `isCallableTarget`
    ///      call and bricks every vault it reaches. Cf. `setExecutorImpl`.
    function setTierRegistry(address newRegistry) external onlyOwner {
        if (newRegistry != address(0) && newRegistry.code.length == 0) revert TierRegistryNotWired();
        address old = tierRegistry;
        tierRegistry = newRegistry;
        emit TierRegistrySet(old, newRegistry);
    }

    /// @notice Set the aggregate-exposure ledger pushed into governors at
    ///         `createSyndicate`. `address(0)` is tolerated — it disables the
    ///         covered-TVL cap and the risk-scaled proposer bond for governors
    ///         created afterward. Existing governors are rewired via `pushWiring`.
    /// @dev WIRING ORDER: seed the ledger's asset feeds and covered-TVL cap BEFORE
    ///      wiring it here — the governor's gates are fail-closed, so a
    ///      wired-but-unseeded ledger bricks `propose`.
    function setExposureLedger(address newLedger) external onlyOwner {
        address old = exposureLedger;
        exposureLedger = newLedger;
        emit ExposureLedgerSet(old, newLedger);
    }

    /// @notice Set the proposer-bond escrow pushed into governors at
    ///         `createSyndicate`. `address(0)` is tolerated — it disables the
    ///         proposer bond for governors created afterward. Existing governors
    ///         are rewired via `pushWiring`.
    /// @dev The escrow slot is CUSTODIAL — re-point it only at zero outstanding
    ///      bonds. Bonds already locked are released against the escrow recorded
    ///      per proposal, so re-pointing does not strand them, but it does split
    ///      custody across two escrows.
    function setBondEscrow(address newEscrow) external onlyOwner {
        address old = bondEscrow;
        bondEscrow = newEscrow;
        emit BondEscrowSet(old, newEscrow);
    }

    /// @notice Whether `governor` is a per-vault governor deployed by THIS factory.
    /// @dev Derived from the existing `_governorOf` bookkeeping rather than a new
    ///      membership set, which would only be populated by future
    ///      `createSyndicate` calls and so answer `false` for exactly the
    ///      pre-upgrade governors `pushWiring` exists to rescue. The round-trip
    ///      `governor.vault() -> _governorOf[vault]` is unforgeable, since
    ///      `_governorOf` only ever holds proxies this factory deployed.
    function isFactoryGovernor(address governor) public view returns (bool) {
        return _isFactoryGovernor(governor);
    }

    /// @notice Push the factory's CURRENT `tierRegistry`, `exposureLedger` and
    ///         `bondEscrow` into an EXISTING governor deployed by this factory.
    /// @dev Closes the governor-predates-the-registry gap: the `createSyndicate`
    ///      push only reaches governors created AFTER the addresses were set, so
    ///      without this a governor deployed before the registries existed would
    ///      run batches unguarded forever, its own setters being `onlyFactory`.
    /// @dev Unset factory slots are SKIPPED, never written as zero — this can only
    ///      add wiring, never silently un-wire a governor.
    /// @param governor A per-vault governor proxy deployed by this factory.
    function pushWiring(address governor) external onlyOwner {
        if (!_isFactoryGovernor(governor)) revert NotFactoryGovernor();
        if (tierRegistry != address(0)) ISyndicateGovernor(governor).setTierRegistry(tierRegistry);
        if (exposureLedger != address(0)) ISyndicateGovernor(governor).setExposureLedger(exposureLedger);
        if (bondEscrow != address(0)) ISyndicateGovernor(governor).setBondEscrow(bondEscrow);
        emit WiringPushed(governor);
    }

    /// @dev See `isFactoryGovernor`. `try/catch` (plus the code-length probe)
    ///      turns an EOA or a non-governor contract into `false` instead of a
    ///      bare decode revert, so the caller sees `NotFactoryGovernor`.
    function _isFactoryGovernor(address governor) internal view returns (bool) {
        if (governor == address(0) || governor.code.length == 0) return false;
        address boundVault;
        try ISyndicateGovernor(governor).vault() returns (address v) {
            boundVault = v;
        } catch {
            return false;
        }
        return boundVault != address(0) && _governorOf[boundVault] == governor;
    }

    /// @notice Transfer a vault's ownership to `newOwner` and rebind the owner-stake
    ///         slot in the guardian registry.
    /// @dev Auth: `msg.sender` must be the vault's current owner OR the original
    ///      syndicate creator — restricting this to the factory owner alone would
    ///      let it unilaterally reassign vault control. Requires the old owner to
    ///      have already unstaked, or rotating would strand the old stake, and is
    ///      forbidden while any proposal binds the vault, or the new owner would
    ///      inherit `pause()` and other owner-only powers mid-flight.
    /// @dev INCOMING-OWNER CONSENT REQUIRED. `newOwner` must first call
    ///      `approveOwnerStakeBinding(vault)` on sWOOD, or this reverts
    ///      `BindingNotApproved`. Rotation is not a bare title assignment: it
    ///      SPENDS `newOwner`'s escrowed prepared stake. The auth above covers only
    ///      the outgoing side, so without that opt-in the owner of any vault with
    ///      an empty bond slot could bind a stranger's escrow to it. Consent is
    ///      enforced at the sWOOD spend site rather than here, so any future
    ///      factory route into `transferOwnerStakeSlot` inherits it.
    /// @dev UX consequence: rotation is two transactions across two contracts. The
    ///      approval is single-use and revocable until consumed. A missing approval
    ///      reverts the WHOLE call, so the `rotateOwnership` performed just before
    ///      it unwinds atomically.
    function rotateOwner(address vault, address newOwner) external {
        if (newOwner == address(0)) revert ZeroAddress();
        uint256 syndicateId = vaultToSyndicate[vault];
        if (syndicateId == 0) revert VaultNotDeployed();

        address currentOwner = SyndicateVault(payable(vault)).owner();
        if (msg.sender != currentOwner && msg.sender != syndicates[syndicateId].creator) {
            revert NotVaultOwnerOrCreator();
        }

        IGuardianRegistry reg = IGuardianRegistry(guardianRegistry);
        // Registry exposes no `hasOwnerStake` view; inline the equivalent check.
        if (reg.ownerStake(vault) > 0) revert VaultStillStaked();
        ISyndicateGovernor gov = ISyndicateGovernor(_governorOf[vault]);
        if (gov.getActiveProposal() != 0) revert ProposalActive();
        if (gov.openProposalCount() != 0) revert ProposalsOpen();

        SyndicateVault(payable(vault)).rotateOwnership(newOwner);
        // Owner-stake slot lives on sWOOD.
        reg.swood().transferOwnerStakeSlot(vault, newOwner);

        // Keep creator record in sync so downstream invariants (e.g. NotCreator
        // gates on updateMetadata / deactivate) follow the active owner.
        syndicates[vaultToSyndicate[vault]].creator = newOwner;

        emit OwnerRotated(vault, newOwner);
    }

    /// @notice Upgrade a vault to a new implementation. Callable by the vault owner.
    /// @dev Factory upgrades must be enabled and `vaultImpl` must equal
    ///      `expectedImpl`, which prevents a factory owner from calling
    ///      `setVaultImpl` between the creator deciding to upgrade and the upgrade
    ///      tx landing.
    /// @param vault The vault proxy to upgrade.
    /// @param expectedImpl The implementation the creator expects to be applied.
    function upgradeVault(address vault, address expectedImpl) external {
        if (!upgradesEnabled) revert UpgradesDisabled();
        uint256 syndicateId = vaultToSyndicate[vault];
        if (syndicateId == 0) revert VaultNotDeployed();
        if (syndicates[syndicateId].creator != msg.sender) revert NotCreator();
        if (vaultImpl != expectedImpl) revert VaultImplMismatch();
        // `getActiveProposal` is set only on the Executed transition, while Draft /
        // Pending / GuardianReview / Approved keep `openProposalCount > 0`. Without
        // the `openProposalCount` gate the creator could swap implementations
        // mid-vote, so LPs would have approved strategy X against impl A but
        // execute under impl B. Split into two errors so tooling can tell which
        // gate fired.
        address gov_ = _governorOf[vault];
        if (gov_ != address(0)) {
            ISyndicateGovernor gov = ISyndicateGovernor(gov_);
            if (gov.getActiveProposal() != 0) revert StrategyActive();
            if (gov.openProposalCount() != 0) revert ProposalsOpen();
        }
        UUPSUpgradeable(vault).upgradeToAndCall(vaultImpl, "");
        emit VaultUpgraded(vault, vaultImpl);
    }

    // ==================== VIEWS ====================

    /// @notice The per-vault governor proxy for `vault` (address(0) if none).
    ///         The vault resolves its own governor through this view; sWOOD and
    ///         off-chain tooling do the same.
    function governorOf(address vault) external view returns (address) {
        return _governorOf[vault];
    }

    /// @notice Check if a subdomain is available for registration
    function isSubdomainAvailable(string calldata subdomain) external view returns (bool) {
        return subdomainToSyndicate[subdomain] == 0
            && (address(ensRegistrar) == address(0) || ensRegistrar.available(subdomain));
    }

    /// @notice Get active syndicates with pagination.
    /// @dev    Backed by an `EnumerableSet` so reads are O(limit), and `limit` is
    ///         hard-capped at `MAX_PAGE_LIMIT` to keep the call well below block
    ///         gas as the set grows.
    /// @param offset Starting index (0-based) into the active set.
    /// @param limit  Maximum results; clamped to `MAX_PAGE_LIMIT`.
    /// @return result Active syndicates, in insertion order with swap-pop gaps.
    /// @return total  Total count of active syndicates.
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
