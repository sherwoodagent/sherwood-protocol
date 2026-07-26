// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ICoverageEpochs} from "./interfaces/ICoverageEpochs.sol";
import {IPriceRouter} from "./interfaces/IPriceRouter.sol";
import {IExposureLedger} from "./interfaces/IExposureLedger.sol";
import {ISyndicateGovernor} from "./interfaces/ISyndicateGovernor.sol";

/**
 * @title CoverageEpochs
 * @notice Per-strategy coverage epochs for the guardian economic-security model
 *         (spec 2026-07-22 §3.4a). A cover pins a baseline NAV when a strategy
 *         proposal executes; later tasks checkpoint NAV at each epoch boundary,
 *         evaluate cumulative drawdown against the proposal's declared
 *         envelope, accept renewal commitments for the next epoch, and flag an
 *         un-renewable cover for wind-down.
 *
 *         The point of epochs is claims-made attribution: liability for a
 *         drawdown breach attaches to the guardians covering the epoch the
 *         breach SURFACES on, so no guardian is committed for longer than one
 *         epoch plus the challenge window however long the strategy runs.
 *
 * @dev    NAV SOURCE — THE RULE THIS CONTRACT EXISTS TO HOLD (D1). Every NAV
 *         read goes through `IPriceRouter.valueStrategy(strategy)` and fails
 *         CLOSED when `instantOK == false`. `SyndicateVault.totalAssets()` is
 *         never read, and must never be: it is `idle float + liveNav`, and the
 *         vault's `_laneState()` deliberately leaves `liveNav` at ZERO whenever
 *         the router cannot price the strategy —
 *
 *             try IPriceRouter(pr).valueStrategy(active) returns (uint256 v, bool ok) {
 *                 if (ok) { liveNav = v; laneA = true; }
 *             } catch {}
 *
 *         — which is correct for the vault (it falls back to a float-only NAV
 *         and routes LP flow through the async queue) and catastrophic as a
 *         checkpoint. A baseline or checkpoint taken from `totalAssets()`
 *         during a router outage would record a ~100% loss, breach the
 *         drawdown envelope, and expose honest guardians to a full slash over
 *         an oracle hiccup. Refusing to act on an unpriceable strategy is the
 *         only safe reading: D6 winds such a cover down rather than slashing
 *         anyone for a number nobody could establish.
 *
 * @dev    NOT UPGRADEABLE (plain `Ownable2Step`), so the storage layout is
 *         unconstrained and no golden pins it. Stated plainly rather than
 *         implying a layout check covers it.
 *
 * @dev    HOLDS NO TOKENS AND MOVES NO FUNDS, EVER (D7). There is no transfer
 *         surface, no `receive`, and no rescue path, because there is nothing
 *         to rescue. Wind-down seizes nothing: it flags a cover so the
 *         settlement path that already exists in `SyndicateGovernor` becomes
 *         permissionlessly callable ahead of `strategyDuration`.
 */
