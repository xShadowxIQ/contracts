// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/// @notice IDOSNodeStaking::stake() contains an explicit guard:
///     uint256 prevBalance = idosToken.balanceOf(address(this));
///     idosToken.safeTransferFrom(user, address(this), amount);
///     uint256 received = idosToken.balanceOf(address(this)) - prevBalance;
///     if (received != amount) revert ERC20TransferAmountMismatch(amount, received);
/// with the comment "guard against non-standard tokens".
///
/// If this guard can be defeated, a caller could acquire staking credit for MORE
/// than they actually paid, or the contract's accounting would diverge from its
/// token balance. This suite attacks the guard with adversarial ERC20s.
contract SecurityNonStandardTokenTest is Test {
    // Fee-on-transfer: recipient receives less than `amount`.
    // burn the fee

    // Rebasing upward on transfer: recipient receives MORE than `amount`.
    // mint extra on every xfer

    // Lies about balanceOf, reporting a larger balance than it holds.

    // Returns false from transferFrom (pre-EIP-20 style return value handling).
    // malicious false

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address node = makeAddr("node");

    uint48 constant START = 1_700_000_000;

    function _deploy(IERC20 token) internal returns (IDOSNodeStaking s) {
        vm.prank(owner);
        s = new IDOSNodeStaking(address(token), owner, START, 100);
        vm.prank(owner);
        s.allowNode(node);
        vm.warp(START);
    }

    function _fund(IERC20 token, address to, uint256 amt) internal {
        vm.prank(address(this));
        token.transfer(to, amt);
        vm.prank(to);
        token.approve(address(_staking), type(uint256).max);
    }

    IDOSNodeStaking internal _staking;

    /// @dev Fee-on-transfer: the guard must reject, and no credit may accrue.
    function test_FeeOnTransferTokenIsRejected() public {
        FeeOnTransferToken token = new FeeOnTransferToken(100); // 1% fee
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        _staking.stake(address(0), node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 0, "no credit for short transfer");
        assertEq(_staking.getNodeStake(node), 0);
    }

    /// @dev Upward-rebasing: recipient receives MORE than `amount`. The guard
    ///      must reject rather than over-credit.
    function test_UpRebaseTokenIsRejected() public {
        UpRebaseToken token = new UpRebaseToken();
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        _staking.stake(address(0), node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 0, "no credit for over-transfer");
    }

    /// @dev Lying balanceOf: if the guard trusts the token's reported balance it
    ///      can be fooled into crediting a full stake for a partial payment.
    function test_LyingBalanceTokenCannotForgeStake() public {
        LyingBalanceToken token = new LyingBalanceToken();
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);
        token.setLie(true);

        // balanceOf doubles the reported delta, so `received` != `amount` and the
        // guard must fire.
        vm.prank(alice);
        vm.expectRevert();
        _staking.stake(address(0), node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 0, "no forged stake");
    }

    /// @dev Token returning false from transferFrom: SafeERC20 must reject it
    ///      rather than treat the transfer as successful.
    function test_TokenReturningFalseIsRejected() public {
        NoReturnToken token = new NoReturnToken();
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert();
        _staking.stake(address(0), node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 0, "no credit on false return");
    }

    /// @dev The arbitrary-user path must be equally protected: an attacker must
    ///      not be able to bank a forged stake against a victim.
    function test_GuardHoldsOnTheArbitraryUserPath() public {
        FeeOnTransferToken token = new FeeOnTransferToken(500); // 5% fee
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);

        vm.prank(attacker);
        vm.expectRevert();
        _staking.stake(alice, node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 0);
        assertEq(token.balanceOf(alice), 10_000, "victim balance untouched");
    }

    /// @dev Sanity: a STANDARD token still works, proving the guard is not simply
    ///      rejecting everything.
    function test_StandardTokenStillStakesNormally() public {
        ERC20 token = new ERC20("Std", "STD");
        _staking = _deploy(token);

        vm.prank(address(this));
        token.transfer(alice, 10_000);
        vm.prank(alice);
        token.approve(address(_staking), type(uint256).max);

        vm.prank(alice);
        _staking.stake(address(0), node, 5_000);

        assertEq(_staking.stakeByNodeByUser(alice, node), 5_000, "standard path unaffected");
        assertEq(_staking.getNodeStake(node), 5_000);
    }
}
