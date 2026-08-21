// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CheckSyndicateParams} from "../../script/CheckSyndicateParams.s.sol";

/// @dev The gate is `internal` on the script, which is the right place for it —
///      this only lifts it into reach, the same shape
///      `DeployConcentratedLiquidityStrategy.t.sol` uses. The rule is exercised
///      through VALUES (`_requireSeeded`) and the reads through STUBS
///      (`_readParams`), so neither test needs a staged chain.
contract CheckSyndicateParamsHarness is CheckSyndicateParams {
    function exposed_requireSeeded(
        uint256 tier2CallCapBps,
        uint256 maxCapitalBps,
        uint16 minBufferBps,
        bool allowInertTier2CallCap,
        bool allowInertMaxCapital,
        bool allowZeroMinBuffer
    ) external pure {
        _requireSeeded(
            tier2CallCapBps,
            maxCapitalBps,
            minBufferBps,
            allowInertTier2CallCap,
            allowInertMaxCapital,
            allowZeroMinBuffer
        );
    }

    function exposed_readParams(address governor, address vault) external view returns (uint256, uint256, uint16) {
        return _readParams(governor, vault);
    }
}

/// @notice Answers the two governor reads the gate makes, and nothing else.
contract GovernorStub {
    uint256 public tier2CallCapBps;
    uint256 public maxCapitalBps;

    constructor(uint256 tier2CallCapBps_, uint256 maxCapitalBps_) {
        tier2CallCapBps = tier2CallCapBps_;
        maxCapitalBps = maxCapitalBps_;
    }
}

contract VaultStub {
    uint16 public minBufferBps;

    constructor(uint16 minBufferBps_) {
        minBufferBps = minBufferBps_;
    }
}

/// @notice A contract that answers every call with empty return data — the
///         shape a WRONG ADDRESS takes (a proxy with a permissive fallback, or
///         a contract predating the selector). Fails closed, not open.
contract MuteStub {
    fallback() external {}
}