contract CoverageEpochs is Ownable2Step, ICoverageEpochs {
    /// @dev Basis-point denominator. Also the passive-mandate threshold: an
    ///      envelope of exactly `10_000` declared the full notional as its
    ///      bound, so it checkpoints but can never breach (D5).
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice The only NAV oracle this contract will consult (D1).
    IPriceRouter public immutable priceRouter;

    /// @notice Source of the epoch schedule, of the approver set behind epoch-0
    ///         attribution, and of the aggregate exposure a renewal books.
    /// @dev Must be the same ledger `ChallengeGame` reads: two ledgers would
    ///      mean two different accused sets for one proposal.
    IExposureLedger public immutable exposureLedger;

    mapping(bytes32 coverKey => Cover) internal _covers;

    /// @param initialOwner    owner of the parameter setters later tasks add
    /// @param priceRouter_    the router the vault's Lane A already trusts
    /// @param exposureLedger_ the ledger `ChallengeGame` reads
    constructor(address initialOwner, address priceRouter_, address exposureLedger_) Ownable(initialOwner) {
        if (priceRouter_ == address(0) || exposureLedger_ == address(0)) revert ZeroAddress();
        priceRouter = IPriceRouter(priceRouter_);
        exposureLedger = IExposureLedger(exposureLedger_);
    }

    // ── Cover lifecycle ──

    /// @inheritdoc ICoverageEpochs
    function openCover(address governor, uint256 proposalId) external {
        bytes32 key = _coverKey(governor, proposalId);
        Cover storage c = _covers[key];
        if (c.opened) revert AlreadyOpened();

        ISyndicateGovernor.StrategyProposal memory p = ISyndicateGovernor(governor).getProposal(proposalId);
        if (p.state != ISyndicateGovernor.ProposalState.Executed) revert NotExecuted();
        if (p.strategy == address(0)) revert NoStrategy();

        // D1: the router, never totalAssets() — a router outage reports
        // float-only NAV, which as a baseline would fabricate a ~100% loss and
        // slash honest guardians for an oracle hiccup. A cover whose
        // denominator cannot be established must not open at all: every later
        // drawdown would be measured against a fiction.
        (uint256 nav, bool ok) = priceRouter.valueStrategy(p.strategy);
        if (!ok) revert NavUnavailable();

        c.governor = governor;
        c.proposalId = proposalId;
        c.strategy = p.strategy;
        // D2: the baseline is what was actually READ, here and now. `openCover`
        // is permissionless and may land blocks after execution, so stamping
        // `executedAt` would back-date a number nobody observed.
        c.openedAt = uint64(block.timestamp);
        // D3: copy the schedule rather than re-reading the ledger on every
        // call. `epochLength` is immutable today, but reading it once means a
        // future ledger re-point cannot retroactively re-slice this cover.
        c.epochLength = uint64(exposureLedger.epochLength());
        c.epochGenesis = uint64(exposureLedger.epochGenesis());
        c.maxDrawdownBps = p.maxDrawdownBps;
        c.baselineNav = nav;
        c.opened = true;

        emit CoverOpened(key, governor, proposalId, p.strategy, nav, p.maxDrawdownBps);
    }

    // ── Views ──

    /// @inheritdoc ICoverageEpochs
    function coverOf(address governor, uint256 proposalId) external view returns (Cover memory) {
        return _covers[_coverKey(governor, proposalId)];
    }

    /// @inheritdoc ICoverageEpochs
    function baselineNavOf(address governor, uint256 proposalId) external view returns (uint256) {
        return _covers[_coverKey(governor, proposalId)].baselineNav;
    }

    /// @inheritdoc ICoverageEpochs
    function epochLengthOf(address governor, uint256 proposalId) external view returns (uint64) {
        return _covers[_coverKey(governor, proposalId)].epochLength;
    }

    /// @inheritdoc ICoverageEpochs
    function epochGenesisOf(address governor, uint256 proposalId) external view returns (uint64) {
        return _covers[_coverKey(governor, proposalId)].epochGenesis;
    }

    /// @inheritdoc ICoverageEpochs
    function maxDrawdownBpsOf(address governor, uint256 proposalId) external view returns (uint16) {
        return _covers[_coverKey(governor, proposalId)].maxDrawdownBps;
    }

    /// @inheritdoc ICoverageEpochs
    function isOpen(address governor, uint256 proposalId) external view returns (bool) {
        return _covers[_coverKey(governor, proposalId)].opened;
    }

    /// @inheritdoc ICoverageEpochs
    function coverKey(address governor, uint256 proposalId) external pure returns (bytes32) {
        return _coverKey(governor, proposalId);
    }

    // ── Internal ──

    /// @dev Same derivation as `ChallengeGame._reviewKey`, `ExposureLedger` and
    ///      `GuardianRegistry`, so a proposal has ONE identity across the whole
    ///      economic-security stack.
    function _coverKey(address governor, uint256 proposalId) internal pure returns (bytes32) {
        return keccak256(abi.encode(governor, proposalId));
    }
}
