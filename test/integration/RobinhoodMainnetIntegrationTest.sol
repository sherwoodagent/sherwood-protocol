// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {DeploySherwood} from "../../script/Deploy.s.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";

// LEGACY pin (US market hours, 2026-07-08 ~15:10 UTC). DEAD ON THE PUBLIC RPC:
// `https://rpc.mainnet.chain.robinhood.com` is pruned and serves state only for
// roughly the last 5k-50k blocks (head was ~34.9M on 2026-08-12), so a fork at
// this block returns `error code -32000` for every state read. Kept only because
// `UniswapAdapterRobinhoodForkTest` still imports it; this harness no longer
// uses it as a default — see the ROBINHOOD_FORK_BLOCK env var.
uint256 constant ROBINHOOD_FORK_BLOCK = 4_453_020;

/// @dev Minimal Chainlink AggregatorV3 surface, declared locally so the harness
///      does not have to import a strategy just to read a feed clock.
interface IAggregatorV3Clock {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/**
 * @title RobinhoodMainnetIntegrationTest
 * @notice Abstract base for fork-based integration tests against Robinhood Chain
 *         mainnet (chain 4663). Nothing of ours is deployed there yet, so the
 *         full Sherwood stack is deployed fresh on the fork in setUp (mirroring
 *         the deploy script), then a test syndicate is created with USDG as the
 *         vault asset.
 *
 *         Robinhood mainnet facts:
 *           - USDG (6 dec) is the canonical stable — there is no USDC.
 *           - Official Uniswap v3 (SwapRouter02 + QuoterV2).
 *           - Chainlink push feeds (AggregatorV3, 8 dec, 24h heartbeat).
 *           - No ENS / ERC-8004 → factory gets address(0) for both.
 *
 * @dev Skips if ROBINHOOD_RPC_URL is not set (shared fork-test convention).
 *
 *      RPC REALITY (verified on-chain 2026-08-12 — trust this over any older
 *      comment):
 *        - The public RPC `https://rpc.mainnet.chain.robinhood.com` is chainid
 *          4663 and PRUNED. State reads work only for roughly the last
 *          5,000–50,000 blocks behind head (~34.9M on 2026-08-12). Any historic
 *          pin (including the legacy `ROBINHOOD_FORK_BLOCK` constant above)
 *          fails with `error code -32000`. Forking at LATEST is therefore the
 *          only thing that works against the public endpoint — which is why the
 *          default here is "latest", not a pin.
 *        - Archive state comes from a Tenderly virtual testnet. It serves the
 *          same addresses but reports chainid 9994663, hence the
 *          ROBINHOOD_FORK_CHAIN_ID override. Its `block.timestamp` also lags the
 *          live Chainlink feeds' `updatedAt` by weeks, which underflows any
 *          `block.timestamp - updatedAt` age math — `_normalizeFeedClock()`
 *          warps past that skew in setUp.
 *
 *      Env vars read here:
 *        ROBINHOOD_RPC_URL       required; empty → the suite skips.
 *        ROBINHOOD_FORK_BLOCK    default 0 = fork at LATEST. Set to pin.
 *        ROBINHOOD_FORK_CHAIN_ID default 4663. Set 9994663 for the Tenderly vnet.
 *      (`script/robinhood-mainnet/Deploy.s.sol` uses the same
 *      ROBINHOOD_FORK_CHAIN_ID convention.)
 *
 *      Run explicitly:
 *        set -a; source .env; set +a
 *        export ROBINHOOD_RPC_URL="$TENDERLY_ROBINHOOD_RPC_URL"
 *        export ROBINHOOD_FORK_CHAIN_ID=9994663
 *        forge test --match-path \
 *          "test/integration/strategies/PortfolioMainnetFork.t.sol" -vv
 */
abstract contract RobinhoodMainnetIntegrationTest is Test {
    // ── Robinhood Chain mainnet addresses ──
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    // Official Uniswap v3.
    address constant UNISWAP_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant UNISWAP_SWAP_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant UNISWAP_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;

    // Uniswap v4 (hookless stock-token pools live here).
    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;

    // Tokenized stock (traded via v4).
    address constant TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    // Chainlink push feeds (AggregatorV3, 8 dec).
    address constant CHAINLINK_ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address constant CHAINLINK_USDG_USD_FEED = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address constant CHAINLINK_TSLA_USD_FEED = 0x4A1166a659A55625345e9515b32adECea5547C38;

    // Liquid v3 pools (verified on-chain): USDG/WETH fee 500 and fee 3000.
    uint24 constant FEE_500 = 500;
    uint24 constant FEE_3000 = 3000;
    // Live TSLA/USDG v4 pool: 5% fee, tickSpacing 1000, hookless.
    uint24 constant V4_FEE_50000 = 50_000;
    int24 constant V4_TICK_SPACING_1000 = 1000;

    // ── Test actors ──
    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    // ── Deployed protocol (fresh on fork) ──
    SyndicateGovernor governor;
    SyndicateFactory factory;
    GuardianRegistry registry;
    StakedWood swood;
    ERC20Mock wood;
    address vaultImpl;
    address executorLib;
    address deployer;
    /// @dev Owned by `deployer` (see `_deployProtocol`) — the same address a
    ///      real deploy hands to the multisig via `TierRegistry.
    ///      transferOwnership`. Resolved here so fork suites can allowlist
    ///      swap adapters / strategy clones (issue #147; see `_cloneAndInit`).
    address tierRegistry;

    uint256 constant MIN_OWNER_STAKE = 10_000e18;

    // ── Per-test syndicate ──
    SyndicateVault vault;
    uint256 agentNftId = 42;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // 0 (the default) means "fork at latest" — the only mode the pruned
        // public RPC supports. A nonzero value pins, for an archive endpoint.
        uint256 forkBlock = vm.envOr("ROBINHOOD_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpc);
        } else {
            vm.createSelectFork(rpc, forkBlock);
        }
        uint256 expectedChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(4663));
        require(
            block.chainid == expectedChainId,
            string.concat(
                "wrong chain: got ",
                vm.toString(block.chainid),
                ", expected ",
                vm.toString(expectedChainId),
                " (set ROBINHOOD_FORK_CHAIN_ID for a Tenderly vnet)"
            )
        );
        _normalizeFeedClock();

