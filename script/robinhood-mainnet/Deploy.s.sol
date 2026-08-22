// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SyndicateFactory} from "../../src/SyndicateFactory.sol";
import {ProtocolConfig} from "../../src/ProtocolConfig.sol";
import {StakedWood} from "../../src/StakedWood.sol";
import {DeploySherwood} from "../Deploy.s.sol";

/**
 * @notice Deploy the Sherwood core stack to Robinhood Chain mainnet (chain 4663).
 *
 *         Robinhood Chain is an Arbitrum Orbit L2 with no ENS/Durin registrar
 *         and no ERC-8004 agent-identity registry, so the factory is deployed
 *         with address(0) for both (identity + subname registration disabled).
 *
 *         Inherits the canonical `DeploySherwood` and delegates the core
 *         ceremony to its `deployCore` (CREATE3-salted, insertion-order-
 *         independent) — no hand-maintained linear-nonce offsets. This override
 *         layers the Robinhood-specific bits on top: the multisig handoff,
 *         post-deploy validation, and address persistence.
 *
 *   Environment:
 *     WOOD_TOKEN            — REQUIRED. Guardian-layer WOOD custody token.
 *     OWNER_MULTISIG        — Multisig receiving ownership of the proxies as the
 *                             final step. Required unless SKIP_MULTISIG_HANDOFF.
 *     SKIP_MULTISIG_HANDOFF — "true"/"1" to keep the deployer as owner (fork/dry
 *                             runs only — never on the real mainnet ceremony).
 *
 *   Usage:
 *     WOOD_TOKEN=0x.. OWNER_MULTISIG=0xSafe.. \
 *       forge script script/robinhood-mainnet/Deploy.s.sol:DeployRobinhoodMainnet \
 *       --rpc-url robinhood --account sherwood-deployer --broadcast --slow
 */
