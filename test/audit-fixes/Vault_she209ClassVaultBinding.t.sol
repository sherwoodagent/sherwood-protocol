// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";

/// @dev A TierRegistry that admits adapters AND reports a code class for them,
///      the two axes the SHE-209 vault-binding check reads. `classOf` returning
///      non-zero is the exact signal that a recipient was admitted via the
///      code-class fallback rather than an explicit per-address grant.
contract ClassAwareTierRegistry {
    mapping(address => bool) public isAdapterAllowed;
    mapping(address => bool) public isCallableTarget;
    mapping(address => bytes32) internal _class;

    /// @param cls non-zero to model class admission; `bytes32(0)` to model an
    ///        explicit per-address grant (no class).
    function allow(address a, bytes32 cls) external {
        isAdapterAllowed[a] = true;
        isCallableTarget[a] = true;
        _class[a] = cls;
    }

    function classOf(address a) external view returns (bytes32) {
        return _class[a];
    }

    function isCounterpartyAllowed(address a) external view returns (bool) {
        return isAdapterAllowed[a];
    }
}

/// @dev Minimal stand-in for a strategy clone: it exposes `vault()`, the one
///      slot an unpermissioned `initialize` sets and the only thing the
///      SHE-209 fix binds. A real ERC-1167 clone's `_vault` is set the same
///      permissionless way; here it is fixed at construction for the test.
contract StrategyCloneStub {
    address public vault;

    constructor(address v) {
        vault = v;
    }
}

/// @dev A recipient with no `vault()` getter at all — models an EXPLICIT-grant
///      adapter (router / token / Permit2) that is not a certified-template
///      clone. `classOf` returns 0 for it, so the binding check is skipped and
///      the missing `vault()` never matters.
contract PlainAdapter {}

/// @dev A class member whose `vault()` returns THIS vault's address with dirty
///      upper bits — an ABI-invalid word. `abi.decode(_, (address))` reverts
///      with EMPTY returndata on it (same refusal, no named error); the guard
///      masks instead, so the refusal is the named `AdapterVaultMismatch`.
contract DirtyVaultStub {
    uint256 immutable dirtyWord;

    constructor(address v) {
        dirtyWord = uint256(uint160(v)) | (uint256(1) << 160);
    }

    fallback() external {
        uint256 w = dirtyWord;
        assembly {
            mstore(0, w)
            return(0, 32)
        }
    }
}

/// @title Vault_she209ClassVaultBinding
/// @notice SHE-209 — the TierRegistry code-class allowlist admits ANY address
///         whose codehash is a certified template's ERC-1167 clone. Codehash
///         pins the clone's CODE but not its `_vault` STORAGE, which an
///         unpermissioned `initialize` lets an attacker set to an address they
///         control; the strategy's `_pushAllToVault` then ships batch funds
///         there. `SyndicateVault._requireRecipientVaultBinding` closes it by
///         requiring a class-admitted recipient to name THIS vault as its own.
contract VaultShe209ClassVaultBindingTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    ClassAwareTierRegistry tiers;

    address owner = makeAddr("owner");
    address attacker = makeAddr("attacker");
    address constant MOCK_GOVERNOR = address(0xF00D);
    bytes32 constant CLASS = keccak256("certified-template-class");

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        tiers = new ClassAwareTierRegistry();

        SyndicateVault impl = new SyndicateVault();
        bytes memory initData = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault",
                    symbol: "swUSDC",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vault = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), initData))));

        queue = new VaultWithdrawalQueue(address(vault));
        vault.setWithdrawalQueue(address(queue));

        vm.mockCall(address(this), abi.encodeWithSignature("governorOf(address)"), abi.encode(MOCK_GOVERNOR));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getActiveProposal()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("openProposalCount()"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("getCapitalSnapshot(uint256)"), abi.encode(uint256(0)));
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("tierRegistry()"), abi.encode(address(tiers)));

        // Fund the vault so the guarded call is a real asset() transfer.
        usdc.mint(address(vault), 1_000e6);
    }

    /// @dev A zero-amount asset() transfer to `recipient`: it still carries the
    ///      recipient in calldata, so `_guardBatchCalls` runs the recipient
    ///      gate, but moves no value — isolating the guard's decision from the
    ///      net-outflow / buffer meters.
    function _transferBatch(address recipient) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (recipient, 0))
        });
    }

    /// @notice THE ATTACK. A clone admitted purely by its code class, whose
    ///         `vault()` points at the attacker, is refused as a batch fund
    ///         recipient.
    function test_she209_rogueCloneRecipient_reverts() public {
        StrategyCloneStub rogue = new StrategyCloneStub(attacker);
        tiers.allow(address(rogue), CLASS);

        // Control: without the fix, isAdapterAllowed alone would admit it.
        assertTrue(tiers.isAdapterAllowed(address(rogue)), "class admits the rogue clone");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, address(rogue)));
        vault.executeGovernorBatch(_transferBatch(address(rogue)), new uint256[](0), 1);
    }

    /// @notice THE CONTROL. The identical batch, with a clone whose `vault()`
    ///         is THIS vault, passes the guard. Pins that the fix binds by
    ///         destination, not by rejecting the class outright — otherwise the
    ///         reject test above would be vacuous.
    function test_she209_vaultBoundCloneRecipient_passesGuard() public {
        StrategyCloneStub legit = new StrategyCloneStub(address(vault));
        tiers.allow(address(legit), CLASS);

        vm.prank(MOCK_GOVERNOR);
        // No revert: guard admits a class member bound to this vault.
        vault.executeGovernorBatch(_transferBatch(address(legit)), new uint256[](0), 1);
    }

    /// @notice EXPLICIT GRANTS ARE EXEMPT. A non-clone adapter (classOf == 0)
    ///         with no `vault()` getter is still admitted — the binding check
    ///         only ever fires on the code-class path, so owner-vetted routers /
    ///         tokens / Permit2 are unaffected.
    function test_she209_explicitGrantNonClone_isExempt() public {
        PlainAdapter router = new PlainAdapter();
        tiers.allow(address(router), bytes32(0)); // explicit grant, no class

        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_transferBatch(address(router)), new uint256[](0), 1);
    }

    /// @notice A class member whose `vault()` word carries dirty upper bits is
    ///         refused with the NAMED error, not an opaque empty revert
    ///         (finding 5). The low 160 bits ARE this vault, which pins that the
    ///         mask resolves the word to `address(0)` rather than truncating it
    ///         into a pass.
    function test_she209_dirtyVaultWord_revertsNamed() public {
        DirtyVaultStub dirty = new DirtyVaultStub(address(vault));
        tiers.allow(address(dirty), CLASS);

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, address(dirty)));
        vault.executeGovernorBatch(_transferBatch(address(dirty)), new uint256[](0), 1);
    }

    /// @notice A class member that cannot even answer `vault()` fails CLOSED —
    ///         it is a confirmed class member (classOf != 0) whose binding is
    ///         unprovable, so it must not be paid.
    function test_she209_classMemberWithoutVaultGetter_failsClosed() public {
        PlainAdapter noVault = new PlainAdapter();
        tiers.allow(address(noVault), CLASS); // class-admitted but no vault()

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, address(noVault)));
        vault.executeGovernorBatch(_transferBatch(address(noVault)), new uint256[](0), 1);
    }
}
