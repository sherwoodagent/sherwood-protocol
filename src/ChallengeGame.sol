// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IChallengeGame} from "./interfaces/IChallengeGame.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";

/// @dev Narrow tier-registry surface: the game may REVOKE a certification on a
///      passed challenge and nothing else (spec §3.4, decision D7). A role
///      rather than registry ownership, so it can never grant one.
interface ITierRegistryDemoterMinimal {
    function demoteByChallenge(address target, bytes4 selector) external;
}

/**
 * @title ChallengeGame
 * @notice The challenge trigger of the guardian economic-security model
 *         (spec 2026-07-22 §3.4). Anyone may post a bonded challenge against
 *         an executed proposal, citing one of the five predicates and an
 *         evidence pointer. Filing freezes the coverage that proposal's
 *         approvers committed, so the accused cannot recycle that budget while
 *         under challenge.
 *
 * @dev    THERE IS NO ON-CHAIN PREDICATE VERIFICATION, and that is deliberate
 *         (decision D1). §3.4 adjudicates by SILENCE — "undisputed challenge →
 *         slash auto-executes after a delay; disputed → escalates to §3.5" —
 *         and never asks the chain to verify anything. Only predicates 1, 4
 *         and 5 could be checked on-chain at all; 2 needs a venue-specific
 *         fair-value model and 3 is a funding-graph question. Enforcing some
 *         in code and the rest by judges would run two security models inside
 *         one mechanism, so all five take the identical path here and the
 *         `Predicate` enum is a label carried in the event, nothing more.
 *
 * @dev    THE CONSEQUENCE, stated rather than discovered: vigilance cost moves
 *         to guardians. A guardian that sleeps through the dispute window is
 *         slashed on an unproven assertion. What holds that in check is the
 *         challenger's bond — sized to the coverage it freezes (D4) and
 *         forfeited to the accused when a challenge fails — plus a dispute
 *         window generous relative to the auto-slash delay.
 *
 * @dev    Plain `Ownable2Step`, NOT upgradeable — same shape as `TierRegistry`
 *         and `ExposureLedger`, so its storage layout is unconstrained.
 *
 * @dev    Integration requirement: WOOD must be a standard ERC20 — no transfer
 *         fee, no rebasing, no hooks. A fee-on-transfer token would make the
 *         recorded bonds exceed the held balance.
 */
