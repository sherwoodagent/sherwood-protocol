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

    uint8 public constant TIER_ARBITRARY = 2;
    uint16 public constant FULL_NOTIONAL_BPS = 10_000;

    /// @dev Floor keeps a demoted bond claimable-not-yet-claimed long enough
    ///      for the slash mechanism to act before payout. Ceiling bounds
    ///      governance error.
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
    ///         the bond requirement.
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
    ///         floor prevents a mis-certifying submitter from exiting before
    ///         the slash mechanism can act.
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
    ///         bond must traverse its release timelock before the key can
    ///         carry a new bond.
    ///
    ///         This applies to benign edits too: correcting an
    ///         `extractableBoundBps` typo, or re-certifying after a
    ///         legitimate adapter upgrade, costs the full demote → delay →
    ///         claim → certify cycle, and the key sits at tier 2 (full
    ///         notional, priced not bounded) for the whole window.
    ///
    ///         Re-certifying a (target, selector) that a prior demotion
    ///         auto-cleared from the adapter allowlist (see `_demote`) does
    ///         NOT restore that allowlist entry — `certify` never sets or
    ///         restores `_adapterAllowed`. Restoring it is always a separate,
    ///         explicit owner `setAdapterAllowed(adapter, true)` call; the
    ///         coupling between the two axes is one-way and fail-closed.
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
        // Pull the submitter bond when configured; a zero bond amount skips it.
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
    ///         ChallengeGame. A ROLE rather than registry ownership, so the
    ///         game can revoke a certification but never grant one.
    address public authorizedDemoter;

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
    function _demote(address target, bytes4 selector) private {
        bytes32 k = key(target, selector);
        delete _configs[k];
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

    /// @notice Allow or disallow `adapter` as the spender/recipient of
    ///         value-moving ERC20 calls (approve / increaseAllowance /
    ///         transfer / transferFrom-out) inside governor batches.
    /// @dev    The only path that SETS this to true. `_demote` is the only
    ///         path that clears it (see `_demote` natspec for the
    ///         over-broad-by-design clear on any demotion of the adapter).
    ///         `certify` never touches this mapping — re-allowlisting after a
    ///         demotion-triggered clear is always this explicit owner call,
    ///         never a side effect of re-certification.
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
