// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";
import {StrategyFactory} from "../src/StrategyFactory.sol";
import {TierRegistry} from "../src/TierRegistry.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IZkLighter} from "../src/lighter/IZkLighter.sol";
import {LighterPerpStrategy} from "../src/strategies/LighterPerpStrategy.sol";

/**
 * @title  DeployLighterTemplate
 * @notice Deploy the `LighterPerpStrategy` template, approve it on the existing
 *         `StrategyFactory`, and open the TierRegistry ceremony that makes clones
 *         of it usable.
 *
 *   TWO ENTRYPOINTS, BECAUSE THE CLASS PATH HAS A DELAY.
 *   `TierRegistry.certifyClass` cannot run until `certifyDelay` (default 3 days)
 *   after `proposeClassCertification`, so the ceremony cannot be one broadcast:
 *
 *     run()       deploy → approve on the factory → `setCounterpartyAllowed(ZK_LIGHTER)`
 *                 → `proposeClassCertification(template, name(), ...)`
 *     finalize()  (after readyAt) `certifyClass(template, name())`
 *                 → `setClassAllowed(template, true)`
 *
 *   `execute()` AND `settle()` ARE DELIBERATELY LEFT UNCERTIFIED. That is the
 *   whole point of the ceremony's shape and it is the opposite of what the
 *   sibling templates do, so read `_classTier` below before "fixing" it: this
 *   template is priced at the uncertified tier-2 / full-notional default, and
 *   the only thing certified is an inert selector that exists to mint the class
 *   ANCHOR `setClassAllowed` requires.
 *
 *   Usage — Robinhood mainnet (4663):
 *     forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --sig 'run()' --rpc-url robinhood --account sherwood-deployer --broadcast
 *     # ...wait out TierRegistry.certifyDelay...
 *     forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --sig 'finalize()' --rpc-url robinhood --account sherwood-deployer --broadcast
 *
 *   Usage — Tenderly Robinhood fork (9994663), where the delay is skippable:
 *     forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --sig 'run()' --rpc-url robinhood_fork --unlocked --sender <factory owner> --broadcast --slow
 *     cast rpc evm_increaseTime 0x40000 --rpc-url robinhood_fork   # 3 days + slack
 *     cast rpc evm_mine --rpc-url robinhood_fork
 *     forge script script/DeployLighterTemplate.s.sol:DeployLighterTemplate \
 *       --sig 'finalize()' --rpc-url robinhood_fork --unlocked --sender <registry owner> --broadcast --slow
 *
 *   `--slow` IS MANDATORY UNDER `--unlocked`, NOT A POLITENESS. Without it forge
 *   pipelines the whole batch into `eth_sendTransaction` and the NODE assigns the
 *   nonces, so the CREATE does not necessarily land on the nonce the simulation
 *   assumed. Observed on vnet a3fb16 on 2026-08-22: the two owner calls took
 *   nonces 256/257 and the CREATE took 258, so `setTemplateApproval` approved the
 *   SIMULATED address — which holds no code — and both
 *   `proposeClassCertification` calls reverted `NotAContract()`. That failure mode
 *   is worse than a crash: the factory ends up carrying an approved codeless
 *   template, and `_patchAddressIfBook` writes the phantom address into
 *   `chains/{chainId}.json`. `script/deploy-robinhood-fork.sh` has always passed
 *   `--slow` for this reason; this runbook simply omitted it.
 *
 *   EVERY OWNER-GATED STEP DEGRADES TO A RUNBOOK LINE, NEVER TO A SILENT SKIP.
 *   `StrategyFactory` and `TierRegistry` are both handed to the parameter
 *   multisig during the core ceremony, so a deployer key running this on mainnet
 *   owns neither. That is the expected case, not the exceptional one: the script
 *   still deploys and still records the template, and prints the exact calls the
 *   Safe owes. What it must never do is complete quietly having done half of it.
 */
