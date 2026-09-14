// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {TierRegistry} from "../src/TierRegistry.sol";

/**
 * @title  CertifyStrategyClasses
 * @notice Certify and allowlist the CODE CLASS of each strategy template, so a
 *         freshly deployed protocol can execute a strategy proposal at all.
 *
 *         Without this ceremony `SyndicateVault._guardBatchCalls` refuses every
 *         batch naming a strategy clone: the callee axis
 *         (`isCallableTarget`) rejects it with `DisallowedBatchCallee`, and the
 *         funds axis (`isAdapterAllowed`) rejects approving capital into it
 *         with `DisallowedTransferTarget`. Clones share one codehash, so one
 *         class grant covers every clone that will ever exist — the per-address
 *         dual-gate would have to be re-run once per proposal, forever.
 *
 *         TWO PHASES, because `certifyDelay` (default 3 days) sits between
 *         them, and phase B is legal only inside `MAX_CERTIFY_WINDOW` (14 days)
 *         past that. Run `propose()` while the deployer still owns the
 *         registry, wait out the delay, then run `finalize()` inside the window.
 *
 *   Usage:
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'propose()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *     # ... wait certifyDelay (default 3 days), finalize within 14 days ...
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'finalize()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *
 *   Risk-parameter overrides (see `_classSet`): PORTFOLIO_CLASS_TIER,
 *   PORTFOLIO_CLASS_BOUND_BPS, CL_CLASS_TIER, CL_CLASS_BOUND_BPS.
 *   `CERTIFY_STRICT=true` turns every skip below into a revert.
 */
