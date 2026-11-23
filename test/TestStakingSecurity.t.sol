// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TestStaking} from "../src/TestStaking.sol";
import {AdversarialToken} from "./mocks/AdversarialToken.sol";

contract TestStakingSecurityTest is Test {
    AdversarialToken internal token;
    TestStaking internal staking;
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_000_000);
        token = new AdversarialToken(alice, 100 ether);
        // Making the malicious token the owner exercises rate callbacks past access control.
        staking = new TestStaking(address(token), address(token));
        vm.prank(alice);
        token.approve(address(staking), 100 ether);
    }

    function _deposit() internal {
        vm.prank(alice);
        staking.stake(10 ether);
    }

    function _assertEmpty() internal view {
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.stakes(alice), 0);
        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.allowance(alice, address(staking)), 100 ether);
    }

    function test_falseReturnDepositRevertsAtomically() public {
        token.setModes(AdversarialToken.Mode.ReturnFalse, AdversarialToken.Mode.Normal);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        staking.stake(10 ether);
        _assertEmpty();
    }

    function test_revertingDepositBubblesError() public {
        token.setModes(AdversarialToken.Mode.Revert, AdversarialToken.Mode.Normal);
        vm.prank(alice);
        vm.expectRevert(AdversarialToken.TokenRefused.selector);
        staking.stake(10 ether);
        _assertEmpty();
    }

    function test_trueWithoutTransferCannotCreatePrincipal() public {
        token.setModes(AdversarialToken.Mode.NoMovement, AdversarialToken.Mode.Normal);
        vm.prank(alice);
        vm.expectRevert(TestStaking.UnexpectedTokenBalance.selector);
        staking.stake(10 ether);
        _assertEmpty();
    }

    function test_transferFeeDepositIsRejected() public {
        token.setModes(AdversarialToken.Mode.TransferFee, AdversarialToken.Mode.Normal);
        vm.prank(alice);
        vm.expectRevert(TestStaking.UnexpectedTokenBalance.selector);
        staking.stake(10 ether);
        _assertEmpty();
    }

    function test_noReturnTokensWorkThroughSafeTransfers() public {
        token.setModes(AdversarialToken.Mode.NoReturn, AdversarialToken.Mode.NoReturn);
        _deposit();
        skip(10);
        vm.prank(alice);
        staking.withdraw(10 ether);
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(staking.pendingPoints(alice), 10 ether);
    }

    function test_failedWithdrawalPreservesPrincipalPointsAndCanRetry() public {
        _deposit();
        skip(10);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.ReturnFalse);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        staking.withdraw(10 ether);
        assertEq(staking.stakes(alice), 10 ether);
        assertEq(staking.totalStaked(), 10 ether);
        assertEq(staking.earnedPoints(alice), 0);
        assertEq(staking.lastUpdateTime(), 1_000_000);
        assertEq(token.balanceOf(address(staking)), 10 ether);
        assertEq(staking.pendingPoints(alice), 10 ether);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Revert);
        vm.prank(alice);
        vm.expectRevert(AdversarialToken.TokenRefused.selector);
        staking.withdraw(10 ether);
        token.setModes(AdversarialToken.Mode.Normal, AdversarialToken.Mode.Normal);
        skip(5);
        vm.prank(alice);
        staking.withdraw(10 ether);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(staking.pendingPoints(alice), 15 ether);
    }

    function test_depositAndWithdrawalCallbacksCannotReenterAnyAccountingMethod() public {
        bytes[4] memory payloads = [
            abi.encodeCall(TestStaking.stake, (1)),
            abi.encodeCall(TestStaking.withdraw, (1)),
            abi.encodeCall(TestStaking.checkpoint, ()),
            abi.encodeCall(TestStaking.setPointsPerSecond, (0))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            token.setCallback(address(staking), payloads[i], false);
            _deposit();
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(staking.totalStaked(), 10 ether);
            skip(1);
            vm.prank(alice);
            staking.withdraw(10 ether);
            assertFalse(token.callbackSucceeded());
            assertEq(
                token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector)
            );
            assertEq(staking.totalStaked(), 0);
            assertEq(token.balanceOf(alice), 100 ether);
            assertEq(staking.pendingPoints(alice), (i + 1) * 1 ether);
            assertEq(staking.pointsPerSecond(), 1 ether);
        }
        assertEq(token.callbackCount(), 8);
        assertEq(staking.stakes(address(token)), 0);
    }

    function test_bubbledReentrancyFailureRollsBackWholeDeposit() public {
        token.setCallback(address(staking), abi.encodeCall(TestStaking.checkpoint, ()), true);
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        staking.stake(10 ether);
        _assertEmpty();
        assertEq(token.callbackCount(), 0);
    }
}
