// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FizzAdapter — benign, fund-neutral batch target for the fuzz harness
///
/// @notice `SyndicateGovernor.propose` rejects an empty execute batch
///         (`EmptyExecuteCalls`), so every proposal needs at least one call —
///         and that call has to survive `SyndicateVault._guardBatchCalls`,
///         which checks the TierRegistry allowlist and the certified codehash.
///
/// @dev Deliberately moves no funds. The campaign targets the governance,
///      coverage and adjudication state machines, not strategy execution; a
///      value-moving batch target would add outflow-accounting noise to every
///      proposal without exercising anything the selected entry points cover.
///      Mirrors `TCE2EAdapter` in `test/TokenCourtEndToEnd.t.sol`, which the
///      repo's own end-to-end suite uses for exactly this purpose.
contract FizzAdapter {
    uint256 public pokes;
    uint256 public bumps;

    function poke() external {
        pokes++;
    }

    function bump() external {
        bumps++;
    }
}
