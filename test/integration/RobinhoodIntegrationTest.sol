// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {StrategyFactory} from "../../src/StrategyFactory.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";

// Pinned Robinhood L2 testnet fork block. Chosen AFTER today's V2 redeployment
// (2026-07-08) — the full core + strategy stack in chains/46630.json has code
// from ~block 88,751,000, so this pin sits comfortably above the deploy and
// below the chain head at fix time (88,751,996). Pinning keeps Synthra pool
// state + guardian/owner-stake reads deterministic across runs. File-level so
// derived suites can pin identically.
uint256 constant ROBINHOOD_TESTNET_FORK_BLOCK = 88_767_205;

/**
 * @title RobinhoodIntegrationTest
 * @notice Abstract base for fork-based integration tests that drive the LIVE,
 *         freshly deployed V2 Sherwood stack on Robinhood L2 testnet (chain
 *         46630). Unlike the mainnet-fork harness (which deploys the stack
 *         in-test), this harness reads every protocol address from
 *         chains/46630.json and exercises the on-chain deployment directly —
 *         the whole point is to prove the live deployment is sound end-to-end.
 *
 *         Robinhood testnet facts baked in here:
 *           - Vault asset is SYNTHRA_WETH (0x33e4…200B94), the token the Synthra
 *             DEX pools denominate stock pairs in — distinct from the canonical
 *             WETH (0x7943…852Fa), which has almost no Synthra pool liquidity.
 *             Verified live at the pinned block: SYNTHRA_WETH/TSLA pools exist
 *             at fee 500/3000/10000 with liquidity; WETH/TSLA is mostly absent.
 *           - WOOD is a non-production fixture (18 dec) minted 100M to the
 *             deployer at deploy. On the fork we `deal` WOOD to the test owner
 *             for the V2 owner-bond flow.
 *           - PriceRouter is zero-adapter → PortfolioStrategy is Lane-B-only
 *             (deposits/withdraws never consult a strategy price).
 *           - No ENS / ERC-8004 (factory has address(0) for both) → identity
 *             checks are skipped.
 *
 * @dev Env-guarded: skips cleanly when ROBINHOOD_TESTNET_RPC_URL is unset
 *      (mirrors HyperEVMIntegrationTest / RobinhoodMainnetIntegrationTest). Run:
 *        set -a; source .env; set +a
 *        forge test --match-path \
 *          "test/integration/strategies/PortfolioIntegration.t.sol" -vv
 */
