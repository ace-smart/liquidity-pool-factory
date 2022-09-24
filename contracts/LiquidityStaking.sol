//SPDX-License-Identifier: Unlicense
pragma solidity >=0.7.0;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract LiquidityStaking is Ownable, Pausable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    struct UserInfo {
        uint256 amount;
        uint256 shares;
        uint256 rewardDebt;
        uint256 pendingRewards;
        uint256 depositedAt;
        uint256 claimedAt;
    }

    struct LockedBalance {
        uint256 amount;
        uint256 unlockTime;
    }

    struct PoolInfo {
        uint256 allocPoint;
        uint256 lastRewardTime;
        uint256 accEulerPerShare;
        uint256 totalSupply;
        uint256 rewardsAmount;
        uint256 lockupDuration;
    }

    IERC20 public immutable lpToken;
    IERC20 public immutable rewardToken;

    PoolInfo[] public poolInfo;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(uint256 => mapping(address => LockedBalance[])) public userLocks;
    uint256 public totalAllocPoint;

    uint256 public rewardRate;

    event Deposit(uint pid, address indexed user, uint256 amount);
    event Withdraw(uint pid, address indexed user, uint256 amount);
    event Claim(uint pid, address indexed user, uint256 amount);

    modifier updateReward(uint pid) {
        PoolInfo storage pool = poolInfo[pid];
        UserInfo storage user = userInfo[pid][msg.sender];

        if (pool.lastRewardTime <= block.timestamp && rewardRate > 0) {
            if (pool.totalSupply > 0) {
                uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
                uint256 rewards = multiplier.mul(rewardRate).mul(pool.allocPoint).div(totalAllocPoint);
                pool.rewardsAmount = pool.rewardsAmount.add(rewards);
                pool.accEulerPerShare = pool.accEulerPerShare.add(rewards.mul(1e12).div(pool.totalSupply));
            }
            pool.lastRewardTime = block.timestamp;
            
            uint256 pending = user.amount.mul(pool.accEulerPerShare).div(1e12).sub(user.rewardDebt);
            user.pendingRewards = user.pendingRewards.add(pending);
        }

        _;
        
        if (pool.lastRewardTime <= block.timestamp) {
            user.rewardDebt = user.amount.mul(pool.accEulerPerShare).div(1e12);
            if (user.claimedAt == 0) user.claimedAt = block.timestamp;
        }
    }

    constructor(address _lp, address _reward, uint _startTime) {
        lpToken = IERC20(_lp);
        rewardToken = IERC20(_reward);

        addPool(2, 30 days, _startTime);
        addPool(3, 60 days, _startTime);
        addPool(5, 90 days, _startTime);
    }

    function addPool(uint256 _allocPoint, uint256 _lockupDuration, uint256 _startTime) public onlyOwner {
        poolInfo.push(
            PoolInfo({
                allocPoint: _allocPoint,
                lastRewardTime: block.timestamp.add(_startTime.mul(1 minutes)),
                accEulerPerShare: 0,
                totalSupply: 0,
                rewardsAmount: 0,
                lockupDuration: _lockupDuration
            })
        );

        totalAllocPoint += _allocPoint;
    }

    function setPool(uint _pid, uint _allocPoint, uint _lockupDuration) external onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        totalAllocPoint = totalAllocPoint - pool.allocPoint + _allocPoint;
        pool.lockupDuration = _lockupDuration;
    }

    function setStartTime(uint _pid, uint _startTime, bool _updateAcc) external onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];

        if (pool.totalSupply > 0 && _updateAcc && rewardRate > 0) {
            uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
            uint256 rewards = multiplier.mul(rewardRate).mul(pool.allocPoint).div(totalAllocPoint);
            pool.rewardsAmount = pool.rewardsAmount.add(rewards);
            pool.accEulerPerShare = pool.accEulerPerShare.add(rewards.mul(1e12).div(pool.totalSupply));
        }
        pool.lastRewardTime = block.timestamp.add(_startTime.mul(1 minutes));
    }

    function deposit(uint256 _pid, uint256 _amount) external whenNotPaused nonReentrant updateReward(_pid) {
        require(_amount > 0, "!amount");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint before = lpToken.balanceOf(address(this));
        lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        _amount = lpToken.balanceOf(address(this)).sub(before);

        pool.totalSupply += _amount;
        user.amount += _amount;
        uint256 unlockTime = block.timestamp.add(pool.lockupDuration);
        userLocks[_pid][msg.sender].push(LockedBalance({amount: _amount, unlockTime: unlockTime}));

        emit Deposit(_pid, msg.sender, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant updateReward(_pid) {
        require(_amount > 0, "!amount");
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 remaining = _amount;
        require(user.amount >= _amount, "No balance");

        for (uint i = 0; ; i++) {
            uint256 lockedAmount = userLocks[_pid][msg.sender][i].amount;
            if (lockedAmount == 0) continue;
            require(userLocks[_pid][msg.sender][i].unlockTime > block.timestamp, "No unlocked balance");
            if (remaining <= lockedAmount) {
                userLocks[_pid][msg.sender][i].amount = lockedAmount.sub(remaining);
                break;
            } else {
                delete userLocks[_pid][msg.sender][i];
                remaining = remaining.sub(lockedAmount);
            }
        }

        user.amount -= _amount;
        pool.totalSupply -= _amount;
        lpToken.safeTransfer(msg.sender, _amount);

        emit Withdraw(_pid, msg.sender, _amount);
    }

    function withdrawExpiredLocks(uint256 _pid) external nonReentrant updateReward(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        LockedBalance[] storage locks = userLocks[_pid][msg.sender];

        uint256 amount;
        uint256 length = locks.length;
        if (locks[length-1].unlockTime <= block.timestamp) {
            amount = user.amount;
            delete userLocks[_pid][msg.sender];
        } else {
            for (uint i = 0; i < length; i++) {
                if (locks[i].unlockTime > block.timestamp) break;
                amount = amount.add(locks[i].amount);
                delete locks[i];
            }
        }
        user.amount -= amount;
        pool.totalSupply -= amount;
        lpToken.safeTransfer(msg.sender, amount);

        emit Withdraw(_pid, msg.sender, amount);
    }

    function unlockedBalance(uint256 _pid, address _user) view external returns (uint256 amount) {
        LockedBalance[] storage locks = userLocks[_pid][_user];
        for (uint i = 0; i < locks.length; i++) {
            if (locks[i].unlockTime > block.timestamp) {
                break;
            }
            amount = amount.add(locks[i].amount);
        }
        return amount;
    }

    function claim(uint256 _pid) public nonReentrant updateReward(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 claimedAmount = safeTransferRewards(msg.sender, user.pendingRewards);
        user.pendingRewards = user.pendingRewards.sub(claimedAmount);
        user.claimedAt = block.timestamp;
        pool.rewardsAmount -= claimedAmount;

        emit Claim(_pid, msg.sender, claimedAmount);
    }

    function claimable(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        if (user.amount == 0) return 0;
        
        uint256 curAccPerShare = pool.accEulerPerShare;
        if (pool.totalSupply > 0) {
            uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
            uint256 reward = multiplier.mul(rewardRate).mul(pool.allocPoint).div(totalAllocPoint);
            curAccPerShare = pool.accEulerPerShare.add(reward.mul(1e12).div(pool.totalSupply));
        }
        
        return user.amount.mul(curAccPerShare).div(1e12).sub(user.rewardDebt).add(user.pendingRewards);
    }

    function safeTransferRewards(address _user, uint _amount) internal returns (uint) {
        uint curBal = rewardToken.balanceOf(address(this));
        require (curBal > 0, "!rewards");

        if (_amount > curBal) _amount = curBal;
        rewardToken.safeTransfer(_user, _amount);

        return _amount;
    }

    function setRewardRate(uint256 _rewardRate) external onlyOwner {
        require (_rewardRate > 0, "Rewards per second should be greater than 0!");

        // Update pool infos with old reward rate before setting new one first
        if (rewardRate > 0) {
            for (uint i = 0; i < poolInfo.length; i++) {
                PoolInfo storage pool = poolInfo[i];
                if (pool.lastRewardTime >= block.timestamp) continue;

                if (pool.totalSupply > 0) {
                    uint256 multiplier = block.timestamp.sub(pool.lastRewardTime);
                    uint256 reward = multiplier.mul(rewardRate).mul(pool.allocPoint).div(totalAllocPoint);
                    pool.rewardsAmount += reward;
                    pool.accEulerPerShare += reward.mul(1e12).div(pool.totalSupply);
                }
                pool.lastRewardTime = block.timestamp;
            }
        }
        rewardRate = _rewardRate;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}