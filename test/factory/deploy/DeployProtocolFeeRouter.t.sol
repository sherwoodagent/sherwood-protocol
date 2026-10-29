// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {ProtocolFeeRouter} from "../../../src/ProtocolFeeRouter.sol";
import {DeploySalts} from "../../../script/DeploySalts.sol";
import {DeployProtocolFeeRouter} from "../../../script/robinhood-mainnet/DeployProtocolFeeRouter.s.sol";
import {ERC20Mock} from "../../mocks/ERC20Mock.sol";
import {ProtocolConfig} from "../../../src/ProtocolConfig.sol";

/// @notice Answers the two Safe reads the script probes.
contract MockSafe {
    uint256 public getThreshold;

    constructor(uint256 threshold) {
        getThreshold = threshold;
    }

    function getOwners() external pure returns (address[] memory o) {
        o = new address[](2);
    }
}

contract DeployProtocolFeeRouterHarness is DeployProtocolFeeRouter {
    function predicted() external returns (address) {
        return _predict(_c3Factory(msg.sender), DeploySalts.PROTOCOL_FEE_ROUTER);
    }
}

/// @dev Every call is pranked as the script: `_c3Factory` bootstraps the CREATE3 factory at
///      `msg.sender` and `c3.deploy` is `onlyOwner`, called by the script itself.
contract DeployProtocolFeeRouterTest is Test {
    DeployProtocolFeeRouterHarness script;
    address safe;

    function setUp() public {
        script = new DeployProtocolFeeRouterHarness();
        safe = address(new MockSafe(2));
    }

    function _deploy(address owner_) internal returns (ProtocolFeeRouter) {
        vm.prank(address(script));
        return script.deploy(owner_);
    }

    function _predicted() internal returns (address) {
        vm.prank(address(script));
        return script.predicted();
    }

    /// @notice The pinned hash is this repo's router; a source edit without re-recording it fails here first.
    function test_pinnedRuntimeHashMatchesTheRouter() public pure {
        assertEq(keccak256(type(ProtocolFeeRouter).runtimeCode), DeploySalts.PROTOCOL_FEE_ROUTER_RUNTIME_HASH);
    }

    /// @notice The router lands at its CREATE3 salt, owned by the Safe, nothing pending, in hold mode.
    function test_deployMintsAtTheSaltForTheSafeInHoldMode() public {
        ProtocolFeeRouter router = _deploy(safe);
        assertEq(address(router), _predicted());
        assertEq(address(router).codehash, DeploySalts.PROTOCOL_FEE_ROUTER_RUNTIME_HASH);
        assertEq(router.owner(), safe);
        assertEq(router.pendingOwner(), address(0));
        assertEq(router.allocations().length, 0);
    }

    /// @notice A re-run adopts the router even after allocations and an ownership move, so the book can be re-patched.
    function test_aRerunAdoptsTheConfiguredRouter() public {
        ProtocolFeeRouter first = _deploy(safe);
        address foundation = address(new MockSafe(3));
        ProtocolFeeRouter.Allocation[] memory a = new ProtocolFeeRouter.Allocation[](1);
        a[0] = ProtocolFeeRouter.Allocation({target: makeAddr("leg"), bps: 10_000});
        vm.startPrank(safe);
        first.setAllocations(a);
        first.transferOwnership(foundation);
        vm.stopPrank();
        vm.prank(foundation);
        first.acceptOwnership();

        assertEq(address(_deploy(safe)), address(first));
    }

    /// @notice Foreign code already at the salt is refused, not adopted.
    function test_foreignCodeAtTheSaltIsRefused() public {
        vm.etch(_predicted(), address(new ERC20Mock("X", "X", 18)).code);
        vm.prank(address(script));
        vm.expectRevert("fee router: code is not the pinned router");
        script.deploy(safe);
    }

    /// @notice An EOA owner is refused.
    function test_deployRefusesAnEoaOwner() public {
        address eoa = makeAddr("eoa");
        vm.prank(address(script));
        vm.expectRevert("DeployProtocolFeeRouter: the Safe must be a contract, not an EOA");
        script.deploy(eoa);
    }

    /// @notice A contract that is not a Safe (here a token) is refused before anything is minted.
    function test_deployRefusesANonSafeContract() public {
        address token = address(new ERC20Mock("USDG", "USDG", 6));
        vm.prank(address(script));
        vm.expectRevert("DeployProtocolFeeRouter: owner does not answer getThreshold(); not a Safe");
        script.deploy(token);
        assertEq(_predicted().code.length, 0, "salt left unused");
    }

    // ── run(): the broadcast wrapper, against a scratch address book ──

    uint256 constant SCRATCH_CHAIN_ID = 7_746_630;

    /// @dev Writes a scratch book naming `deployer`, calls `run(safe)` from this contract, and deletes the book
    ///      before returning, so a failed assert never leaves a file behind.
    function _runAgainstScratchBook(address deployer) internal returns (bool ok, bytes memory ret, string memory book) {
        vm.chainId(SCRATCH_CHAIN_ID);
        string memory path = string.concat(vm.projectRoot(), "/chains/", vm.toString(SCRATCH_CHAIN_ID), ".json");
        ProtocolConfig config = new ProtocolConfig(deployer);
        vm.writeFile(
            path,
            string.concat(
                "{\"DEPLOYER\":\"",
                vm.toString(deployer),
                "\",\"PROTOCOL_CONFIG\":\"",
                vm.toString(address(config)),
                "\"}"
            )
        );
        (ok, ret) = address(script).call(abi.encodeCall(DeployProtocolFeeRouter.run, (safe)));
        book = vm.readFile(path);
        vm.removeFile(path);
    }

    /// @notice Outside a --broadcast run the router is simulated, as the book's DEPLOYER, but never recorded in the book.
    function test_aDryRunRecordsNothingInTheBook() public {
        (bool ok, bytes memory ret, string memory book) = _runAgainstScratchBook(makeAddr("deployer"));
        assertTrue(ok, string(ret));
        assertGt(abi.decode(ret, (address)).code.length, 0, "the simulation minted the router");
        assertFalse(vm.keyExistsJson(book, ".PROTOCOL_FEE_ROUTER"), "dry run wrote the router into the book");
    }

    /// @notice A Safe with a zero threshold is refused.
    function test_deployRefusesAZeroThresholdSafe() public {
        address broken = address(new MockSafe(0));
        vm.prank(address(script));
        vm.expectRevert("DeployProtocolFeeRouter: Safe threshold is zero");
        script.deploy(broken);
    }
}
