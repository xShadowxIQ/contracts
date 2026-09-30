// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice Adversarial invariant hunt against IDOSNodeStaking.
///         Asserts two properties that must hold for the contract to be safe:
///
///  1. SOLVENCY - the contract's IDOS balance must always cover
///         (active user stakes) + (pending unstakes) + (unwithdrawn rewards).
///         If reward over-payment or slashing bookkeeping let claims exceed the
///         pool, users would be able to drain other users' principal.
///
///  2. REWARD CONSERVATION - the sum of all rewards ever owed/paid must never
///         exceed the sum of the epoch rewards that actually elapsed. A violation
///         means the reward engine mints rewards out of thin air.
contract SecuritySolvencyInvariantTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;

    address owner = makeAddr("owner");
    address[4] users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2"), makeAddr("u3")];
    address[3] nodes = [makeAddr("n0"), makeAddr("n1"), makeAddr("n2")];

    uint48 constant START = 1_000_000;
    uint256 constant EPOCH_REWARD = 100;
    uint256 constant REWARD_POOL = 1_000_000;
    uint256 constant USER_FUNDS = 50_000;

    // Total rewards already paid out, tracked across the fuzz run.
    uint256 internal totalRewardPaid;
    uint256 internal totalUnstakedPaid;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, EPOCH_REWARD);

        vm.prank(owner);
        token.transfer(address(staking), REWARD_POOL);

        for (uint256 i; i < users.length; ++i) {
            vm.prank(owner);
            token.transfer(users[i], USER_FUNDS);
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }

        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.allowNode(nodes[i]);
        }
        vm.warp(START);
    }

    /// @notice Sum of a user's pending unstake entries (public getter reverts past the end).
    function _pendingUnstake(address u) internal view returns (uint256 total) {
        for (uint256 i; i < 4096; ++i) {
            try staking.unstakesByUser(u, i) returns (uint256 amount, uint48) {
                total += amount;
            } catch {
                break;
            }
        }
    }

    /// @notice withdrawableReward(...) must never revert for a post-start user.
    /// @dev If it does, withdrawReward() is permanently blocked and the user's
    ///      accrued rewards are frozen forever.
    function _withdrawableReward(address u) internal view returns (uint256 amount, bool ok) {
        try staking.withdrawableReward(u) returns (uint256 a, uint256, uint256, uint256) {
            return (a, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Total IDOS owed to users right now (principal + pending + rewards).
    function _totalUserClaims() internal view returns (uint256 claims) {
        for (uint256 u; u < users.length; ++u) {
            (uint256 active,) = staking.getUserStake(users[u]);
            claims += active;
            claims += _pendingUnstake(users[u]);
            (uint256 reward,) = _withdrawableReward(users[u]);
            claims += reward;
        }
    }

    function _assertSolvent() internal view {
        uint256 balance = token.balanceOf(address(staking));
        uint256 claims = _totalUserClaims();
        assertGe(balance, claims, "staking contract is insolvent");
    }

    /// @notice Rewards ever owed/paid must be bounded by elapsed epoch rewards.
    function _assertRewardConservation() internal view {
        uint256 owed;
        for (uint256 u; u < users.length; ++u) {
            (uint256 reward, bool ok) = _withdrawableReward(users[u]);
            assertTrue(ok, "withdrawableReward reverted -> user rewards permanently frozen");
            owed += reward;
        }

        // Worst case if the owner never changed the epoch reward.
        uint256 elapsed = uint256(staking.currentEpoch());
        assertLe(owed + totalRewardPaid, (elapsed + 1) * EPOCH_REWARD, "reward budget exceeded");
    }

    function testFuzz_SolvencyAndRewardConservation(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 60));

        for (uint256 i; i < steps; ++i) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 12;
            uint256 ui = uint256(keccak256(abi.encode(seed, i, "u"))) % users.length;
            uint256 ni = uint256(keccak256(abi.encode(seed, i, "n"))) % nodes.length;
            uint256 amount = uint256(keccak256(abi.encode(seed, i, "a")));

            if (action == 0 || action == 1) {
                amount = bound(amount, 1, 20_000);
                // Deliberately exercise the arbitrary-user path as well.
                vm.prank(users[ui]);
                try staking.stake(users[ui], nodes[ni], amount) {} catch {}
            } else if (action == 2) {
                uint256 current = staking.stakeByNodeByUser(users[ui], nodes[ni]);
                if (current != 0) {
                    amount = bound(amount, 1, current);
                    vm.prank(users[ui]);
                    try staking.unstake(nodes[ni], amount) {} catch {}
                }
            } else if (action == 3) {
                vm.prank(owner);
                try staking.slash(nodes[ni]) {} catch {}
            } else if (action == 4) {
                vm.warp(block.timestamp + 1 days);
            } else if (action == 5) {
                vm.warp(block.timestamp + 15 days); // cross the unbonding window
            } else if (action == 6) {
                vm.prank(users[ui]);
                try staking.withdrawReward() returns (uint256 got) {
                    totalRewardPaid += got;
                } catch {}
            } else if (action == 7) {
                vm.prank(users[ui]);
                try staking.withdrawUnstaked() returns (uint256 got) {
                    totalUnstakedPaid += got;
                } catch {}
            } else if (action == 8) {
                vm.prank(owner);
                try staking.withdrawSlashedStakes() {} catch {}
            } else if (action == 9) {
                vm.prank(users[(ui + 1) % users.length]);
                try staking.withdrawReward() {} catch {}
            } else if (action == 10) {
                vm.prank(address(this));
                try staking.createEpochCheckpoint(users[ui]) {} catch {}
            } else {
                // Cross-epoch boundary stress: warp just past an epoch edge.
                vm.warp((block.timestamp / 1 days + 1) * 1 days + 1);
            }

            _assertSolvent();
            _assertRewardConservation();
        }
    }

    /// @notice Targeted: stake at the very end of an epoch, slash on the boundary,
    ///         then withdraw. Verifies no insolvency and no reward budget breach.
    function test_EndOfEpochStakeThenSlashThenWithdrawStaysSolvent() public {
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 1 days - 1); // last second of the epoch
            vm.prank(users[i % users.length]);
            staking.stake(users[i % users.length], nodes[i % nodes.length], 5_000);
        }

        vm.warp(block.timestamp + 1); // cross the epoch boundary

        vm.prank(owner);
        staking.slash(nodes[0]);
        vm.prank(owner);
        try staking.withdrawSlashedStakes() {} catch {}

        vm.warp(block.timestamp + 15 days);

        for (uint256 u; u < users.length; ++u) {
            vm.prank(users[u]);
            try staking.withdrawReward() returns (uint256 got) {
                totalRewardPaid += got;
            } catch {}
            vm.prank(users[u]);
            try staking.withdrawUnstaked() returns (uint256 got) {
                totalUnstakedPaid += got;
            } catch {}
        }

        _assertSolvent();
        _assertRewardConservation();
    }
}