        wood = new ERC20Mock("Wood", "WOOD", 18);
        _deployProtocol();
        _wireOracleAllowlist();
        _bondOwnerStake();
        _createSyndicate();
        _fundAndDeposit(10_000e6, 10_000e6); // 10k USDG each

        // Warp 1s so the deposit snapshot is in the past for voting.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    /// @notice Warp the fork clock past any Chainlink feed whose `updatedAt`
    ///         lies in the FUTURE relative to `block.timestamp`.
    /// @dev The Tenderly archive vnet's block clock runs ~35 days behind the
    ///      live feeds it serves, so `block.timestamp - updatedAt` underflows
    ///      (it does so in `_assertFeedHealthy` in the Portfolio fork suite, and
    ///      in any age math a downstream suite writes). `PortfolioStrategy`
    ///      itself clamps that case to age 0 (`_feedPriceX8`:
    ///      `block.timestamp > updatedAt ? block.timestamp - updatedAt : 0`), so
    ///      the contracts survive it — the TESTS are what break.
    ///
    ///      Warps to `maxUpdatedAt + 1`, i.e. the freshest instant at which
    ///      every feed is already published. That leaves each feed with an age
    ///      of at most the spread BETWEEN feeds, which is what a sane fork
    ///      looks like anyway; it never manufactures freshness a feed does not
    ///      have relative to its peers.
    ///
    ///      NO-OP on a fork whose clock is at or ahead of every feed (the
    ///      normal public-RPC case): the condition is `maxUpdatedAt >=
    ///      block.timestamp`, so nothing moves and time never runs backwards
    ///      (`vm.warp` backwards is a silent no-op in forge 1.7.1 anyway).
    function _normalizeFeedClock() internal {
        address[3] memory feeds = [CHAINLINK_ETH_USD_FEED, CHAINLINK_USDG_USD_FEED, CHAINLINK_TSLA_USD_FEED];
        uint256 maxUpdatedAt;
        for (uint256 i = 0; i < feeds.length; ++i) {
            try IAggregatorV3Clock(feeds[i]).latestRoundData() returns (
                uint80, int256, uint256, uint256 updatedAt, uint80
            ) {
                if (updatedAt > maxUpdatedAt) maxUpdatedAt = updatedAt;
            } catch {
                // Feed absent on this fork — nothing to normalize against.
            }
        }
        uint256 nowTs = vm.getBlockTimestamp();
        if (maxUpdatedAt >= nowTs) {
            console2.log("fork clock behind Chainlink feeds; warping forward by (s):", maxUpdatedAt + 1 - nowTs);
            vm.warp(maxUpdatedAt + 1);
        }
    }

