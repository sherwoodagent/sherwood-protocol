// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {LeveragedAeroForkBase} from "./LeveragedAeroForkBase.sol";
import {BaseAddresses} from "./BaseAddresses.sol";
import {LeveragedAerodromeCLStrategy} from "../../../src/strategies/LeveragedAerodromeCLStrategy.sol";
import {BaseStrategy} from "../../../src/strategies/BaseStrategy.sol";

import {SyndicateGovernor} from "../../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../../src/SyndicateFactory.sol";
import {BatchExecutorLib} from "../../../src/BatchExecutorLib.sol";
import {DeploySherwood} from "../../../script/Deploy.s.sol";

import {IMoonwellMarket, ICToken} from "../../../src/interfaces/IMoonwellMarket.sol";
import {ICLPool, ICLSwapRouter} from "../../../src/interfaces/ISlipstream.sol";
import {TickMath} from "../../../src/libraries/TickMath.sol";

/// @dev Minimal Chainlink aggregator interface for the deleverage feed-mock.
interface IAggE2E {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title  LeveragedAeroCLE2EFork
/// @notice Task 3.12a — END-TO-END full-stack lifecycle for the Leveraged Aerodrome CL
///         strategy through the REAL Sherwood stack (NOT the fakeVault/fakeProposer harness).
///
///         Unlike the other `LeveragedAeroCL.*.fork.t.sol` suites — which clone+init the
///         strategy against a `makeAddr` vault/proposer and drive `execute()`/`settle()`
///         directly — this test:
///
///           1. Deploys a FRESH Sherwood core on the Tenderly Base vnet via
///              `DeploySherwood.deployCore(betaMode: true)` with a HIGH `maxStrategyDays`
///              (3650 — the `ABSOLUTE_MAX_STRATEGY_DURATION` cap), so the indefinite-lived
///              strategy can be proposed with a 3650-day duration.
///           2. Creates a real `SyndicateVault` via the real `SyndicateFactory`
///              (openDeposits) and funds two LPs.
///           3. Runs the proposal lifecycle through the real `SyndicateGovernor`:
///              propose → vote → execute → (manage) → settle.
///           4. Asserts the vault LOCK semantics (vault-native deposit/redeem/withdraw/mint
///              revert while a proposal is active; the strategy's own deposit/redeem WORK)
///              and that the lock releases at settle.
///
///         Registry note: betaMode `deployCore` wires `MinimalGuardianRegistry`
///         (`reviewPeriod()==0`, `getReviewState()==(resolved,not-blocked)`) — the
///         deploy-path equivalent of the test-only `MockRegistryMinimal` the task names.
///         Both give a cold-start guardian AUTO-PASS: a proposal advances Pending→Approved
///         the instant the vote window closes, with no openReview/resolveReview ceremony and
///         no WOOD / owner-stake setup.
///
///         Template-approval note: `StrategyFactory.setTemplateApproval` is NOT part of the
///         propose→execute path. `deployCore` deploys no `StrategyFactory`, and the
///         governor's `propose()` stores the `strategy` address DIRECTLY with no on-chain
///         template-registry check (it only requires a registered vault + a registered
///         agent caller). The e2e therefore clones+inits the template directly (the
///         `_cloneAndInit` pattern) — which is the real, current propose path.
///
///         Feed-staleness handling: the strategy reads Chainlink BTC/ETH/USDC. Rather than
///         `vm.mockCall`-ing them around every time-advance, the strategy is initialised with
///         a GENEROUS `maxDelay = 48 hours` (mirroring every other LeveragedAero fork test).
///         The whole lifecycle elapses ~2h of vnet time (1h vote + 1h proposer self-settle),
///         well inside 48h, so live feeds stay fresh end-to-end. The ONLY `vm.mockCall` is
///         the deliberate `_mockBtcScaled(3,1)` deleverage trigger, cleared before settle.
///
///         Run: forge test --match-path '*LeveragedAeroCL.e2e.fork.t.sol' -vv
///         Skips (vm pass) when `TENDERLY_FORK_RPC_URL` is unset (handled by the base setUp).
contract LeveragedAeroCLE2EFork is LeveragedAeroForkBase {
    // ── Actors ──
    address internal vaultOwner = makeAddr("vaultOwner");
    address internal agent = makeAddr("agent");
    address internal lp1 = makeAddr("lp1");
    address internal lp2 = makeAddr("lp2");
    address internal depA = makeAddr("depA"); // mid-proposal strategy.deposit LP
    address internal depB = makeAddr("depB"); // mid-proposal strategy.deposit LP
    address internal stranger = makeAddr("stranger"); // permissionless deleverage caller
    address internal feeRecipient = makeAddr("feeRecipient");

    // ── Deployed Sherwood core (fresh on the fork) ──
    SyndicateGovernor internal governor;
    SyndicateFactory internal factory;
    SyndicateVault internal vault;
    address internal deployer;

    // ── Strategy under test ──
    LeveragedAerodromeCLStrategy internal strategy;
    uint256 internal proposalId;

    // ── Confirmed risk / fee envelope (Global Constraints) ──
    uint16 internal constant TARGET_LTV_BPS = 5000; // 50%
    uint16 internal constant MAX_LTV_BPS = 6500; // 65%
    uint16 internal constant MIN_HEALTH_BPS = 12000; // 1.20x
    uint16 internal constant MAX_SLIPPAGE_BPS = 100; // 1%
    uint16 internal constant MGMT_FEE_BPS = 100; // 1%/yr
    uint16 internal constant PERF_FEE_BPS = 1000; // 10% HWM

    // ── Amounts ──
    uint256 internal constant LP1_DEPOSIT = 30_000e6;
    uint256 internal constant LP2_DEPOSIT = 20_000e6;
    // Full vault float is deployed at execute (vault float → 0) so the strategy's
    // oracle-free proportional redeem is fair (no float share left behind in the vault).
    uint256 internal constant PRINCIPAL = LP1_DEPOSIT + LP2_DEPOSIT; // 50_000e6
    uint256 internal constant STRATEGY_DURATION = 3650 days; // indefinite (== ABSOLUTE cap)

    // ─────────────────────────────────────────────────────────────
    // setUp — fork + fresh stack + funded vault
    // ─────────────────────────────────────────────────────────────

    function setUp() public override {
        super.setUp(); // Tenderly fork-or-skip
        if (_skip) return;
        _deployStack();
        _createVaultAndFund();
    }

    /// @dev Deploy a fresh Sherwood core via the real deploy script, betaMode (stub registry).
    function _deployStack() internal {
        DeploySherwood deployScript = new DeploySherwood();
        DeploySherwood.Config memory cfg = DeploySherwood.Config({
            ensRegistrar: address(0),
            agentRegistry: address(0), // no ERC-8004 NFT check
            managementFeeBps: 50,
            protocolFeeBps: 0, // keep settle PnL math clean
            maxStrategyDays: 3650, // HIGH — relies on ABSOLUTE_MAX_STRATEGY_DURATION = 3650 days
            votingPeriod: 1 hours,
            woodToken: address(0), // beta: no WOOD
            slashAppealSeed: 0,
            epochZeroSeed: 0,
            betaMode: true // MinimalGuardianRegistry — cold-start auto-pass
        });
        // deployCore runs nested CREATE3 calls AS the script address; prank as the
        // script so the Create3Factory owner is consistent (mirrors HyperEVMIntegrationTest).
        vm.prank(address(deployScript));
        DeploySherwood.Deployed memory d = deployScript.deployCore(cfg);

        governor = SyndicateGovernor(d.governorProxy);
        factory = SyndicateFactory(d.factoryProxy);
        deployer = d.deployer;
    }

    /// @dev Create the syndicate vault (openDeposits, beta needs no owner stake) + register
    ///      the agent, then fund + deposit two LPs.
    function _createVaultAndFund() internal {
        SyndicateFactory.SyndicateConfig memory config = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://lev-aero-cl-e2e",
            asset: IERC20(USDC),
            name: "Lev Aero CL E2E Vault",
            symbol: "laUSDC",
            openDeposits: true,
            subdomain: "lev-aero-cl-e2e"
        });
        vm.prank(vaultOwner);
        (, address vaultAddr) = factory.createSyndicate(42, config);
        vault = SyndicateVault(payable(vaultAddr));

