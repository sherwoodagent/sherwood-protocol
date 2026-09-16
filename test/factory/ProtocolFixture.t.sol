// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProtocolFixture} from "../helpers/ProtocolFixture.sol";

contract ProtocolFixtureTest is ProtocolFixture {
    ProtocolDeployment internal protocol;
    address internal owner = makeAddr("owner");

    function setUp() public {
        protocol = _deployProtocol(owner);
    }

    function test_realStackCreatesBondedSyndicateAndAcceptsDeposit() public {
        ProtocolDeployment memory p = protocol;
        assertEq(p.factory.governorOf(address(p.vault)), address(p.governor));
        assertEq(p.registry.vaultOf(address(p.governor)), address(p.vault));
        assertEq(p.swood.factory(), address(p.factory));
        assertEq(p.swood.registry(), address(p.registry));
        assertEq(p.swood.exposureLedger(), address(p.ledger));
        assertEq(address(p.registry.exposureLedger()), address(p.ledger));
        assertEq(p.ledger.coverageFreezer(), address(p.game));
        assertEq(p.swood.authorizedSlasher(), address(p.game));
        assertEq(p.tiers.authorizedDemoter(), address(p.game));
        assertEq(p.game.court(), address(p.court));
        assertEq(p.court.stakedWood(), address(p.swood));
        assertEq(address(p.governor.exposureLedger()), address(p.ledger));
        assertEq(address(p.governor.bondEscrow()), address(p.escrow));
        assertEq(address(p.governor.tierRegistry()), address(p.tiers));
        assertEq(p.tiers.strategyFactory(), address(p.strategies));
        assertEq(p.wood.balanceOf(address(p.swood)), p.swood.minOwnerStake());
        assertEq(p.swood.ownerStake(address(p.vault)), p.swood.minOwnerStake());
        assertTrue(p.swood.ownerBondLive(address(p.vault)));

        address lp = makeAddr("lp");
        p.asset.mint(lp, 1_000e6);
        vm.startPrank(lp);
        p.asset.approve(address(p.vault), 1_000e6);
        uint256 shares = p.vault.deposit(1_000e6, lp);
        vm.stopPrank();
        assertGt(shares, 0);
        assertEq(p.vault.balanceOf(lp), shares);
        assertEq(p.vault.totalAssets(), 1_000e6);
    }
}
