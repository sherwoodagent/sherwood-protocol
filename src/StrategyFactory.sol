// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";

/// @notice Minimal view surface needed to gate clone calls on registered vaults.
interface ISyndicateRegistry {
    function vaultToSyndicate(address vault) external view returns (uint256);
}

/// @notice Minimal view surface for agent / owner check.
interface IVaultMembership {
    function isAgent(address agentAddress) external view returns (bool);
    function owner() external view returns (address);
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
///         Strategies must always be pre-deployed by the vault's creator or
///         a registered agent BEFORE proposal execution. The governor itself
///         does not deploy strategies during execute — proposals reference an
///         already-cloned-and-initialized strategy address. Authorized callers:
///
///           - `vault.owner()` (creator pre-deploy);
///           - `vault.isAgent(msg.sender)` (registered agent pre-deploy).
///
///         The vault must additionally be registered on `syndicateFactory` so
///         a rogue contract cannot spoof the membership view.
///
///         `template` is gated by an owner-managed allowlist: an unlisted
///         template reverts here, so this factory never clones an
///         attacker-controlled contract. It is NOT the only chokepoint on what
///         a vault may pay, though: `TierRegistry`'s code-class fallback admits
///         ANY ERC-1167 clone of a class-allowed template as a batch recipient,
///         whether or not this factory produced it (a bare `Clones.clone` +
///         permissionless `initialize` bound to the paying vault is
///         indistinguishable from a factory clone to every on-chain check,
///
///           - `setTemplateApproval(t, false)` stops NEW clones through this
///             factory only. To stop a template's clones from being FUNDED,
///             the owner must also run `TierRegistry.setClassAllowed(t, false)`
///             — the two allowlists must be revoked together.
///           - The class path's safety rests on a TEMPLATE invariant, checked
///             at certification review rather than enforced by code: every
///             certified template must derive its fund destination and its
///             counterparty allowlist from `vault()` (as `BaseStrategy` and
///             the shipped templates do) and expose no payout / recipient /
///             router address settable from `initialize` or `updateParams`
///             data. See `TierRegistry.proposeClassCertification`.
contract StrategyFactory is Ownable {
    /// @notice SyndicateFactory used to verify that `vault` is a registered vault.
    /// @dev Immutable: set once at construction. A clone-fn caller-vault gate is
    ///      meaningless if the registry it consults can be hot-swapped.
    address public immutable syndicateFactory;

    /// @notice Owner-managed allowlist of strategy templates
    ///         that may be cloned through this factory. Default: empty
    ///         (everything reverts). The owner (deployer / Sherwood multisig)
    ///         adds the canonical templates (Aerodrome / Moonwell / Portfolio
    ///         / HL Grid / HL Perp / WstETH / Mamo) at deploy.
    mapping(address template => bool approved) public approvedTemplate;

    error Unauthorized();
    error VaultNotRegistered();
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

    constructor(address syndicateFactory_, address owner_) Ownable(owner_) {
        if (syndicateFactory_ == address(0)) revert InvalidSyndicateFactory();
        syndicateFactory = syndicateFactory_;
    }

    /// @notice Toggle a strategy template in the allowlist. Owner-only.
    function setTemplateApproval(address template, bool approved) external onlyOwner {
        approvedTemplate[template] = approved;
        emit TemplateApprovalSet(template, approved);
    }

    /// @dev Caller is the vault's owner or a registered agent of the vault,
    ///      and the vault is a registered Sherwood vault.
    function _authClone(address vault) internal view {
        if (ISyndicateRegistry(syndicateFactory).vaultToSyndicate(vault) == 0) {
            revert VaultNotRegistered();
        }
        IVaultMembership v = IVaultMembership(vault);
        if (msg.sender == v.owner()) return;
        if (v.isAgent(msg.sender)) return;
        revert Unauthorized();
    }

    /// @dev Gate the template against the allowlist.
    function _authTemplate(address template) internal view {
        if (!approvedTemplate[template]) revert TemplateNotApproved(template);
    }

    /// @notice Clone `template` and run `initialize(vault, proposer, data)` atomically.
    /// @param template Strategy template address. MUST be on the allowlist.
    /// @param vault    Vault that will own the clone's lifecycle. Registered on
    ///                 `syndicateFactory`, and `msg.sender` MUST be its owner or
    ///                 one of its agents (`_authClone`) — never the vault itself.
    /// @param proposer Strategy proposer. MUST equal `msg.sender` (see the
    ///                 dev comment below for the rationale).
    /// @param data     Strategy-specific init bytes (decoded inside `_initialize`).
    /// @return clone   Address of the cloned + initialized strategy.
    /// @dev Requiring `proposer == msg.sender` ties the strategy clone's
    ///      stored `_proposer` to the deployer, closing the attack vector of
    ///      an arbitrary EXTERNAL address X retaining `onlyProposer`
    ///      mutation rights on the live strategy — `_proposer` is a known
    ///      authorized address (vault owner OR registered agent of this
    ///      vault) rather than an attacker-supplied unknown. Does NOT fully
    ///      close the cross-agent case (agent A deploys, agent B proposes via
    ///      governor → strategy's `_proposer = A` ≠ `proposal.proposer = B`);
    ///      the full fix requires a governor-side `IStrategy.proposer() ==
    ///      msg.sender` check at `propose`, deferred because the ~140 B
    ///      `staticcall` setup doesn't fit governor's +12 B margin without
    ///      ABI-breaking trims. In practice, agents deploy their own
    ///      strategies and propose them, so this covers the common case.
    function cloneAndInit(address template, address vault, address proposer, bytes calldata data)
        external
        returns (address clone)
    {
        _authClone(vault);
        _authTemplate(template);
        if (proposer != msg.sender) revert ProposerMustBeSender();
        clone = Clones.clone(template);
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
    ///      brick a keyless propose referencing it. Occupying a vault's address
    ///      requires passing that vault here, which `_authClone`
    ///      only lets the vault's owner / registered agents do. The off-chain
    ///      predictor mirrors this byte-for-byte (SDK `effectiveStrategySalt`);
    ///      the two MUST stay in lockstep or predictions diverge from the
    ///      deployed address.
    function cloneAndInitDeterministic(
        address template,
        address vault,
        address proposer,
        bytes calldata data,
        bytes32 salt
    ) external returns (address clone) {
        _authClone(vault);
        _authTemplate(template);
        if (proposer != msg.sender) revert ProposerMustBeSender();
        clone = Clones.cloneDeterministic(template, keccak256(abi.encode(vault, salt)));
        IStrategy(clone).initialize(vault, proposer, data);
        emit StrategyCloned(template, vault, clone);
    }
}
