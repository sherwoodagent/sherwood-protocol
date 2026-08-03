// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TierRegistry
 * @notice Adapter-selector tier certification for the guardian economic-security
 *         model. Tier is a property of (target, selector), set at listing by
 *         governance, consumed at propose/execute time.
 *
 *         Tier 0: closed-loop — extractable bounded to `extractableBoundBps`.
 *         Tier 1: oracle-bounded discretion — extractable bounded likewise.
 *         Tier 2: arbitrary calldata — full notional. DEFAULT for any
 *                 uncertified (target, selector).
 *
 * @dev Fail-safe demotion is LAZY: `tierOf` verifies the target's live
 *      EXTCODEHASH against the certified hash on every read and reports tier 2
 *      on mismatch — no state write in the hot path, nothing to grief. `poke`
 *      persists the demotion and emits for indexers.
 *
 *      SCOPE OF THE CODEHASH CHECK: EXTCODEHASH identity catches ONLY
 *      same-address bytecode mutation — i.e. metamorphic redeploys (CREATE2 +
 *      SELFDESTRUCT). It does NOT catch proxy implementation swaps: for
 *      EIP-1967 / UUPS / transparent / beacon proxies the PROXY's runtime
 *      bytecode is static across upgrades, so the certified hash keeps
 *      matching while the behavior behind it changes arbitrarily. Governance
 *      MUST NOT certify proxied adapters at tier 0/1 — an upgradeable target
 *      can never be "closed-loop" or "oracle-bounded" by inspection of frozen
 *      code. Leave proxies at the tier-2 default.
 *
 *      THIS RULE IS NOT LIMITED TO RECOGNIZED PROXY SHAPES: EXTCODEHASH
 *      attests only to unchanged bytecode, never to unchanged behavior. ANY
 *      target exposing ordinary, non-`immutable` storage that is settable
 *      after deployment and can affect fund routing — a beneficiary address,
 *      a fee sink, a swap-path parameter, and so on — can have that state
 *      rewired and be certified atomically in the same transaction, since its
 *      codehash never moves. Governance MUST treat "certifiable at tier 0/1"
 *      as bytecode-AND-storage-immutable for every fund-routing-relevant
 *      parameter, not merely "not a known proxy shape": review the target's
 *      full storage layout for post-deployment setters before certifying,
 *      not just the presence or absence of a delegatecall.
 *
 *      GRANTING is announced, not instant: `proposeCertification` (owner-only)
 *      records intent and pins the target's codehash and bond amount;
 *      `certify` (permissionless) executes it no earlier than `certifyDelay`
 *      later, and only if the live codehash still matches the pinned
 *      snapshot. The announcement window is the enforcement aid for the
 *      proxy-discipline rule above — anyone can inspect a queued target, in
 *      particular a proxied one, before the grant takes effect. REVOKING
 *      (`demote`, `demoteByChallenge`, `poke`) stays instant and permissionless
 *      or owner-gated exactly as before — the delay applies only to granting a
 *      lower tier, never to revoking one.
 */
