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

    /// @notice GL-14 — the counter-bond pool is keyed per PROPOSAL, not per
    ///         challenge (pashov 2026-08 finding #10), so this no longer asserts
    ///         anything per-challenge. For every live (`Filed`/`Disputed`)
    ///         challenge it now says three things about THE POOL THAT CHALLENGE
    ///         BELONGS TO:
    ///
    ///           1. Σ `counterBondContributionOf` over the pool's contributor
    ///              list equals the pool's `raisedWood` — the contributor ledger
    ///              and the pool total never diverge.
    ///           2. The pool still HOLDS what it raised (`poolWood ==
    ///              raisedWood`) and has not been burned. Only a terminal
    ///              outcome empties a pool, and a live challenge on the key
    ///              means none has landed on it.
    ///           3. The pool never exceeds its target — `dispute` clamps the
    ///              overshoot rather than refunding it.
    ///
    ///         The pre-fix version compared a per-challenge contributor sum
    ///         against `challengeOf(id).counterBondWood`. That comparison went
    ///         vacuous rather than false once the pool moved per-key: BOTH sides
    ///         now read the shared pool, so it could no longer catch a
    ///         divergence between a challenge and its own funding. Concurrent
    ///         challenges on one review key deliberately report the SAME pool
    ///         here, which is the whole point of the fix.
    function property_GL14_counterBondPoolMatchesContributions() public view returns (bool) {
        uint256 n = game.challengeCount();
        for (uint256 id = 1; id <= n; id++) {
            IChallengeGame.Challenge memory c = game.challengeOf(id);
            if (c.status != IChallengeGame.Status.Filed && c.status != IChallengeGame.Status.Disputed) continue;

            (uint256 poolWood, uint256 targetWood, uint256 raisedWood,, bool burned) = game.counterBondPoolOf(id);
            address[] memory contributors = game.counterBondContributors(id);
            uint256 sum;
            for (uint256 j; j < contributors.length; j++) {
                sum += game.counterBondContributionOf(id, contributors[j]);
            }
            if (sum != raisedWood) return false;
            if (poolWood != raisedWood || burned) return false;
            if (raisedWood > targetWood) return false;
        }
        return true;
    }

    // ── Counts and state consistency (GL-15, GL-16, GL-17, GL-18) ──
    //
    // GL-19 is still NOT implemented: it needs BLOCKER set membership, and
    // `GuardianRegistry` exposes no getter for `_blockers` — only
    // `getApproverWeights` (approvers only) and `getReviewState`/`outcomeOf`
    // (aggregate flags). Asserting it would mean adding a getter to production
    // code to suit a test, which is the wrong trade.
    //
    // GL-20 IS implemented, further down, but against the ledger rather than
    // the registry: `approversOf`/`pledgedOf` expose exactly the membership and
    // pledge pair the property is about, so no new getter is needed.

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

    // ―――――――――――― One-shot latches (ghost-backed) ――――――――――――
    // Each of these guards a fact the protocol commits to ONCE. State alone
    // cannot prove a latch was never re-opened — only a remembered previous
    // observation can — so these read and update a ghost, and are therefore
    // deliberately NOT `view`, matching the existing GL-23/26/30/31 pattern.

    /// @notice GL-25 `SHOULD-HOLD` — `proposal.executedAt` is a one-shot latch.
    /// @dev It is the pre-drain snapshot basis every slash is measured against,
    ///      and `ChallengeGame.file` pins it onto the challenge precisely so a
    ///      governor cannot move it afterwards. If it could be rewritten while a
    ///      challenge is live, the accusation would be re-anchored to a
    ///      different moment than the one it was filed about.
    function property_GL25_executedAtIsOneShot() public returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            uint256 cur = governor.getProposal(pid).executedAt;
            uint256 prev = ghosts.lastExecutedAt[pid];
            if (prev != 0 && cur != prev) return false;
            if (cur != 0) ghosts.lastExecutedAt[pid] = cur;
        }
        return true;
    }

    /// @notice GL-32 `SHOULD-HOLD` — `caseOfChallenge` is set once per
    ///         challenge.
    /// @dev A second referral would hand one challenge two adjudications, and
    ///      the two verdicts could disagree — `rule` would then be callable
    ///      twice against the same bond. Relevant because referral has TWO
    ///      entry points: the auto-referral inside `dispute` and the explicit
    ///      `TokenCourt.refer`.
    function property_GL32_caseOfChallengeSetOnce() public returns (bool) {
        uint256 n = game.challengeCount();
        for (uint256 id = 1; id <= n; id++) {
            uint256 cur = court.caseOfChallenge(address(game), id);
            uint256 prev = ghosts.lastCaseOfChallenge[id];
            if (prev != 0 && cur != prev) return false;
            if (cur != 0) ghosts.lastCaseOfChallenge[id] = cur;
        }
        return true;
    }

    /// @notice GL-33 `SHOULD-HOLD` — `isAccused` is never cleared mid-case.
    /// @dev The bar exists so an approver cannot vote on their own conviction.
    ///      Clearing it before `finalize` would let the accused cohort acquit
    ///      itself, which is the single most valuable state to reach for an
    ///      attacker in the whole court.
    function property_GL33_accusedFlagNeverCleared() public returns (bool) {
        uint256 n = court.caseCount();
        for (uint256 id = 1; id <= n; id++) {
            for (uint256 a; a < actors.length; a++) {
                bool cur = court.isAccused(id, actors[a]);
                if (cur) {
                    ghosts.everAccused[id][actors[a]] = true;
                } else if (ghosts.everAccused[id][actors[a]]) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @notice GL-35 `SHOULD-HOLD` — x-ray G-19: a proposal's settle price is
    ///         stamped at most once.
    /// @dev The queue reserves assets at the stamped price, so re-stamping
    ///      would re-price redemptions that already have a claim against the
    ///      old one — the mid-flight NAV re-pricing surface the single stamp
    ///      exists to close.
    function property_GL35_settlePriceStampIsOneShot() public returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            bool cur = queue.getSettlePrice(pid).stamped;
            if (cur) {
                ghosts.everStamped[pid] = true;
            } else if (ghosts.everStamped[pid]) {
                return false;
            }
        }
        return true;
    }

    /// @notice GL-37 `SHOULD-HOLD` — `Review.opened` and `Review.resolved` are
    ///         each one-shot.
    /// @dev Re-opening a resolved review would re-run the slash path over a
    ///      cohort already judged, and re-opening an opened one would reset the
    ///      window guardians are voting inside. Both flags gate
    ///      `slashGuardians`, so neither may fall back to false.
    function property_GL37_reviewFlagsAreOneShot() public returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            bytes32 key = keccak256(abi.encode(address(governor), pid));
            (bool opened, bool resolved,) = registry.getReviewState(address(governor), pid);
            if (opened) ghosts.everOpened[key] = true;
            else if (ghosts.everOpened[key]) return false;
            if (resolved) ghosts.everResolved[key] = true;
            else if (ghosts.everResolved[key]) return false;
        }
        return true;
    }

    /// @notice GL-03 `SHOULD-HOLD` — the escrow's WOOD balance always covers
    ///         every bond it still owes.
    /// @dev Solvency in the same shape as GL-01: a bond that is still locked is
    ///      a claim on this balance, so a shortfall means two proposals were
    ///      promised the same WOOD. `bondOf` reads zero after EITHER exit
    ///      (release or forfeit), so this sums only live obligations — which is
    ///      exactly the set the balance has to cover.
    function property_GL03_escrowCoversLockedBonds() public view returns (bool) {
        uint256 owed;
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            (, uint256 amount) = bondEscrow.bondOf(address(governor), pid);
            owed += amount;
        }
        return wood.balanceOf(address(bondEscrow)) >= owed;
    }

    /// @notice GL-10 `SHOULD-HOLD` — vault asset accounting never creates or
    ///         destroys the underlying: every minted asset sits in exactly one
    ///         known holder.
    ///
    /// @dev The asset is a mock whose only mint path is `deal` at setup, so
    ///      `totalSupply()` is a closed universe and equality is the right
    ///      shape — but only if the holder set is genuinely complete.
    ///
    ///      IT WAS NOT, on the first campaign. This originally counted actors
    ///      plus vault/queue/adapter/governor, with a docstring asserting that
    ///      "no handler can route assets to an address outside this list". The
    ///      fuzzer refuted that in three calls
    ///      (`donateERC20 -> lifecycle_toExecuted -> lifecycle_toSettled`):
    ///      SETTLEMENT PAYS FEES. The management fee goes to the vault owner —
    ///      which in this harness is the test contract itself — and the
    ///      protocol/guardian legs go to whatever `ProtocolConfig` names. None
    ///      of those was counted, so a settled proposal always "lost" assets.
    ///
    ///      The recipients are read LIVE rather than hardcoded, because the
    ///      secondary dispatcher can re-point them mid-campaign. Zero addresses
    ///      are skipped: an unseated recipient does not strand its leg, the
    ///      governor hands that slice to the proposer as remainder, and the
    ///      proposer is already an actor.
    ///
    ///      Kept as `==`, not relaxed to `<=`. A future failure means either
    ///      conservation genuinely broke or a NEW asset sink was introduced —
    ///      and the counterexample sequence distinguishes them immediately, as
    ///      it did here. That is worth more than a bound that can never fire.
    function property_GL10_assetSupplyConserved() public view returns (bool) {
        uint256 sum = asset.balanceOf(address(vault)) + asset.balanceOf(address(queue))
            + asset.balanceOf(address(adapter)) + asset.balanceOf(address(governor)) + asset.balanceOf(address(this)); // vault owner: management-fee sink
        for (uint256 i; i < actors.length; i++) {
            sum += asset.balanceOf(actors[i]);
        }
        address p = protocolConfig.protocolFeeRecipient();
        address g = protocolConfig.guardiansFeeRecipient();
        if (p != address(0) && p != address(this)) sum += asset.balanceOf(p);
        if (g != address(0) && g != address(this) && g != p) sum += asset.balanceOf(g);
        return sum == asset.totalSupply();
    }

    /// @notice GL-20 `SHOULD-HOLD` — the approver array holds exactly the
    ///         guardians carrying a live pledge, with no duplicates.
    /// @dev `_approversOf` is append-only while `_reservedUsd` is cleared on
    ///      release, so the two can drift: a guardian appearing twice would
    ///      double-count toward `requireApproveQuorum`, and one appearing with a
    ///      zeroed pledge would inflate the cohort's apparent size. Both are
    ///      quorum-inflation bugs, which is why membership and pledge are
    ///      checked together rather than counting length alone.
    function property_GL20_approverArrayMatchesPledges() public view returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            (address[] memory approvers,) = ledger.approversOf(address(governor), pid);
            (, uint256[] memory pledged) = ledger.pledgedOf(address(governor), pid);
            for (uint256 i; i < approvers.length; i++) {
                if (pledged[i] == 0) return false;
                for (uint256 j = i + 1; j < approvers.length; j++) {
                    if (approvers[i] == approvers[j]) return false;
                }
            }
        }
        return true;
    }

    /// @notice GL-21 `SHOULD-HOLD` — x-ray G-44: at most one LIVE challenge per
    ///         (proposal, challenger).
    /// @dev `file` enforces this through `_liveByChallenger`, and the guard is
    ///      what stops a challenger re-filing to re-freeze coverage that a
    ///      previous filing already released — a griefing loop that would pin a
    ///      guardian's stake indefinitely at the cost of one bond. Live means
    ///      Filed or Disputed; the terminal statuses are allowed to repeat
    ///      because the window legitimately re-arms after an Inconclusive.
    function property_GL21_oneLiveChallengePerProposalChallenger() public view returns (bool) {
        uint256 n = game.challengeCount();
        for (uint256 a = 1; a <= n; a++) {
            IChallengeGame.Challenge memory x = game.challengeOf(a);
            if (!_isLive(x.status)) continue;
            for (uint256 b = a + 1; b <= n; b++) {
                IChallengeGame.Challenge memory y = game.challengeOf(b);
                if (!_isLive(y.status)) continue;
                if (x.challenger == y.challenger && x.governor == y.governor && x.proposalId == y.proposalId) {
                    return false;
                }
            }
        }
        return true;
    }

    function _isLive(IChallengeGame.Status s) private pure returns (bool) {
        return s == IChallengeGame.Status.Filed || s == IChallengeGame.Status.Disputed;
    }

    // ―――――― ExposureLedger shared-stake accumulators (x-ray I-5 / X-8) ――――――
    // The mathematical core of the protocol's central economic claim: one
    // guardian bond backs many proposals at once, and the ledger's job is to
    // stop the same stake being promised twice. Nothing on-chain asserts it.

    /// @notice GL-12 `SHOULD-HOLD` — a guardian's live bucketed exposure never
    ///         exceeds the sum of what the ledger recorded for them across
    ///         every proposal.
    ///
    /// @dev `<=`, NOT `==`, and the asymmetry is the whole subtlety.
    ///      `openExposureUsd` sums `_buckets[guardian][epoch]` over a WALL-CLOCK
    ///      window — buckets age out once their challenge window elapses — while
    ///      `approversOf` returns `_recorded[key][guardian]` for every key ever
    ///      written. Expiry, `retireApproval` and `settleCoverage`'s re-book can
    ///      each drop the live side below the historical sum, so equality is
    ///      false for a reason that is correct behaviour.
    ///
    ///      `<=` still carries the real content: it fails if a booking is
    ///      double-counted into the buckets, or if a bucket is credited without
    ///      a matching record — the two ways this accumulator could overstate a
    ///      guardian's free budget and let them over-promise their bond.
    ///
    ///      Deliberately not written as `==` first and relaxed later: GL-09 and
    ///      GL-16 both shipped as equalities, both fired, and both turned out to
    ///      be defects in the property rather than the protocol. The direction
    ///      that can actually be violated is the one worth asserting.
    function property_GL12_openExposureWithinRecordedSum() public view returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 g; g < GUARDIAN_COUNT; g++) {
            address guardian = actors[g];
            uint256 recorded;
            for (uint256 pid = 1; pid <= n; pid++) {
                (address[] memory approvers, uint256[] memory committed) = ledger.approversOf(address(governor), pid);
                for (uint256 i; i < approvers.length; i++) {
                    if (approvers[i] == guardian) recorded += committed[i];
                }
            }
            if (ledger.openExposureUsd(guardian) > recorded) return false;
        }
        return true;
    }

    /// @notice GL-13 `SHOULD-HOLD` — per (proposal, guardian), the pledged
    ///         reservation is never below the recorded exposure booked against
    ///         it.
    ///
    /// @dev I-5's second clause. `recordApproval` writes both sides equal
    ///      (`_reservedUsd` and `_recorded.usd` both take `share`), and only
    ///      `settleCoverage`'s re-book moves them apart — downward on the
    ///      recorded side, rebooking approvals to actual need. The pledge is the
    ///      standing promise and nothing but a release clears it, so recorded
    ///      exposure exceeding its own pledge would mean the ledger is carrying
    ///      liability the guardian never reserved.
    ///
    ///      PROPERTIES.md specifies this against `_livePledgedUsd`, which has no
    ///      accessor and would need a ghost mirroring every mutation site. This
    ///      is the same clause expressed through the two accessors that DO
    ///      exist, so it is assertable today; the ghost-based aggregate remains
    ///      open.
    function property_GL13_pledgeCoversRecorded() public view returns (bool) {
        uint256 n = governor.proposalCount();
        for (uint256 pid = 1; pid <= n; pid++) {
            (address[] memory approvers, uint256[] memory committed) = ledger.approversOf(address(governor), pid);
            (, uint256[] memory pledged) = ledger.pledgedOf(address(governor), pid);
            if (pledged.length != approvers.length) return false;
            for (uint256 i; i < approvers.length; i++) {
                if (pledged[i] < committed[i]) return false;
            }
        }
        return true;
    }

    /// @notice GL-49 `EXPLORATORY` — x-ray X-8: a guardian's aggregate booked
    ///         coverage never exceeds the stake that backs it,
    ///         `kNumerator * slashableBondUsd`.
    ///
    /// @dev THE central economic claim, and x-ray flags it On-chain=**No** —
    ///      nothing asserts it anywhere. `recordApproval` maintains it going in:
    ///      it books `share = min(free, need)` only while `open < capUsd`, so
    ///      the sum cannot exceed the cap AT BOOKING TIME.
    ///
    ///      EXPLORATORY because the bound is enforced only at that instant and
    ///      the right-hand side moves afterwards. `slashableBondUsd` is a live
    ///      read: a WOOD price fall, a haircut change, or a slash on another
    ///      case all shrink the cap under commitments already booked against it.
    ///      A violation is therefore not automatically a bug — it is the
    ///      quantitative answer to "how far can a guardian's book drift past
    ///      their collateral without any single call being wrong", which is
    ///      exactly what the fuzzer should be asked and what E-1 rests on.
    function property_GL49_bookedCoverageWithinSlashableStake() public view returns (bool) {
        uint256 k = ledger.kNumerator();
        for (uint256 g; g < GUARDIAN_COUNT; g++) {
            address guardian = actors[g];
            if (ledger.openExposureUsd(guardian) > k * ledger.slashableBondUsd(guardian)) return false;
        }
        return true;
    }

    /// @notice GL-51 `EXPLORATORY` — under every configuration the four
    ///         setters accept, filing an honest challenge is not a losing
    ///         trade: `honestFilingNetPayoffBps() >= 0`.
    ///
    /// @dev EXPLORATORY, NOT SHOULD-HOLD — a counterexample is a question, not
    ///      a bug, and the expected outcome here is that this DOES fail. Three
    ///      reasons it is still worth running:
    ///
    ///      1. It prices only the SILENCE branch, where the challenger
    ///         recovers `bond - burned`. On the escalated branch it also takes
    ///         the forfeited counter-bond (`Disputed` implies
    ///         `pool == bondWood`), which the contract deliberately does not
    ///         model. So negative here does not prove a losing game overall.
    ///      2. No setter can enforce it. `proposerBondBps` lives on
    ///         `ExposureLedger` and the other three on `ChallengeGame`, so
    ///         there is no single owner to check the product against — and a
    ///         per-setter guard would brick reconfiguration, since moving
    ///         between two sound configurations can require an intermediate
    ///         that violates the condition.
    ///      3. What the counterexample IS good for: the exact parameter tuple
    ///         the fuzzer reaches is the one governance must not ship. That
    ///         makes this a monitoring surface — which is what
    ///         `honestFilingBreaksEven` was built to be.
    ///
    ///      Reachability depends on the four setter handlers added alongside
    ///      this (three in `ChallengeGameHandler`, one in
    ///      `ExposureLedgerHandler`). Without them this reduces to a single
    ///      fixed deploy configuration and proves nothing.
    function property_GL51_honestFilingNeverLoses() public view returns (bool) {
        return game.honestFilingNetPayoffBps() >= 0;
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.
}
