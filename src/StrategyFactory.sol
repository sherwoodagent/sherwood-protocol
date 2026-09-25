// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IStrategyFactory} from "./interfaces/IStrategyFactory.sol";

/// @notice Minimal view surface needed to gate clone calls on registered vaults.
interface ISyndicateRegistry {
    function vaultToSyndicate(address vault) external view returns (uint256);
}

/// @title StrategyFactory
/// @notice Atomic clone + initialize wrapper for strategy templates.
///
///         Strategy templates use a custom `_initialized` flag (not OZ
///         Initializable) and run `initialize` from an `external` function;
///         deploying a clone via `Clones.clone(template)` followed by a
///         separate `initialize` tx exposes a front-running window where an
///         attacker can race the init and bind the clone to their own vault.
///
///         This factory bundles both into a single tx.
///
///         Cloning is permissionless: anyone may clone an approved template
///         bound to a registered vault, naming themselves as proposer. A clone
///         is only ever executed by that vault's governor through a proposal
///         its agents write, priced at the template's class tier.
///
///         `template` is gated by an owner-managed allowlist: an unlisted
///         template reverts here, so this factory never clones an
///         attacker-controlled contract. `cloneTemplate` records which template
///         each clone came from, and `TierRegistry._classOf` requires that
///         record to name the class's anchored template, so a clone this
///         factory did not produce is not a class member.
///
///           - `setTemplateApproval(t, false)` stops NEW clones through this
///             factory only; `TierRegistry.demoteClass` re-prices the ones
///             already minted.
///           - The class path's safety rests on a TEMPLATE invariant, checked
///             at certification review rather than enforced by code: every
///             certified template must derive its fund destination and its
///             counterparty allowlist from `vault()` (as `BaseStrategy` and
///             the shipped templates do) and expose no payout / recipient /
///             router address settable from `initialize` or `updateParams`
///             data. See `TierRegistry.proposeClassCertification`.
contract StrategyFactory is Ownable, IStrategyFactory {
    /// @notice SyndicateFactory used to verify that `vault` is a registered vault.
    /// @dev Immutable: set once at construction. The vault-registered check is
    ///      meaningless if the registry it consults can be hot-swapped.
    address public immutable syndicateFactory;

    /// @notice Owner-managed allowlist of strategy templates
    ///         that may be cloned through this factory. Default: empty
    ///         (everything reverts). The owner (deployer / Sherwood multisig)
    ///         adds the canonical templates (Aerodrome / Moonwell / Portfolio
    ///         / HL Grid / HL Perp / WstETH / Mamo) at deploy.
    mapping(address template => bool approved) public approvedTemplate;

    /// @notice Template `clone` was deployed from; `address(0)` when this
    ///         factory did not deploy it.
    mapping(address clone => address template) public cloneTemplate;

    /// @notice Registered strategies and the code they were registered with.
    mapping(address strategy => bool registered) public registeredStrategy;
    mapping(address strategy => bytes32 codehash) public registeredCodehash;

    error VaultNotRegistered();
    /// @notice `registerStrategy` was given a codeless address or one that does not answer
    ///         `IStrategy`'s `vault()`, `proposer()` and `executed()`.
    error NotAStrategy(address strategy);
    error InvalidSyndicateFactory();
    /// @notice `template` is not on the allowlist.
    error TemplateNotApproved(address template);
    /// @notice `proposer` arg to `cloneAndInit` / `cloneAndInitDeterministic`
    ///         must equal `msg.sender` so the strategy's stored `_proposer` is
    ///         the deployer (a known authorized address), not an arbitrary
    ///         external address that could retain `onlyProposer` mutation
    ///         rights post-execution.
    error ProposerMustBeSender();

    event StrategyCloned(address indexed template, address indexed vault, address indexed clone);
    event TemplateApprovalSet(address indexed template, bool approved);
    event StrategyRegistered(address indexed strategy, bytes32 codehash);

    constructor(address syndicateFactory_, address owner_) Ownable(owner_) {
        if (syndicateFactory_ == address(0)) revert InvalidSyndicateFactory();
        syndicateFactory = syndicateFactory_;
    }

    /// @notice Toggle a strategy template in the allowlist. Owner-only.
    function setTemplateApproval(address template, bool approved) external onlyOwner {
        approvedTemplate[template] = approved;
        emit TemplateApprovalSet(template, approved);
    }

    /// @notice Register a hand-written strategy. Permissionless: registration fixes the shape a
    ///         batch target has (`IStrategy`) so guardians can simulate it; it is not a trust check.
    function registerStrategy(address strategy) external {
        if (strategy.code.length == 0) revert NotAStrategy(strategy);
        _mustAnswer(strategy, IStrategy.vault.selector);
        _mustAnswer(strategy, IStrategy.proposer.selector);
        _mustAnswer(strategy, IStrategy.executed.selector);
        _register(strategy);
    }

    /// @inheritdoc IStrategyFactory
    /// @dev A code change after registration de-registers.
    function isRegisteredStrategy(address strategy) external view returns (bool) {
        return registeredStrategy[strategy] && strategy.codehash == registeredCodehash[strategy];
    }

    function _register(address strategy) private {
        registeredStrategy[strategy] = true;
        registeredCodehash[strategy] = strategy.codehash;
        emit StrategyRegistered(strategy, strategy.codehash);
    }

    /// @dev Fail-closed conformance probe: the getter must answer exactly one word.
    function _mustAnswer(address strategy, bytes4 selector) private view {
        (bool ok, bytes memory ret) = strategy.staticcall(abi.encodeWithSelector(selector));
        if (!ok || ret.length != 32) revert NotAStrategy(strategy);
    }

    /// @dev The vault is a registered Sherwood vault: provenance only ever names real vaults.
    function _requireRegisteredVault(address vault) internal view {
        if (ISyndicateRegistry(syndicateFactory).vaultToSyndicate(vault) == 0) {
            revert VaultNotRegistered();
        }
    }

    /// @dev Gate the template against the allowlist.
    function _authTemplate(address template) internal view {
        if (!approvedTemplate[template]) revert TemplateNotApproved(template);
    }

    /// @notice Clone `template` and run `initialize(vault, proposer, data)` atomically.
    /// @param template Strategy template address. MUST be on the allowlist.
    /// @param vault    Vault that will own the clone's lifecycle. Registered on
    ///                 `syndicateFactory`.
    /// @param proposer Strategy proposer. MUST equal `msg.sender` (see the
    ///                 dev comment below for the rationale).
    /// @param data     Strategy-specific init bytes (decoded inside `_initialize`).
    /// @return clone   Address of the cloned + initialized strategy.
    /// @dev `proposer == msg.sender` ties the clone's stored `_proposer` to the
    ///      deployer, so `onlyProposer` rights cannot be handed to a third party.
    function cloneAndInit(address template, address vault, address proposer, bytes calldata data)
        external
        returns (address clone)
    {
        _requireRegisteredVault(vault);
        _authTemplate(template);
        if (proposer != msg.sender) revert ProposerMustBeSender();
        clone = Clones.clone(template);
        cloneTemplate[clone] = template;
        _register(clone);
        IStrategy(clone).initialize(vault, proposer, data);
        emit StrategyCloned(template, vault, clone);
    }

    /// @notice Deterministic variant — caller can predict the clone address via
    ///         `Clones.predictDeterministicAddress(template, keccak256(abi.encode(vault, salt)), factory)`.
    /// @dev See `cloneAndInit` for the `proposer == msg.sender` rationale.
    /// @dev The CREATE2 salt is bound to `vault`
    ///      (`keccak256(abi.encode(vault, salt))`) so each vault gets its own
    ///      address namespace. `salt` is visible in calldata; without this a
    ///      front-runner could race the deploy and occupy the predicted address
    ///      with a clone bound to their own vault — a recoverable DoS that would
    ///      brick a keyless propose referencing it. The off-chain predictor
    ///      mirrors this byte-for-byte (SDK `effectiveStrategySalt`); the two
    ///      MUST stay in lockstep or predictions diverge from the deployed address.
    function cloneAndInitDeterministic(
        address template,
        address vault,
        address proposer,
        bytes calldata data,
        bytes32 salt
    ) external returns (address clone) {
        _requireRegisteredVault(vault);
        _authTemplate(template);
        if (proposer != msg.sender) revert ProposerMustBeSender();
        clone = Clones.cloneDeterministic(template, keccak256(abi.encode(vault, salt)));
        cloneTemplate[clone] = template;
        _register(clone);
        IStrategy(clone).initialize(vault, proposer, data);
        emit StrategyCloned(template, vault, clone);
    }
}