contract CertifyStrategyClasses is ScriptBase {
    /// @dev `IStrategy.execute()` / `IStrategy.settle()` — the only two
    ///      selectors a governor batch ever names on a strategy clone.
    bytes4 internal constant SEL_EXECUTE = 0x61461954;
    bytes4 internal constant SEL_SETTLE = 0x11da60b4;

    // ── Risk parameters. RATIFY BEFORE ANY MAINNET RUN. ──
    //
    // `boundBps` becomes required guardian coverage PER CALL:
    // `Σ cap_i * boundBps / 10_000` (`SyndicateGovernor._scanCalls`).
    // Tier 1, not 0: both templates swap on external AMMs.
    // Portfolio 2_000 = 2x its <=1_000 bps single-call slippage ceiling.
    // CL 9_999 (max below `FULL_NOTIONAL_BPS`) = tier-2-equivalent coverage:
    // levered CL leaves `marketParams.oracle/irm/lltv` unbound (only
    // `lastUpdate != 0` is checked, true of any permissionless Morpho market),
    // so a hostile oracle seizes the whole collateral.
    // NO BOUND PRICES `PortfolioStrategy.rebalance()`/`rebalanceDelta()`
    // (`onlyProposer`, off-batch, <= `MAX_CUMULATIVE_DECAY_BPS` lifetime decay)
    // or the permissionless `ConcentratedLiquidityStrategy.rerange()`.
    // RATIFY: tier < 2 also drops the per-call `Tier2CallCapExceedsCeiling`.
    uint8 internal constant PORTFOLIO_TIER = 1;
    uint16 internal constant PORTFOLIO_BOUND_BPS = 2_000;
    uint8 internal constant CL_TIER = 1;
    uint16 internal constant CL_BOUND_BPS = 9_999;

    struct ClassParams {
        string key;
        uint8 tier;
        uint16 boundBps;
    }

    /// @dev The templates eligible for CLASS certification, with their risk
    ///      parameters. MORPHO_SUPPLY_TEMPLATE is deliberately absent: its
    ///      `marketParams.oracle/irm/lltv` are proposer-chosen and unbound, so
    ///      no class bound holds over every initialization. Its address path is
    ///      impractical rather than equivalent — see the openspec change.
    function _classSet() internal view returns (ClassParams[] memory set) {
        set = new ClassParams[](2);
        set[0] = ClassParams({
            key: "PORTFOLIO_TEMPLATE",
            tier: uint8(vm.envOr("PORTFOLIO_CLASS_TIER", uint256(PORTFOLIO_TIER))),
            boundBps: uint16(vm.envOr("PORTFOLIO_CLASS_BOUND_BPS", uint256(PORTFOLIO_BOUND_BPS)))
        });
        set[1] = ClassParams({
            key: "CONCENTRATED_LIQUIDITY_TEMPLATE",
            tier: uint8(vm.envOr("CL_CLASS_TIER", uint256(CL_TIER))),
            boundBps: uint16(vm.envOr("CL_CLASS_BOUND_BPS", uint256(CL_BOUND_BPS)))
        });
    }

    // ── Entrypoints ──

    /// @notice Phase A: announce a class certification for every deployed
    ///         template, for both selectors. Starts the `certifyDelay` clock.
    function propose() external {
        address tierRegistry = _readAddress("TIER_REGISTRY");
        vm.startBroadcast();
        _proposeClasses(msg.sender, tierRegistry);
        vm.stopBroadcast();
    }

    /// @notice Phase B: execute the pending certifications and open both
    ///         allowlist axes. Idempotent — re-running skips allowed classes.
    function finalize() external {
        address tierRegistry = _readAddress("TIER_REGISTRY");
        vm.startBroadcast();
        _finalizeClasses(msg.sender, tierRegistry);
        vm.stopBroadcast();
    }

    // ── Phase A ──

    function _proposeClasses(address deployer, address tierRegistryAddr) internal {
        console.log("\n=== Strategy class certification: propose ===");
        TierRegistry registry = TierRegistry(tierRegistryAddr);
        if (!_ownsRegistry(registry, deployer)) return;
        if (!_bondIsUnset(registry)) return;

        ClassParams[] memory set = _classSet();
        bool halted;
        for (uint256 i; i < set.length; ++i) {
            address template = _templateOrSkip(set[i].key);
            if (template == address(0)) continue;
            if (_revokedOrPartial(registry, template, set[i].key)) {
                halted = true;
                continue;
            }
            console.log("  proposing:", set[i].key, template);
            console.log("    tier / extractableBoundBps:", uint256(set[i].tier), uint256(set[i].boundBps));
            _proposeOne(registry, template, SEL_EXECUTE, set[i]);
            _proposeOne(registry, template, SEL_SETTLE, set[i]);
        }
        console.log("\n  RUNBOOK: run finalize() no earlier than certifyDelay seconds:", registry.certifyDelay());
        console.log(
            "  RUNBOOK: and no later than this unix deadline, else MAX_CERTIFY_WINDOW lapses:",
            block.timestamp + registry.certifyDelay() + registry.MAX_CERTIFY_WINDOW()
        );
        require(!halted, "class previously certified then revoked - see RUNBOOK lines above");
    }

    function _proposeOne(TierRegistry registry, address template, bytes4 selector, ClassParams memory p) private {
        TierRegistry.PendingClassCertification memory pending = registry.pendingClassCertificationOf(template, selector);
        if (pending.readyAt != 0) {
            console.log("    already pending, readyAt:", pending.readyAt);
            return;
        }
        (uint8 tier,) = registry.classTierOf(template, selector);
        if (tier != registry.TIER_ARBITRARY()) {
            console.log("    already certified, nothing to propose");
            return;
        }
        // `submitter` is address(0) because the bond is unset — checked above.
        registry.proposeClassCertification(template, selector, p.tier, p.boundBps, address(0), template.codehash);
    }

    // ── Phase B ──

    function _finalizeClasses(address deployer, address tierRegistryAddr) internal {
        console.log("\n=== Strategy class certification: finalize ===");
        TierRegistry registry = TierRegistry(tierRegistryAddr);
        // `setClassAllowed` is onlyOwner, so the whole phase needs ownership
        // even though `certifyClass` itself is permissionless.
        if (!_ownsRegistry(registry, deployer)) return;

        ClassParams[] memory set = _classSet();
        bool revoked;
        bool halted;
        bool deadGrant;
        for (uint256 i; i < set.length; ++i) {
            address template = _templateOrSkip(set[i].key);
            if (template == address(0)) continue;
            if (registry.isClassAllowed(template)) {
                console.log("  skipped (class already allowed):", set[i].key);
                continue;
            }
            if (_revokedOrPartial(registry, template, set[i].key)) {
                revoked = true;
                continue;
            }
            if (_templateDrifted(registry, template, set[i].key)) {
                halted = true;
                continue;
            }
            // Both, never short-circuited: `setClassAllowed` opens both axes for
            // every selector at once, so one certified selector is not a class.
            bool certified = _certifyOne(registry, template, SEL_EXECUTE);
            certified = _certifyOne(registry, template, SEL_SETTLE) && certified;
            if (!certified) {
                console.log("  RUNBOOK: NOT allowlisted - both selectors must be certified first:", set[i].key);
                halted = true;
                continue;
            }
            registry.setClassAllowed(template, true);
            // A grant is only real if a CLONE reads it. `_classOf` returns zero
            // whenever the anchor's snapshot no longer matches the live template,
            // so an allowed class can still refuse every clone it covers.
            if (!_cloneAxesOpen(registry, template)) {
                console.log("  RUNBOOK: ALLOWLISTED BUT EVERY CLONE IS STILL REFUSED -", set[i].key, template);
                console.log("  RUNBOOK: the class anchor does not match the deployed template. Owner must");
                console.log("  RUNBOOK: cancelClassCertification(template, selector) for both selectors and");
                console.log("  RUNBOOK: re-run propose() against the code that is actually deployed.");
                deadGrant = true;
                continue;
            }
            console.log("  class allowed (callee + funds axes):", set[i].key, template);
        }
        // Deferred on purpose: forge broadcasts only on a clean `run()`, so a
        // late revert makes the whole phase all-or-nothing under --broadcast.
        // One string per reason, so a test can tell WHICH guard fired: a revoked
        // class needs an owner decision, a halted one the RUNBOOK recovery above,
        // and a dead grant means a guard ahead of the write missed the drift.
        require(!revoked, "class previously certified then revoked - see RUNBOOK lines above");
        require(!halted, "class certification halted - see RUNBOOK lines above");
        require(!deadGrant, "class allowlisted but its clones are still refused - see RUNBOOK lines above");
    }

    /// @dev True once `selector` carries a live class certification. False is a
    ///      halt, not a skip: `readyAt == 0` also means never proposed or
    ///      cancelled, and allowlisting then opens both axes on a half class.
    function _certifyOne(TierRegistry registry, address template, bytes4 selector) private returns (bool) {
        TierRegistry.PendingClassCertification memory p = registry.pendingClassCertificationOf(template, selector);
        if (p.readyAt == 0) {
            (uint8 tier,) = registry.classTierOf(template, selector);
            if (tier != registry.TIER_ARBITRARY()) {
                console.log("    already certified, skipping certifyClass");
                return true;
            }
            console.log("  RUNBOOK: SELECTOR NEITHER CERTIFIED NOR ANNOUNCED - run propose() first.");
            return false;
        }
        uint256 expiresAt = p.readyAt + registry.MAX_CERTIFY_WINDOW();
        if (block.timestamp > expiresAt) {
            console.log("  RUNBOOK: CERTIFICATION WINDOW LAPSED at unix:", expiresAt);
            console.log("  RUNBOOK: owner must cancelClassCertification(template, selector) for both");
            console.log("  RUNBOOK: selectors, then re-run propose() and finalize() inside the window.");
            return false;
        }
        registry.certifyClass(template, selector);
        return true;
    }

    /// @dev Anchor survives `_demoteClass`, configs do not: anchor present with a
    ///      selector uncertified and nothing pending is "certified, then revoked"
    ///      — `setClassAllowed` natspec: restoration is an explicit owner call.
    function _revokedOrPartial(TierRegistry registry, address template, string memory key) private returns (bool) {
        if (registry.classAnchorOf(registry.cloneCodehashOf(template)).template == address(0)) return false;
        bool selectorsLive =
            _selectorLive(registry, template, SEL_EXECUTE) && _selectorLive(registry, template, SEL_SETTLE);
        if (selectorsLive && !_classDemoted(registry, template)) return false;
        console.log("  RUNBOOK: CLASS WAS CERTIFIED AND IS NO LONGER -", key, template);
        console.log("  RUNBOOK: owner demotion or a ChallengeGame conviction. This script will NOT re-grant it.");
        console.log("  RUNBOOK: after re-review the owner re-certifies and calls setClassAllowed(template, true)");
        console.log("  RUNBOOK: itself, so allowlist standing is never a side effect of re-running this script.");
        return true;
    }

    /// @dev Certified, or announced and still executable.
    function _selectorLive(TierRegistry registry, address template, bytes4 selector) private view returns (bool) {
        (uint8 tier,) = registry.classTierOf(template, selector);
        if (tier != registry.TIER_ARBITRARY()) return true;
        return registry.pendingClassCertificationOf(template, selector).readyAt != 0;
    }

    /// @dev The per-selector sweep only sees `execute()`/`settle()`, but
    ///      `_demoteClass` clears `_classAllowed` for the WHOLE class on ANY
    ///      selector. It leaves `_classCalleeAllowed` set, so callee-open with
    ///      the class disallowed is exactly "was allowlisted, then demoted" —
    ///      distinct from "certified, never allowlisted", where both are false.
    function _classDemoted(TierRegistry registry, address template) private returns (bool) {
        if (registry.isClassAllowed(template)) return false;
        return registry.isCallableTarget(Clones.clone(template));
    }

    /// @dev Both axes, read through a throwaway clone: `_classCalleeAllowed` has
    ///      no getter and class membership is only decidable from a member.
    function _cloneAxesOpen(TierRegistry registry, address template) private returns (bool) {
        address probe = Clones.clone(template);
        return registry.isCallableTarget(probe) && registry.isAdapterAllowed(probe);
    }

    /// @dev A template redeployed between the phases voids the grant inside
    ///      `certifyClass` with `TemplateCodehashChanged`. BOTH selectors: one
    ///      record can already be executed while the other still carries drift.
    ///      The ANCHOR too: with both grants already executed there is no pending
    ///      record left to inspect, and a stale anchor makes `_classOf` return
    ///      zero, so `setClassAllowed` would succeed and grant nothing.
    function _templateDrifted(TierRegistry registry, address template, string memory key) private view returns (bool) {
        bytes32 live = template.codehash;
        TierRegistry.ClassAnchor memory anchor = registry.classAnchorOf(registry.cloneCodehashOf(template));
        bool drifted = anchor.template != address(0) && anchor.templateCodehash != live;
        bytes4[2] memory selectors = [SEL_EXECUTE, SEL_SETTLE];
        for (uint256 i; i < selectors.length; ++i) {
            TierRegistry.PendingClassCertification memory p =
                registry.pendingClassCertificationOf(template, selectors[i]);
            if (p.readyAt != 0 && p.templateCodehash != live) drifted = true;
        }
        if (!drifted) return false;
        console.log("  RUNBOOK: TEMPLATE REDEPLOYED SINCE propose() -", key, template);
        console.log("  RUNBOOK: the pending grant is void. Owner must call");
        console.log("  RUNBOOK: cancelClassCertification(template, selector) for both selectors,");
        console.log("  RUNBOOK: re-review the new code, then re-run propose().");
        return true;
    }

    // ── Guards ──

    /// @dev Default is skip-with-a-RUNBOOK-line, so a deploy that already
    ///      broadcast is not aborted. `CERTIFY_STRICT=true` for a run that IS a
    ///      documented ceremony step and must not exit 0 having done nothing.
    function _haltIfStrict(string memory reason) private view {
        if (_strictMode()) revert(reason);
    }

    /// @dev The knob is the env var; the seam exists because `vm.setEnv` is
    ///      process-global and tests in a suite run in parallel, so an env-driven
    ///      strict test flips the flag under every test running beside it.
    function _strictMode() internal view virtual returns (bool) {
        return vm.envOr("CERTIFY_STRICT", false);
    }

    /// @dev Mirrors `Deploy._seedTierRegistry`: both phases are `onlyOwner`
    ///      writes, so a completed Ownable2Step handoff means the multisig runs
    ///      the ceremony. Skip, never revert — the deploy has already broadcast.
    function _ownsRegistry(TierRegistry registry, address deployer) private view returns (bool) {
        if (registry.owner() == deployer) return true;
        console.log("RUNBOOK: deployer no longer owns TierRegistry - class certification SKIPPED.");
        console.log("RUNBOOK: the owner must run propose()/finalize() itself before any strategy proposal.");
        _haltIfStrict("deployer does not own TierRegistry - class certification would be a no-op");
        return false;
    }

    /// @dev With a bond configured, `certifyClass` becomes submitter-only and
    ///      pulls WOOD from that submitter — a flow this script does not fund.
    function _bondIsUnset(TierRegistry registry) private view returns (bool) {
        uint256 bond = registry.submitterBondWood();
        if (bond == 0) return true;
        console.log("RUNBOOK: submitterBondWood is non-zero - class certification SKIPPED:", bond);
        console.log("RUNBOOK: propose with a real submitter, who must approve WOOD and call certifyClass.");
        _haltIfStrict("submitterBondWood is non-zero - this script funds no bonded submitter");
        return false;
    }

    function _templateOrSkip(string memory key) private view returns (address) {
        address template = _optionalAddress(key);
        if (template == address(0)) {
            console.log("  skipped (not in address book):", key);
            _haltIfStrict("strategy template missing from the address book");
            return address(0);
        }
        if (template.code.length == 0) {
            console.log("  skipped (no code at book address):", key, template);
            _haltIfStrict("no code at the address book's strategy template address");
            return address(0);
        }
        return template;
    }
}
