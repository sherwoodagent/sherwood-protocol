// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IStrategyFactory} from "./interfaces/IStrategyFactory.sol";

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
 *      on mismatch — no state write in the hot path, nothing to grief.
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
 */
contract TierRegistry is Ownable2Step {
    struct TierConfig {
        uint8 tier; // 0 or 1 when certified; entry absent => tier 2
        uint16 extractableBoundBps; // certified extractable bound, bps of notional
        bytes32 certifiedCodehash; // EXTCODEHASH of target at certification
    }

    uint8 public constant TIER_ARBITRARY = 2;
    uint16 public constant FULL_NOTIONAL_BPS = 10_000;

    /// @dev EXTCODEHASH of an EXISTING account with no code (EIP-1052). A funded
    ///      EOA hashes to this, not bytes32(0) — `certify` rejects both.
    bytes32 private constant _EMPTY_CODEHASH = keccak256("");

    mapping(bytes32 configKey => TierConfig) private _configs;

    /// @dev Addresses a strategy template may bind as a venue. The only address axis;
    ///      confers nothing to a governor batch, which the vault admits structurally.
    mapping(address counterparty => bool) private _counterpartyAllowed;

    /// @dev Grant-time codehash snapshot; meaningful only while the flag is set.
    mapping(address counterparty => bytes32) private _counterpartyAllowedCodehash;

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
    ///         clone of one template is byte-identical, so a matching codehash
    ///         narrows a target to "clone of `template`" — one of the three
    ///         conditions `_classOf` requires, alongside the anchored template
    ///         codehash and the factory's own provenance record.
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
        // Class fallback. `_classOf` returns 0 unless the target is a
        // factory-minted clone of a certified template whose code is unchanged.
        bytes32 cch = _classOf(target);
        if (cch != bytes32(0)) {
            TierConfig storage cc = _classConfigs[_classCfgKey(cch, selector)];
            if (cc.certifiedCodehash != bytes32(0)) return (cc.tier, cc.extractableBoundBps);
        }
        return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
    }

    event TierCertified(
        address indexed target, bytes4 indexed selector, uint8 tier, uint16 extractableBoundBps, bytes32 codehash
    );
    event TierDemoted(address indexed target, bytes4 indexed selector);
    event CounterpartyAllowedSet(address indexed counterparty, bool allowed);

    error InvalidTier();
    error BoundRequired();
    error NotAContract();
    error NotCertified();
    error CodehashChanged();

    /// @notice Certify (target, selector) at tier 0/1 with its extractable bound.
    /// @dev `expectedCodehash` is the hash the owner reviewed off-chain: reading
    ///      `target.codehash` live would let the target's deployer land different
    ///      bytecode before this transaction mines and pin a hash nobody reviewed.
    function certify(address target, bytes4 selector, uint8 tier, uint16 extractableBoundBps, bytes32 expectedCodehash)
        external
        onlyOwner
    {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) revert NotAContract();
        if (ch != expectedCodehash) revert CodehashChanged();
        _configs[key(target, selector)] =
            TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: ch});
        emit TierCertified(target, selector, tier, extractableBoundBps, ch);
    }

    /// @notice The one address permitted to demote on a passed challenge — the
    ///         ChallengeGame. A ROLE rather than registry ownership, so the
    ///         game can revoke a certification but never grant one.
    address public authorizedDemoter;

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
    /// @dev    Requires an existing certification — see `demoteByChallenge`'s
    ///         natspec for why this guard exists.
    function demote(address target, bytes4 selector) external onlyOwner {
        if (!_isCertifiedFor(target, selector)) revert NotCertified();
        _demote(target, selector);
    }

    /// @notice Demote (target, selector) back to the tier-2 default because a
    ///         challenge against it passed.
    /// @dev    REQUIRES AN EXISTING CERTIFICATION: `ChallengeGame.file`
    ///         only checks that the pair appears in the executed calldata, so an
    ///         uncertified selector must not be demotable for ~1% of coverage.
    ///
    ///         ACCEPTS A CLASS-ONLY MEMBER (see `_isCertifiedFor`). Restricting
    ///         this to address entries made the whole class axis unreachable
    ///         from adjudication: the normal class-certified clone has no
    ///         address entry, so this reverted `NotCertified` into
    ///         `ChallengeGame`'s bare catch and a won challenge produced only an
    ///         `AdapterDemotionFailed` event. The anti-grief guard is unchanged
    ///         in substance — an uncertified selector is still rejected.
    function demoteByChallenge(address target, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        if (!_isCertifiedFor(target, selector)) revert NotCertified();
        _demote(target, selector);
    }

    function _demote(address target, bytes4 selector) private {
        bytes32 k = key(target, selector);
        delete _configs[k];
        if (!_classTierDenied[k]) {
            _classTierDenied[k] = true;
            emit ClassMemberTierDenied(target, selector);
        }
        emit TierDemoted(target, selector);
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

    /// @notice Allow or disallow `counterparty` as a venue a strategy template may bind.
    /// @dev    Snapshots the codehash on grant: grant after the final code is deployed,
    ///         re-grant to re-attest a verified bytecode change. No class fallback.
    function setCounterpartyAllowed(address counterparty, bool allowed) external onlyOwner {
        _counterpartyAllowed[counterparty] = allowed;
        if (allowed) _counterpartyAllowedCodehash[counterparty] = _effectiveCodehash(counterparty);
        emit CounterpartyAllowedSet(counterparty, allowed);
    }

    /// @notice True while the grant stands and the live effective codehash matches the
    ///         grant-time snapshot (same lazy self-heal and proxy caveat as `tierOf`).
    function isCounterpartyAllowed(address counterparty) external view returns (bool) {
        return _counterpartyAllowed[counterparty]
            && _effectiveCodehash(counterparty) == _counterpartyAllowedCodehash[counterparty];
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

    /// @dev class fingerprint (clone codehash) => anchor. One per class,
    ///      shared by the tier and allowlist axes.
    mapping(bytes32 cloneCodehash => ClassAnchor) private _classAnchors;

    /// @dev `_classCfgKey(cloneCodehash, selector)` => tier config. A SEPARATE
    ///      mapping from `_configs`, so an address entry can never be written
    ///      or demoted through a class entry point or vice versa — namespace
    ///      isolation is structural here, not merely improbable.
    mapping(bytes32 classConfigKey => TierConfig) private _classConfigs;

    /// @dev A selector certified against one template codehash is never served
    ///      for another.
    mapping(bytes32 cloneCodehash => uint64 epoch) private _classEpoch;

    /// @notice The StrategyFactory whose clone provenance gates class
    ///         membership. Zero resolves no class at all.
    address public strategyFactory;

    /// @dev Class fingerprint at the CURRENT epoch. The funds bit and the tier
    ///      configs are keyed by it, so a re-point orphans them in O(1).
    function _classFp(bytes32 cch) private view returns (bytes32) {
        return keccak256(abi.encodePacked(cch, _classEpoch[cch]));
    }

    /// @dev Class tier-config key at the current epoch.
    function _classCfgKey(bytes32 cch, bytes4 selector) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_classFp(cch), selector));
    }

    // ── PER-MEMBER DENIAL (the class fallback's off switch) ──
    //
    // Revocation in this contract is expressed as ERASURE: `_demote` deletes
    // `_configs[k]`, and the absence of a record
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
    ///      WRITE-ONCE BY DESIGN — nothing clears it. The recovery path is an
    ///      ordinary `certify`, which writes an address entry that wins ahead
    ///      of both this flag and the class.
    mapping(bytes32 configKey => bool) private _classTierDenied;

    event ClassMemberTierDenied(address indexed target, bytes4 indexed selector);

    /// @notice Whether `target` has been barred from reading `selector`'s tier
    ///         off a class by a prior demotion.
    function isClassTierDenied(address target, bytes4 selector) external view returns (bool) {
        return _classTierDenied[key(target, selector)];
    }

    function _isCertifiedFor(address target, bytes4 selector) private view returns (bool) {
        if (_configs[key(target, selector)].certifiedCodehash != bytes32(0)) return true;
        bytes32 cch = _classOf(target);
        if (cch == bytes32(0)) return false;
        return _classConfigs[_classCfgKey(cch, selector)].certifiedCodehash != bytes32(0);
    }

    error ClassNotCertified();
    error InvalidStrategyFactory();

    event ClassCertified(
        address indexed template,
        bytes4 indexed selector,
        bytes32 indexed cloneCodehash,
        uint8 tier,
        uint16 extractableBoundBps,
        bytes32 templateCodehash
    );
    event ClassDemoted(address indexed template, bytes4 indexed selector, bytes32 indexed cloneCodehash);

    /// @notice Points class membership at a contract that answers `cloneTemplate(0)`
    ///         with `address(0)`; reverts on any other answer, including none. `onlyOwner`.
    function setStrategyFactory(address factory) external onlyOwner {
        if (factory.code.length == 0) revert InvalidStrategyFactory();
        try IStrategyFactory(factory).cloneTemplate(address(0)) returns (address t) {
            if (t != address(0)) revert InvalidStrategyFactory();
        } catch {
            revert InvalidStrategyFactory();
        }
        strategyFactory = factory;
    }

    /// @dev The CODE half of class membership, no provenance condition — stays
    ///      true for a clone the current factory pointer does not vouch for.
    function _classAnchorOf(address target) private view returns (bytes32 cch, address template) {
        bytes32 ch = target.codehash;
        if (ch == bytes32(0) || ch == _EMPTY_CODEHASH) return (bytes32(0), address(0));
        ClassAnchor storage a = _classAnchors[ch];
        address t = a.template;
        if (t == address(0) || t.codehash != a.templateCodehash) return (bytes32(0), address(0));
        return (ch, t);
    }

    /// @dev The code half plus the factory's provenance record. Read by the
    ///      tier, funds and class-config axes, never by the callee axis.
    function _classOf(address target) private view returns (bytes32) {
        (bytes32 ch, address t) = _classAnchorOf(target);
        if (ch == bytes32(0)) return bytes32(0);
        return _provenanceTemplateOf(target) == t ? ch : bytes32(0);
    }

    /// @dev The factory's `cloneTemplate` record for `target`, resolving to
    ///      `address(0)` on any answer that is not one clean word. A pointer
    ///      that stops answering must de-class, never revert: `tierOf` is read
    ///      at propose, and a revert there refuses every proposal at once.
    function _provenanceTemplateOf(address target) private view returns (address) {
        address f = strategyFactory;
        if (f == address(0)) return address(0);
        (bool ok, bytes memory ret) = f.staticcall(abi.encodeCall(IStrategyFactory.cloneTemplate, (target)));
        if (!ok || ret.length != 32) return address(0);
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint160).max) return address(0);
        return address(uint160(word));
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

    /// @notice Certify every `StrategyFactory` clone of `template` for `selector`.
    /// @dev The owner must verify off-chain that `template` binds every init-supplied
    ///      address and is not itself a proxy; nothing here can check that.
    function certifyClass(
        address template,
        bytes4 selector,
        uint8 tier,
        uint16 extractableBoundBps,
        bytes32 expectedTemplateCodehash
    ) external onlyOwner {
        if (tier >= TIER_ARBITRARY) revert InvalidTier();
        if (extractableBoundBps == 0 || extractableBoundBps >= FULL_NOTIONAL_BPS) revert BoundRequired();
        bytes32 tch = template.codehash;
        if (tch == bytes32(0) || tch == _EMPTY_CODEHASH) revert NotAContract();
        if (tch != expectedTemplateCodehash) revert CodehashChanged();
        bytes32 cch = cloneCodehashOf(template);
        bytes32 anchored = _classAnchors[cch].templateCodehash;
        if (anchored != bytes32(0) && anchored != tch) ++_classEpoch[cch];
        _classAnchors[cch] = ClassAnchor({template: template, templateCodehash: tch});
        _classConfigs[_classCfgKey(cch, selector)] =
            TierConfig({tier: tier, extractableBoundBps: extractableBoundBps, certifiedCodehash: cch});
        emit ClassCertified(template, selector, cch, tier, extractableBoundBps, tch);
    }

    /// @notice Effective tier for a class's `selector`, ignoring membership.
    ///         `(2, 10_000)` when the class carries no certification.
    function classTierOf(address template, bytes4 selector) external view returns (uint8, uint16) {
        TierConfig storage c = _classConfigs[_classCfgKey(cloneCodehashOf(template), selector)];
        if (c.certifiedCodehash == bytes32(0)) return (TIER_ARBITRARY, FULL_NOTIONAL_BPS);
        return (c.tier, c.extractableBoundBps);
    }

    /// @notice Demote a class for `selector`. `onlyOwner`. Instant.
    function demoteClass(address template, bytes4 selector) external onlyOwner {
        if (_classConfigs[_classCfgKey(cloneCodehashOf(template), selector)].certifiedCodehash == bytes32(0)) {
            revert ClassNotCertified();
        }
        _demoteClass(template, selector);
    }

    /// @notice Demote a class for `selector` on a challenge conviction.
    ///         Restricted to `authorizedDemoter`, mirroring `demoteByChallenge`.
    function demoteClassByChallenge(address template, bytes4 selector) external {
        if (msg.sender != authorizedDemoter) revert NotAuthorizedDemoter();
        bytes32 cch = cloneCodehashOf(template);
        if (_classConfigs[_classCfgKey(cch, selector)].certifiedCodehash == bytes32(0)) revert ClassNotCertified();
        _demoteClass(template, selector);
    }

    function _demoteClass(address template, bytes4 selector) private {
        bytes32 cch = cloneCodehashOf(template);
        delete _classConfigs[_classCfgKey(cch, selector)];
        emit ClassDemoted(template, selector, cch);
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

    /// @dev token => price source (aggregator address widened to bytes32) => attested.
    ///      Callers MUST strip packed metadata (e.g. max-age) before lookup, so one
    ///      attestation covers every staleness variant.
    mapping(address token => mapping(bytes32 priceSource => bool)) private _tokenPriceSource;

    event PriceSourceForTokenSet(address indexed token, bytes32 indexed priceSource, bool allowed);

    /// @notice Attest that `priceSource` prices `token`. `onlyOwner`.
    /// @dev    A separate axis from `setCounterpartyAllowed`: that says "this source
    ///         may be bound at all", this says "…for THIS token". Adversary: a
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
