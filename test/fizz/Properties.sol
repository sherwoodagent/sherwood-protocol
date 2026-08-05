// SPDX-License-Identifier: MIT
pragma solidity >=0.6.2 <0.9.0;

import {Snapshots} from "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";

import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IChallengeGame} from "../../src/interfaces/IChallengeGame.sol";
import {ITokenCourt} from "../../src/interfaces/ITokenCourt.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {
    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.
    //
    // All return `bool` (false = violation) per the harness convention:
    // Medusa's `propertyTesting` checks the return value directly, and a
    // clean bool keeps output readable. None of them revert on legitimate
    // (including empty/zero) state — every loop bound tolerates zero and
    // every external read is one the target contracts guarantee not to
    // revert on.

    // ── Conservation (GL-01, GL-05, GL-06, GL-07, GL-09, GL-11, GL-14) ──

    /// @notice GL-01 — WOOD held by `ChallengeGame` always covers bonded +
    ///         unclaimed WOOD (verbatim NatSpec invariant on the contract).
    function property_GL01_gameWoodCoversBondedAndUnclaimed() public view returns (bool) {
        return wood.balanceOf(address(game)) >= game.bondedWood() + game.unclaimedWood();
    }

    /// @notice GL-05 — Σ live (unclaimed, uncancelled) redeem-request amounts
    ///         equals `queue.pendingShares()`.
    function property_GL05_queuePendingSharesMatchLiveRedeems() public view returns (bool) {
        uint256 sum;
        uint256 n = queue.nextRequestId();
        for (uint256 id = 1; id < n; id++) {
            IVaultWithdrawalQueue.Request memory r = queue.getRequest(id);
            if (r.kind == IVaultWithdrawalQueue.RequestKind.Redeem && !r.claimed && !r.cancelled) {
                sum += r.amount;
            }
        }
        return sum == queue.pendingShares();
    }

    /// @notice GL-06 — Σ live (unclaimed, uncancelled) deposit-request
    ///         amounts equals `queue.pendingDepositAssets()`.
    function property_GL06_queuePendingDepositAssetsMatchLiveDeposits() public view returns (bool) {
        uint256 sum;
        uint256 n = queue.nextRequestId();
        for (uint256 id = 1; id < n; id++) {
            IVaultWithdrawalQueue.Request memory r = queue.getRequest(id);
            if (r.kind == IVaultWithdrawalQueue.RequestKind.Deposit && !r.claimed && !r.cancelled) {
                sum += r.amount;
            }
        }
        return sum == queue.pendingDepositAssets();
    }

    /// @notice GL-07 — Σ stamped-but-unclaimed redeem amounts equals
    ///         `queue.stampedUnclaimedShares()` — the exact set
    ///         `SyndicateVault._pricingSupply` excludes.
    function property_GL07_queueStampedUnclaimedSharesMatch() public view returns (bool) {
        uint256 sum;
        uint256 n = queue.nextRequestId();
        for (uint256 id = 1; id < n; id++) {
            IVaultWithdrawalQueue.Request memory r = queue.getRequest(id);
            if (r.kind == IVaultWithdrawalQueue.RequestKind.Redeem && !r.claimed && !r.cancelled) {
                if (queue.getSettlePrice(r.pid).stamped) {
                    sum += r.amount;
                }
            }
        }
        return sum == queue.stampedUnclaimedShares();
    }

    /// @notice GL-09 — Σ actor vault-share balances + queue-escrowed shares
    ///         equals `vault.totalSupply()`. `settleRedeem`/`settleDeposit`
    ///         only ever burn from / mint to actors and the queue, so those
    ///         two sets are the entire holder universe.
    /// @dev Relaxed to `<=` after the first campaign flagged it.
    ///
    ///      The equality form is only valid if every share holder is an actor
    ///      or the queue — and it is not. The UNCLAMPED handlers
    ///      (`syndicateVault_deposit`, `_mint`, `_transfer`, `_transferFrom`)
    ///      are direct fuzz entry points taking a RAW `receiver`/`to`, by
    ///      design, so the fuzzer can legitimately park shares at an arbitrary
    ///      address outside the tracked set. Confirmed by
    ///      `test_triage_GL09`: a deposit to `0xBEEF` leaves those shares
    ///      uncounted while `totalSupply` rises.
    ///
    ///      `<=` is still meaningful: it catches a phantom BURN (tracked
    ///      balances outliving the supply that backs them) and any accounting
    ///      path that mints to a tracked holder without moving `totalSupply`.
    function property_GL09_vaultShareSupplyConserved() public view returns (bool) {
        uint256 sum = vault.balanceOf(address(queue));
        for (uint256 i; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        return sum <= vault.totalSupply();
    }

    /// @notice GL-11 — `StakedWood.totalGuardianStake` equals Σ `stakedAmount`
    ///         over guardians with `unstakeRequestedAt == 0` (i.e. active).
    function property_GL11_totalGuardianStakeMatchesActiveSum() public view returns (bool) {
        uint256 sum;
        for (uint256 i; i < actors.length; i++) {
            if (swood.isActiveGuardian(actors[i])) {
                sum += swood.guardianStake(actors[i]);
            }
        }
        return sum == swood.totalGuardianStake();
    }

    /// @notice GL-14 — while a challenge is live (`Filed`/`Disputed`), Σ
    ///         contributor amounts equals `challengeOf(id).counterBondWood`.
    function property_GL14_counterBondPoolMatchesContributions() public view returns (bool) {
        uint256 n = game.challengeCount();
        for (uint256 id = 1; id <= n; id++) {
            IChallengeGame.Challenge memory c = game.challengeOf(id);
            if (c.status == IChallengeGame.Status.Filed || c.status == IChallengeGame.Status.Disputed) {
                address[] memory contributors = game.counterBondContributors(id);
                uint256 sum;
                for (uint256 j; j < contributors.length; j++) {
                    sum += game.counterBondContributionOf(id, contributors[j]);
                }
                if (sum != c.counterBondWood) return false;
            }
        }
        return true;
    }

    // ── Counts and state consistency (GL-15, GL-16, GL-17, GL-18) ──
    //
    // GL-19 and GL-20 are NOT implemented: they need to inspect the
    // blocker/approver *set membership* and per-guardian vote (registry's
    // internal `_blockers` / `_votes`), and `GuardianRegistry` exposes no
    // getter for either — only `getApproverWeights` (approvers only) and
    // `getReviewState`/`outcomeOf` (aggregate flags). Implementing them
    // would require inventing a getter, which is out of scope here.

    /// @notice GL-15 — `getActiveProposal() != 0` iff exactly one proposal is
    ///         `Executed`, and it is that one.
    function property_GL15_activeProposalMatchesSoleExecuted() public view returns (bool) {
        uint256 active = governor.getActiveProposal();
        uint256 n = governor.proposalCount();
        uint256 executedCount;
        uint256 executedId;
        for (uint256 pid = 1; pid <= n; pid++) {
            if (governor.stateOf(pid) == ISyndicateGovernor.ProposalState.Executed) {
                executedCount++;
                executedId = pid;
            }
        }
        if (active == 0) return executedCount == 0;
        return executedCount == 1 && executedId == active;
    }

    /// @notice GL-16 — `openProposalCount()` equals the count of proposals in
    ///         {Draft, Pending, GuardianReview, Approved, Executed}.
    /// @dev Relaxed from `==` to `>=` after the first campaign flagged it.
    ///
    ///      `stateOf` is a TRUE VIEW: `ProposalLifecycle._computeState`
    ///      resolves Approved/Rejected/Expired the instant they become
    ///      determinable, without writing. `_openProposalCount` decrements
    ///      only inside `_decOpen`, which runs when `_commitState` actually
    ///      COMMITS the transition. Between those two moments a proposal reads
    ///      terminal through `stateOf` while still being counted open — the
    ///      documented lazy-commit design, not a defect.
    ///
    ///      Confirmed by `test_triage_GL16`: 60 days after propose, `stateOf`
    ///      returns Expired while `openProposalCount` is still 1.
    ///
    ///      So the eagerly-computed count is a LOWER bound on the committed
    ///      counter. `>=` still catches the failure that matters — the counter
    ///      dropping below the number of genuinely live proposals, which would
    ///      silently lift the one-live-proposal rule (G-1) and the
    ///      parameter freeze (G-13).
    function property_GL16_openProposalCountMatchesOpenStates() public view returns (bool) {
        uint256 n = governor.proposalCount();
        uint256 openCount;
        for (uint256 pid = 1; pid <= n; pid++) {
            ISyndicateGovernor.ProposalState s = governor.stateOf(pid);
            if (
                s == ISyndicateGovernor.ProposalState.Draft || s == ISyndicateGovernor.ProposalState.Pending
                    || s == ISyndicateGovernor.ProposalState.GuardianReview
                    || s == ISyndicateGovernor.ProposalState.Approved || s == ISyndicateGovernor.ProposalState.Executed
            ) {
                openCount++;
            }
        }
        return governor.openProposalCount() >= openCount;
    }

    /// @notice GL-17 — `game.liveChallengeCountOf(governor, pid)` equals the
    ///         count of challenges against that key with status `Filed` or
    ///         `Disputed`.
    function property_GL17_liveChallengeCountMatchesFiledOrDisputed() public view returns (bool) {
        uint256 pCount = governor.proposalCount();
        uint256 cCount = game.challengeCount();
        uint256[] memory liveCounts = new uint256[](pCount + 1);
        for (uint256 id = 1; id <= cCount; id++) {
            IChallengeGame.Challenge memory c = game.challengeOf(id);
            if (
                c.governor == address(governor) && c.proposalId <= pCount
                    && (c.status == IChallengeGame.Status.Filed || c.status == IChallengeGame.Status.Disputed)
            ) {
                liveCounts[c.proposalId]++;
            }
        }
        for (uint256 pid = 1; pid <= pCount; pid++) {
            if (game.liveChallengeCountOf(address(governor), pid) != liveCounts[pid]) return false;
        }
        return true;
    }

    /// @notice GL-18 — `ledger.frozenCoverageCount()` equals the number of
    ///         (governor, proposalId) keys reporting `isCoverageFrozen` true.
    function property_GL18_frozenCoverageCountMatches() public view returns (bool) {
        uint256 n = governor.proposalCount();
        uint256 frozenCount;
        for (uint256 pid = 1; pid <= n; pid++) {
            if (ledger.isCoverageFrozen(address(governor), pid)) frozenCount++;
        }
        return frozenCount == ledger.frozenCoverageCount();
    }

    // ── One-shot latches and terminality (GL-23, GL-26, GL-30, GL-31, GL-34, GL-36) ──
    //
    // GL-23, GL-26, GL-30, GL-31 and GL-34 are entirely SELF-MAINTAINED: each
    // property function reads the current on-chain value, compares it to the
    // ghost it wrote on its own previous call, then overwrites the ghost.
    // No handler wiring is needed for those. GL-36 is the one exception —
    // see the `Ghosts` struct doc in `Base.sol`.

    function _isTerminalProposalState(uint8 s) private pure returns (bool) {
        return s == uint8(ISyndicateGovernor.ProposalState.Rejected)
            || s == uint8(ISyndicateGovernor.ProposalState.Expired)
            || s == uint8(ISyndicateGovernor.ProposalState.Settled)
            || s == uint8(ISyndicateGovernor.ProposalState.Cancelled);
    }

    /// @notice GL-23 — a terminal `proposal.state` never changes again.
    function property_GL23_terminalProposalStateIsImmutable() public returns (bool) {
        uint256 n = governor.proposalCount();
        bool ok = true;
        for (uint256 pid = 1; pid <= n; pid++) {
            uint8 cur = uint8(governor.stateOf(pid));
            uint8 prev = ghosts.lastProposalState[pid];
            if (_isTerminalProposalState(prev) && cur != prev) ok = false;
            ghosts.lastProposalState[pid] = cur;
        }
        return ok;
    }

    function _isTerminalChallengeStatus(uint8 s) private pure returns (bool) {
        return s == uint8(IChallengeGame.Status.Failed) || s == uint8(IChallengeGame.Status.Settled)
            || s == uint8(IChallengeGame.Status.Inconclusive);
    }

    /// @notice GL-26 — a challenge reaches exactly one terminal status and
    ///         never changes after.
    function property_GL26_terminalChallengeStatusIsImmutable() public returns (bool) {
        uint256 n = game.challengeCount();
        bool ok = true;
        for (uint256 id = 1; id <= n; id++) {
            uint8 cur = uint8(game.challengeOf(id).status);
            uint8 prev = ghosts.lastChallengeStatus[id];
            if (_isTerminalChallengeStatus(prev) && cur != prev) ok = false;
            ghosts.lastChallengeStatus[id] = cur;
        }
        return ok;
    }

    /// @notice GL-30 — a court case's phase goes `Voting → Resolved` once,
    ///         never back.
    function property_GL30_caseResolvedIsOneShot() public returns (bool) {
        uint256 n = court.caseCount();
        bool ok = true;
        for (uint256 id = 1; id <= n; id++) {
            uint8 cur = uint8(court.caseOf(id).phase);
            uint8 prev = ghosts.lastCasePhase[id];
            if (prev == uint8(ITokenCourt.Phase.Resolved) && cur != prev) ok = false;
            ghosts.lastCasePhase[id] = cur;
        }
        return ok;
    }

    /// @notice GL-31 — `voteOf[caseId][voter]` is one-shot: NatSpec says
    ///         "NO VOTE CHANGES".
    function property_GL31_voteOfIsOneShot() public returns (bool) {
        uint256 n = court.caseCount();
        bool ok = true;
        for (uint256 id = 1; id <= n; id++) {
            for (uint256 i; i < actors.length; i++) {
                address voter = actors[i];
                uint8 cur = uint8(court.voteOf(id, voter));
                uint8 prev = ghosts.lastVoteOf[id][voter];
                if (prev != uint8(ITokenCourt.Ruling.None) && cur != prev) ok = false;
                ghosts.lastVoteOf[id][voter] = cur;
            }
        }
        return ok;
    }

    /// @notice GL-34 — a queue request's `claimed` and `cancelled` are
    ///         mutually exclusive and each one-shot.
    function property_GL34_requestClaimedAndCancelledAreExclusiveOneShot() public returns (bool) {
        uint256 n = queue.nextRequestId();
        bool ok = true;
        for (uint256 id = 1; id < n; id++) {
            IVaultWithdrawalQueue.Request memory r = queue.getRequest(id);
            if (r.claimed && r.cancelled) ok = false;
            if (ghosts.everClaimed[id] && !r.claimed) ok = false;
            if (ghosts.everCancelled[id] && !r.cancelled) ok = false;
            if (r.claimed) ghosts.everClaimed[id] = true;
            if (r.cancelled) ghosts.everCancelled[id] = true;
        }
        return ok;
    }

    /// @notice GL-36 — a bond record goes `0 → proposer → 0` via exactly one
    ///         of `releaseBond` XOR `forfeitBond`.
    /// @dev    Relies on `ghosts.bondReleased` / `ghosts.bondForfeited`,
    ///         which `ProposerBondEscrowHandler` must set — see the
    ///         `Ghosts` struct doc in `Base.sol`. Until that wiring lands
    ///         this property is vacuously true (both flags stay false), not
    ///         wrong — it simply cannot observe a violation yet.
    function property_GL36_bondExitsViaExactlyOneOfReleaseOrForfeit() public view returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            bytes32 key = keccak256(abi.encode(address(governor), pid));
            if (ghosts.bondReleased[key] && ghosts.bondForfeited[key]) return false;
        }
        return true;
    }

    // ── Monotonicity (GL-39, GL-40) ──
    //
    // GL-41 (`EmergencyReview.round` never decreases) is NOT implemented:
    // `GuardianRegistry` exposes no getter for `EmergencyReview.round` (or
    // any field of it) among the verified getters — only
    // `getReviewState`/`outcomeOf`, which read the ordinary `Review`, not
    // `EmergencyReview`. Would need an invented accessor or a harness
    // contract; out of scope here.

    /// @notice GL-39 — `challengeCount`, `caseCount`, `proposalCount` and
    ///         `nextRequestId` never decrease.
    function property_GL39_countersNeverDecrease() public returns (bool) {
        bool ok = true;

        uint256 pCount = governor.proposalCount();
        if (pCount < ghosts.lastProposalCount) ok = false;
        ghosts.lastProposalCount = pCount;

        uint256 cCount = game.challengeCount();
        if (cCount < ghosts.lastChallengeCount) ok = false;
        ghosts.lastChallengeCount = cCount;

        uint256 caseCnt = court.caseCount();
        if (caseCnt < ghosts.lastCaseCount) ok = false;
        ghosts.lastCaseCount = caseCnt;

        uint256 reqId = queue.nextRequestId();
        if (reqId < ghosts.lastNextRequestId) ok = false;
        ghosts.lastNextRequestId = reqId;

        return ok;
    }

    /// @notice GL-40 — `challengeableUntil[key]` never decreases.
    function property_GL40_challengeableUntilNeverDecreases() public returns (bool) {
        uint256 n = governor.proposalCount();
        bool ok = true;
        for (uint256 pid = 1; pid <= n; pid++) {
            bytes32 key = keccak256(abi.encode(address(governor), pid));
            uint256 cur = game.challengeableUntil(key);
            if (cur < ghosts.lastChallengeableUntil[key]) ok = false;
            ghosts.lastChallengeableUntil[key] = cur;
        }
        return ok;
    }

    // ── Pricing and rounding (GL-42, GL-44, GL-45, GL-47) ──

    /// @notice GL-42 — `vault.highWaterPricePerShare()` is non-decreasing
    ///         while `totalSupply != 0`, and resets to 0 only on a full
    ///         drain.
    function property_GL42_highWaterMarkNonDecreasing() public returns (bool) {
        uint256 current = vault.highWaterPricePerShare();
        uint256 prev = ghosts.lastHighWaterPricePerShare;
        bool ok = true;
        if (current < prev) {
            ok = (current == 0 && vault.totalSupply() == 0);
        }
        ghosts.lastHighWaterPricePerShare = current;
        return ok;
    }

    /// @notice GL-44 — `convertToAssets(convertToShares(a)) <= a` (ERC-4626),
    ///         checked over a fixed set of representative magnitudes rather
    ///         than a fuzzed argument (Medusa's `propertyTesting` calls
    ///         `property_*` functions with no arguments).
    function property_GL44_convertRoundTripAssetsNeverGains() public view returns (bool) {
        uint256[6] memory samples = [uint256(0), 1, 1e6, 1e12, 1e18, type(uint128).max];
        for (uint256 i; i < samples.length; i++) {
            uint256 a = samples[i];
            uint256 shares = vault.convertToShares(a);
            uint256 assetsBack = vault.convertToAssets(shares);
            if (assetsBack > a) return false;
        }
        return true;
    }

    /// @notice GL-45 — `convertToShares(convertToAssets(s)) <= s` (ERC-4626).
    function property_GL45_convertRoundTripSharesNeverGains() public view returns (bool) {
        uint256[6] memory samples = [uint256(0), 1, 1e6, 1e12, 1e18, type(uint128).max];
        for (uint256 i; i < samples.length; i++) {
            uint256 s = samples[i];
            uint256 assetsOut = vault.convertToAssets(s);
            uint256 sharesBack = vault.convertToShares(assetsOut);
            if (sharesBack > s) return false;
        }
        return true;
    }

    /// @notice GL-47 — a guardian's age-weighted vote weight never exceeds
    ///         their raw votable stake at the same timestamp.
    function property_GL47_ageWeightedVoteNeverExceedsRawStake() public view returns (bool) {
        for (uint256 i; i < actors.length; i++) {
            if (swood.getPastVotes(actors[i], block.timestamp) > swood.getPastStake(actors[i], block.timestamp)) {
                return false;
            }
        }
        return true;
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.
}
