// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {SyndicateFactory} from "../src/SyndicateFactory.sol";
import {ScriptBase} from "./ScriptBase.sol";

/**
 * @notice Atomic UUPS upgrade of SyndicateFactory + setEnsRegistrar.
 *
 *   The Base mainnet factory was deployed with `ensRegistrar = address(0)`,
 *   which made every `createSyndicate` silently skip ENS subname registration.
 *   This script ships the new implementation (which adds `setEnsRegistrar`)
 *   and configures the registrar in the same proxy delegatecall, so there is
 *   no in-between state where the new implementation is live but ENS is
 *   still misconfigured.
 *
 *   Steps:
 *     1. Snapshot current on-chain state.
 *     2. Deploy new SyndicateFactory implementation.
 *     3. upgradeToAndCall(newImpl, abi.encodeCall(setEnsRegistrar, (l2Registrar))) —
 *        atomic upgrade + config.
 *     4. Validate state survived AND ensRegistrar is now non-zero.
 *
 *   Existing syndicates remain unregistered on ENS (their NFTs were never
 *   minted). Backfill those by calling `IL2Registrar(l2Registrar).register(
 *   subdomain, vault)` for each — permissionless, anyone can do it.
 *
 *   Must be called by the factory owner.
 *
 *   Usage:
 *     forge script script/UpgradeFactorySetEnsRegistrar.s.sol:UpgradeFactorySetEnsRegistrar \
 *       --rpc-url base \
 *       --account sherwood-agent \
 *       --broadcast
 */
contract UpgradeFactorySetEnsRegistrar is ScriptBase {
    function run() external {
        address factoryAddr = _readAddress("SYNDICATE_FACTORY");
        address l2Registrar = _readAddress("L2_REGISTRAR");
        SyndicateFactory factory = SyndicateFactory(factoryAddr);

        console.log("Factory proxy:", factoryAddr);
        console.log("Owner:        ", factory.owner());
        console.log("L2 Registrar: ", l2Registrar);

        // ── 1. Pre-upgrade snapshot ──
        address oldEnsRegistrar = address(factory.ensRegistrar());
        address preOwner = factory.owner();
        address preGovernor = factory.governor();
        uint256 preCount = factory.syndicateCount();
        address preVaultImpl = factory.vaultImpl();
        console.log("\n--- Pre-upgrade state ---");
        console.log("  ensRegistrar:", oldEnsRegistrar);
        console.log("  syndicateCount:", preCount);
        console.log("  vaultImpl:", preVaultImpl);
        console.log("  governor:", preGovernor);

        vm.startBroadcast();

        // ── 2. Deploy new implementation ──
        SyndicateFactory newImpl = new SyndicateFactory();
        console.log("\nNew implementation:", address(newImpl));

        // ── 3. Atomic upgrade + setEnsRegistrar ──
        bytes memory initCall = abi.encodeCall(SyndicateFactory.setEnsRegistrar, (l2Registrar));
        factory.upgradeToAndCall(address(newImpl), initCall);
        console.log("Upgrade + setEnsRegistrar broadcast");

        vm.stopBroadcast();

        // ── 4. Post-upgrade validation ──
        console.log("\n--- Post-upgrade validation ---");
        require(factory.owner() == preOwner, "owner changed");
        console.log("  owner: OK");
        require(factory.governor() == preGovernor, "governor changed");
        console.log("  governor: OK");
        require(factory.syndicateCount() == preCount, "syndicateCount changed");
        console.log("  syndicateCount: OK");
        require(factory.vaultImpl() == preVaultImpl, "vaultImpl changed");
        console.log("  vaultImpl: OK");
        require(address(factory.ensRegistrar()) == l2Registrar, "ensRegistrar not updated");
        console.log("  ensRegistrar: OK (now %s)", address(factory.ensRegistrar()));

        // ── 5. Persist new impl + record V2 history ──
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(block.chainid), ".json");
        vm.writeJson(vm.toString(address(newImpl)), path, ".SYNDICATE_FACTORY_V3_IMPL");
        console.log("\nSaved SYNDICATE_FACTORY_V3_IMPL to chains/%s.json", vm.toString(block.chainid));
        console.log("\nDone. Future syndicates will register ENS subnames automatically.");
        console.log("Backfill existing syndicates by calling register(subdomain, vault) on the registrar directly.");
    }
}
