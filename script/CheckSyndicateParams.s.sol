// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ScriptBase} from "./ScriptBase.sol";

/**
 * @notice Post-`createSyndicate` gate: refuse a syndicate whose three risk
 *         parameters are still at their INERT defaults.
 *
 *         READ-ONLY. `run()` is `view` and there is no `vm.startBroadcast` —
 *         this script cannot send a transaction, and cannot seed anything
 *         either. Seeding is three owner calls the operator makes by hand
 *         (`docs/pre-deployment-parameter-review.md` §4); this is the check
 *         that they happened.
 *
 *         WHY A SEPARATE SCRIPT AND NOT A DEPLOY-SCRIPT PRE-FLIGHT. All three
 *         parameters live on contracts the core ceremony does not mint:
 *         `tier2CallCapBps` and `maxCapitalBps` are per-GOVERNOR and
 *         `minBufferBps` is per-VAULT, and both are minted by
 *         `SyndicateFactory.createSyndicate` — strictly after every deploy
 *         script has finished. There is no instance to assert against at deploy
 *         time, which is exactly why `script/robinhood-mainnet/Deploy.s.sol`
 *         records the ceiling as deliberately unasserted rather than asserting
 *         it. This script runs at the lifecycle point where the instances exist.
 *
 *         THE INERT VALUE IS A LEGITIMATE ANSWER, but it has to be an ANSWER.
 *         Each parameter has its own waiver env var; setting one records the
 *         decision in the command line that ran the ceremony instead of leaving
 *         an omission indistinguishable from a choice. `minBufferBps` needs this
 *         most: it has no unset sentinel, so a deliberate `setMinBufferBps(0)`
 *         and never calling the setter are byte-identical on chain.
 *
 *   Environment:
 *     GOVERNOR                     — REQUIRED. The syndicate's governor proxy
 *                                    (`factory.governorOf(vault)`).
 *     VAULT                        — REQUIRED. The syndicate's vault proxy.
 *     ALLOW_INERT_TIER2_CALL_CAP   — "true" to accept `tier2CallCapBps == 10_000`.
 *     ALLOW_INERT_MAX_CAPITAL      — "true" to accept `maxCapitalBps == 10_000`.
 *     ALLOW_ZERO_MIN_BUFFER        — "true" to accept `minBufferBps == 0`.
 *
 *   Usage:
 *     GOVERNOR=0x.. VAULT=0x.. \
 *       forge script script/CheckSyndicateParams.s.sol:CheckSyndicateParams --rpc-url robinhood
 */
contract CheckSyndicateParams is ScriptBase {
    /// @notice `GovernorParameters.tier2CallCapBps()` / `maxCapitalBps()` map a
    ///         stored 0 to this, so reading it means "no ceiling binds".
    uint256 internal constant INERT_BPS = 10_000;

    /// @notice `SyndicateVault.minBufferBps` is plain storage with no sentinel:
    ///         0 is literally "off" (`src/SyndicateVault.sol:209`).
    uint16 internal constant INERT_MIN_BUFFER_BPS = 0;

    function run() external view {
        address governor = vm.envAddress("GOVERNOR");
        address vault = vm.envAddress("VAULT");
        require(governor != address(0), "GOVERNOR required");
        require(vault != address(0), "VAULT required");

        (uint256 tier2CallCapBps, uint256 maxCapitalBps, uint16 minBufferBps) = _readParams(governor, vault);

        console.log("governor            %s", governor);
        console.log("vault               %s", vault);
        console.log("tier2CallCapBps     %s", tier2CallCapBps);
        console.log("maxCapitalBps       %s", maxCapitalBps);
        console.log("minBufferBps        %s", uint256(minBufferBps));

        _requireSeeded(
            tier2CallCapBps,
            maxCapitalBps,
            minBufferBps,
            vm.envOr("ALLOW_INERT_TIER2_CALL_CAP", false),
            vm.envOr("ALLOW_INERT_MAX_CAPITAL", false),
            vm.envOr("ALLOW_ZERO_MIN_BUFFER", false)
        );

        console.log("OK: no parameter is sitting at an un-waived inert default.");
    }

    /// @dev RAW STATICCALLS, not typed calls. A typed call against an address
    ///      that is not the contract you think it is reverts in THIS frame with
    ///      no return data, which is undecodable — the operator sees a bare
    ///      revert and cannot tell a wrong address from a broken script. An
    ///      explicit `ret.length` check turns the same mistake into a named
    ///      refusal. Same pattern as `ExposureLedger._feedPriceX8` and
    ///      `SyndicateVault._pricingSupply`; this one FAILS CLOSED in every
    ///      branch, because a check that cannot read its subject has not passed.
    function _readParams(address governor, address vault)
        internal
        view
        returns (uint256 tier2CallCapBps, uint256 maxCapitalBps, uint16 minBufferBps)
    {
        tier2CallCapBps = _readUint(governor, "tier2CallCapBps()", "GOVERNOR did not answer tier2CallCapBps()");
        maxCapitalBps = _readUint(governor, "maxCapitalBps()", "GOVERNOR did not answer maxCapitalBps()");
        uint256 buffer = _readUint(vault, "minBufferBps()", "VAULT did not answer minBufferBps()");
        require(buffer <= type(uint16).max, "VAULT minBufferBps() overflows uint16 -- wrong address?");
        minBufferBps = uint16(buffer);
    }

    function _readUint(address target, string memory signature, string memory failure) private view returns (uint256) {
        require(target.code.length != 0, string.concat(failure, " (no code at address)"));
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(signature));
        require(ok && ret.length == 32, failure);
        return abi.decode(ret, (uint256));
    }

    /// @dev PURE, and takes the values rather than the addresses, so the RULE is
    ///      testable without staging a chain. Reports every offender in one run:
    ///      an operator who has to re-run the gate three times to discover three
    ///      omissions will stop running it.
    function _requireSeeded(
        uint256 tier2CallCapBps,
        uint256 maxCapitalBps,
        uint16 minBufferBps,
        bool allowInertTier2CallCap,
        bool allowInertMaxCapital,
        bool allowZeroMinBuffer
    ) internal pure {
        bool tier2Inert = !allowInertTier2CallCap && tier2CallCapBps == INERT_BPS;
        bool maxCapitalInert = !allowInertMaxCapital && maxCapitalBps == INERT_BPS;
        bool bufferInert = !allowZeroMinBuffer && minBufferBps == INERT_MIN_BUFFER_BPS;

        if (!tier2Inert && !maxCapitalInert && !bufferInert) return;

        string memory reason = "INERT PARAMETERS -- see docs/pre-deployment-parameter-review.md:";
        if (tier2Inert) {
            reason = string.concat(
                reason,
                " tier2CallCapBps is 10_000 (100% of TVL), so sandbox funding and every tier-2 per-call"
                " declaration are unbounded -- governor.setTier2CallCapBps(<bps>) or ALLOW_INERT_TIER2_CALL_CAP=true;"
            );
        }
        if (maxCapitalInert) {
            reason = string.concat(
                reason,
                " maxCapitalBps is 10_000, so one proposal may declare the whole vault as its envelope --"
                " governor.setMaxCapitalBps(<bps>) or ALLOW_INERT_MAX_CAPITAL=true;"
            );
        }
        if (bufferInert) {
            reason = string.concat(
                reason,
                " minBufferBps is 0, so a batch may deploy the entire unreserved float --"
                " vault.setMinBufferBps(<bps>) or ALLOW_ZERO_MIN_BUFFER=true;"
            );
        }
        revert(reason);
    }
}
