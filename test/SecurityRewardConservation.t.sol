// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice Closes a real gap in earlier fuzzing: those runs used a CONSTANT epoch
///         reward, so `setEpochReward()` interleaved with checkpoint creation was
///         never exercised.
///
/// `withdrawableReward()` derives each epoch's reward via
///     epochRewardHistory.upperLookup(i)
/// and accumulates
///     rewardAcc += (userStakeAcc * epochReward) / totalStakeAcc
/// If the upper-lookup window, the epoch boundaries, or the checkpoint epoch are
/// off by one, rewards can be paid OUTSIDE the funded budget - i.e. the reward
/// engine mints claims that are backed by other users' principal.
///
/// This suite models the exact reward schedule in the test and asserts the hard
/// conservation law: total rewards owed/paid <= total rewards actually allotted.
contract SecurityRewardConservationTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address[4] users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
    address[3] nodes = [makeAddr("n0"), makeAddr("n1"), makeAddr("n2")];

    uint48 constant START = 1_000_000;
    uint256 constant INITIAL_REWARD = 100;
    uint256 constant MAX_EPOCH = 96;

    /// Mirror of epochRewardHistory: reward applicable to epoch i.
    mapping(uint256 => uint256) internal rewardAt;
    /// Cumulative rewards already withdrawn, per user.
    mapping(address => uint256) internal paid;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, INITIAL_REWARD);

        vm.prank(owner);
        token.transfer(address(staking), 5_000_000);

        for (uint256 i; i < users.length; ++i) {
            vm.prank(owner);
            token.transfer(users[i], 100_000);
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }
        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.allowNode(nodes[i]);
        }
        for (uint256 i; i <= MAX_EPOCH; ++i) {
            rewardAt[i] = INITIAL_REWARD;
        }
        vm.warp(START);
    }

    /// @dev Apply a reward change exactly the way the contract does:
    ///      setEpochReward pushes at currentEpoch(), and upperLookup(i) returns the
    ///      last value with key <= i, so the new value governs i >= currentEpoch.
    function _modelSetEpochReward(uint256 newReward) internal {
        uint48 e = staking.currentEpoch();
        for (uint256 i = e; i <= MAX_EPOCH; ++i) {
            rewardAt[i] = newReward;
        }
    }

    /// @dev Total rewards the protocol actually allotted over all COMPLETED epochs.
    function _budget() internal view returns (uint256 total) {
        uint256 e = staking.currentEpoch();
        for (uint256 i; i < e; ++i) {
            total += rewardAt[i];
        }
    }

    function _totalOwed() internal view returns (uint256 total) {
        for (uint256 u; u < users.length; ++u) {
            (uint256 reward, bool ok) = _withdrawable(users[u]);
            assertTrue(ok, "withdrawableReward reverted");
            total += paid[users[u]] + reward;
        }
    }

    function _withdrawable(address u) internal view returns (uint256 amount, bool ok) {
        try staking.withdrawableReward(u) returns (uint256 a, uint256, uint256, uint256) {
            return (a, true);
        } catch {
            return (0, false);
        }
    }

    function _assertConservation() internal view {
        assertLe(_totalOwed(), _budget(), "reward claims exceed allotted budget");
    }

    /// @dev Warp, but never past the modelled epoch horizon - otherwise the
    ///      rewardAt mirror runs out and the budget silently undercounts
    ///      (a false positive, not a contract bug).
    function _safeWarp(uint256 delta) internal {
        // exact epoch horizon guard: a `delta` second jump advances up to
        // floor(delta / EPOCH_LENGTH) + 1 epochs, so budget for that.
        uint256 epochsNeeded = delta / 1 days + 2;
        if (uint256(staking.currentEpoch()) + epochsNeeded >= MAX_EPOCH) return;
        vm.warp(block.timestamp + delta);
    }

    function testFuzz_RewardConservationUnderChangingEpochReward(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 70));

        for (uint256 i; i < steps; ++i) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 13;
            uint256 ui = uint256(keccak256(abi.encode(seed, i, "u"))) % users.length;
            uint256 ni = uint256(keccak256(abi.encode(seed, i, "n"))) % nodes.length;

            if (action == 0 || action == 1) {
                uint256 amt = bound(uint256(keccak256(abi.encode(seed, i, "a"))), 1, 40_000);
                vm.prank(users[ui]);
                try staking.stake(users[ui], nodes[ni], amt) {} catch {}
            } else if (action == 2) {
                uint256 cur = staking.stakeByNodeByUser(users[ui], nodes[ni]);
                if (cur != 0) {
                    uint256 amt = bound(uint256(keccak256(abi.encode(seed, i, "b"))), 1, cur);
                    vm.prank(users[ui]);
                    try staking.unstake(nodes[ni], amt) {} catch {}
                }
            } else if (action == 3) {
                vm.prank(owner);
                try staking.slash(nodes[ni]) {} catch {}
            } else if (action == 4) {
                _safeWarp(1 days);
            } else if (action == 5) {
                _safeWarp(15 days);
            } else if (action == 6) {
                // *** the previously untested axis ***
                uint256 r = bound(uint256(keccak256(abi.encode(seed, i, "r"))), 0, 5_000);
                vm.prank(owner);
                try staking.setEpochReward(r) {
                    _modelSetEpochReward(r);
                } catch {}
            } else if (action == 7) {
                vm.prank(users[ui]);
                try staking.withdrawReward() returns (uint256 got) {
                    paid[users[ui]] += got;
                } catch {}
            } else if (action == 8) {
                vm.prank(users[ui]);
                try staking.withdrawUnstaked() {} catch {}
            } else if (action == 9) {
                vm.prank(owner);
                try staking.withdrawSlashedStakes() {} catch {}
            } else if (action == 10) {
                // third-party checkpoint creation (permissionless, griefing vector)
                vm.prank(users[(ui + 1) % users.length]);
                try staking.createEpochCheckpoint(users[ui]) {} catch {}
            } else if (action == 11) {
                if (staking.currentEpoch() + 2 < MAX_EPOCH) {
                    vm.warp((block.timestamp / 1 days + 1) * 1 days + 1); // epoch edge
                }
            } else {
                // stake with a third-party `user` to keep the arbitrary-user path hot
                uint256 amt = bound(uint256(keccak256(abi.encode(seed, i, "c"))), 1, 5_000);
                vm.prank(users[ui]);
                try staking.stake(users[(ui + 2) % users.length], nodes[ni], amt) {} catch {}
            }

            _assertConservation();
        }
    }

    /// @dev Targeted: stake, checkpoint, then the owner DOUBLES the epoch reward.
    ///      Verifies no epoch is paid twice or retroactively inflated.
    function test_RewardChangeAfterCheckpointDoesNotRetroactivelyInflate() public {
        vm.prank(users[0]);
        staking.stake(users[0], nodes[0], 10_000);

        vm.warp(block.timestamp + 1 days); // epoch 1 begins

        // User checkpoints at epoch 1, before any reward change.
        vm.prank(users[0]);
        staking.createEpochCheckpoint(users[0]);

        // Owner now doubles the reward; this must govern epoch >= 1 only.
        vm.prank(owner);
        staking.setEpochReward(INITIAL_REWARD * 2);
        _modelSetEpochReward(INITIAL_REWARD * 2);

        vm.warp(block.timestamp + 1 days); // epoch 2 begins

        vm.prank(users[0]);
        uint256 got = staking.withdrawReward();
        paid[users[0]] += got;

        // Budget over 2 completed epochs = 100 (epoch0) + 200 (epoch1) = 300.
        assertEq(_budget(), 300, "budget model");
        assertLe(_totalOwed(), _budget(), "over-credited");
    }

    /// @dev Targeted: reward DROPPED to zero after checkpoints - a classic
    ///      upperLookup off-by-one would let the old (larger) reward through.
    function test_RewardDroppedToZeroAfterCheckpoint() public {
        vm.prank(users[0]);
        staking.stake(users[0], nodes[0], 10_000);
        vm.prank(users[1]);
        staking.stake(users[1], nodes[1], 10_000);

        vm.warp(block.timestamp + 1 days);
        vm.prank(users[0]);
        staking.createEpochCheckpoint(users[0]);

        vm.prank(owner);
        staking.setEpochReward(0);
        _modelSetEpochReward(0);

        vm.warp(block.timestamp + 2 days);

        vm.prank(users[0]);
        try staking.withdrawReward() returns (uint256 got) {
            paid[users[0]] += got;
        } catch {}

        assertLe(_totalOwed(), _budget(), "must not exceed post-change budget");
    }

    /// @dev Two setEpochReward calls inside one epoch. OZ v5 Checkpoints OVERWRITE an
    ///      existing key rather than reverting, so the second call succeeds and
    ///      replaces the value. Confirm that is harmless: the final value governs,
    ///      completed epochs are untouched, and conservation still holds.
    function test_SetEpochRewardTwiceInSameEpochOverwritesSafely() public {
        vm.prank(users[0]);
        staking.stake(users[0], nodes[0], 10_000);

        vm.prank(owner);
        staking.setEpochReward(500);
        _modelSetEpochReward(500);

        // Same epoch, second change - overwrites rather than reverting.
        vm.prank(owner);
        staking.setEpochReward(700);
        _modelSetEpochReward(700);

        // A completed epoch's reward must stay pinned to the value in force then.
        vm.warp(block.timestamp + 1 days);

        vm.prank(users[0]);
        uint256 got = staking.withdrawReward();
        paid[users[0]] += got;

        // Epoch 0 completed under reward 700 (set before the epoch closed).
        assertEq(_budget(), 700, "epoch 0 budget pinned to latest in-epoch value");
        assertLe(_totalOwed(), _budget(), "conservation holds");
    }
}
