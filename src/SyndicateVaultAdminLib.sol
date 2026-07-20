// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISyndicateVault} from "./interfaces/ISyndicateVault.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title SyndicateVaultAdminLib
 * @notice Cold-path admin logic (depositor whitelist + agent management)
 *         extracted from `SyndicateVault` to free EIP-170 runtime headroom.
 *
 *   Deployed once and DELEGATECALLed (Foundry auto-links, same idiom as
 *   `LeveragedAeroManager`). Every function runs in the calling vault's storage
 *   context: the vault passes its own storage (`EnumerableSet.AddressSet` /
 *   `mapping`) by reference, so the state stays declared in — and owned by —
 *   the vault. Its storage layout is unchanged.
 *
 *   TRUST BOUNDARY: this library performs NO access control. The vault keeps
 *   every `onlyOwner` / factory check on the calling wrapper and only
 *   delegatecalls here for the body logic, so the access model is identical to
 *   the pre-extraction inline code. Errors and events are referenced from
 *   `ISyndicateVault`, so selectors (revert data) and topic0 (log signatures)
 *   are byte-identical to what the vault emitted before.
 */
library SyndicateVaultAdminLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Mirrors `SyndicateVault.MAX_PAGE_LIMIT` (the vault keeps the public
    ///      constant getter). Kept in sync by hand — both are compile-time.
    uint256 internal constant MAX_PAGE_LIMIT = 100;

    /// @dev Mirrors `SyndicateVault.MAX_AGENTS_PER_VAULT`.
    uint256 internal constant MAX_AGENTS_PER_VAULT = 32;

    // ==================== DEPOSITOR WHITELIST ====================

    /// @dev Body of `SyndicateVault.approveDepositor` (owner-gated on the vault side).
    function approveDepositor(EnumerableSet.AddressSet storage approvedDepositors, address depositor) external {
        if (depositor == address(0)) revert ISyndicateVault.InvalidDepositor();
        if (!approvedDepositors.add(depositor)) revert ISyndicateVault.DepositorAlreadyApproved();
        emit ISyndicateVault.DepositorApproved(depositor);
    }

    /// @dev Body of `SyndicateVault.removeDepositor`.
    function removeDepositor(EnumerableSet.AddressSet storage approvedDepositors, address depositor) external {
        if (!approvedDepositors.remove(depositor)) revert ISyndicateVault.DepositorNotApproved();
        emit ISyndicateVault.DepositorRemoved(depositor);
    }

    /// @dev Body of `SyndicateVault.approveDepositors`.
    function approveDepositors(EnumerableSet.AddressSet storage approvedDepositors, address[] calldata depositors)
        external
    {
        for (uint256 i = 0; i < depositors.length; i++) {
            if (depositors[i] == address(0)) revert ISyndicateVault.InvalidDepositor();
            approvedDepositors.add(depositors[i]);
            emit ISyndicateVault.DepositorApproved(depositors[i]);
        }
    }

    // ==================== AGENT MANAGEMENT ====================

    /// @dev Body of `SyndicateVault.registerAgent`. `vaultOwner` is `owner()`
    ///      read on the vault side and passed in so the NFT-owner check is
    ///      unchanged; `agentRegistry` is the vault's `_agentRegistry`.
    function registerAgent(
        mapping(address => ISyndicateVault.AgentConfig) storage agents,
        EnumerableSet.AddressSet storage agentSet,
        uint256 agentId,
        address agentAddress,
        IERC721 agentRegistry,
        address vaultOwner
    ) external {
        if (agentAddress == address(0)) revert ISyndicateVault.ZeroAddress();
        if (agents[agentAddress].active) revert ISyndicateVault.AgentAlreadyRegistered();
        // PR #324 review R4: bound `agentSet` so `rotateOwnership`'s deactivation
        // loop (Sherlock #38) can't OOG. `removeAgent` frees a slot.
        if (agentSet.length() >= MAX_AGENTS_PER_VAULT) revert ISyndicateVault.AgentCapExceeded();

        // Verify ERC-8004 identity (skipped on chains without agent registry)
        if (address(agentRegistry) != address(0)) {
            address nftOwner = agentRegistry.ownerOf(agentId);
            if (nftOwner != agentAddress && nftOwner != vaultOwner) revert ISyndicateVault.NotAgentOwner();
        }

        agents[agentAddress] = ISyndicateVault.AgentConfig({agentId: agentId, agentAddress: agentAddress, active: true});

        agentSet.add(agentAddress);

        emit ISyndicateVault.AgentRegistered(agentId, agentAddress);
    }

    /// @dev Body of `SyndicateVault.removeAgent`. Full-deletes the struct (V-M5)
    ///      so a stale `agentId` can't be silently reused.
    function removeAgent(
        mapping(address => ISyndicateVault.AgentConfig) storage agents,
        EnumerableSet.AddressSet storage agentSet,
        address agentAddress
    ) external {
        if (!agents[agentAddress].active) {
            revert ISyndicateVault.AgentNotActive();
        }

        delete agents[agentAddress];
        agentSet.remove(agentAddress);

        emit ISyndicateVault.AgentRemoved(agentAddress);
    }

    /// @dev Agent-drain loop of `SyndicateVault.rotateOwnership` (Sherlock #38 v2).
    ///      The vault retains the factory-only check and `_transferOwnership`.
    ///      Snapshot via `.values()` first so the in-loop `remove` doesn't
    ///      invalidate iteration (OZ swap-and-pop on `at(i)`).
    function drainAgents(
        mapping(address => ISyndicateVault.AgentConfig) storage agents,
        EnumerableSet.AddressSet storage agentSet
    ) external {
        address[] memory snap = agentSet.values();
        uint256 n = snap.length;
        for (uint256 i; i < n; ++i) {
            address a = snap[i];
            delete agents[a];
            agentSet.remove(a);
            emit ISyndicateVault.AgentRemoved(a);
        }
    }

    // ==================== PAGINATION ====================

    /// @dev Body of the vault's `_pageAddresses` (V-M3): a slice
    ///      `[offset, offset + min(limit, MAX_PAGE_LIMIT))` clipped to the set's
    ///      length. Returns an empty array when `offset >= length`. Shared by
    ///      `approvedDepositorsPaginated` / `agentsPaginated`.
    function pageAddresses(EnumerableSet.AddressSet storage set, uint256 offset, uint256 limit)
        external
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
}
