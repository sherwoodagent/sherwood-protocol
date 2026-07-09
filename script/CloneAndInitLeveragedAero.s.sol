// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ScriptBase} from "./ScriptBase.sol";
import {console} from "forge-std/console.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {LeveragedAerodromeCLStrategy} from "../src/strategies/LeveragedAerodromeCLStrategy.sol";

/**
 * @notice Clone the LeveragedAerodromeCLStrategy template and initialize it against a live vault.
 *         The Base venue book is hardcoded (see the constant block); runtime actors + fee bps come
 *         from env. `initialize` has no proposer==caller check (that lives in the factory), so the
 *         governor's `propose()` can store this clone directly.
 *
 *   Env:
 *     VAULT              — REQUIRED. Live SyndicateVault address.
 *     PROPOSER           — REQUIRED. The agent EOA registered on the vault.
 *     FEE_RECIPIENT      — REQUIRED (fees > 0). EOA receiving fee-shares.
 *     LEVERAGED_AERO_CL_TEMPLATE — template addr (else read from chains.json).
 *     PERF_FEE_BPS       — perf fee bps (default 1000).
 *     MGMT_FEE_BPS       — mgmt fee bps (default 100).
 *
 *   Usage:
 *     VAULT=0x.. PROPOSER=0x.. FEE_RECIPIENT=0x.. \
 *     forge script script/CloneAndInitLeveragedAero.s.sol:CloneAndInitLeveragedAero \
 *       --rpc-url "$RPC" --broadcast --slow --private-key $DEPLOYER_PK
 */
contract CloneAndInitLeveragedAero is ScriptBase {
    // ── Base venue book (mirror of BaseAddresses.sol; token0=WETH, token1=cbBTC, ts=100) ──
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant COMPTROLLER = 0xfBb21d0380beE3312B33c4353c8936a0F13EF26C;
    address constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address constant MWETH = 0x628ff693426583D9a7FB391E54366292F509D457;
    address constant MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;
    address constant POOL = 0x70aCDF2Ad0bf2402C957154f944c19Ef4e1cbAE1;
    address constant NPM = 0x827922686190790b37229fd06084350E74485b72;
    address constant GAUGE = 0x41b2126661C673C2beDd208cC72E85DC51a5320a;
    address constant CL_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant BTC_FEED = 0x64c911996D3c6aC71f9b455B1E8E7266BcbD848F;
    address constant ETH_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address constant USDC_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address constant SEQ_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address constant AERO_FEED = 0x4EC5970fC728C5f65ba413992CD5fF6FD70fcfF0;
    int24 constant TICK_SPACING = 100;

    function run() external {
        address vault = vm.envAddress("VAULT");
        address proposer = vm.envAddress("PROPOSER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint16 perfFeeBps = uint16(vm.envOr("PERF_FEE_BPS", uint256(1000)));
        uint16 mgmtFeeBps = uint16(vm.envOr("MGMT_FEE_BPS", uint256(100)));

        address template = vm.envOr("LEVERAGED_AERO_CL_TEMPLATE", address(0));
        if (template == address(0)) template = _readAddress("LEVERAGED_AERO_CL_TEMPLATE");
        require(template != address(0), "template not set (env or chains.json)");

        LeveragedAerodromeCLStrategy.InitParams memory p = LeveragedAerodromeCLStrategy.InitParams({
            usdc: USDC,
            mUsdc: MUSDC,
            mCbBTC: MCBBTC,
            mWeth: MWETH,
            comptroller: COMPTROLLER,
            cbBTC: CBBTC,
            weth: WETH,
            pool: POOL,
            npm: NPM,
            gauge: GAUGE,
            swapRouter: CL_ROUTER,
            cbBTCFeed: BTC_FEED,
            wethFeed: ETH_FEED,
            usdcFeed: USDC_FEED,
            sequencerFeed: SEQ_FEED,
            aeroUsdFeed: AERO_FEED,
            maxDelay: 48 hours,
            gracePeriod: 1 hours,
            calmDeviationTicks: 500,
            twapWindow: 1800,
            tickSpacing: TICK_SPACING,
            targetLtvBps: 5000,
            maxLtvBps: 6500,
            minHealthBps: 12000,
            maxSlippageBps: 100,
            managementFeeBps: mgmtFeeBps,
            performanceFeeBps: perfFeeBps,
            feeRecipient: feeRecipient
        });

        vm.startBroadcast();
        address clone = Clones.clone(template);
        LeveragedAerodromeCLStrategy(payable(clone)).initialize(vault, proposer, abi.encode(p));
        vm.stopBroadcast();

        console.log("LEV_AERO_CLONE", clone);
        console.log("clone.vault:", LeveragedAerodromeCLStrategy(payable(clone)).vault());
        console.log("clone.proposer:", LeveragedAerodromeCLStrategy(payable(clone)).proposer());
        console.log("clone.state (0=Pending):", uint256(LeveragedAerodromeCLStrategy(payable(clone)).state()));
    }
}
