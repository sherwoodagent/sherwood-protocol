// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Every numeric/fixed input of the Robinhood v1 ceremony, committed and reviewed in the PR.
///         No runtime override exists: DeployAll reads these where used, never from env.
library RobinhoodParams {
    uint256 internal constant MAINNET_CHAIN_ID = 4663;
    // Arbitrum Orbit (ArbOS 116): 4x EIP-170, probed on-chain 2026-07-24.
    uint256 internal constant ROBINHOOD_MAX_CODE_SIZE = 98_304;
    // Deterministic deployment proxy (same address on every EVM chain); mints the Create3Factory.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // No ENS on Robinhood; ERC-8004 IdentityRegistry is live on 4663 but v1 leaves identity gating off.
    address internal constant ENS_REGISTRAR = address(0);
    address internal constant AGENT_REGISTRY = address(0);

    // Factory / governor. 200 bps is the guardian-budget floor, stamped once per vault at initialize.
    uint256 internal constant MANAGEMENT_FEE_BPS = 200;
    uint256 internal constant MIN_VOTING_PERIOD = 24 hours;
    uint256 internal constant MIN_COOLDOWN_PERIOD = 1 hours;
    uint256 internal constant MIN_REVIEW_PERIOD = 6 hours;
    uint256 internal constant MAX_STRATEGY_DURATION = 30 days;

    // Guardian registry
    uint256 internal constant REVIEW_PERIOD = 24 hours;
    uint256 internal constant BLOCK_QUORUM_BPS = 3000;

    // StakedWood
    uint256 internal constant MIN_GUARDIAN_STAKE = 10_000e18;
    uint256 internal constant MIN_OWNER_STAKE = 10_000e18;
    uint256 internal constant COOLDOWN = 7 days;
    uint256 internal constant MIN_SLASH_BPS = 1000;
    uint256 internal constant MAX_SLASH_BPS = 10_000;
    uint256 internal constant AGE_FLOOR_BPS = 2500;
    uint256 internal constant MATURATION = 30 days;

    // ExposureLedger / ChallengeGame
    uint256 internal constant EPOCH_LENGTH = 28 days;
    uint256 internal constant EXPECTED_CHALLENGE_WINDOW = 14 days;
    // Sits ON the ledger's MIN_WOOD_HAIRCUT_BPS floor; the two move together.
    uint256 internal constant WOOD_HAIRCUT_BPS = 5000;

    // WoodPoolFeed
    uint256 internal constant TWAP_WINDOW = 24 hours;
    uint256 internal constant ETH_USD_MAX_AGE = 1 days;
    uint256 internal constant MIN_WETH_RESERVE = 10e18;
    uint256 internal constant MAX_PAIR_IDLE = 5 minutes;
    uint256 internal constant KEEPER_CADENCE_SLACK = 2 hours;
    // `updatedAt` rolls at most once per window, so the bound must clear a window plus the keeper cadence.
    uint256 internal constant WOOD_FEED_MAX_DELAY = TWAP_WINDOW + KEEPER_CADENCE_SLACK + 1;

    // PLACEHOLDER - Ana to confirm. Test-fixture value; must exceed votingPeriod + reviewPeriod +
    // executionWindow (3 days at the factory defaults) or fully-covered proposals die at execute with StalePrice.
    uint256 internal constant ASSET_FEED_MAX_DELAY = 1 days;
    // PLACEHOLDER - Ana to confirm. Test-fixture value; per-vault covered-TVL ceiling, USD-18.
    uint256 internal constant COVERED_TVL_CAP_USD18 = 1_000_000e18;
    // PLACEHOLDER - Ana to confirm. Test-fixture value ($0.50); pre-flight bounds it to [1.25x, 2x] spot.
    uint256 internal constant WOOD_PRICE_CAP_X8 = 5e7;

    /// @notice TierRegistry launch set. Every CHAINLINK_<SYM>_USD_FEED and <SYM> (WETH for ETH) book key is
    ///         REQUIRED. A Solidity constant cannot hold an array, hence a pure accessor.
    function launchSetSymbols() internal pure returns (string[16] memory) {
        return [
            "ETH",
            "USDG",
            "USDC",
            "BTC",
            "LINK",
            "AAPL",
            "AMD",
            "AMZN",
            "GOOGL",
            "META",
            "MSFT",
            "NVDA",
            "TSLA",
            "QQQ",
            "SPY",
            "SLV"
        ];
    }
}
