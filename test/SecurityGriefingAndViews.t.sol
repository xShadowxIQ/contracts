// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice Targets the remaining UNVERIFIED vectors:
///   1. `createEpochCheckpoint(address)` is PERMISSIONLESS. Can a third party
///      checkpoint a victim repeatedly and cost them accrued rewards?
///      (If yes -> theft of unclaimed funds, High. If no -> griefing only.)
///   2. `getNodeStakes()` sizes its array as
///         stakeByNode.length() - slashedNodes.length()
///      which underflows if a slashed node is ever absent from stakeByNode.
///   3. `getUserStake()` computes active = total - slashed; can `slashed`
///      ever exceed `total` (underflow -> user permanently cannot unstake)?
contract SecurityGriefingAndViewsTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address victim = makeAddr("victim");
    address attacker = makeAddr("attacker");
    address[3] nodes = [makeAddr("n0"), makeAddr("n1"), makeAddr("n2")];

    uint48 constant START = 1_000_000;
    uint256 constant REWARD = 100;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, REWARD);

        vm.prank(owner);
        token.transfer(address(staking), 5_000_000);
        vm.prank(owner);
        token.transfer(victim, 1_000_000);
        vm.prank(victim);
        token.approve(address(staking), type(uint256).max);

        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.allowNode(nodes[i]);
        }
        vm.warp(START);
    }

    /// @dev 1. A third party hammering createEpochCheckpoint(victim) must not
    ///      reduce the victim's accrued rewards.
    ///      Uses a parallel control contract put through the IDENTICAL warp
    ///      sequence, so the only difference is the attacker's interference.
    function test_PermissionlessCheckpointingDoesNotStealRewards() public {
        IDOSNodeStaking ctl = new IDOSNodeStaking(address(token), owner, START, REWARD);
        address cv = makeAddr("control-victim");
        vm.prank(owner);
        token.transfer(cv, 1_000_000);
        vm.prank(cv);
        token.approve(address(ctl), type(uint256).max);
        vm.prank(owner);
        ctl.allowNode(nodes[0]);
        vm.prank(cv);
        ctl.stake(cv, nodes[0], 100_000);

        vm.prank(victim);
        staking.stake(victim, nodes[0], 100_000);

        for (uint256 e; e < 5; ++e) {
            for (uint256 k; k < 10; ++k) {
                vm.warp(block.timestamp + 2 hours);
                vm.prank(attacker);
                staking.createEpochCheckpoint(victim); // only the victim is interfered with
            }
            vm.warp(block.timestamp + 1 days);
        }

        vm.prank(victim);
        uint256 interfered = staking.withdrawReward();

        vm.prank(cv);
        uint256 clean = ctl.withdrawReward();

        assertEq(interfered, clean, "attacker checkpointing changed victim's rewards");
        assertGt(interfered, 0, "victim still earns normally");
    }

    /// @dev 1b. Even an attacker who checkpoints the victim every hour across
    ///       several days must not reduce the payout.
    function test_PerBlockCheckpointingIsStillLossless() public {
        vm.prank(victim);
        staking.stake(victim, nodes[0], 50_000);

        for (uint256 d; d < 3; ++d) {
            for (uint256 h; h < 24; ++h) {
                vm.warp(block.timestamp + 1 hours);
                vm.prank(attacker);
                staking.createEpochCheckpoint(victim);
            }
        }

        vm.prank(victim);
        uint256 afterGrief = staking.withdrawReward();

        // 3 days == 3 completed epochs, sole staker, full reward each.
        assertEq(afterGrief, 3 * REWARD, "3 full epochs at full reward, un diminished");
    }

    /// @dev 2. getNodeStakes() must not underflow and must return only
    ///      non-slashed nodes.
    function test_GetNodeStakesSurvivesAggressiveSlashing() public {
        // fund each node
        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(victim);
            staking.stake(victim, nodes[i], 10_000);
        }

        // slash every node -> slashedNodes == stakeByNode
        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.slash(nodes[i]);
        }

        IDOSNodeStaking.NodeStake[] memory unslashed = staking.getNodeStakes();
        assertEq(unslashed.length, 0, "no unslashed nodes remain");

        IDOSNodeStaking.NodeStake[] memory slashed = staking.getSlashedNodeStakes();
        assertEq(slashed.length, nodes.length, "all three recorded as slashed");
    }

    /// @dev 2b. Mixed state: slash some, empty others, never underflow.
    function test_GetNodeStakesWithMixedEmptyAndSlashedNodes() public {
        vm.prank(victim);
        staking.stake(victim, nodes[0], 10_000); // will be emptied
        vm.prank(victim);
        staking.stake(victim, nodes[1], 10_000); // will be slashed
        vm.prank(victim);
        staking.stake(victim, nodes[2], 10_000); // stays active

        // empty node0 completely
        vm.prank(victim);
        staking.unstake(nodes[0], 10_000);

        vm.prank(owner);
        staking.slash(nodes[1]);

        IDOSNodeStaking.NodeStake[] memory unslashed = staking.getNodeStakes();
        assertEq(unslashed.length, 1, "only node2 remains");
        assertEq(unslashed[0].node, nodes[2]);
        assertEq(unslashed[0].stake, 10_000);

        IDOSNodeStaking.NodeStake[] memory slashed = staking.getSlashedNodeStakes();
        assertEq(slashed.length, 1);
        assertEq(slashed[0].node, nodes[1]);
    }

    /// @dev 3. getUserStake() must never underflow, so a user holding slashed
    ///      stake can still unstake their remaining stake.
    function test_GetUserStakeNeverUnderflowsWithSlashedStake() public {
        vm.prank(victim);
        staking.stake(victim, nodes[0], 60_000);
        vm.prank(victim);
        staking.stake(victim, nodes[1], 40_000);

        vm.prank(owner);
        staking.slash(nodes[0]); // 60k of victim's stake becomes slashed

        (uint256 active, uint256 slashed) = staking.getUserStake(victim);
        assertEq(active, 40_000, "only the live node counts as active");
        assertEq(slashed, 60_000);

        // The victim can still exit the live node - no underflow, no lock.
        vm.prank(victim);
        staking.unstake(nodes[1], 40_000);

        (active, slashed) = staking.getUserStake(victim);
        assertEq(active, 0);
        assertEq(slashed, 60_000);
    }

    /// @dev 3b. Interleaved slash / unstake across every node, checking the
    ///      invariant after each step.
    function testFuzz_SlashedStakeAccountingStaysConsistent(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 50));

        for (uint256 i; i < steps; ++i) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 6;
            uint256 ni = uint256(keccak256(abi.encode(seed, i, "n"))) % nodes.length;

            if (action <= 1) {
                vm.prank(victim);
                try staking.stake(victim, nodes[ni], 1 + (uint256(keccak256(abi.encode(seed, i))) % 20_000)) {} catch {}
            } else if (action <= 3) {
                uint256 cur = staking.stakeByNodeByUser(victim, nodes[ni]);
                if (cur != 0) {
                    vm.prank(victim);
                    try staking.unstake(nodes[ni], 1 + (uint256(keccak256(abi.encode(seed, i))) % cur)) {} catch {}
                }
            } else if (action == 4) {
                vm.prank(owner);
                try staking.slash(nodes[ni]) {} catch {}
            } else {
                vm.warp(block.timestamp + 1 days);
            }

            // Invariant: active + slashed must equal the per-node sum, and must
            // never revert (an underflow here would permanently lock the user).
            uint256 byNode;
            for (uint256 n; n < nodes.length; ++n) {
                byNode += staking.stakeByNodeByUser(victim, nodes[n]);
            }
            (uint256 active, uint256 slashed) = staking.getUserStake(victim);
            assertEq(active + slashed, byNode, "stakeByUser diverged from per-node sum");

            // Views must keep working (no array-size underflow).
            staking.getNodeStakes();
            staking.getSlashedNodeStakes();
        }
    }
}
