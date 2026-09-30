// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

// Fee-on-transfer: the recipient receives LESS than `amount`.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBps;

    constructor(uint256 f) ERC20("Fee", "FEE") {
        feeBps = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 fee = (value * feeBps) / 10_000;
        super._update(from, to, value - fee);
        if (fee > 0) {
            super._update(from, address(0xdead), fee);
        }
    }
}

// Rebases upward on every transfer: the recipient receives MORE than `amount`.
contract UpRebaseToken is ERC20 {
    constructor() ERC20("Up", "UP") {}

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to != address(0)) {
            super._update(address(0), to, value / 10);
        }
    }
}

// Reports a balanceOf larger than what it actually holds.
contract LyingBalanceToken is ERC20 {
    bool public lie;

    constructor() ERC20("Liar", "LIAR") {}

    function setLie(bool v) external {
        lie = v;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) * (lie ? 2 : 1);
    }
}

// Performs the transfer but returns false, as some pre-EIP-20 tokens did.
contract NoReturnToken is ERC20 {
    constructor() ERC20("NoRet", "NRT") {}

    function transferFrom(address f, address t, uint256 v) public override returns (bool) {
        super._transfer(f, t, v);
        return false;
    }
}

/// @notice IDOSNodeStaking::stake() carries an explicit guard:
///     uint256 prevBalance = idosToken.balanceOf(address(this));
///     idosToken.safeTransferFrom(user, address(this), amount);
///     uint256 received = idosToken.balanceOf(address(this)) - prevBalance;
///     if (received != amount) revert ERC20TransferAmountMismatch(amount, received);
/// commented "guard against non-standard tokens".
///
/// If that guard can be defeated, a caller could bank staking credit for MORE
/// than was actually paid, or the contract's accounting would diverge from its
/// token balance. This suite attacks the guard with adversarial ERC20s.
contract SecurityNonStandardTokenTest is Test {
    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address attacker = makeAddr("attacker");
    address node = makeAddr("node");

    uint48 constant START = 1_700_000_000;

    IDOSNodeStaking internal staking;

    function _deploy(IERC20 token) internal {
        vm.prank(owner);
        staking = new IDOSNodeStaking(address(token), owner, START, 100);
        vm.prank(owner);
        staking.allowNode(node);
        vm.warp(START);
    }

    function _fund(IERC20 token, address to, uint256 amt) internal {
        vm.prank(address(this));
        token.transfer(to, amt);
        vm.prank(to);
        token.approve(address(staking), type(uint256).max);
    }

    function test_FeeOnTransferTokenIsRejected() public {
        FeeOnTransferToken token = new FeeOnTransferToken(100);
        _deploy(token);
        _fund(token, alice, 10_000);

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(address(0), node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 0, "no credit for short transfer");
        assertEq(staking.getNodeStake(node), 0);
    }

    function test_UpRebaseTokenIsRejected() public {
        UpRebaseToken token = new UpRebaseToken();
        _deploy(token);
        _fund(token, alice, 10_000);

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(address(0), node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 0, "no credit for over-transfer");
    }

    function test_LyingBalanceTokenCannotForgeStake() public {
        LyingBalanceToken token = new LyingBalanceToken();
        _deploy(token);
        _fund(token, alice, 10_000);
        token.setLie(true);

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(address(0), node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 0, "no forged stake");
    }

    function test_TokenReturningFalseIsRejected() public {
        NoReturnToken token = new NoReturnToken();
        _deploy(token);
        _fund(token, alice, 10_000);

        vm.prank(alice);
        vm.expectRevert();
        staking.stake(address(0), node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 0, "no credit on false return");
    }

    function test_GuardHoldsOnTheArbitraryUserPath() public {
        FeeOnTransferToken token = new FeeOnTransferToken(500);
        _deploy(token);
        _fund(token, alice, 10_000);

        uint256 aliceBefore = token.balanceOf(alice);

        vm.prank(attacker);
        vm.expectRevert();
        staking.stake(alice, node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 0);
        assertEq(token.balanceOf(alice), aliceBefore, "victim balance untouched");
    }

    function test_StandardTokenStillStakesNormally() public {
        ERC20 token = new ERC20("Std", "STD");
        _deploy(token);
        _fund(token, alice, 10_000);

        vm.prank(alice);
        staking.stake(address(0), node, 5_000);

        assertEq(staking.stakeByNodeByUser(alice, node), 5_000, "standard path unaffected");
        assertEq(staking.getNodeStake(node), 5_000);
    }
}