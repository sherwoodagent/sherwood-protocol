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
        IERC20 token;
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
        IERC20 bondToken; // ┘
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

    ///      three cases reject the two obvious wrong fixes (never clearing the
    ///      bit, and exempting in-flight positions vault-side).
    mapping(address adapter => bool) private _calleeAllowed;

    /// @dev EXPLICIT owner revocation of the callee axis, and the reason it
    ///      needs its own slot. `_classAllowDenied` cannot serve: `_demote`
    ///      writes it too, so honouring it in `isCallableTarget` would re-close
    ///      the axis for exactly the demoted class-certified clones this split
    ///      exists to rescue. It is also the only flag that reaches a class
    ///      member, which has no address entry for a cleared `_calleeAllowed`
    ///      to bite — and anyone may permissionlessly deploy an ERC-1167 clone
    ///      of a certified template to become one.
    ///
    ///      Set ONLY by `setCallable(a, false)`; cleared by `setCallable(a,
    ///      true)` and by a full re-grant. Neither `_demote` nor
    ///      `setAdapterAllowed(a, false)` touches it: both say "you may not be
    ///      PAID again", never "the vault has no further business with you".
    mapping(address adapter => bool) private _calleeRevoked;

    /// @dev The CLASS half of the callee axis, mirroring `_calleeAllowed` on the
    ///      address half. Set by `setClassAllowed(t, true)`, cleared only by
    ///      `setClassCallable(t, false)`; neither `_demoteClass` nor
    ///      `setClassAllowed(t, false)` touches it.
    ///
    ///      Without this the split did nothing for the case it most needed to
    ///      cover. A per-proposal strategy clone has NO address entry — class
    ///      standing is the only standing it ever had — so a class conviction
    ///      cleared `_classAllowed`, `isCallableTarget`'s fallback read false,
    ///      and the vault again could not reach the clone holding its capital.
    ///      The address-entry version of the test passed regardless, which is
    ///      why this went unnoticed until a class-clone test was written.
    mapping(bytes32 classCodehash => bool) private _classCalleeAllowed;

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

    /// @dev THE OTHER AXIS: addresses a STRATEGY TEMPLATE may bind as a
    ///      counterparty, without any of the batch-callee, approve-spender or
    ///      transfer-recipient standing `_adapterAllowed` confers.
    ///
    ///      Exists because those are genuinely different questions and the
    ///      answer to one is not the answer to the other. `_adapterAllowed`'s
    ///      own contract says exotic-asset contracts — "ERC-721/1155/777,
    ///      LP-position NFTs" — MUST NOT be listed on it, yet a concentrated-
    ///      liquidity template has to bind a Uniswap position manager, which is
    ///      exactly an LP-position NFT. Forcing that binding through the
    ///      adapter axis would make operating the template require an entry the
    ///      adapter axis forbids, and would widen the vault's batch guard for
    ///      the position manager and for Morpho as a side effect of a decision
    ///      about a strategy.
    ///
    ///      Strictly weaker than `_adapterAllowed`, and implied by it: see
    ///      `isCounterpartyAllowed`.
    ///
    ///      WHAT IT WITHHOLDS IS BATCH REACHABILITY, NOT FUND CONTACT. An
    ///      earlier version of this note said "nothing that reads this may spend
    ///      vault funds on the strength of it", which is false and was corrected
    ///      every address it binds here. The real boundary is whose calldata
    ///      does the approving — a certified template's own reviewed code, not a
    ///      proposer-authored governor batch. Every `isAdapterAllowed` read in
    ///      `SyndicateVault` sits inside `_guardBatchCalls` iterating `calls[]`,
    ///      so that is precisely the capability this axis does not confer.
    mapping(address counterparty => bool) private _counterpartyAllowed;

    /// @dev Grant-time codehash snapshot for the counterparty axis, mirroring
    ///      `_adapterAllowedCodehash` and for the same adversary: a grant made
    ///      against a codeless address, or bytecode swapped at a listed one.
    ///      Meaningful only while `_counterpartyAllowed[x]` is true.
    mapping(address counterparty => bytes32) private _counterpartyAllowedCodehash;

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

    /// @notice The runtime EXTCODEHASH every ERC-1167 minimal-proxy clone of
    ///         `template` will have.
    /// @dev    OpenZeppelin `Clones.clone` (OZ 5.6.1,
    ///         lib/openzeppelin-contracts/contracts/proxy/Clones.sol) deploys the
    ///         standard 45-byte ERC-1167 runtime:
    ///
    ///             363d3d373d3d3d363d73 <template:20> 5af43d82803e903d91602b57fd5bf3
    ///
    ///         The implementation address is baked into the bytecode, so every
    ///         clone of one template is byte-identical and a matching codehash
    ///         is self-verifying proof of "clone of `template`" — no factory
    ///         record and no proposer-supplied claim (design.md Decision 1).
    ///
    ///         PURE, and deliberately so: it derives what a clone WOULD hash to,
    ///         never reads chain state. Membership is decided by the caller
    ///         comparing this against a live `EXTCODEHASH` — see
    ///         `_classMemberOf`, which also carries the second-level template
    ///         check this derivation cannot provide.
    ///
    ///         The byte layout is pinned by test against a real
    ///         `StrategyFactory` clone. If the factory ever moves to a clone
    ///         variant that writes per-instance data into the clone's bytecode
    ///         (clones-with-immutable-args), every clone gets a distinct
    ///         codehash, this derivation silently matches nothing, and every
    ///         class dissolves to the tier-2 default with no revert anywhere —
    ///         which is why that migration is barred by spec, not by comment
    ///         (tier-policy: "Class-certifiable templates are cloned without
    ///         per-instance bytecode").
    function cloneCodehashOf(address template) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(hex"363d3d373d3d3d363d73", template, hex"5af43d82803e903d91602b57fd5bf3"));
    }

    /// @notice Config key for a code class. Distinct namespace from `key`.
    /// @dev    Class entries live in their own mapping (`_classConfigs`), so
    ///         aliasing between the two keying modes is structurally impossible
    ///         rather than merely improbable — an address entry cannot be
    ///         written or demoted through a class entry point, or vice versa
    ///         (tier-policy: "Address and class keys never collide"). The
    ///         preimages also differ in length (24 vs 36 bytes), so even a
    ///         shared mapping could not be made to collide through
    ///         `encodePacked` ambiguity; the separate mapping is belt and
    ///         braces on a security boundary.
    function classKey(bytes32 cloneCodehash, bytes4 selector) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(cloneCodehash, selector));
    }

    /// @notice Effective tier for (target, selector). Uncertified, demoted, or
    ///         codehash-mismatched entries all report (2, 10_000).
    /// @dev Lookup order is address entry, then per-address DENIAL, then code
    ///      class, then the tier-2 default. Address ALWAYS wins (design.md
    ///      Decision 3), and that holds in BOTH directions: a live address entry
    ///      out-prices the class, and an address demoted for cause is barred
    ///      from reading the class at all. Without the middle step the second
    ///      half was false — `_demote` erases the address entry, and erasure
    ///      alone would drop the target straight into the permissive fallback,
    ///      restoring the standing the demotion just took away.
    ///
    ///      The hot path pays for neither extra step on an address hit.
    function tierOf(address target, bytes4 selector) public view returns (uint8 tier, uint16 boundBps) {
        bytes32 k = key(target, selector);
        TierConfig storage c = _configs[k];
        if (c.certifiedCodehash != bytes32(0) && target.codehash == c.certifiedCodehash) {
            return (c.tier, c.extractableBoundBps);
        }
        // A demotion against THIS address stops here: the class must not undo
        // what an owner or a challenge conviction just revoked.
        if (_classTierDenied[k]) return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
        // Class fallback. `_classOf` returns 0 unless the target is a live
        // ERC-1167 clone of a certified template whose own code is unchanged.
        bytes32 cch = _classOf(target);
        if (cch != bytes32(0)) {
            TierConfig storage cc = _classConfigs[classKey(cch, selector)];
            if (cc.certifiedCodehash != bytes32(0)) return (cc.tier, cc.extractableBoundBps);
        }
        return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
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
    event CalleeAllowedSet(address indexed target, bool callable);
    /// @notice The counterparty axis moved for `counterparty`. Distinct from
    ///         `AdapterAllowedSet` so an indexer can tell "may be bound by a
    ///         strategy" from "may receive vault funds through a batch".
    event CounterpartyAllowedSet(address indexed counterparty, bool allowed);
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
        if (!_isCertifiedFor(target, selector)) revert NotCertified();
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
    ///
    ///         ACCEPTS A CLASS-ONLY MEMBER (see `_isCertifiedFor`). Restricting
    ///         this to address entries made the whole class axis unreachable
    ///         from adjudication: the normal class-certified clone has no
    ///         address entry, so this reverted `NotCertified` into
    ///         `ChallengeGame`'s bare catch and a won challenge produced only an
    ///         `AdapterDemotionFailed` event. The anti-grief guard is unchanged
    ///         in substance — an uncertified selector is still rejected.
    ///
    ///         A PENDING CERTIFICATION IS CANCELLED AHEAD OF THAT GUARD, and
    ///         cancelling one satisfies the call on its own: a demotion taken
    ///         before the verdict lands leaves the key uncertified, so the
    ///         guard would otherwise revert and roll the cancellation back,
    ///         letting the re-proposal ripen through the conviction.
    function demoteByChallenge(address target, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        bytes32 k = key(target, selector);
        bool cancelled = _pending[k].readyAt != 0;
        if (cancelled) {
            delete _pending[k];
            emit CertificationCancelled(target, selector);
        }
        if (!_isCertifiedFor(target, selector)) {
            if (cancelled) return;
            revert NotCertified();
        }
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

    function _demote(address target, bytes4 selector) private {
        bytes32 k = key(target, selector);
        delete _configs[k];
        if (!_classTierDenied[k]) {
            _classTierDenied[k] = true;
            emit ClassMemberTierDenied(target, selector);
        }
        if (!_classAllowDenied[target]) {
            _classAllowDenied[target] = true;
            emit ClassMemberAllowDenied(target, true);
        }
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
        if (_counterpartyAllowed[target]) {
            delete _counterpartyAllowed[target];
            emit CounterpartyAllowedSet(target, false);
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
    ///         ERC20 calls inside governor batches. `true` opens the callee axis
    ///         with it; `false` closes this axis only and leaves `setCallable`
    ///         the switch for "never call this again". Exotic-asset contracts
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
    ///
    ///         BOTH BRANCHES ALSO MOVE `_classAllowDenied`, so this call is a
    ///         decision about the address rather than about one of the two
    ///         paths that can grant it. `false` must SET the denial or the owner
    ///         cannot disallow a single class member at all — the class fallback
    ///         re-allows it on the very next read. `true` clears it, making this
    ///         the recovery ceremony after a demotion, exactly as it already was
    ///         for the address path.
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        _adapterAllowed[adapter] = allowed;
        if (allowed) {
            _calleeRevoked[adapter] = false;
            _calleeAllowed[adapter] = true;
            _adapterAllowedCodehash[adapter] = _effectiveCodehash(adapter);
            if (_classAllowDenied[adapter]) {
                delete _classAllowDenied[adapter];
                emit ClassMemberAllowDenied(adapter, false);
            }
        } else if (!_classAllowDenied[adapter]) {
            _classAllowDenied[adapter] = true;
            emit ClassMemberAllowDenied(adapter, true);
        }
        emit AdapterAllowedSet(adapter, allowed);
    }

    /// @notice Open or close the callee axis for `target` — a POST-SETTLEMENT
    ///         action, taken once the vault holds nothing there. `onlyOwner`.
    function setCallable(address target, bool callable) external onlyOwner {
        _calleeRevoked[target] = !callable;
        emit CalleeAllowedSet(target, callable);
    }

    /// @notice True when `adapter` may receive approvals/transfers of vault funds
    ///         through a governor batch. Whether it may be named as a batch
    ///         callee at all is the separate `isCallableTarget` predicate, which
    ///         a demotion or an owner delisting deliberately leaves open.
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
    ///
    ///         CLASS FALLBACK: on an address miss, the adapter is allowed if it
    ///         is a live member of an allowlisted code class — same ordering as
    ///         `tierOf` (address first, class second), same two-level check, and
    ///         the same per-address denial ahead of it, so an adapter demoted
    ///         for cause or explicitly disallowed by the owner cannot re-acquire
    ///         standing from its class on the next read.
    function isAdapterAllowed(address adapter) public view returns (bool) {
        if (_adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter]) {
            return true;
        }
        if (_classAllowDenied[adapter]) return false;
        bytes32 cch = _classOf(adapter);
        return cch != bytes32(0) && _classAllowed[cch];
    }

    /// @notice May the vault CALL `target` inside a governor batch? This is the
    ///         question `SyndicateVault._guardBatchCalls` PART 2a asks, and the
    ///         ONLY one it asks — a `true` here confers no right to receive
    ///         value, which PART 2b gates separately on `isAdapterAllowed`.
    function isCallableTarget(address target) public view returns (bool) {
        // An explicit `setCallable(target, false)` closes this axis outright,
        // including via the class path below. Neither `_demote` nor
        // `setAdapterAllowed(target, false)` sets this flag, so a CONVICTED or
        // delisted clone stays reachable for the settlement batch that reclaims
        // the vault's capital — which is the entire point of the split.
        if (_calleeRevoked[target]) return false;
        if (_calleeAllowed[target] && _effectiveCodehash(target) == _adapterAllowedCodehash[target]) {
            return true;
        }
        bytes32 cch = _classOf(target);
        return cch != bytes32(0) && _classCalleeAllowed[cch];
    }

    /// @notice Allow or disallow `counterparty` as an address a STRATEGY
    ///         TEMPLATE may bind — a lending market, a position manager, a
    ///         collateral token. Confers NONE of `setAdapterAllowed`'s standing:
    ///         nothing listed here becomes a batch callee, an approve spender or
    ///         a transfer recipient by virtue of this call.
    /// @dev    A LISTED COUNTERPARTY WILL RECEIVE TOKEN APPROVALS. That is not
    ///         a contradiction of the line above and it is worth stating
    ///         plainly, because the natural reading of "weaker grant" is
    ///         "cannot touch funds" and that reading is wrong: a template binds
    ///         a lending market precisely in order to approve and supply to it.
    ///         What the grant withholds is appearing in a governor batch, whose
    ///         calldata a proposer writes freely. Grant this the same way you
    ///         would grant the strong one — against code you have read.
    /// @dev    The point of the separation is that `setAdapterAllowed`'s own
    ///         contract forbids listing exotic-asset contracts ("ERC-721/1155/
    ///         777, LP-position NFTs"), while a concentrated-liquidity template
    ///         must bind a Uniswap position manager, which is one. Without this
    ///         axis an owner has to choose between not running the template and
    ///         making an entry the other axis tells them not to make.
    ///
    ///         Snapshots the codehash on the grant path exactly as
    ///         `setAdapterAllowed` does, with the same consequence: grant AFTER
    ///         the counterparty's final code is deployed, and re-grant as the
    ///         recovery ceremony after a verified legitimate bytecode change.
    ///
    ///         NO CLASS FALLBACK, deliberately. The class axis exists so one
    ///         certification can cover every clone of a template; counterparties
    ///         are long-lived singletons an owner names individually, so a
    ///         fallback would add reach without removing any ceremony.
    function setCounterpartyAllowed(address counterparty, bool allowed) external onlyOwner {
        _counterpartyAllowed[counterparty] = allowed;
        if (allowed) _counterpartyAllowedCodehash[counterparty] = _effectiveCodehash(counterparty);
        emit CounterpartyAllowedSet(counterparty, allowed);
    }

    /// @notice True when `counterparty` may be bound by a strategy template.
    /// @dev    IMPLIED BY ADAPTER STANDING. `isAdapterAllowed` is the strictly
    ///         stronger grant — it already licenses moving vault funds to the
    ///         address — so anything carrying it trivially clears the weaker
    ///         bar, and an owner who has listed a swap adapter never needs a
    ///         second entry for it. The implication runs one way only: a
    ///         counterparty entry grants nothing on the adapter axis, which is
    ///         the whole reason the axis exists.
    ///
    ///         Same SCOPE CAVEAT as `tierOf` and `isAdapterAllowed`: the
    ///         codehash check catches same-address bytecode mutation, not proxy
    ///         implementation swaps.
    function isCounterpartyAllowed(address counterparty) external view returns (bool) {
        if (
            _counterpartyAllowed[counterparty]
                && _effectiveCodehash(counterparty) == _counterpartyAllowedCodehash[counterparty]
        ) {
            return true;
        }
        return isAdapterAllowed(counterparty);
    }

    // ── CODEHASH-CLASS CERTIFICATION ──
    //
    // Every proposal deploys a fresh ERC-1167 clone at a fresh address, so
    // address-keyed consent costs one owner ceremony per proposal, forever.
    // Clones of one template are byte-identical, so a codehash identifies the
    // template and certifying it covers every clone that will ever exist.
    //
    // A class certification asserts a STRICTLY STRONGER claim than an address
    // one: that the bound holds under EVERY initialization, not for one
    // deployment's stored config. Which templates may carry that claim is a
    // governance rule (tier-policy: "Only conformant templates may be
    // class-certified"), not a check this contract can make.

    /// @dev Per-class anchor, shared by both axes. Keyed by clone codehash.
    ///
    ///      `templateCodehash` is load-bearing: a clone's codehash embeds the
    ///      template's ADDRESS, not its CODE, so mutating the template in place
    ///      changes every clone's behaviour while leaving every clone's codehash
    ///      identical. Without this snapshot the class would keep vouching for
    ///      hostile code across every clone at once — strictly worse than the
    ///      address path. Adversary: metamorphic CREATE2 redeploy of the
    ///      template after certification.
    struct ClassAnchor {
        address template;
        bytes32 templateCodehash;
    }

    /// @dev A proposed-but-not-yet-executed class certification. Mirrors
    ///      `PendingCertification` field-for-field on the bond/timelock half —
    ///      same pins, same rationale — and adds the template identity the
    ///      address form has no need for. `readyAt == 0` is the existence
    ///      sentinel.
    struct PendingClassCertification {
        uint8 tier;
        uint16 extractableBoundBps;
        address submitter;
        uint64 readyAt;
        uint96 bondAmount;
        IERC20 bondToken; // ┘
        address template;
        bytes32 templateCodehash;
    }

    /// @dev class fingerprint (clone codehash) => anchor. One per class,
    ///      shared by the tier and allowlist axes.
    mapping(bytes32 cloneCodehash => ClassAnchor) private _classAnchors;

    /// @dev `classKey(cloneCodehash, selector)` => tier config. A SEPARATE
    ///      mapping from `_configs`, so an address entry can never be written
    ///      or demoted through a class entry point or vice versa — namespace
    ///      isolation is structural here, not merely improbable.
    mapping(bytes32 classConfigKey => TierConfig) private _classConfigs;

    /// @dev `classKey(cloneCodehash, selector)` => pending class certification.
    mapping(bytes32 classConfigKey => PendingClassCertification) private _classPending;

    /// @dev class fingerprint => allowlist flag. The class analogue of
    ///      `_adapterAllowed`. No separate codehash snapshot is needed: the
    ///      anchor's two-level check already proves the code is current, and
    ///      the class key IS a codehash.
    mapping(bytes32 cloneCodehash => bool) private _classAllowed;

    // ── PER-MEMBER DENIAL (the class fallback's off switch) ──
    //
    // Revocation in this contract is expressed as ERASURE: `_demote` deletes
    // `_configs[k]` and `_adapterAllowed[target]`, and the absence of a record
    // used to BE the tier-2 default. The class fallback gave absence a second,
    // permissive meaning, which silently converted every revocation against a
    // class member into a no-op — the conviction still deleted a record, but
    // the read that follows it lands on the class instead of the default.
    //
    // These two flags restore the invariant the erasure model depends on: a
    // record can be absent because it was never granted, or absent because it
    // was TAKEN AWAY, and only the first may consult the class. They are the
    // exact mechanism behind `tierOf`'s "address ALWAYS wins" claim — which
    // before them held for grants but not for revocations.

    /// @dev `key(target, selector)` => this ADDRESS may not read its tier off a
    ///      class. Per-selector, matching the granularity of the certification
    ///      `_demote` erases: convicting a clone for one selector leaves its
    ///      other selectors on the class, and leaves every sibling clone
    ///      untouched.
    ///
    ///      WRITE-ONCE BY DESIGN — nothing clears it. The recovery path is the
    ///      ordinary announced `proposeCertification` / `certify` ceremony,
    ///      which writes an address entry that wins ahead of both this flag and
    ///      the class. Adding a clear would be adding an INSTANT owner path to
    ///      restore a convicted address's tier, undercutting `certifyDelay` —
    ///      the one guarantee that every tier grant is announced in advance.
    mapping(bytes32 configKey => bool) private _classTierDenied;

    /// @dev target => this ADDRESS may not read its allowlist standing off a
    ///      class. Per-address, matching `_adapterAllowed`, so it inherits
    ///      `_demote`'s deliberate over-broadness: demoting one selector strips
    ///      the whole adapter's fund-movement standing.
    ///
    ///      Cleared by `setAdapterAllowed(target, true)` and set by
    ///      `setAdapterAllowed(target, false)`, so the owner's explicit
    ///      address-level decision beats the class in BOTH directions. Without
    ///      the `false` branch the owner could not disallow a single class
    ///      member at all — the class would re-allow it on the next read.
    ///
    ///      Unlike the tier flag this is safe to clear instantly: it mirrors
    ///      `setAdapterAllowed`'s own re-grant, which has always been an
    ///      instant owner call with no delay to undercut.
    mapping(address target => bool) private _classAllowDenied;

    event ClassMemberTierDenied(address indexed target, bytes4 indexed selector);
    event ClassMemberAllowDenied(address indexed target, bool denied);

    /// @notice Whether `target` has been barred from reading `selector`'s tier
    ///         off a class by a prior demotion.
    function isClassTierDenied(address target, bytes4 selector) external view returns (bool) {
        return _classTierDenied[key(target, selector)];
    }

    /// @notice Whether `target` has been barred from reading allowlist standing
    ///         off a class.
    function isClassAllowDenied(address target) external view returns (bool) {
        return _classAllowDenied[target];
    }

    function _isCertifiedFor(address target, bytes4 selector) private view returns (bool) {
        if (_configs[key(target, selector)].certifiedCodehash != bytes32(0)) return true;
        bytes32 cch = _classOf(target);
        if (cch == bytes32(0)) return false;
        return _classConfigs[classKey(cch, selector)].certifiedCodehash != bytes32(0);
    }

    error ClassNotCertified();
    error NoPendingClassCertification();
    /// @notice The certified template's live codehash no longer matches the
    ///         snapshot taken at certification.
    error TemplateCodehashChanged();

    event ClassCertificationProposed(
        address indexed template,
        bytes4 indexed selector,
        bytes32 indexed cloneCodehash,
        uint8 tier,
        uint16 extractableBoundBps,
        address submitter,
        uint256 bondAmount,
        bytes32 templateCodehash,
        uint64 readyAt
    );
    event ClassCertified(
        address indexed template,
        bytes4 indexed selector,
        bytes32 indexed cloneCodehash,
        uint8 tier,
        uint16 extractableBoundBps,
        bytes32 templateCodehash
    );
    event ClassCertificationCancelled(address indexed template, bytes4 indexed selector);
    event ClassDemoted(address indexed template, bytes4 indexed selector, bytes32 indexed cloneCodehash);
    event ClassAllowedSet(address indexed template, bytes32 indexed cloneCodehash, bool allowed);
    event ClassCalleeAllowedSet(address indexed template, bytes32 indexed cloneCodehash, bool callable);

    function _classOf(address target) private view returns (bytes32) {
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) return bytes32(0);
        ClassAnchor storage a = _classAnchors[ch];
        address t = a.template;
        if (t == address(0)) return bytes32(0);
        if (t.codehash != a.templateCodehash) return bytes32(0);
        return ch;
    }

    /// @notice Public view of the class `target` currently belongs to.
    ///         `bytes32(0)` when it belongs to none. Operator/watchtower read.
    function classOf(address target) external view returns (bytes32) {
        return _classOf(target);
    }

    /// @notice Full anchor for a class fingerprint; zeroed when no class exists.
    function classAnchorOf(bytes32 cloneCodehash) external view returns (ClassAnchor memory) {
        return _classAnchors[cloneCodehash];
    }

    /// @notice Propose certifying every ERC-1167 clone of `template` for
    ///         `selector` at `tier` with `extractableBoundBps`. `onlyOwner`.
    /// @dev    Mirrors `proposeCertification`: same delay, same bond pin, same
    ///         codehash-drift guard — the gap between owner review and mining
    ///         otherwise lets the template's deployer land different bytecode
    ///         first, anchoring a class to code the owner never reviewed.
    ///         `NotAContract` on a codeless template, else the level-2 check
    ///         could later be satisfied by counterfactual CREATE2 code.
    ///
    ///         What the owner must check and this cannot: that `template` binds
    ///         every init-supplied external address and is not itself a proxy.
    ///
    ///         every clone of `template` as a batch recipient, including clones
    ///         minted outside `StrategyFactory` and initialized permissionlessly.
    ///         `SyndicateVault` binds each member to the paying vault
    ///         (`vault() == vault`), which neutralizes a hostile clone ONLY IF
    ///         the template derives its fund destination and its counterparty
    ///         allowlist from `vault()` and exposes no payout / recipient /
    ///         router address settable from `initialize` or `updateParams`
    ///         data. `BaseStrategy._pushToVault` and the shipped templates
    ///         satisfy this; the reviewer certifying a new template MUST verify
    ///         it, because nothing on-chain does.
    function proposeClassCertification(
        address template,
        bytes4 selector,
        uint8 tier,
        uint16 extractableBoundBps,
        address submitter,
        bytes32 expectedTemplateCodehash
    ) external onlyOwner {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 tch = template.codehash;
        if (tch == bytes32(0) || tch == _EMPTY_CODEHASH) revert NotAContract();
        if (tch != expectedTemplateCodehash) revert CodehashChanged();
        uint256 bondAmount = submitterBondWood;
        if (bondAmount != 0 && submitter == address(0)) revert ZeroAddressSubmitter();

        bytes32 cch = cloneCodehashOf(template);
        bytes32 k = classKey(cch, selector);
        uint64 readyAt = uint64(block.timestamp + certifyDelay);
        _classPending[k] = PendingClassCertification({
            tier: tier,
            extractableBoundBps: extractableBoundBps,
            submitter: submitter,
            readyAt: readyAt,
            // casting to 'uint96' is safe because setSubmitterBondWood rejects
            // amounts above type(uint96).max (BondTooLarge)
            // forge-lint: disable-next-line(unsafe-typecast)
            bondAmount: uint96(bondAmount),
            bondToken: wood,
            template: template,
            templateCodehash: tch
        });
        emit ClassCertificationProposed(
            template, selector, cch, tier, extractableBoundBps, submitter, bondAmount, tch, readyAt
        );
    }

    /// @notice Execute a pending class certification once its delay elapsed.
    /// @dev    Same execution model as `certify`: permissionless without a bond,
    ///         submitter-only with one, every parameter fixed at proposal time.
    ///         Reuses `_bonds` keyed by the class key. Re-verifies the TEMPLATE's
    ///         codehash — a mid-window mutation voids the grant rather than
    ///         certifying different bytecode under an old announcement.
    function certifyClass(address template, bytes4 selector) external {
        bytes32 cch = cloneCodehashOf(template);
        bytes32 k = classKey(cch, selector);
        PendingClassCertification memory p = _classPending[k];
        if (p.readyAt == 0) revert NoPendingClassCertification();
        if (block.timestamp < p.readyAt) revert CertifyDelayNotElapsed();
        if (block.timestamp > p.readyAt + MAX_CERTIFY_WINDOW) revert CertificationExpired();
        if (template.codehash != p.templateCodehash) revert TemplateCodehashChanged();
        if (p.bondAmount != 0 && msg.sender != p.submitter) revert NotSubmitter();

        SubmitterBond storage existing = _bonds[k];
        if (existing.amount != 0) {
            if (existing.releasableAt != 0) revert BondPendingRelease();
            revert BondActive();
        }
        delete _classPending[k];
        if (p.bondAmount != 0) {
            _bonds[k] =
                SubmitterBond({submitter: p.submitter, amount: p.bondAmount, releasableAt: 0, token: p.bondToken});
            totalBondedWood += p.bondAmount;
            p.bondToken.safeTransferFrom(p.submitter, address(this), p.bondAmount);
            emit SubmitterBondLocked(template, selector, p.submitter, p.bondAmount);
        }
        _classAnchors[cch] = ClassAnchor({template: p.template, templateCodehash: p.templateCodehash});
        _classConfigs[k] =
            TierConfig({tier: p.tier, extractableBoundBps: p.extractableBoundBps, certifiedCodehash: cch});
        emit ClassCertified(template, selector, cch, p.tier, p.extractableBoundBps, p.templateCodehash);
    }

    /// @notice Withdraw a pending class certification before it executes.
    function cancelClassCertification(address template, bytes4 selector) external onlyOwner {
        bytes32 k = classKey(cloneCodehashOf(template), selector);
        if (_classPending[k].readyAt == 0) revert NoPendingClassCertification();
        delete _classPending[k];
        emit ClassCertificationCancelled(template, selector);
    }

    /// @notice Full pending class-certification record; zeroed struct
    ///         (`readyAt == 0`) when nothing is pending.
    function pendingClassCertificationOf(address template, bytes4 selector)
        external
        view
        returns (PendingClassCertification memory)
    {
        return _classPending[classKey(cloneCodehashOf(template), selector)];
    }

    /// @notice Effective tier for a class's `selector`, ignoring membership.
    ///         `(2, 10_000)` when the class carries no certification.
    function classTierOf(address template, bytes4 selector) external view returns (uint8, uint16) {
        TierConfig storage c = _classConfigs[classKey(cloneCodehashOf(template), selector)];
        if (c.certifiedCodehash == bytes32(0)) return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
        return (c.tier, c.extractableBoundBps);
    }

    /// @notice Allow or disallow every clone of `template` as a batch callee
    ///         and as spender/recipient of vault funds. `onlyOwner`.
    /// @dev    Class analogue of `setAdapterAllowed`, and the half that removes
    ///         the operational blocker: without it a clone cannot be named in a
    ///         governor batch at all (`_guardBatchCalls` PART 2a).
    ///
    ///         Requires a live anchor, so a class must be certified first — the
    ///         anchor carries the two-level check. `certifyClass` never sets
    ///         this: restoring allowlist standing after a demotion is always an
    ///         explicit owner call, never a side effect of re-certification. The
    ///         address path's rule, and the reason multiplies here — the blast
    ///         radius is every clone of the template at once.
    function setClassAllowed(address template, bool allowed) external onlyOwner {
        bytes32 cch = cloneCodehashOf(template);
        if (allowed && _classAnchors[cch].template == address(0)) revert ClassNotCertified();
        _classAllowed[cch] = allowed;
        // The callee axis opens with a grant and never closes with a delisting,
        // mirroring `_demoteClass` and the address path: a class that may no
        // longer be PAID stays reclaimable. `setClassCallable` closes it.
        if (allowed) _classCalleeAllowed[cch] = true;
        emit ClassAllowedSet(template, cch, allowed);
    }

    /// @notice Open or close the callee axis for every clone of `template` — a
    ///         POST-SETTLEMENT action, taken once the vault holds nothing in any
    ///         of them. `onlyOwner`.
    function setClassCallable(address template, bool callable) external onlyOwner {
        bytes32 cch = cloneCodehashOf(template);
        if (callable && _classAnchors[cch].template == address(0)) revert ClassNotCertified();
        _classCalleeAllowed[cch] = callable;
        emit ClassCalleeAllowedSet(template, cch, callable);
    }

    /// @notice Whether every clone of `template` is currently allowlisted.
    function isClassAllowed(address template) external view returns (bool) {
        return _classAllowed[cloneCodehashOf(template)];
    }

    /// @notice Demote a class for `selector`. `onlyOwner`. Instant.
    function demoteClass(address template, bytes4 selector) external onlyOwner {
        if (_classConfigs[classKey(cloneCodehashOf(template), selector)].certifiedCodehash == bytes32(0)) {
            revert ClassNotCertified();
        }
        _demoteClass(template, selector);
    }

    /// @notice Demote a class for `selector` on a challenge conviction.
    ///         Restricted to `authorizedDemoter`, mirroring `demoteByChallenge`.
    ///         Cancels a pending class certification ahead of the
    ///         `ClassNotCertified` guard, on the same terms.
    function demoteClassByChallenge(address template, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        bytes32 k = classKey(cloneCodehashOf(template), selector);
        bool cancelled = _classPending[k].readyAt != 0;
        if (cancelled) {
            delete _classPending[k];
            emit ClassCertificationCancelled(template, selector);
        }
        if (_classConfigs[k].certifiedCodehash == bytes32(0)) {
            if (cancelled) return;
            revert ClassNotCertified();
        }
        _demoteClass(template, selector);
    }

    /// @notice Permissionless demotion once the certified template's live
    ///         codehash no longer matches the anchor snapshot. Persists what
    ///         `tierOf` and `isAdapterAllowed` already report lazily.
    /// @dev    Class analogue of `poke`, targeting level 2 specifically: level 1
    ///         cannot change for an already-deployed address, level 2 can.
    function pokeClass(address template, bytes4 selector) external {
        bytes32 cch = cloneCodehashOf(template);
        if (_classConfigs[classKey(cch, selector)].certifiedCodehash == bytes32(0)) revert ClassNotCertified();
        if (template.codehash == _classAnchors[cch].templateCodehash) revert CodehashMatches();
        _demoteClass(template, selector);
    }

    function _demoteClass(address template, bytes4 selector) private {
        bytes32 cch = cloneCodehashOf(template);
        bytes32 k = classKey(cch, selector);
        delete _classConfigs[k];
        if (_classPending[k].readyAt != 0) {
            delete _classPending[k];
            emit ClassCertificationCancelled(template, selector);
        }
        SubmitterBond storage b = _bonds[k];
        if (b.amount != 0 && b.releasableAt == 0) {
            uint64 releasableAt = uint64(block.timestamp + bondReleaseDelay);
            b.releasableAt = releasableAt;
            emit SubmitterBondReleaseStarted(template, selector, b.submitter, releasableAt);
        }
        if (_classAllowed[cch]) {
            delete _classAllowed[cch];
            emit ClassAllowedSet(template, cch, false);
        }
        emit ClassDemoted(template, selector, cch);
    }

    /// @notice Release a demoted class bond to its submitter. Permissionless,
    ///         same model as `claimSubmitterBond` on the address path.
    function claimClassSubmitterBond(address template, bytes4 selector) external {
        bytes32 k = classKey(cloneCodehashOf(template), selector);
        SubmitterBond memory b = _bonds[k];
        if (b.amount == 0) revert NotCertified();
        if (b.releasableAt == 0 || block.timestamp < b.releasableAt) revert BondNotReleasable();
        delete _bonds[k];
        totalBondedWood -= b.amount;
        b.token.safeTransfer(b.submitter, b.amount);
        emit SubmitterBondClaimed(template, selector, b.submitter, b.amount);
    }

    /// @notice Bond record for a (class, selector); zeroed when none.
    function classBondOf(address template, bytes4 selector) external view returns (SubmitterBond memory) {
        return _bonds[classKey(cloneCodehashOf(template), selector)];
    }

    // ── TOKEN ↔ PRICE-SOURCE ATTESTATION ──
    //
    // A template pricing token X with a feed describing something else derives
    // its slippage floor from the wrong reference, so a trade can lose value
    // while sitting inside its configured tolerance. Nothing on-chain answers
    // "does this feed describe this token?" (`description()` is a human string,
    // and the Feed Registry is absent on Robinhood), so the pairing is ATTESTED
    // rather than derived. Without it the token list is an unbound init
    // parameter, which disqualifies a template from class certification.

    /// @dev token => price source => attested. `bytes32` so one mapping serves
    ///      both modes: a push aggregator address widened, or a Data Streams
    ///      feed id verbatim. Callers MUST strip packed metadata (e.g. max-age)
    ///      before lookup, so one attestation covers every staleness variant.
    mapping(address token => mapping(bytes32 priceSource => bool)) private _tokenPriceSource;

    event PriceSourceForTokenSet(address indexed token, bytes32 indexed priceSource, bool allowed);

    /// @notice Attest that `priceSource` prices `token`. `onlyOwner`.
    /// @dev    A separate axis from `setAdapterAllowed`: that says "this source
    ///         may be used at all", this says "…for THIS token". Adversary: a
    ///         proposer pairing a valuable token with a cheap asset's feed, so
    ///         the derived minimum output sits far below fair value and the
    ///         difference is extracted while every slippage check passes.
    function setPriceSourceForToken(address token, bytes32 priceSource, bool allowed) external onlyOwner {
        _tokenPriceSource[token][priceSource] = allowed;
        emit PriceSourceForTokenSet(token, priceSource, allowed);
    }

    /// @notice Whether `priceSource` is attested to price `token`.
    /// @dev    Consumed via length-checked raw staticcall, so a registry
    ///         predating this function is distinguishable from one answering
    ///         false — see `PortfolioStrategy._isPriceSourceForToken`.
    function isPriceSourceForToken(address token, bytes32 priceSource) external view returns (bool) {
        return _tokenPriceSource[token][priceSource];
    }
}
