// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "../ScriptBase.sol";

/**
 * @notice A Chainlink-shaped WOOD/USD aggregator for FORK / VNET USE ONLY.
 *
 *         Robinhood Chain 4663 publishes no WOOD/USD feed, which is the whole
 *         reason `WoodTwapOracle` exists. But a Tenderly vnet cannot prime that
 *         oracle: the WOOD/WETH pair stops trading at the fork point, the idle
 *         span grows without bound, and `_currentCumulative` refuses to
 *         extrapolate across it — so `update()` no-ops forever and `consult()`
 *         never answers. `DeployPlanB` pre-flight 8 then refuses the run,
 *         correctly, because a ledger with no market source reverts
 *         `NoWoodPrice` on every price read.
 *
 *         This contract is the sanctioned way out on a fork: wire it via
 *         `ExposureLedger.setWoodFeed` (i.e. `WOOD_USD_FEED` on `DeployPlanB`)
 *         and the ledger prices WOOD off it, still capped by `woodUsdPriceX8`
 *         and still discounted by `woodHaircutBps`.
 *
 *         NEVER DEPLOY THIS TO MAINNET. It is not an oracle — it reports
 *         whatever its owner last wrote, and it reports it as PERPETUALLY
 *         FRESH.
 *
 * @dev `updatedAt` is `block.timestamp` rather than a stored value, on purpose.
 *      A fork spends most of its life being warped forward (`evm_increaseTime`)
 *      to traverse 24h vote + 24h review windows, and a stored timestamp goes
 *      stale the moment it is. The operator would then have to refresh the feed
 *      after every warp — the exact papercut the lifecycle runbook already
 *      documents for the Chainlink push feeds. Deriving it removes the step.
 *      That makes staleness untestable through this contract, which is the
 *      correct trade for a fixture whose only job is to keep the price path
 *      alive across time travel.
 */
contract ForkWoodUsdFeed {
    /// @notice Matches the 8-decimal convention of every Chainlink USD feed,
    ///         and of `ExposureLedger`'s own X8 price space.
    uint8 public constant decimals = 8;

    string public constant description = "WOOD / USD (FORK FIXTURE - NOT AN ORACLE)";

    address public owner;

    int256 private _answer;
    uint80 private _roundId;

    error NotOwner();
    error NonPositiveAnswer();

    event AnswerSet(int256 previous, int256 current, uint80 roundId);

    constructor(address owner_, int256 answerX8) {
        if (answerX8 <= 0) revert NonPositiveAnswer();
        owner = owner_;
        _answer = answerX8;
        _roundId = 1;
        emit AnswerSet(0, answerX8, 1);
    }

    /// @notice Move the reported WOOD/USD price. Fork sims use this to walk WOOD
    ///         through a crash and watch bond valuations follow.
    function setAnswer(int256 answerX8) external {
        if (msg.sender != owner) revert NotOwner();
        // A non-positive answer is how a real aggregator signals "unavailable",
        // and `ExposureLedger._feedPriceX8` treats it as exactly that — it would
        // fall through to the TWAP oracle, which on a fork cannot answer either.
        // Refusing here keeps the failure at the setter instead of surfacing it
        // as an unexplained `NoWoodPrice` several transactions later.
        if (answerX8 <= 0) revert NonPositiveAnswer();
        emit AnswerSet(_answer, answerX8, _roundId + 1);
        _answer = answerX8;
        _roundId += 1;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, block.timestamp, block.timestamp, _roundId);
    }
}

/**
 * @notice Deploys `ForkWoodUsdFeed` and persists `WOOD_USD_FEED` into
 *         chains/{chainId}.json, so `DeployPlanB` can read it back the same way
 *         it reads every other address.
 *
 *         Runs AFTER the core ceremony and BEFORE `DeployPlanB`, in the slot
 *         `DeployWoodTwapOracle` occupies on a real chain.
 *
 *   Environment:
 *     WOOD_USD_PRICE_X8      — REQUIRED. Starting WOOD/USD price, 8 decimals.
 *                              Derive it from the fork's own WOOD/WETH pair
 *                              reserves times the Chainlink ETH/USD answer, so
 *                              the fork stays mainnet-faithful rather than
 *                              pricing WOOD at an invented number.
 *     ROBINHOOD_FORK_CHAIN_ID — REQUIRED. The vnet's chain id. Doubles as the
 *                              guard below: this script refuses to run anywhere
 *                              its own chain id was not explicitly named.
 *
 *   Usage:
 *     WOOD_USD_PRICE_X8=627821 ROBINHOOD_FORK_CHAIN_ID=9994663 \
 *       forge script script/fork/DeployForkWoodUsdFeed.s.sol:DeployForkWoodUsdFeed \
 *       --rpc-url "$RPC" --broadcast --slow --unlocked --sender 0x5A00...
 */
contract DeployForkWoodUsdFeed is ScriptBase {
    /// @notice Robinhood Chain mainnet. Named here only to be REFUSED.
    uint256 internal constant ROBINHOOD_MAINNET = 4663;

    function run() external {
        // THE GUARD THIS SCRIPT EXISTS BEHIND. Every other deploy script accepts
        // `4663 || forkChainId`; this one accepts the fork id ALONE and names
        // mainnet explicitly so the refusal reads as a decision rather than a
        // missing branch. A fixture feed on mainnet would price every guardian
        // bond off an owner-writable number.
        uint256 forkChainId = vm.envUint("ROBINHOOD_FORK_CHAIN_ID");
        require(forkChainId != ROBINHOOD_MAINNET, "ROBINHOOD_FORK_CHAIN_ID names mainnet: this is a fork fixture");
        require(
            block.chainid == forkChainId,
            "wrong chain: this fixture feed deploys ONLY to the fork named by ROBINHOOD_FORK_CHAIN_ID"
        );

        uint256 priceX8 = vm.envUint("WOOD_USD_PRICE_X8");
        require(priceX8 != 0 && priceX8 <= uint256(type(int256).max), "WOOD_USD_PRICE_X8 out of range");

        address deployer = msg.sender;

        vm.startBroadcast();
        ForkWoodUsdFeed feed = new ForkWoodUsdFeed(deployer, int256(priceX8));
        vm.stopBroadcast();

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        require(answer == int256(priceX8), "feed did not take the seeded price");
        require(updatedAt == block.timestamp, "feed does not report itself fresh");
        require(feed.decimals() == 8, "feed decimals != 8");

        _patchAddress("WOOD_USD_FEED", address(feed));

        console.log("ForkWoodUsdFeed:  %s", address(feed));
        console.log("WOOD/USD (X8):    %s", priceX8);
        console.log("owner:            %s", feed.owner());
        console.log("");
        console.log("NEXT: pass WOOD_USD_FEED=%s to DeployPlanB", address(feed));
        console.log("      together with a non-zero WOOD_FEED_MAX_DELAY (pre-flight 12).");
    }
}
