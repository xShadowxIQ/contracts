// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

contract GasDoSPoC is Test {
    IDOSToken idosToken;
    IDOSNodeStaking idosStaking;

    address owner;
    address user1;
    address node1;

    uint256 constant START_TIME = 365 days;
    uint256 constant EPOCH_REWARD = 100;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        node1 = makeAddr("node1");

        vm.prank(owner);
        idosToken = new IDOSToken(owner);
        vm.prank(owner);
        idosStaking = new IDOSNodeStaking(address(idosToken), owner, uint48(START_TIME), EPOCH_REWARD);

        vm.prank(owner);
        require(idosToken.transfer(address(idosStaking), 1_000_000));
        vm.prank(owner);
        require(idosToken.transfer(user1, 1_000_000));

        vm.prank(user1);
        idosToken.approve(address(idosStaking), 1_000_000);

        vm.prank(owner);
        idosStaking.allowNode(node1);

        vm.warp(START_TIME);
    }

    // Test: Gas DoS via non-compacting array deletion
    // After many unstake+withdraw cycles, the unstakesByUser array grows unboundedly
    // because delete only clears the element but doesn't compact the array
    function test_GasDoS_WithdrawUnstakedArrayGrowth() public {
        // Stake and unstake multiple times to create many entries in the unstakes array
        // Each unstake adds an entry to unstakesByUser[user1]
        // After each withdraw, delete is called but the array doesn't shrink

        uint256 numUnstakes = 50; // 50 unstake/withdraw cycles should be enough to demonstrate

        for (uint256 i = 0; i < numUnstakes; i++) {
            // Stake
            vm.prank(user1);
            idosStaking.stake(address(0), node1, 100);

            // Unstake (adds entry to unstakesByUser array)
            vm.prank(user1);
            idosStaking.unstake(node1, 100);

            // Advance past unstake delay
            vm.warp(block.timestamp + idosStaking.UNSTAKE_DELAY() + 1);

            // Withdraw - this should trigger the gas issue as array grows
            vm.prank(user1);
            uint256 withdrawn = idosStaking.withdrawUnstaked();
            assertEq(withdrawn, 100);

            // Reset time for next iteration (but array keeps growing)
            vm.warp(START_TIME + i + 1);
        }

        // At this point, unstakesByUser[user1] has 50 entries (all "deleted" but still in array)
        // If we try to withdraw again, the loop iterates over all 50 entries
        // With enough entries, this will exceed block gas limit
    }

    // Test: Multiple unstakes without withdrawal causes O(n) gas on every call
    function test_GasDoS_MultipleUnstakesBeforeWithdrawal() public {
        uint256 numUnstakes = 100;

        // Stake and unstake multiple times without withdrawing
        for (uint256 i = 0; i < numUnstakes; i++) {
            vm.prank(user1);
            idosStaking.stake(address(0), node1, 100);

            vm.prank(user1);
            idosStaking.unstake(node1, 100);
        }

        // Now advance time past unstake delay
        skip(idosStaking.UNSTAKE_DELAY() + 1);

        // This single call should iterate over ALL 100 stale entries
        // While delete doesn't compact, the loop itself is expensive
        vm.prank(user1);
        uint256 withdrawn = idosStaking.withdrawUnstaked();

        assertEq(withdrawn, numUnstakes * 100);
    }

    // Test: Stale slashed stake tracking - after withdrawSlashedStakes, getUserStake still shows slashed amount
    function test_StaleSlashedStake_LossOfFunds() public {
        address maliciousNode = makeAddr("maliciousNode");

        vm.prank(owner);
        idosStaking.allowNode(maliciousNode);

        // User stakes on a node
        vm.prank(user1);
        idosStaking.stake(address(0), maliciousNode, 1000);

        assertEq(idosStaking.stakeByNodeByUser(user1, maliciousNode), 1000);

        // Node gets slashed
        vm.prank(owner);
        idosStaking.slash(maliciousNode);

        // Verify the stake is recorded as slashed
        (uint256 activeStake, uint256 slashedStake) = idosStaking.getUserStake(user1);
        assertEq(activeStake, 0);
        assertEq(slashedStake, 1000);

        // Owner withdraws the slashed stake (sends tokens to owner)
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // BUG: After withdrawal, getUserStake still shows 1000 slashed stake
        // because stakeByNodeByUser[user1][maliciousNode] is never cleared
        (uint256 activeStake2, uint256 slashedStake2) = idosStaking.getUserStake(user1);
        assertEq(activeStake2, 0);
        assertEq(slashedStake2, 1000); // Should be 0 after withdrawal!

        // The slashed stake is permanently "stuck" - user can't withdraw or unstake it
        // The tokens have already been sent to the owner
    }

    // Test: User cannot unstake from slashed node even after stake was withdrawn
    function test_StaleSlashedStake_BlockedFromUnstaking() public {
        address maliciousNode = makeAddr("maliciousNode");

        vm.prank(owner);
        idosStaking.allowNode(maliciousNode);

        vm.prank(user1);
        idosStaking.stake(address(0), maliciousNode, 500);

        // Slash the node
        vm.prank(owner);
        idosStaking.slash(maliciousNode);

        // Withdraw slashed stakes
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // User tries to unstake from the slashed node
        vm.prank(user1);
        vm.expectRevert(IDOSNodeStaking.NodeIsSlashed.selector);
        idosStaking.unstake(maliciousNode, 500);

        // So the user is permanently locked out of their stake with no recovery mechanism
    }
}
