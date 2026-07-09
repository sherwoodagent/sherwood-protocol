// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateGovernor} from "../../src/SyndicateGovernor.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {GuardianRegistry} from "../../src/GuardianRegistry.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {DeploySherwood} from "../../script/Deploy.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

// Pinned Robinhood mainnet fork block (US market hours, 2026-07-08 ~15:10 UTC).
// Chosen so the Chainlink TSLA/ETH/USDG push feeds are fresh (updatedAt within
// the 24h heartbeat) at the fork timestamp and the live Uniswap pool state is
// stable. File-level so both this harness and UniswapAdapterRobinhoodForkTest
// pin identically.
uint256 constant ROBINHOOD_FORK_BLOCK = 4_453_020;

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
 * @dev Skips if ROBINHOOD_RPC_URL is not set (mirrors the HyperEVM harness). The
 *      fork is PINNED to a fixed block so live equity/ETH feed values and pool
 *      state stay deterministic across runs. Run explicitly:
 *        forge test --fork-url $ROBINHOOD_RPC_URL \
 *          --match-path "test/integration/strategies/PortfolioMainnetFork.t.sol" -vv
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
        vm.createSelectFork(rpc, ROBINHOOD_FORK_BLOCK);
        require(block.chainid == 4663, "not on Robinhood mainnet fork");

        wood = new ERC20Mock("Wood", "WOOD", 18);
        _deployProtocol();
        _bondOwnerStake();
        _createSyndicate();
        _fundAndDeposit(10_000e6, 10_000e6); // 10k USDG each

        // Warp 1s so the deposit snapshot is in the past for voting.
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _deployProtocol() internal {
        DeploySherwood deployScript = new DeploySherwood();
        DeploySherwood.Config memory cfg = DeploySherwood.Config({
            ensRegistrar: address(0),
            agentRegistry: address(0),
            managementFeeBps: 50,
            protocolFeeBps: 100,
            maxStrategyDays: 14,
            votingPeriod: 1 days,
            woodToken: address(wood),
            slashAppealSeed: 0,
            epochZeroSeed: 0,
            betaMode: false
        });
        // deployCore's internal c3.deploy calls run as the script address, so
        // prank as the script to keep the Create3Factory owner consistent.
        vm.prank(address(deployScript));
        DeploySherwood.Deployed memory d = deployScript.deployCore(cfg);

        governor = SyndicateGovernor(d.governorProxy);
        factory = SyndicateFactory(d.factoryProxy);
        registry = GuardianRegistry(d.registryProxy);
        swood = StakedWood(d.swoodProxy);
        vaultImpl = d.vaultImpl;
        executorLib = d.executorLib;
        deployer = d.deployer;
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
    }

    /// @dev Propose → vote → open+resolve guardian review → execute. The cohort
    ///      is empty (no guardians staked), so `resolveReview` short-circuits
    ///      via the cold-start / cohortTooSmall path and the proposal executes.
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
            address(vault), address(0), "ipfs://rh-mainnet-test", duration, execCalls, settleCalls, _emptyCoProposers()
        );

        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(lp1);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);
        vm.prank(lp2);
        governor.vote(proposalId, ISyndicateGovernor.VoteType.For);

        ISyndicateGovernor.GovernorParams memory params = governor.getGovernorParams();
        vm.warp(vm.getBlockTimestamp() + params.votingPeriod + 1);

        registry.openReview(proposalId);
        uint256 reviewPeriod = registry.reviewPeriod();
        vm.warp(vm.getBlockTimestamp() + reviewPeriod + 1);
        registry.resolveReview(proposalId);

        governor.executeProposal(proposalId);
    }

    function _emptyCoProposers() internal pure returns (ISyndicateGovernor.CoProposer[] memory) {
        return new ISyndicateGovernor.CoProposer[](0);
    }
}
