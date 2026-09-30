// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";
import {IDOSToken} from "../src/IDOSToken.sol";

contract SecurityUnauthorizedStakeTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;
    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address node = makeAddr("allowlisted-node");

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);

        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, uint48(1), 100);

        vm.prank(owner);
        token.transfer(victim, 1000);

        vm.prank(victim);
        token.approve(address(staking), 1000);

        vm.prank(owner);
        staking.allowNode(node);

        vm.warp(1);
    }

    function test_ThirdPartyCanStakeFromVictimAllowance() public {
        uint256 victimBefore = token.balanceOf(victim);

        vm.prank(attacker);
        staking.stake(victim, node, 100);

        assertEq(token.balanceOf(victim), victimBefore - 100);
        assertEq(staking.stakeByNodeByUser(victim, node), 100);
        assertEq(staking.getNodeStake(node), 100);
        assertEq(staking.getUserStake(victim), (100, 0));
    }
}