    function _deployProtocol() internal {
        DeploySherwood deployScript = new DeploySherwood();
        DeploySherwood.Config memory cfg = DeploySherwood.Config({
            ensRegistrar: address(0),
            agentRegistry: address(0),
            managementFeeBps: 50,
            maxStrategyDays: 14,
            votingPeriod: 1 days,
            woodToken: address(wood),
            slashAppealSeed: 0,
            epochZeroSeed: 0
        });
        // deployCore's internal c3.deploy calls run as the script address, so
        // prank as the script to keep the Create3Factory owner consistent.
        vm.prank(address(deployScript));
        DeploySherwood.Deployed memory d = deployScript.deployCore(cfg);

        // `governor` is per-vault — bound in `_createSyndicate` once the factory
        // has minted this vault's BeaconProxy governor.
        factory = SyndicateFactory(d.factoryProxy);
        registry = GuardianRegistry(d.registryProxy);
        swood = StakedWood(d.swoodProxy);
        vaultImpl = d.vaultImpl;
        executorLib = d.executorLib;
        deployer = d.deployer;
        tierRegistry = d.tierRegistry;
    }

    /// @notice Governance-attest a Chainlink push feed as a usable price source
    ///         for `token`, exactly as a real deploy would.
    /// @dev `PortfolioStrategy` gates oracles TWICE against the vault's
    ///      TierRegistry (`vault -> governor -> tierRegistry`):
    ///        1. `_requireAllowedPriceSource` — is this oracle allowed AT ALL
    ///           (`isAdapterAllowed`); reverts `PriceSourceNotAllowed`.
    ///        2. `_requireAllowedPriceSourceForToken` — is it attested for THIS
    ///           token (`isPriceSourceForToken`), keyed by the feed address
    ///           widened to bytes32 with any packed max-age stripped, so one
    ///           attestation covers every staleness variant of the same feed.
    ///      Both default to FALSE on a freshly deployed registry, so a fork stack
    ///      that skips this cannot initialize any priced strategy.
    function _allowPriceSource(address feed, address token) internal {
        vm.startPrank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(feed, true);
        TierRegistry(tierRegistry).setPriceSourceForToken(token, bytes32(uint256(uint160(feed))), true);
        vm.stopPrank();
    }

    /// @dev Attests the three live Robinhood push feeds for the tokens they
    ///      actually price. Deliberately NOT a blanket allow: a test that wires
    ///      the wrong feed to a token must still fail.
    function _wireOracleAllowlist() internal {
        _allowPriceSource(CHAINLINK_ETH_USD_FEED, WETH);
        _allowPriceSource(CHAINLINK_TSLA_USD_FEED, TSLA);
        _allowPriceSource(CHAINLINK_USDG_USD_FEED, USDG);
    }

    function _bondOwnerStake() internal {
        wood.mint(owner, MIN_OWNER_STAKE);
        vm.startPrank(owner);
        wood.approve(address(swood), type(uint256).max);
        swood.prepareOwnerStake(MIN_OWNER_STAKE);
        vm.stopPrank();
    }

