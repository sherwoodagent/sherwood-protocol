// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {ScriptBase} from "../ScriptBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IGuardianRegistry} from "../../src/interfaces/IGuardianRegistry.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {LighterPerpStrategy} from "../../src/strategies/LighterPerpStrategy.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {IZkLighter} from "../../src/lighter/IZkLighter.sol";

/**
 * @title  LighterForkBench
 * @notice The §5 lifecycle bench from `docs/lighter-fork-testing.md`, driven as
 *         a re-runnable broadcast script against the LIVE post-audit Sherwood
 *         stack on the Tenderly Robinhood fork (9994663) and the REAL ZkLighter.
 *
 *   WHY A SCRIPT AND NOT A `forge test --fork` SUITE. Every existing Robinhood
 *   fork suite (`RobinhoodMainnetIntegrationTest` and its children) deploys a
 *   FRESH Sherwood stack inside `setUp`. That is the right shape for testing the
 *   contracts and the wrong shape for this: what has to be proven here is that
 *   the template works against the governor, guardian registry, exposure ledger
 *   and tier registry that are ACTUALLY DEPLOYED on the fork, with their real
 *   parameters — the approve quorum, the proposer bond, the class certification.
 *   A fresh stack would prove none of that.
 *
 *   PHASES, BECAUSE THE CLOCK IS DRIVEN FROM OUTSIDE. `evm_increaseTime` is an
 *   RPC cheat, not a cheatcode, so the waits between voting, review and
 *   settlement cannot happen inside one broadcast. Each phase is its own
 *   `--sig`; `script/fork/lighter-bench.sh` is the driver that interleaves the
 *   `cast rpc` warps and the ERC-20 cheats.
 *
 *   STATE IS RE-DERIVED, NEVER PASSED. No phase takes an address argument and
 *   no phase writes a state file: the vault is found by its subdomain in
 *   `SyndicateFactory.getAllActiveSyndicates()`, the clone address is the
 *   deterministic `Clones.predictDeterministicAddress` of (template, vault,
 *   salt) from `StrategyFactory`, and the proposal is the governor's latest.
 *   So any phase can be re-run, or run days later, without the driver having
 *   carried anything between them.
 *
 *   --slow IS MANDATORY (see DeployLighterTemplate's header): under `--unlocked`
 *   the node assigns nonces, and a pipelined batch reorders.
 */
