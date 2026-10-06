// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SitOnHands
/// @notice An ownerless, non-upgradeable vault for voluntary locks of the existing IMD token.
/// @dev Configure the canonical mainnet IMD address at deployment. No fees, yield, rescue, or early exit.
contract SitOnHands is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Inclusive duration bounds: 86,400 to 31,536,000 seconds (exactly 365 days maximum).
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 365 days;

    IERC20 public immutable imd;

    struct Position {
        address depositor;
        uint256 amount;
        uint256 unlockTime;
        bool withdrawn;
    }

    /// @notice IDs start at zero and are never reused. Withdrawn records remain readable.
    mapping(uint256 positionId => Position) public positions;
    uint256 public nextPositionId;
    /// @notice Outstanding principal, including matured positions not yet withdrawn.
    mapping(address depositor => uint256) public lockedBalance;
    uint256 public totalLocked;

    error InvalidToken();
    error ZeroAmount();
    error InvalidDuration();
    error UnknownPosition();
    error NotDepositor();
    error AlreadyWithdrawn();
    error StillLocked(uint256 unlockTime);
    error UnexpectedTokenBalance();

    event Locked(address indexed depositor, uint256 amount, uint256 unlockTime, uint256 indexed positionId);
    event Withdrawn(address indexed depositor, uint256 amount, uint256 unlockTime, uint256 indexed positionId);

    /// @param imd_ Canonical existing IMD ERC-20 address; deployment tooling must verify its identity.
    /// @dev No external calls in construction, allowing deterministic deployment through a factory.
    constructor(address imd_) {
        if (imd_ == address(0)) revert InvalidToken();
        imd = IERC20(imd_);
    }

    /// @notice Lock the caller's IMD for an inclusive 1–365 day duration, measured from this transaction.
    /// @param amount Principal in the token's smallest units. Approve this vault first.
    /// @return positionId The nontransferable position belonging only to msg.sender.
    function lock(uint256 amount, uint256 durationSeconds) external nonReentrant returns (uint256 positionId) {
        if (amount == 0) revert ZeroAmount();
        if (durationSeconds < MIN_DURATION || durationSeconds > MAX_DURATION) revert InvalidDuration();
        uint256 unlockTime = block.timestamp + durationSeconds;

        uint256 beforeBalance = imd.balanceOf(address(this));
        uint256 depositorBefore = imd.balanceOf(msg.sender);
        imd.safeTransferFrom(msg.sender, address(this), amount);
        if (
            depositorBefore < amount || imd.balanceOf(msg.sender) != depositorBefore - amount
                || imd.balanceOf(address(this)) != beforeBalance + amount
        ) revert UnexpectedTokenBalance();

        positionId = nextPositionId++;
        positions[positionId] = Position(msg.sender, amount, unlockTime, false);
        lockedBalance[msg.sender] += amount;
        totalLocked += amount;
        emit Locked(msg.sender, amount, unlockTime, positionId);
    }

    /// @notice Return exactly one matured position's principal to its original depositor.
    /// @dev Effects precede the transfer. Any token failure rolls back all accounting for a later retry.
    function withdraw(uint256 positionId) external nonReentrant {
        Position storage position = positions[positionId];
        if (position.depositor == address(0)) revert UnknownPosition();
        if (msg.sender != position.depositor) revert NotDepositor();
        if (position.withdrawn) revert AlreadyWithdrawn();
        if (block.timestamp < position.unlockTime) revert StillLocked(position.unlockTime);

        uint256 amount = position.amount;
        position.withdrawn = true;
        lockedBalance[msg.sender] -= amount;
        totalLocked -= amount;

        uint256 vaultBefore = imd.balanceOf(address(this));
        uint256 depositorBefore = imd.balanceOf(msg.sender);
        imd.safeTransfer(msg.sender, amount);
        if (
            vaultBefore < amount || imd.balanceOf(address(this)) != vaultBefore - amount
                || imd.balanceOf(msg.sender) != depositorBefore + amount
        ) revert UnexpectedTokenBalance();

        emit Withdrawn(msg.sender, amount, position.unlockTime, positionId);
    }

    /// @notice Whether the depositor may withdraw now, assuming IMD transfers are operational.
    function canWithdraw(uint256 positionId) external view returns (bool) {
        Position storage position = positions[positionId];
        return position.depositor != address(0) && !position.withdrawn && block.timestamp >= position.unlockTime;
    }
}
