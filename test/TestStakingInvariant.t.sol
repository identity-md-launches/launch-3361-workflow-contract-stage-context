// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TestStaking} from "../src/TestStaking.sol";

/// @dev Independent interval-by-interval model: no production accumulator or remainder formulas.
contract StakingHandler is Test {
    uint256 public constant MODEL_PRECISION = 1e45;
    uint256 public constant ALLOCATION = 200_000_000 ether;
    LaunchToken public immutable token;
    TestStaking public immutable staking;
    address[4] public actors;
    // Each actor's TEST in their wallet and in custody combined.
    uint256[4] public modelHoldings;
    uint256[4] public modelStake;
    uint256[4] public modelPointsLower;
    uint256[4] public modelPointsUpper;
    uint256 public modelTotal;
    uint256 public modelRate = 1 ether;
    uint256 public modelEmitted;
    uint256 public donations;
    uint256 public distributionChanges;
    uint256 public discardedScaledPoints;
    uint256 private emissionAtStakeChange;

    constructor(LaunchToken token_) {
        token = token_;
        staking = new TestStaking(address(token_), address(this));
        for (uint256 i; i < 4; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            modelHoldings[i] = ALLOCATION;
        }
    }

    function stake(uint256 actorSeed, uint256 rawAmount) external {
        uint256 i = actorSeed % 4;
        address actor = actors[i];
        uint256 available = modelHoldings[i] - modelStake[i];
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.startPrank(actor);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
        _closeStakeInterval();
        modelStake[i] += amount;
        modelTotal += amount;
    }

    function withdraw(uint256 actorSeed, uint256 rawAmount) external {
        uint256 i = actorSeed % 4;
        uint256 available = modelStake[i];
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        vm.prank(actors[i]);
        staking.withdraw(amount);
        _closeStakeInterval();
        modelStake[i] -= amount;
        modelTotal -= amount;
    }

    function advance(uint256 rawElapsed) external {
        uint256 elapsed = bound(rawElapsed, 0, 1 days);
        uint256 emitted = elapsed * modelRate;
        if (modelTotal != 0) {
            modelEmitted += emitted;
            for (uint256 i; i < 4; ++i) {
                modelPointsLower[i] += Math.mulDiv(emitted * MODEL_PRECISION, modelStake[i], modelTotal);
                modelPointsUpper[
                    i
                ] += Math.mulDiv(emitted * MODEL_PRECISION, modelStake[i], modelTotal, Math.Rounding.Ceil);
            }
        }
        skip(elapsed);
    }

    function setRate(uint256 rawRate) external {
        uint256 rate = bound(rawRate, 0, staking.MAX_POINTS_PER_SECOND());
        staking.setPointsPerSecond(rate);
        modelRate = rate;
    }

    function checkpoint(uint256 actorSeed) external {
        // Include the unstaked handler as a caller to exercise unsolicited global updates.
        address caller = actorSeed % 5 == 4 ? address(this) : actors[actorSeed % 4];
        vm.prank(caller);
        staking.checkpoint();
    }

    function donate(uint256 rawAmount) external {
        uint256 available = token.balanceOf(address(this));
        if (available == 0) return;
        uint256 amount = bound(rawAmount, 1, available);
        token.transfer(address(staking), amount);
        donations += amount;
    }

    function transfer(uint256 senderSeed, uint256 recipientSeed, uint256 rawAmount) external {
        uint256 from = senderSeed % 4;
        uint256 to = recipientSeed % 4;
        uint256 amount = bound(rawAmount, 0, modelHoldings[from] - modelStake[from]);
        vm.prank(actors[from]);
        assertTrue(token.transfer(actors[to], amount));
        modelHoldings[from] -= amount;
        modelHoldings[to] += amount;
    }

    function exitAll() external {
        for (uint256 i; i < 4; ++i) {
            if (modelStake[i] == 0) continue;
            vm.prank(actors[i]);
            staking.withdraw(modelStake[i]);
            _closeStakeInterval();
            modelTotal -= modelStake[i];
            modelStake[i] = 0;
        }
    }

    function _closeStakeInterval() private {
        // Divide once per distribution, regardless of how often the contract checkpointed or changed rate.
        if (modelTotal != 0) {
            uint256 intervalEmission = modelEmitted - emissionAtStakeChange;
            discardedScaledPoints += mulmod(intervalEmission, staking.ACC_PRECISION(), modelTotal);
        }
        emissionAtStakeChange = modelEmitted;
        ++distributionChanges;
    }
}