contract DeployRobinhoodMainnet is DeploySherwood {
    // No ENS or ERC-8004 on Robinhood Chain.
    address constant L2_REGISTRAR = address(0);
    address constant AGENT_REGISTRY = address(0);

    // Production governor / factory parameters (mirror script/Deploy.s.sol prod).
    /// @dev 200 = the 2%-management headline of the two-number fee model, and
    ///      the same value the canonical `DeploySherwood` defaults to. THIS IS A
    ///      GUARDIAN-BUDGET NUMBER, NOT A REVENUE ONE: 20% of the management fee
    ///      funds the guardian pool (`ProtocolConfig._mgmtSplit.guardianBps`),
    ///      and it is the only leg that pays in flat and losing markets — the
    ///      performance leg pays nothing below the high-water mark while the
    ///      review workload is unchanged.
    ///
    ///      The prior 50 here was a leftover from before the split rework and
    ///      undershot the tier-1 guardian ROE hurdle: at 50 bps the pool reaches
    ///      0.60% of TVL/yr against the 0.90% the 15% hurdle needs. It is a
    ///      FLOOR rather than a generous choice, because management accrues only
    ///      while a strategy is deployed — at partial utilisation the mgmt leg
    ///      shrinks proportionally and 200 itself lands near the hurdle.
    ///
    ///      STAMPED ONCE PER VAULT at `initialize`; `SyndicateVault` has no
    ///      setter and the factory's `setManagementFeeBps` reaches only NEW
    ///      vaults, so every fund created under a wrong value keeps it forever.
    uint256 constant MANAGEMENT_FEE_BPS = 200;
    uint256 constant MAX_STRATEGY_DAYS = 14;
    uint256 constant VOTING_PERIOD = 1 days;

    function run() external override {
        // Accept Robinhood mainnet (4663) OR a Tenderly-fork chain id passed via
        // ROBINHOOD_FORK_CHAIN_ID (e.g. 9994663) so the byte-same ceremony runs
        // against a mainnet fork. The fork writes chains/{forkChainId}.json.
        uint256 forkChainId = vm.envOr("ROBINHOOD_FORK_CHAIN_ID", uint256(0));
        require(
            block.chainid == 4663 || (forkChainId != 0 && block.chainid == forkChainId),
            "wrong chain: expected Robinhood mainnet 4663 or ROBINHOOD_FORK_CHAIN_ID"
        );

        address woodToken = vm.envAddress("WOOD_TOKEN");
        require(woodToken != address(0), "WOOD_TOKEN required");

        bool skipHandoff = vm.envOr("SKIP_MULTISIG_HANDOFF", false);
        address ownerMultisig = vm.envOr("OWNER_MULTISIG", address(0));
        if (!skipHandoff) {
            require(ownerMultisig != address(0), "OWNER_MULTISIG required (or set SKIP_MULTISIG_HANDOFF=true)");
            require(ownerMultisig.code.length > 0, "OWNER_MULTISIG must be a contract (Safe), not an EOA");
        }

        Config memory cfg = Config({
            ensRegistrar: L2_REGISTRAR,
            agentRegistry: AGENT_REGISTRY,
            managementFeeBps: MANAGEMENT_FEE_BPS,
            maxStrategyDays: MAX_STRATEGY_DAYS,
            votingPeriod: VOTING_PERIOD,
            woodToken: woodToken,
            slashAppealSeed: 0,
            epochZeroSeed: 0
        });

        vm.startBroadcast();
        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Network: Robinhood Chain (chain ID 4663)");

        // Canonical core ceremony (CREATE3, order-independent + setFactory).
        // Called on `this` so `msg.sender` inside deployCore is the broadcaster.
        Deployed memory d = deployCore(cfg);

        // ProtocolConfig ships with ZERO fee recipients (its constructor seeds
        // only the splits), and a zero recipient does NOT strand its leg — it
        // FOLDS INTO THE AGENT'S REMAINDER (`SyndicateGovernor._chargeManagementFee`,
        // and again in `_chargePerformanceFee`). So an unseated recipient is not
        // a missing payment, it is a silent re-routing of that leg to the
        // proposer, with nothing on-chain to notice.
        //
        // BOTH LEGS, NOT JUST THE PROTOCOL ONE. The guardian leg is the reason
        // MANAGEMENT_FEE_BPS is 200: 20% of management and 25% of performance
        // fund the guardian pool. Left unseated, that whole budget pays the
        // agent instead, and the fee level is sized for a pool receiving
        // nothing. Seat both inside the broadcast, while the deployer still
        // owns the config.
        _seatOwnerWrites(d, deployer);

        // Multisig handoff (final action inside the broadcast).
        if (!skipHandoff) _handoffRobinhood(d, ownerMultisig);

        vm.stopBroadcast();

        // `address(0)` for the multisig is how validation is told the handoff
        // was skipped — the fork posture, where the deployer keeps everything.
        _validateMainnet(d, deployer, skipHandoff ? address(0) : ownerMultisig, woodToken);

        // Persist. `_writeAddresses` patches the core keys in place, so the
        // external addresses (WETH / USDG / Uniswap / Chainlink feeds) that were
        // committed into chains/4663.json survive. SYNDICATE_GOVERNOR stays zero:
        // governors are per-vault, resolved via `factory.governorOf(vault)`.
        _writeAddresses("Robinhood Chain", deployer, d.factoryProxy, address(0), d.executorLib, d.vaultImpl);
        _patchAddress("GOVERNOR_BEACON", d.beacon);
        _patchAddress("PROTOCOL_CONFIG", d.protocolConfig);
        _patchAddress("GUARDIAN_REGISTRY", d.registryProxy);
        // TIER_REGISTRY is read as an env address by DeployPlanD and
        // WireTokenCourt; without this key the later phases have nothing to
        // read and the operator has to recover it from broadcast logs.
        _patchAddress("TIER_REGISTRY", d.tierRegistry);
        // CREATE3-salted, so not recoverable from a nonce; the factory's
        // `sandboxImpl()` is the only on-chain copy and reading it presupposes
        // already knowing the factory. Persist it for the CLI/SDK address books.
        _patchAddress("CALL_SANDBOX_IMPL", d.sandboxImpl);
        _patchAddress("STAKED_WOOD", d.swoodProxy);
        _patchAddress("WOOD_TOKEN", woodToken);

        console.log("SyndicateFactory:", d.factoryProxy);
        console.log("GovernorBeacon:", d.beacon);
        console.log("ProtocolConfig:", d.protocolConfig);
        console.log("GuardianRegistry:", d.registryProxy);
        console.log("StakedWood:", d.swoodProxy);
        console.log(
            "\nNext: forge script script/robinhood-mainnet/DeployPortfolioStrategy.s.sol --rpc-url robinhood --broadcast"
        );
    }

    /// @notice Every write that REQUIRES the deployer to still be the owner,
    ///         collected into one place so the set can be asserted as a set.
    /// @dev    THIS GROUPING IS THE POINT. Each of these is an `onlyOwner` write
    ///         on a contract `_handoffRobinhood` is about to transfer, so each
    ///         has exactly one window in which it is cheap and an eternity
    ///         afterwards in which it is a multisig chore. Scattered inline,
    ///         they were three unrelated-looking statements and one of them went
    ///         missing for the entire life of this script.
    ///
    ///         Fee recipients: `ProtocolConfig`'s constructor seeds only the
    ///         SPLITS, and a zero recipient does NOT strand its leg — it folds
    ///         into the agent's remainder in both `_chargeManagementFee` and
    ///         `_chargePerformanceFee`. So an unseated recipient is not a
    ///         missing payment, it is a SILENT RE-ROUTING to the proposer.
    ///         BOTH legs, not just the protocol one: the guardian leg is why
    ///         `MANAGEMENT_FEE_BPS` is 200, since 20% of management and 25% of
    ///         performance fund the guardian pool. Left unseated, that whole
    ///         budget pays the agent while depositors are charged at a rate
    ///         sized for a pool receiving nothing. Both are seeded to the
    ///         DEPLOYER as a PLACEHOLDER, never as the destination — the runbook
    ///         directs the multisig to repoint them after `acceptOwnership()`.
    ///
    ///         TierRegistry launch set: `deployCore` mints the registry EMPTY
    ///         and wires it into the factory; the attestations are separate
    ///         `onlyOwner` writes. The canonical `DeploySherwood.run()` makes
    ///         them, but this script overrides `run()` and calls `deployCore`
    ///         directly — so until this existed, the Robinhood ceremony deployed
    ///         an empty registry and handed it straight to the Safe. Not
    ///         cosmetic: `isCounterpartyAllowed` GATES CLONE-INIT, so an empty
    ///         registry makes every ConcentratedLiquidity clone revert
    ///         `CounterpartyNotAllowed` and makes
    ///         `DeployConcentratedLiquidityStrategy` refuse to run at all.
    ///         Caught by the fork redeploy, where phase 4 stopped on exactly
    ///         that.
    function _seatOwnerWrites(Deployed memory d, address deployer) internal {
        ProtocolConfig(d.protocolConfig).setProtocolFeeRecipient(deployer);
        ProtocolConfig(d.protocolConfig).setGuardiansFeeRecipient(deployer);
        _seedTierRegistry(deployer, d.tierRegistry);
    }

    /// @dev THE OWNERSHIP MODELS ARE NOT UNIFORM, and treating them as if they
    ///      were is what made this script revert on every real mainnet run.
    ///      Beacon / factory / registry / sWOOD are one-step `Ownable`, so
    ///      `transferOwnership` moves `owner()` immediately. `ProtocolConfig`
    ///      and `TierRegistry` are `Ownable2Step`, so the same call only ARMS
    ///      the transfer: `owner()` stays the deployer and the multisig has to
    ///      call `acceptOwnership()`. Validation has to expect each shape.
    ///
    ///      `TierRegistry` was missing here entirely. `deployCore` mints it
    ///      owned by the deployer and wires it into the factory, and nothing
    ///      afterwards moved it — so a mainnet ceremony handed five contracts to
    ///      the Safe and left the adapter-certification authority
    ///      (`proposeCertification`, `demote`, `setAdapterAllowed`) on the
    ///      deployer key, with no assertion anywhere to notice.
    function _handoffRobinhood(Deployed memory d, address ownerMultisig) internal {
        // Per-vault governors: the beacon (shared impl) and ProtocolConfig
        // (global fee params) are the governance handles — there is no
        // singleton governor proxy to hand off.
        Ownable(d.beacon).transferOwnership(ownerMultisig);
        Ownable(d.factoryProxy).transferOwnership(ownerMultisig);
        Ownable(d.registryProxy).transferOwnership(ownerMultisig);
        Ownable(d.swoodProxy).transferOwnership(ownerMultisig);

        Ownable2Step(d.protocolConfig).transferOwnership(ownerMultisig);
        Ownable2Step(d.tierRegistry).transferOwnership(ownerMultisig);
        console.log("RUNBOOK: the multisig MUST call acceptOwnership() on ProtocolConfig AND TierRegistry");
        // BOTH FEE LEGS CURRENTLY PAY THE DEPLOYER KEY. They are seeded there
        // because a zero recipient is worse — it folds the leg into the agent's
        // remainder silently — but the deployer is a seed value, not the
        // destination. Until the Safe re-points them, protocol revenue and the
        // entire guardian budget accrue to a single EOA.
        console.log("RUNBOOK: then, from the Safe, setProtocolFeeRecipient(treasury)");
        console.log("RUNBOOK: and setGuardiansFeeRecipient(guardian payout address)");
        console.log("RUNBOOK: until both are re-pointed, BOTH fee legs pay the deployer key.");
    }

    /// @param ownerMultisig the Safe the handoff targeted, or `address(0)` when
    ///        the handoff was skipped (fork posture: the deployer keeps all).
    function _validateMainnet(Deployed memory d, address deployer, address ownerMultisig, address wood) internal view {
        SyndicateFactory factory = SyndicateFactory(d.factoryProxy);

        bool handedOff = ownerMultisig != address(0);
        address oneStepOwner = handedOff ? ownerMultisig : deployer;
        // A two-step transfer never moves `owner()`; only `pendingOwner()`.
        address expectedPending = handedOff ? ownerMultisig : address(0);

        // Per-vault governors are minted at `createSyndicate`, so there is no
        // governor instance to inspect here. What's checkable at deploy time is
        // the beacon (shared impl + upgrade authority) and ProtocolConfig.
        _checkAddr("beacon.owner", Ownable(d.beacon).owner(), oneStepOwner);
        _checkAddr("factory.owner", Ownable(d.factoryProxy).owner(), oneStepOwner);
        _checkAddr("registry.owner", Ownable(d.registryProxy).owner(), oneStepOwner);
        _checkAddr("swood.owner", Ownable(d.swoodProxy).owner(), oneStepOwner);

        // The `Ownable2Step` pair. Asserting the PENDING owner is what catches a
        // deployer who never ran the `acceptOwnership()` runbook step.
        _checkAddr("protocolConfig.owner", Ownable(d.protocolConfig).owner(), deployer);
        _checkAddr("protocolConfig.pendingOwner", Ownable2Step(d.protocolConfig).pendingOwner(), expectedPending);
        _checkAddr("tierRegistry.owner", Ownable(d.tierRegistry).owner(), deployer);
        _checkAddr("tierRegistry.pendingOwner", Ownable2Step(d.tierRegistry).pendingOwner(), expectedPending);

        // BOTH RECIPIENTS, because a zero one folds its leg into the agent's
        // remainder rather than failing. Asserting only the protocol leg would
        // leave the guardian budget — the whole reason MANAGEMENT_FEE_BPS is
        // 200 — silently payable to the proposer.
        ProtocolConfig protocolConfig = ProtocolConfig(d.protocolConfig);
        _checkAddr("protocolConfig.protocolFeeRecipient", protocolConfig.protocolFeeRecipient(), deployer);
        _checkAddr("protocolConfig.guardiansFeeRecipient", protocolConfig.guardiansFeeRecipient(), deployer);

        _checkAddr("factory.beacon", factory.beacon(), d.beacon);
        // WITHOUT THIS THE PERMISSIONLESS TIER-2 PATH IS DEAD ON ARRIVAL. Every
        // vault binds its sandbox at `createSyndicate` and the binding is
        // set-once, so a factory that goes live unbound produces vaults that can
        // never run a payload and can never be repaired.
        //
        // The FUNDING CEILING is deliberately not asserted here. `tier2CallCapBps`
        // is per-governor and governors are minted at `createSyndicate`, so there
        // is no instance to seed at deploy time; and it is being left at its
        // 10,000 default (no tier-2-specific ceiling) by explicit decision — see
        // the change's tasks.md §6.2. What still bounds a payload is the
        // proposal's own envelope, the guardian coverage scaling, and the vault's
        // buffer and queue-reserve checks.
        //
        // NOT IN CONFLICT WITH `script/DeployPlanB.s.sol`, which pins
        // `TIER2_CALL_CAP_BPS = 200` and pre-flights it. THE TWO ACT AT DIFFERENT
        // LIFECYCLE POINTS: this assertion block runs during the CORE ceremony,
        // before any governor exists, so the only honest thing it can say about
        // the ceiling is that it has no subject. Plan B's constant is not a value
        // that script seats either — `setTier2CallCapBps` is `onlyVaultOwner`, a
        // role no deploy script holds — it is the POLICY figure its post-broadcast
        // MANUAL NEXT tells each vault owner to call with, AFTER `createSyndicate`
        // (`script/DeployPlanB.s.sol:327`, `:672`, `:1087`). Neither script writes
        // this parameter; one records that the ceremony leaves it inert, the other
        // recommends what the owner should later make it. Seeding it per vault is
        // exactly the escape hatch `openspec/specs/deployment-docs/spec.md:103`
        // names, and the gate that catches an owner who never did is
        // `script/CheckSyndicateParams.s.sol` (issue SHE-127/SHE-42;
        // `docs/pre-deployment-parameter-review.md`).
        _checkAddr("factory.sandboxImpl", factory.sandboxImpl(), d.sandboxImpl);
        _checkAddr("factory.tierRegistry", address(factory.tierRegistry()), d.tierRegistry);
        _checkAddr("factory.ensRegistrar", address(factory.ensRegistrar()), address(0));
        _checkAddr("factory.agentRegistry", address(factory.agentRegistry()), address(0));

        _checkAddr("swood.wood", address(StakedWood(d.swoodProxy).wood()), wood);
        _checkAddr("swood.registry", StakedWood(d.swoodProxy).registry(), d.registryProxy);
    }
}