        vm.prank(vaultOwner);
        vault.registerAgent(43, agent);

        _fundUSDC(lp1, LP1_DEPOSIT);
        _fundUSDC(lp2, LP2_DEPOSIT);

        vm.startPrank(lp1);
        IERC20(USDC).approve(address(vault), LP1_DEPOSIT);
        vault.deposit(LP1_DEPOSIT, lp1);
        vm.stopPrank();

        vm.startPrank(lp2);
        IERC20(USDC).approve(address(vault), LP2_DEPOSIT);
        vault.deposit(LP2_DEPOSIT, lp2);
        vm.stopPrank();

        // Snapshot block in the past so the vote checkpoint reads cleanly.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ─────────────────────────────────────────────────────────────
    // Step 1 confirmation — governor impl carries the 3650d cap
    // ─────────────────────────────────────────────────────────────

    /// @notice The freshly-deployed governor must carry the Phase-2
    ///         `ABSOLUTE_MAX_STRATEGY_DURATION = 3650 days` (not the legacy 30d), and the
    ///         deploy must have applied `maxStrategyDuration = 3650 days`. Without this the
    ///         indefinite-duration propose below reverts `StrategyDurationTooLong`.
    function test_governorImpl_carries3650dCap() public {
        if (_skip) return;
        assertEq(governor.ABSOLUTE_MAX_STRATEGY_DURATION(), 3650 days, "governor impl missing 3650d cap");
        ISyndicateGovernor.GovernorParams memory gp = governor.getGovernorParams();
        assertEq(gp.maxStrategyDuration, 3650 days, "deployed maxStrategyDuration != 3650d");
    }

