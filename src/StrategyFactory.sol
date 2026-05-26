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
///         Sherlock run #1 finding #34 — `template` is gated by an
///         owner-managed allowlist. Pre-fix, `cloneAndInit` accepted any
///         address as a template, so a hostile agent could clone an
///         attacker-controlled contract and route vault assets to it via a
///         governor proposal. The governor doesn't independently validate
///         the strategy address against an implementation registry, so the
///         allowlist here is the single chokepoint.
contract StrategyFactory is Ownable {
    /// @notice SyndicateFactory used to verify that `vault` is a registered vault.
    /// @dev Immutable: set once at construction. A clone-fn caller-vault gate is
    ///      meaningless if the registry it consults can be hot-swapped.
    address public immutable syndicateFactory;

    /// @notice Sherlock #34 — owner-managed allowlist of strategy templates
    ///         that may be cloned through this factory. Default: empty
    ///         (everything reverts). The owner (deployer / Sherwood multisig)
    ///         adds the canonical templates (Aerodrome / Moonwell / Portfolio
    ///         / HL Grid / HL Perp / Venice / WstETH / Mamo) at deploy.
    mapping(address template => bool approved) public approvedTemplate;

    error Unauthorized();
    error VaultNotRegistered();
    error InvalidSyndicateFactory();
    /// @notice Sherlock #34 — `template` is not on the allowlist.
    error TemplateNotApproved(address template);
    /// @notice Sherlock run #2 #9 partial — `proposer` arg to
    ///         `cloneAndInit` / `cloneAndInitDeterministic` must equal
    ///         `msg.sender` so the strategy's stored `_proposer` is the
    ///         deployer (a known authorized address), not an arbitrary
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

    /// @dev Sherlock #34 — gate the template against the allowlist.
    function _authTemplate(address template) internal view {
        if (!approvedTemplate[template]) revert TemplateNotApproved(template);
    }

    /// @notice Clone `template` and run `initialize(vault, proposer, data)` atomically.
    /// @param template Strategy template address. MUST be on the allowlist (Sherlock #34).
    /// @param vault    Vault that will own the clone's lifecycle. MUST equal `msg.sender`.
    /// @param proposer Strategy proposer. MUST equal `msg.sender` (Sherlock run #2 #9
    ///                 partial fix — see contract-level comment for full rationale).
    /// @param data     Strategy-specific init bytes (decoded inside `_initialize`).
    /// @return clone   Address of the cloned + initialized strategy.
    /// @dev Sherlock run #2 #9 partial: requiring `proposer == msg.sender`
    ///      ties the strategy clone's stored `_proposer` to the deployer.
    ///      Closes the audit's specific attack vector (an arbitrary EXTERNAL
    ///      address X retaining `onlyProposer` mutation rights on the live
    ///      strategy) by ensuring `_proposer` is a known authorized address
    ///      (vault owner OR registered agent of this vault) rather than an
    ///      attacker-supplied unknown. Does NOT fully close the
    ///      cross-agent case (agent A deploys, agent B proposes via
    ///      governor → strategy's `_proposer = A` ≠ `proposal.proposer = B`);
    ///      the full fix requires a governor-side `IStrategy.proposer() ==
    ///      msg.sender` check at `propose`, deferred because the ~140 B
    ///      `staticcall` setup doesn't fit governor's +12 B margin without
    ///      ABI-breaking trims. In practice, agents deploy their own
    ///      strategies and propose them, so the partial fix covers the
    ///      common case.
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
    ///         `Clones.predictDeterministicAddress`.
    /// @dev Sherlock run #2 #9 partial — see `cloneAndInit` for the rationale.
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
        clone = Clones.cloneDeterministic(template, salt);
        IStrategy(clone).initialize(vault, proposer, data);
        emit StrategyCloned(template, vault, clone);
    }
}