contract ChallengeGame is Ownable2Step, IChallengeGame {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Bond currency for both the challenger's bond and the accused's
    ///         counter-bond.
    IERC20 public immutable wood;

    /// @notice Source of truth for WHO covered a proposal and for how much, and
    ///         the contract whose coverage this game freezes (spec §3.4 freeze
    ///         scope: per-proposal, never whole-stake). This game must be the
    ///         ledger's `coverageFreezer`.
    IExposureLedger public exposureLedger;

    /// @notice Adapter certification registry. Read on the PASSED-challenge
    ///         path only (§3.4: "adapters demote only on a passed challenge");
    ///         this game must be its `authorizedDemoter`.
    ITierRegistryDemoterMinimal public tierRegistry;

    /// @notice How long after execution a proposal remains challengeable
    ///         (spec §5: 14d initial, matching the ledger's coverage window —
    ///         coverage that has expired out of the exposure buckets can no
    ///         longer be meaningfully frozen).
    uint256 public challengeWindow = 14 days;

    /// @notice Challenger bond as bps of the USD coverage a filing freezes
    ///         (spec §3.4/§5). Load-bearing: with no proof required this is the
    ///         only cost of a frivolous filing, and a failed challenge forfeits
    ///         it to the accused approvers.
    uint256 public challengerBondBps = 500;

    uint256 public challengeCount;

    mapping(uint256 challengeId => Challenge) internal _challenges;

    /// @dev The most recent challenge against a proposal. Only meaningful while
    ///      that challenge is still live — `_liveChallengeId` re-checks status
    ///      rather than trusting the pointer, so a terminal challenge never
    ///      blocks a later, legitimate one.
    mapping(bytes32 reviewKey => uint256 challengeId) internal _lastChallenge;

    constructor(address initialOwner, address wood_, address exposureLedger_, address tierRegistry_)
        Ownable(initialOwner)
    {
        if (wood_ == address(0) || exposureLedger_ == address(0) || tierRegistry_ == address(0)) revert ZeroAddress();
        wood = IERC20(wood_);
        exposureLedger = IExposureLedger(exposureLedger_);
        tierRegistry = ITierRegistryDemoterMinimal(tierRegistry_);
    }

    /// @dev Same derivation as `ExposureLedger` and `GuardianRegistry`.
    function _reviewKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }

    // ── Filing ──

    /// @inheritdoc IChallengeGame
    /// @dev The predicate is recorded and emitted but never read: see the
    ///      contract-level note and D1. Adding a branch here — for any
    ///      predicate — reintroduces the two-security-models problem this
    ///      design exists to avoid.
    /// @dev CEI: the challenge is recorded before the freeze and before the
    ///      bond transfer, so neither external call can observe or re-enter a
    ///      half-written challenge.
    function file(address governor, uint256 proposalId, Predicate predicate, string calldata evidenceURI)
        external
        returns (uint256 challengeId)
    {
        // A challenge accuses an EXECUTED proposal: there is no drain to allege
        // before execution, and `executedAt` is what §3.8's pre-drain snapshot
        // is derived from on the slash path.
        uint256 executedAt = ISyndicateGovernor(governor).getProposal(proposalId).executedAt;
        if (executedAt == 0) revert NotExecuted();
        if (block.timestamp > executedAt + challengeWindow) revert WindowClosed();

        bytes32 key = _reviewKey(governor, proposalId);
        // One live challenge per proposal — a second would double-freeze and
        // double-account the same coverage.
        if (_liveChallengeId(key) != 0) revert AlreadyChallenged();

        // The accused set is the ledger's committed approvers (D2): slashing
        // exactly those is what makes §2's inequality hold, because recovery is
        // the sum of THEIR bonds. A released commitment reports zero, so it
        // contributes nothing to the frozen total.
        (, uint256[] memory committedUsd) = exposureLedger.approversOf(governor, proposalId);
        uint256 coverageUsd;
        for (uint256 i = 0; i < committedUsd.length; i++) {
            coverageUsd += committedUsd[i];
        }
        if (coverageUsd == 0) revert NothingToFreeze();

        // D4: the bond scales with the exposure the filing freezes, converted
        // at the ledger's conservative haircut price. Fail-closed on an unset
        // price and on a bond that floors to zero — an unpriced or free
        // challenge is a free freeze, which is precisely what the bond exists
        // to prevent.
        uint256 priceX8 = exposureLedger.woodUsdPriceX8();
        if (priceX8 == 0) revert InvalidParameter();
        uint256 bondWood = (((coverageUsd * challengerBondBps) / BPS_DENOMINATOR) * 1e8) / priceX8;
        if (bondWood == 0) revert InvalidParameter();

        challengeId = ++challengeCount;
        _challenges[challengeId] = Challenge({
            governor: governor,
            proposalId: proposalId,
            challenger: msg.sender,
            bondWood: bondWood,
            counterBondWood: 0,
            predicate: predicate,
            status: Status.Filed,
            filedAt: block.timestamp,
            frozenCoverageUsd: coverageUsd
        });
        _lastChallenge[key] = challengeId;

        exposureLedger.freezeCoverage(governor, proposalId);
        wood.safeTransferFrom(msg.sender, address(this), bondWood);
        emit ChallengeFiled(challengeId, governor, proposalId, msg.sender, predicate, bondWood, evidenceURI);
    }

    // ── Views ──

    /// @inheritdoc IChallengeGame
    function challengeOf(uint256 challengeId) external view returns (Challenge memory) {
        return _challenges[challengeId];
    }

    /// @inheritdoc IChallengeGame
    function liveChallengeOf(address governor, uint256 proposalId) external view returns (uint256) {
        return _liveChallengeId(_reviewKey(governor, proposalId));
    }

    function _liveChallengeId(bytes32 key) internal view returns (uint256) {
        uint256 id = _lastChallenge[key];
        if (id == 0) return 0;
        Status status = _challenges[id].status;
        return (status == Status.Filed || status == Status.Disputed) ? id : 0;
    }

    // ── Owner setters ──

    function setExposureLedger(address ledger) external onlyOwner {
        if (ledger == address(0)) revert ZeroAddress();
        emit ExposureLedgerSet(address(exposureLedger), ledger);
        exposureLedger = IExposureLedger(ledger);
    }

    function setTierRegistry(address registry) external onlyOwner {
        if (registry == address(0)) revert ZeroAddress();
        emit TierRegistrySet(address(tierRegistry), registry);
        tierRegistry = ITierRegistryDemoterMinimal(registry);
    }

    /// @dev Bounded (0, 90 days]: a zero window makes every proposal
    ///      unchallengeable, and a window far beyond the ledger's coverage
    ///      window would let a filing freeze exposure that has already expired
    ///      out of its epoch buckets.
    function setChallengeWindow(uint256 newWindow) external onlyOwner {
        if (newWindow == 0 || newWindow > 90 days) revert InvalidParameter();
        emit ChallengeWindowSet(challengeWindow, newWindow);
        challengeWindow = newWindow;
    }

    /// @dev Bounded (0, 10_000]: zero would make filing free, and therefore the
    ///      freeze free (D4).
    function setChallengerBondBps(uint256 newBps) external onlyOwner {
        if (newBps == 0 || newBps > BPS_DENOMINATOR) revert InvalidParameter();
        emit ChallengerBondBpsSet(challengerBondBps, newBps);
        challengerBondBps = newBps;
    }
}
