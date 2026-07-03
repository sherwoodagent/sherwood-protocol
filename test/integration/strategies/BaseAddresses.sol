// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// token0=WETH / token1=cbBTC for the ts=100 pool; addresses confirmed on the Tenderly Base vnet;
// test-only external-address book (do NOT put these in chains/8453.json).
library BaseAddresses {
    // ── Tokens ──

    /// @dev USDC on Base — 6 decimals
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @dev Wrapped Ether (native WETH9 on Base) — 18 decimals
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    /// @dev Coinbase Wrapped Bitcoin — 8 decimals
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    /// @dev Aerodrome (AERO) governance/rewards token
    address internal constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // ── Moonwell ──

    /// @dev Moonwell Comptroller (Unitroller proxy)
    address internal constant MOONWELL_COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;

    /// @dev Moonwell mUSDC market
    address internal constant MOONWELL_MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;

    /// @dev Moonwell mWETH market
    address internal constant MOONWELL_MWETH = 0x628ff693426583D9a7FB391E54366292F509D457;

    /// @dev Moonwell mcbBTC market
    address internal constant MOONWELL_MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;

    // ── Chainlink price feeds ──

    /// @dev Chainlink BTC/USD aggregator on Base
    address internal constant CHAINLINK_BTC_USD = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;

    /// @dev Chainlink ETH/USD aggregator on Base
    address internal constant CHAINLINK_ETH_USD = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;

    /// @dev Chainlink USDC/USD aggregator on Base
    address internal constant CHAINLINK_USDC_USD = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    /// @dev Chainlink AERO/USD aggregator on Base — "AERO / USD", 8dp (floors compound's reward swap)
    address internal constant CHAINLINK_AERO_USD = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;

    /// @dev Chainlink L2 Sequencer Uptime feed (Base)
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    // ── Aerodrome Slipstream (CL) ──

    /// @dev Slipstream CL Factory
    address internal constant SLIPSTREAM_CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;

    /// @dev Slipstream Non-Fungible Position Manager
    address internal constant SLIPSTREAM_NPM = 0x827922686190790b37229fd06084350E74485b72;

    /// @dev Slipstream CL Swap Router
    address internal constant SLIPSTREAM_CL_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    /// @dev Aerodrome Voter (maps pool → gauge)
    address internal constant AERODROME_VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;

    // ── Slipstream CBBTC/WETH pools (token0=WETH, token1=cbBTC) ──

    /// @dev CBBTC/WETH CL pool — tickSpacing=100 (deepest liquidity)
    address internal constant CBBTC_WETH_POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1;

    /// @dev Gauge for CBBTC_WETH_POOL (tickSpacing=100)
    address internal constant CBBTC_WETH_GAUGE = 0x41b2126661C673C2beDd208cC72E85DC51a5320a;

    /// @dev Tick spacing for the primary CBBTC/WETH pool
    int24 internal constant CBBTC_WETH_TICK_SPACING = 100;

    /// @dev CBBTC/WETH CL pool — tickSpacing=1
    address internal constant CBBTC_WETH_POOL_TS1 = 0x22AEe3699b6A0fEd71490C103Bd4E5f3309891D5;

    /// @dev Gauge for CBBTC_WETH_POOL_TS1 (tickSpacing=1)
    address internal constant CBBTC_WETH_GAUGE_TS1 = 0x83e2E9493996651ed63033d81f5052cBE2fEB6A1;
}
