// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Stands in for `ChallengeGame` as `ExposureLedger.coverageFreezer`
///         wherever a fixture only needs an address that may call the
///         `onlyFreezer` surface (prank as `address(this mock)`).
///
///         Since SHE-214 the ledger REFUSES a non-zero freezer that cannot
///         answer `challengeWindow()` — `setCoverageFreezer` reads it on the
///         incoming address and `setChallengeWindow` on the wired one — so a
///         codeless `makeAddr` no longer wires. This mock answers with a
///         settable window (no ledger-side floor, unlike the real game, so a
///         test can seat a divergence AFTER wiring) and can be muted to model
///         a game that stops answering.
contract MockCoverageFreezer {
    uint256 internal _window;
    bool public muted;

    constructor(uint256 window_) {
        _window = window_;
    }

    function challengeWindow() external view returns (uint256) {
        require(!muted, "MockCoverageFreezer: muted");
        return _window;
    }

    /// @dev Unchecked against any ledger, deliberately.
    function setChallengeWindow(uint256 window_) external {
        _window = window_;
    }

    function setMuted(bool muted_) external {
        muted = muted_;
    }
}
