// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title FizzFactory — minimal stand-in for `SyndicateFactory` in the fuzz harness
///
/// @notice Exists for one structural reason: the harness cannot be its own
///         factory.
///
/// @dev Under Medusa and Echidna, `Base.setup()` runs inside `FuzzTester`'s
///      CONSTRUCTOR, so `address(FuzzTester).code.length == 0` for its whole
///      duration. `SyndicateVault._getGovernor()` resolves the governor with an
///      external `factory.governorOf(vault)` call, which every deposit and every
///      `onlyGovernor` check reaches — and an external call into a
///      still-constructing contract reverts. Foundry hides this because `setUp()`
///      runs after deployment; the fuzzers do not.
///
///      `SyndicateVault.initialize` also records `_factory = msg.sender`, so the
///      vault proxy has to be deployed BY this contract rather than by the
///      harness. `deployProxy` exists for that.
///
///      Deliberately unowned and unguarded: it is test scaffolding, and the
///      access control under test lives in the real contracts that point AT it.
contract FizzFactory {
    mapping(address vault => address governor) private _governorOf;

    /// @notice Deploy an ERC-1967 proxy from this contract's context so the
    ///         callee records `msg.sender == address(this)` as its factory.
    function deployProxy(address impl, bytes calldata initData) external returns (address) {
        return address(new ERC1967Proxy(impl, initData));
    }

    function setGovernor(address vault, address governor) external {
        _governorOf[vault] = governor;
    }

    /// @notice The lookup `StakedWood` and `SyndicateVault` depend on.
    function governorOf(address vault) external view returns (address) {
        return _governorOf[vault];
    }

    /// @notice Forward an arbitrary call so factory-gated setters
    ///         (`setWithdrawalQueue`, `SyndicateGovernor.set*`,
    ///         `GuardianRegistry.addGovernor`) run with this contract as
    ///         `msg.sender`.
    function forwardCall(address target, bytes calldata data) external returns (bytes memory) {
        (bool ok, bytes memory ret) = target.call(data);
        require(ok, "FizzFactory: forwarded call failed");
        return ret;
    }
}