/// @title CheckSyndicateParams — the inert-default gate
///
/// @notice `tier2CallCapBps` and `maxCapitalBps` read as 10_000 while unset and
///         `minBufferBps` is a plain 0, so a syndicate ships with no per-call
///         tier-2 ceiling, no envelope ceiling and no idle-liquidity floor
///         unless somebody makes three owner calls after `createSyndicate`.
///         Nothing on-chain requires those calls; this gate is what stands in
///         for the missing requirement, so it is the gate itself that has to be
///         proven — a check that cannot fail is worse than no check.
contract CheckSyndicateParamsTest is Test {
    CheckSyndicateParamsHarness internal gate;

    uint256 internal constant SEEDED_TIER2 = 200;
    uint256 internal constant SEEDED_MAX_CAPITAL = 8_000;
    uint16 internal constant SEEDED_BUFFER = 500;

    function setUp() public {
        gate = new CheckSyndicateParamsHarness();
    }

    // ── The rule ────────────────────────────────────────────────────────────

    /// @dev NON-VACUITY CONTROL for every revert case below: the recommended
    ///      seed values pass with no waiver at all. Without this the gate could
    ///      be one that refuses everything.
    function test_requireSeeded_passesOnSeededValues() public view {
        gate.exposed_requireSeeded(SEEDED_TIER2, SEEDED_MAX_CAPITAL, SEEDED_BUFFER, false, false, false);
    }

    function test_requireSeeded_rejectsInertTier2CallCap() public {
        vm.expectRevert(bytes(_reasonFor(10_000, SEEDED_MAX_CAPITAL, SEEDED_BUFFER)));
        gate.exposed_requireSeeded(10_000, SEEDED_MAX_CAPITAL, SEEDED_BUFFER, false, false, false);
    }

    function test_requireSeeded_rejectsInertMaxCapital() public {
        vm.expectRevert(bytes(_reasonFor(SEEDED_TIER2, 10_000, SEEDED_BUFFER)));
        gate.exposed_requireSeeded(SEEDED_TIER2, 10_000, SEEDED_BUFFER, false, false, false);
    }

    function test_requireSeeded_rejectsZeroMinBuffer() public {
        vm.expectRevert(bytes(_reasonFor(SEEDED_TIER2, SEEDED_MAX_CAPITAL, 0)));
        gate.exposed_requireSeeded(SEEDED_TIER2, SEEDED_MAX_CAPITAL, 0, false, false, false);
    }

    /// @dev The whole-hog case — a syndicate on which nobody ran anything. All
    ///      three offenders must be named in ONE run: an operator who has to
    ///      re-run the gate three times to find three omissions stops running it.
    function test_requireSeeded_namesEveryOffenderInOneRun() public {
        string memory reason = _reasonFor(10_000, 10_000, 0);
        assertTrue(_contains(reason, "tier2CallCapBps is 10_000"), "tier2 named");
        assertTrue(_contains(reason, "maxCapitalBps is 10_000"), "maxCapital named");
        assertTrue(_contains(reason, "minBufferBps is 0"), "minBuffer named");

        vm.expectRevert(bytes(reason));
        gate.exposed_requireSeeded(10_000, 10_000, 0, false, false, false);
    }

    /// @dev A waiver is per-parameter, so waiving one must not waive the others.
    function test_requireSeeded_waiverIsPerParameter() public {
        // Tier-2 waived, the other two still inert -> still refused, and the
        // reason no longer mentions tier2.
        string memory reason = _reasonFor(SEEDED_TIER2, 10_000, 0);
        assertFalse(_contains(reason, "tier2CallCapBps"), "waived param must not be reported");

        vm.expectRevert(bytes(reason));
        gate.exposed_requireSeeded(10_000, 10_000, 0, true, false, false);
    }

    function test_requireSeeded_allThreeWaivedPasses() public view {
        gate.exposed_requireSeeded(10_000, 10_000, 0, true, true, true);
    }

    /// @dev The boundary: 9_999 is not the sentinel. A gate keyed on ">= some
    ///      threshold" would wrongly refuse a deliberate near-100% policy.
    function test_requireSeeded_onlyTheExactSentinelIsInert() public view {
        gate.exposed_requireSeeded(9_999, 9_999, 1, false, false, false);
    }

    // ── The reads ───────────────────────────────────────────────────────────

    function test_readParams_readsBothContracts() public {
        address governor = address(new GovernorStub(SEEDED_TIER2, SEEDED_MAX_CAPITAL));
        address vault = address(new VaultStub(SEEDED_BUFFER));

        (uint256 tier2, uint256 maxCapital, uint16 buffer) = gate.exposed_readParams(governor, vault);
        assertEq(tier2, SEEDED_TIER2);
        assertEq(maxCapital, SEEDED_MAX_CAPITAL);
        assertEq(buffer, SEEDED_BUFFER);
    }

    /// @dev An EOA — the classic wrong-address paste. Fails with a NAMED reason,
    ///      not the undecodable empty revert a typed call would produce.
    function test_readParams_refusesCodelessGovernor() public {
        address vault = address(new VaultStub(SEEDED_BUFFER));
        vm.expectRevert(bytes("GOVERNOR did not answer tier2CallCapBps() (no code at address)"));
        gate.exposed_readParams(address(0xBEEF), vault);
    }

    function test_readParams_refusesCodelessVault() public {
        address governor = address(new GovernorStub(SEEDED_TIER2, SEEDED_MAX_CAPITAL));
        vm.expectRevert(bytes("VAULT did not answer minBufferBps() (no code at address)"));
        gate.exposed_readParams(governor, address(0xBEEF));
    }

    /// @dev A contract that swallows the call and returns nothing. `ok` is TRUE
    ///      here — only the returndata length distinguishes it — which is the
    ///      case a bare `(bool ok, ) = staticcall` would sail straight past and
    ///      then `abi.decode` into a zero, i.e. into "inert", i.e. into a
    ///      refusal for the WRONG reason.
    function test_readParams_refusesEmptyReturndata() public {
        address vault = address(new VaultStub(SEEDED_BUFFER));
        // HOISTED. `new MuteStub()` in argument position is evaluated BEFORE the
        // call and consumes the armed one-shot `expectRevert`, which fails as
        // "next call did not revert as expected" — i.e. as the opposite finding.
        address mute = address(new MuteStub());
        vm.expectRevert(bytes("GOVERNOR did not answer tier2CallCapBps()"));
        gate.exposed_readParams(mute, vault);
    }

    /// @dev A word that does not fit `uint16` is not a buffer value; it is a
    ///      read of something else entirely.
    function test_readParams_refusesOversizedBufferWord() public {
        address governor = address(new GovernorStub(SEEDED_TIER2, SEEDED_MAX_CAPITAL));
        address vault = address(new GovernorStub(0, 0)); // wrong contract, right-ish shape
        vm.mockCall(vault, abi.encodeWithSignature("minBufferBps()"), abi.encode(uint256(70_000)));
        vm.expectRevert(bytes("VAULT minBufferBps() overflows uint16 -- wrong address?"));
        gate.exposed_readParams(governor, vault);
    }

    // ── run(): the env wiring ───────────────────────────────────────────────

    /// @dev The three `ALLOW_*` names live ONLY inside `run()`; every test above
    ///      drives `_requireSeeded` directly with booleans, so a typo in an env
    ///      var name — or a waiver wired to the wrong parameter — would be
    ///      invisible to all of them. The revert strings and
    ///      `docs/pre-deployment-parameter-review.md` both promise these exact
    ///      names, so the promise is what gets pinned here.
    ///
    ///      ONE TEST, NOT FOUR, DELIBERATELY. `vm.setEnv` mutates the FORGE
    ///      PROCESS's environment, which is shared by every test in the suite,
    ///      while forge is free to run those tests concurrently. Split across
    ///      four functions these raced: the all-waivers case set the three vars
    ///      to "true" while the no-waiver case was reading them, and the
    ///      no-waiver case failed as "next call did not revert as expected" —
    ///      i.e. reported the gate as broken when the gate was fine. Sequencing
    ///      the states inside a single function is what makes them deterministic.
    function test_run_envWiring() public {
        address seededGov = address(new GovernorStub(SEEDED_TIER2, SEEDED_MAX_CAPITAL));
        address seededVault = address(new VaultStub(SEEDED_BUFFER));
        address virginGov = address(new GovernorStub(10_000, 10_000));
        address virginVault = address(new VaultStub(0));

        vm.setEnv("ALLOW_INERT_TIER2_CALL_CAP", "false");
        vm.setEnv("ALLOW_INERT_MAX_CAPITAL", "false");
        vm.setEnv("ALLOW_ZERO_MIN_BUFFER", "false");

        // 1. A seeded syndicate passes with no waiver. NON-VACUITY CONTROL for
        //    every refusal below: the gate is not one that refuses everything.
        vm.setEnv("GOVERNOR", vm.toString(seededGov));
        vm.setEnv("VAULT", vm.toString(seededVault));
        gate.run();

        // 2. A virgin syndicate is refused, and `run()` reads BOTH contracts —
        //    the vault's zero buffer is named, not just the governor's pair.
        vm.setEnv("GOVERNOR", vm.toString(virginGov));
        vm.setEnv("VAULT", vm.toString(virginVault));
        vm.expectRevert(bytes(_reasonFor(10_000, 10_000, 0)));
        gate.run();

        // 3. Waiving only the buffer must leave the two governor parameters
        //    reported — i.e. each name binds to the parameter it names.
        vm.setEnv("ALLOW_ZERO_MIN_BUFFER", "true");
        vm.expectRevert(bytes(_reasonFor(10_000, 10_000, 1)));
        gate.run();

        // 4. All three waived, same virgin syndicate, now accepted. An unset or
        //    misspelled var defaults to `false`, so a typo would leave this
        //    reverting — which is what makes step 4 evidence about the NAMES.
        vm.setEnv("ALLOW_INERT_TIER2_CALL_CAP", "true");
        vm.setEnv("ALLOW_INERT_MAX_CAPITAL", "true");
        gate.run();

        // Leave the process env as we found it; the suite is shared.
        vm.setEnv("ALLOW_INERT_TIER2_CALL_CAP", "false");
        vm.setEnv("ALLOW_INERT_MAX_CAPITAL", "false");
        vm.setEnv("ALLOW_ZERO_MIN_BUFFER", "false");
    }

    // ── helpers ─────────────────────────────────────────────────────────────

    /// @dev Rebuilds the expected revert string from the same pieces the script
    ///      uses, so `vm.expectRevert` pins the MESSAGE and not merely the fact
    ///      that something reverted.
    function _reasonFor(uint256 tier2, uint256 maxCapital, uint16 buffer) internal pure returns (string memory) {
        string memory reason = "INERT PARAMETERS -- see docs/pre-deployment-parameter-review.md:";
        if (tier2 == 10_000) {
            reason = string.concat(
                reason,
                " tier2CallCapBps is 10_000 (100% of TVL), so sandbox funding and every tier-2 per-call"
                " declaration are unbounded -- governor.setTier2CallCapBps(<bps>) or ALLOW_INERT_TIER2_CALL_CAP=true;"
            );
        }
        if (maxCapital == 10_000) {
            reason = string.concat(
                reason,
                " maxCapitalBps is 10_000, so one proposal may declare the whole vault as its envelope --"
                " governor.setMaxCapitalBps(<bps>) or ALLOW_INERT_MAX_CAPITAL=true;"
            );
        }
        if (buffer == 0) {
            reason = string.concat(
                reason,
                " minBufferBps is 0, so a batch may deploy the entire unreserved float --"
                " vault.setMinBufferBps(<bps>) or ALLOW_ZERO_MIN_BUFFER=true;"
            );
        }
        return reason;
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool hit = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    hit = false;
                    break;
                }
            }
            if (hit) return true;
        }
        return false;
    }
}
