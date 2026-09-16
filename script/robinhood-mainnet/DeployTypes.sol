// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySherwood} from "../Deploy.s.sol";

/// @notice 4663 is Mainnet; any other chain with a committed address book is Fork.
enum Posture {
    Mainnet,
    Fork
}

/// @notice Every external address the ceremony reads, all from chains/{chainId}.json.
/// @dev Numeric parameters are deliberately NOT fields — they are `RobinhoodParams`
///      constants read where used, so this struct cannot carry a mis-set value.
struct Inputs {
    Posture posture;
    address deployer;
    address ownerMultisig; // Mainnet only; address(0) on Fork
    address wood;
    address weth;
    address usdg;
    address usdgFeed;
    address ethUsdFeed;
    address uniswapV3Factory;
    address uniswapV3PositionManager;
    address uniswapSwapRouter;
    address uniswapQuoterV2;
    address uniswapV4PoolManager;
    address uniswapV4Quoter;
    address morphoBlue;
    address woodWethV2Pair;
    address woodWethSushiV2Pair;
}

/// @notice Everything the ceremony mints or adopts, filled phase by phase.
///         Every field is `Create3.addressOf(create3Factory, <DeploySalts constant>)`.
struct Stack {
    DeploySherwood.Deployed core;
    address create3Factory;
    address uniswapSwapAdapter;
    address portfolioTemplate;
    address morphoSupplyTemplate;
    address concentratedLiquidityTemplate;
    address strategyFactory;
    address woodUsdFeed;
    address exposureLedger;
    address proposerBondEscrow;
    address challengeGame;
    address tokenCourt;
}
