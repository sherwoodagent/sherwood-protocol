// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Create3} from "../src/Create3.sol";
import {WoodToken} from "../src/WoodToken.sol";
import {VotingEscrow} from "../src/VotingEscrow.sol";
import {Voter} from "../src/Voter.sol";
import {Minter} from "../src/Minter.sol";
import {RewardsDistributor} from "../src/RewardsDistributor.sol";
import {VoteIncentive} from "../src/VoteIncentive.sol";
import {IVotingEscrow} from "../src/interfaces/IVotingEscrow.sol";
import {ScriptBase} from "./ScriptBase.sol";

/**
 * @title DeployTokenomics — Deterministic cross-chain deployment of ve(3,3) contracts
 * @notice Deploys all tokenomics contracts via CREATE3 so WoodToken (and all contracts)
 *         get the same address on every chain regardless of chain-specific constructor args.
 *
 *   All addresses are predicted upfront, breaking circular dependencies:
 *     WoodToken → needs Minter address
 *     Minter → needs Voter, VotingEscrow, WoodToken
 *     Voter → needs VotingEscrow, WoodToken, Minter
 *
 *   Environment variables:
 *     LZ_ENDPOINT           — LayerZero V2 endpoint for this chain
 *     SYNDICATE_FACTORY     — Existing SyndicateFactory address (from core deploy)
 *     TEAM_TREASURY         — Team treasury address
 *     EPOCH_START_REFERENCE — First Thursday 00:00 UTC timestamp for epoch system
 *
 *   Usage:
 *     forge script script/DeployTokenomics.s.sol:DeployTokenomics \
 *       --rpc-url base \
 *       --account sherwood-agent \
 *       --sender <DEPLOYER_ADDRESS> \
 *       --broadcast \
 *       --verify
 */