contract TierRegistry is Ownable2Step {
    using SafeERC20 for IERC20;

    struct TierConfig {
        uint8 tier; // 0 or 1 when certified; entry absent => tier 2
        uint16 extractableBoundBps; // certified extractable bound, bps of notional
        bytes32 certifiedCodehash; // EXTCODEHASH of target at certification
    }

    /// @dev Submitter bond per certification. Held while certified; demotion
    ///      starts `bondReleaseDelay`, then the submitter claims. The delay
    ///      gives the slash mechanism a window to act before the submitter's
    ///      bond can be pulled out from under it.
    struct SubmitterBond {
        address submitter;
        uint96 amount;
        uint64 releasableAt; // 0 while certified; set on demotion
    }

    /// @dev A proposed-but-not-yet-executed certification. `readyAt == 0` is
    ///      the existence sentinel (no pending record). `codehash`,
    ///      `bondAmount`, and `bondToken` are snapshotted/pinned at proposal
    ///      time so that permissionless execution can only choose WHEN, never
    ///      WHAT — see `proposeCertification` / `certify` natspec.
    ///
    ///      `bondToken` pins the live `wood` at proposal time (audit finding
    ///      #1): without it, an ordinary `setWood` token migration during the
    ///      certify-delay window would make `certify` pull the pinned AMOUNT
    ///      denominated in a token the submitter never approved against for
    ///      this certification — `setWood`'s only guard
    ///      (`totalBondedWood != 0`) cannot see an unexecuted pending bond.
    struct PendingCertification {
        uint8 tier; // ┐
        uint16 extractableBoundBps; // │ slot 1: 1 + 2 + 20 + 8 = 31 bytes
        address submitter; // │
        uint64 readyAt; // ┘ 0 = no pending (existence sentinel)
        uint96 bondAmount; // ┐ slot 2: 12 + 20 = 32 bytes
        IERC20 bondToken; // ┘ pinned `wood` at proposal time (finding #1)
        bytes32 codehash; // slot 3: proposal-time EXTCODEHASH snapshot
    }

    uint8 public constant TIER_ARBITRARY = 2;
    uint16 public constant FULL_NOTIONAL_BPS = 10_000;

    /// @dev Floor keeps a demoted bond claimable-not-yet-claimed long enough
    ///      for the slash mechanism to act before payout. Ceiling bounds
    ///      governance error.
    uint256 public constant MIN_BOND_RELEASE_DELAY = 1 days;
    uint256 public constant MAX_BOND_RELEASE_DELAY = 365 days;

    /// @dev Floor guarantees every grant is announced for at least one full
    ///      day — `certifyDelay` can never be configured back into the
    ///      instant path. Ceiling bounds governance error: an over-long
    ///      delay stalls ALL adapter onboarding, so a mis-set value above it
    ///      is un-settable rather than merely survivable.
    uint256 public constant MIN_CERTIFY_DELAY = 1 days;
    uint256 public constant MAX_CERTIFY_DELAY = 30 days;

    /// @dev Upper bound on how long after `readyAt` a pending certification
    ///      may still be executed (audit finding #5). Without this, `certify`
    ///      has no upper bound at all — a submitter fully controls WHEN to
    ///      trigger the permissionless execute and can wait out a price
    ///      collapse on the bond token's liquidity before posting badly-stale
    ///      collateral against an unchanged extractable bound. A fixed
    ///      constant (not an owner-configurable delay, unlike
    ///      `certifyDelay`) deliberately gives the owner no lever to shorten
    ///      this window and expire someone else's pending certification
    ///      early. 14 days is generous relative to `certifyDelay`'s 30-day
    ///      ceiling for review, while still bounding collateral staleness to
    ///      a fixed, known window.
    uint256 public constant MAX_CERTIFY_WINDOW = 14 days;

    /// @dev EXTCODEHASH of an EXISTING account with no code (EIP-1052). A funded
    ///      EOA hashes to this, not bytes32(0) — `certify` rejects both.
    bytes32 private constant _EMPTY_CODEHASH = keccak256("");

    mapping(bytes32 configKey => TierConfig) private _configs;

    /// @notice Owner-managed allowlist of adapter addresses that may appear as
    ///         the spender/recipient of value-moving ERC20 calls inside a
    ///         governor batch (see `SyndicateVault._guardBatchCalls`). A
    ///         separate axis from (target, selector) tier certification: tiers
    ///         PRICE extractable value for coverage; this list bounds WHERE
    ///         vault funds may be approved or sent at all.
    mapping(address adapter => bool) private _adapterAllowed;

    /// @dev Grant-time codehash snapshot for the allowlist axis (issue #137).
    ///      The adversary: an allowlisted adapter whose bytecode is swapped at
    ///      the same address (metamorphic CREATE2 + SELFDESTRUCT redeploy), or
    ///      a codeless allowlisted address at which code later appears
    ///      (counterfactual CREATE2), otherwise keeps the standing right to
    ///      appear as spender/recipient of vault-fund movements until someone
    ///      happens to persist a demotion — and `poke` is unreachable
    ///      (`NotCertified`) for an allowlisted-but-uncertified adapter, so no
    ///      permissionless persistence path exists at all for that case.
    ///
    ///      INVARIANT: meaningful only while `_adapterAllowed[adapter]` is
    ///      true; records the effective codehash (see `_effectiveCodehash`)
    ///      attested at the LAST grant. Inert under a cleared flag and
    ///      unconditionally overwritten by the next grant — `_demote` and
    ///      `setAdapterAllowed(adapter, false)` do NOT clear it (design.md D1
    ///      of fix-adapter-allowlist-selfheal; keeps `_demote` and issue #51's
    ///      `DEMOTION_GAS` sizing untouched).
    ///
    ///      DEDICATED TO THE TRANSFER-PERMISSION AXIS ONLY: a future
    ///      certify-path audit trail (e.g. issue #45's certify timelock) MUST
    ///      use a SEPARATE mapping — certification tier is a per-(target,
    ///      selector) pricing axis with its own snapshot
    ///      (`TierConfig.certifiedCodehash`); repurposing this one would
    ///      re-couple the two axes exactly where they must stay independent.
    mapping(address adapter => bytes32) private _adapterAllowedCodehash;

    IERC20 public wood;
    uint256 public submitterBondWood;
    uint256 public bondReleaseDelay = 14 days;
    mapping(bytes32 configKey => SubmitterBond) internal _bonds;

    /// @notice Sum of all bonds held (active + pending release). Invariant
    ///         (spec §4): `wood.balanceOf(address(this)) == totalBondedWood`.
    uint256 public totalBondedWood;

    constructor(address initialOwner) Ownable(initialOwner) {}

    function key(address target, bytes4 selector) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(target, selector));
    }

    /// @notice Effective tier for (target, selector). Uncertified, demoted, or
    ///         codehash-mismatched entries all report (2, 10_000).
    function tierOf(address target, bytes4 selector) public view returns (uint8 tier, uint16 boundBps) {
        TierConfig storage c = _configs[key(target, selector)];
        if (c.certifiedCodehash == bytes32(0) || target.codehash != c.certifiedCodehash) {
            return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
        }
        return (c.tier, c.extractableBoundBps);
    }

    event TierCertified(
        address indexed target, bytes4 indexed selector, uint8 tier, uint16 extractableBoundBps, bytes32 codehash
    );
    event CertificationProposed(
        address indexed target,
        bytes4 indexed selector,
        uint8 tier,
        uint16 extractableBoundBps,
        address submitter,
        uint256 bondAmount,
        bytes32 codehash,
        uint64 readyAt
    );
    event CertificationCancelled(address indexed target, bytes4 indexed selector);
    event CertifyDelaySet(uint256 delay);
    event TierDemoted(address indexed target, bytes4 indexed selector);
    event AdapterAllowedSet(address indexed adapter, bool allowed);
    event SubmitterBondLocked(
        address indexed target, bytes4 indexed selector, address indexed submitter, uint256 amount
    );
    event SubmitterBondClaimed(
        address indexed target, bytes4 indexed selector, address indexed submitter, uint256 amount
    );
    event SubmitterBondConfigSet(address wood, uint256 bondWood, uint256 releaseDelay);
    event SubmitterBondReleaseStarted(
        address indexed target, bytes4 indexed selector, address indexed submitter, uint64 releasableAt
    );

    error InvalidTier();
    error BoundRequired();
    error NotAContract();
    error CodehashMatches();
    error NotCertified();
    error BondNotReleasable();
    error BondPendingRelease();
    error BondActive();
    error BondConfigUnset();
    error ZeroAddressSubmitter();
    error BondTooLarge();
    error InvalidDelay();
    error BondsOutstanding();
    error NoPendingCertification();
    error CertifyDelayNotElapsed();
    error CodehashChanged();
    error CertificationExpired();
    error NotSubmitter();

    /// @notice Set the WOOD token used for submitter bonds.
    /// @dev    Token-swap constraint: the bond token cannot change while ANY
    ///         bond is held (`BondsOutstanding`) — outstanding bonds are
    ///         denominated in the OLD token and a swap would strand them (the
    ///         claim path pays out in the new token, whose balance is zero).
    ///         Drain all bonds (demote → timelock → claim) before swapping.
    ///         Clearing the token to address(0) while the bond amount is still
    ///         armed is also rejected — zero the amount first.
    ///
    ///         `totalBondedWood != 0` is the ONLY guard here and it is
    ///         deliberately silent about pending (unexecuted) certifications:
    ///         a certification proposed while `wood` was TokenA no longer
    ///         cares what this setter does before it executes, because
    ///         `PendingCertification.bondToken` pins TokenA at proposal time
    ///         (audit finding #1) and `certify` pulls against that pinned
    ///         token, never against this live variable. Swapping `wood` here
    ///         mid-window is therefore inert to any already-pending
    ///         certification's bond economics by construction, not merely by
    ///         accident of timing.
    function setWood(address wood_) external onlyOwner {
        if (totalBondedWood != 0) revert BondsOutstanding();
        if (wood_ == address(0) && submitterBondWood != 0) revert BondConfigUnset();
        wood = IERC20(wood_);
        emit SubmitterBondConfigSet(wood_, submitterBondWood, bondReleaseDelay);
    }

    /// @notice Set the submitter bond amount pinned at `proposeCertification`
    ///         and pulled at `certify`. Zero disables the bond requirement.
    /// @dev    Bounded to uint96 so the narrowing cast into
    ///         `PendingCertification.bondAmount` (and from there into
    ///         `SubmitterBond.amount`) is provably lossless.
    function setSubmitterBondWood(uint256 amount) external onlyOwner {
        if (amount != 0 && address(wood) == address(0)) revert BondConfigUnset();
        if (amount > type(uint96).max) revert BondTooLarge();
        submitterBondWood = amount;
        emit SubmitterBondConfigSet(address(wood), amount, bondReleaseDelay);
    }

    /// @notice Set the timelock delay between demotion and submitter bond claim.
    /// @dev    Bounded to [MIN_BOND_RELEASE_DELAY, MAX_BOND_RELEASE_DELAY]. The
    ///         floor prevents a mis-certifying submitter from exiting before
    ///         the slash mechanism can act.
    function setBondReleaseDelay(uint256 delay) external onlyOwner {
        if (delay < MIN_BOND_RELEASE_DELAY || delay > MAX_BOND_RELEASE_DELAY) revert InvalidDelay();
        bondReleaseDelay = delay;
        emit SubmitterBondConfigSet(address(wood), submitterBondWood, delay);
    }

    /// @notice Announce a certification of (target, selector) at tier 0/1 with
    ///         its extractable bound. `onlyOwner`. Runs every input guard the
    ///         old instant `certify` ran, snapshots the target's current
    ///         EXTCODEHASH and the current `submitterBondWood`, and records
    ///         `readyAt = block.timestamp + certifyDelay`. Nothing takes
    ///         effect yet: `tierOf`, demotion, and the allowlist are all
    ///         unaffected by a pending certification.
    /// @dev    The adversary this two-step flow defends against is the
    ///         certification key itself: a compromised or coerced owner
    ///         certifying a malicious target at a loose bound would, under
    ///         the old instant path, reprice extractable value for every
    ///         vault in the same transaction that announces it. Splitting
    ///         propose/execute with a mandatory delay gives guardians,
    ///         depositors, and watchtowers a window — named in
    ///         `CertificationProposed` — to react before the grant is live;
    ///         see the contract-level note on the codehash check's blind spot
    ///         (proxies) for why that window is also the only practical way
    ///         to catch a proxied adapter queued at tier 0/1.
    ///
    ///         Re-proposing a key with an existing pending certification
    ///         OVERWRITES it entirely — fresh parameters, fresh codehash
    ///         snapshot, fresh pinned bond amount, fresh `readyAt`. A
    ///         re-announcement restarts the clock; it never shortens it.
    ///
    ///         NOT bond-gated: this call may run while an old bond on the
    ///         same key is still active or releasing (see D5 / the
    ///         `BondActive`/`BondPendingRelease` guards, which live in
    ///         `certify` where the new bond is actually written) — so the
    ///         certify delay and the bond-release timelock can run
    ///         concurrently instead of serializing.
    ///
    ///         `expectedCodehash` (audit finding #6) makes the owner's
    ///         off-chain review cryptographically asserted rather than
    ///         blindly re-photographed: without it, this function reads
    ///         `target.codehash` live at its OWN mining time, not at the
    ///         time the owner actually reviewed the bytecode. A gap between
    ///         review and mining (mempool, multisig confirmation latency)
    ///         lets a third party — the target's own deployer, not this
    ///         registry's owner — redeploy different bytecode at `target`
    ///         before the proposal transaction lands, silently pinning the
    ///         wrong codehash. Passing the hash the owner actually reviewed
    ///         and reverting on drift closes that gap; `certify`'s own
    ///         `CodehashChanged` check only re-verifies THIS snapshot, so it
    ///         can never catch a snapshot that was wrong from the start.
    function proposeCertification(
        address target,
        bytes4 selector,
        uint8 tier,
        uint16 extractableBoundBps,
        address submitter,
        bytes32 expectedCodehash
    ) external onlyOwner {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) revert NotAContract();
        if (ch != expectedCodehash) revert CodehashChanged();
        uint256 bondAmount = submitterBondWood;
        if (bondAmount != 0 && submitter == address(0)) revert ZeroAddressSubmitter();
        bytes32 k = key(target, selector);
        uint64 readyAt = uint64(block.timestamp + certifyDelay);
        _pending[k] = PendingCertification({
            tier: tier,
            extractableBoundBps: extractableBoundBps,
            submitter: submitter,
            readyAt: readyAt,
            // casting to 'uint96' is safe because setSubmitterBondWood rejects
            // amounts above type(uint96).max (BondTooLarge)
            // forge-lint: disable-next-line(unsafe-typecast)
            bondAmount: uint96(bondAmount),
            bondToken: wood,
            codehash: ch
        });
        emit CertificationProposed(target, selector, tier, extractableBoundBps, submitter, bondAmount, ch, readyAt);
    }

    /// @notice Execute a pending certification once its delay has elapsed.
    ///         PERMISSIONLESS when no bond is at stake (`p.bondAmount == 0`);
    ///         otherwise only the pinned `submitter` may trigger it.
    /// @dev    Safe to leave permissionless in the no-bond case because every
    ///         parameter was pinned and announced at `proposeCertification`
    ///         time: an executing third party chooses only WHEN (after
    ///         `readyAt`), never WHAT. The owner's remedies against an
    ///         execution it no longer wants are `cancelCertification` before
    ///         this runs, and instant `demote` after it lands.
    ///
    ///         When a bond IS pinned, execution is restricted to
    ///         `msg.sender == p.submitter` (audit finding #3): `submitter`
    ///         is an arbitrary, owner-chosen parameter with no signature or
    ///         `msg.sender` tie-in at proposal time, so without this check a
    ///         permissionless caller could pull the pinned bond off whatever
    ///         STANDING ERC20 allowance that address already happens to have
    ///         on this registry — never scoped to THIS certification — even
    ///         though that address never saw or approved this specific
    ///         grant. Restricting the pull-triggering call to the submitter
    ///         turns that stale allowance into live, in-the-moment consent:
    ///         the party whose funds are actually at stake is also the only
    ///         one who can put them at stake. This is a deliberate narrowing
    ///         of "anyone can trigger" to "the submitter can trigger" for
    ///         bonded certifications only — an unbonded certification still
    ///         has no funds to consent about, so it stays fully
    ///         permissionless.
    ///
    ///         Reverts `NoPendingCertification` when no proposal is pending
    ///         for the key (`readyAt == 0`), `CertifyDelayNotElapsed` before
    ///         `readyAt`, `CertificationExpired` once `MAX_CERTIFY_WINDOW`
    ///         has elapsed past `readyAt` (audit finding #5 — bounds how
    ///         stale the pinned bond's real-world value may get before it can
    ///         still post; an unbounded window lets a submitter wait out a
    ///         price collapse on the bond token's liquidity before triggering
    ///         with badly-stale collateral), `CodehashChanged` when the
    ///         target's live EXTCODEHASH no longer matches the proposal-time
    ///         snapshot — a code change mid-window voids the pending grant
    ///         instead of certifying different bytecode under an old
    ///         announcement — and `NotSubmitter` when a bond is pinned and
    ///         `msg.sender != p.submitter`. A voided pending is NOT deleted
    ///         on a failed execution (reverts don't write state): it stays
    ///         inert unless the owner `cancelCertification`s it, the
    ///         bytecode returns to the announced hash, or it ages past
    ///         `MAX_CERTIFY_WINDOW` and becomes permanently unexecutable.
    ///
    ///         The bond-conflict guards live HERE, not in
    ///         `proposeCertification`, because bond state can change during
    ///         the window (a release timelock can lapse and be claimed) and
    ///         this is the only place a new bond is actually recorded: ANY
    ///         existing bond for the key blocks execution —
    ///         `BondActive` (still held under a live certification) or
    ///         `BondPendingRelease` (demoted, in its release timelock).
    ///
    ///         The bond amount AND bond token are both PINNED at proposal
    ///         time (`p.bondAmount`, `p.bondToken` — audit finding #1) and
    ///         pulled only now (see the requirement's rationale in
    ///         `proposeCertification`'s natspec): reading the live `wood`
    ///         state variable here instead of the pinned `p.bondToken` would
    ///         let an ordinary, honest `setWood` token migration during the
    ///         window silently repoint the pull at a token the submitter
    ///         never approved for this certification. A submitter who
    ///         withholds approval on the pinned token thereby withholds the
    ///         certification: if the pull fails (allowance revoked, balance
    ///         insufficient), this call reverts entirely and the pending
    ///         record is untouched, retryable once approval is restored.
    function certify(address target, bytes4 selector) external {
        bytes32 k = key(target, selector);
        PendingCertification memory p = _pending[k];
        if (p.readyAt == 0) revert NoPendingCertification();
        if (block.timestamp < p.readyAt) revert CertifyDelayNotElapsed();
        if (block.timestamp > p.readyAt + MAX_CERTIFY_WINDOW) revert CertificationExpired();
        if (target.codehash != p.codehash) revert CodehashChanged();
        if (p.bondAmount != 0 && msg.sender != p.submitter) revert NotSubmitter();
        // ANY existing bond blocks (re-)certification — one bond per key, and
        // a live bond must never be overwritten (that would strand the old
        // submitter's WOOD in the registry with no claim path).
        SubmitterBond storage existing = _bonds[k];
        if (existing.amount != 0) {
            if (existing.releasableAt != 0) revert BondPendingRelease();
            revert BondActive();
        }
        delete _pending[k];
        if (p.bondAmount != 0) {
            _bonds[k] = SubmitterBond({submitter: p.submitter, amount: p.bondAmount, releasableAt: 0});
            totalBondedWood += p.bondAmount;
            p.bondToken.safeTransferFrom(p.submitter, address(this), p.bondAmount);
            emit SubmitterBondLocked(target, selector, p.submitter, p.bondAmount);
        }
        _configs[k] =
            TierConfig({tier: p.tier, extractableBoundBps: p.extractableBoundBps, certifiedCodehash: p.codehash});
        emit TierCertified(target, selector, p.tier, p.extractableBoundBps, p.codehash);
    }

    /// @notice Withdraw a pending certification before it executes. `onlyOwner`.
    /// @dev    Reverts `NoPendingCertification` when no proposal is pending.
    ///         Touches ONLY the pending record — any live certification, its
    ///         bond, and the allowlist for the key are unaffected, since a
    ///         cancel can target a key that already carries a certification
    ///         (a proposed replacement) as well as one that does not.
    function cancelCertification(address target, bytes4 selector) external onlyOwner {
        bytes32 k = key(target, selector);
        if (_pending[k].readyAt == 0) revert NoPendingCertification();
        delete _pending[k];
        emit CertificationCancelled(target, selector);
    }

    /// @notice Full pending-certification record for (target, selector);
    ///         zeroed struct (`readyAt == 0`) when nothing is pending.
    ///         Mirrors `bondOf` for UIs/watchtowers monitoring the queue.
    function pendingCertificationOf(address target, bytes4 selector)
        external
        view
        returns (PendingCertification memory)
    {
        return _pending[key(target, selector)];
    }

    /// @notice Set the delay between `proposeCertification` and the earliest
    ///         allowed `certify`.
    /// @dev    Bounded to [MIN_CERTIFY_DELAY, MAX_CERTIFY_DELAY]. The floor
    ///         guarantees every grant is announced for at least one full day
    ///         — the delay can never be configured back into the instant
    ///         path. The ceiling bounds governance error so a mis-set delay
    ///         cannot stall onboarding indefinitely.
    ///
    ///         `readyAt` is computed ONCE at proposal time from whatever
    ///         delay is live then (same intent-time-pinning discipline as
    ///         `releasableAt`, which reads `bondReleaseDelay` once at
    ///         demotion): changing `certifyDelay` here NEVER moves the
    ///         `readyAt` of an already-pending certification. The adversary
    ///         is an owner shortening the delay to ripen an already-announced
    ///         grant early — the emitted `readyAt` must stay trustworthy as
    ///         the earliest possible activation. The only way to apply a new
    ///         delay to an announced grant is to re-propose it, which
    ///         restarts the full window.
    function setCertifyDelay(uint256 delay) external onlyOwner {
        if (delay < MIN_CERTIFY_DELAY || delay > MAX_CERTIFY_DELAY) revert InvalidDelay();
        certifyDelay = delay;
        emit CertifyDelaySet(delay);
    }

    /// @notice The one address permitted to demote on a passed challenge — the
    ///         ChallengeGame. A ROLE rather than registry ownership, so the
    ///         game can revoke a certification but never grant one.
    address public authorizedDemoter;

    /// @notice Delay between `proposeCertification` and the earliest allowed
    ///         `certify`. Bounded to [MIN_CERTIFY_DELAY, MAX_CERTIFY_DELAY].
    ///         `readyAt` is computed once at proposal time from the delay
    ///         live at that moment — changing `certifyDelay` never moves an
    ///         already-pinned `readyAt` (see `setCertifyDelay`).
    uint256 public certifyDelay = 3 days;

    mapping(bytes32 configKey => PendingCertification) private _pending;

    error NotAuthorizedDemoter();

    event AuthorizedDemoterSet(address indexed demoter);

    /// @dev Zero is legal and deliberate — it is the UNWIRE switch, revoking
    ///      the challenge game's demotion role while a replacement is wired.
    ///      The unwired state fails CLOSED (nothing can demote), which is why
    ///      this setter carries no zero-address check.
    ///
    ///      `ChallengeGame` treats the demotion call as best-effort and emits
    ///      `AdapterDemotionFailed` on failure rather than reverting the
    ///      verdict, so this role is safe to rotate at any time; `demote`
    ///      below is the owner's remedy for any revocation a rotation misses.
    function setAuthorizedDemoter(address demoter) external onlyOwner {
        authorizedDemoter = demoter;
        emit AuthorizedDemoterSet(demoter);
    }

    /// @notice Owner demotion (revoke certification).
    /// @dev    Requires an existing certification, same as `poke` — see
    ///         `demoteByChallenge`'s natspec for why this guard exists.
    function demote(address target, bytes4 selector) external onlyOwner {
        if (_configs[key(target, selector)].certifiedCodehash == bytes32(0)) revert NotCertified();
        _demote(target, selector);
    }

    /// @notice Demote (target, selector) back to the tier-2 default because a
    ///         challenge against it passed. Reuses the same `_demote` path as
    ///         owner demotion, so the submitter-bond release timelock starts
    ///         identically.
    /// @dev    REQUIRES AN EXISTING CERTIFICATION, mirroring `poke`'s
    ///         `NotCertified` guard. Without it, `_demote`'s adapter-allowlist
    ///         clear (see its own natspec) is reachable for a `(target,
    ///         selector)` that was never certified: `ChallengeGame.file`'s
    ///         only check on the named pair is that it appears somewhere in
    ///         the executed proposal's calldata, not that TierRegistry
    ///         certified it — so a challenger could name a routine, uncertified
    ///         selector on an otherwise-legitimate, allowlisted adapter,
    ///         let the challenge settle on silence (`ChallengeGame`'s
    ///         adjudication model treats an uncontested filing as convicted),
    ///         and strip that adapter's ENTIRE fund-movement standing for
    ///         ~1% of the proposal's coverage — without anything about the
    ///         adapter ever actually being adjudicated. This guard confines
    ///         the allowlist-clearing side effect to demotions of pairs that
    ///         were real certifications.
    function demoteByChallenge(address target, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        if (_configs[key(target, selector)].certifiedCodehash == bytes32(0)) revert NotCertified();
        _demote(target, selector);
    }

    /// @notice Permissionless demotion when the live codehash no longer matches
    ///         the certified hash. Persists what `tierOf` already reports lazily.
    function poke(address target, bytes4 selector) external {
        TierConfig storage c = _configs[key(target, selector)];
        if (c.certifiedCodehash == bytes32(0)) revert NotCertified();
        if (target.codehash == c.certifiedCodehash) revert CodehashMatches();
        _demote(target, selector);
    }

    /// @dev Convergence point for all three demotion paths (owner `demote`,
    ///      `demoteByChallenge`, `poke`). ALSO clears the target's adapter
    ///      allowlist entry, emitting the existing `AdapterAllowedSet(target,
    ///      false)` if (and only if) the entry was set — a never-allowlisted
    ///      target emits no phantom event. The adversary: an adapter that was
    ///      just convicted in a challenge, or whose bytecode was just swapped
    ///      under it (the `poke` trigger), otherwise retains the standing
    ///      right to appear as spender/recipient of value-moving ERC20 calls
    ///      (approve / increaseAllowance / transfer / transferFrom-out) inside
    ///      a governor batch — tier 2 raises the coverage price but is a
    ///      price, not a prohibition.
    ///
    ///      DELIBERATELY OVER-BROAD: certification is keyed `(target,
    ///      selector)`; the allowlist is keyed by bare `address`. Demoting
    ///      ONE selector therefore de-allowlists the WHOLE adapter, even if
    ///      other selectors on it remain certified. This is the chosen,
    ///      conservative direction of error — recovery is one owner
    ///      `setAdapterAllowed(adapter, true)` call — and it is pinned by
    ///      test. Do NOT "fix" this back to a per-selector allowlist.
    ///
    ///      ALSO clears a same-key PENDING certification, if one exists
    ///      (audit finding #2): without this, a "renewal" proposed while a
    ///      certification is still live would survive that certification's
    ///      later for-cause demotion untouched, and would go on to execute
    ///      at `readyAt` re-certifying the just-convicted target — possibly
    ///      at looser terms than before the conviction. `demoteByChallenge`
    ///      has no other lever to stop this, since `cancelCertification` is
    ///      `onlyOwner`. Reuses the existing `CertificationCancelled` event
    ///      so watchtowers see the same signal as an owner cancel.
    function _demote(address target, bytes4 selector) private {
        bytes32 k = key(target, selector);
        delete _configs[k];
        if (_pending[k].readyAt != 0) {
            delete _pending[k];
            emit CertificationCancelled(target, selector);
        }
        SubmitterBond storage b = _bonds[k];
        if (b.amount != 0 && b.releasableAt == 0) {
            uint64 releasableAt = uint64(block.timestamp + bondReleaseDelay);
            b.releasableAt = releasableAt;
            emit SubmitterBondReleaseStarted(target, selector, b.submitter, releasableAt);
        }
        if (_adapterAllowed[target]) {
            delete _adapterAllowed[target];
            emit AdapterAllowedSet(target, false);
        }
        emit TierDemoted(target, selector);
    }

    /// @notice Release a demoted bond to its submitter, `bondReleaseDelay` after
    ///         demotion. PERMISSIONLESS: the payout address is fixed to the
    ///         recorded submitter, so a caller gate would protect nothing —
    ///         and it would let a lost-key submitter permanently retire a
    ///         (target, selector) key, since `certify` blocks while any bond
    ///         exists. The delay is the window the slash mechanism acts in.
    function claimSubmitterBond(address target, bytes4 selector) external {
        bytes32 k = key(target, selector);
        SubmitterBond memory b = _bonds[k];
        if (b.releasableAt == 0 || block.timestamp < b.releasableAt) revert BondNotReleasable();
        delete _bonds[k];
        totalBondedWood -= b.amount;
        wood.safeTransfer(b.submitter, b.amount);
        emit SubmitterBondClaimed(target, selector, b.submitter, b.amount);
    }

    /// @notice Full bond record for (target, selector); `releasableAt` times
    ///         the challenge window for callers that need it. Zeroed struct
    ///         when no bond exists.
    function bondOf(address target, bytes4 selector) external view returns (SubmitterBond memory) {
        return _bonds[key(target, selector)];
    }

    // ── Adapter allowlist (spender/recipient gate for value-moving selectors) ──

    /// @dev EXTCODEHASH of `a`, normalized so a non-existent account
    ///      (`bytes32(0)`, EIP-1052) and an existing account with no code
    ///      (`_EMPTY_CODEHASH`) both read as `bytes32(0)` — "no code" is one
    ///      value. Without this, merely funding a codeless allowlisted
    ///      address (non-existent -> existing-codeless) would flip its raw
    ///      EXTCODEHASH and could be used as a 1-wei donation that griefs the
    ///      vault's funds path closed.
    function _effectiveCodehash(address a) internal view returns (bytes32) {
        bytes32 ch = a.codehash;
        return ch == _EMPTY_CODEHASH ? bytes32(0) : ch;
    }

    /// @notice Allow or disallow `adapter` as the spender/recipient of
    ///         value-moving ERC20 calls (approve / increaseAllowance /
    ///         transfer / transferFrom-out) inside governor batches.
    /// @dev    The only path that SETS this to true. `_demote` is the only
    ///         path that clears it (see `_demote` natspec for the
    ///         over-broad-by-design clear on any demotion of the adapter).
    ///         `certify` never touches this mapping — re-allowlisting after a
    ///         demotion-triggered clear is always this explicit owner call,
    ///         never a side effect of re-certification.
    ///
    ///         On the grant path (`allowed == true`), (re)writes
    ///         `_adapterAllowedCodehash[adapter]` to the adapter's CURRENT
    ///         effective codehash — every grant re-attests the code the owner
    ///         is looking at right now. Consequences: (i) the grant MUST be
    ///         made AFTER the adapter's final code is deployed and verified —
    ///         granting against a predicted (counterfactual) address snapshots
    ///         "no code" and the funds path closes the instant code appears
    ///         there (see `isAdapterAllowed`); (ii) re-granting after a
    ///         verified legitimate bytecode change at the adapter's address is
    ///         the intended recovery ceremony, mirroring the demote ->
    ///         re-certify cycle for tiers. The `false` branch does not touch
    ///         the snapshot — it is left inert and is overwritten by the next
    ///         grant (design.md D1 of fix-adapter-allowlist-selfheal).
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        _adapterAllowed[adapter] = allowed;
        if (allowed) {
            _adapterAllowedCodehash[adapter] = _effectiveCodehash(adapter);
        }
        emit AdapterAllowedSet(adapter, allowed);
    }

    /// @notice True when `adapter` may receive approvals/transfers of vault
    ///         funds through a governor batch.
    /// @dev    Fail-safe self-heal is LAZY, mirroring `tierOf`: this returns
    ///         true only when the allowlist flag is set AND the adapter's
    ///         live effective codehash still matches the grant-time snapshot
    ///         — no state write in the hot path, nothing to grief, and no
    ///         dependence on `poke` (or any demotion path) ever running.
    ///         Persistence of a `false` result into storage still comes from
    ///         `poke` / `demote` / `demoteByChallenge` (where a certification
    ///         exists) or an explicit owner `setAdapterAllowed(adapter,
    ///         false)` (the only path for an allowlisted-but-uncertified
    ///         adapter, since `poke` reverts `NotCertified` there).
    ///
    ///         The adversary: an allowlisted adapter whose bytecode is
    ///         swapped at the same address (metamorphic CREATE2 +
    ///         SELFDESTRUCT redeploy), or a codeless allowlisted address at
    ///         which code later appears (counterfactual CREATE2), otherwise
    ///         retains the standing right to appear as spender/recipient of
    ///         vault-fund movements until someone happens to persist a
    ///         demotion. `SyndicateVault._guardBatchCalls` is the sole `src/`
    ///         consumer of this read and is itself `private view` — this
    ///         function MUST stay `view` (design.md D2).
    ///
    ///         SCOPE CAVEAT (same as `tierOf`, see contract natspec): this
    ///         catches only same-address bytecode mutation, not proxy
    ///         implementation swaps — a proxy's runtime bytecode is static
    ///         across upgrades, so allowlisting a proxied adapter carries the
    ///         same governance-discipline caveat as certifying one.
    function isAdapterAllowed(address adapter) external view returns (bool) {
        return _adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter];
    }
}
