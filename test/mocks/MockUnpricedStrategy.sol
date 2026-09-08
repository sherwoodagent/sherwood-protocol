// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Strategy stand-in that controls exactly what `unpricedCostBasis()`
///         reports, so settlement's handling of that number can be tested
///         adversarially rather than only on the honest path.
/// @dev    Deliberately does NOT implement `IStrategy.proposer()`: `propose`
///         binds a strategy's proposer only when the address answers that call,
///         so staying silent keeps these fixtures usable without a factory.
contract MockUnpricedStrategy {
    uint256 public basis;
    bool public probeReverts;
    bool public burnGas;
    bool public declares;

    /// @dev The template's propose-time declaration. Set BEFORE proposing —
    ///      the governor snapshots it onto the proposal at that moment.
    function setDeclares(bool v) external {
        declares = v;
    }

    function expectsUnpricedResidue() external view returns (bool) {
        return declares;
    }

    function setBasis(uint256 b) external {
        basis = b;
    }

    function setProbeReverts(bool v) external {
        probeReverts = v;
    }

    /// @dev Burns unbounded gas so the probe's `_PROBE_GAS` ceiling is what
    ///      stops it. Proves the cap bounds a hostile template rather than
    ///      letting it consume the settling caller's whole budget.
    function setBurnGas(bool v) external {
        burnGas = v;
    }

    function unpricedCostBasis() external view returns (uint256) {
        if (probeReverts) revert("probe");
        if (burnGas) {
            uint256 acc;
            for (uint256 i = 0; i < type(uint256).max; i++) {
                acc = uint256(keccak256(abi.encode(acc, i)));
            }
            return acc;
        }
        return basis;
    }
}

/// @notice A strategy with no `unpricedCostBasis()` at all — a template
///         compiled before the view existed. The probe must treat it as zero.
contract MockStrategyWithoutBasis {
    uint256 public placeholder;
}
