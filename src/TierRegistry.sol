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
 *      same-address bytecode mutation, i.e. metamorphic redeploys. It does NOT
 *      catch proxy implementation swaps — a proxy's runtime bytecode is static
 *      across upgrades, so the certified hash keeps matching while the behavior
 *      behind it changes arbitrarily. Governance MUST NOT certify proxied
 *      adapters at tier 0/1.
 *
 *      THIS RULE IS NOT LIMITED TO RECOGNIZED PROXY SHAPES. ANY target exposing
 *      ordinary, non-`immutable` storage that is settable after deployment and
 *      can affect fund routing — a beneficiary address, a fee sink, a swap-path
 *      parameter — can have that state rewired and be certified atomically in
 *      the same transaction, since its codehash never moves. Treat certifiable
 *      at tier 0/1 as bytecode-AND-storage-immutable for every fund-routing
 *      parameter: review the target's full storage layout for post-deployment
 *      setters, not just the presence or absence of a delegatecall.
 *
 *      GRANTING is announced, not instant: `proposeCertification` (owner-only)
 *      records intent and pins the target's codehash and bond amount; `certify`
 *      executes it no earlier than `certifyDelay` later, and only if the live
 *      codehash still matches. The announcement window is the enforcement aid
 *      for the proxy-discipline rule above. REVOKING stays instant — the delay
 *      applies only to granting a lower tier, never to revoking one.
 */
