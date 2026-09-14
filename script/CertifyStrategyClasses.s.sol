// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {TierRegistry} from "../src/TierRegistry.sol";

/**
 * @title  CertifyStrategyClasses
 * @notice Certify the CODE CLASS of a strategy template, so proposals naming
 *         its clones are priced on their real loss surface instead of the
 *         uncertified default.
 *
 *         This is an ECONOMICS step, not a liveness one. `StrategyFactory`
 *         auto-registers every clone and `SyndicateVault._guardBatchCalls`
 *         admits any registered strategy, so clones are already callable.
 *         What certification changes is `SyndicateGovernor._scanCalls`, which
 *         reads `tierOf(target, selector)` per call: an uncertified class
 *         answers `(TIER_ARBITRARY, FULL_NOTIONAL_BPS)` and books full-notional
 *         required guardian coverage on every proposal.
 *
 *         TWO PHASES, because `certifyDelay` (default 3 days) sits between
 *         them, and phase B is legal only inside `MAX_CERTIFY_WINDOW` (14 days)
 *         past that — days 3-17 of the ceremony.
 *
 *   Usage:
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'propose()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *     # ... wait certifyDelay (default 3 days), finalize within 14 days ...
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'finalize()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *
 *   Risk-parameter overrides: PORTFOLIO_CLASS_TIER, PORTFOLIO_CLASS_BOUND_BPS.
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
    // 2_000 = 2x the <=1_000 bps single-call slippage ceiling
    // (`PortfolioStrategy.MAX_SLIPPAGE_CEILING_BPS`), which is the whole
    // in-batch surface: init binds the adapter, every feed, and each
    // token<->feed pairing through the registry.
    // NO BOUND PRICES `rebalanceDelta()` — `onlyProposer`, called on the clone
    // rather than through a governor batch, and this branch carries no
    // lifetime decay budget, so repeats are unbounded.
    // RATIFY: tier < 2 also drops the per-call `Tier2CallCapExceedsCeiling`.
    uint8 internal constant PORTFOLIO_TIER = 1;
    uint16 internal constant PORTFOLIO_BOUND_BPS = 2_000;

    struct ClassParams {
        string key;
        uint8 tier;
        uint16 boundBps;
    }

    /// @dev The templates eligible for CLASS certification. Certification buys
    ///      only a coverage discount here, so a template whose loss surface is
    ///      not bounded by its own `_initialize` stays uncertified and keeps
    ///      paying full notional — see the openspec change for CL and Morpho.
    function _classSet() internal view returns (ClassParams[] memory set) {
        set = new ClassParams[](1);
        set[0] = ClassParams({
            key: "PORTFOLIO_TEMPLATE",
            tier: uint8(vm.envOr("PORTFOLIO_CLASS_TIER", uint256(PORTFOLIO_TIER))),
            boundBps: uint16(vm.envOr("PORTFOLIO_CLASS_BOUND_BPS", uint256(PORTFOLIO_BOUND_BPS)))
        });
    }

    // ── Entrypoints ──

    /// @notice Phase A: announce a class certification for every eligible
    ///         template, for both selectors. Starts the `certifyDelay` clock.
    function propose() external {
        address tierRegistry = _readAddress("TIER_REGISTRY");
        vm.startBroadcast();
        _proposeClasses(msg.sender, tierRegistry);
        vm.stopBroadcast();
    }

    /// @notice Phase B: execute the pending certifications. Idempotent —
    ///         re-running skips classes already certified.
    function finalize() external {
        address tierRegistry = _readAddress("TIER_REGISTRY");
        vm.startBroadcast();
        _finalizeClasses(tierRegistry);
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

    /// @dev No ownership guard: `certifyClass` is permissionless without a
    ///      bond, and the `onlyOwner` write this phase used to make
    ///      (`setClassAllowed`) no longer exists. A handoff that lands inside
    ///      the 3-day gap must not strand the ceremony.
    function _finalizeClasses(address tierRegistryAddr) internal {
        console.log("\n=== Strategy class certification: finalize ===");
        TierRegistry registry = TierRegistry(tierRegistryAddr);

        ClassParams[] memory set = _classSet();
        bool revoked;
        bool halted;
        for (uint256 i; i < set.length; ++i) {
            address template = _templateOrSkip(set[i].key);
            if (template == address(0)) continue;
            if (_revokedOrPartial(registry, template, set[i].key)) {
                revoked = true;
                continue;
            }
            if (_templateDrifted(registry, template, set[i].key)) {
                halted = true;
                continue;
            }
            // Both, never short-circuited: a governor batch names execute() and
            // settle(), so one certified selector still prices the other at
            // full notional.
            bool certified = _certifyOne(registry, template, SEL_EXECUTE);
            certified = _certifyOne(registry, template, SEL_SETTLE) && certified;
            if (!certified) {
                console.log("  RUNBOOK: BOTH selectors must be certified - see the lines above:", set[i].key);
                halted = true;
                continue;
            }
            console.log("  class certified on both selectors:", set[i].key, template);
        }
        // Deferred on purpose: forge broadcasts only on a clean run, so a late
        // revert makes the whole phase all-or-nothing under --broadcast. One
        // string per reason, so a test can tell WHICH guard fired.
        require(!revoked, "class previously certified then revoked - see RUNBOOK lines above");
        require(!halted, "class certification halted - see RUNBOOK lines above");
    }

    /// @dev True once `selector` carries a live class certification. False is a
    ///      halt, not a skip: `readyAt == 0` also means never proposed or
    ///      cancelled.
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

    /// @dev The anchor survives `_demoteClass`, the tier config does not. An
    ///      anchor standing over a selector that is neither certified nor
    ///      pending is "certified, then taken away" — or a class only ever
    ///      half-granted. Both need an owner decision, not a re-run.
    function _revokedOrPartial(TierRegistry registry, address template, string memory key) private view returns (bool) {
        if (registry.classAnchorOf(registry.cloneCodehashOf(template)).template == address(0)) return false;
        if (_selectorLive(registry, template, SEL_EXECUTE) && _selectorLive(registry, template, SEL_SETTLE)) {
            return false;
        }
        console.log("  RUNBOOK: CLASS WAS CERTIFIED AND IS NO LONGER -", key, template);
        console.log("  RUNBOOK: owner demotion or a ChallengeGame conviction. This script will NOT re-grant it.");
        console.log("  RUNBOOK: after re-review the owner re-announces with proposeClassCertification itself,");
        console.log("  RUNBOOK: so restored standing is never a side effect of re-running this script.");
        return true;
    }

    /// @dev Certified, or announced and still executable.
    function _selectorLive(TierRegistry registry, address template, bytes4 selector) private view returns (bool) {
        (uint8 tier,) = registry.classTierOf(template, selector);
        if (tier != registry.TIER_ARBITRARY()) return true;
        return registry.pendingClassCertificationOf(template, selector).readyAt != 0;
    }

    /// @dev A template redeployed between the phases voids the grant inside
    ///      `certifyClass` with `TemplateCodehashChanged`. BOTH selectors: one
    ///      record can already be executed while the other still carries drift.
    ///      The ANCHOR too: with both grants already executed there is no
    ///      pending record left to inspect, and a stale anchor makes
    ///      `_classAnchorOf` resolve nothing, so every clone silently falls
    ///      back to the uncertified default.
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
        console.log("  RUNBOOK: the pending grant is void and the anchored one covers no clone. Owner must call");
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

    /// @dev Seam for the same reason as `_strictMode`: no shipped address book
    ///      carries the `*_TEMPLATE` keys, so a test cannot stage one without
    ///      writing into `chains/`.
    function _templateAddress(string memory key) internal view virtual returns (address) {
        return _optionalAddress(key);
    }

    /// @dev Mirrors `Deploy._seedTierRegistry`: `proposeClassCertification` is
    ///      `onlyOwner`, so a completed Ownable2Step handoff means the multisig
    ///      runs phase A. Skip, never revert — the deploy has already broadcast.
    function _ownsRegistry(TierRegistry registry, address deployer) private view returns (bool) {
        if (registry.owner() == deployer) return true;
        console.log("RUNBOOK: deployer no longer owns TierRegistry - class certification SKIPPED.");
        console.log("RUNBOOK: the owner must run propose() itself before any strategy proposal is priced.");
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
        address template = _templateAddress(key);
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