contract DeployLighterTemplate is ScriptBase {
    /// @dev Robinhood Chain MaxCodeSize is 98,304 bytes (4x EIP-170), matching
    ///      `DeployConcentratedLiquidityStrategy`. Asserted rather than assumed:
    ///      a template over the limit deploys to a codeless address on some
    ///      clients and reverts on others, and neither failure names itself.
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;

    /// @dev THE SAME TWO CHAINS `LighterPerpStrategy`'s constructor accepts, and
    ///      no others. The venue and asset addresses are `constant` in the
    ///      template, so on any other chain they point at whatever code happens
    ///      to live there. Note what is NOT here: 46630 (robinhood-testnet).
    ///      Lighter is not deployed on it — the template would revert
    ///      `UnsupportedChain` at construction, and if it somehow did not, it
    ///      would address an unrelated contract.
    uint256 internal constant CHAIN_ROBINHOOD = 4663;
    uint256 internal constant CHAIN_ROBINHOOD_FORK = 9994663;

    /// @dev Mirrors the template's own constants — asserted below rather than
    ///      trusted, because a wrong venue address is the one mistake this
    ///      ceremony cannot recover from.
    address internal constant ZK_LIGHTER = 0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint16 internal constant USDG_ASSET_INDEX = 3;

    /// @dev The two selectors the governor prices, named here only so the
    ///      verification reads below can print what they resolve to. NEITHER IS
    ///      CERTIFIED — see `SEL_ANCHOR`.
    bytes4 internal constant SEL_EXECUTE = IStrategy.execute.selector;
    bytes4 internal constant SEL_SETTLE = IStrategy.settle.selector;

    /// @dev THE ANCHOR SELECTOR, AND THE ONLY CERTIFIED ONE. `name()` is `pure`,
    ///      returns a string literal, and moves nothing — so certifying it at
    ///      tier 0 / bound 1 is a true statement rather than a convenient one.
    ///
    ///      It exists because the two class axes are not the same axis.
    ///      `setClassAllowed(template, true)` is what makes a per-proposal clone
    ///      a legal batch callee at all (`SyndicateVault._guardBatchCalls` PART
    ///      2a via `isCallableTarget`), and it reverts `ClassNotCertified`
    ///      unless a class ANCHOR exists — which only `certifyClass` writes, and
    ///      which is keyed on the clone codehash, NOT on the selector
    ///      (`TierRegistry:1303`). So certifying any ONE selector opens the
    ///      allowlist for the whole class while leaving every OTHER selector at
    ///      the uncertified default. That is exactly the combination this
    ///      template wants, and there is no other way to reach it: the class
    ///      path cannot express tier 2 or a 10_000 bound directly (see
    ///      `_classTier`).
    bytes4 internal constant SEL_ANCHOR = IStrategy.name.selector;

    /// @dev Tier and extractable bound FOR THE ANCHOR GRANT ONLY.
    ///
    ///      THE DECISION THIS ENCODES: `LighterPerpStrategy.execute()` moves the
    ///      whole declared cap into an off-chain perp venue whose sequencer this
    ///      protocol does not control and whose margin no on-chain reader can
    ///      price. There is no honest sub-10_000 extractable bound for that
    ///      call, and no honest claim that it is a bounded, reviewed money
    ///      movement in the tier-0/1 sense. It should be priced exactly like an
    ///      uncertified call: tier 2, full notional.
    ///
    ///      THE REGISTRY CANNOT BE ASKED FOR THAT DIRECTLY. Verified, not
    ///      assumed: `proposeClassCertification` reverts `InvalidTier` on
    ///      `tier >= TIER_ARBITRARY (2)` and `BoundRequired` on a bound of `0`
    ///      or `>= FULL_NOTIONAL_BPS (10_000)` (`TierRegistry:1245-1246`). Tier
    ///      2 / 10_000 is not a certification you can buy — it is what `tierOf`
    ///      RETURNS when no certification exists (`TierRegistry:358`). So the
    ///      correct encoding of "tier 2 / full notional" is to certify neither
    ///      `execute()` nor `settle()`, and to mint the anchor off `SEL_ANCHOR`.
    ///
    ///      GUARDIAN-COVERAGE CONSEQUENCE, stated plainly because it is the
    ///      point and not a side effect: `_scanCalls` sums
    ///      `cap_i * boundBps_i / 10_000` across BOTH legs, so a proposal's
    ///      `requiredCoverage` becomes `sum(execCaps) + sum(settleCaps)` at the
    ///      full 10_000 bound — for the canonical one-mover-per-leg shape,
    ///      `2 x maxCapital`. It was `9_999/10_000` of that under the old
    ///      default, so the delta is 0.01%; the substantive change is
    ///      `envelopeTier`, which is now 2 and can never be lowered by a
    ///      parameter change. Three things follow, all of them the safe
    ///      direction:
    ///        - the bond-encumbered approve quorum can never be escaped by an
    ///          owner raising `ExposureLedger.quorumTierThreshold` to 2. A
    ///          template that moves the whole cap off-chain must always have an
    ///          identified, stake-backed approver on the hook.
    ///        - the per-call tier-2 ceiling (`tier2CallCapBps`, default 10_000 =
    ///          inert) now binds this template if an owner ever tightens it.
    ///        - `executeProposal`'s `TierRegressed` / `CoverageRegressed` guards
    ///          become unreachable for this template: tier cannot rise above 2
    ///          and coverage cannot rise above the full bound, so a class
    ///          demotion landing between propose and execute can no longer brick
    ///          an in-flight proposal.
    ///
    ///      Still overridable, because it is a governance parameter — but note
    ///      that the override now moves the ANCHOR's grant, not `execute()`'s.
    ///      Certifying `execute()` itself is a deliberate act that this script
    ///      will not perform; the RUNBOOK lines print the call shape for an
    ///      operator who decides otherwise.
    function _classTier() internal view returns (uint8) {
        return uint8(vm.envOr("LIGHTER_CLASS_TIER", uint256(0)));
    }

    function _classBoundBps() internal view returns (uint16) {
        return uint16(vm.envOr("LIGHTER_CLASS_BOUND_BPS", uint256(1)));
    }

    // ── Phase 1 ──

    function run() external {
        _requireLighterChain();
        _assertVenue();

        address factory = _readAddress("STRATEGY_FACTORY");
        address registry = _optionalAddress("TIER_REGISTRY");

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Chain id:", block.chainid);

        LighterPerpStrategy template = new LighterPerpStrategy();

        // FACTORY-OWNER PRE-FLIGHT. `setTemplateApproval` is `onlyOwner`; calling
        // it from a non-owner aborts the whole broadcast AFTER the template has
        // been deployed, which loses the deploy and tells the operator nothing
        // about what to do next.
        if (StrategyFactory(factory).owner() == deployer) {
            StrategyFactory(factory).setTemplateApproval(address(template), true);
            console.log("approved on StrategyFactory:", factory);
        } else {
            console.log("RUNBOOK: deployer does not own STRATEGY_FACTORY - template NOT approved.");
            console.log(
                "RUNBOOK: the factory owner must call setTemplateApproval(<template>, true):", address(template)
            );
            console.log("RUNBOOK:   StrategyFactory:", factory);
        }

        _openTierCeremony(registry, deployer, address(template));

        vm.stopBroadcast();

        uint256 size = address(template).code.length;
        console.log("Template runtime size:", size);
        require(size <= ROBINHOOD_MAX_CODE_SIZE, "template exceeds Robinhood MaxCodeSize");

        _patchAddressIfBook("LIGHTER_PERP_TEMPLATE", address(template));
        console.log("LighterPerpStrategy template:", address(template));
        console.log("NEXT: wait out TierRegistry.certifyDelay, then run --sig 'finalize()'");
    }

    // ── Phase 2 (after `readyAt`) ──

    /// @notice Execute the pending ANCHOR certification and open the class axis.
    /// @dev    Split from `run()` because `certifyClass` reverts
    ///         `CertifyDelayNotElapsed` until `certifyDelay` has passed. On the
    ///         Tenderly fork that wait is `evm_increaseTime`; on 4663 it is three
    ///         real days, and the announcement window is exactly what the delay
    ///         exists to give guardians.
    ///
    ///         `certifyClass` is PERMISSIONLESS when `submitterBondWood == 0` and
    ///         submitter-only otherwise, so this half can be broadcast by a
    ///         keyholder who owns nothing — but `setClassAllowed` is `onlyOwner`
    ///         and degrades to a RUNBOOK line like every other owner step here.
    function finalize() external {
        _requireLighterChain();

        address registry = _readAddress("TIER_REGISTRY");
        address template = _readAddress("LIGHTER_PERP_TEMPLATE");

        vm.startBroadcast();
        address sender = msg.sender;

        TierRegistry(registry).certifyClass(template, SEL_ANCHOR);
        console.log("class ANCHOR certified on name():", template);

        if (TierRegistry(registry).owner() == sender) {
            TierRegistry(registry).setClassAllowed(template, true);
            console.log("class allowed on TierRegistry:", registry);
        } else {
            console.log("RUNBOOK: sender does not own TIER_REGISTRY - class axis NOT opened.");
            console.log("RUNBOOK: the registry owner must call setClassAllowed(<template>, true):", template);
        }
        vm.stopBroadcast();

        console.log("isClassAllowed:", TierRegistry(registry).isClassAllowed(template));
        // THE READ THAT PROVES THE DECISION. Both must print `2 10000` — the
        // uncertified full-notional default. Anything else means someone
        // certified the money-moving selectors and the template is being priced
        // as a bounded adapter, which it is not.
        (uint8 te, uint16 be) = TierRegistry(registry).classTierOf(template, SEL_EXECUTE);
        (uint8 ts, uint16 bs) = TierRegistry(registry).classTierOf(template, SEL_SETTLE);
        console.log("classTierOf(execute) tier / boundBps (expect 2 / 10000):", te, be);
        console.log("classTierOf(settle)  tier / boundBps (expect 2 / 10000):", ts, bs);
        require(te == 2 && be == 10_000 && ts == 2 && bs == 10_000, "execute()/settle() must stay UNCERTIFIED");
    }

    // ── Internals ──

    /// @dev A DEPLOY-TIME ASSERTION, NOT A RUNBOOK LINE, for the same reason
    ///      `DeployConcentratedLiquidityStrategy._assertFactoryIsVouchedFor` is
    ///      one: `LighterPerpStrategy._initialize` binds `ZK_LIGHTER` through
    ///      `vault() -> governor() -> tierRegistry() -> isCounterpartyAllowed`
    ///      and reverts `CounterpartyNotAllowed` otherwise. An unlisted venue
    ///      does not degrade the template, it makes it INERT — the ceremony
    ///      completes, agents write proposals, and every one reverts at
    ///      clone-init a governance cycle later.
    function _openTierCeremony(address registry, address deployer, address template) internal {
        if (registry == address(0)) {
            console.log("RUNBOOK: no TIER_REGISTRY in the address book - counterparty + class axes NOT opened.");
            console.log("RUNBOOK: the registry owner must call, in order:");
            console.log("RUNBOOK:   setCounterpartyAllowed(<ZK_LIGHTER>, true):", ZK_LIGHTER);
            console.log(
                "RUNBOOK:   proposeClassCertification(<template>, name(), 0, 1, submitter, codehash) - ANCHOR ONLY"
            );
            console.log("RUNBOOK:   do NOT certify execute()/settle(): they must stay tier-2 full-notional");
            console.log("RUNBOOK:   certifyClass(<template>, name()) + setClassAllowed(<template>, true):", template);
            return;
        }
        if (TierRegistry(registry).owner() != deployer) {
            console.log("RUNBOOK: deployer does not own TIER_REGISTRY - counterparty + class axes NOT opened.");
            console.log("RUNBOOK: the registry owner must call, in order:");
            console.log("RUNBOOK:   setCounterpartyAllowed(<ZK_LIGHTER>, true):", ZK_LIGHTER);
            console.log(
                "RUNBOOK:   proposeClassCertification(<template>, name(), 0, 1, submitter, codehash) - ANCHOR ONLY"
            );
            console.log("RUNBOOK:   do NOT certify execute()/settle(): they must stay tier-2 full-notional");
            console.log("RUNBOOK:   certifyClass(<template>, name()) + setClassAllowed(<template>, true):", template);
            return;
        }

        TierRegistry(registry).setCounterpartyAllowed(ZK_LIGHTER, true);
        console.log("ZK_LIGHTER counterparty-allowlisted on TierRegistry:", registry);

        // The submitter is only load-bearing when `submitterBondWood != 0`, in
        // which case `certifyClass` becomes submitter-only and pulls WOOD from
        // it. Naming the deployer either way is harmless and keeps the bonded
        // configuration workable without a second script.
        // THE ANCHOR SELECTOR ONLY. `execute()` and `settle()` are left
        // uncertified on purpose so `tierOf` resolves them to the tier-2 /
        // full-notional default — see `SEL_ANCHOR` and `_classTier`.
        uint8 tier = _classTier();
        uint16 boundBps = _classBoundBps();
        bytes32 codehash = template.codehash;
        TierRegistry(registry).proposeClassCertification(template, SEL_ANCHOR, tier, boundBps, deployer, codehash);
        console.log("class ANCHOR certification proposed on name(); tier / boundBps:", tier, boundBps);
        console.log("execute() + settle() left UNCERTIFIED - they price at tier 2 / 10000 bps");
        console.log("readyAt is now + TierRegistry.certifyDelay:", TierRegistry(registry).certifyDelay());
        if (TierRegistry(registry).submitterBondWood() != 0) {
            console.log("RUNBOOK: submitterBondWood is nonzero - the submitter must approve WOOD to the registry");
            console.log("RUNBOOK: before finalize(), and finalize() must be broadcast BY the submitter:", deployer);
        }
    }

    /// @dev `LighterPerpStrategy`'s constructor carries the same guard and would
    ///      revert `UnsupportedChain` anyway. Asserting here turns an undecodable
    ///      constructor revert mid-broadcast into a named failure before anything
    ///      is spent, and names the chain that actually gets attempted by mistake.
    function _requireLighterChain() internal view {
        require(
            block.chainid == CHAIN_ROBINHOOD || block.chainid == CHAIN_ROBINHOOD_FORK,
            "wrong chain: LighterPerpStrategy exists only on Robinhood mainnet 4663 and its 9994663 fork - 46630 (robinhood-testnet) has no Lighter deployment"
        );
    }

    /// @dev IDENTITY, NOT CODE PRESENCE — the lesson `addresses/4663.json`
    ///      records for the Uniswap addresses, which hold ~2110 bytes of an
    ///      unrelated contract on this chain. `tokenToAssetIndex(USDG) == 3` is
    ///      the cheapest read that only the real ZkLighter can answer correctly,
    ///      and it is exactly the constant `LighterPerpStrategy` hardcodes as
    ///      `USDG_ASSET_INDEX`: if the venue ever reindexes USDG, every deposit
    ///      and every withdraw this template makes would address the wrong asset.
    function _assertVenue() internal view {
        require(ZK_LIGHTER.code.length != 0, "ZK_LIGHTER holds no code on this chain");
        require(USDG.code.length != 0, "USDG holds no code on this chain");
        require(
            IZkLighter(ZK_LIGHTER).tokenToAssetIndex(USDG) == USDG_ASSET_INDEX,
            "ZK_LIGHTER does not index USDG at 3 - the template's USDG_ASSET_INDEX constant is wrong for this chain"
        );
        console.log("venue verified: tokenToAssetIndex(USDG) == 3 at", ZK_LIGHTER);
    }
}
