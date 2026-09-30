// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";
import {IDOSToken} from "../src/IDOSToken.sol";

contract SecurityAccountingFuzzTest is Test {
    IDOSToken token;
    IDOSNodeStaking staking;
    address owner = makeAddr("owner");
    address[3] users = [makeAddr("u0"), makeAddr("u1"), makeAddr("u2")];
    address[2] nodes = [makeAddr("n0"), makeAddr("n1")];

    uint48 constant START = 1_000_000;

    function setUp() public {
        vm.prank(owner);
        token = new IDOSToken(owner);
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, 100);

        vm.prank(owner);
        token.transfer(address(staking), 1_000_000);

        for (uint256 i; i < users.length; ++i) {
            vm.prank(owner);
            token.transfer(users[i], 10_000);
            vm.prank(users[i]);
            token.approve(address(staking), type(uint256).max);
        }

        for (uint256 i; i < nodes.length; ++i) {
            vm.prank(owner);
            staking.allowNode(nodes[i]);
        }
        vm.warp(START);
    }

    function _tryStake(uint256 ui, uint256 ni, uint256 amount, address caller) internal {
        ui %= users.length;
        ni %= nodes.length;
        amount = bound(amount, 1, 1_000);
        vm.prank(caller);
        try staking.stake(users[ui], nodes[ni], amount) {} catch {}
    }

    function _tryUnstake(uint256 ui, uint256 ni, uint256 amount) internal {
        ui %= users.length;
        ni %= nodes.length;
        uint256 current = staking.stakeByNodeByUser(users[ui], nodes[ni]);
        if (current == 0) return;
        amount = bound(amount, 1, current);
        vm.prank(users[ui]);
        try staking.unstake(nodes[ni], amount) {} catch {}
    }

    function _trySlash(uint256 ni) internal {
        ni %= nodes.length;
        vm.prank(owner);
        try staking.slash(nodes[ni]) {} catch {}
    }

    function _assertAccounting() internal view {
        uint256 totalNodes;
        for (uint256 n; n < nodes.length; ++n) {
            uint256 nodeTotal;
            for (uint256 u; u < users.length; ++u) {
                nodeTotal += staking.stakeByNodeByUser(users[u], nodes[n]);
            }
            assertEq(staking.getNodeStake(nodes[n]), nodeTotal);
            totalNodes += nodeTotal;
        }

        uint256 totalUsers;
        for (uint256 u; u < users.length; ++u) {
            (uint256 active, uint256 slashed) = staking.getUserStake(users[u]);
            uint256 byNode;
            for (uint256 n; n < nodes.length; ++n) {
                byNode += staking.stakeByNodeByUser(users[u], nodes[n]);
            }
            assertEq(active + slashed, byNode);
            totalUsers += active + slashed;
        }

        assertEq(totalNodes, totalUsers);
    }

    function testFuzz_AccountingAndRewardConservation(
        uint256 seed,
        uint8 steps,
        uint256[8] memory amounts
    ) public {
        steps = uint8(bound(steps, 1, 40));

        for (uint256 i; i < steps; ++i) {
            uint256 action = uint256(keccak256(abi.encode(seed, i))) % 8;
            uint256 ui = uint256(keccak256(abi.encode(seed, i, "u"))) % users.length;
            uint256 ni = uint256(keccak256(abi.encode(seed, i, "n"))) % nodes.length;
            uint256 amount = amounts[i % amounts.length];

            if (action == 0 || action == 1) {
                _tryStake(ui, ni, amount, users[ui]);
            } else if (action == 2 || action == 3) {
                _tryUnstake(ui, ni, amount);
            } else if (action == 4) {
                _trySlash(ni);
            } else if (action == 5) {
                vm.warp(block.timestamp + 1 days);
            } else if (action == 6) {
                vm.prank(users[ui]);
                try staking.withdrawReward() {} catch {}
            } else {
                vm.prank(address(this));
                try staking.createEpochCheckpoint(users[ui]) {} catch {}
            }

            _assertAccounting();
        }

        vm.warp(block.timestamp + 5 days);

        uint256 sumWithdrawable;
        for (uint256 u; u < users.length; ++u) {
            (uint256 amount,,,,) = staking.withdrawableReward(users[u]);
            sumWithdrawable += amount;
        }

        uint256 epochs = uint256(staking.currentEpoch()) + 1;
        assertLe(sumWithdrawable, epochs * 100);
    }
}
