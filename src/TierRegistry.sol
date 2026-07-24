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

    error InvalidTier();
    error BoundRequired();
    error NotAContract();
    error CodehashMatches();
    error NotCertified();
    error BondNotReleasable();
    error BondPendingRelease();
    error NotSubmitter();
    error BondConfigUnset();
    error ZeroAddressSubmitter();

    /// @notice Set the WOOD token used for submitter bonds.
    function setWood(address wood_) external onlyOwner {
        wood = IERC20(wood_);
        emit SubmitterBondConfigSet(wood_, submitterBondWood, bondReleaseDelay);
    }

    /// @notice Set the submitter bond amount pulled on `certify`. Zero disables
    ///         the bond requirement (Plan A no-bond passthrough).
    function setSubmitterBondWood(uint256 amount) external onlyOwner {
        if (amount != 0 && address(wood) == address(0)) revert BondConfigUnset();
        submitterBondWood = amount;
        emit SubmitterBondConfigSet(address(wood), amount, bondReleaseDelay);
    }

    /// @notice Set the timelock delay between demotion and submitter bond claim.
    function setBondReleaseDelay(uint256 delay) external onlyOwner {
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
    function certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, address submitter)
        external
        onlyOwner
    {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) revert NotAContract();
        bytes32 k = key(target, selector);
        // A bond pending release blocks re-certification — one bond per key.
        if (_bonds[k].releasableAt != 0) revert BondPendingRelease();
        // Pull the submitter bond when configured (spec §3.6). Zero-config
        // (bond amount 0) preserves the Plan A no-bond path for the governance-
        // assigned initial adapter set.
        uint256 bondAmount = submitterBondWood;
        if (bondAmount != 0) {
            if (submitter == address(0)) revert ZeroAddressSubmitter();
            _bonds[k] = SubmitterBond({submitter: submitter, amount: uint96(bondAmount), releasableAt: 0});
            wood.safeTransferFrom(submitter, address(this), bondAmount);
            emit SubmitterBondLocked(target, selector, submitter, bondAmount);
        }
        _configs[k] = TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: ch});
        emit TierCertified(target, selector, tier, extractableBoundBps, ch);
    }

    /// @notice Owner demotion (revoke certification).
    function demote(address target, bytes4 selector) external onlyOwner {
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
            b.releasableAt = uint64(block.timestamp + bondReleaseDelay);
        }
        emit TierDemoted(target, selector);
    }

    /// @notice Submitter claims its bond back, `bondReleaseDelay` after demotion.
    ///         The delay is the window Plan C's guard-bypass slash will act in.
    function claimSubmitterBond(address target, bytes4 selector) external {
        bytes32 k = key(target, selector);
        SubmitterBond memory b = _bonds[k];
        if (b.submitter != msg.sender) revert NotSubmitter();
        if (b.releasableAt == 0 || block.timestamp < b.releasableAt) revert BondNotReleasable();
        delete _bonds[k];
        wood.safeTransfer(b.submitter, b.amount);
        emit SubmitterBondClaimed(target, selector, b.submitter, b.amount);
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