abstract contract RobinhoodIntegrationTest is Test {
    // ── Robinhood L2 tokens (verified live) ──

    // Synthra pools denominate in this WETH — the vault asset.
    address constant SYNTHRA_WETH = 0x33e4191705c386532ba27cBF171Db86919200B94;
    // Canonical WETH — kept for reference only; NOT the pool numeraire.
    address constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    address constant TSLA = 0xC9f9c86933092BbbfFF3CCb4b105A4A94bf3Bd4E;
    address constant AMZN = 0x5884aD2f920c162CFBbACc88C9C51AA75eC09E02;
    address constant AMD = 0x71178BAc73cBeb415514eB542a8995b82669778d;
    address constant NFLX = 0x3b8262A63d25f0477c4DDE23F83cfe22Cb768C93;
    address constant PLTR = 0x1FBE1a0e43594b3455993B5dE5Fd0A7A266298d0;

    // ── Test actors ──

    address owner = makeAddr("owner");
    address agent = makeAddr("agent");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");

    // ── Live deployed protocol (read from chains/46630.json) ──

    SyndicateGovernor governor;
    SyndicateFactory factory;
    GuardianRegistry registry;
    StakedWood swood;
    StrategyFactory strategyFactory;
    address swapAdapter;
    address portfolioTemplate;
    address chainlinkVerifier;

    // ── Per-test syndicate ──

    SyndicateVault vault;

    function setUp() public virtual {
        string memory rpc = vm.envOr("ROBINHOOD_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, ROBINHOOD_TESTNET_FORK_BLOCK);
        require(block.chainid == 46630, "not on Robinhood L2 testnet fork");

        factory = SyndicateFactory(_readAddress("SYNDICATE_FACTORY"));
        governor = SyndicateGovernor(_readAddress("SYNDICATE_GOVERNOR"));
        registry = GuardianRegistry(_readAddress("GUARDIAN_REGISTRY"));
        swood = StakedWood(_readAddress("STAKED_WOOD"));
        strategyFactory = StrategyFactory(_readAddress("STRATEGY_FACTORY"));
        swapAdapter = _readAddress("UNISWAP_SWAP_ADAPTER");
        portfolioTemplate = _readAddress("PORTFOLIO_TEMPLATE");
        chainlinkVerifier = _readAddress("CHAINLINK_VERIFIER");

        // The deployed factory is already wired to the governor at init; assert
        // it rather than mutate the live deployment.
        assertEq(governor.factory(), address(factory), "governor.factory not wired to deployed factory");

        _bondOwnerStake();
        _createTestSyndicate();
        _fundAndDeposit(10e18, 10e18); // 10 SYNTHRA_WETH each

        // Warp 1s so the deposit snapshot is strictly in the past for voting.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Address reader ──

    function _readAddress(string memory key) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/chains/46630.json");
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, string.concat(".", key));
    }

    // ── V2 owner-bond flow: deal fixture WOOD → prepareOwnerStake ──

    function _bondOwnerStake() internal {
        uint256 minStake = swood.minOwnerStake();
        address wood = address(swood.wood());
        deal(wood, owner, minStake);

        vm.startPrank(owner);
        IERC20(wood).approve(address(swood), minStake);
        swood.prepareOwnerStake(minStake);
        vm.stopPrank();

        assertTrue(swood.canCreateVault(owner), "owner not eligible to create vault after prepareOwnerStake");
    }

    // ── Create a test syndicate against the LIVE factory (V2 signature) ──

    function _createTestSyndicate() internal {
        SyndicateFactory.SyndicateConfig memory config = SyndicateFactory.SyndicateConfig({
            metadataURI: "ipfs://robinhood-testnet-integration",
            asset: IERC20(SYNTHRA_WETH),
            name: "Robinhood Testnet Vault",
            symbol: "rtWETH",
            openDeposits: true,
            subdomain: "rh-testnet-integration"
        });

        vm.prank(owner);
        (, address vaultAddr) = factory.createSyndicate(0, config);
        vault = SyndicateVault(payable(vaultAddr));

        // Identity check skipped when agentRegistry == address(0).
        vm.prank(owner);
        vault.registerAgent(0, agent);
    }

    // ── Fund LPs with the vault asset and deposit ──

    function _fundAndDeposit(uint256 lp1Amount, uint256 lp2Amount) internal {
        deal(SYNTHRA_WETH, lp1, lp1Amount);
        deal(SYNTHRA_WETH, lp2, lp2Amount);

        vm.startPrank(lp1);
        IERC20(SYNTHRA_WETH).approve(address(vault), lp1Amount);
        vault.deposit(lp1Amount, lp1);
        vm.stopPrank();

        vm.startPrank(lp2);
        IERC20(SYNTHRA_WETH).approve(address(vault), lp2Amount);
        vault.deposit(lp2Amount, lp2);
        vm.stopPrank();
    }

    // ── Clone + initialize a strategy template via the DEPLOYED StrategyFactory ──
    // Keyless path: the registered agent clones (proposer == msg.sender), the
    // factory gates on the template allowlist + vault membership.

    function _cloneAndInit(address template, bytes memory initData) internal returns (address clone) {
        vm.prank(agent);
        clone = strategyFactory.cloneAndInit(template, address(vault), agent, initData);
    }

    // ── Propose → vote → guardian review (cold-start) → execute ──
    // No guardians are staked on the fresh deployment, so `resolveReview`
    // short-circuits via the cold-start (cohort-too-small) path and the
    // proposal executes without a block.

    function _proposeVoteExecute(
        BatchExecutorLib.Call[] memory execCalls,
        BatchExecutorLib.Call[] memory settleCalls,
        uint256 feeBps,
        uint256 duration
    ) internal returns (uint256 proposalId) {
        vm.prank(owner);
        vault.setAgentFeeBps(feeBps);

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault), address(0), "ipfs://rh-testnet-test", duration, execCalls, settleCalls, _emptyCoProposers()
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
}
