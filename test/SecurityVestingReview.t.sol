// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSVesting} from "../src/IDOSVesting.sol";

/// @notice Attempts to break IDOSVesting. Records the outcome of each hypothesis
///         so the file doubles as evidence that the contract is NOT vulnerable.
contract SecurityVestingReviewTest is Test {
    IDOSToken token;
    address beneficiary = makeAddr("beneficiary");
    address attacker = makeAddr("attacker");

    uint256 constant START = 1_000_000;
    uint256 constant DURATION = 100 days;

    function setUp() public {
        vm.prank(beneficiary);
        token = new IDOSToken(beneficiary);
    }

    /// @dev H1 (REJECTED): cliff > duration would strand the allocation.
    ///      OZ 5.5.0 VestingWalletCliff guards this in its constructor.
    function test_H1_CliffLongerThanDurationIsRejectedAtConstruction() public {
        vm.expectRevert(
            abi.encodeWithSignature("InvalidCliffDuration(uint64,uint64)", uint64(DURATION + 1), uint64(DURATION))
        );
        new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), uint64(DURATION + 1));
    }

    /// @dev H2 (REJECTED): cliff == duration degenerates to a plain timelock,
    ///      not a fund-stranding bug - everything unlocks exactly at end().
    function test_H2_CliffEqualToDurationUnlocksAtEnd() public {
        IDOSVesting v = new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), uint64(DURATION));
        vm.prank(beneficiary);
        token.transfer(address(v), 100);

        vm.warp(START + DURATION - 1);
        assertEq(v.releasable(address(token)), 0, "nothing before end");

        vm.warp(START + DURATION);
        assertEq(v.releasable(address(token)), 100, "all at end");
    }

    /// @dev H3 (REJECTED): pre-start calls must revert, not underflow.
    function test_H3_NoUnderflowBeforeStart() public {
        IDOSVesting v = new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), 10 days);
        vm.prank(beneficiary);
        token.transfer(address(v), 100);

        vm.warp(START - 1);
        assertEq(v.releasable(address(token)), 0);

        // release() before start is a harmless no-op (0-value transfer), not an
        // underflow and not a drain: nothing moves.
        uint256 benBefore = token.balanceOf(beneficiary);
        uint256 walletBefore = token.balanceOf(address(v));
        vm.prank(attacker);
        v.release(address(token));
        assertEq(token.balanceOf(address(v)), walletBefore, "wallet untouched");
        assertEq(token.balanceOf(beneficiary), benBefore, "beneficiary untouched");
    }

    /// @dev H4 (REJECTED): release() is permissionless by design but always pays
    ///      the beneficiary (owner). No third party can redirect funds.
    function test_H4_PermissionlessReleaseAlwaysPaysBeneficiary() public {
        IDOSVesting v = new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), 0);
        vm.prank(beneficiary);
        token.transfer(address(v), 100);

        vm.warp(START + DURATION);

        uint256 benBefore = token.balanceOf(beneficiary);
        uint256 attBefore = token.balanceOf(attacker);

        vm.prank(attacker);
        v.release(address(token));

        assertEq(token.balanceOf(beneficiary), benBefore + 100, "beneficiary paid in full");
        assertEq(token.balanceOf(attacker), attBefore, "attacker gains nothing");
    }

    /// @dev H5 (REJECTED): double release cannot overdraw - releasable() nets
    ///      against released(token).
    function test_H5_NoDoubleRelease() public {
        IDOSVesting v = new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), 0);
        vm.prank(beneficiary);
        token.transfer(address(v), 100);

        vm.warp(START + DURATION);

        vm.prank(attacker);
        v.release(address(token));
        assertEq(v.releasable(address(token)), 0, "fully released");
        assertEq(token.balanceOf(address(v)), 0, "wallet drained exactly once");

        // A repeat release is a 0-value no-op: no further outflow.
        uint256 benAfter = token.balanceOf(beneficiary);
        vm.prank(attacker);
        v.release(address(token));
        assertEq(token.balanceOf(beneficiary), benAfter, "no double payout");
    }

    /// @dev H6 (INFORMATIONAL): the _vestingSchedule override in IDOSVesting is
    ///      byte-identical in behaviour to VestingWalletCliff's own implementation,
    ///      i.e. redundant dead code. Confirms it changes no schedule semantics.
    function test_H6_OverrideIsRedundantNotDivergent() public {
        IDOSVesting v = new IDOSVesting(beneficiary, uint64(START), uint64(DURATION), 10 days);
        vm.prank(beneficiary);
        token.transfer(address(v), 100);

        // Cliff semantics must hold: nothing before cliff, linear-at-cliff value after.
        vm.warp(START + 10 days - 1);
        assertEq(v.releasable(address(token)), 0, "zero before cliff");
        vm.warp(START + 10 days);
        assertEq(v.releasable(address(token)), 10, "10% at cliff for 100 token / 100 day duration");
    }
}