contract TestStakingInvariantTest is StdInvariant, Test {
    LaunchToken internal token;
    TestStaking internal staking;
    StakingHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        handler = new StakingHandler(token);
        staking = handler.staking();
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), handler.ALLOCATION());
        }
        token.transfer(address(handler), handler.ALLOCATION());
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = StakingHandler.stake.selector;
        selectors[1] = StakingHandler.withdraw.selector;
        selectors[2] = StakingHandler.advance.selector;
        selectors[3] = StakingHandler.setRate.selector;
        selectors[4] = StakingHandler.checkpoint.selector;
        selectors[5] = StakingHandler.donate.selector;
        selectors[6] = StakingHandler.transfer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_principalIsFullyBackedAndConserved() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 staked = staking.stakes(actor);
            assertEq(staked, handler.modelStake(i));
            assertEq(token.balanceOf(actor) + staked, handler.modelHoldings(i));
            sum += staked;
        }
        assertEq(sum, staking.totalStaked());
        assertEq(sum, handler.modelTotal());
        assertEq(token.balanceOf(address(staking)), sum + handler.donations());
        assertEq(token.balanceOf(address(handler)) + handler.donations(), handler.ALLOCATION());
        assertEq(token.totalSupply(), 1e27);
    }

    function invariant_pointsMatchIndependentIntervalModelAndConserveEmission() public view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 points = staking.pendingPoints(actor);
            uint256 lower = handler.modelPointsLower(i) / handler.MODEL_PRECISION();
            uint256 upper = handler.modelPointsUpper(i) / handler.MODEL_PRECISION();
            assertLe(points, upper, "points exceed ideal interval allocation");
            if (lower > points) assertLe(lower - points, 1, "rounding exceeds one point minor unit");
            assertGe(points, staking.earnedPoints(actor));
            assertLt(staking.userPointRemainder(actor), staking.ACC_PRECISION());
            sum += points;
        }
        assertEq(staking.currentTotalPointsEmitted(), handler.modelEmitted());
        assertLe(sum, handler.modelEmitted(), "over-emission");
        // Four displayed fractions plus < 1 minor unit of discarded global dust.
        assertLe(handler.modelEmitted() - sum, 4, "points lost beyond precision bound");
        assertEq(staking.pendingPoints(address(handler)), 0);
    }

    function invariant_configurationAndRemainderBounds() public view {
        assertEq(address(staking.token()), address(token));
        assertEq(staking.owner(), address(handler));
        assertEq(staking.pointsPerSecond(), handler.modelRate());
        assertLe(staking.pointsPerSecond(), staking.MAX_POINTS_PER_SECOND());
        assertLe(staking.totalStaked(), staking.MAX_TOTAL_STAKED());
        if (staking.totalStaked() == 0) assertEq(staking.globalRemainder(), 0);
        else assertLt(staking.globalRemainder(), staking.totalStaked());
    }

    function invariant_everyFractionOfCheckpointedEmissionIsAccountedFor() public view {
        uint256 precision = staking.ACC_PRECISION();
        uint256 index = staking.accPointsPerToken();
        uint256 allocated;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            allocated += staking.earnedPoints(actor) * precision + staking.userPointRemainder(actor);
            // Accrual at the saved global index that the account has yet to checkpoint.
            allocated += handler.modelStake(i) * (index - staking.userPointsPerTokenPaid(actor));
        }
        assertEq(
            allocated + staking.globalRemainder() + handler.discardedScaledPoints(),
            staking.totalPointsEmitted() * precision,
            "fractional points missing or counted twice"
        );
    }

    function afterInvariant() public {
        handler.exitAll();
        invariant_principalIsFullyBackedAndConserved();
        invariant_pointsMatchIndependentIntervalModelAndConserveEmission();
        invariant_everyFractionOfCheckpointedEmissionIsAccountedFor();
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(address(staking)), handler.donations());
    }
}
