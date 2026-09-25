// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

contract SecurityPendingUnstakeTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner;
    address user1;
    address user2;
    address node;

    uint256 constant START_TIME = 365 days;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        node = makeAddr("node");

        vm.prank(owner);
        token = new IDOSToken(owner);

        vm.prank(owner);
        staking = new IDOSNodeStaking(
            address(token),
            owner,
            uint48(START_TIME),
            100
        );

        vm.prank(owner);
        require(token.transfer(address(staking), 10_000));

        vm.prank(owner);
        require(token.transfer(user1, 1_000));
        vm.prank(owner);
        require(token.transfer(user2, 1_000));

        vm.prank(user1);
        token.approve(address(staking), 1_000);
        vm.prank(user2);
        token.approve(address(staking), 1_000);
    }

    function test_PendingUnstakeEscapesLaterSlash() public {
        vm.warp(START_TIME);

        vm.prank(owner);
        staking.allowNode(node);

        vm.prank(user1);
        staking.stake(address(0), node, 100);

        vm.prank(user2);
        staking.stake(address(0), node, 100);

        assertEq(staking.getNodeStake(node), 200);

        // User 1 enters the 14-day unbonding period.
        vm.prank(user1);
        staking.unstake(node, 100);

        assertEq(staking.stakeByNodeByUser(user1, node), 0);
        assertEq(staking.getNodeStake(node), 100);
        assertEq(token.balanceOf(user1), 900);

        // The node is slashed after User 1 has moved their stake
        // into the pending unbonding queue.
        vm.prank(owner);
        staking.slash(node);

        // Only User 2's active 100 IDOS remains represented by
        // the slashed node stake.
        assertEq(staking.getNodeStake(node), 100);

        uint256 ownerBefore = token.balanceOf(owner);

        vm.prank(owner);
        staking.withdrawSlashedStakes();

        assertEq(token.balanceOf(owner), ownerBefore + 100);

        // User 1 has not received the pending amount yet.
        assertEq(token.balanceOf(user1), 900);

        // After the unbonding delay, User 1 can withdraw it.
        skip(staking.UNSTAKE_DELAY() + 1);

        vm.prank(user1);
        staking.withdrawUnstaked();

        assertEq(token.balanceOf(user1), 1_000);
    }
}
