// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TestStaking
/// @notice Custodies TEST principal and records nontransferable, nonredeemable points.
/// @dev All point amounts use 18 decimals. Stake amounts use TEST's 18 decimals.
///      Only LaunchToken is supported. No initializer, mint, rescue, pause, or upgrade path exists.
contract TestStaking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 public constant POINTS_DECIMALS = 18;
    uint256 public constant DEFAULT_POINTS_PER_SECOND = 1 ether;
    uint256 public constant MAX_POINTS_PER_SECOND = 1_000_000 ether;
    uint256 public constant MAX_TOTAL_STAKED = 1_000_000_000 ether;
    uint256 public constant ACC_PRECISION = 1e36;

    IERC20 public immutable token;
    uint256 public totalStaked;
    uint256 public pointsPerSecond;
    uint256 public lastUpdateTime;
    uint256 public accPointsPerToken;
    /// @notice Emitted point minor units through lastUpdateTime, excluding empty intervals.
    uint256 public totalPointsEmitted;
    /// @notice Division remainder carried while the stake distribution is unchanged.
    uint256 public globalRemainder;

    mapping(address account => uint256 amount) public stakes;
    /// @notice Checkpointed lifetime point minor units; use pendingPoints for a current total.
    mapping(address account => uint256 amount) public earnedPoints;
    mapping(address account => uint256 accumulator) public userPointsPerTokenPaid;
    /// @notice Fraction of a point minor unit, with denominator ACC_PRECISION.
    mapping(address account => uint256 fraction) public userPointRemainder;

    error InvalidToken();
    error TokenHasNoCode();
    error ZeroAmount();
    error StakeLimitExceeded();
    error InsufficientStake(uint256 available, uint256 requested);
    error UnexpectedTokenBalance();
    error RateTooHigh(uint256 requested, uint256 maximum);

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event PointsCheckpointed(address indexed account, uint256 earnedPoints);
    event PointsRateUpdated(uint256 previousRate, uint256 newRate);

    /// @param token_ The launch's $token. Stored without any external constructor calls.
    /// @param owner_ The launch's $owner, never implicitly the deploying factory.
    constructor(address token_, address owner_) Ownable(owner_) {
        if (token_ == address(0) || token_ == address(this)) revert InvalidToken();
        token = IERC20(token_);
        pointsPerSecond = DEFAULT_POINTS_PER_SECOND;
        lastUpdateTime = block.timestamp;
        emit PointsRateUpdated(0, DEFAULT_POINTS_PER_SECOND);
    }

    /// @notice Stake your own TEST after approving this contract for amount.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > MAX_TOTAL_STAKED - totalStaked) revert StakeLimitExceeded();
        if (address(token).code.length == 0) revert TokenHasNoCode();

        _checkpoint(msg.sender);
        uint256 balanceBefore = token.balanceOf(address(this));
        stakes[msg.sender] += amount;
        totalStaked += amount;
        // This dust belongs to the old distribution; never give it to a new entrant.
        globalRemainder = 0;

        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) != balanceBefore + amount) revert UnexpectedTokenBalance();
        emit Staked(msg.sender, amount);
    }

    /// @notice Withdraw your principal to yourself; lifetime points and their fractions remain.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 balance = stakes[msg.sender];
        if (amount > balance) revert InsufficientStake(balance, amount);

        _checkpoint(msg.sender);
        stakes[msg.sender] = balance - amount;
        totalStaked -= amount;
        globalRemainder = 0;

        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Save your accrued points. Optional: stake and withdraw checkpoint automatically.
    /// @return points Your cumulative earned point minor units; nothing is paid or reset.
    function checkpoint() external nonReentrant returns (uint256 points) {
        _checkpoint(msg.sender);
        return earnedPoints[msg.sender];
    }

    /// @notice Set future global emission in point minor units/second, including zero.
    /// @dev Accrual up to this timestamp uses the previous rate and stake distribution.
    function setPointsPerSecond(uint256 newRate) external nonReentrant onlyOwner {
        if (newRate > MAX_POINTS_PER_SECOND) revert RateTooHigh(newRate, MAX_POINTS_PER_SECOND);
        _updateGlobal();
        uint256 previousRate = pointsPerSecond;
        pointsPerSecond = newRate;
        emit PointsRateUpdated(previousRate, newRate);
    }

    /// @notice Current cumulative points, INCLUDING already checkpointed points (18 decimals).
    function pendingPoints(address account) external view returns (uint256) {
        (uint256 accumulator,,) = _previewGlobal();
        (uint256 whole,) = _userAccrual(account, accumulator);
        return earnedPoints[account] + whole;
    }

    /// @notice Global accumulator including accrual since lastUpdateTime.
    function currentPointsPerToken() external view returns (uint256) {
        (uint256 accumulator,,) = _previewGlobal();
        return accumulator;
    }

    /// @notice Total emitted point minor units, including the current nonempty interval.
    function currentTotalPointsEmitted() external view returns (uint256) {
        (,, uint256 emitted) = _previewGlobal();
        return totalPointsEmitted + emitted;
    }

    function _checkpoint(address account) private {
        _updateGlobal();
        (uint256 whole, uint256 fraction) = _userAccrual(account, accPointsPerToken);
        earnedPoints[account] += whole;
        userPointRemainder[account] = fraction;
        userPointsPerTokenPaid[account] = accPointsPerToken;
        emit PointsCheckpointed(account, earnedPoints[account]);
    }

    function _userAccrual(address account, uint256 accumulator) private view returns (uint256 whole, uint256 fraction) {
        uint256 delta = accumulator - userPointsPerTokenPaid[account];
        uint256 balance = stakes[account];
        whole = Math.mulDiv(balance, delta, ACC_PRECISION);
        fraction = mulmod(balance, delta, ACC_PRECISION) + userPointRemainder[account];
        whole += fraction / ACC_PRECISION;
        fraction %= ACC_PRECISION;
    }

    function _updateGlobal() private {
        uint256 emitted;
        (accPointsPerToken, globalRemainder, emitted) = _previewGlobal();
        totalPointsEmitted += emitted;
        // Advancing even when empty ensures the next depositor gets no historical emission.
        lastUpdateTime = block.timestamp;
    }

    function _previewGlobal() private view returns (uint256 accumulator, uint256 remainder, uint256 emitted) {
        accumulator = accPointsPerToken;
        uint256 supply = totalStaked;
        if (supply == 0) return (accumulator, 0, 0);

        emitted = (block.timestamp - lastUpdateTime) * pointsPerSecond;
        uint256 increment = Math.mulDiv(emitted, ACC_PRECISION, supply);
        remainder = mulmod(emitted, ACC_PRECISION, supply) + globalRemainder;
        accumulator += increment + remainder / supply;
        remainder %= supply;
    }
}
