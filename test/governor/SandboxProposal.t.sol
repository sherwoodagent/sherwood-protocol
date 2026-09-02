// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {CallSandbox} from "../../src/CallSandbox.sol";
import {ICallSandbox} from "../../src/interfaces/ICallSandbox.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";

/// @dev A target nobody allowlisted and nobody certified — the whole point.
///      Records who called it, so the identity claim is measured rather than
///      argued.
contract IdentitySpy {
    address public lastCaller;
    uint256 public callCount;

    function ping() external {
        lastCaller = msg.sender;
        callCount++;
    }
}

/// @dev A third-party contract whose authorization is `msg.sender == vault` —
///      the exact gate a `delegatecall` batch would satisfy and a sandbox must
///      not.
contract VaultGated {
    address public immutable vault;

    error NotTheVault(address caller);

    constructor(address vault_) {
        vault = vault_;
    }

    function privilegedAction() external view {
        if (msg.sender != vault) revert NotTheVault(msg.sender);
    }
}

/// @dev Hands the CALLER a non-asset token — how a payload realistically ends
///      up holding something the sandbox cannot value. The sandbox's own address
///      is not known when the payload is written, so the token must be pushed to
///      `msg.sender` rather than to a named address.
contract TokenFaucet {
    function pour(address token, uint256 amount) external {
        ERC20Mock(token).mint(msg.sender, amount);
    }
}

/// @dev A token that answers `balanceOf` honestly and refuses every transfer —
///      a proposer can deploy exactly this. Without abandonment it would pin
///      `hasUnvaluedResidue()` true forever with nothing able to move it.
contract UnmovableToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("nope");
    }
}

/// @dev Faucet for the unmovable token — same reason as `TokenFaucet`: the
///      sandbox's address is not known when the payload is authored.
contract UnmovableFaucet {
    function pour(address token, uint256 amount) external {
        UnmovableToken(token).mint(msg.sender, amount);
    }
}

/// @dev A declared token whose `balanceOf` burns every drop of gas handed to it.
///      A proposer can deploy exactly this, and it is the ADVERSARY the residue
///      probes have to survive: the sandbox's loops run on gas BORROWED from the
///      vault (150,000 for `hasUnvaluedResidue`, 1,500,000 for `collectResidue`'s
///      sweep), so an entry that takes more than its share does not merely fail —
///      it reverts the whole call, and `SyndicateVault._refreshUnvalued` reads an
///      unreadable probe as "keep the last known flag".
contract GasBurnerToken {
    uint256 public sink;

    function balanceOf(address) external view returns (uint256) {
        uint256 acc;
        while (true) {
            acc = uint256(keccak256(abi.encode(acc, sink)));
        }
        return acc;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }
}

/// @dev A token that can be made to refuse transfers and then allowed again —
///      a paused token, a temporary blacklist, an incident. Distinguishes a
///      TRANSIENT failure from a permanent one, which is the whole question
///      `ABANDON_DELAY` exists to answer.
contract PausableToken {
    mapping(address => uint256) public balanceOf;
    bool public paused;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!paused, "paused");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Faucet for `PausableToken` — same reason as `TokenFaucet`.
contract PausableFaucet {
    function pour(address token, uint256 amount) external {
        PausableToken(token).mint(msg.sender, amount);
    }
}

