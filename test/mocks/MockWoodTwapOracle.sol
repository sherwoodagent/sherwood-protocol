// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title  MockWoodTwapOracle
/// @notice The two reads `ExposureLedger` makes of an `IWoodTwapOracle`,
///         directly settable so a fixture can put the market wherever the test
///         needs it, and degradable into each shape the ledger must survive.
///
/// @dev    THE MARKET SIDE OF THE PRODUCTION CONFIGURATION. Under design
///         revision 2 the ledger prices bonds from a market source and uses
///         `woodUsdPriceX8` only as a CAP, so a fixture that wires no oracle is
///         not a simplified ledger — it is a ledger that reverts `NoWoodPrice`
///         on every price read. Every suite that touches a price path wires one
///         of these, with the cap set ABOVE it, which is how the protocol ships.
///
///         Deliberately NOT the real accumulator arithmetic: that is exercised
///         against a verbatim `UniswapV2Pair._update` in
///         `test/pricing/WoodTwapOracle.t.sol`. What the ledger's tests need is
///         control over the ANSWER — including the malformed answers a
///         defensive consumer has to survive — not another copy of the maths.
contract MockWoodTwapOracle {
    uint256 public priceX8;
    bool public available = true;
    bool public pairValid = true;
    bool public consultReverts;
    bool public validateReverts;

    constructor(uint256 priceX8_) {
        priceX8 = priceX8_;
    }

    function setPrice(uint256 priceX8_) external {
        priceX8 = priceX8_;
    }

    /// @dev The stale-snapshot / dead-ETH-feed shape: the oracle answers, and
    ///      its answer is "I cannot price this".
    function setAvailable(bool available_) external {
        available = available_;
    }

    function setPairValid(bool valid_) external {
        pairValid = valid_;
    }

    /// @dev The wired-then-broke shape. Wiring validates the pair, so an oracle
    ///      that reverts on `consult()` has to be able to pass `validatePair()`
    ///      at wire time and fail later — which is exactly how a real one
    ///      degrades.
    function setConsultReverts(bool reverts_) external {
        consultReverts = reverts_;
    }

    function setValidateReverts(bool reverts_) external {
        validateReverts = reverts_;
    }

    function consult() external view returns (uint256, bool) {
        if (consultReverts) revert("oracle down");
        return (priceX8, available);
    }

    function validatePair() external view returns (bool) {
        if (validateReverts) revert("oracle down");
        return pairValid;
    }
}

/// @dev Returns a DIRTY BOOLEAN WORD from `consult()` — 2, not 0 or 1.
///
///      This is the shape that motivated decoding the flag as a `uint256`:
///      `abi.decode(ret, (uint256, bool))` reverts on any second word outside
///      {0, 1}, and it reverts in the CALLER's frame, where no `try` can catch
///      it. A wired contract like this would otherwise take the whole price
///      path down, which is precisely what the defensive wrapper exists to
///      stop. Reachable in practice from a non-Solidity contract, a proxy
///      returning garbage, or an address that used to be something else.
///
///      `validatePair()` answers honestly so the thing can actually be wired;
///      the fallback catches `consult()`.
contract DirtyFlagWoodTwapOracle {
    uint256 public priceX8;

    constructor(uint256 priceX8_) {
        priceX8 = priceX8_;
    }

    function validatePair() external pure returns (bool) {
        return true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(priceX8, uint256(2));
    }
}

/// @dev Returns TOO FEW WORDS from `consult()` — one, where two are expected.
///      `abi.decode` would revert on short data; the ledger rejects it on
///      length before decoding.
contract ShortReturnWoodTwapOracle {
    function validatePair() external pure returns (bool) {
        return true;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return abi.encode(uint256(1));
    }
}
