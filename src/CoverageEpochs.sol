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

    /// @dev Boundary NAV per COVER-RELATIVE epoch (D8). Sparse on purpose: a
    ///      boundary nobody checkpointed stays EMPTY forever (D4). Back-filling
    ///      it later with a NAV read today would invent an observation for a
    ///      period nobody watched, and would stamp `breachEpoch` with the wrong
    ///      epoch's coverers — the one thing claims-made attribution exists to
    ///      get right.
    mapping(bytes32 coverKey => mapping(uint256 epoch => uint256 nav)) internal _nav;

    /// @dev Whether `epoch`'s boundary was checkpointed. Separate from `_nav`
    ///      because a NAV of zero is a legal reading, and "unobserved" must
    ///      never be confused with "worthless".
    mapping(bytes32 coverKey => mapping(uint256 epoch => bool)) internal _checkpointed;

    /// @dev The most recent checkpointed NAV — the numerator of the drawdown.
    ///      The denominator is always `baselineNav` (D4).
    mapping(bytes32 coverKey => uint256 nav) internal _lastNav;

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

    /// @inheritdoc ICoverageEpochs
    function checkpoint(address governor, uint256 proposalId) external {
        bytes32 key = _coverKey(governor, proposalId);
        Cover storage c = _covers[key];
        // Before this guard `c.epochLength` is zero and `_epochAt` would panic
        // on the division; an unopened cover has no schedule to be at a
        // boundary of.
        if (!c.opened) revert NotOpened();

        // An epoch's boundary is the START of the following epoch, so the first
        // boundary this cover can close is `_boundary(c, openEpoch + 1)`. A
        // cover cannot close an epoch that ended before it existed: one opened
        // mid-epoch waits for its own epoch's boundary, never back-filling the
        // epochs the ledger's absolute schedule already ran through.
        uint256 openEpoch = _epochAt(c, c.openedAt);
        if (block.timestamp < _boundary(c, openEpoch + 1)) revert BoundaryNotReached();

        // The epoch being closed is the one whose boundary just passed — not a
        // cursor position. Filing a NAV read today under an older, skipped
        // epoch would invent an observation for a period nobody watched and
        // stamp `breachEpoch` with an epoch the breach did not surface on. D4
        // is explicit that a missed boundary simply stays uncheckpointed.
        //
        // D8: the INDEX is cover-relative even though the BOUNDARY above is
        // global. `_relativeEpoch` is at least 1 here — the guard just proved
        // the cover's own first boundary has passed — so the subtraction cannot
        // underflow.
        uint256 due = _relativeEpoch(c, block.timestamp) - 1;
        if (_checkpointed[key][due]) revert AlreadyCheckpointed();

        // D1: the router, never totalAssets(). A router outage reports a
        // float-only NAV whose `liveNav` is silently zero — recorded as a
        // checkpoint that is a ~100% loss, and the epoch's coverers get slashed
        // over an oracle hiccup. Refuse instead; D6 winds down a cover that
        // stays unpriceable past the grace window.
        (uint256 nav, bool ok) = priceRouter.valueStrategy(c.strategy);
        if (!ok) revert NavUnavailable();

        _nav[key][due] = nav;
        _checkpointed[key][due] = true;
        _lastNav[key] = nav;
        c.lastCheckpointedEpoch = uint64(due);

        uint256 lossBps = cumulativeLossBps(governor, proposalId);
        emit Checkpointed(key, due, nav, lossBps);

        // D5: a passive mandate (envelope 10_000) declared the full notional as
        // its bound. It checkpoints so §6 monitoring sees the NAV, but it can
        // never breach. The early return is deliberate rather than leaning on
        // `lossBps > 10_000` being unreachable: that would be the same
        // behaviour by accident, and a later change to how loss is computed
        // could silently make it reachable.
        if (c.maxDrawdownBps >= BPS_DENOMINATOR) return;

        // Strictly greater. A mandate that declared a 20% envelope is permitted
        // to lose exactly 20%; only a loss beyond the declared bound is the
        // breach predicate 5 exists for.
        //
        // `!c.breached` latches the FIRST breach. Liability is claims-made: it
        // attaches to the guardians covering the epoch the breach SURFACED on,
        // so a later, deeper checkpoint must not re-point `breachEpoch` at a
        // different epoch's coverers.
        if (lossBps > c.maxDrawdownBps && !c.breached) {
            c.breached = true;
            c.breachEpoch = uint64(due); // cover-relative (D8)
            emit DrawdownBreached(key, due, lossBps, c.maxDrawdownBps);
        }
    }

    // ── Views ──

    /// @inheritdoc ICoverageEpochs
    function navAt(address governor, uint256 proposalId, uint256 epoch) external view returns (uint256) {
        return _nav[_coverKey(governor, proposalId)][epoch];
    }

    /// @inheritdoc ICoverageEpochs
    function cumulativeLossBps(address governor, uint256 proposalId) public view returns (uint256) {
        bytes32 key = _coverKey(governor, proposalId);
        Cover storage c = _covers[key];
        if (!c.opened || c.baselineNav == 0) return 0;
        // No checkpoint yet means no observation. `_lastNav` defaults to zero,
        // and reading that default as a NAV would report a fabricated 100%
        // drawdown on a cover that has simply never been checkpointed — the
        // same trap as D1, in view form. `lastCheckpointedEpoch` only ever
        // names an epoch that was actually recorded, so this is exact even for
        // a cover whose one checkpoint was epoch 0.
        if (!_checkpointed[key][c.lastCheckpointedEpoch]) return 0;
        uint256 last = _lastNav[key];
        if (last >= c.baselineNav) return 0;
        // D4: the denominator is the BASELINE, not the previous checkpoint. An
        // epoch-over-epoch measure would let a missed call re-baseline against
        // a depressed NAV and read a 30% drawdown as 0%.
        return ((c.baselineNav - last) * BPS_DENOMINATOR) / c.baselineNav;
    }

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
    function breached(address governor, uint256 proposalId) external view returns (bool) {
        return _covers[_coverKey(governor, proposalId)].breached;
    }

    /// @inheritdoc ICoverageEpochs
    function relativeEpochNow(address governor, uint256 proposalId) external view returns (uint256) {
        Cover storage c = _covers[_coverKey(governor, proposalId)];
        // Without this guard `epochLength` is zero and `_epochAt` panics on the
        // division. An unopened cover has no schedule to be positioned on.
        if (!c.opened) revert NotOpened();
        return _relativeEpoch(c, block.timestamp);
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

    /// @dev Start of epoch `epoch`, which is also the BOUNDARY of epoch
    ///      `epoch - 1`. Uses the schedule copied onto the cover at open (D3),
    ///      never a fresh read of the ledger: a ledger re-point must not
    ///      retroactively re-slice a live strategy's epochs.
    function _boundary(Cover storage c, uint256 epoch) internal view returns (uint256) {
        return uint256(c.epochGenesis) + epoch * uint256(c.epochLength);
    }

    /// @dev Epoch containing `timestamp` on the cover's copied schedule.
    ///      Callers must have checked `c.opened`, which is what guarantees a
    ///      non-zero `epochLength` and a `epochGenesis` in the past.
    function _epochAt(Cover storage c, uint256 timestamp) internal view returns (uint256) {
        return (timestamp - uint256(c.epochGenesis)) / uint256(c.epochLength);
    }

    /// @dev D8 — the epoch index EVERY external surface speaks in: the ledger's
    ///      absolute epoch minus the absolute epoch the cover opened in, so this
    ///      cover's own first watch is 0.
    ///
    ///      Boundaries deliberately stay absolute (`_boundary`/`_epochAt` are
    ///      untouched). `ExposureLedger`'s exposure buckets expire on the global
    ///      grid, and a guardian's commitment expiring together with its bucket
    ///      is the entire mechanism; re-slicing the grid per cover would
    ///      desynchronise the two. Only the LABEL is cover-relative.
    ///
    ///      The distinction is invisible in a fixture that deploys the ledger
    ///      and opens the cover in the same block — `epochGenesis` is ledger
    ///      DEPLOY time, so in production a cover opens in absolute epoch
    ///      40-something and an absolute index would be meaningless to anyone
    ///      reading `breachEpoch`.
    ///
    ///      `timestamp` must be at or after `c.openedAt`; every caller either
    ///      passes `block.timestamp` on an opened cover or has already cleared a
    ///      boundary guard.
    function _relativeEpoch(Cover storage c, uint256 timestamp) internal view returns (uint256) {
        return _epochAt(c, timestamp) - _epochAt(c, uint256(c.openedAt));
    }
}
