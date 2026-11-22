// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Time locks with no admin and no early exit. A lock can be extended, never shortened.
contract LockVault is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Lock {
        address owner;
        address token;
        uint256 amount;
        uint64 unlockAt;
    }
    Lock[] public locks;

    event Locked(uint256 indexed id, address indexed owner, address indexed token, uint256 amount, uint64 unlockAt);
    event Extended(uint256 indexed id, uint64 unlockAt);
    event Unlocked(uint256 indexed id, address indexed owner, uint256 amount);

    function lockCount() external view returns (uint256) { return locks.length; }

    function lock(address token, uint256 amount, uint64 unlockAt) external nonReentrant returns (uint256 id) {
        require(amount > 0 && unlockAt > block.timestamp, "lock");
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        id = locks.length;
        locks.push(Lock(msg.sender, token, received, unlockAt));
        emit Locked(id, msg.sender, token, received, unlockAt);
    }

    function extend(uint256 id, uint64 unlockAt) external {
        Lock storage l = locks[id];
        require(msg.sender == l.owner && unlockAt > l.unlockAt, "extend");
        l.unlockAt = unlockAt;
        emit Extended(id, unlockAt);
    }

    function unlock(uint256 id) external nonReentrant {
        Lock storage l = locks[id];
        require(msg.sender == l.owner && block.timestamp >= l.unlockAt && l.amount > 0, "unlock");
        uint256 amount = l.amount;
        l.amount = 0;
        IERC20(l.token).safeTransfer(l.owner, amount);
        emit Unlocked(id, l.owner, amount);
    }
}