    // ─────────────────────────────────────────────────────────────
    // The full lifecycle
    // ─────────────────────────────────────────────────────────────

    function test_e2e_fullLifecycle() public {
        if (_skip) return;

        // ── Step 1: governor 3650d confirmation (also asserted standalone above) ──
        ISyndicateGovernor.GovernorParams memory gp = governor.getGovernorParams();
        assertEq(governor.ABSOLUTE_MAX_STRATEGY_DURATION(), 3650 days, "governor impl missing 3650d cap");
        assertEq(gp.maxStrategyDuration, 3650 days, "deployed maxStrategyDuration != 3650d");

        // ── Step 2: clone + init the template (real propose path: no StrategyFactory) ──
        strategy = _cloneStrategy();
        assertEq(strategy.vault(), address(vault), "strategy.vault");
        assertEq(strategy.proposer(), agent, "strategy.proposer");
        assertEq(strategy.tokenId(), 0, "tokenId should be 0 pre-execute");
        assertEq(strategy.targetLtvBps(), TARGET_LTV_BPS, "targetLtv wired");
        assertEq(strategy.maxLtvBps(), MAX_LTV_BPS, "maxLtv wired");
        assertEq(strategy.minHealthBps(), MIN_HEALTH_BPS, "minHealth wired");

        // ── Step 3: propose → vote → execute ──
        _proposeVoteExecute();

        // Execute deployed the levered book.
        assertEq(governor.getActiveProposal(address(vault)), proposalId, "proposal not active");
        assertGt(strategy.tokenId(), 0, "tokenId 0 after execute");
        assertGt(ICToken(MUSDC).balanceOf(address(strategy)), 0, "no mUSDC collateral");
        assertGt(IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy)), 0, "no cbBTC borrow");
        assertGt(IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy)), 0, "no WETH borrow");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault float not drained into strategy");
        assertGt(strategy.nav(), 0, "nav 0 after execute");

        // ── Step 4: lock semantics (the key integration property) ──
        assertTrue(vault.redemptionsLocked(), "vault must be locked while a proposal is active");
        _assertVaultNativeFlowReverts();
        // (strategy.deposit / strategy.redeem are exercised — and proven to WORK — in step 5)

        // ── Step 5: exercise management through the real stack ──
        _exerciseStrategyDeposits(); // depA + depB strategy.deposit (shares at nav, auto-delegated)
        _exerciseDeployIdle(); // proposer deploys the idle deposits into the position
        _exerciseCompound(); // claim+swap AERO (dealt) → redeploy
        _exerciseRerange(); // shove tick (in-band) then recenter
        _exerciseDeleverage(); // mock feed → unhealthy → permissionless deleverage
        _exercisePartialRedeem(); // approval-gated oracle-free partial redeem

        // ── Step 6: settle (proposer self-settle after MIN_STRATEGY_DURATION_BEFORE_SELF_SETTLE) ──
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        uint256 vaultUsdcBeforeSettle = IERC20(USDC).balanceOf(address(vault));

        vm.prank(agent); // proposer
        governor.settleProposal(proposalId);

        // Position fully cleared.
        assertEq(strategy.tokenId(), 0, "tokenId not cleared after settle");
        assertEq(IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy)), 0, "cbBTC debt after settle");
        assertEq(IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy)), 0, "WETH debt after settle");
        // Realized USDC returned to the vault.
        assertGt(IERC20(USDC).balanceOf(address(vault)), vaultUsdcBeforeSettle, "vault not refilled at settle");
        // Lock released.
        assertEq(governor.getActiveProposal(address(vault)), 0, "active proposal not cleared");
        assertFalse(vault.redemptionsLocked(), "vault still locked after settle");

        // Vault-native deposit/redeem work again.
        _assertVaultNativeFlowWorks();
    }

    // ─────────────────────────────────────────────────────────────
    // Lifecycle helpers
    // ─────────────────────────────────────────────────────────────

    function _proposeVoteExecute() internal {
        ISyndicateGovernor.GovernorParams memory gp = governor.getGovernorParams();

        // Agent performance fee is a vault property — owner sets it before proposing.
        vm.prank(vaultOwner);
        vault.setAgentFeeBps(PERF_FEE_BPS);

        (BatchExecutorLib.Call[] memory exec, BatchExecutorLib.Call[] memory settle) = _proposalCalls(address(strategy));

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault), address(strategy), "ipfs://e2e", STRATEGY_DURATION, exec, settle, _noCoProposers()
        );

        // Not active yet (still Pending) — vault not locked.
        assertFalse(vault.redemptionsLocked(), "vault locked before execute");

        // Snapshot in the past, then vote For.
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);

        // Close the vote window → cold-start auto-pass (reviewPeriod==0) → Approved.
        vm.warp(vm.getBlockTimestamp() + gp.votingPeriod + 1);
        governor.executeProposal(proposalId);
    }

    /// @dev execCalls move the vault float into the clone (executeImpl supplies the clone's
    ///      OWN balance), then call execute(); settleCalls call settle().
    function _proposalCalls(address clone)
        internal
        pure
        returns (BatchExecutorLib.Call[] memory exec, BatchExecutorLib.Call[] memory settle)
    {
        exec = new BatchExecutorLib.Call[](2);
        exec[0] =
            BatchExecutorLib.Call({target: USDC, data: abi.encodeCall(IERC20.transfer, (clone, PRINCIPAL)), value: 0});
        exec[1] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("execute()"), value: 0});

        settle = new BatchExecutorLib.Call[](1);
        settle[0] = BatchExecutorLib.Call({target: clone, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    /// @dev While a proposal is active: vault-native deposit/mint revert (deposits locked),
    ///      and vault-native redeem/withdraw revert (maxRedeem/maxWithdraw == 0, Lane A off).
    ///      The strategy's own deposit/redeem are the only LP lane (exercised in step 5).
    function _assertVaultNativeFlowReverts() internal {
        // Value-level lock proof: instant-exit caps are 0 (no Lane A live-NAV).
        assertEq(vault.maxRedeem(lp1), 0, "maxRedeem != 0 while locked");
        assertEq(vault.maxWithdraw(lp1), 0, "maxWithdraw != 0 while locked");

        // Native deposit + mint revert (DepositsLocked: an open proposal binds the vault).
        _fundUSDC(stranger, 2_000e6);
        vm.startPrank(stranger);
        IERC20(USDC).approve(address(vault), 2_000e6);
        vm.expectRevert();
        vault.deposit(1_000e6, stranger);
        vm.expectRevert();
        vault.mint(1e12, stranger);
        vm.stopPrank();

        // Native redeem + withdraw revert (capped to 0 by maxRedeem / maxWithdraw).
        uint256 lp1Shares = vault.balanceOf(lp1);
        vm.startPrank(lp1);
        vm.expectRevert();
        vault.redeem(lp1Shares, lp1, lp1);
        vm.expectRevert();
        vault.withdraw(1e6, lp1, lp1);
        vm.stopPrank();
    }

    /// @dev Two LPs deposit straight into the strategy (the only LP lane while locked):
    ///      shares mint proportional to oracle NAV, USDC lands idle in the strategy, and the
    ///      depositor is auto-delegated to self for voting power.
    function _exerciseStrategyDeposits() internal {
        _strategyDeposit(depA, 1_000e6);
        _strategyDeposit(depB, 1_000e6);
    }

    function _strategyDeposit(address who, uint256 amt) internal {
        _fundUSDC(who, amt);
        uint256 navBefore = strategy.nav();
        uint256 supplyBefore = vault.totalSupply();
        uint256 idleBefore = IERC20(USDC).balanceOf(address(strategy));

        vm.startPrank(who);
        IERC20(USDC).approve(address(strategy), amt);
        uint256 shares = strategy.deposit(amt, 0);
        vm.stopPrank();

        assertGt(shares, 0, "strategy.deposit minted 0 shares");
        assertEq(vault.balanceOf(who), shares, "depositor share balance mismatch");
        // Shares minted at oracle NAV (≈ amt * supply / nav). Tolerance covers the tiny
        // management-fee crystallise that mints a sliver to feeRecipient first.
        uint256 expected = (amt * supplyBefore) / navBefore;
        assertApproxEqRel(shares, expected, 2e16, "shares not minted at oracle nav (>2% off)"); // 2%
        // USDC lands idle in the strategy (not pushed to the vault).
        assertEq(IERC20(USDC).balanceOf(address(strategy)), idleBefore + amt, "deposit not idle in strategy");
        // Auto-delegated to self.
        assertEq(vault.delegates(who), who, "depositor not auto-delegated to self");
    }

    /// @dev Proposer deploys all idle (the two deposits) into the levered position.
    function _exerciseDeployIdle() internal {
        uint256 idle = IERC20(USDC).balanceOf(address(strategy));
        assertGt(idle, 0, "no idle USDC to deploy");
        uint256 navBefore = strategy.nav();

        vm.prank(agent);
        strategy.deployIdle(idle, 0);

        assertLt(IERC20(USDC).balanceOf(address(strategy)), 1e6, "idle not deployed");
        // NAV approximately conserved (idle USDC → levered LP; no realized swap on add).
        assertApproxEqRel(strategy.nav(), navBefore, 2e16, "nav not conserved across deployIdle"); // 2%
    }

    /// @dev Proposer compounds a (dealt) AERO reward: claim → AERO→USDC swap → redeploy. NAV ↑.
    function _exerciseCompound() internal {
        uint256 aeroReward = 20_000e18; // ≈ $7.1k at ~$0.357/AERO
        deal(BaseAddresses.AERO, address(strategy), aeroReward);
        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), aeroReward, "AERO not funded");

        uint256 navBefore = strategy.nav();
        vm.prank(agent);
        strategy.compound(6_000e6, 0); // minUsdcOut 6k

        assertEq(IERC20(BaseAddresses.AERO).balanceOf(address(strategy)), 0, "AERO not fully swapped");
        // Compounding realizes yield into the book → NAV rises.
        assertGt(strategy.nav(), navBefore, "nav did not rise after compound");
    }

    /// @dev Proposer recenters after an in-band (300-tick, inside the 500-tick calm gate)
    ///      tick drift: a new NFT is minted and staked; Moonwell debt/collateral untouched.
    function _exerciseRerange() internal {
        (, int24 tickStart,,,,) = ICLPool(POOL).slot0();
        _shoveToTick(tickStart - 300);
        (, int24 tickShoved,,,,) = ICLPool(POOL).slot0();
        assertLt(tickShoved, tickStart, "shove did not move tick down");

        uint256 tidBefore = strategy.tokenId();
        uint256 cbDebtBefore = IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy));

        vm.prank(agent);
        strategy.rerange(0, 0);

        uint256 tidAfter = strategy.tokenId();
        assertTrue(tidAfter != tidBefore && tidAfter != 0, "rerange did not rotate to a recentered NFT");
        assertEq(IERC721(NPM).ownerOf(tidAfter), GAUGE, "recentered NFT not staked in gauge");
        // rerange never touches Moonwell.
        assertEq(IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy)), cbDebtBefore, "cbBTC debt moved");
        assertEq(IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy)), wethDebtBefore, "WETH debt moved");
    }

    /// @dev Permissionless safety valve: an adverse cbBTC move (mock BTC/USD ×3) pushes
    ///      our-oracle health < minHealthBps; ANY caller (here a stranger) may deleverage.
    function _exerciseDeleverage() internal {
        _mockBtcScaled(3, 1); // net-short cbBTC debt value triples → health falls below min
        uint256 cbDebtBefore = IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy));
        uint256 wethDebtBefore = IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy));

        vm.prank(stranger);
        strategy.deleverage(0);

        // Debt repaid down on both legs (recovery op).
        assertLt(IMoonwellMarket(MCBBTC).borrowBalanceStored(address(strategy)), cbDebtBefore, "cbBTC not repaid");
        assertLt(IMoonwellMarket(MWETH).borrowBalanceStored(address(strategy)), wethDebtBefore, "WETH not repaid");

        // Position now healthy again → a second deleverage reverts.
        vm.prank(stranger);
        vm.expectRevert(LeveragedAerodromeCLStrategy.HealthyNoDeleverage.selector);
        strategy.deleverage(0);

        // Restore live feeds for the settle sweep.
        vm.clearMockedCalls();
    }

    /// @dev Approval-gated, oracle-free partial redeem: an LP burns half their shares for
    ///      pro-rata USDC. Without the prior `vault.approve(strategy, shares)` it reverts.
    function _exercisePartialRedeem() internal {
        uint256 lp1Shares = vault.balanceOf(lp1);
        assertGt(lp1Shares, 0, "lp1 holds no shares");
        uint256 redeemShares = lp1Shares / 2;
        uint256 usdcBefore = IERC20(USDC).balanceOf(lp1);

        // Without approval → safeTransferFrom of the shares reverts.
        vm.prank(lp1);
        vm.expectRevert();
        strategy.redeem(redeemShares, 0);

        // Approve the strategy to pull the shares, then redeem.
        vm.prank(lp1);
        IERC20(address(vault)).approve(address(strategy), redeemShares);
        vm.prank(lp1);
        uint256 assetsOut = strategy.redeem(redeemShares, 0);

        assertGt(assetsOut, 0, "partial redeem returned 0 USDC");
        assertEq(IERC20(USDC).balanceOf(lp1), usdcBefore + assetsOut, "lp1 did not receive the USDC");
        assertEq(vault.balanceOf(lp1), lp1Shares - redeemShares, "lp1 shares not burned");
    }

    /// @dev After settle the vault is unlocked: instant deposit + redeem work natively again.
    function _assertVaultNativeFlowWorks() internal {
        _fundUSDC(stranger, 1_000e6);
        vm.startPrank(stranger);
        IERC20(USDC).approve(address(vault), 1_000e6);
        uint256 sh = vault.deposit(1_000e6, stranger);
        vm.stopPrank();
        assertGt(sh, 0, "native deposit minted 0 after unlock");

        uint256 r = vault.maxRedeem(lp2);
        assertGt(r, 0, "maxRedeem 0 after unlock");
        vm.prank(lp2);
        uint256 out = vault.redeem(r, lp2, lp2);
        assertGt(out, 0, "native redeem returned 0 after unlock");
    }

    // ─────────────────────────────────────────────────────────────
    // Strategy clone + init
    // ─────────────────────────────────────────────────────────────

    function _cloneStrategy() internal returns (LeveragedAerodromeCLStrategy s) {
        address template = address(new LeveragedAerodromeCLStrategy());
        address clone = Clones.clone(template);
        s = LeveragedAerodromeCLStrategy(payable(clone));
        s.initialize(address(vault), agent, abi.encode(_initParams()));
    }

    function _initParams() internal view returns (LeveragedAerodromeCLStrategy.InitParams memory p) {
        p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: BaseAddresses.USDC,
            mUsdc: BaseAddresses.MOONWELL_MUSDC,
            mCbBTC: BaseAddresses.MOONWELL_MCBBTC,
            mWeth: BaseAddresses.MOONWELL_MWETH,
            comptroller: BaseAddresses.MOONWELL_COMPTROLLER,
            cbBTC: BaseAddresses.CBBTC,
            weth: BaseAddresses.WETH,
            pool: BaseAddresses.CBBTC_WETH_POOL,
            npm: BaseAddresses.SLIPSTREAM_NPM,
            gauge: BaseAddresses.CBBTC_WETH_GAUGE,
            swapRouter: BaseAddresses.SLIPSTREAM_CL_SWAP_ROUTER,
            cbBTCFeed: BaseAddresses.CHAINLINK_BTC_USD,
            wethFeed: BaseAddresses.CHAINLINK_ETH_USD,
            usdcFeed: BaseAddresses.CHAINLINK_USDC_USD,
            sequencerFeed: BaseAddresses.SEQUENCER_UPTIME_FEED,
            maxDelay: 48 hours, // generous: covers the ~2h lifecycle without per-step feed mocks
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: BaseAddresses.CBBTC_WETH_TICK_SPACING,
            targetLtvBps: TARGET_LTV_BPS,
            maxLtvBps: MAX_LTV_BPS,
            minHealthBps: MIN_HEALTH_BPS,
            maxSlippageBps: MAX_SLIPPAGE_BPS,
            managementFeeBps: MGMT_FEE_BPS,
            performanceFeeBps: PERF_FEE_BPS,
            feeRecipient: feeRecipient
        });
    }

    // ─────────────────────────────────────────────────────────────
    // Local fork utilities (copied from the rerange / leverage suites)
    // ─────────────────────────────────────────────────────────────

    /// @dev Bounded in-band shove: sell WETH→cbBTC, stopping at `targetTick` via
    ///      sqrtPriceLimitX96 so the move lands deterministically inside the calm band.
    function _shoveToTick(int24 targetTick) internal {
        address shover = makeAddr("inband_shover");
        uint256 wethIn = 1_000e18; // generous; the price limit caps how much actually fills
        _fundWETH(shover, wethIn);
        vm.startPrank(shover);
        IERC20(WETH).approve(CL_ROUTER, wethIn);
        ICLSwapRouter(CL_ROUTER)
            .exactInputSingle(
                ICLSwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: CBBTC,
                tickSpacing: TICK_SPACING,
                recipient: shover,
                deadline: vm.getBlockTimestamp() + 600,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(targetTick)
            })
            );
        vm.stopPrank();
    }

    /// @dev Mock the cbBTC (BTC/USD) feed to `num/den` × its real answer, preserving the
    ///      real (fresh) round metadata so the hardened staleness checks still pass.
    function _mockBtcScaled(uint256 num, uint256 den) internal {
        address feed = BaseAddresses.CHAINLINK_BTC_USD;
        (uint80 rid, int256 ans, uint256 startedAt, uint256 updatedAt, uint80 air) = IAggE2E(feed).latestRoundData();
        int256 scaled = (ans * int256(num)) / int256(den);
        vm.mockCall(
            feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(rid, scaled, startedAt, updatedAt, air)
        );
    }

    function _noCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }
}