/// @notice The central claims of `permissionless-tier2-sandbox`: an uncertified,
///         unlisted target reaches execution with no owner transaction, and the
///         most a hostile payload can cost is the amount it was funded with —
///         measured across execute, settle AND a follow-up transaction in which
///         the attacker spends every approval the sandbox granted.
///
///         Fixture mirrors `test/governor/PerCallCapitalDeclarations.t.sol`
///         (test contract as factory, `MockRegistryMinimal`, no exposure ledger)
///         so that coverage is un-gated and every revert observed here belongs to
///         the sandbox path rather than to the quorum machinery.
contract SandboxProposalTest is Test {
    SyndicateGovernor public governor;
    SyndicateVault public vault;
    BatchExecutorLib public executorLib;
    ERC20Mock public usdc;
    MockAgentRegistry public agentRegistry;
    MockRegistryMinimal public guardianRegistry;
    TierRegistry public tierRegistry;
    CallSandbox public sandboxImpl;
    VaultWithdrawalQueue public queue;

    IdentitySpy public spy;
    VaultGated public vaultGated;
    TokenFaucet public faucet;
    ERC20Mock public foreign;

    address public owner = makeAddr("owner");
    address public agent = makeAddr("agent");
    address public stranger = makeAddr("stranger");
    address public attacker = makeAddr("attacker");
    address public lp1 = makeAddr("lp1");

    uint256 constant VOTING_PERIOD = 1 days;
    uint256 constant EXECUTION_WINDOW = 1 days;
    uint256 constant TVL = 20_000_000e6;
    uint256 constant FUNDING = 1_000e6;

    /// @dev Cached in `setUp` on purpose. `GovEnvelope.permissive` reads the
    ///      vault, and an external call in ARGUMENT position consumes a pending
    ///      one-shot cheatcode — building the envelope inline would eat every
    ///      `vm.expectRevert` in this file and the propose-validation tests would
    ///      pass for the wrong reason.
    ISyndicateGovernor.RiskEnvelope internal envelope;

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        guardianRegistry = new MockRegistryMinimal();
        tierRegistry = new TierRegistry(address(this));
        sandboxImpl = new CallSandbox();

        SyndicateVault vaultImpl = new SyndicateVault();
        bytes memory vaultInit = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    // ZERO ON PURPOSE. `test_maxLoss_*` measures the vault's raw
                    // balance delta across a full lifecycle; a management fee
                    // also leaves the vault at settle (≈1,917 USDC on this TVL
                    // over 7 days at 50 bps) and would be counted as payload
                    // loss, turning a structural claim into an accounting one.
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(vaultImpl), vaultInit))));

        SyndicateGovernor govImpl = new SyndicateGovernor(24 hours, 1 hours);
        bytes memory govInit = abi.encodeCall(
            SyndicateGovernor.initialize,
            (
                address(vault),
                address(guardianRegistry),
                address(new ProtocolConfig(owner)),
                address(this),
                address(deployTierRegistry(address(this))),
                ISyndicateGovernor.GovernorParams({
                    votingPeriod: VOTING_PERIOD,
                    executionWindow: EXECUTION_WINDOW,
                    vetoThresholdBps: 4000,
                    maxPerformanceFeeBps: 1500,
                    cooldownPeriod: 1 days,
                    collaborationWindow: 48 hours,
                    maxCoProposers: 5,
                    minStrategyDuration: 1 hours,
                    maxStrategyDuration: 30 days
                })
            )
        );
        governor = SyndicateGovernor(address(new ERC1967Proxy(address(govImpl), govInit)));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(address(governor)));

        // Factory-gated, one-shot: the test contract is this vault's factory.
        vault.setSandboxImplementation(address(sandboxImpl));
        // A REAL queue, not a stub — the denylist resolves it live off the vault
        // and an unbound queue would read as `address(0)`, which never matches
        // and would make the queue arm of the denylist vacuously pass.
        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.startPrank(owner);
        vault.registerAgent(agentRegistry.mint(agent), agent);
        vm.stopPrank();

        spy = new IdentitySpy();
        vaultGated = new VaultGated(address(vault));
        faucet = new TokenFaucet();
        foreign = new ERC20Mock("Foreign", "FGN", 18);

        usdc.mint(lp1, TVL);
        vm.startPrank(lp1);
        usdc.approve(address(vault), TVL);
        vault.deposit(TVL, lp1);
        vm.stopPrank();

        envelope = GovEnvelope.permissive(address(vault));

        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @dev Wires the TierRegistry and allowlists the vault ASSET so an ordinary
    ///      execute batch can run. THIS CEREMONY NEVER TOUCHES A SANDBOX TARGET:
    ///      `spy` is deliberately left unlisted and uncertified in every test
    ///      below, which is what the permissionless claim is about. The batch
    ///      itself is ordinary protocol behaviour and keeps its existing gate.
    function _wireTierRegistry() internal {
        governor.setTierRegistry(address(tierRegistry));
        tierRegistry.setAdapterAllowed(address(usdc), true);
    }

    // ── fixture helpers ───────────────────────────────────────────────────

    function _benignExec() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (address(usdc), 0)), value: 0
        });
    }

    function _benignSettle() internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = _benignExec();
    }

    function _payload(ICallSandbox.Call[] memory calls, uint256 funding, address[] memory tokens)
        internal
        pure
        returns (ISyndicateGovernor.SandboxPayload memory)
    {
        return ISyndicateGovernor.SandboxPayload({funding: funding, calls: calls, declaredTokens: tokens});
    }

    function _oneCall(address target, bytes memory data) internal pure returns (ICallSandbox.Call[] memory calls) {
        calls = new ICallSandbox.Call[](1);
        calls[0] = ICallSandbox.Call({target: target, data: data});
    }

    function _proposeSandbox(ISyndicateGovernor.SandboxPayload memory sandbox, address caller)
        internal
        returns (uint256 pid)
    {
        vm.prank(caller);
        pid = governor.proposeWithSandbox(
            sandbox,
            address(vault),
            address(0),
            "ipfs://sandbox",
            7 days,
            envelope,
            _benignExec(),
            new uint256[](1),
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
    }

    function _advancePastVoting() internal {
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
    }

    // ── 5.1 THE HEADLINE ──────────────────────────────────────────────────

    /// @notice An uncertified, never-allowlisted target runs end to end, and the
    ///         owner key is not used once after deployment. `vm.startPrank(owner)`
    ///         appears nowhere below, and no owner-gated setter is called —
    ///         `setTier2CallCapBps` stays at its inert default, so even the
    ///         ceiling required no ceremony.
    function test_permissionless_unlistedTargetExecutesWithNoOwnerTransaction() public {
        // Wiring the registry is what makes this claim non-vacuous: with a
        // registry present, `spy` is uncertified and therefore tier 2, exactly
        // the case a batch call could never reach.
        _wireTierRegistry();
        assertFalse(tierRegistry.isAdapterAllowed(address(spy)), "the target is not allowlisted anywhere");

        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );

        assertEq(governor.getProposalTier(pid), 2, "a sandbox payload forces tier 2");

        _advancePastVoting();
        governor.executeProposal(pid);

        assertEq(spy.callCount(), 1, "the uncertified target was actually called");
        address sandbox = vault.sandboxOf(pid);
        assertTrue(sandbox != address(0), "a sandbox was minted for the proposal");
        assertEq(spy.lastCaller(), sandbox, "and the call arrived from the sandbox");
    }

    /// @notice The execute-time coverage guard prices the same quantity the
    ///         propose-time snapshot did. `requiredCoverage` for a sandbox
    ///         proposal is `batchCoverage + funding`; if the live figure were
    ///         batch-only, a mid-review re-certification raising the batch's
    ///         coverage by LESS than the funding would execute undetected —
    ///         under-covered by exactly that amount.
    /// @dev    Batch: one certified `usdc.approve` at 50 bps on a 10_000e6 cap
    ///         (50e6 coverage) plus 1_000e6 sandbox funding → required 1_050e6.
    ///         Re-certified at 500 bps the batch prices 500e6: a 450e6 rise,
    ///         strictly inside the 1_000e6 funding, so a batch-only comparison
    ///         (500e6 <= 1_050e6) passes and only the funding-inclusive one
    ///         (1_500e6 > 1_050e6) trips. Timing mirrors
    ///         `TierResolution.test_executeRevertsWhenCoverageRegressedAtSameTier`:
    ///         `certifyDelay` floored to `MIN_CERTIFY_DELAY` (== VOTING_PERIOD)
    ///         so one warp lands the replacement inside the execution window.
    function test_coverageRegression_countsSandboxFundingAtExecute() public {
        _wireTierRegistry();
        tierRegistry.proposeCertification(
            address(usdc), usdc.approve.selector, 0, 50, address(0), address(usdc).codehash
        );
        vm.warp(vm.getBlockTimestamp() + tierRegistry.certifyDelay());
        tierRegistry.certify(address(usdc), usdc.approve.selector);

        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = 10_000e6;
        vm.prank(agent);
        uint256 pid = governor.proposeWithSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)),
            address(vault),
            address(0),
            "ipfs://sandbox",
            7 days,
            envelope,
            _benignExec(),
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );
        assertEq(governor.getRequiredCoverage(pid), 50e6 + FUNDING, "batch coverage + funding");

        tierRegistry.setCertifyDelay(tierRegistry.MIN_CERTIFY_DELAY());
        tierRegistry.proposeCertification(
            address(usdc), usdc.approve.selector, 0, 500, address(0), address(usdc).codehash
        );

        _advancePastVoting(); // == MIN_CERTIFY_DELAY, so the replacement is also ready

        tierRegistry.certify(address(usdc), usdc.approve.selector);

        vm.expectRevert(ISyndicateGovernor.CoverageRegressed.selector);
        governor.executeProposal(pid);
    }

    // ── 4.2 identity ──────────────────────────────────────────────────────

    /// @notice The confinement argument in one assertion: a contract gated on
    ///         `msg.sender == vault` refuses the sandbox. A `delegatecall` batch
    ///         would have satisfied that gate.
    function test_identity_vaultGatedTargetRefusesTheSandbox() public {
        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(address(vaultGated), abi.encodeCall(VaultGated.privilegedAction, ())),
                FUNDING,
                new address[](0)
            ),
            agent
        );

        _advancePastVoting();
        // The whole run reverts: a partial run is a different proposal than the
        // one guardians approved.
        vm.expectRevert(abi.encodeWithSelector(ICallSandbox.CallFailed.selector, 0));
        governor.executeProposal(pid);
    }

    // ── 4.1 / 4.3 the max-loss invariant ──────────────────────────────────

    /// @notice A hostile call set that approves an attacker for the maximum AND
    ///         transfers what it holds still costs the vault exactly `FUNDING` —
    ///         measured across execute, settle, and a follow-up transaction in
    ///         which the attacker spends the approval that was granted.
    function test_maxLoss_hostilePayloadCostsAtMostTheFundedAmount() public {
        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](2);
        calls[0] = ICallSandbox.Call({
            target: address(usdc), data: abi.encodeCall(usdc.approve, (attacker, type(uint256).max))
        });
        calls[1] =
            ICallSandbox.Call({target: address(usdc), data: abi.encodeCall(usdc.transfer, (attacker, FUNDING / 2))});

        uint256 pid = _proposeSandbox(_payload(calls, FUNDING, new address[](0)), agent);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        _advancePastVoting();
        governor.executeProposal(pid);

        address sandbox = vault.sandboxOf(pid);
        assertEq(usdc.allowance(address(vault), sandbox), 0, "the vault never approves the sandbox");

        // The follow-up transaction: the attacker spends the standing approval
        // the payload granted. This is the drain that no per-call meter could
        // have seen, and it reaches only the sandbox's own balance.
        // Balance hoisted: an external call in argument position would consume
        // the prank and the drain would run as this test contract.
        uint256 sandboxLeft = usdc.balanceOf(sandbox);
        vm.prank(attacker);
        usdc.transferFrom(sandbox, attacker, sandboxLeft);

        // And it cannot reach the vault: the sandbox holds no allowance there.
        vm.prank(attacker);
        vm.expectRevert();
        usdc.transferFrom(address(vault), attacker, 1);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);

        uint256 lost = vaultBefore - usdc.balanceOf(address(vault));
        assertLe(lost, FUNDING, "structural bound: the funded amount, and never more");
        assertEq(usdc.balanceOf(attacker), FUNDING, "the attacker got the funding and precisely nothing else");
    }

    /// @notice Funding is one-shot: a second `run()` on the minted sandbox
    ///         reverts even for the vault, so a later balance cannot be
    ///         re-dispatched against already-reviewed calldata.
    function test_run_isOneShot() public {
        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);

        address sandbox = vault.sandboxOf(pid);
        vm.prank(address(vault));
        vm.expectRevert(ICallSandbox.AlreadyRun.selector);
        ICallSandbox(sandbox).run();

        // And it is vault-only in the first place.
        vm.prank(stranger);
        vm.expectRevert(ICallSandbox.NotVault.selector);
        ICallSandbox(sandbox).run();
    }

    // ── 4.5 denylist ──────────────────────────────────────────────────────

    function test_denylist_vaultTargetRevertsTheWholeRun() public {
        _assertDenied(address(vault));
    }

    function test_denylist_governorTargetRevertsTheWholeRun() public {
        _assertDenied(address(governor));
    }

    /// @notice The queue is denied for the accounting reason, not a custody one:
    ///         a sandbox holding vault capital could touch the queue's stamp and
    ///         reserve counters, which other guards assume only the vault moves.
    function test_denylist_queueTargetRevertsTheWholeRun() public {
        assertTrue(vault.withdrawalQueue() != address(0), "fixture sanity: a real queue is bound");
        _assertDenied(vault.withdrawalQueue());
    }

    function _assertDenied(address denied) internal {
        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](2);
        calls[0] = ICallSandbox.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ())});
        calls[1] = ICallSandbox.Call({target: denied, data: abi.encodeWithSignature("asset()")});

        uint256 pid = _proposeSandbox(_payload(calls, FUNDING, new address[](0)), agent);
        _advancePastVoting();
        vm.expectRevert(abi.encodeWithSelector(ICallSandbox.DeniedTarget.selector, denied));
        governor.executeProposal(pid);
        assertEq(spy.callCount(), 0, "no call in the set was applied");
    }

    /// @notice THE BEST-EFFORT BRANCH, MEASURED RATHER THAN ARGUED. When the
    ///         governor cannot answer `tierRegistry()`, `CallSandbox._probeAddress`
    ///         yields `address(0)`, `_denyIfNamed` treats that as "unresolved" and
    ///         returns, and the tier registry is left UNDENIED — a stored target
    ///         naming it walks straight through the denylist.
    ///
    ///         `CallSandbox`'s natspec calls that acceptable on one specific
    ///         argument rather than a shrug: every function on the best-effort
    ///         contracts is gated to its own privileged caller, so a sandbox that
    ///         reaches them acts only as itself, holding no standing. This test
    ///         pins both halves — the registry really is reached, and the identity
    ///         it is reached with is the sandbox's own.
    function test_denylist_unresolvedTierRegistryIsUndeniedAndArrivesWithNoStanding() public {
        _wireTierRegistry();
        address registry = governor.tierRegistry();
        assertEq(registry, address(tierRegistry), "fixture sanity: the governor resolves a real registry");
        // Read BEFORE the `expectCall` below is armed. `expectCall` counts every
        // matching call for the rest of the test, so reading `owner()` after
        // arming would let the non-vacuity control be satisfied by this
        // assertion's own call instead of by the payload's.
        address registryOwner = tierRegistry.owner();
        assertEq(registryOwner, address(this), "fixture sanity: this test contract owns the registry");

        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](2);
        calls[0] = ICallSandbox.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ())});
        // An UNGATED view on the registry: the point here is reachability, so the
        // call has to succeed. The privileged shape is the next test.
        calls[1] = ICallSandbox.Call({target: registry, data: abi.encodeWithSignature("owner()")});

        uint256 pid = _proposeSandbox(_payload(calls, FUNDING, new address[](0)), agent);
        _advancePastVoting();

        // ONLY THE FIRST READ GOES UNANSWERED, and the mock is armed only now.
        // `SyndicateVault._guardBatchCalls` resolves the SAME getter later in this
        // transaction and fails CLOSED on it (`TierRegistryUnresolved`), so muting
        // it for the whole call would take the execute batch down before anything
        // here could be observed. `mockCalls` answers each successive read from the
        // list and then repeats the last entry, so entry 0 starves the sandbox's
        // probe and entry 1 hands every later read the real address.
        //
        // THAT ALSO PINS THE ORDERING RATHER THAN ASSUMING IT: `executeProposal`
        // dispatches the sandbox BEFORE the execute batch, so the probe is read 0.
        // If it were not, the probe would take entry 1, resolve, and this test
        // would fail with `DeniedTarget` — the assertion below cannot be satisfied
        // by an accident of ordering.
        bytes[] memory answers = new bytes[](2);
        answers[0] = ""; // ret.length != 32, so `_probeAddress` returns address(0)
        answers[1] = abi.encode(registry);
        vm.mockCalls(address(governor), abi.encodeCall(ISyndicateGovernor.tierRegistry, ()), answers);

        // NON-VACUITY. Without this the test would pass just as happily if the run
        // had never dispatched a thing: `expectCall` fails the test unless the
        // payload actually lands on the registry.
        vm.expectCall(registry, abi.encodeWithSignature("owner()"), 1);
        governor.executeProposal(pid);
        assertEq(spy.callCount(), 1, "the run dispatched; naming the registry did not deny it");

        // AND THE STANDING IT ARRIVES WITH IS NOTHING. The registry's own owner
        // gate names the sandbox, which is the whole reason leaving it undenied is
        // defensible: the denylist is defence in depth, this is the boundary.
        address sandbox = vault.sandboxOf(pid);
        assertTrue(sandbox != address(0), "a sandbox was minted for the proposal");
        assertTrue(sandbox != registryOwner, "control: the sandbox is not the registry owner");
        vm.prank(sandbox);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, sandbox));
        tierRegistry.setAdapterAllowed(address(spy), true);
    }

    /// @notice The same unresolved probe, with the payload naming a PRIVILEGED
    ///         function on the now-undenied registry. The run reaches it and the
    ///         registry's own owner gate turns it away, so the failure surfaces as
    ///         `CallFailed` — the sandbox wrapping the registry's revert — and
    ///         never as `DeniedTarget`.
    ///
    ///         THE REVERT REASON IS THE WHOLE ASSERTION. A post-revert state read
    ///         cannot pin which branch fired: `vm.expectRevert` rolls the registry
    ///         back either way, so `isAdapterAllowed` reads false under a denial
    ///         and under a gated refusal alike. Only the reason separates them.
    function test_denylist_unresolvedTierRegistryPrivilegedCallDiesOnTheRegistryGate() public {
        _wireTierRegistry();
        address registry = governor.tierRegistry();

        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(registry, abi.encodeCall(TierRegistry.setAdapterAllowed, (address(spy), true))),
                FUNDING,
                new address[](0)
            ),
            agent
        );
        _advancePastVoting();

        // Same shape as the test above: read 0 (the sandbox's probe) goes
        // unanswered, every later read resolves normally.
        bytes[] memory answers = new bytes[](2);
        answers[0] = "";
        answers[1] = abi.encode(registry);
        vm.mockCalls(address(governor), abi.encodeCall(ISyndicateGovernor.tierRegistry, ()), answers);

        vm.expectRevert(abi.encodeWithSelector(ICallSandbox.CallFailed.selector, 0));
        governor.executeProposal(pid);

        assertFalse(tierRegistry.isAdapterAllowed(address(spy)), "the privileged call never took");
    }

    // ── 4.4 the funding ceiling ───────────────────────────────────────────

    /// @notice One wei above the ceiling is refused at EXECUTE, not at propose:
    ///         the vault reads `tier2CallCapBps` live, and that read is the only
    ///         one that can see the ceiling in force when the capital actually
    ///         moves.
    function test_ceiling_oneWeiAboveIsRefusedAtExecute() public {
        vm.prank(owner);
        governor.setTier2CallCapBps(1); // 0.01% of TVL
        uint256 ceiling = (vault.totalAssets() * 1) / 10_000;

        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), ceiling + 1, new address[](0)), agent
        );

        _advancePastVoting();
        vm.expectRevert(
            abi.encodeWithSelector(ISyndicateVault.SandboxFundingExceedsCeiling.selector, ceiling + 1, ceiling)
        );
        governor.executeProposal(pid);
    }

    /// @notice And exactly at the ceiling it runs.
    function test_ceiling_atTheCeilingPasses() public {
        vm.prank(owner);
        governor.setTier2CallCapBps(1);
        uint256 ceiling = (vault.totalAssets() * 1) / 10_000;

        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), ceiling, new address[](0)), agent
        );

        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(spy.callCount(), 1, "at the ceiling, the payload runs");
    }

    /// @notice WHY THERE IS NO "TIGHTENED MID-LIFECYCLE" CASE TO TEST: the
    ///         parameter is frozen for the whole time a proposal is open, so the
    ///         window between propose and execute cannot be moved at all. The
    ///         live read at execute still matters — it is what binds a ceiling
    ///         changed while no proposal was open, which is every other moment.
    function test_ceiling_cannotBeMovedWhileAProposalIsOpen() public {
        _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );

        vm.prank(owner);
        vm.expectRevert(ISyndicateGovernor.ParamsFrozenDuringProposal.selector);
        governor.setTier2CallCapBps(1);
    }

    // ── 5.2 the batch guard is untouched ──────────────────────────────────

    /// @notice The sandbox does not loosen `_guardBatchCalls`: the SAME
    ///         uncertified target named directly in a governor batch is still
    ///         refused. Reachability moved to a new path; it was not widened on
    ///         the old one.
    function test_batchGuard_unchangedForDirectlyNamedTargets() public {
        governor.setTierRegistry(address(tierRegistry));

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] =
            BatchExecutorLib.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ()), value: 0});

        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://direct",
            7 days,
            envelope,
            execCalls,
            new uint256[](1),
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        _advancePastVoting();
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.DisallowedBatchCallee.selector, address(spy)));
        governor.executeProposal(pid);
    }

    // ── 5.3 proposer gate ─────────────────────────────────────────────────

    function test_proposerGate_nonAgentCannotOpenASandboxProposal() public {
        vm.expectRevert(ISyndicateGovernor.NotRegisteredAgent.selector);
        _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), stranger
        );
    }

    // ── 5.5 payload readability and immutability ──────────────────────────

    /// @notice The payload is readable in full for the whole review period —
    ///         which is what guardian underwriting of an uncertified target
    ///         rests on — and identical the moment before it executes.
    function test_payload_readableInFullAndUnchangedAtExecute() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        bytes memory data = abi.encodeCall(IdentitySpy.ping, ());

        uint256 pid = _proposeSandbox(_payload(_oneCall(address(spy), data), FUNDING, tokens), agent);

        ISyndicateGovernor.SandboxPayload memory stored = governor.sandboxPayload(pid);
        assertEq(stored.funding, FUNDING, "funding readable");
        assertEq(stored.calls.length, 1, "call set readable");
        assertEq(stored.calls[0].target, address(spy), "target readable");
        assertEq(stored.calls[0].data, data, "calldata readable verbatim");
        assertEq(stored.declaredTokens.length, 1, "declared tokens readable");
        assertEq(stored.declaredTokens[0], address(usdc), "declared token readable");

        _advancePastVoting();
        ISyndicateGovernor.SandboxPayload memory atExecute = governor.sandboxPayload(pid);
        assertEq(keccak256(abi.encode(atExecute)), keccak256(abi.encode(stored)), "no path altered the payload");

        governor.executeProposal(pid);
        ICallSandbox minted = ICallSandbox(vault.sandboxOf(pid));
        assertEq(minted.calls().length, 1, "the minted sandbox carries the reviewed set");
        assertEq(minted.calls()[0].target, address(spy), "and the same target");
    }

    /// @notice A proposal with no payload reads back as an empty one rather than
    ///         reverting — the view is the guardians' entry point and must answer
    ///         for every proposal.
    function test_payload_absentReadsEmpty() public {
        vm.prank(agent);
        uint256 pid = governor.propose(
            address(vault),
            address(0),
            "ipfs://plain",
            7 days,
            envelope,
            _benignExec(),
            new uint256[](1),
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        ISyndicateGovernor.SandboxPayload memory stored = governor.sandboxPayload(pid);
        assertEq(stored.funding, 0, "no funding");
        assertEq(stored.calls.length, 0, "no calls");

        _advancePastVoting();
        governor.executeProposal(pid);
        assertEq(vault.sandboxOf(pid), address(0), "and no sandbox is ever minted");
    }

    // ── 5.6 residue ───────────────────────────────────────────────────────

    /// @dev Run a payload that leaves `amount` of `foreign` in the sandbox, with
    ///      the token declared or not, and settle. Returns the sandbox address.
    function _runLeavingForeignToken(uint256 amount, bool declare) internal returns (uint256 pid, address sandbox) {
        address[] memory tokens = new address[](declare ? 1 : 0);
        if (declare) tokens[0] = address(foreign);

        pid = _proposeSandbox(
            _payload(
                _oneCall(address(faucet), abi.encodeCall(TokenFaucet.pour, (address(foreign), amount))), FUNDING, tokens
            ),
            agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        sandbox = vault.sandboxOf(pid);
        assertEq(foreign.balanceOf(sandbox), amount, "the payload really did leave a foreign token behind");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
    }

    /// @notice A DECLARED non-asset leftover is what the vault can see, so it
    ///         refuses to mint rather than price a NAV it knows is incomplete —
    ///         and `collectResidue` is the permissionless exit that reopens
    ///         deposits.
    function test_residue_declaredLeftoverLocksDepositsUntilCollected() public {
        (, address sandbox) = _runLeavingForeignToken(5e18, true);

        assertTrue(vault.depositsLocked(), "an unvaluable leftover shuts the mint side");

        vault.collectResidue(sandbox);

        assertFalse(vault.depositsLocked(), "collecting it reopens deposits");
        assertEq(foreign.balanceOf(sandbox), 0, "and the sandbox no longer holds it");
    }

    /// @notice THE COHORT-SPLIT DOOR STAYS SHUT. `_payCohortShare` splits a
    ///         MEASURED BALANCE DELTA taken across the call inside
    ///         `collectResidue`, and a delta is a complete measurement only
    ///         while the vault is the one door vault asset arrives through. A
    ///         sandbox is genuinely enrolled in that split — `onProposalSettled`
    ///         records it against the settling pid — so a bare EOA driving
    ///         `sweep()` directly used to land the whole balance in the vault
    ///         OUTSIDE the measurement: the exited cohort credited nothing,
    ///         unrepairably, and `depositNav()` double-counting until someone
    ///         called `collectResidue`.
    ///
    ///         Both templates already carried `onlyVault` for this reason; the
    ///         sandbox was a third residue holder merged with the door open.
    function test_residue_directSweepIsRefusedSoTheCohortSplitStaysComplete() public {
        (, address sandbox) = _runLeavingForeignToken(5e18, true);

        // NON-VACUITY: there is really something to sweep, so a refusal here is
        // the gate firing rather than an empty call trivially doing nothing.
        assertGt(foreign.balanceOf(sandbox), 0, "the sandbox holds a leftover to sweep");

        address keeper = makeAddr("keeper");
        assertTrue(keeper != address(vault), "control: the caller is not the vault");
        vm.prank(keeper);
        vm.expectRevert(ICallSandbox.NotVault.selector);
        ICallSandbox(sandbox).sweep();

        // AND THE VAULT-ROUTED PATH STILL WORKS. The permissionless property is
        // routed, not removed: `collectResidue` is itself callable by anyone.
        vm.prank(keeper);
        vault.collectResidue(sandbox);
        assertEq(foreign.balanceOf(sandbox), 0, "the vault-routed exit still brings it home");
        assertFalse(vault.depositsLocked(), "and it reopens deposits");
    }

    /// @notice An UNDECLARED leftover is stranded in the sandbox and never
    ///         priced into a deposit. The safe direction of error: the proposer
    ///         loses what it failed to declare, and no LP ever mints against it.
    function test_residue_undeclaredLeftoverIsStrandedAndNeverPriced() public {
        uint256 navBefore = vault.totalAssets();
        (, address sandbox) = _runLeavingForeignToken(5e18, false);

        assertFalse(vault.depositsLocked(), "the vault cannot see what was never declared");
        assertEq(foreign.balanceOf(sandbox), 5e18, "the token stays stranded in the sandbox");
        assertEq(foreign.balanceOf(address(vault)), 0, "and never reaches the vault");
        assertLe(vault.totalAssets(), navBefore, "it is never counted as vault value");
    }

    /// @notice A DECLARED token that refuses every transfer must not become a
    ///         permanent deposit brick. `sweep` proves it unmovable, abandons it,
    ///         and the lock clears — the token stays stranded and unpriced,
    ///         which is exactly how an undeclared leftover is already treated.
    ///         Any registered agent could otherwise shut minting forever.
    /// @dev    TWO SWEEPS, `ABANDON_DELAY` APART, and that is the point rather
    ///         than a wrinkle. One failed transfer is a snapshot: `sweep()` is
    ///         permissionless, so if a single failure wrote the token off anyone
    ///         could pick a moment when a PERFECTLY GOOD token happens to be
    ///         paused and make the vault stop counting value it still holds.
    ///         Abandonment therefore requires the failure to persist, and the
    ///         lock it clears is bounded by that delay instead of permanent.
    function test_residue_unmovableDeclaredTokenIsAbandonedRatherThanBrickingDeposits() public {
        UnmovableToken bad = new UnmovableToken();
        UnmovableFaucet badFaucet = new UnmovableFaucet();

        address[] memory tokens = new address[](1);
        tokens[0] = address(bad);

        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(address(badFaucet), abi.encodeCall(UnmovableFaucet.pour, (address(bad), 5e18))),
                FUNDING,
                tokens
            ),
            agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        address sandbox = vault.sandboxOf(pid);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertTrue(vault.depositsLocked(), "it locks like any other declared leftover");

        vault.collectResidue(sandbox);
        assertTrue(vault.depositsLocked(), "the FIRST failure only starts the clock - one sweep is not evidence");
        assertEq(usdc.balanceOf(sandbox), 0, "while the real capital came home on that very first call");

        vm.warp(vm.getBlockTimestamp() + sandboxImpl.ABANDON_DELAY());
        vault.collectResidue(sandbox);

        assertFalse(vault.depositsLocked(), "still failing a delay later: abandoned, and deposits reopen");
        assertEq(bad.balanceOf(sandbox), 5e18, "the token itself is stranded, as it must be");
    }

    /// @notice A token that was merely PAUSED is not written off. Abandonment
    ///         reopens deposits on value the vault then stops counting, and
    ///         `sweep()` is permissionless — so a griefer must not be able to
    ///         pick a moment of transient failure and make that call for
    ///         everyone. Once the token moves again it is swept for real.
    function test_abandon_transientFailureIsNotWrittenOff() public {
        PausableToken flaky = new PausableToken();
        PausableFaucet flakyFaucet = new PausableFaucet();

        address[] memory tokens = new address[](1);
        tokens[0] = address(flaky);

        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(address(flakyFaucet), abi.encodeCall(PausableFaucet.pour, (address(flaky), 5e18))),
                FUNDING,
                tokens
            ),
            agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        address sandbox = vault.sandboxOf(pid);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);

        flaky.setPaused(true);
        vault.collectResidue(sandbox);
        assertTrue(vault.depositsLocked(), "a paused token is still held, so it still counts");
        assertEq(flaky.balanceOf(sandbox), 5e18, "and it is still there");

        // The incident ends WITHIN the delay - exactly the case a single-failure
        // write-off would have got wrong.
        flaky.setPaused(false);
        vault.collectResidue(sandbox);

        assertFalse(vault.depositsLocked(), "it moved, so there is nothing left to count");
        assertEq(flaky.balanceOf(sandbox), 0, "the value was RECOVERED, not written off");
        assertEq(flaky.balanceOf(address(vault)), 5e18, "and it reached the vault");
    }

    // ── 5.6b gas-adversarial declared tokens ──────────────────────────────

    /// @notice A declared token that BURNS GAS must not be able to freeze the
    ///         residue flag. The vault reads `hasUnvaluedResidue()` through a
    ///         150,000-gas staticcall and `_refreshUnvalued` KEEPS THE LAST KNOWN
    ///         FLAG when that read fails — so a payload that latches the flag
    ///         true and then makes the probe permanently unreadable would shut
    ///         the mint side for the life of the vault, with no permissionless
    ///         exit and no owner override.
    /// @dev    The sequence is the exploit: `foreign` sits FIRST so the first
    ///         probe returns true cheaply and the flag latches; sweeping it out
    ///         then forces every later probe to walk past it into the burner.
    ///         Against a fixed per-token gas ceiling equal to the caller's whole
    ///         budget this reverts out of gas forever; against `_fairShare` the
    ///         burner gets its slice and the loop still answers.
    ///
    ///         THE TRAILING TOKEN IS LOAD-BEARING, not padding. With the burner
    ///         LAST this test passes against the broken code too: EIP-150 hands a
    ///         sub-call only 63/64 of what is left, so a final burner still
    ///         leaves its caller the 1/64 it needs to return. Only an entry that
    ///         starves an entry BEHIND it makes the whole function unreadable,
    ///         which is the condition `_fairShare` actually removes. Verified by
    ///         mutation: restore the fixed `_PROBE_GAS` ceiling and this fails.
    function test_probe_gasBurningDeclaredTokenCannotFreezeTheResidueFlag() public {
        GasBurnerToken burner = new GasBurnerToken();

        address[] memory tokens = new address[](3);
        tokens[0] = address(foreign);
        tokens[1] = address(burner);
        tokens[2] = address(new ERC20Mock("Trailing", "TRAIL", 18));

        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(address(faucet), abi.encodeCall(TokenFaucet.pour, (address(foreign), 5e18))), FUNDING, tokens
            ),
            agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        address sandbox = vault.sandboxOf(pid);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        assertTrue(vault.depositsLocked(), "the flag latches true while the declared leftover is held");

        vault.collectResidue(sandbox);

        assertEq(foreign.balanceOf(sandbox), 0, "the leftover came home");
        assertFalse(vault.depositsLocked(), "and the probe still ANSWERS with a burner behind it");
    }

    /// @notice The vault's `collectResidue` lends `sweep()` 1,500,000 gas. A full
    ///         declared list of gas-burning tokens must not consume it before the
    ///         ASSET leg — that leg is the only one carrying priced value, and
    ///         losing it means the funded capital never comes home.
    /// @dev    Measured against the pre-fix code: 16 burners consumed the entire
    ///         1.5M, the whole sweep reverted, and the vault recovered ZERO.
    function test_sweep_hostileTokenListStillReturnsTheFundedAsset() public {
        address[] memory tokens = new address[](16);
        for (uint256 i = 0; i < 16; i++) {
            tokens[i] = address(new GasBurnerToken());
        }

        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, tokens), agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        address sandbox = vault.sandboxOf(pid);
        assertEq(usdc.balanceOf(sandbox), FUNDING, "the payload spent nothing, so the funding is still out there");

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);

        uint256 vaultBefore = usdc.balanceOf(address(vault));
        vault.collectResidue(sandbox);

        assertEq(usdc.balanceOf(sandbox), 0, "the funded capital came home");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, FUNDING, "in full, despite 16 hostile declared tokens");
    }

    /// @notice A FULL list of entirely well-behaved declared tokens must stay
    ///         readable inside the vault's own probe budget. This is the budget
    ///         regression gate: `MAX_DECLARED_TOKENS`, the per-token ceilings and
    ///         `SyndicateVault._PROBE_GAS` are three numbers in two contracts, and
    ///         nothing else fails loudly when they drift apart — an unreadable
    ///         probe is silently read as "keep the last known flag".
    function test_probe_maxDeclaredTokensStayReadableInsideTheVaultProbeBudget() public {
        address[] memory tokens = new address[](16);
        tokens[0] = address(foreign);
        for (uint256 i = 1; i < 16; i++) {
            tokens[i] = address(new ERC20Mock("Filler", "FILL", 18));
        }

        uint256 pid = _proposeSandbox(
            _payload(
                _oneCall(address(faucet), abi.encodeCall(TokenFaucet.pour, (address(foreign), 5e18))), FUNDING, tokens
            ),
            agent
        );
        _advancePastVoting();
        governor.executeProposal(pid);
        address sandbox = vault.sandboxOf(pid);

        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        governor.settleProposal(pid);
        vault.collectResidue(sandbox);

        // Read it exactly as the vault does: same selector, same 150,000 budget.
        (bool ok, bytes memory ret) = sandbox.staticcall{gas: 150_000}(abi.encodeWithSignature("hasUnvaluedResidue()"));
        assertTrue(ok && ret.length == 32, "a full, benign declared list must answer inside the vault's budget");
        assertFalse(abi.decode(ret, (bool)), "and answer that nothing is left");
        assertFalse(vault.depositsLocked(), "so deposits reopen");
    }

    // ── 5.7 runSandbox authorization ──────────────────────────────────────

    /// @notice Pausing halts the sandbox alongside every other capital movement.
    ///         A pause that stopped LP flow but still let arbitrary calldata
    ///         reach an uncertified target with vault capital would be no pause
    ///         at all.
    function test_runSandbox_refusesWhilePaused() public {
        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );
        _advancePastVoting();

        vm.prank(owner);
        vault.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        governor.executeProposal(pid);
        assertEq(vault.sandboxOf(pid), address(0), "nothing was minted and nothing was funded");
    }

    function test_runSandbox_refusesNonGovernorCallers() public {
        vm.prank(stranger);
        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.runSandbox(1, _oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), new address[](0), FUNDING);
    }

    // ── propose-time payload validation ───────────────────────────────────

    /// @notice A vault with no sandbox implementation refuses at PROPOSE. The
    ///         vault's binding is factory-only and set-once, so a vault created
    ///         before its factory had one can never acquire it — letting the
    ///         proposal through would burn the vote and the whole review period
    ///         and lock the proposer's bond against an execution that can never
    ///         succeed, with `SandboxNotConfigured` as the only outcome.
    function test_propose_refusedWhenTheVaultHasNoSandboxImplementation() public {
        vm.mockCall(address(vault), abi.encodeCall(ISyndicateVault.sandboxImplementation, ()), abi.encode(address(0)));

        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.SandboxNotAvailable.selector, address(vault)));
        _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );
    }

    function test_propose_emptyCallSetRejected() public {
        vm.expectRevert(ISyndicateGovernor.EmptySandboxCalls.selector);
        _proposeSandbox(_payload(new ICallSandbox.Call[](0), FUNDING, new address[](0)), agent);
    }

    function test_propose_zeroFundingRejected() public {
        vm.expectRevert(ISyndicateGovernor.ZeroSandboxFunding.selector);
        _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), 0, new address[](0)), agent
        );
    }

    /// @notice The sandbox spends the declared envelope, not a second one.
    function test_propose_fundingAboveMaxCapitalRejected() public {
        uint256 maxCapital = envelope.maxCapital;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateGovernor.SandboxFundingExceedsMaxCapital.selector, maxCapital + 1, maxCapital
            )
        );
        _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), maxCapital + 1, new address[](0)),
            agent
        );
    }

    /// @notice The governor's mirrored bounds must equal the sandbox's own, or a
    ///         proposal could clear review and then revert `InvalidCallSet` at
    ///         execute with the bond already locked.
    function test_sandboxBounds_matchImplementation() public view {
        assertEq(sandboxImpl.MAX_CALLS(), 32, "MAX_SANDBOX_CALLS mirror");
        assertEq(sandboxImpl.MAX_DECLARED_TOKENS(), 16, "MAX_SANDBOX_TOKENS mirror");
    }

    function test_propose_oversizedCallSetRejected() public {
        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](33);
        for (uint256 i = 0; i < calls.length; i++) {
            calls[i] = ICallSandbox.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ())});
        }
        vm.expectRevert(ISyndicateGovernor.TooManyCalls.selector);
        _proposeSandbox(_payload(calls, FUNDING, new address[](0)), agent);
    }

    /// @notice The token bound has its OWN error, so a rejected payload says
    ///         which of the two limits it broke.
    function test_propose_oversizedTokenListUsesItsOwnError() public {
        address[] memory tokens = new address[](17);
        for (uint256 i = 0; i < tokens.length; i++) {
            tokens[i] = address(new ERC20Mock("Filler", "FILL", 18));
        }
        vm.expectRevert(ISyndicateGovernor.TooManySandboxTokens.selector);
        _proposeSandbox(_payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, tokens), agent);
    }

    /// @notice Duplicates are refused AT PROPOSE, not at execute. Both residue
    ///         loops divide a borrowed gas budget between entries, so a padded
    ///         list starves the real ones — but the reason this check lives in
    ///         the governor as well as in `CallSandbox.init` is the lifecycle:
    ///         a rule enforced only at execute kills a proposal that already
    ///         cleared the vote and the review period, with the bond locked and
    ///         no way to amend it.
    function test_propose_duplicateDeclaredTokenRejectedAtProposeNotExecute() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(foreign);
        tokens[1] = address(foreign);

        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.DuplicateSandboxToken.selector, address(foreign)));
        _proposeSandbox(_payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, tokens), agent);
    }

    /// @notice Same lifecycle argument as the duplicate-token check above, for
    ///         the one other rule `CallSandbox.init` enforces: a zero target.
    ///         Without this the payload reaches execute and reverts
    ///         `InvalidCallSet` there, with the bond locked and the review
    ///         period already spent.
    function test_propose_zeroTargetRejectedAtProposeNotExecute() public {
        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.ZeroSandboxTarget.selector, uint256(0)));
        _proposeSandbox(_payload(_oneCall(address(0), ""), FUNDING, new address[](0)), agent);
    }

    /// @notice The whole call set is scanned, not just its head, and the error
    ///         names WHICH call was zero.
    ///
    ///         Without the index assertion this test would also pass against a
    ///         check that only ever looked at `calls[0]` — it would simply
    ///         report the wrong index — so the index is what makes it pin the
    ///         loop rather than the existence of a revert.
    function test_propose_zeroTargetFoundAnywhereInTheCallSet() public {
        ICallSandbox.Call[] memory calls = new ICallSandbox.Call[](3);
        calls[0] = ICallSandbox.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ())});
        calls[1] = ICallSandbox.Call({target: address(spy), data: abi.encodeCall(IdentitySpy.ping, ())});
        calls[2] = ICallSandbox.Call({target: address(0), data: ""});

        vm.expectRevert(abi.encodeWithSelector(ISyndicateGovernor.ZeroSandboxTarget.selector, uint256(2)));
        _proposeSandbox(_payload(calls, FUNDING, new address[](0)), agent);
    }

    // ── 4.1 (envelope) ────────────────────────────────────────────────────

    /// @notice The funded amount is subtracted from the capital the execute
    ///         batch runs under, so the two cannot spend the same declaration.
    function test_envelope_fundingIsSubtractedFromTheBatchCapital() public {
        uint256 maxCapital = FUNDING; // the whole envelope goes to the sandbox

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](1);
        execCalls[0] = BatchExecutorLib.Call({
            target: address(usdc), data: abi.encodeCall(usdc.transfer, (attacker, 1)), value: 0
        });
        uint256[] memory execCaps = new uint256[](1);
        execCaps[0] = maxCapital;

        vm.prank(agent);
        uint256 pid = governor.proposeWithSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)),
            address(vault),
            address(0),
            "ipfs://envelope",
            7 days,
            ISyndicateGovernor.RiskEnvelope({maxCapital: maxCapital, maxDrawdownBps: 10_000}),
            execCalls,
            execCaps,
            _benignSettle(),
            new uint256[](1),
            new ISyndicateGovernor.CoProposer[](0)
        );

        _advancePastVoting();
        // The sandbox consumed the entire envelope, so the batch runs under a
        // net-outflow ceiling of zero and its 1-wei transfer is refused.
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.MaxNetOutflowExceeded.selector, 1, 0));
        governor.executeProposal(pid);
    }

    /// @notice A sandbox payload is priced at full notional on top of whatever
    ///         the batches cost.
    function test_pricing_fundingAddsToRequiredCoverageAtFullNotional() public {
        governor.setTierRegistry(address(tierRegistry));

        uint256 pid = _proposeSandbox(
            _payload(_oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), FUNDING, new address[](0)), agent
        );

        // Both batches declare zero caps, so every unit of required coverage
        // here is the sandbox's own.
        assertEq(governor.getRequiredCoverage(pid), FUNDING, "full notional, no bound to reduce it");
    }
}