contract LighterForkBench is ScriptBase {
    // ── Venue ──
    IZkLighter constant ZKL = IZkLighter(0x94bAB9693Ba2f6358507eFfcbd372b0660AFfF9d);
    IERC20 constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    uint16 constant USDG_ASSET_INDEX = 3;

    /// @dev `pendingAssetBalances[assetIndex][accountIndex].balanceToWithdraw`.
    ///      Derived, not guessed: `script/fork/LighterSlotProbe.s.sol` records the
    ///      SLOADs of a real `getPendingBalance` against the forked venue and
    ///      `498` is the only base that reproduces them. See §2 of
    ///      docs/lighter-fork-testing.md.
    uint256 constant PENDING_BALANCES_BASE_SLOT = 498;

    /// @dev ZkLighter's priority-queue event. THE ONLY PROOF ON A FORK that a
    ///      guardrail actually reached the venue rather than no-oping: the
    ///      sequencer never answers here, so a call that enqueues nothing is
    ///      indistinguishable from one that succeeded, unless the enqueue itself
    ///      is asserted. Taken off a REAL receipt on vnet a3fb16 (the 2026-08-22
    ///      `guardrails` tx 0x7067470934749519d05e2262c93561bf02bfe4811424601748874383bda77300),
    ///      not derived from a signature - `IZkLighter` does not declare it.
    bytes32 constant NEW_PRIORITY_REQUEST = 0xefdd379e3e15772fcc7d2a67fa5bbb0790b932724153aded4648307094733b2f;

    // ── Bench actors. Impersonated; the admin RPC signs for anyone. ──
    address constant OWNER = 0x1111111111111111111111111111111111111111;
    address constant AGENT = 0x2222222222222222222222222222222222222222;
    address constant LP1 = 0x3333333333333333333333333333333333333333;
    address constant LP2 = 0x4444444444444444444444444444444444444444;
    address constant OUTSIDER = 0x5555555555555555555555555555555555555555;

    // ── Sizing. Bounded by what the fork's ONE live guardian can underwrite:
    //    `slashableBondUsd` is ~$6.5k, and required coverage is
    //    `execCap + settleCap` USDG priced ~1:1 (the FULL notional: `execute()`
    //    and `settle()` are deliberately uncertified, so they resolve to the
    //    tier-2 / 10_000-bps default — see DeployLighterTemplate). 2k + 2k
    //    leaves comfortable headroom; 40k (the 2026-07 run's figure) would be
    //    scaled down by `_deriveAndStoreEffectiveCapital` and the clone would
    //    deploy the scaled figure instead — which is a legal bench run, just not
    //    the one the phases below assert sizes against. Keep it coverable.
    uint256 constant LP_DEPOSIT = 5_000e6;
    uint256 constant DEFAULT_DEPLOY_AMOUNT = 2_000e6;
    uint256 constant STRATEGY_DURATION = 1 hours;
    uint256 constant OWNER_STAKE = 10_000e18;
    uint8 constant API_KEY_INDEX = 2;

    string constant SUBDOMAIN = "lighter-bench-1";

    // ── Resolved wiring ──
    SyndicateFactory factory;
    StrategyFactory strategyFactory;
    GuardianRegistry guardians;
    StakedWood swood;
    TierRegistry tiers;
    IERC20 wood;
    address template;
    address deployer;

    /// @notice USDG the clone deploys. Overridable, because the ceiling is not a
    ///         property of the template but of whatever approve coverage the
    ///         cohort can still raise — see `coveragePreflight`.
    function _deployAmount() internal view returns (uint256) {
        return vm.envOr("LIGHTER_BENCH_DEPLOY_AMOUNT", DEFAULT_DEPLOY_AMOUNT);
    }

    function _load() internal {
        require(block.chainid == 9994663, "LighterForkBench: fork 9994663 only");
        factory = SyndicateFactory(_readAddress("SYNDICATE_FACTORY"));
        strategyFactory = StrategyFactory(_readAddress("STRATEGY_FACTORY"));
        guardians = GuardianRegistry(_readAddress("GUARDIAN_REGISTRY"));
        swood = StakedWood(_readAddress("STAKED_WOOD"));
        tiers = TierRegistry(_readAddress("TIER_REGISTRY"));
        wood = IERC20(_readAddress("WOOD_TOKEN"));
        template = _readAddress("LIGHTER_PERP_TEMPLATE");
        deployer = _readAddress("DEPLOYER");
    }

    // ── Re-derivation (no state is passed between phases) ──

    function _vault() internal view returns (SyndicateVault) {
        SyndicateFactory.Syndicate[] memory all = factory.getAllActiveSyndicates();
        bytes32 want = keccak256(bytes(SUBDOMAIN));
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(all[i].subdomain)) == want) return SyndicateVault(payable(all[i].vault));
        }
        revert("bench vault not found - run setup() first");
    }

    function _gov() internal view returns (SyndicateGovernor) {
        return SyndicateGovernor(factory.governorOf(address(_vault())));
    }

    function _clone(uint256 salt) internal view returns (address) {
        return Clones.predictDeterministicAddress(
            template, keccak256(abi.encode(address(_vault()), bytes32(salt))), address(strategyFactory)
        );
    }

    function _pid() internal view returns (uint256) {
        return _gov().proposalCount();
    }

    // ================= PHASE 1: fund =================

    /// @notice Create the bench syndicate, seat the agent, and deposit both LPs.
    /// @dev    Idempotent: returns early when the subdomain is already taken, so
    ///         the driver can re-run the whole ceremony.
    function setup() external {
        _load();
        SyndicateFactory.Syndicate[] memory all = factory.getAllActiveSyndicates();
        bytes32 want = keccak256(bytes(SUBDOMAIN));
        for (uint256 i; i < all.length; i++) {
            if (keccak256(bytes(all[i].subdomain)) == want) {
                console.log("BENCH_VAULT=%s (already created)", all[i].vault);
                // RE-SEAT, because the §6 liveness leg DE-REGISTERS the agent and
                // that is the whole point of it. Without this the bench is
                // single-shot: the next `cloneAndPropose` reverts `NotAgent` at
                // the governor a phase later, with nothing naming the cause.
                // `removeAgent` full-deletes the struct, so re-registering the
                // same id is legal rather than an `AgentAlreadyRegistered`.
                SyndicateVault existing = SyndicateVault(payable(all[i].vault));
                if (!existing.isAgent(AGENT)) {
                    vm.broadcast(OWNER);
                    existing.registerAgent(9002, AGENT);
                    console.log("re-seated the bench agent after a liveness run:", AGENT);
                }
                return;
            }
        }

        vm.startBroadcast(OWNER);
        wood.approve(address(swood), OWNER_STAKE);
        swood.prepareOwnerStake(OWNER_STAKE);
        (, address vaultAddr) = factory.createSyndicate(
            9001,
            SyndicateFactory.SyndicateConfig({
                metadataURI: "ipfs://lighter-fork-bench",
                asset: USDG,
                name: "Lighter Fork Bench",
                symbol: "lfbUSDG",
                openDeposits: true,
                subdomain: SUBDOMAIN
            })
        );
        SyndicateVault v = SyndicateVault(payable(vaultAddr));
        v.registerAgent(9002, AGENT);
        vm.stopBroadcast();

        vm.startBroadcast(LP1);
        USDG.approve(vaultAddr, LP_DEPOSIT);
        v.deposit(LP_DEPOSIT, LP1);
        vm.stopBroadcast();

        vm.startBroadcast(LP2);
        USDG.approve(vaultAddr, LP_DEPOSIT);
        v.deposit(LP_DEPOSIT, LP2);
        vm.stopBroadcast();

        console.log("BENCH_VAULT=%s", vaultAddr);
        console.log("BENCH_GOVERNOR=%s", factory.governorOf(vaultAddr));
        console.log("totalAssets:", v.totalAssets());
    }

    // ================= PHASE 2: clone + propose + LP vote =================

    function cloneAndPropose(uint256 salt) external {
        _load();
        SyndicateVault v = _vault();
        SyndicateGovernor gov = _gov();

        vm.startBroadcast(AGENT);
        address clone = strategyFactory.cloneAndInitDeterministic(
            template,
            address(v),
            AGENT,
            abi.encode(_pubKey(), API_KEY_INDEX, _marketList(), _deployAmount()),
            bytes32(salt)
        );
        vm.stopBroadcast();
        require(clone == _clone(salt), "clone address prediction diverged");
        console.log("BENCH_CLONE=%s", clone);

        // THE CLASS PATH IS THE WHOLE POINT OF STEP 1. A clone gets BOTH the
        // callee axis (`isCallableTarget`, PART 2a of `_guardBatchCalls`) and
        // the approve-spender axis (`isAdapterAllowed`, PART 2b) from
        // `setClassAllowed(template, true)` alone — no per-clone owner call.
        require(tiers.isCallableTarget(clone), "clone not callable via the class path");
        require(tiers.isAdapterAllowed(clone), "clone not an allowed spender via the class path");
        // ...while `execute()` itself stays UNCERTIFIED, which is the deploy
        // ceremony's deliberate choice: the class anchor is minted off the inert
        // `name()` selector so the allowlist opens without pricing the
        // money-moving selectors as bounded. Expect `2 / 10000`.
        (uint8 t, uint16 b) = tiers.classTierOf(template, IStrategy.execute.selector);
        console.log("classTierOf(execute) tier / boundBps (expect 2 / 10000):", t, b);
        require(t == 2 && b == 10_000, "execute() is class-certified - re-run DeployLighterTemplate's ceremony");

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(USDG), data: abi.encodeCall(IERC20.approve, (clone, _deployAmount())), value: 0
        });
        execCalls[1] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("execute()"), value: 0});
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = _deployAmount(); // the MOVER is the last call

        BatchExecutorLib.Call[] memory settleCalls = new BatchExecutorLib.Call[](1);
        settleCalls[0] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("settle()"), value: 0});
        uint256[] memory settleCaps = new uint256[](1);
        settleCaps[0] = _deployAmount();

        uint256 maxCapital = IERC4626(address(v)).totalAssets();
        uint256 bond = _bondFor(gov, address(v), execCaps, settleCaps);
        console.log("proposer bond (WOOD):", bond);

        vm.startBroadcast(AGENT);
        if (bond != 0) wood.approve(gov.bondEscrow(), bond);
        uint256 pid = gov.propose(
            address(v),
            clone,
            "ipfs://lighter-fork-bench",
            STRATEGY_DURATION,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            settleCalls,
            settleCaps,
            new ISyndicateGovernor.CoProposer[](0)
        );
        vm.stopBroadcast();
        console.log("BENCH_PID=%s", pid);

        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
        console.log("envelopeTier / requiredCoverage:", p.envelopeTier, p.requiredCoverage);
        console.log("voteEnd / reviewEnd:", p.voteEnd, p.reviewEnd);
    }

    /// @notice The LP vote, as its OWN phase.
    /// @dev    NOT foldable into `cloneAndPropose`. `vote` weighs
    ///         `IVotes(vault).getPastVotes(voter, p.snapshotTimestamp)` and the
    ///         snapshot is stamped at `block.timestamp` inside `propose`, so a
    ///         vote at the same timestamp reads a checkpoint that is not yet
    ///         PAST and weighs zero — `NoVotingPower()`. Forge simulates every
    ///         call in one script at a single timestamp, so the two must be
    ///         separated by an `evm_increaseTime` the driver performs. The
    ///         fork-test harness hides this behind a `vm.warp(+1)`; a broadcast
    ///         script has no such lever.
    function lpVote() external {
        _load();
        SyndicateGovernor gov = _gov();
        uint256 pid = _pid();
        ISyndicateGovernor.StrategyProposal memory p = gov.getProposal(pid);
        require(block.timestamp > p.snapshotTimestamp, "snapshot not yet in the past - warp first");

        vm.broadcast(LP1);
        gov.vote(pid, ISyndicateGovernor.VoteType.For);
        vm.broadcast(LP2);
        gov.vote(pid, ISyndicateGovernor.VoteType.For);
        p = gov.getProposal(pid);
        console.log("votesFor / votesAgainst:", p.votesFor, p.votesAgainst);
    }

    /// @dev The bond the ledger will demand, computed the way `_snapshotTierAndGate`
    ///      does, so the driver can approve exactly it before `propose` pulls.
    function _bondFor(SyndicateGovernor gov, address v, uint256[] memory execCaps, uint256[] memory settleCaps)
        internal
        view
        returns (uint256)
    {
        address ledger = gov.exposureLedger();
        if (ledger == address(0)) return 0;
        // FULL NOTIONAL on both legs: neither `execute()` nor `settle()` is
        // class-certified, so `tierOf` returns the `(2, 10_000)` default and
        // `_scanCalls` sums the caps verbatim.
        uint256 coverage;
        for (uint256 i; i < execCaps.length; i++) {
            coverage += execCaps[i];
        }
        for (uint256 i; i < settleCaps.length; i++) {
            coverage += settleCaps[i];
        }
        (bool ok, bytes memory ret) = ledger.staticcall(
            abi.encodeWithSignature("proposerBondWood(address,uint256)", IERC4626(v).asset(), coverage)
        );
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    // ================= PHASE 3: open review + guardian approve =================

    /// @notice Open the guardian review and cast the approve vote that the
    ///         execute-time quorum reads.
    /// @dev    `quorumTierThreshold == 0` on this fork, so the bond-encumbered
    ///         approve quorum is MANDATORY at every tier — with no approver
    ///         `executeProposal` reverts `InsufficientApproveCoverage`. The
    ///         guardian is whichever address the driver passes; on vnet a3fb16
    ///         exactly one has live stake.
    function openReviewAndApprove(address guardian) external {
        _load();
        SyndicateGovernor gov = _gov();
        uint256 pid = _pid();

        vm.broadcast(OUTSIDER); // permissionless
        guardians.openReview(address(gov), pid);

        require(swood.isActiveGuardian(guardian), "guardian has no live stake");
        vm.broadcast(guardian);
        guardians.voteOnProposal(address(gov), pid, IGuardianRegistry.GuardianVoteType.Approve);
        console.log("guardian approved:", guardian);
    }

    // ================= PHASE 4: resolve + execute =================

    function executeStep(uint256 salt) external {
        _load();
        SyndicateVault v = _vault();
        SyndicateGovernor gov = _gov();
        uint256 pid = _pid();
        address clone = _clone(salt);

        uint256 vaultBefore = USDG.balanceOf(address(v));

        vm.broadcast(OUTSIDER);
        guardians.resolveReview(address(gov), pid);
        require(guardians.outcomeOf(address(gov), pid) != IGuardianRegistry.ReviewOutcome.Blocked, "review blocked");

        vm.broadcast(OUTSIDER);
        gov.executeProposal(pid);

        uint48 acct = LighterPerpStrategy(clone).accountIndex();
        console.log("BENCH_ACCOUNT_INDEX=%s", uint256(acct));
        require(acct != 0, "ZkLighter did not register the account");
        uint256 spent = vaultBefore - USDG.balanceOf(address(v));
        uint256 deployed = LighterPerpStrategy(clone).deployedAmount();
        console.log("vault USDG delta (pulled) / clone deployedAmount:", spent, deployed);
        // THE CLONE'S OWN FIGURE IS THE ORACLE, not the declaration. Under a
        // short approve quorum the governor scales the proposal and `_execute`
        // deploys `depositAmount * effectiveMaxCapital / maxCapital`; the run is
        // still valid, it just deployed less. What must hold is that the vault
        // lost exactly what the clone says it took, and never more than declared.
        require(spent == deployed, "vault outflow != clone deployedAmount");
        require(deployed <= _deployAmount(), "clone deployed more than declared");

        // THE SCALING LAW ITSELF, ASSERTED RATHER THAN NARRATED, and it is the
        // same statement in both regimes: `_coverageScaledDeposit` returns
        // `mulDiv(depositAmount, effectiveMaxCapital, maxCapital)`, which
        // degenerates to `depositAmount` exactly when the proposal was fully
        // covered (`effective == declared`). One `require` therefore covers the
        // fully-covered leg AND the scaled one, and a template that ever went
        // back to pulling the pinned declaration into a scaled batch would fail
        // it here rather than reverting `CallCapExceeded` and looking like a
        // coverage problem.
        (uint256 declared, uint256 effective) = _envelope(gov, pid);
        uint256 want = declared == 0 || effective >= declared
            ? _deployAmount()
            : Math.mulDiv(_deployAmount(), effective, declared);
        console.log("maxCapital / effectiveMaxCapital:", declared, effective);
        console.log("expected deployedAmount (declared x effective / max):", want);
        require(deployed == want, "deployedAmount != depositAmount x effective / maxCapital");
        if (deployed != _deployAmount()) {
            console.log("NOTE: under-covered proposal - scaled down from:", _deployAmount());
            require(!_expectFullCoverage(), "LIGHTER_BENCH_EXPECT_FULL=1 but the proposal was SCALED DOWN");
        } else {
            console.log("FULLY COVERED: deployedAmount == depositAmount");
        }
        require(USDG.balanceOf(clone) == 0, "clone did not forward the deposit to the venue");
        require(v.redemptionsLocked(), "vault not locked while deployed");
        // Surplus float untouched: 10k deposited, 2k deployed.
        console.log("vault float left:", USDG.balanceOf(address(v)));
        _probes(clone, "after execute");
    }

    // ================= PHASE 5: guardrails =================

    function guardrails(uint256 salt) external {
        _load();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));

        vm.broadcast(AGENT);
        s.registerAgentKey();
        console.log("registerAgentKey (proposer) ok");

        vm.broadcast(OWNER);
        s.registerAgentKey();
        console.log("registerAgentKey (vault owner) ok - the second key works too");

        vm.broadcast(AGENT);
        s.updateParams(abi.encode(uint8(1), bytes("")));
        console.log("updateParams CANCEL_ALL ok");

        vm.broadcast(AGENT);
        s.updateParams(abi.encode(uint8(2), abi.encode(uint16(1), uint32(1), uint8(1))));
        console.log("updateParams CLOSE_MARKET ok");

        vm.broadcast(AGENT);
        s.updateParams(abi.encode(uint8(3), abi.encode(_pubKey2())));
        console.log("updateParams ROTATE_KEY ok");

        vm.broadcast(OWNER);
        s.guardrailAction(abi.encode(uint8(1), bytes("")));
        console.log("guardrailAction CANCEL_ALL from the vault OWNER ok");

        // Retired action 4 must be a named refusal, not a silent no-op.
        vm.prank(AGENT);
        (bool ok4,) = address(s).call(abi.encodeWithSignature("updateParams(bytes)", abi.encode(uint8(4), bytes(""))));
        require(!ok4, "retired WITHDRAW action 4 still dispatches");
        console.log("updateParams action 4 (retired WITHDRAW) reverts as expected");

        vm.prank(OUTSIDER);
        (bool okO,) =
            address(s).call(abi.encodeWithSignature("guardrailAction(bytes)", abi.encode(uint8(1), bytes(""))));
        require(!okO, "a non-proposer non-owner drove a guardrail");
        console.log("guardrailAction from an outsider reverts as expected");
    }

    // ================= PHASE 6: unwind =================

    /// @param ticks the drain to queue. Pass the clone's `deployedAmount()` for
    ///        the clean path (NOT `LIGHTER_BENCH_DEPLOY_AMOUNT` — an
    ///        under-covered proposal deployed less, and asking for the
    ///        declaration reverts venue-side on a balance never there), or 1 for
    ///        the C1 under-withdraw regression.
    function unwind(uint256 salt, uint64 ticks) external {
        _load();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));

        vm.broadcast(AGENT);
        s.initiateReturn();
        console.log("initiateReturn ok; returnsInitiatedAt:", s.returnsInitiatedAt());
        require(s.queuedTicks() == 0, "initiateReturn queued a withdrawal - C1 split broken");

        vm.prank(OUTSIDER);
        (bool okO,) = address(s).call(abi.encodeWithSignature("queueWithdraw(uint64)", ticks));
        require(!okO, "an outsider queued a withdrawal");
        console.log("queueWithdraw from an outsider reverts as expected");

        vm.broadcast(AGENT);
        s.queueWithdraw(ticks);
        console.log("queueWithdraw ok; queuedTicks:", s.queuedTicks());
        _probes(address(s), "after queueWithdraw");
    }

    // ================= PHASE 6b: §6 LIVENESS =================

    /// @notice §6 of docs/lighter-fork-testing.md: `removeAgent(proposer)` must
    ///         REVOKE without STRANDING.
    /// @dev    THE TWO HALVES ARE ONE CLAIM, and testing either alone proves the
    ///         wrong thing. Before the `guardrailAction` / `_isLiveProposer`
    ///         work, revocation was simultaneously TOO WEAK and TOO STRONG: the
    ///         hand-rolled `msg.sender == proposer()` in `queueWithdraw` /
    ///         `initiateReturn` / `acknowledgeShortfall` skipped the live
    ///         agent-set re-check, so a de-registered agent kept the privileged
    ///         branch; and every guardrail hung off `updateParams`, which is
    ///         `onlyProposer`, so removing the agent also removed the only key
    ///         that could cancel its resting orders. Revoking made the position
    ///         LESS controllable AND left the agent in charge of the drain.
    ///
    ///         So this leg asserts both directions on one clone, in one tx
    ///         sequence, against the real venue:
    ///           - the proposer loses `updateParams`, `guardrailAction`,
    ///             `registerAgentKey`, `queueWithdraw` and the PRIVILEGED branch
    ///             of `initiateReturn` — with the exact named errors, not just
    ///             "it reverted";
    ///           - the owner keeps every one of them, and each venue-touching
    ///             call is proven by the venue's OWN `NewPriorityRequest` rather
    ///             than by the call not reverting. On a fork a no-op and a
    ///             success look identical from the return value alone.
    ///
    ///         `initiateReturn` from the de-registered proposer resolves to
    ///         `NotAuthorized` rather than `ProposerNoLongerAgent` and that is
    ///         the design: it does not have a proposer modifier, it FALLS THROUGH
    ///         to the permissionless branch, where the timing gate
    ///         (`executedAt + strategyDuration`) has not elapsed yet. The
    ///         demotion is exactly "as much authority as anyone else, and no
    ///         more".
    ///
    ///         Leaves the agent REMOVED. `setup()` re-seats it on the next run.
    /// @param  ticks the drain the owner queues — the clone's `deployedAmount()`.
    function liveness(uint256 salt, uint64 ticks) external {
        _load();
        SyndicateVault v = _vault();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));
        require(uint8(s.state()) == 1, "clone is not Executed - liveness is the post-execute leg");
        require(s.returnsInitiatedAt() == 0, "unwind already started - the liveness leg must own the whole unwind");
        require(v.isAgent(AGENT), "bench agent is not seated - re-run setup()");
        require(v.owner() == OWNER, "bench OWNER does not own the vault");

        // ── The revocation ──
        vm.broadcast(OWNER);
        v.removeAgent(AGENT);
        require(!v.isAgent(AGENT), "removeAgent did not clear the live agent set");
        console.log("removeAgent(proposer) ok - vault.isAgent(proposer) is now false");

        // ── It BITES: every proposer-gated door is shut ──
        console.log("--- the de-registered proposer ---");
        _mustRevert(
            address(s),
            AGENT,
            abi.encodeWithSignature("updateParams(bytes)", abi.encode(uint8(1), bytes(""))),
            BaseStrategy.ProposerNoLongerAgent.selector,
            "updateParams(CANCEL_ALL)"
        );
        _mustRevert(
            address(s),
            AGENT,
            abi.encodeWithSignature("guardrailAction(bytes)", abi.encode(uint8(1), bytes(""))),
            LighterPerpStrategy.NotAuthorized.selector,
            "guardrailAction(CANCEL_ALL)"
        );
        _mustRevert(
            address(s),
            AGENT,
            abi.encodeWithSignature("registerAgentKey()"),
            LighterPerpStrategy.NotAuthorized.selector,
            "registerAgentKey"
        );
        _mustRevert(
            address(s),
            AGENT,
            abi.encodeWithSignature("queueWithdraw(uint64)", ticks),
            LighterPerpStrategy.NotAuthorized.selector,
            "queueWithdraw"
        );
        _mustRevert(
            address(s),
            AGENT,
            abi.encodeWithSignature("initiateReturn()"),
            LighterPerpStrategy.NotAuthorized.selector,
            "initiateReturn (falls through to the permissionless branch)"
        );

        // ── ...and the OWNER still holds every one of them ──
        console.log("--- the vault owner ---");
        uint256 markets = _marketList().length;

        vm.recordLogs();
        vm.broadcast(OWNER);
        s.guardrailAction(abi.encode(uint8(1), bytes("")));
        _requirePriorityRequests(1, "owner guardrailAction(CANCEL_ALL)");

        vm.recordLogs();
        vm.broadcast(OWNER);
        s.registerAgentKey();
        _requirePriorityRequests(1, "owner registerAgentKey");

        // One cancel-all + a both-side market close per configured market.
        vm.recordLogs();
        vm.broadcast(OWNER);
        s.initiateReturn();
        _requirePriorityRequests(1 + 2 * markets, "owner initiateReturn");
        require(s.returnsInitiatedAt() != 0, "initiateReturn did not stamp returnsInitiatedAt");
        require(s.queuedTicks() == 0, "initiateReturn queued a withdrawal - C1 split broken");
        console.log("returnsInitiatedAt:", s.returnsInitiatedAt());

        vm.recordLogs();
        vm.broadcast(OWNER);
        s.queueWithdraw(ticks);
        _requirePriorityRequests(1, "owner queueWithdraw");
        console.log("queuedTicks:", s.queuedTicks());

        _probes(address(s), "after the owner-driven unwind");
        console.log("BENCH_LIVENESS=ok - the agent is REMOVED; setup() re-seats it");
    }

    /// @notice Re-seat the bench agent by hand (setup() also does it).
    function reseatAgent() external {
        _load();
        SyndicateVault v = _vault();
        if (v.isAgent(AGENT)) {
            console.log("agent already seated:", AGENT);
            return;
        }
        vm.broadcast(OWNER);
        v.registerAgent(9002, AGENT);
        console.log("re-seated:", AGENT, v.isAgent(AGENT));
    }

    // ================= PHASE 7: settle =================

    /// @notice Post-settle assertions. The `settleProposal` CALL ITSELF is not
    ///         here — see the driver.
    /// @dev    NEITHER SETTLE NOR ITS PRE-MATURITY REFUSAL CAN BE DRIVEN FROM A
    ///         FORGE SCRIPT ON THIS VNET, and the reason is worth stating because
    ///         it is not a bug in either tool. `LighterPerpStrategy._settle`
    ///         guards on `block.number <= returnsInitiatedAt`, and this vnet
    ///         reports TWO different block numbers: `evm_increaseTime` advances
    ///         the number contracts see via the NUMBER opcode (measured
    ///         2026-08-22: 25,813,800 stamped into `returnsInitiatedAt` by a real
    ///         tx) while `eth_blockNumber` still returned 21,178,087. Forge forks
    ///         at `eth_blockNumber`, so its simulation runs ~4.6M blocks in the
    ///         PAST and every settle simulates as `SettleTooSoon()` no matter how
    ///         long the drain has actually been down. `cast send` / `cast call`
    ///         execute in the NODE's context and see the real figure, so the
    ///         driver uses those for both — and `cast call` is what proves the
    ///         `WithdrawalInFlight` refusal, on the node, with the real numbers.
    function assertSettled(uint256 salt) external {
        _load();
        SyndicateVault v = _vault();
        SyndicateGovernor gov = _gov();
        uint256 pid = _pid();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));

        require(s.settled(), "strategy did not settle");
        require(uint8(gov.getProposal(pid).state) == uint8(ISyndicateGovernor.ProposalState.Settled), "not Settled");
        console.log("proposal state: Settled");
        require(!v.redemptionsLocked(), "vault still locked after settlement");
        require(USDG.balanceOf(address(s)) == 0, "clone still holds USDG after settle");
        console.log("returnedAssets / queuedTicks:", s.returnedAssets(), s.queuedTicks());
        console.log("vault USDG / totalAssets:", USDG.balanceOf(address(v)), v.totalAssets());
        _probes(address(s), "after settle");
    }

    // ================= PHASE 8: residue =================

    /// @notice The post-audit residue surface: `sweep()` is `onlyVault`,
    ///         `recoverResiduals()` is claim-only, and the vault's
    ///         `collectResidue` is the single door the cohort split measures.
    function residue(uint256 salt) external {
        _load();
        SyndicateVault v = _vault();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));

        vm.prank(OUTSIDER);
        (bool okS,) = address(s).call(abi.encodeWithSignature("sweep()"));
        require(!okS, "a non-vault caller drove sweep()");
        console.log("direct sweep() from a non-vault caller reverts (NotVault) as expected");

        uint256 cloneBefore = USDG.balanceOf(address(s));
        vm.broadcast(OUTSIDER); // recoverResiduals is permissionless
        s.recoverResiduals();
        console.log("recoverResiduals claimed onto the clone (delta):", USDG.balanceOf(address(s)) - cloneBefore);
        require(USDG.balanceOf(address(v)) >= 0, "");

        uint256 vaultBefore = USDG.balanceOf(address(v));
        uint256 held = USDG.balanceOf(address(s));
        vm.broadcast(OUTSIDER); // collectResidue is permissionless
        uint256 collected = v.collectResidue(address(s));
        console.log("collectResidue moved:", collected);
        require(USDG.balanceOf(address(v)) - vaultBefore == held, "collectResidue did not drain the clone");
        require(USDG.balanceOf(address(s)) == 0, "clone still holds USDG after collectResidue");
        _probes(address(s), "after collectResidue");
        console.log("vault.depositsLocked():", v.depositsLocked());
    }

    /// @notice C1: queue the REST after the proposal is already Settled.
    function queueRest(uint256 salt, uint64 ticks) external {
        _load();
        LighterPerpStrategy s = LighterPerpStrategy(_clone(salt));
        require(uint8(s.state()) == 2, "clone is not Settled - this is the post-settle path");
        // WHICHEVER KEY IS STILL LIVE. After the §6 leg the proposer is no longer
        // an agent and `_requireProposerOrOwner` refuses it; the owner is the
        // holder the liveness fix exists to preserve, so use it rather than
        // failing a residue assertion for an auth reason that is the point.
        address caller = _vault().isAgent(AGENT) ? AGENT : OWNER;
        vm.broadcast(caller);
        s.queueWithdraw(ticks);
        console.log("post-Settled queueWithdraw ok; queuedTicks:", s.queuedTicks());
        _probes(address(s), "after post-settle queueWithdraw");
    }

    /// @notice Sweep the guardian's DEAD approvals off the shared-stake
    ///         denominator, so the next approve allocates its full reservation.
    /// @dev    THE SECOND HALF OF "THE RESERVATION CLEARS", AND THE HALF THAT IS
    ///         NOT AUTOMATIC. Two different ledger counters carry a guardian's
    ///         approval and only ONE of them decays on the clock:
    ///           - `_buckets` / `openExposureUsd` — the BUDGET. Bucket `e` stops
    ///             counting at `genesis + (e+1)*L + W`, so warping past that
    ///             frees the guardian to reserve again, and `recordApproval` will
    ///             happily book the full `requiredCoverage`.
    ///           - `_livePledgedUsd` — the DENOMINATOR `_sharedSlashableUsd`
    ///             divides the bond by. It has no clock at all: `releaseApproval`
    ///             is gated on `block.timestamp < reviewEnd`, so once a review
    ///             closes nothing decrements it except the permissionless
    ///             `retireApproval`.
    ///
    ///         So a guardian whose old bookings have expired still reports a full
    ///         reservation and STILL allocates only `bond * reserved /
    ///         livePledged`. Measured on vnet a3fb16 on 2026-08-22, one guardian,
    ///         two dead approvals worth $6,520.56 of pledge: the next proposal
    ///         reserved the whole $3,999.67 it needed, `openExposureUsd` agreed,
    ///         and `allocatedUsd` came out at $2,479.04 — 62% — so a proposal
    ///         nothing was competing for still deployed 1,239,622,687 of a
    ///         declared 2,000,000,000. The bench read that as an under-covered
    ///         run because on the budget axis it was not one.
    ///
    ///         `retireApproval` is permissionless and refuses exactly the cases
    ///         it must (`CoverageFrozen`, `CoveragePinnedActive`, bucket not yet
    ///         expired), so the sweepable set is discovered by PROBING inside a
    ///         state snapshot and only then broadcast — a revert inside
    ///         `vm.broadcast` would take the whole script down for a pid that was
    ///         merely still live.
    ///
    ///         SCOPE: this governor only. A guardian that approved on some OTHER
    ///         vault carries that pledge too, and only that vault's governor can
    ///         name it.
    function retireStale(address guardian) external {
        _load();
        SyndicateGovernor gov = _gov();
        address ledger = gov.exposureLedger();
        require(ledger != address(0), "no exposure ledger on this governor");
        uint256 last = gov.proposalCount();

        uint256[] memory hits = new uint256[](last + 1);
        uint256 n;
        uint256 snap = vm.snapshotState();
        for (uint256 pid = 1; pid <= last; pid++) {
            if (_allocatedUsd(ledger, address(gov), pid, guardian) == 0) continue;
            vm.prank(OUTSIDER);
            (bool ok,) = ledger.call(_retireCall(address(gov), pid, guardian));
            if (ok) {
                hits[n++] = pid;
            } else {
                console.log("  pid NOT sweepable yet (frozen, pinned, or bucket unexpired):", pid);
            }
        }
        vm.revertToState(snap);

        for (uint256 i; i < n; i++) {
            vm.broadcast(OUTSIDER); // retireApproval is permissionless
            (bool ok,) = ledger.call(_retireCall(address(gov), hits[i], guardian));
            require(ok, "retireApproval reverted on broadcast");
            console.log("  retired dead approval on pid:", hits[i]);
        }
        console.log("BENCH_RETIRED=%s", n);
        console.log("openExposureUsd after sweep:", _openExposureUsd(ledger, guardian));
    }

    function _retireCall(address gov_, uint256 pid, address guardian) private pure returns (bytes memory) {
        return abi.encodeWithSignature("retireApproval(address,uint256,address)", gov_, pid, guardian);
    }

    function _allocatedUsd(address ledger, address gov_, uint256 pid, address guardian)
        private
        view
        returns (uint256)
    {
        (bool ok, bytes memory ret) = ledger.staticcall(
            abi.encodeWithSignature("allocatedUsd(address,uint256,address)", gov_, pid, guardian)
        );
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    function _openExposureUsd(address ledger, address guardian) private view returns (uint256) {
        (bool ok, bytes memory ret) =
            ledger.staticcall(abi.encodeWithSignature("openExposureUsd(address)", guardian));
        if (!ok || ret.length < 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @notice SIZE BEFORE THE VOTE, BECAUSE THE EXECUTE BATCH NO LONGER
    ///         REFUSES. The approve quorum does not fail closed when it is short
    ///         — it returns the coverage actually raised, and
    ///         `_deriveAndStoreEffectiveCapital` SCALES the proposal's per-call
    ///         caps by `raised / required`. `LighterPerpStrategy._execute` now
    ///         scales its pull by the same ratio, so an under-covered Lighter
    ///         proposal DEPLOYS LESS rather than reverting `CallCapExceeded` —
    ///         which is the graceful degrade every other template already had,
    ///         and which is why this check is now about getting the size you
    ///         asked for rather than about executing at all.
    ///
    ///         Observed on vnet a3fb16 on 2026-08-22, back to back on one
    ///         guardian: the first 2,000-USDG proposal booked $3,999.27 of a
    ///         $6,520.56 bond, and the second raised only the $2,521.29
    ///         remainder — 63% — so its cap scaled to 1,260,872,310. Pre-fix the
    ///         unscaled 2,000,000,000 pull broke the batch; post-fix that
    ///         proposal deploys 1,260,872,310 and runs. A reservation is released
    ///         by a vote change or by the epoch bucket expiring, NOT by the
    ///         earlier proposal settling, so "the last one is finished" is not
    ///         the question to ask. This is.
    /// @param guardian the address that will cast the approve vote.
    function coveragePreflight(address guardian) external {
        _load();
        address ledger = _gov().exposureLedger();
        uint256 want = _deployAmount();
        // Both legs at the UNCERTIFIED full-notional bound, exactly as
        // `_resolveTierAndCoverage` sums them.
        uint256 coverage = want * 2;
        (, bytes memory needRet) =
            ledger.staticcall(abi.encodeWithSignature("coverageUsd(address,uint256)", address(USDG), coverage));
        uint256 needUsd = abi.decode(needRet, (uint256));
        (, bytes memory haveRet) = ledger.staticcall(abi.encodeWithSignature("slashableBondUsd(address)", guardian));
        uint256 bondUsd = abi.decode(haveRet, (uint256));
        console.log("deployAmount / requiredCoverageUsd:", want, needUsd);
        console.log("guardian slashableBondUsd (GROSS, before existing bookings):", bondUsd);
        require(bondUsd >= needUsd, "guardian bond cannot cover this deployAmount even unbooked");

        // BOTH AXES, BECAUSE THE BUDGET ONE ALONE LIES. `openExposureUsd` is the
        // clock-decaying BUDGET; a guardian can read zero here and still allocate
        // a fraction of what it reserves, because `_livePledgedUsd` — the
        // denominator the bond is shared across — has no clock. See
        // `retireStale`, which is the only thing that clears it.
        uint256 booked = _openExposureUsd(ledger, guardian);
        console.log("guardian openExposureUsd (the BUDGET already booked):", booked);
        if (bondUsd < booked + needUsd) {
            console.log("WARNING: the budget axis is short - this proposal will be SCALED DOWN.");
        }
        console.log("preflight ok on the GROSS bond. Two things can still scale it:");
        console.log("  1. a live booking of this guardian (the figure above);");
        console.log("  2. a DEAD approval still on _livePledgedUsd - run retireStale(guardian).");
        console.log("executeStep prints the gap either way; the clone's deployedAmount is the oracle.");
    }

    // ================= helpers =================

    /// @dev The proposal's declared and post-quorum envelope, read the way
    ///      `LighterPerpStrategy._coverageScaledDeposit` reads them so the bench
    ///      asserts the template's own inputs rather than a re-derivation.
    function _envelope(SyndicateGovernor gov, uint256 pid) internal view returns (uint256, uint256) {
        (uint256 declared,) = gov.getRiskEnvelope(pid);
        return (declared, gov.getEffectiveMaxCapital(pid));
    }

    /// @notice Set `LIGHTER_BENCH_EXPECT_FULL=1` to make a scaled-down execute a
    ///         FAILURE rather than a note. The fully-covered leg wants that; the
    ///         deliberate under-coverage leg does not.
    function _expectFullCoverage() internal view returns (bool) {
        return vm.envOr("LIGHTER_BENCH_EXPECT_FULL", uint256(0)) != 0;
    }

    /// @dev A NAMED refusal, not just "it reverted". A bare `require(!ok)` passes
    ///      on an out-of-gas, on a wrong-selector typo, and on a revert that
    ///      happened three frames deeper for an unrelated reason — which on an
    ///      auth test is precisely the failure it is supposed to catch.
    function _mustRevert(address target, address who, bytes memory data, bytes4 want, string memory label) internal {
        vm.prank(who);
        (bool ok, bytes memory ret) = target.call(data);
        require(!ok, string.concat(label, ": expected a revert, the call SUCCEEDED"));
        require(ret.length >= 4, string.concat(label, ": reverted with EMPTY returndata"));
        bytes4 got;
        assembly ("memory-safe") {
            got := mload(add(ret, 0x20))
        }
        require(got == want, string.concat(label, ": wrong revert - got ", vm.toString(ret)));
        console.log("  %s reverts %s (expected)", label, vm.toString(abi.encodePacked(got)));
    }

    /// @dev Count the venue's own priority-queue events in the last recorded
    ///      span. `vm.recordLogs()` must have been armed immediately before.
    function _requirePriorityRequests(uint256 want, string memory label) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (
                logs[i].emitter == address(ZKL) && logs[i].topics.length != 0
                    && logs[i].topics[0] == NEW_PRIORITY_REQUEST
            ) n++;
        }
        console.log("  %s ok - NewPriorityRequest x%s", label, n);
        require(n == want, string.concat(label, ": wrong NewPriorityRequest count"));
    }

    /// @notice The three `IStrategyDelivery` answers, printed at every stage.
    function _probes(address clone, string memory ctx) internal view {
        LighterPerpStrategy s = LighterPerpStrategy(clone);
        console.log("--- probes %s ---", ctx);
        console.log("  state (0=Pending,1=Executed,2=Settled):", uint256(uint8(s.state())));
        console.log("  hasUndeliveredValue:", s.hasUndeliveredValue());
        console.log("  undeliveredValue:", s.undeliveredValue());
        console.log("  hasUnvaluedResidue:", s.hasUnvaluedResidue());
        console.log("  pendingBalance / idle USDG:", uint256(s.pendingBalance()), USDG.balanceOf(clone));
    }

    /// @notice Greppable wiring dump. The driver reads the vault/governor/clone
    ///         from here instead of carrying them between phases.
    function wiring(uint256 salt) external {
        _load();
        SyndicateVault v = _vault();
        console.log("BENCH_VAULT=%s", address(v));
        console.log("BENCH_GOVERNOR=%s", factory.governorOf(address(v)));
        console.log("BENCH_CLONE=%s", _clone(salt));
        console.log("BENCH_PID=%s", _pid());
    }

    /// @notice Read-only dump the driver calls between phases.
    function probe(uint256 salt) external {
        _load();
        _probes(_clone(salt), "probe");
        console.log("vault depositsLocked:", _vault().depositsLocked());
        console.log("vault totalAssets:", _vault().totalAssets());
    }

    /// @notice The `pendingAssetBalances` slot for this clone, for the driver's
    ///         `tenderly_setStorageAt`.
    function maturitySlot(uint256 salt) external {
        _load();
        address clone = _clone(salt);
        uint48 acct = LighterPerpStrategy(clone).accountIndex();
        bytes32 inner = keccak256(abi.encode(uint256(USDG_ASSET_INDEX), PENDING_BALANCES_BASE_SLOT));
        bytes32 slot = keccak256(abi.encode(uint256(acct), inner));
        console.log("BENCH_ACCOUNT_INDEX=%s", uint256(acct));
        console.log("BENCH_MATURITY_SLOT=%s", vm.toString(slot));
    }

    function _pubKey() internal pure returns (bytes memory) {
        // 5 x uint64 little-endian, each nonzero and < 0xffffffff00000001.
        return abi.encodePacked(
            bytes8(0x0100000000000000),
            bytes8(0x0200000000000000),
            bytes8(0x0300000000000000),
            bytes8(0x0400000000000000),
            bytes8(0x0500000000000000)
        );
    }

    function _pubKey2() internal pure returns (bytes memory) {
        return abi.encodePacked(
            bytes8(0x0600000000000000),
            bytes8(0x0700000000000000),
            bytes8(0x0800000000000000),
            bytes8(0x0900000000000000),
            bytes8(0x0a00000000000000)
        );
    }

    function _marketList() internal pure returns (uint16[] memory m) {
        m = new uint16[](2);
        m[0] = 1;
        m[1] = 2;
    }
}
