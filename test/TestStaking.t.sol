// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TestStaking} from "../src/TestStaking.sol";

contract TestStakingTest is Test {
    LaunchToken internal token;
    TestStaking internal staking;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    uint256 internal constant ALLOCATION = 200_000_000 ether;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        staking = new TestStaking(address(token), owner);
        token.transfer(alice, ALLOCATION);
        token.transfer(bob, ALLOCATION);
        token.transfer(carol, ALLOCATION);
    }

    function _stake(address account, uint256 amount) internal {
        vm.startPrank(account);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function _withdraw(address account, uint256 amount) internal {
        vm.prank(account);
        staking.withdraw(amount);
    }

    function _rate(uint256 value) internal {
        vm.prank(owner);
        staking.setPointsPerSecond(value);
    }

    function test_constructorDefaults() public view {
        assertEq(address(staking.token()), address(token));
        assertEq(staking.owner(), owner);
        assertEq(staking.pointsPerSecond(), 1 ether);
        assertEq(staking.lastUpdateTime(), 1_000_000);
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.POINTS_DECIMALS(), 18);
        assertEq(staking.pendingPoints(alice), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(TestStaking.InvalidToken.selector);
        new TestStaking(address(0), owner);
    }

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new TestStaking(address(token), address(0));
    }

    function test_constructorNeedsNoExternalCodeButFirstStakeDoes() public {
        TestStaking deferred = new TestStaking(makeAddr("future token"), owner);
        assertEq(deferred.owner(), owner);
        vm.expectRevert(TestStaking.TokenHasNoCode.selector);
        deferred.stake(1);
        assertEq(deferred.totalStaked(), 0);
    }

    function test_stakeAndWithdrawEventsAndPrincipal() public {
        vm.startPrank(alice);
        token.approve(address(staking), 10 ether);
        vm.expectEmit(true, false, false, true, address(staking));
        emit TestStaking.Staked(alice, 10 ether);
        staking.stake(10 ether);
        assertEq(staking.stakes(alice), 10 ether);
        assertEq(staking.totalStaked(), 10 ether);
        assertEq(token.balanceOf(address(staking)), 10 ether);
        vm.expectEmit(true, false, false, true, address(staking));
        emit TestStaking.Withdrawn(alice, 4 ether);
        staking.withdraw(4 ether);
        assertEq(staking.stakes(alice), 6 ether);
        assertEq(token.balanceOf(alice), ALLOCATION - 6 ether);
        vm.stopPrank();
    }

    function test_singleStakerGetsGlobalRate() public {
        _stake(alice, 100 ether);
        skip(123);
        assertEq(staking.pendingPoints(alice), 123 ether);
        assertEq(staking.earnedPoints(alice), 0);
        vm.prank(alice);
        assertEq(staking.checkpoint(), 123 ether);
        assertEq(staking.earnedPoints(alice), 123 ether);
        assertEq(staking.pendingPoints(alice), 123 ether);
        assertEq(staking.totalPointsEmitted(), 123 ether);
    }

    function test_staggeredEntryAndChangingShares() public {
        _stake(alice, 100 ether);
        skip(10);
        _stake(bob, 300 ether);
        assertEq(staking.pendingPoints(bob), 0);
        assertEq(staking.pendingPoints(alice), 10 ether);
        skip(10);
        assertEq(staking.pendingPoints(alice), 12.5 ether);
        assertEq(staking.pendingPoints(bob), 7.5 ether);
        _stake(alice, 300 ether);
        skip(7);
        assertEq(staking.pendingPoints(alice), 16.5 ether);
        assertEq(staking.pendingPoints(bob), 10.5 ether);
        assertEq(staking.currentTotalPointsEmitted(), 27 ether);
    }

    function test_partialThenFullExitPreservesPointsAndFractions() public {
        _stake(alice, 100 ether);
        _stake(bob, 100 ether);
        skip(10);
        _withdraw(alice, 50 ether);
        assertEq(staking.earnedPoints(alice), 5 ether);
        skip(9);
        _withdraw(alice, 50 ether);
        assertEq(staking.earnedPoints(alice), 8 ether);
        assertEq(staking.stakes(alice), 0);
        assertEq(token.balanceOf(alice), ALLOCATION);
        skip(7);
        assertEq(staking.pendingPoints(alice), 8 ether);
        assertEq(staking.pendingPoints(bob), 18 ether);
        _withdraw(bob, 100 ether);
        assertEq(token.balanceOf(address(staking)), 0);
        assertEq(staking.totalStaked(), 0);
    }

    function test_emptyIntervalsNeverAccrueOrGoToNextEntrant() public {
        skip(1_000);
        staking.checkpoint();
        assertEq(staking.currentTotalPointsEmitted(), 0);
        _stake(alice, 1 ether);
        skip(10);
        _withdraw(alice, 1 ether);
        skip(10_000);
        _rate(2 ether);
        skip(100);
        _stake(bob, 2 ether);
        assertEq(staking.pendingPoints(bob), 0);
        skip(3);
        assertEq(staking.pendingPoints(alice), 10 ether);
        assertEq(staking.pendingPoints(bob), 6 ether);
        assertEq(staking.currentTotalPointsEmitted(), 16 ether);
    }

    function test_rateChangeCheckpointsOldRateAndCanStopAndResume() public {
        _stake(alice, 10 ether);
        skip(10);
        vm.expectEmit(false, false, false, true, address(staking));
        emit TestStaking.PointsRateUpdated(1 ether, 3 ether);
        _rate(3 ether);
        skip(5);
        assertEq(staking.pendingPoints(alice), 25 ether);
        _rate(0);
        skip(100);
        assertEq(staking.pendingPoints(alice), 25 ether);
        _withdraw(alice, 5 ether);
        _rate(2 ether);
        skip(2);
        assertEq(staking.pendingPoints(alice), 29 ether);
        _withdraw(alice, 5 ether);
        assertEq(token.balanceOf(alice), ALLOCATION);
    }

    function test_onlyOwnerCanChangeRate() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setPointsPerSecond(3 ether);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        staking.setPointsPerSecond(3 ether);
        assertEq(staking.pointsPerSecond(), 1 ether);
    }

    function test_rateBoundAndRejectedChangeIsAtomic() public {
        uint256 maximum = staking.MAX_POINTS_PER_SECOND();
        _stake(alice, 1);
        skip(1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(TestStaking.RateTooHigh.selector, maximum + 1, maximum));
        staking.setPointsPerSecond(maximum + 1);
        assertEq(staking.lastUpdateTime(), 1_000_000);
        assertEq(staking.pendingPoints(alice), 1 ether);
        _rate(maximum);
        skip(100 * 365 days);
        assertEq(staking.pendingPoints(alice), 1 ether + 100 * 365 days * maximum);
        _withdraw(alice, 1);
    }

    function test_twoStepOwnershipAndCancellation() public {
        vm.prank(owner);
        staking.transferOwnership(bob);
        assertEq(staking.owner(), owner);
        assertEq(staking.pendingOwner(), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.acceptOwnership();
        vm.prank(owner);
        staking.transferOwnership(address(0));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        staking.acceptOwnership();
        vm.prank(owner);
        staking.transferOwnership(bob);
        vm.prank(bob);
        staking.acceptOwnership();
        assertEq(staking.owner(), bob);
        assertEq(staking.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        staking.setPointsPerSecond(0);
        vm.prank(bob);
        staking.setPointsPerSecond(2 ether);
        assertEq(staking.pointsPerSecond(), 2 ether);
    }

    function test_renouncingFixesRateButCannotBlockWithdrawals() public {
        _stake(alice, 1 ether);
        vm.prank(owner);
        staking.renounceOwnership();
        skip(10);
        _withdraw(alice, 1 ether);
        assertEq(staking.owner(), address(0));
        assertEq(staking.pendingPoints(alice), 10 ether);
        assertEq(token.balanceOf(alice), ALLOCATION);
    }

    function test_zeroAmountsAndOversizedActionsRevert() public {
        vm.expectRevert(TestStaking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(TestStaking.ZeroAmount.selector);
        staking.withdraw(0);
        vm.expectRevert(TestStaking.StakeLimitExceeded.selector);
        staking.stake(type(uint256).max);
        _stake(alice, 3);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestStaking.InsufficientStake.selector, 3, 4));
        staking.withdraw(4);
    }

    function test_cannotWithdrawAnotherUsersPrincipalOrWithdrawTwice() public {
        _stake(alice, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TestStaking.InsufficientStake.selector, 0, 1 ether));
        staking.withdraw(1 ether);
        _withdraw(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestStaking.InsufficientStake.selector, 0, 1 ether));
        staking.withdraw(1 ether);
    }

    function test_failedDepositRollsBackCheckpointAndBalances() public {
        _stake(alice, 1 ether);
        skip(10);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(staking), 0, 2 ether)
        );
        staking.stake(2 ether);
        assertEq(staking.earnedPoints(alice), 0);
        assertEq(staking.lastUpdateTime(), 1_000_000);
        assertEq(staking.stakes(alice), 1 ether);
        assertEq(staking.pendingPoints(alice), 10 ether);
        assertEq(token.balanceOf(address(staking)), 1 ether);
    }

    function test_insufficientTokenBalanceRollsBack() public {
        address empty = makeAddr("empty");
        vm.startPrank(empty);
        token.approve(address(staking), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, empty, 0, 1));
        staking.stake(1);
        vm.stopPrank();
        assertEq(staking.totalStaked(), 0);
    }

    function test_directDonationsDoNotCreateStakeOrDilutePoints() public {
        _stake(alice, 1 ether);
        skip(10);
        token.transfer(address(staking), 100 ether);
        skip(10);
        assertEq(staking.pendingPoints(alice), 20 ether);
        assertEq(staking.totalStaked(), 1 ether);
        assertEq(staking.stakes(address(this)), 0);
        _withdraw(alice, 1 ether);
        assertEq(token.balanceOf(address(staking)), 100 ether);
        assertEq(staking.totalStaked(), 0);
    }

    function test_frequentCheckpointsCarryGlobalAndUserFractions() public {
        _rate(1);
        _stake(alice, 1);
        _stake(bob, 2);
        _stake(carol, 3);
        for (uint256 i; i < 6; ++i) {
            skip(1);
            vm.prank(alice);
            staking.checkpoint();
            vm.prank(bob);
            staking.checkpoint();
            vm.prank(carol);
            staking.checkpoint();
            staking.checkpoint(); // A nonstaker also cannot destroy rounding fractions.
        }
        assertEq(staking.pendingPoints(alice), 1);
        assertEq(staking.pendingPoints(bob), 2);
        assertEq(staking.pendingPoints(carol), 3);
        assertEq(staking.globalRemainder(), 0);
        assertEq(staking.userPointRemainder(alice), 0);
        assertEq(staking.totalPointsEmitted(), 6);
    }

    function test_fractionSurvivesFullExitAndRestaking() public {
        _rate(1);
        _stake(alice, 1);
        _stake(bob, 1);
        skip(1);
        _withdraw(alice, 1);
        assertEq(staking.earnedPoints(alice), 0);
        assertEq(staking.userPointRemainder(alice), 5e35);
        skip(10);
        _stake(alice, 1);
        skip(1);
        vm.prank(alice);
        staking.checkpoint();
        assertEq(staking.earnedPoints(alice), 1);
        assertEq(staking.userPointRemainder(alice), 0);
        assertEq(staking.pendingPoints(bob), 11);
    }

    function test_oldGlobalDustIsDiscardedOnDistributionChange() public {
        _rate(1);
        _stake(alice, 3);
        skip(1);
        staking.checkpoint();
        assertEq(staking.globalRemainder(), 1);
        _stake(bob, 1);
        assertEq(staking.globalRemainder(), 0);
        assertEq(staking.pendingPoints(bob), 0);
        skip(4);
        assertEq(staking.pendingPoints(alice), 3); // The saved fraction is just below 4; display rounds down.
        assertEq(staking.pendingPoints(bob), 1);
        assertEq(staking.currentTotalPointsEmitted(), 5);
    }

    function test_sameTimestampActionsEarnNothing() public {
        _stake(alice, 1 ether);
        _stake(bob, 3 ether);
        _withdraw(alice, 1 ether);
        _rate(123);
        _withdraw(bob, 3 ether);
        assertEq(staking.pendingPoints(alice), 0);
        assertEq(staking.pendingPoints(bob), 0);
        assertEq(staking.totalPointsEmitted(), 0);
    }

    function test_fullSupplyCanBeStaked() public {
        LaunchToken full = new LaunchToken();
        TestStaking vault = new TestStaking(address(full), owner);
        full.approve(address(vault), 1e27);
        vault.stake(1e27);
        skip(1);
        assertEq(vault.pendingPoints(address(this)), 1 ether);
        vault.withdraw(1e27);
        assertEq(full.balanceOf(address(this)), 1e27);
    }

    function test_nativeEthIsNotAccepted() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success,) = address(staking).call{value: 1 ether}("");
        assertFalse(success);
    }

    function testFuzz_constantSharesMatchFormula(uint256 a, uint256 b, uint256 elapsed, uint256 rate) public {
        a = bound(a, 1, ALLOCATION);
        b = bound(b, 1, ALLOCATION);
        elapsed = bound(elapsed, 0, 3650 days);
        rate = bound(rate, 0, staking.MAX_POINTS_PER_SECOND());
        _rate(rate);
        _stake(alice, a);
        _stake(bob, b);
        skip(elapsed);
        uint256 emission = rate * elapsed;
        uint256 expectedAlice = Math.mulDiv(emission, a, a + b);
        uint256 expectedBob = Math.mulDiv(emission, b, a + b);
        uint256 actualAlice = staking.pendingPoints(alice);
        uint256 actualBob = staking.pendingPoints(bob);
        assertLe(actualAlice, expectedAlice);
        assertLe(actualBob, expectedBob);
        assertLe(expectedAlice - actualAlice, 1);
        assertLe(expectedBob - actualBob, 1);
        assertLe(actualAlice + actualBob, emission);
        assertLe(emission - actualAlice - actualBob, 2);
    }

    function testFuzz_partialExitConservesPrincipal(uint256 deposit, uint256 exit, uint256 elapsed) public {
        deposit = bound(deposit, 1, ALLOCATION);
        exit = bound(exit, 1, deposit);
        elapsed = bound(elapsed, 0, 3650 days);
        _stake(alice, deposit);
        skip(elapsed);
        _withdraw(alice, exit);
        assertEq(token.balanceOf(alice) + staking.stakes(alice), ALLOCATION);
        assertEq(token.balanceOf(address(staking)), deposit - exit);
        uint256 points = staking.pendingPoints(alice);
        if (deposit != exit) _withdraw(alice, deposit - exit);
        assertEq(staking.pendingPoints(alice), points);
        assertEq(token.balanceOf(alice), ALLOCATION);
        assertEq(token.balanceOf(address(staking)), 0);
    }
}
