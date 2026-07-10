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
import {DeploySherwood} from "../../script/Deploy.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

// Pinned Robinhood L2 testnet fork block. Chosen AFTER today's V2 redeployment
// (2026-07-08) — the full core + strategy stack in chains/46630.json has code
// from ~block 88,751,000, so this pin sits comfortably above the deploy and
// below the chain head at fix time (88,751,996). Pinning keeps Synthra pool
// state + guardian/owner-stake reads deterministic across runs. File-level so
// derived suites can pin identically.
uint256 constant ROBINHOOD_TESTNET_FORK_BLOCK = 88_767_205;

/**
 * @title RobinhoodIntegrationTest
 * @notice Abstract base for fork-based integration tests on Robinhood L2
 *         testnet (chain 46630): a FRESH post-#421 Sherwood core deployed
 *         in-test, driving the LIVE periphery (Synthra pools, the deployed
 *         UniswapSwapAdapter + quoter shim, the deployed strategy templates)
 *         read from chains/46630.json.
 *
 *         #421 (per-vault governors): the LIVE 46630 core in chains/46630.json
 *         predates the per-vault BeaconProxy governor (singleton
 *         SYNDICATE_GOVERNOR, one-arg registry reviews) — head-compiled tests
 *         can no longer drive it, so the core is deployed fresh on the fork
 *         (mirrors HyperEVMIntegrationTest) until the testnet core is
 *         redeployed post-#421. `governor` is resolved per-vault AFTER
 *         createSyndicate; the live STRATEGY_FACTORY is likewise replaced by a
 *         fresh one because its `_authClone` checks `vaultToSyndicate` on the
 *         OLD core factory. This harness must track the live deploy + factory
 *         wiring (CLAUDE.md MockRegistryMinimal lesson).
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

    // ── Protocol under test: fresh post-#421 core + LIVE periphery (chains/46630.json) ──

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

        // Fresh post-#421 core (see the contract-level natspec for why the LIVE
        // pre-#421 core in chains/46630.json can't be driven by head tests).
        _deployStack();

        // LIVE periphery stays under test: the deployed Synthra-wired swap
        // adapter (+ quoter shim) and the deployed strategy template bytecode.
        swapAdapter = _readAddress("UNISWAP_SWAP_ADAPTER");
        portfolioTemplate = _readAddress("PORTFOLIO_TEMPLATE");
        chainlinkVerifier = _readAddress("CHAINLINK_VERIFIER");

        // The LIVE StrategyFactory gates `_authClone` on `vaultToSyndicate` of
        // the OLD core factory, so a fresh vault would revert VaultNotRegistered.
        // Deploy a fresh keyless factory against the fresh core and approve the
        // LIVE template on it — the keyless clone path + live template bytecode
        // stay exercised.
        strategyFactory = new StrategyFactory(address(factory), address(this));
        strategyFactory.setTemplateApproval(portfolioTemplate, true);

        _bondOwnerStake();
        _createTestSyndicate();
        _fundAndDeposit(10e18, 10e18); // 10 SYNTHRA_WETH each

        // Warp 1s so the deposit snapshot is strictly in the past for voting.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    // ── Fresh core deployment (mirrors HyperEVMIntegrationTest) ──

    function _deployStack() internal {
        // Non-production WOOD fixture for the V2 owner-bond flow (post-split:
        // owner staking lives in sWOOD).
        ERC20Mock wood = new ERC20Mock("Wood", "WOOD", 18);

        DeploySherwood deployScript = new DeploySherwood();
        DeploySherwood.Config memory cfg = DeploySherwood.Config({
            ensRegistrar: address(0), // no ENS on Robinhood testnet
            agentRegistry: address(0), // no ERC-8004 on Robinhood testnet
            managementFeeBps: 50, // deploy-script defaults (mirrors the live-deploy config)
            protocolFeeBps: 100,
            maxStrategyDays: 14,
            votingPeriod: 1 days,
            woodToken: address(wood),
            slashAppealSeed: 0,
            epochZeroSeed: 0,
            betaMode: false // real GuardianRegistry + sWOOD — owner-bond + review ceremony under test
        });
        // deployCore runs nested CREATE3 calls AS the script address; prank as the
        // script so the Create3Factory owner is consistent (mirrors HyperEVMIntegrationTest).
        vm.prank(address(deployScript));
        DeploySherwood.Deployed memory d = deployScript.deployCore(cfg);

        // Per-vault governors (#421): no singleton governor exists at deploy.
        // `governor` is resolved from the factory after createSyndicate below.
        factory = SyndicateFactory(d.factoryProxy);
        registry = GuardianRegistry(d.registryProxy);
        swood = StakedWood(d.swoodProxy);
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
        // Per-vault governor (#421): resolve the vault's own governor proxy.
        governor = SyndicateGovernor(factory.governorOf(vaultAddr));

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
