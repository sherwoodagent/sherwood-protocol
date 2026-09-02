// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {IStrategy} from "../../src/interfaces/IStrategy.sol";
import {TierRegistry} from "../../src/TierRegistry.sol";
import {VaultWithdrawalQueue} from "../../src/queue/VaultWithdrawalQueue.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockAgentRegistry} from "../mocks/MockAgentRegistry.sol";
import {MockStrategy} from "../mocks/MockStrategy.sol";

/// @title Vault_she209RealRegistryBinding
/// @notice SHE-209 against the REAL `TierRegistry`, the REAL certification
///         ceremony, and a REAL permissionless `Clones.clone` of a real
///         `BaseStrategy` template — never a hand-written registry mock.
///
///         The sibling suite (`Vault_she209ClassVaultBinding`) proves the
///         vault-side logic against a mock whose `classOf` is set by hand, so
///         the load-bearing equivalence the whole fix rests on —
///         `classOf(x) != 0` ⟺ the class fallback is what can admit `x` — is
///         asserted by that mock's construction, not tested. A refactor that
///         split `TierRegistry.classOf` from the `isAdapterAllowed` class
///         branch would leave that suite green while reopening the Critical.
///         This suite pins the equivalence on the real registry (Carlos, PR
///         #284 finding 4), and covers the two sites that suite left untested:
///         the Permit2 batch recipient loop, and an explicit per-address grant
///         on a class member (finding 3).
contract VaultShe209RealRegistryBindingTest is Test {
    SyndicateVault vault;
    VaultWithdrawalQueue queue;
    BatchExecutorLib executorLib;
    ERC20Mock usdc;
    MockAgentRegistry agentRegistry;
    TierRegistry registry;
    MockStrategy template;

    address owner = makeAddr("owner");
    address registryOwner = makeAddr("registryOwner");
    address attacker = makeAddr("attacker");
    address permit2 = makeAddr("permit2");
    address constant MOCK_GOVERNOR = address(0xF00D);
    bytes4 constant SEL = IStrategy.execute.selector;
    bytes4 constant SEL_PERMIT2_BATCH_TRANSFER_FROM = 0x0d58b1db; // Permit2 AllowanceTransfer.transferFrom(AllowanceTransferDetails[])

    /// @dev Test-side mirror of Permit2's `AllowanceTransferDetails` — only
    ///      used to `abi.encode` the batch selector's calldata.
    struct PermitBatchDetail {
        address from;
        address to;
        uint160 amount;
        address token;
    }

    function setUp() public {
        usdc = new ERC20Mock("USD Coin", "USDC", 6);
        executorLib = new BatchExecutorLib();
        agentRegistry = new MockAgentRegistry();
        registry = new TierRegistry(registryOwner);
        template = new MockStrategy();

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
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("tierRegistry()"), abi.encode(address(registry)));

        // THE REAL CEREMONY: propose → wait certifyDelay → certify → allow the
        // class. After this, every ERC-1167 clone of `template` is a class
        // member and `isAdapterAllowed` admits it via the class fallback.
        vm.startPrank(registryOwner);
        registry.proposeClassCertification(address(template), SEL, 1, 500, address(0), address(template).codehash);
        vm.warp(vm.getBlockTimestamp() + registry.certifyDelay());
        registry.certifyClass(address(template), SEL);
        registry.setClassAllowed(address(template), true);
        // Permit2 must be a legal batch CALLEE for the batch site to be reached.
        registry.setAdapterAllowed(permit2, true);
        vm.stopPrank();

        usdc.mint(address(vault), 1_000e6);
    }

    /// @dev A bare `Clones.clone` — never through `StrategyFactory` — with the
    ///      unpermissioned `initialize` binding it to `vault_`.
    function _rogueClone(address vault_) internal returns (address clone) {
        clone = Clones.clone(address(template));
        bytes memory data = abi.encode(address(usdc), address(0), uint256(0), uint256(0), false);
        vm.prank(attacker);
        MockStrategy(clone).initialize(vault_, attacker, data);
    }

    function _transferBatch(address recipient) internal view returns (BatchExecutorLib.Call[] memory calls) {
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: address(usdc), value: 0, data: abi.encodeCall(IERC20.transfer, (recipient, 0))
        });
    }

    function _permit2Batch(address recipient) internal view returns (BatchExecutorLib.Call[] memory calls) {
        PermitBatchDetail[] memory details = new PermitBatchDetail[](1);
        details[0] = PermitBatchDetail({from: address(vault), to: recipient, amount: 0, token: address(usdc)});
        calls = new BatchExecutorLib.Call[](1);
        calls[0] = BatchExecutorLib.Call({
            target: permit2, value: 0, data: abi.encodeWithSelector(SEL_PERMIT2_BATCH_TRANSFER_FROM, details)
        });
    }

    /// @notice THE AUDITED SEQUENCE, END TO END. The real registry admits the
    ///         permissionless clone purely by class, and the vault refuses it
    ///         because its `vault()` is the attacker.
    function test_she209_realRegistry_rogueCloneRecipient_reverts() public {
        address rogue = _rogueClone(attacker);

        // The registry-layer hole is intact, as intended: class admission and
        // a non-zero class report agree — pinning the equivalence the vault
        // guard relies on.
        assertTrue(registry.isAdapterAllowed(rogue), "real registry admits the rogue clone by class");
        assertEq(registry.classOf(rogue), registry.cloneCodehashOf(address(template)), "classOf is the clone class");
        assertEq(MockStrategy(rogue).vault(), attacker, "rogue clone pays the attacker");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, rogue));
        vault.executeGovernorBatch(_transferBatch(rogue), new uint256[](0), 1);
    }

    /// @notice CONTROL. The identical permissionless clone bound to THIS vault
    ///         passes — the guard binds by destination, not by provenance.
    function test_she209_realRegistry_vaultBoundClone_passesGuard() public {
        address bound = _rogueClone(address(vault));
        assertTrue(registry.isAdapterAllowed(bound), "still admitted by class");

        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }

    /// @notice The equivalence, negated: a clone of a template whose class is
    ///         certified but NOT `_classAllowed` reports `classOf != 0` while
    ///         `isAdapterAllowed` is false — the recipient guard refuses it on
    ///         the allowlist BEFORE the binding check runs, so the binding is
    ///         never what admits a clone the class allowlist rejects.
    function test_she209_realRegistry_classNotAllowed_refusedOnAllowlistFirst() public {
        vm.prank(registryOwner);
        registry.setClassAllowed(address(template), false);
        address bound = _rogueClone(address(vault));
        assertTrue(registry.classOf(bound) != bytes32(0), "still a class member");
        assertFalse(registry.isAdapterAllowed(bound), "but not allowed");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISyndicateVault.DisallowedTransferTarget.selector, address(usdc), IERC20.transfer.selector, bound
            )
        );
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }

    /// @notice PERMIT2 BATCH SITE. The per-element loop at the Permit2
    ///         `transferFrom(AllowanceTransferDetails[])` site binds too.
    function test_she209_realRegistry_permit2BatchRecipient_reverts() public {
        address rogue = _rogueClone(attacker);

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, rogue));
        vault.executeGovernorBatch(_permit2Batch(rogue), new uint256[](0), 1);
    }

    /// @notice Permit2 batch CONTROL: a vault-bound clone passes the same
    ///         site, so the reject above is not the source guard or the callee
    ///         gate firing.
    function test_she209_realRegistry_permit2BatchVaultBound_passesGuard() public {
        address bound = _rogueClone(address(vault));

        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_permit2Batch(bound), new uint256[](0), 1);
    }

    /// @notice EXPLICIT GRANT ON A CLASS MEMBER (finding 3). The owner's
    ///         per-address `setAdapterAllowed(clone, true)` — the documented
    ///         per-clone pattern — vets the ADDRESS, but the clone is still a
    ///         class member, and the binding still fires. The exemption is
    ///         "non-member", not "explicitly granted".
    function test_she209_realRegistry_explicitGrantOnRogueClassMember_stillBound() public {
        address rogue = _rogueClone(attacker);
        vm.prank(registryOwner);
        registry.setAdapterAllowed(rogue, true);
        assertTrue(registry.isAdapterAllowed(rogue), "address path admits it");
        assertTrue(registry.classOf(rogue) != bytes32(0), "and it is still a class member");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert(abi.encodeWithSelector(ISyndicateVault.AdapterVaultMismatch.selector, rogue));
        vault.executeGovernorBatch(_transferBatch(rogue), new uint256[](0), 1);
    }

    /// @notice And the legitimate shape of that pattern — an explicit grant on
    ///         a clone bound to THIS vault — keeps working.
    function test_she209_realRegistry_explicitGrantOnBoundClassMember_passesGuard() public {
        address bound = _rogueClone(address(vault));
        vm.prank(registryOwner);
        registry.setAdapterAllowed(bound, true);

        vm.prank(MOCK_GOVERNOR);
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }

    /// @notice A registry that cannot answer `classOf` is a misconfigured
    ///         registry, not a class-less one: the typed call reverts instead
    ///         of admitting (finding 2). Modeled by mocking the selector to
    ///         revert on the otherwise-real registry.
    function test_she209_realRegistry_classOfUnreadable_failsClosed() public {
        address bound = _rogueClone(address(vault));
        vm.mockCallRevert(address(registry), abi.encodeWithSelector(TierRegistry.classOf.selector, bound), "");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert();
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }

    /// @notice Second fail-closed mode: a registry that answers `classOf` with
    ///         a SHORT word. The typed call's `returndatasize >= 32` check
    ///         rejects it, where the old raw probe's `length < 32 → return`
    ///         would have ADMITTED the recipient unbound.
    function test_she209_realRegistry_classOfShortReturn_failsClosed() public {
        address bound = _rogueClone(address(vault));
        vm.mockCall(address(registry), abi.encodeWithSelector(TierRegistry.classOf.selector, bound), hex"01");

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert();
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }

    /// @notice Third fail-closed mode: a registry with NO `classOf` selector at
    ///         all (a pre-class registry). `isAdapterAllowed` answers, so the
    ///         batch reaches the binding, and the missing selector reverts the
    ///         batch rather than skipping the binding. This is the deploy
    ///         precondition: the wired registry must expose `classOf(address)`.
    function test_she209_realRegistry_registryWithoutClassOf_failsClosed() public {
        NoClassOfRegistry legacy = new NoClassOfRegistry();
        vm.mockCall(MOCK_GOVERNOR, abi.encodeWithSignature("tierRegistry()"), abi.encode(address(legacy)));
        address bound = _rogueClone(address(vault));

        vm.prank(MOCK_GOVERNOR);
        vm.expectRevert();
        vault.executeGovernorBatch(_transferBatch(bound), new uint256[](0), 1);
    }
}

/// @dev A registry from before the class concept: admits everything, exposes
///      no `classOf`. Models a mis-wired `setTierRegistry` target.
contract NoClassOfRegistry {
    function isAdapterAllowed(address) external pure returns (bool) {
        return true;
    }

    function isCallableTarget(address) external pure returns (bool) {
        return true;
    }
}
