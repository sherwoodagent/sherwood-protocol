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
    ///
    ///      `token` pins the ERC20 this specific bond was actually PULLED in
    ///      (audit finding #3, refund half): `certify` already pins
    ///      `PendingCertification.bondToken` so the PULL can't be silently
    ///      repointed by an intervening `setWood` — but until this field
    ///      existed, the REFUND in `claimSubmitterBond` read the LIVE `wood`
    ///      state variable instead, so that pin never reached payout. Two
    ///      certifications under two different tokens sharing this registry
    ///      would let the first claimant drain the second submitter's
    ///      collateral out of a shared balance; a single certification
    ///      followed by one `setWood` would strand the bond permanently
    ///      (claim reverts on the new token's zero balance for this key,
    ///      `totalBondedWood` never decrements, and `setWood`'s
    ///      `BondsOutstanding` guard can then never be satisfied again — no
    ///      sweep function exists and the contract is non-upgradeable).
    ///      Recording the token on the bond itself makes every later state of
    ///      `wood` irrelevant to an already-locked bond's payout, exactly
    ///      like `bondToken` already does for the pull.
    struct SubmitterBond {
        address submitter;
        uint96 amount;
        uint64 releasableAt; // 0 while certified; set on demotion
        IERC20 token; // pinned at certify time (audit finding #3)
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
    ///         governor batch (see `SyndicateVault._guardBatchCalls` PART 2b).
    ///         A separate axis from (target, selector) tier certification: tiers
    ///         PRICE extractable value for coverage; this list bounds WHERE
    ///         vault funds may be approved or sent at all.
    ///
    ///         SECOND CONSUMER (issue #166): also the predicate for whether a
    ///         target "may be reached by a governor batch at all, and hence may
    ///         receive vault funds" (`_guardBatchCalls` PART 2a, the callee
    ///         gate) — same mapping, same owner ceremony, not a second
    ///         allowlist. `asset()` is the sole callee exempt from this check
    ///         (metered separately via the vault's own balance diff); every
    ///         other batch target, whether or not it carries a value-moving
    ///         selector, must clear this predicate to be callable at all.
    ///         GOVERNANCE DISCIPLINE: exotic-asset contracts (ERC-721/1155/777
    ///         and other non-fungible/position tokens) MUST NOT be allowlisted
    ///         here as batch callees — their non-ERC20 selectors are not
    ///         examined by the retained selector switch, so allowlisting one as
    ///         a callee would open an unexamined surface. Batches reach such
    ///         positions through allowlisted adapters instead.
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
    /// @dev LAUNCH GATE (issue #40): a non-zero value is inert as a warranty
    ///      — and imposes a real, currently-unrecoverable cost on adapter
    ///      submitters — until ALL THREE hold:
    ///        1. a guard-bypass slash function exists and can reach `_bonds`
    ///           (the seam is here — `MIN_BOND_RELEASE_DELAY` and the
    ///           `slash`-referencing comments throughout this file hold the
    ///           bond long enough for it — but the function itself does not
    ///           exist yet);
    ///        2. a seated court can enforce a DISPUTED slash (Plan E) — per
    ///           issue #25, a disputed challenge currently times out in the
    ///           accused's favour, so a submitter who disputes keeps the bond
    ///           regardless of (1);
    ///        3. third-party adapter submission actually exists, so the bond
    ///           filters submitters rather than merely deterring the only
    ///           participant with no revenue from the adapter it warrants.
    ///      `script/Deploy.s.sol` never calls `setSubmitterBondWood`, so this
    ///      stays `0` (unbonded, governance-judged certification) at launch —
    ///      do not enable it from the setter without meeting the gate above.
    uint256 public submitterBondWood;
    uint256 public bondReleaseDelay = 14 days;
    mapping(bytes32 configKey => SubmitterBond) internal _bonds;

    /// @notice Sum of all bonds held (active + pending release), across every
    ///         token a bond has ever been pulled in.
    /// @dev    NOT `wood.balanceOf(address(this)) == totalBondedWood` (spec
    ///         §4's original phrasing, written before `SubmitterBond.token`
    ///         existed): each bond now carries its OWN pinned token (audit
    ///         finding #3), so once bonds under two different tokens coexist
    ///         this sum spans balances in both and no longer equals any
    ///         single token's `balanceOf`. What DOES still hold, per token
    ///         `t`: `t.balanceOf(address(this)) >= sum(amount for bonds where
    ///         token == t)`. The scalar here is used only as the
    ///         `BondsOutstanding` existence gate in `setWood` — zero iff no
    ///         bond, in any token, is currently held.
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
    /// @dev Lookup order is address entry, then code class, then the tier-2
    ///      default. Address ALWAYS wins (design.md Decision 3): existing
    ///      behavior is preserved by construction, the owner keeps a
    ///      per-address override to re-price or demote one misbehaving clone
    ///      without touching the class, and the hot path pays for the class
    ///      lookup only on an address miss.
    function tierOf(address target, bytes4 selector) public view returns (uint8 tier, uint16 boundBps) {
        TierConfig storage c = _configs[key(target, selector)];
        if (c.certifiedCodehash != bytes32(0) && target.codehash == c.certifiedCodehash) {
            return (c.tier, c.extractableBoundBps);
        }
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
    ///         bond is held (`BondsOutstanding`). This is defense-in-depth,
    ///         not strictly load-bearing for fund safety: every bond now
    ///         pins its OWN token at certify time (`SubmitterBond.token`,
    ///         audit finding #3) and `claimSubmitterBond` pays out against
    ///         that pinned field, never the live `wood` variable — so an
    ///         already-locked bond can no longer be stranded, misdirected
    ///         onto another bond's collateral, or pointed at a codeless
    ///         `address(0)` by a swap here. The guard is kept anyway because
    ///         letting bonds accumulate under multiple live tokens
    ///         simultaneously is unmaintainable operationally (per-token
    ///         accounting the owner would have to track off-chain) even
    ///         though it is no longer unsafe on-chain. Drain all bonds
    ///         (demote → timelock → claim) before swapping. Clearing the
    ///         token to address(0) while the bond amount is still armed is
    ///         also rejected — zero the amount first.
    ///
    ///         `totalBondedWood != 0` is the ONLY guard here and it is
    ///         deliberately silent about pending (unexecuted) certifications:
    ///         a certification proposed while `wood` was TokenA no longer
    ///         cares what this setter does before it executes, because
    ///         `PendingCertification.bondToken` pins TokenA at proposal time
    ///         (audit finding #1) and `certify` pulls against that pinned
    ///         token — and now also WRITES it onto the new bond's `token`
    ///         field (finding #3) — never against this live variable at
    ///         either step. Swapping `wood` here mid-window is therefore
    ///         inert to any already-pending certification's bond economics,
    ///         both at pull time and at every later claim, by construction.
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
    ///         transfer / transferFrom-out) inside governor batches, AND
    ///         (issue #166) as a batch callee at all — a target that fails
    ///         this check cannot be named in a governor batch regardless of
    ///         selector or calldata (see `isAdapterAllowed` and
    ///         `SyndicateVault._guardBatchCalls` PART 2a). Exotic-asset
    ///         contracts (ERC-721/1155/777, LP-position NFTs) MUST NOT be
    ///         allowlisted here as batch callees — their non-ERC20 selectors
    ///         are not examined by the retained PART 2b selector switch, so
    ///         batches should reach such positions through allowlisted
    ///         adapters instead.
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
    ///         funds through a governor batch, AND (issue #166) whether
    ///         `adapter` may be named as a batch callee at all —
    ///         `SyndicateVault._guardBatchCalls` PART 2a consults this same
    ///         read to decide callability, not just fund-destination consent;
    ///         the two roles are deliberately the collapsed same predicate
    ///         (design.md Decision 1 of `target-based-batch-gating`).
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
    ///         CLASS FALLBACK: when no address grant resolves, the adapter is
    ///         allowed if it is a live member of an allowlisted code class —
    ///         same ordering as `tierOf` (address first, class second), same
    ///         two-level membership check. This is what removes the
    ///         per-proposal owner ceremony for clones; without it a fresh clone
    ///         cannot be named in a governor batch at all.
    function isAdapterAllowed(address adapter) external view returns (bool) {
        if (_adapterAllowed[adapter] && _effectiveCodehash(adapter) == _adapterAllowedCodehash[adapter]) {
            return true;
        }
        bytes32 cch = _classOf(adapter);
        return cch != bytes32(0) && _classAllowed[cch];
    }

    // ─────────────────────────────────────────────────────────────────────
    // CODEHASH-CLASS CERTIFICATION (change: codehash-class-certification)
    //
    // Every strategy proposal deploys a fresh ERC-1167 clone at a fresh
    // address, so address-keyed consent forces one owner ceremony per
    // proposal, forever. Clones of one template are byte-identical, so a
    // codehash identifies the template — and certifying that codehash
    // certifies every clone that will ever exist, with no per-clone action.
    //
    // A class certification asserts a STRICTLY STRONGER claim than an
    // address certification: that the bound holds under EVERY
    // initialization, not merely for one deployment's stored config. Which
    // templates may carry that claim is a governance-discipline rule stated
    // in the tier-policy spec ("Only conformant templates may be
    // class-certified"), not a check this contract can make.
    // ─────────────────────────────────────────────────────────────────────

    /// @dev Per-class anchor, shared by BOTH axes (tier and allowlist). Keyed
    ///      by the clone codehash, which is the class identity.
    ///
    ///      `templateCodehash` is the load-bearing field. A clone's codehash
    ///      embeds the template's ADDRESS, not the template's CODE, so
    ///      mutating the template in place changes every clone's behavior
    ///      while leaving every clone's codehash identical. Without this
    ///      snapshot the class would keep vouching for hostile code across
    ///      every clone at once — strictly worse than the address path it
    ///      extends. Adversary: a template whose bytecode is replaced at the
    ///      same address (metamorphic CREATE2 + SELFDESTRUCT redeploy) after
    ///      certification.
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
        IERC20 bondToken;
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

    /// @notice The class fingerprint `target` belongs to, or `bytes32(0)` when
    ///         it belongs to no live class.
    /// @dev    THE two-level membership check, shared by `tierOf` and
    ///         `isAdapterAllowed` so the two axes can never drift apart:
    ///
    ///           level 1 — an anchor exists at `target.codehash`, i.e. the
    ///                     target's runtime code is exactly the ERC-1167 stub
    ///                     pointing at the certified template. This is what
    ///                     proves "clone of T" from chain state alone, with no
    ///                     factory record and no proposer-supplied claim.
    ///           level 2 — the template's live codehash still equals the
    ///                     snapshot. See `ClassAnchor.templateCodehash` for why
    ///                     dropping this would make the class strictly weaker
    ///                     than the address path.
    ///
    ///         Read-side and state-free, mirroring `tierOf`/`isAdapterAllowed`:
    ///         no write in the hot path, nothing to grief, no dependence on any
    ///         poke ever running. A mutated template needs no demotion — its
    ///         clones simply stop being members, because membership IS code
    ///         identity.
    ///
    ///         Lookup is O(1): the class is found BY the target's own codehash,
    ///         not by scanning certified templates.
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
    /// @dev    Deliberately mirrors `proposeCertification`: same delay, same
    ///         bond pin, same `expectedTemplateCodehash` drift guard, and the
    ///         same reason for that guard — the gap between owner review and
    ///         mining lets the TEMPLATE's own deployer land different bytecode
    ///         before this transaction does, silently anchoring a class to code
    ///         the owner never reviewed.
    ///
    ///         `NotAContract` on a codeless template: there is no class to
    ///         anchor, and anchoring one would create a class whose level-2
    ///         check could later be satisfied by whatever code appears at that
    ///         address (counterfactual CREATE2).
    ///
    ///         What this cannot check, and the owner must: that `template`
    ///         binds every init-supplied external address, and that it is not
    ///         itself a proxy. Both are governance discipline — a proxy's
    ///         runtime bytecode is static across implementation swaps, so
    ///         neither membership level can observe the change.
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
    /// @dev    Same execution model as `certify`: permissionless with no bond
    ///         at stake, submitter-only when a bond is pinned, and every
    ///         parameter fixed at proposal time so a caller chooses only WHEN,
    ///         never WHAT. Reuses `_bonds` keyed by the class key — one bond per
    ///         (class, selector), and any existing bond blocks re-certification
    ///         exactly as on the address path.
    ///
    ///         Re-verifies the TEMPLATE's codehash, not a clone's: the class is
    ///         anchored to the template's code, and a mid-window mutation must
    ///         void the grant rather than certify different bytecode under an
    ///         old announcement.
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
    /// @dev    The class analogue of `setAdapterAllowed`, and the half that
    ///         removes the operational blocker: without it a clone cannot be
    ///         named in a governor batch at all (`SyndicateVault`
    ///         `_guardBatchCalls` PART 2a), which is a hard failure rather than
    ///         a cost.
    ///
    ///         Grantable independently of a tier certification — the two axes
    ///         stay separate here exactly as they do on the address path — but
    ///         the anchor must already exist, so a class must be certified
    ///         before it can be allowlisted. That ordering is deliberate: the
    ///         anchor is what carries the two-level check, and an allowlist
    ///         entry without it would be a codehash match with no template
    ///         binding at all.
    ///
    ///         `certifyClass` never sets this. Restoring allowlist standing
    ///         after a demotion is always this explicit owner call, never a
    ///         side effect of re-certification — the address path's rule,
    ///         and the reason for it multiplies here: a submitter who gets a
    ///         class re-certified would otherwise silently re-open the funds
    ///         path for every clone of that template at once.
    function setClassAllowed(address template, bool allowed) external onlyOwner {
        bytes32 cch = cloneCodehashOf(template);
        if (allowed && _classAnchors[cch].template == address(0)) revert ClassNotCertified();
        _classAllowed[cch] = allowed;
        emit ClassAllowedSet(template, cch, allowed);
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
    function demoteClassByChallenge(address template, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        if (_classConfigs[classKey(cloneCodehashOf(template), selector)].certifiedCodehash == bytes32(0)) {
            revert ClassNotCertified();
        }
        _demoteClass(template, selector);
    }

    /// @notice Permissionless demotion once the certified template's live
    ///         codehash no longer matches the anchor snapshot. Persists what
    ///         `tierOf` and `isAdapterAllowed` already report lazily.
    /// @dev    The class analogue of `poke`, and it targets level 2 of the
    ///         membership check specifically. Level 1 has nothing to persist —
    ///         an address either is or is not a clone of the template, and that
    ///         cannot change for an already-deployed address. Level 2 can and
    ///         does change, and it is the one whose failure would otherwise let
    ///         a mutated template keep a certification record on the books.
    function pokeClass(address template, bytes4 selector) external {
        bytes32 cch = cloneCodehashOf(template);
        if (_classConfigs[classKey(cch, selector)].certifiedCodehash == bytes32(0)) revert ClassNotCertified();
        if (template.codehash == _classAnchors[cch].templateCodehash) revert CodehashMatches();
        _demoteClass(template, selector);
    }

    /// @dev Convergence point for all three class demotion paths, mirroring
    ///      `_demote` field for field.
    ///
    ///      Clears the CLASS allowlist entry, and is over-broad in exactly the
    ///      same deliberate way: class configs are keyed `(class, selector)`
    ///      while the class allowlist is keyed by bare class, so demoting one
    ///      selector de-allowlists every clone of the template even if other
    ///      selectors stay certified. Recovery is one owner
    ///      `setClassAllowed(template, true)`. Do NOT "fix" this to a
    ///      per-selector class allowlist — the conservative direction of error
    ///      is the point, and the blast radius here is every clone at once,
    ///      which argues for more caution than the address path, not less.
    ///
    ///      Also cancels a same-key pending class certification, for the reason
    ///      `_demote` does: a renewal proposed while the class was live would
    ///      otherwise survive a for-cause demotion and execute at `readyAt`,
    ///      re-certifying a just-convicted template — across every clone.
    ///
    ///      The ANCHOR is deliberately left in place. It grants nothing on its
    ///      own (`tierOf` needs a class config, `isAdapterAllowed` needs the
    ///      class allowlist flag), other selectors on the same class still need
    ///      it, and `setClassAllowed` requiring a live anchor is what keeps
    ///      re-allowlisting an explicit owner decision rather than a side
    ///      effect. Same posture as `_adapterAllowedCodehash`, which `_demote`
    ///      also leaves inert.
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

    // ─────────────────────────────────────────────────────────────────────
    // TOKEN ↔ PRICE-SOURCE ATTESTATION
    //
    // A template that prices token X with a feed describing something else
    // computes its own slippage floor off the wrong reference — the safety
    // rail is measured against the wrong ruler, so a trade can lose value
    // while appearing to sit inside its configured tolerance. Nothing in
    // Chainlink's AggregatorV3 surface answers "does this feed describe this
    // token?" on-chain (`description()` is a human string, and the Feed
    // Registry is not deployed on Robinhood Chain), so the pairing has to be
    // ATTESTED by governance rather than derived.
    //
    // This is what lets a basket template make the class-certification claim
    // — that its bound holds under EVERY initialization — instead of relying
    // on a human reviewing each clone's configuration before it can move
    // money. Without it the token list is an unbound init parameter, and an
    // unbound external address is exactly what disqualifies a template from
    // being class-certified (tier-policy: "Only conformant templates may be
    // class-certified").
    // ─────────────────────────────────────────────────────────────────────

    /// @dev token => price source => attested. The source is carried as
    ///      `bytes32` so one mapping serves both price modes: a push-feed
    ///      aggregator address widened to bytes32, or a Data Streams feed id
    ///      verbatim. Callers MUST strip any packed metadata (e.g. a max-age
    ///      field) before looking up, so the same aggregator attests
    ///      identically regardless of the staleness bound a proposer chose.
    mapping(address token => mapping(bytes32 priceSource => bool)) private _tokenPriceSource;

    event PriceSourceForTokenSet(address indexed token, bytes32 indexed priceSource, bool allowed);

    /// @notice Attest that `priceSource` prices `token`. `onlyOwner`.
    /// @dev    Deliberately a separate axis from `setAdapterAllowed`: that one
    ///         says "this price source may be used at all", this one says
    ///         "…for THIS token". A template needs both — the source allowlist
    ///         stops an unknown oracle, and this stops a known oracle being
    ///         pointed at the wrong asset. Adversary: a proposer pairing a
    ///         valuable token with a cheap asset's feed so the derived minimum
    ///         output is far below fair value, extracting the difference on
    ///         every rebalance while every slippage check passes.
    function setPriceSourceForToken(address token, bytes32 priceSource, bool allowed) external onlyOwner {
        _tokenPriceSource[token][priceSource] = allowed;
        emit PriceSourceForTokenSet(token, priceSource, allowed);
    }

    /// @notice Whether `priceSource` is attested to price `token`.
    /// @dev    Consumed by strategy templates through a raw `staticcall` with
    ///         an explicit returndata-length check, so a registry that
    ///         predates this function is distinguishable from one that answers
    ///         `false` — see `PortfolioStrategy._isPriceSourceForToken`.
    function isPriceSourceForToken(address token, bytes32 priceSource) external view returns (bool) {
        return _tokenPriceSource[token][priceSource];
    }
}