    function _createSyndicate() internal {
        SyndicateFactory.SyndicateConfig memory config = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://robinhood-mainnet-fork-test",
            asset: IERC20(USDG),
            name: "Robinhood Mainnet Fork Vault",
            symbol: "rmfUSDG",
            openDeposits: true,
            subdomain: "robinhood-mainnet-fork"
        });

        vm.prank(owner);
        (, address vaultAddr) = factory.createSyndicate(agentNftId, config);
        vault = SyndicateVault(payable(vaultAddr));
        governor = SyndicateGovernor(factory.governorOf(vaultAddr));

        vm.prank(owner);
        vault.registerAgent(43, agent);
    }

    /// @dev USDG is a plain ERC-20 — `deal` works. If a future USDG variant
    ///      breaks `deal`, this is the single choke point to patch.
    function _dealUSDG(address to, uint256 amount) internal {
        deal(USDG, to, amount);
    }

    function _fundAndDeposit(uint256 lp1Amount, uint256 lp2Amount) internal {
        _dealUSDG(lp1, lp1Amount);
        _dealUSDG(lp2, lp2Amount);

        vm.startPrank(lp1);
        IERC20(USDG).approve(address(vault), lp1Amount);
        vault.deposit(lp1Amount, lp1);
        vm.stopPrank();

        vm.startPrank(lp2);
        IERC20(USDG).approve(address(vault), lp2Amount);
        vault.deposit(lp2Amount, lp2);
        vm.stopPrank();
    }

    function _cloneAndInit(address template, bytes memory initData) internal returns (address clone) {
        clone = Clones.clone(template);
        (bool success,) =
            clone.call(abi.encodeWithSignature("initialize(address,address,bytes)", address(vault), agent, initData));
        require(success, "Strategy initialization failed");
        // PRE-EXISTING fix, not fallout of issue #147: `_guardBatchCalls`
        // (guard + registry wiring landed 9fafa00, post-dating this suite;
        // RPC gating hid it) requires the strategy CLONE itself to be
        // allowlisted before a governor batch's `asset.approve(strategy,
        // amount)` can pass. Callers allowlist the SWAP ADAPTER separately,
        // before this function runs, since #147's `_requireAllowedAdapter`
        // check is enforced synchronously inside `initialize` above.
        vm.prank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(clone, true);
    }

    /// @dev Propose → vote → open+resolve guardian review → execute, labelling
    ///      the proposal with the LAST exec call's target as its strategy.
    ///
    ///      THAT LABEL IS LOAD-BEARING, not cosmetic. Issue #150 gave
    ///      `BaseStrategy.execute()` an active-proposal binding: it resolves
    ///      `vault -> governor` and reverts `NotActiveProposalStrategy()` unless
    ///      `strategyOf(getActiveProposal()) == address(this)`. This harness
    ///      previously proposed with `address(0)`, so every strategy fork test
    ///      reverted at the execute leg. The last exec call is already assumed
    ///      to be the mover by the cap convention just below, and for the
    ///      `[approve(strategy, amount), strategy.execute()]` shape every suite
    ///      here uses, that target IS the strategy.
    ///
    ///      Use `_proposeVoteExecuteFor` when the mover is not the last call, or
    ///      for a queue-only proposal that should carry no strategy
    ///      (`address(0)`).
    function _proposeVoteExecute(
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256 feeBps,
        uint256 duration
    ) internal returns (uint256 proposalId) {
        address strategy = execCalls.length > 0 ? execCalls[execCalls.length - 1].target : address(0);
        return _proposeVoteExecuteFor(strategy, execCalls, settleCalls, feeBps, duration);
    }

    /// @dev As `_proposeVoteExecute`, with the proposal's strategy label given
    ///      explicitly. The cohort is empty (no guardians staked), so
    ///      `resolveReview` short-circuits via the cold-start / cohortTooSmall
    ///      path and the proposal executes.
    function _proposeVoteExecuteFor(
        address strategy,
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256 feeBps,
        uint256 duration
    ) internal returns (uint256 proposalId) {
        vm.prank(owner);
        vault.setAgentFeeBps(feeBps);

        // Issue #43: `PortfolioMainnetForkTest`'s exec batch is
        // `[approve(strategy, amount), strategy.execute()]` — the MOVER
        // (`execute()`) is at the LAST index, not the first, so the generic
        // `GovEnvelope.defaultCaps` convention (cap the FIRST call) would
        // zero-cap the actual mover and trip `CallCapExceeded`. Cap the LAST
        // exec call instead; the settle batch here is single-call, so first
        // and last coincide and the generic default stays correct for it.
        uint256 maxCapital = GovEnvelope.permissive(address(vault)).maxCapital;
        uint256[] memory execCaps = new uint256[](execCalls.length);
        if (execCalls.length > 0) execCaps[execCalls.length - 1] = maxCapital;

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy,
            "ipfs://rh-mainnet-test",
            duration,
            GovEnvelope.permissive(address(vault)),
            execCalls,
            execCaps,
            settleCalls,
            GovEnvelope.defaultCaps(maxCapital, settleCalls.length),
            _emptyCoProposers()
        );

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);

        ISyndicateGovernor.GovernorParams memory params = governor.getGovernorParams();
        vm.warp(vm.getBlockTimestamp() + params.votingPeriod + 1);

        registry.openReview(address(governor), proposalId);
        uint256 reviewPeriod = registry.reviewPeriod();
        vm.warp(vm.getBlockTimestamp() + reviewPeriod + 1);
        registry.resolveReview(address(governor), proposalId);

        governor.executeProposal(proposalId);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }

    // ==================== DEPOSITOR EXIT / ENTRY HELPERS ====================
    //
    // The real exit surface on this branch (read from src/SyndicateVault.sol and
    // src/queue/VaultWithdrawalQueue.sol — do not guess at names):
    //
    //  INSTANT (ERC-4626 `withdraw` / `redeem`), open only BETWEEN proposals:
    //    `maxWithdraw`/`maxRedeem` return 0 while `redemptionsLocked()` (i.e.
    //    while the governor reports an active proposal) or while `paused()`, and
    //    are otherwise capped by idle float minus the queue's reserved assets.
    //    `_withdraw` additionally reverts `QueueReserveBreached` if the draw
    //    would eat into that reserve. There is NO strategy pull: an amount
    //    beyond idle float simply cannot be withdrawn instantly.
    //
    //  QUEUED / ASYNC, open only DURING a proposal:
    //    redeem  : `vault.requestRedeem(shares, owner)` — requires
    //              `redemptionsLocked() == true`; escrows the SHARES in the
    //              queue (transfer, not burn) tagged to the active pid.
    //    deposit : `vault.requestDeposit(assets, receiver)` — gated on the
    //              governor's `openProposalCount() != 0`, which is a WIDER
    //              window than `redemptionsLocked()` (it covers Pending/Review
    //              too); escrows the ASSETS in the queue, off-vault.
    //    settle  : the governor's settlement calls `vault.onProposalSettled`,
    //              which calls `queue.stampSettlement(pid, num, den)` and
    //              freezes one price per proposal. Nothing is claimable before
    //              that stamp.
    //    claim   : `queue.claim(requestId)` — permissionless, but requires the
    //              relevant stamp AND `redemptionsLocked() == false`, so claims
    //              land only in the gap BETWEEN proposals. Redeem claims price
    //              at their own pid's stamp; deposit claims price at the LATEST
    //              stamp.
    //    cancel  : `queue.cancel(requestId)` — owner-only, and ONLY before the
    //              price this claim would use is stamped (exact complement of
    //              `claim`'s gate).
    //
    //  Ordering that actually works for a queued redeem:
    //    execute proposal -> requestRedeem -> settleProposal -> claim.

    /// @notice The per-vault async queue (deployed and bound by the factory in
    ///         `createSyndicate`, so it is always set for a harness vault).
    function _queue() internal view returns (IVaultWithdrawalQueue) {
        return IVaultWithdrawalQueue(vault.withdrawalQueue());
    }

    /// @notice Instant ERC-4626 redeem of `shares` (between proposals only).
    /// @return assetsOut assets actually paid to `who`.
    function _instantRedeem(address who, uint256 shares) internal returns (uint256 assetsOut) {
        vm.prank(who);
        assetsOut = vault.redeem(shares, who, who);
    }

    /// @notice Instant redeem of everything `maxRedeem` currently allows.
    /// @dev Returns (0,0) when the instant path is shut (locked / no float) —
    ///      callers that care must assert on `sharesRedeemed` themselves rather
    ///      than treating a silent zero as success.
    function _instantRedeemMax(address who) internal returns (uint256 sharesRedeemed, uint256 assetsOut) {
        sharesRedeemed = vault.maxRedeem(who);
        if (sharesRedeemed == 0) return (0, 0);
        vm.prank(who);
        assetsOut = vault.redeem(sharesRedeemed, who, who);
    }

    /// @notice Instant ERC-4626 withdraw of an exact `assets` amount.
    /// @return sharesBurned shares burned from `who`.
    function _instantWithdraw(address who, uint256 assets) internal returns (uint256 sharesBurned) {
        vm.prank(who);
        sharesBurned = vault.withdraw(assets, who, who);
    }

    /// @notice Queue an async redeem (requires an ACTIVE proposal — reverts
    ///         `RedemptionsNotLocked` otherwise).
    function _requestRedeem(address who, uint256 shares) internal returns (uint256 requestId) {
        vm.prank(who);
        requestId = vault.requestRedeem(shares, who);
    }

    /// @notice Queue an async deposit (requires an OPEN proposal — reverts
    ///         `NoOpenProposal` otherwise). The vault pulls the assets straight
    ///         into queue custody, so the approval is owner → vault.
    function _requestDeposit(address who, uint256 assets) internal returns (uint256 requestId) {
        address asset_ = vault.asset();
        vm.startPrank(who);
        IERC20(asset_).approve(address(vault), assets);
        requestId = vault.requestDeposit(assets, who);
        vm.stopPrank();
    }

    /// @notice Claim a settled queue request. Permissionless by design — proceeds
    ///         always go to the request's recorded owner, never to the caller —
    ///         so `caller` is a parameter, not an assumption.
    /// @return outAmount assets (Redeem) or shares (Deposit) delivered to the owner.
    function _claimQueued(address caller, uint256 requestId) internal returns (uint256 outAmount) {
        IVaultWithdrawalQueue q = _queue();
        vm.prank(caller);
        outAmount = q.claim(requestId);
    }

    /// @notice Cancel an unstamped queue request (owner-only).
    function _cancelQueued(address who, uint256 requestId) internal {
        IVaultWithdrawalQueue q = _queue();
        vm.prank(who);
        q.cancel(requestId);
    }

    // ==================== CONSERVATION / ACCOUNTING ASSERTIONS ====================

    /// @notice Assert a strategy stranded nothing: zero balance of every token in
    ///         `tokens`, and zero native ETH.
    function _assertNoDust(address strategy, address[] memory tokens) internal view {
        for (uint256 i = 0; i < tokens.length; ++i) {
            assertEq(
                IERC20(tokens[i]).balanceOf(strategy),
                0,
                string.concat("dust stranded in strategy: token ", vm.toString(tokens[i]))
            );
        }
        assertEq(strategy.balance, 0, "native ETH stranded in strategy");
    }

    /// @notice Assert the vault is not promising more than it holds: the sum of
    ///         every holder's `previewRedeem(balanceOf)` must not exceed
    ///         `totalAssets()`.
    /// @dev The QUEUE MUST NOT be in `holders`, and this reverts if it is. The
    ///      inequality only holds for shares that are still a claim on the pool:
    ///      shares escrowed in the queue against an already-stamped settlement
    ///      are excluded from BOTH `totalAssets()` (their assets are reserved)
    ///      and `_pricingSupply()` (their shares are subtracted), so pricing the
    ///      queue's balance with `previewRedeem` double-counts a claim that has
    ///      already been carved out. With the queue excluded, Σbalances ≤
    ///      pricingSupply and each `previewRedeem` rounds DOWN, so the sum is
    ///      bounded by `totalAssets()` exactly.
    function _assertShareClaimsSolvent(address[] memory holders) internal view {
        address q = vault.withdrawalQueue();
        uint256 sum;
        for (uint256 i = 0; i < holders.length; ++i) {
            require(holders[i] != q, "_assertShareClaimsSolvent: exclude the queue");
            sum += vault.previewRedeem(vault.balanceOf(holders[i]));
        }
        assertLe(sum, vault.totalAssets(), "sum of holder claims exceeds totalAssets");
    }

    /// @notice Current vault price per share (fixed-point per `pricePerShare`).
    function _pricePerShare() internal view returns (uint256) {
        return vault.pricePerShare();
    }

    /// @notice Assert price per share did not fall below `previousPps`.
    /// @dev For no-op / value-neutral transitions only (a claim, a settled
    ///      round-trip that must not dilute holders). A real trading loss legally
    ///      lowers it, so do NOT wrap a strategy execution in this.
    function _assertPpsNotBelow(uint256 previousPps, string memory ctx) internal view {
        assertGe(vault.pricePerShare(), previousPps, string.concat("price per share fell: ", ctx));
    }
}
