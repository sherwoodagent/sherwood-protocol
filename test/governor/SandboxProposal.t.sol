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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockRegistryMinimal} from "../mocks/MockRegistryMinimal.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {deployTierRegistry} from "../helpers/TierRegistryFixture.sol";

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

        assertFalse(vault.depositsLocked(), "and one permissionless call still reopens deposits");
        assertEq(bad.balanceOf(sandbox), 5e18, "the token itself is stranded, as it must be");
        assertEq(usdc.balanceOf(sandbox), 0, "while the real capital came home");
    }

    // ── 5.7 runSandbox authorization ──────────────────────────────────────

    function test_runSandbox_refusesNonGovernorCallers() public {
        vm.prank(stranger);
        vm.expectRevert(ISyndicateVault.NotGovernor.selector);
        vault.runSandbox(1, _oneCall(address(spy), abi.encodeCall(IdentitySpy.ping, ())), new address[](0), FUNDING);
    }

    // ── propose-time payload validation ───────────────────────────────────

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