contract DeployTokenomics is ScriptBase {
    // ── Salts (same on every chain → same addresses) ──
    bytes32 constant SALT_WOOD = keccak256("sherwood.wood.v1");
    bytes32 constant SALT_VOTING_ESCROW = keccak256("sherwood.veWOOD.v1");
    bytes32 constant SALT_VOTER = keccak256("sherwood.voter.v1");
    bytes32 constant SALT_MINTER = keccak256("sherwood.minter.v1");
    bytes32 constant SALT_REWARDS_DIST = keccak256("sherwood.rebase.v1");
    bytes32 constant SALT_VOTE_INCENTIVE = keccak256("sherwood.bribes.v1");

    struct ChainConfig {
        address lzEndpoint;
        address syndicateFactory;
        address teamTreasury;
        uint256 epochStartReference;
    }

    struct Addresses {
        address woodToken;
        address votingEscrow;
        address voter;
        address minter;
        address rewardsDist;
        address voteIncentive;
        address deployer;
        address teamTreasury;
    }

    function run() external {
        ChainConfig memory cfg = ChainConfig({
            lzEndpoint: vm.envAddress("LZ_ENDPOINT"),
            syndicateFactory: vm.envAddress("SYNDICATE_FACTORY"),
            teamTreasury: vm.envAddress("TEAM_TREASURY"),
            epochStartReference: vm.envUint("EPOCH_START_REFERENCE")
        });

        vm.startBroadcast();

        address deployer = msg.sender;
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // ── 1. Predict key addresses upfront (breaks circular deps) ──
        address predictedMinter = Create3.addressOf(deployer, SALT_MINTER);
        _logPredictions(deployer);

        // ── 2. Deploy all contracts via CREATE3 ──
        Addresses memory a = _deployAll(deployer, predictedMinter, cfg);

        // ── 3. Post-deploy configuration ──
        Minter(a.minter).setRewardsDistributor(a.rewardsDist);
        console.log("\nMinter.rewardsDistributor set to:", a.rewardsDist);

        vm.stopBroadcast();

        // ── 4. Validate + persist ──
        _validate(a);
        _writeTokenomicsAddresses(a.woodToken, a.votingEscrow, a.voter, a.minter, a.rewardsDist, a.voteIncentive);
    }

    function _logPredictions(address deployer) internal pure {
        console.log("\n=== Predicted addresses (same on every chain) ===");
        console.log("WoodToken:          ", Create3.addressOf(deployer, SALT_WOOD));
        console.log("VotingEscrow:       ", Create3.addressOf(deployer, SALT_VOTING_ESCROW));
        console.log("Voter:              ", Create3.addressOf(deployer, SALT_VOTER));
        console.log("Minter:             ", Create3.addressOf(deployer, SALT_MINTER));
        console.log("RewardsDistributor: ", Create3.addressOf(deployer, SALT_REWARDS_DIST));
        console.log("VoteIncentive:      ", Create3.addressOf(deployer, SALT_VOTE_INCENTIVE));
    }

    function _deployAll(address deployer, address predictedMinter, ChainConfig memory cfg)
        internal
        returns (Addresses memory a)
    {
        a.deployer = deployer;
        a.teamTreasury = cfg.teamTreasury;

        // a. WoodToken — OFT with immutable minter (predicted)
        a.woodToken = Create3.deploy(
            SALT_WOOD,
            abi.encodePacked(type(WoodToken).creationCode, abi.encode(cfg.lzEndpoint, deployer, predictedMinter))
        );
        console.log("\nWoodToken deployed: ", a.woodToken);

        // b. VotingEscrow — lock WOOD → veWOOD NFT
        a.votingEscrow = Create3.deploy(
            SALT_VOTING_ESCROW, abi.encodePacked(type(VotingEscrow).creationCode, abi.encode(a.woodToken, deployer))
        );
        console.log("VotingEscrow deployed:", a.votingEscrow);

        // c. Voter — epoch voting, deploys SyndicateGauges
        a.voter = Create3.deploy(
            SALT_VOTER,
            abi.encodePacked(
                type(Voter).creationCode,
                abi.encode(
                    a.votingEscrow,
                    cfg.syndicateFactory,
                    cfg.epochStartReference,
                    a.woodToken,
                    predictedMinter,
                    deployer
                )
            )
        );
        console.log("Voter deployed:      ", a.voter);

        // d. Minter — emission schedule, rebase
        a.minter = Create3.deploy(
            SALT_MINTER,
            abi.encodePacked(
                type(Minter).creationCode, abi.encode(a.woodToken, a.voter, a.votingEscrow, cfg.teamTreasury, deployer)
            )
        );
        console.log("Minter deployed:     ", a.minter);

        // e. RewardsDistributor — veWOOD rebase anti-dilution
        a.rewardsDist = Create3.deploy(
            SALT_REWARDS_DIST,
            abi.encodePacked(
                type(RewardsDistributor).creationCode, abi.encode(a.votingEscrow, a.woodToken, a.minter, deployer)
            )
        );
        console.log("RewardsDistributor:  ", a.rewardsDist);

        // f. VoteIncentive — bribe marketplace
        a.voteIncentive = Create3.deploy(
            SALT_VOTE_INCENTIVE,
            abi.encodePacked(type(VoteIncentive).creationCode, abi.encode(a.voter, a.votingEscrow, deployer))
        );
        console.log("VoteIncentive:       ", a.voteIncentive);
    }

    function _validate(Addresses memory d) internal view {
        console.log("\n=== Validating on-chain state ===");

        // Verify CREATE3 predictions match actual deployments
        _checkAddr("wood predicted", d.woodToken, Create3.addressOf(d.deployer, SALT_WOOD));
        _checkAddr("ve predicted", d.votingEscrow, Create3.addressOf(d.deployer, SALT_VOTING_ESCROW));
        _checkAddr("voter predicted", d.voter, Create3.addressOf(d.deployer, SALT_VOTER));
        _checkAddr("minter predicted", d.minter, Create3.addressOf(d.deployer, SALT_MINTER));
        _checkAddr("rewardsDist predicted", d.rewardsDist, Create3.addressOf(d.deployer, SALT_REWARDS_DIST));
        _checkAddr("voteIncentive predicted", d.voteIncentive, Create3.addressOf(d.deployer, SALT_VOTE_INCENTIVE));

        // Verify cross-references
        _checkAddr("wood.minter", WoodToken(d.woodToken).minter(), d.minter);
        _checkAddr("voter.wood", Voter(d.voter).wood(), d.woodToken);
        _checkAddr("voter.minter", Voter(d.voter).minter(), d.minter);
        _checkAddr("minter.voter", address(Minter(d.minter).voter()), d.voter);
        _checkAddr("minter.treasury", Minter(d.minter).teamTreasury(), d.teamTreasury);
        _checkAddr("minter.rewardsDist", Minter(d.minter).rewardsDistributor(), d.rewardsDist);
        _checkAddr("rewardsDist.minter", RewardsDistributor(d.rewardsDist).minter(), d.minter);
        _checkAddr("voteIncentive.voter", address(VoteIncentive(d.voteIncentive).voter()), d.voter);

        console.log("=== All checks passed ===");
    }
}
