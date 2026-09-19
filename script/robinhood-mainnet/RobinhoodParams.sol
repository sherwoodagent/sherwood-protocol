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
    // Governor-impl IMMUTABLE, so this deploy is the only chance to set it. Held at the
    // per-vault floor (SHE-234) so it can never bind tighter than `setVotingPeriod` itself;
    // the operating value is the factory's 24h default, which owners may now lower.
    uint256 internal constant MIN_VOTING_PERIOD = 1 hours;
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
    // The V3 leg's depth floor, in in-range liquidity: half of what the live WOOD/WETH V3 pool carries.
    uint256 internal constant MIN_V3_LIQUIDITY = 1e22;
    // Average seconds between WRITES to the V3 pool's observation ring (one per block in which
    // the pool is touched, not one per block), measured 2026-09-16. DERIVATION INPUT for the
    // cardinality the feed script prints; nothing is enforced against it. RE-MEASURE before the
    // ceremony: binary-search `observe([S, 0])` for the largest S that does not revert OLD, then
    // divide by the pool's current cardinality.
    uint256 internal constant V3_WRITE_INTERVAL_SECONDS = 880;
    uint256 internal constant MAX_PAIR_IDLE = 5 minutes;
    uint256 internal constant KEEPER_CADENCE_SLACK = 2 hours;
    // `updatedAt` rolls at most once per window, so the bound must clear a window plus the keeper cadence.
    uint256 internal constant WOOD_FEED_MAX_DELAY = TWAP_WINDOW + KEEPER_CADENCE_SLACK + 1;

    // Bounds the AGGREGATOR's own updatedAt age inside `ExposureLedger.coverageUsd`, not the
    // proposal lifecycle: 4663 Chainlink feeds heartbeat at 24h, so exactly 24h makes every
    // covered read revert `StalePrice` on a late publish. Same 2h allowance, and the same
    // reasoning, as `PortfolioStrategy.MAX_PUSH_PRICE_AGE` (26h). Owner-settable per asset.
    uint256 internal constant ASSET_FEED_MAX_DELAY = 1 days + 2 hours;
    // Per-vault ceiling on ONE proposal's coverage, USD-18, checked at `propose`. Not a running
    // total. Owner-settable and read live, so the launch value is a starting point, not a lock.
    uint256 internal constant COVERED_TVL_CAP_USD18 = 1_000_000e18;
    // How far above live spot the WOOD price cap is seated, bps. Both postures DERIVE the cap
    // from the pool at deploy time, so no measured price is ever committed here. Must land
    // inside the ceremony's [1.25x, 2x] band; the Safe re-reviews the cap monthly after launch.
    uint256 internal constant CAP_OVER_SPOT_BPS = 15_000;

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
