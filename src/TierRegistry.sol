// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TierRegistry
 * @notice Adapter-selector tier certification for the guardian economic-security
 *         model (spec 2026-07-22 §3.2). Tier is a property of (target, selector),
 *         set at listing by governance, consumed at propose/execute time.
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
 *      SCOPE OF THE CODEHASH CHECK (finding 4): EXTCODEHASH identity catches
 *      ONLY same-address bytecode mutation — i.e. metamorphic redeploys
 *      (CREATE2 + SELFDESTRUCT). It does NOT catch proxy implementation swaps:
 *      for EIP-1967 / UUPS / transparent / beacon proxies the PROXY's runtime
 *      bytecode is static across upgrades, so the certified hash keeps
 *      matching while the behavior behind it changes arbitrarily. Governance
 *      MUST NOT certify proxied adapters at tier 0/1 — certification is a
 *      governance judgment (per spec), and an upgradeable target can never be
 *      "closed-loop" or "oracle-bounded" by inspection of frozen code. Leave
 *      proxies at the tier-2 default.
 */
contract TierRegistry is Ownable2Step {
    using SafeERC20 for IERC20;

    struct TierConfig {
        uint8 tier; // 0 or 1 when certified; entry absent => tier 2
        uint16 extractableBoundBps; // certified extractable bound, bps of notional
        bytes32 certifiedCodehash; // EXTCODEHASH of target at certification
    }

    /// @dev Submitter bond per certification (spec §3.6: "tier downgrade = bonded
    ///      claim"). Held while certified; demotion starts `bondReleaseDelay`,
    ///      then the submitter claims. The delay is the seam Plan C's
    ///      guard-bypass slash attaches to (slash-first layering: submitter bond
    ///      before protocol backstop).
    struct SubmitterBond {
        address submitter;
        uint96 amount;
        uint64 releasableAt; // 0 while certified; set on demotion
    }

    uint8 public constant TIER_ARBITRARY = 2;
    uint16 public constant FULL_NOTIONAL_BPS = 10_000;

    /// @dev Floor preserves Plan C's slash window: a demoted bond must stay
    ///      claimable-not-yet-claimed long enough for the guard-bypass slash
    ///      machinery to act. Ceiling bounds governance error.
    uint256 public constant MIN_BOND_RELEASE_DELAY = 1 days;
    uint256 public constant MAX_BOND_RELEASE_DELAY = 365 days;

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

    /// @notice Set the WOOD token used for submitter bonds.
    /// @dev    Token-swap constraint: the bond token cannot change while ANY
    ///         bond is held (`BondsOutstanding`) — outstanding bonds are
    ///         denominated in the OLD token and a swap would strand them (the
    ///         claim path pays out in the new token, whose balance is zero).
    ///         Drain all bonds (demote → timelock → claim) before swapping.
    ///         Clearing the token to address(0) while the bond amount is still
    ///         armed is also rejected — zero the amount first.
    function setWood(address wood_) external onlyOwner {
        if (totalBondedWood != 0) revert BondsOutstanding();
        if (wood_ == address(0) && submitterBondWood != 0) revert BondConfigUnset();
        wood = IERC20(wood_);
        emit SubmitterBondConfigSet(wood_, submitterBondWood, bondReleaseDelay);
    }

    /// @notice Set the submitter bond amount pulled on `certify`. Zero disables
    ///         the bond requirement (Plan A no-bond passthrough).
    /// @dev    Bounded to uint96 so the `SubmitterBond.amount` narrowing cast
    ///         in `certify` is provably lossless.
    function setSubmitterBondWood(uint256 amount) external onlyOwner {
        if (amount != 0 && address(wood) == address(0)) revert BondConfigUnset();
        if (amount > type(uint96).max) revert BondTooLarge();
        submitterBondWood = amount;
        emit SubmitterBondConfigSet(address(wood), amount, bondReleaseDelay);
    }

    /// @notice Set the timelock delay between demotion and submitter bond claim.
    /// @dev    Bounded to [MIN_BOND_RELEASE_DELAY, MAX_BOND_RELEASE_DELAY]. The
    ///         floor preserves Plan C's slash window — a zero/near-zero delay
    ///         would let a mis-certifying submitter exit before the guard-bypass
    ///         slash can attach.
    function setBondReleaseDelay(uint256 delay) external onlyOwner {
        if (delay < MIN_BOND_RELEASE_DELAY || delay > MAX_BOND_RELEASE_DELAY) revert InvalidDelay();
        bondReleaseDelay = delay;
        emit SubmitterBondConfigSet(address(wood), submitterBondWood, delay);
    }

    /// @notice Certify (target, selector) at tier 0/1 with its extractable bound.
    ///         Snapshots EXTCODEHASH so a metamorphic self-redeploy (CREATE2 +
    ///         SELFDESTRUCT: new bytecode at the same address) trips the lazy
    ///         demotion on its first post-mutation read.
    /// @dev    The snapshot does NOT protect against proxy implementation
    ///         swaps — an EIP-1967/UUPS/transparent/beacon proxy's runtime
    ///         bytecode (and hence its EXTCODEHASH) never changes when the
    ///         implementation is upgraded. There is no reliable on-chain proxy
    ///         detector (a contract cannot read another contract's storage
    ///         slots), so this is a GOVERNANCE obligation: do not certify
    ///         proxied targets at tier 0/1 (see contract-level note).
    ///
    ///         A bonded certification cannot be replaced in place: while ANY
    ///         bond exists for the key — active (`BondActive`) or pending
    ///         release (`BondPendingRelease`) — `certify` reverts. Replacing
    ///         it goes demote → timelock → claim → fresh certify, so the old
    ///         bond must traverse its release timelock (slash-first layering)
    ///         before the key can carry a new bond.
    ///
    ///         OPERATIONAL COST, stated rather than discovered (review m2):
    ///         this applies to BENIGN edits too. Correcting an
    ///         `extractableBoundBps` typo, or re-certifying after a legitimate
    ///         adapter upgrade, costs the full demote → 14d → claim → certify
    ///         cycle — and the key sits at tier 2 (full notional, priced not
    ///         bounded) for the whole window. Deliberate: the alternative is a
    ///         path that swaps a certification out from under a live bond. It
    ///         belongs in the runbook so operators plan around it rather than
    ///         discovering it mid-incident.
    function certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, address submitter)
        external
        onlyOwner
    {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) revert NotAContract();
        bytes32 k = key(target, selector);
        // ANY existing bond blocks re-certification — one bond per key, and a
        // live bond must never be overwritten (that would strand the old
        // submitter's WOOD in the registry with no claim path).
        SubmitterBond storage existing = _bonds[k];
        if (existing.amount != 0) {
            if (existing.releasableAt != 0) revert BondPendingRelease();
            revert BondActive();
        }
        // Pull the submitter bond when configured (spec §3.6). Zero-config
        // (bond amount 0) preserves the Plan A no-bond path for the governance-
        // assigned initial adapter set.
        uint256 bondAmount = submitterBondWood;
        if (bondAmount != 0) {
            if (submitter == address(0)) revert ZeroAddressSubmitter();
            // casting to 'uint96' is safe because setSubmitterBondWood rejects
            // amounts above type(uint96).max (BondTooLarge)
            // forge-lint: disable-next-line(unsafe-typecast)
            _bonds[k] = SubmitterBond({submitter: submitter, amount: uint96(bondAmount), releasableAt: 0});
            totalBondedWood += bondAmount;
            wood.safeTransferFrom(submitter, address(this), bondAmount);
            emit SubmitterBondLocked(target, selector, submitter, bondAmount);
        }
        _configs[k] = TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: ch});
        emit TierCertified(target, selector, tier, extractableBoundBps, ch);
    }

    /// @notice The one address permitted to demote on a passed challenge — the
    ///         ChallengeGame (spec §3.4: "adapters demote only on a passed
    ///         challenge"). A ROLE rather than registry ownership, so the game
    ///         can revoke a certification but never grant one.
    address public authorizedDemoter;

    error NotAuthorizedDemoter();

    event AuthorizedDemoterSet(address indexed demoter);

    /// @dev Zero is legal and deliberate — it is the UNWIRE switch, revoking
    ///      the challenge game's demotion role outright while a replacement is
    ///      wired. The unwired state fails CLOSED (nothing can demote), which
    ///      is why this setter carries no zero-address check where the others
    ///      in this diff do (PR #25 review, minor).
    ///
    ///      WHAT "FAILS CLOSED" DOES AND DOES NOT COVER (review 🟠F11). It holds
    ///      for FUTURE demotions and did NOT hold for live challenges:
    ///      `ChallengeGame._settle` called `demoteByChallenge` unguarded, so
    ///      throwing this switch mid-challenge reverted the whole verdict —
    ///      `resolve()` could never complete, the slash never landed, both bonds
    ///      stranded in the game, and the frozen coverage barred every accused
    ///      approver from `claimUnstakeGuardian`, permanently. The game now
    ///      treats the demotion as best-effort and emits `AdapterDemotionFailed`
    ///      instead, so this role is safe to rotate at any time — and `demote`
    ///      below is the owner's remedy for any revocation the rotation lost.
    function setAuthorizedDemoter(address demoter) external onlyOwner {
        authorizedDemoter = demoter;
        emit AuthorizedDemoterSet(demoter);
    }

    /// @notice Owner demotion (revoke certification).
    function demote(address target, bytes4 selector) external onlyOwner {
        _demote(target, selector);
    }

    /// @notice Demote (target, selector) back to the tier-2 default because a
    ///         challenge against it passed. Reuses the same `_demote` path as
    ///         owner demotion, so the submitter-bond release timelock starts
    ///         identically (§3.6 slash-first layering).
    function demoteByChallenge(address target, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
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
        SubmitterBond storage b = _bonds[k];
        if (b.amount != 0 && b.releasableAt == 0) {
            uint64 releasableAt = uint64(block.timestamp + bondReleaseDelay);
            b.releasableAt = releasableAt;
            emit SubmitterBondReleaseStarted(target, selector, b.submitter, releasableAt);
        }
        emit TierDemoted(target, selector);
    }

    /// @notice Release a demoted bond to its submitter, `bondReleaseDelay` after
    ///         demotion. PERMISSIONLESS: the payout address is fixed to the
    ///         recorded submitter, so a caller gate would protect nothing —
    ///         and it would let a lost-key submitter permanently retire a
    ///         (target, selector) key, since `certify` blocks while any bond
    ///         exists. The delay is the window Plan C's guard-bypass slash
    ///         will act in.
    function claimSubmitterBond(address target, bytes4 selector) external {
        bytes32 k = key(target, selector);
        SubmitterBond memory b = _bonds[k];
        if (b.releasableAt == 0 || block.timestamp < b.releasableAt) revert BondNotReleasable();
        delete _bonds[k];
        totalBondedWood -= b.amount;
        wood.safeTransfer(b.submitter, b.amount);
        emit SubmitterBondClaimed(target, selector, b.submitter, b.amount);
    }

    /// @notice Full bond record for (target, selector) — Plan C's slash
    ///         contract and UIs need `releasableAt` to time the challenge
    ///         window. Zeroed struct when no bond exists.
    function bondOf(address target, bytes4 selector) external view returns (SubmitterBond memory) {
        return _bonds[key(target, selector)];
    }

    // ── Adapter allowlist (spender/recipient gate for value-moving selectors) ──

    /// @notice Allow or disallow `adapter` as the spender/recipient of
    ///         value-moving ERC20 calls (approve / increaseAllowance /
    ///         transfer / transferFrom-out) inside governor batches.
    function setAdapterAllowed(address adapter, bool allowed) external onlyOwner {
        _adapterAllowed[adapter] = allowed;
        emit AdapterAllowedSet(adapter, allowed);
    }

    /// @notice True when `adapter` may receive approvals/transfers of vault
    ///         funds through a governor batch.
    function isAdapterAllowed(address adapter) external view returns (bool) {
        return _adapterAllowed[adapter];
    }
}
