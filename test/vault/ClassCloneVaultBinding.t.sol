// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StructuralBatchRulesTest} from "./StructuralBatchRules.t.sol";
import {SyndicateVault} from "../../src/SyndicateVault.sol";
import {ISyndicateVault} from "../../src/interfaces/ISyndicateVault.sol";
import {BatchExecutorLib} from "../../src/BatchExecutorLib.sol";
import {BaseStrategy} from "../../src/strategies/BaseStrategy.sol";
import {MorphoSupplyStrategy} from "../../src/strategies/MorphoSupplyStrategy.sol";

/// @notice A template that drops `onlyVault`: `execute` spends the paying vault's approval
///         and sends the proceeds to the vault this clone is bound to.
contract UnguardedTemplate {
    address public vault;
    address public proposer;
    address private _asset;
    uint256 private _amount;
    bool private _initialized;

    constructor() {
        _initialized = true;
    }

    function initialize(address vault_, address proposer_, bytes calldata data) external {
        require(!_initialized, "initialized");
        _initialized = true;
        vault = vault_;
        proposer = proposer_;
        (_asset, _amount) = abi.decode(data, (address, uint256));
    }

    function executed() external pure returns (bool) {
        return false;
    }

    function execute() external {
        IERC20(_asset).transferFrom(msg.sender, vault, _amount);
    }

    function settle() external {}
}

/// @notice The trust boundary a class certification sits on: the protocol admits a class member
///         on code identity and factory provenance alone and never reads its `vault()`, so
///         "the clone pays the vault that paid it" is a TEMPLATE invariant a certifier must
///         verify per template (`TierRegistry.proposeClassCertification`, SHE-209 / NM 6.2).
contract ClassCloneVaultBindingTest is StructuralBatchRulesTest {
    /// @notice A clone of a certified template bound to ANOTHER vault is admitted by this
    ///         vault's propose-time and batch-time target rules and priced at the class tier;
    ///         only the template's own `onlyVault` refuses it.
    function test_foreignBoundCloneIsAdmittedAndPricedAtItsClassTier() public {
        MorphoSupplyStrategy template = _morphoVenue();
        _certifyClassNow(address(template), BaseStrategy.execute.selector, 1, uint16(CLASS_BOUND));

        SyndicateVault vaultB = _deployVaultB();
        assertTrue(address(vaultB) != address(vault), "two distinct vaults");

        // Cloning is permissionless: anyone mints a clone bound to vault B.
        uint256 cap = 1_000_000e6;
        vm.prank(attacker);
        address foreign = strategyFactory.cloneAndInit(
            address(template), address(vaultB), attacker, abi.encode(address(morpho), mp, cap)
        );
        assertEq(BaseStrategy(foreign).vault(), address(vaultB), "clone is bound to vault B");

        // `tierOf` takes no vault argument, so the class tier follows the code, not the binding.
        (uint8 tier_, uint16 bound_) = tierRegistry.tierOf(foreign, BaseStrategy.execute.selector);
        assertEq(tier_, 1, "foreign-bound clone inherits the class tier");
        assertEq(bound_, uint16(CLASS_BOUND), "and the class bound");

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (foreign, cap)));
        execCalls[1] = _call(foreign, abi.encodeCall(BaseStrategy.execute, ()));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = cap;
        uint256 pid = _propose(
            foreign, execCalls, execCaps, _one(foreign, abi.encodeCall(BaseStrategy.settle, ())), new uint256[](1), cap
        );
        // Coverage is the per-call sum: the execute leg gets the class discount a clone bound
        // to this vault would get. (The proposal tier is the max over legs, 2 here because the
        // uncertified `settle` selector sits in the settlement leg.)
        assertEq(governor.getRequiredCoverage(pid), cap * CLASS_BOUND / 10_000, "class coverage");
        assertLt(governor.getRequiredCoverage(pid), cap, "not full notional");

        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        vm.expectRevert(BaseStrategy.NotVault.selector);
        governor.executeProposal(pid);
    }

    /// @notice Certify a template that drops `onlyVault` and the paying vault's capital lands in
    ///         the foreign vault its clone is bound to — nothing in the protocol refuses it.
    function test_templateWithoutOnlyVaultMovesThePayingVaultsCapitalToItsOwnVault() public {
        UnguardedTemplate template = new UnguardedTemplate();
        strategyFactory.setTemplateApproval(address(template), true);
        _certifyClassNow(address(template), UnguardedTemplate.execute.selector, 1, uint16(CLASS_BOUND));

        SyndicateVault vaultB = _deployVaultB();
        uint256 amount = 500_000e6;
        vm.prank(attacker);
        address foreign = strategyFactory.cloneAndInit(
            address(template), address(vaultB), attacker, abi.encode(address(usdc), amount)
        );

        BatchExecutorLib.Call[] memory execCalls = new BatchExecutorLib.Call[](2);
        execCalls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (foreign, amount)));
        execCalls[1] = _call(foreign, abi.encodeCall(UnguardedTemplate.execute, ()));
        uint256[] memory execCaps = new uint256[](2);
        execCaps[1] = amount;
        uint256 pid = _propose(
            foreign,
            execCalls,
            execCaps,
            _one(foreign, abi.encodeCall(UnguardedTemplate.settle, ())),
            new uint256[](1),
            amount
        );
        assertEq(governor.getRequiredCoverage(pid), amount * CLASS_BOUND / 10_000, "priced at the class tier");

        uint256 beforeA = usdc.balanceOf(address(vault));
        vm.warp(vm.getBlockTimestamp() + VOTING_PERIOD + 1);
        governor.executeProposal(pid);
        assertEq(usdc.balanceOf(address(vaultB)), amount, "the paying vault's capital landed in vault B");
        assertEq(usdc.balanceOf(address(vault)), beforeA - amount, "and left vault A");
    }

    /// @dev Vault B: a real `SyndicateVault` proxy. The harness mocks `vaultToSyndicate` and
    ///      `governorOf` for every address, so it is registered and resolves the same registry.
    function _deployVaultB() internal returns (SyndicateVault vaultB) {
        SyndicateVault impl = new SyndicateVault();
        bytes memory init = abi.encodeCall(
            SyndicateVault.initialize,
            (ISyndicateVault.InitParams({
                    asset: address(usdc),
                    name: "Sherwood Vault B",
                    symbol: "swUSDCb",
                    owner: owner,
                    executorImpl: address(executorLib),
                    openDeposits: true,
                    agentRegistry: address(agentRegistry),
                    managementFeeBps: 0
                }))
        );
        vaultB = SyndicateVault(payable(address(new ERC1967Proxy(address(impl), init))));
    }
}