contract TierRegistry is Ownable2Step {
    using SafeERC20 for IERC20;

    struct TierConfig {
        uint8 tier; // 0 or 1 when certified; entry absent => tier 2
        uint16 extractableBoundBps; // certified extractable bound, bps of notional
        bytes32 certifiedCodehash; // EXTCODEHASH of target at certification
    }

    /// @dev Submitter bond per certification. Held while certified; demotion
    ///      starts `bondReleaseDelay`, then the submitter claims. The delay gives
    ///      the slash mechanism a window to act before the bond can be pulled out
    ///      from under it.
    ///
    ///      `token` pins the ERC20 this specific bond was actually PULLED in.
    ///      `certify` pins `PendingCertification.bondToken` so the PULL cannot be
    ///      repointed by an intervening `setWood`, but the REFUND reading the LIVE
    ///      `wood` variable meant that pin never reached payout: two
    ///      certifications under two tokens would let the first claimant drain the
    ///      second submitter's collateral out of a shared balance, and a single
    ///      `setWood` would strand a bond permanently (no sweep exists and the
    ///      contract is non-upgradeable). Recording the token on the bond makes
    ///      every later state of `wood` irrelevant to an already-locked payout.
    struct SubmitterBond {
        address submitter;
        uint96 amount;
        uint64 releasableAt; // 0 while certified; set on demotion
        IERC20 token; // pinned at certify time (audit finding #3)
    }

    /// @dev A proposed-but-not-yet-executed certification. `readyAt == 0` is the
    ///      existence sentinel. `codehash`, `bondAmount` and `bondToken` are
    ///      pinned at proposal time so permissionless execution can only choose
    ///      WHEN, never WHAT.
    ///
    ///      `bondToken` pins the live `wood` at proposal time: without it, an
    ///      ordinary token migration during the certify-delay window would make
    ///      `certify` pull the pinned AMOUNT denominated in a token the submitter
    ///      never approved for this certification, and `setWood`'s only guard
    ///      cannot see an unexecuted pending bond.
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

    /// @dev Upper bound on how long after `readyAt` a pending certification may
    ///      still be executed. Without it a submitter fully controls WHEN to
    ///      trigger the permissionless execute and can wait out a price collapse
    ///      on the bond token before posting badly-stale collateral against an
    ///      unchanged extractable bound. A fixed constant, not owner-configurable,
    ///      so the owner has no lever to expire someone else's pending
    ///      certification early.
    uint256 public constant MAX_CERTIFY_WINDOW = 14 days;

    /// @dev EXTCODEHASH of an EXISTING account with no code (EIP-1052). A funded
    ///      EOA hashes to this, not bytes32(0) — `certify` rejects both.
    bytes32 private constant _EMPTY_CODEHASH = keccak256("");

    mapping(bytes32 configKey => TierConfig) private _configs;

    /// @notice Owner-managed allowlist of adapter addresses that may appear as the
    ///         spender/recipient of value-moving ERC20 calls inside a governor
    ///         batch. A separate axis from (target, selector) tier certification:
    ///         tiers PRICE extractable value for coverage; this list bounds WHERE
    ///         vault funds may be approved or sent at all.
    ///
    ///         SECOND CONSUMER: also the predicate for whether a target may be
    ///         reached by a governor batch AT ALL (`_guardBatchCalls` PART 2a) —
    ///         same mapping, same owner ceremony, not a second allowlist.
    ///         `asset()` is the sole exempt callee. GOVERNANCE DISCIPLINE:
    ///         exotic-asset contracts (ERC-721/1155/777 and other position
    ///         tokens) MUST NOT be allowlisted here as batch callees — their
    ///         non-ERC20 selectors are not examined by the selector switch.
    ///         Batches reach such positions through allowlisted adapters instead.
    mapping(address adapter => bool) private _adapterAllowed;

    /// @dev Grant-time codehash snapshot for the allowlist axis. The adversary: an
    ///      allowlisted adapter whose bytecode is swapped at the same address, or
    ///      a codeless allowlisted address at which code later appears, otherwise
    ///      keeps the standing right to receive vault-fund movements until someone
    ///      persists a demotion — and `poke` is unreachable for an
    ///      allowlisted-but-uncertified adapter, so no permissionless persistence
    ///      path exists at all for that case.
    ///
    ///      INVARIANT: meaningful only while `_adapterAllowed[adapter]` is true.
    ///      Inert under a cleared flag and unconditionally overwritten by the next
    ///      grant — `_demote` and `setAdapterAllowed(adapter, false)` do NOT clear
    ///      it. DEDICATED TO THE TRANSFER-PERMISSION AXIS ONLY: a certify-path
    ///      audit trail MUST use a SEPARATE mapping, since certification tier is a
    ///      per-(target, selector) pricing axis with its own snapshot.
    mapping(address adapter => bytes32) private _adapterAllowedCodehash;

    IERC20 public wood;
    /// @dev LAUNCH GATE: a non-zero value is inert as a warranty — and imposes a
    ///      real, currently-unrecoverable cost on adapter submitters — until ALL
    ///      THREE hold:
    ///        1. a guard-bypass slash function exists and can reach `_bonds`;
    ///        2. a seated court can enforce a DISPUTED slash, since a disputed
    ///           challenge currently times out in the accused's favour;
    ///        3. third-party adapter submission actually exists, so the bond
    ///           filters submitters rather than merely deterring the only
    ///           participant with no revenue from the adapter it warrants.
    ///      The deploy script never calls `setSubmitterBondWood`, so this stays
    ///      `0` at launch — do not enable it without meeting the gate above.
    uint256 public submitterBondWood;
    uint256 public bondReleaseDelay = 14 days;
    mapping(bytes32 configKey => SubmitterBond) internal _bonds;

    /// @notice Sum of all bonds held (active + pending release), across every
    ///         token a bond has ever been pulled in.
    /// @dev    NOT `wood.balanceOf(address(this)) == totalBondedWood`: each bond
    ///         carries its OWN pinned token, so once bonds under two tokens
    ///         coexist this sum spans both balances. What holds per token `t` is
    ///         `t.balanceOf(this) >= sum(amount for bonds where token == t)`. The
    ///         scalar is used only as the `BondsOutstanding` existence gate in
    ///         `setWood` — zero iff no bond, in any token, is currently held.
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
    /// @dev    The bond token cannot change while ANY bond is held. This is
    ///         defense-in-depth, not load-bearing for fund safety: every bond pins
    ///         its OWN token at certify time and `claimSubmitterBond` pays out
    ///         against that pinned field, so an already-locked bond can no longer
    ///         be stranded, misdirected, or pointed at `address(0)` by a swap. The
    ///         guard is kept because letting bonds accumulate under multiple live
    ///         tokens is unmaintainable operationally. Drain all bonds before
    ///         swapping; clearing the token to zero while the bond amount is still
    ///         armed is also rejected.
    ///
    ///         Deliberately silent about pending (unexecuted) certifications: one
    ///         proposed while `wood` was TokenA pins TokenA at proposal time and
    ///         `certify` pulls against that pinned token, then writes it onto the
    ///         new bond, so swapping `wood` mid-window is inert to any pending
    ///         certification's bond economics at both steps.
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

    /// @notice Announce a certification of (target, selector) at tier 0/1 with its
    ///         extractable bound. `onlyOwner`. Runs every input guard, snapshots
    ///         the target's current EXTCODEHASH and the current
    ///         `submitterBondWood`, and records `readyAt`. Nothing takes effect
    ///         yet.
    /// @dev    The adversary is the certification key itself: a compromised or
    ///         coerced owner certifying a malicious target at a loose bound would,
    ///         under an instant path, reprice extractable value for every vault in
    ///         the same transaction that announces it. The mandatory delay gives
    ///         guardians and watchtowers a window — named in
    ///         `CertificationProposed` — to react, and it is also the only
    ///         practical way to catch a proxied adapter queued at tier 0/1.
    ///
    ///         Re-proposing a key OVERWRITES any existing pending certification
    ///         entirely and restarts the clock; it never shortens it.
    ///
    ///         NOT bond-gated: this may run while an old bond on the same key is
    ///         still active or releasing, so the certify delay and the
    ///         bond-release timelock can run concurrently instead of serializing.
    ///         The bond-conflict guards live in `certify`, where the new bond is
    ///         actually written.
    ///
    ///         `expectedCodehash` makes the owner's off-chain review
    ///         cryptographically asserted rather than blindly re-photographed:
    ///         reading `target.codehash` live at THIS transaction's mining time
    ///         lets a third party — the target's own deployer — redeploy different
    ///         bytecode before the proposal lands, silently pinning the wrong
    ///         hash. `certify`'s own `CodehashChanged` check only re-verifies THIS
    ///         snapshot, so it can never catch a snapshot that was wrong from the
    ///         start.
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
    ///         PERMISSIONLESS when no bond is at stake; otherwise only the pinned
    ///         `submitter` may trigger it.
    /// @dev    Safe to leave permissionless in the no-bond case because every
    ///         parameter was pinned and announced at proposal time: an executing
    ///         third party chooses only WHEN, never WHAT. The owner's remedies are
    ///         `cancelCertification` before this runs and instant `demote` after.
    ///
    ///         When a bond IS pinned, execution is restricted to the submitter:
    ///         `submitter` is an owner-chosen parameter with no signature tie-in,
    ///         so without this a permissionless caller could pull the pinned bond
    ///         off whatever STANDING ERC20 allowance that address already has on
    ///         this registry — never scoped to THIS certification — even though it
    ///         never approved this specific grant. Restricting the trigger turns a
    ///         stale allowance into live, in-the-moment consent.
    ///
    ///         Reverts `NoPendingCertification` when nothing is pending,
    ///         `CertifyDelayNotElapsed` before `readyAt`, `CertificationExpired`
    ///         once `MAX_CERTIFY_WINDOW` has elapsed past it, `CodehashChanged`
    ///         when the live EXTCODEHASH no longer matches the proposal-time
    ///         snapshot, and `NotSubmitter` when a bond is pinned and the caller
    ///         is not the submitter. A voided pending is NOT deleted on a failed
    ///         execution: it stays inert unless cancelled, unless the bytecode
    ///         returns to the announced hash, or until it ages past the window.
    ///
    ///         The bond-conflict guards live HERE because bond state can change
    ///         during the window: ANY existing bond for the key blocks execution,
    ///         whether still held (`BondActive`) or in its release timelock
    ///         (`BondPendingRelease`). Both the bond amount and token are pinned
    ///         at proposal time and pulled only now. A submitter who withholds
    ///         approval on the pinned token thereby withholds the certification:
    ///         the call reverts entirely and the pending record is untouched,
    ///         retryable once approval is restored.
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
            _bonds[k] =
                SubmitterBond({submitter: p.submitter, amount: p.bondAmount, releasableAt: 0, token: p.bondToken});
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
    /// @dev    Bounded to `[MIN_CERTIFY_DELAY, MAX_CERTIFY_DELAY]`. The floor
    ///         guarantees every grant is announced for at least a full day, so the
    ///         delay can never be configured back into the instant path; the
    ///         ceiling bounds governance error.
    ///
    ///         `readyAt` is computed ONCE at proposal time from whatever delay is
    ///         live then, so changing this NEVER moves an already-pending
    ///         certification's `readyAt`. The adversary is an owner shortening the
    ///         delay to ripen an already-announced grant early — the emitted
    ///         `readyAt` must stay trustworthy as the earliest possible
    ///         activation. Applying a new delay requires re-proposing.
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

    /// @dev Zero is legal and deliberate — the UNWIRE switch, revoking the
    ///      challenge game's demotion role while a replacement is wired. The
    ///      unwired state fails CLOSED, which is why there is no zero check.
    ///      `ChallengeGame` treats the demotion call as best-effort and emits
    ///      rather than reverting the verdict, so this role is safe to rotate at
    ///      any time; `demote` is the owner's remedy for anything a rotation
    ///      misses.
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
    ///         owner demotion, so the bond release timelock starts identically.
    /// @dev    REQUIRES AN EXISTING CERTIFICATION, mirroring `poke`. Without it,
    ///         `_demote`'s adapter-allowlist clear is reachable for a pair that
    ///         was never certified: `ChallengeGame.file` only checks that the
    ///         named pair appears somewhere in the executed proposal's calldata,
    ///         so a challenger could name a routine, uncertified selector on an
    ///         otherwise-legitimate allowlisted adapter, let the challenge settle
    ///         on silence, and strip that adapter's ENTIRE fund-movement standing
    ///         for ~1% of the proposal's coverage — without the adapter ever being
    ///         adjudicated.
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

    /// @dev Convergence point for all three demotion paths. ALSO clears the
    ///      target's adapter allowlist entry, emitting only if the entry was set.
    ///      The adversary: an adapter just convicted in a challenge, or whose
    ///      bytecode was just swapped under it, otherwise retains the standing
    ///      right to receive value-moving ERC20 calls inside a governor batch —
    ///      tier 2 raises the coverage price but is a price, not a prohibition.
    ///
    ///      DELIBERATELY OVER-BROAD: certification is keyed `(target, selector)`
    ///      while the allowlist is keyed by bare address, so demoting ONE selector
    ///      de-allowlists the WHOLE adapter. This is the chosen conservative
    ///      direction of error — recovery is one owner `setAdapterAllowed` call —
    ///      and it is pinned by test. Do NOT change it to a per-selector
    ///      allowlist.
    ///
    ///      ALSO clears a same-key PENDING certification: otherwise a renewal
    ///      proposed while a certification is still live would survive that
    ///      certification's later for-cause demotion and go on to execute at
    ///      `readyAt`, re-certifying the just-convicted target, possibly at looser
    ///      terms. `demoteByChallenge` has no other lever, since
    ///      `cancelCertification` is `onlyOwner`.
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
        // Pays out in the token THIS bond was pulled in (`b.token`, audit
        // finding #3), never the live `wood` state variable: `wood` can have
        // been repointed by `setWood` any number of times since this bond was
        // locked (see `SubmitterBond.token` natspec for why the live variable
        // is unsafe here — cross-token drain / permanent stranding).
        b.token.safeTransfer(b.submitter, b.amount);
        emit SubmitterBondClaimed(target, selector, b.submitter, b.amount);
    }

    /// @notice Full bond record for (target, selector); `releasableAt` times
    ///         the challenge window for callers that need it. Zeroed struct
    ///         when no bond exists.
    function bondOf(address target, bytes4 selector) external view returns (SubmitterBond memory) {
        return _bonds[key(target, selector)];
    }

    // ── Adapter allowlist (spender/recipient gate for value-moving selectors) ──

    /// @dev EXTCODEHASH of `a`, normalized so a non-existent account and an
    ///      existing account with no code both read as `bytes32(0)` — no-code is
    ///      one value. Without this, merely funding a codeless allowlisted address
    ///      would flip its raw EXTCODEHASH and could be used as a 1-wei donation
    ///      that griefs the vault's funds path closed.
    function _effectiveCodehash(address a) internal view returns (bytes32) {
        bytes32 ch = a.codehash;
        return ch == _EMPTY_CODEHASH ? bytes32(0) : ch;
    }

    /// @notice Allow or disallow `adapter` as the spender/recipient of value-moving
    ///         ERC20 calls inside governor batches, AND as a batch callee at all —
    ///         a target that fails this check cannot be named in a governor batch
    ///         regardless of selector or calldata. Exotic-asset contracts
    ///         (ERC-721/1155/777, LP-position NFTs) MUST NOT be allowlisted here
    ///         as batch callees; batches should reach such positions through
    ///         allowlisted adapters instead.
    /// @dev    The only path that SETS this to true. `_demote` is the only path
    ///         that clears it, over-broadly by design. `certify` never touches
    ///         this mapping — re-allowlisting after a demotion-triggered clear is
    ///         always this explicit owner call.
    ///
    ///         On the grant path, (re)writes `_adapterAllowedCodehash[adapter]` to
    ///         the adapter's CURRENT effective codehash, so every grant re-attests
    ///         the code the owner is looking at right now. Consequences: the grant
    ///         MUST be made AFTER the adapter's final code is deployed, since
    ///         granting against a counterfactual address snapshots no-code and the
    ///         funds path closes the instant code appears; and re-granting after a
    ///         verified legitimate bytecode change is the intended recovery
    ///         ceremony. The `false` branch leaves the snapshot inert.
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        _adapterAllowed[adapter] = allowed;
        if (allowed) {
            _adapterAllowedCodehash[adapter] = _effectiveCodehash(adapter);
        }
        emit AdapterAllowedSet(adapter, allowed);
    }

    /// @notice True when `adapter` may receive approvals/transfers of vault funds
    ///         through a governor batch, AND whether it may be named as a batch
    ///         callee at all — the two roles are deliberately the collapsed same
    ///         predicate.
    /// @dev    Fail-safe self-heal is LAZY, mirroring `tierOf`: true only when the
    ///         allowlist flag is set AND the adapter's live effective codehash
    ///         still matches the grant-time snapshot — no state write in the hot
    ///         path, nothing to grief, and no dependence on any demotion path ever
    ///         running. Persistence of a `false` result still comes from
    ///         `poke`/`demote`/`demoteByChallenge` where a certification exists, or
    ///         an explicit owner `setAdapterAllowed(adapter, false)` — the only
    ///         path for an allowlisted-but-uncertified adapter.
    ///
    ///         The adversary: an allowlisted adapter whose bytecode is swapped at
    ///         the same address, or a codeless allowlisted address at which code
    ///         later appears, otherwise retains the standing right to receive
    ///         vault-fund movements until someone persists a demotion.
    ///         `SyndicateVault._guardBatchCalls` is the sole `src/` consumer and
    ///         is itself `private view`, so this MUST stay `view`.
    ///
    ///         SCOPE CAVEAT, same as `tierOf`: this catches only same-address
    ///         bytecode mutation, not proxy implementation swaps.
    function isAdapterAllowed(address adapter) external view returns (bool) {
        return _adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter];
    }
}
