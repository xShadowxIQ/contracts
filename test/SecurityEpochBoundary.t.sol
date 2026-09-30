// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice Characterises the epoch-bucketed reward accounting from BOTH sides.
///         Time is warped to the second, so stake/unstake timing within a single
///         epoch is fully controllable. This pins down exactly who is credited
///         and who is debited, and for how long they actually held capital.
contract SecurityEpochBoundaryTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address node = makeAddr("node");

    uint48 constant START = 1_000_000;
    uint256 constant REWARD = 1_000;
    uint256 constant STAKE = 10_000;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, REWARD);

        vm.prank(owner);
        token.transfer(address(staking), 1_000_000);
        vm.prank(owner);
        token.transfer(alice, 1_000_000);
        vm.prank(alice);
        token.approve(address(staking), type(uint256).max);
        vm.prank(owner);
        staking.allowNode(node);
        vm.warp(START);
    }

    /// @dev Holds capital for ~the ENTIRE epoch, then exits 1 second before the
    ///      boundary (still inside the same epoch).
    ///      Expectation from a time-weighted design: nearly a full epoch's reward.
    function test_HeldNearlyWholeEpochThenExitedEarlyInSameEpoch() public {
        vm.prank(alice);
        staking.stake(alice, node, STAKE);

        // 23h 59m into epoch 0
        vm.warp(START + 23 hours + 59 minutes);

        vm.prank(alice);
        staking.unstake(node, STAKE);

        vm.warp(START + 2 days); // epoch 1 begins, epoch 0 is now complete

        vm.prank(alice);
        uint256 got = staking.withdrawReward();

        // Actual behaviour: stake and unstake land in the SAME epoch, so they
        // cancel out and the user is credited NOTHING.
        assertEq(got, 0, "held ~24h but received zero reward");
    }

    /// @dev Holds capital for ~ONE SECOND across the epoch boundary.
    ///      Expectation from a time-weighted design: a rounding error's worth.
    function test_HeldOneSecondAcrossBoundaryEarnsFullEpochReward() public {
        // 1 second before the epoch 0 -> 1 boundary
        vm.warp(START + 1 days - 1);
        vm.prank(alice);
        staking.stake(alice, node, STAKE);

        // 1 second after the boundary
        vm.warp(START + 1 days + 1);
        vm.prank(alice);
        staking.unstake(node, STAKE);

        vm.warp(START + 2 days + 1);

        vm.prank(alice);
        uint256 got = staking.withdrawReward();

        // Actual behaviour: FULL epoch reward for one second of exposure.
        assertEq(got, REWARD, "1 second of staking earned a full epoch reward");
    }

    /// @dev Control: stake and unstake in DIFFERENT epochs, holding across the
    ///      boundary properly. This is the case the design handles correctly.
    function test_HeldAcrossBoundaryInSeparateEpochsEarnsCorrectly() public {
        vm.prank(alice);
        staking.stake(alice, node, STAKE); // epoch 0

        vm.warp(START + 1 days + 1); // epoch 1
        vm.prank(alice);
        staking.unstake(node, STAKE); // epoch 1

        vm.warp(START + 2 days + 1); // epoch 1 complete

        vm.prank(alice);
        uint256 got = staking.withdrawReward();

        assertEq(got, REWARD, "exactly one epoch rewarded");
    }

    /// @dev Two users, same node: the over-credit from holding 1 second across the
    ///      boundary is paid out of the same pool, so it dilutes the user who
    ///      actually held the capital all epoch.
    function test_SecondBoundarySnifferDilutesLongTermStaker() public {
        address bob = makeAddr("bob");
        vm.prank(owner);
        token.transfer(bob, 1_000_000);
        vm.prank(bob);
        token.approve(address(staking), type(uint256).max);

        // Long-term staker: holds from the start of epoch 0.
        vm.prank(alice);
        staking.stake(alice, node, STAKE);

        // Boundary sniffer: stakes 1 second before the boundary.
        vm.warp(START + 1 days - 1);
        vm.prank(bob);
        staking.stake(bob, node, STAKE);

        // Alice exits in epoch 1; Bob exits in epoch 1 too (after the boundary).
        vm.warp(START + 1 days + 1);
        vm.prank(alice);
        staking.unstake(node, STAKE);
        vm.prank(bob);
        staking.unstake(node, STAKE);

        vm.warp(START + 2 days + 1);

        vm.prank(alice);
        uint256 aliceGot = staking.withdrawReward();
        vm.prank(bob);
        uint256 bobGot = staking.withdrawReward();

        // Both held identical principal. Alice held the whole epoch; Bob held ~1s.
        assertEq(bobGot, aliceGot, "identical principal earned identical reward");
        assertGt(bobGot, 0);
    }
}