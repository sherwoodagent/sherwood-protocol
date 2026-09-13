// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
 *         them. Run `propose()` while the deployer still owns the registry,
 *         wait out the delay, then run `finalize()`.
 *
 *   Usage:
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'propose()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *     # ... wait certifyDelay (default 3 days) ...
 *     forge script script/CertifyStrategyClasses.s.sol:CertifyStrategyClasses \
 *       --sig 'finalize()' --rpc-url <rpc> --broadcast --account sherwood-agent
 *
 *   Risk-parameter overrides (see `_classSet`): PORTFOLIO_CLASS_TIER,
 *   PORTFOLIO_CLASS_BOUND_BPS, CL_CLASS_TIER, CL_CLASS_BOUND_BPS.
 */
contract CertifyStrategyClasses is ScriptBase {
    /// @dev `IStrategy.execute()` / `IStrategy.settle()` — the only two
    ///      selectors a governor batch ever names on a strategy clone.
    bytes4 internal constant SEL_EXECUTE = 0x61461954;
    bytes4 internal constant SEL_SETTLE = 0x11da60b4;

    // ── Risk parameters. RATIFY THESE BEFORE ANY MAINNET RUN. ──
    //
    // `tier` and `extractableBoundBps` are what the governor turns into
    // required guardian coverage: `Σ cap_i * boundBps / 10_000`
    // (`SyndicateGovernor._scanCalls`). A loose bound looks safe and prices the
    // review away, so these are stated per template, not derived in a loop.
    //
    // TIER 1 (oracle-bounded discretion), not 0: both templates swap on
    // external AMMs, bounded by oracle-derived floors rather than closed-loop.
    //
    // BOUND 2_000 bps = 2x the per-swap ceiling each template hard-codes
    // (`PortfolioStrategy.MAX_SLIPPAGE_CEILING_BPS` /
    // `ConcentratedLiquidityStrategy.MAX_SLIPPAGE_BPS`, both 1_000), covering
    // the entry and exit legs of one proposal. 5x headroom under tier 2's
    // 10_000 full notional.
    uint8 internal constant PORTFOLIO_TIER = 1;
    uint16 internal constant PORTFOLIO_BOUND_BPS = 2_000;
    uint8 internal constant CL_TIER = 1;
    uint16 internal constant CL_BOUND_BPS = 2_000;

    struct ClassParams {
        string key;
        uint8 tier;
        uint16 boundBps;
    }

    /// @dev The templates eligible for CLASS certification, with their risk
    ///      parameters. MORPHO_SUPPLY_TEMPLATE is deliberately absent:
    ///      `MorphoSupplyStrategy` validates its Morpho address by asking that
    ///      address, which disqualifies it per
    ///      docs/adapter-onboarding-checklist.md §4b eligibility rule 1 — it
    ///      stays address-certifiable only.
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
        for (uint256 i; i < set.length; ++i) {
            address template = _templateOrSkip(set[i].key);
            if (template == address(0)) continue;
            console.log("  proposing:", set[i].key, template);
            console.log("    tier / extractableBoundBps:", uint256(set[i].tier), uint256(set[i].boundBps));
            _proposeOne(registry, template, SEL_EXECUTE, set[i]);
            _proposeOne(registry, template, SEL_SETTLE, set[i]);
        }
        console.log("\n  RUNBOOK: wait certifyDelay seconds, then run finalize():", registry.certifyDelay());
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
        bool drifted;
        for (uint256 i; i < set.length; ++i) {
            address template = _templateOrSkip(set[i].key);
            if (template == address(0)) continue;
            if (registry.isClassAllowed(template)) {
                console.log("  skipped (class already allowed):", set[i].key);
                continue;
            }
            if (_templateDrifted(registry, template, set[i].key)) {
                drifted = true;
                continue;
            }
            _certifyOne(registry, template, SEL_EXECUTE);
            _certifyOne(registry, template, SEL_SETTLE);
            registry.setClassAllowed(template, true);
            console.log("  class allowed (callee + funds axes):", set[i].key, template);
        }
        require(!drifted, "template codehash drifted since propose - see RUNBOOK lines above");
    }

    function _certifyOne(TierRegistry registry, address template, bytes4 selector) private {
        if (registry.pendingClassCertificationOf(template, selector).readyAt == 0) {
            console.log("    no pending certification (already executed), skipping certifyClass");
            return;
        }
        registry.certifyClass(template, selector);
    }

    /// @dev A template redeployed between the two phases voids the grant inside
    ///      `certifyClass` with `TemplateCodehashChanged`. Name it here instead,
    ///      with the recovery, rather than letting a bare selector surface.
    function _templateDrifted(TierRegistry registry, address template, string memory key) private view returns (bool) {
        TierRegistry.PendingClassCertification memory pending =
            registry.pendingClassCertificationOf(template, SEL_EXECUTE);
        if (pending.readyAt == 0 || pending.templateCodehash == template.codehash) return false;
        console.log("  RUNBOOK: TEMPLATE REDEPLOYED SINCE propose() -", key, template);
        console.log("  RUNBOOK: the pending grant is void. Owner must call");
        console.log("  RUNBOOK: cancelClassCertification(template, selector) for both selectors,");
        console.log("  RUNBOOK: re-review the new code, then re-run propose().");
        return true;
    }

    // ── Guards ──

    /// @dev Mirrors `Deploy._seedTierRegistry`: both phases are `onlyOwner`
    ///      writes, so a completed Ownable2Step handoff means the multisig runs
    ///      the ceremony. Skip, never revert — the deploy has already broadcast.
    function _ownsRegistry(TierRegistry registry, address deployer) private view returns (bool) {
        if (registry.owner() == deployer) return true;
        console.log("RUNBOOK: deployer no longer owns TierRegistry - class certification SKIPPED.");
        console.log("RUNBOOK: the owner must run propose()/finalize() itself before any strategy proposal.");
        return false;
    }

    /// @dev With a bond configured, `certifyClass` becomes submitter-only and
    ///      pulls WOOD from that submitter — a flow this script does not fund.
    function _bondIsUnset(TierRegistry registry) private view returns (bool) {
        uint256 bond = registry.submitterBondWood();
        if (bond == 0) return true;
        console.log("RUNBOOK: submitterBondWood is non-zero - class certification SKIPPED:", bond);
        console.log("RUNBOOK: propose with a real submitter, who must approve WOOD and call certifyClass.");
        return false;
    }

    function _templateOrSkip(string memory key) private view returns (address) {
        address template = _optionalAddress(key);
        if (template == address(0)) {
            console.log("  skipped (not in address book):", key);
            return address(0);
        }
        if (template.code.length == 0) {
            console.log("  skipped (no code at book address):", key, template);
            return address(0);
        }
        return template;
    }
}
