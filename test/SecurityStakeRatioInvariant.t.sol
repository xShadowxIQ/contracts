// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice Targets a precise hypothesis raised by Slither's `incorrect-equality`
///         flag on line 245 of IDOSNodeStaking:
///
///     if (totalStakeAcc == 0) continue;
///     rewardAcc += (userStakeAcc * epochReward) / totalStakeAcc;
///
/// `withdrawableReward` is a view that RETURNS both accumulators. If it were ever
/// possible for `userStakeAcc > totalStakeAcc`, the ratio would exceed 1 and a
/// user would be credited more than the entire epoch reward pool - i.e. rewards
/// minted out of thin air, paid from other users' principal.
///
/// Invariant asserted after every single state transition:
///     userStakeAcc(user) <= totalStakeAcc   for every user
///
/// Plus the aggregate consequence: sum of all users' shares <= 1 x pool.
contract SecurityStakeRatioInvariantTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address[5] users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2"), makeAddr("u3"), makeAddr("u4")];
    address[4] nodes = [makeAddr("n0"), makeAddr("n1"), makeAddr("n2"), makeAddr("n3")];

    uint48 constant START = 1_000_000;
    uint256 constant REWARD = 1_000;
    uint256 constant MAX_EPOCH = 200;

    mapping(uint256 => uint256) internal rewardAt;
    mapping(address => uint256) internal paid;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, REWARD);

        vm.prank(owner);
        token.transfer(address(staking), 10_000_000);

        for (uint256 i; i < users.length; ++i) {
            vm.prank(owner);
            token.transfer(users[i], 200_000);
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }
        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.allowNode(nodes[i]);
        }
        for (uint256 i; i <= MAX_EPOCH; ++i) {
            rewardAt[i] = REWARD;
        }
        vm.warp(START);
    }

    function _safeWarp(uint256 delta) internal {
        uint256 epochsNeeded = delta / 1 days + 2;
        if (uint256(staking.currentEpoch()) + epochsNeeded >= MAX_EPOCH) return;
        vm.warp(block.timestamp + delta);
    }

    function _modelSetEpochReward(uint256 r) internal {
        uint48 e = staking.currentEpoch();
        for (uint256 i = e; i <= MAX_EPOCH; ++i) {
            rewardAt[i] = r;
        }
    }

    function _budget() internal view returns (uint256 total) {
        uint256 e = staking.currentEpoch();
        for (uint256 i; i < e; ++i) {
            total += rewardAt[i];
        }
    }

    /// @dev The core hypothesis check.
    function _assertNoUserExceedsPool() internal view {
        uint256 owed;
        for (uint256 u; u < users.length; ++u) {
            (uint256 reward,, uint256 userStakeAcc, uint256 totalStakeAcc) = staking.withdrawableReward(users[u]);

            assertLe(userStakeAcc, totalStakeAcc, "userStakeAcc exceeded totalStakeAcc -> ratio > 1 -> over-reward");
            owed += paid[users[u]] + reward;
        }
        assertLe(owed, _budget(), "aggregate rewards exceeded budget");
    }

    function testFuzz_UserStakeShareNeverExceedsPool(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 80));

        for (uint256 i; i < steps; ++i) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 14;
            uint256 ui = uint256(keccak256(abi.encode(seed, i, "u"))) % users.length;
            uint256 ni = uint256(keccak256(abi.encode(seed, i, "n"))) % nodes.length;

            if (action <= 1) {
                uint256 amt = bound(uint256(keccak256(abi.encode(seed, i, "a"))), 1, 50_000);
                // Mix self-stake and third-party (arbitrary-user) stakes.
                address who = action == 0 ? users[ui] : users[(ui + 2) % users.length];
                vm.prank(users[ui]);
                try staking.stake(who, nodes[ni], amt) {} catch {}
            } else if (action <= 3) {
                uint256 cur = staking.stakeByNodeByUser(users[ui], nodes[ni]);
                if (cur != 0) {
                    uint256 amt = bound(uint256(keccak256(abi.encode(seed, i, "b"))), 1, cur);
                    vm.prank(users[ui]);
                    try staking.unstake(nodes[ni], amt) {} catch {}
                }
            } else if (action == 4) {
                vm.prank(owner);
                try staking.slash(nodes[ni]) {} catch {}
            } else if (action == 5) {
                _safeWarp(1 hours); // sub-day warps to hit partial epochs
            } else if (action == 6) {
                _safeWarp(1 days);
            } else if (action == 7) {
                _safeWarp(15 days);
            } else if (action == 8) {
                uint256 r = bound(uint256(keccak256(abi.encode(seed, i, "r"))), 0, 20_000);
                vm.prank(owner);
                try staking.setEpochReward(r) {
                    _modelSetEpochReward(r);
                } catch {}
            } else if (action == 9) {
                vm.prank(users[ui]);
                try staking.withdrawReward() returns (uint256 got) {
                    paid[users[ui]] += got;
                } catch {}
            } else if (action == 10) {
                vm.prank(users[ui]);
                try staking.withdrawUnstaked() {} catch {}
            } else if (action == 11) {
                vm.prank(owner);
                try staking.withdrawSlashedStakes() {} catch {}
            } else if (action == 12) {
                vm.prank(users[(ui + 3) % users.length]);
                try staking.createEpochCheckpoint(users[ui]) {} catch {}
            } else {
                if (uint256(staking.currentEpoch()) + 2 < MAX_EPOCH) {
                    vm.warp((block.timestamp / 1 days + 1) * 1 days + 1); // epoch edge
                }
            }

            _assertNoUserExceedsPool();
        }
    }

    /// @dev Targeted: drive the pool to zero via slashing while a user still
    ///      carries a non-zero accumulator, then let a new epoch re-open it.
    ///      This is the exact shape that would expose ratio > 1.
    function test_ZeroPoolEpochThenReopenNeverOverRewards() public {
        vm.prank(users[0]);
        staking.stake(users[0], nodes[0], 100_000);

        // Bob joins so the pool is shared.
        vm.prank(users[1]);
        staking.stake(users[1], nodes[1], 100_000);

        _safeWarp(1 days);

        // Slash the node user0 is on: their share drops, then both exit.
        vm.prank(owner);
        staking.slash(nodes[0]);
        vm.prank(users[1]);
        staking.unstake(nodes[1], 100_000);

        _safeWarp(1 days); // epoch where totalStakeAcc may hit 0 -> `continue`

        // Carol re-opens the pool at a new node.
        vm.prank(users[2]);
        staking.stake(users[2], nodes[2], 50_000);

        _safeWarp(2 days);

        for (uint256 u; u < users.length; ++u) {
            vm.prank(users[u]);
            try staking.withdrawReward() returns (uint256 got) {
                paid[users[u]] += got;
            } catch {}
        }

        _assertNoUserExceedsPool();
    }
}
