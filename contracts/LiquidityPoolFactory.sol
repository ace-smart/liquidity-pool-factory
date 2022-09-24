//SPDX-License-Identifier: Unlicense
pragma solidity >=0.7.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IUniswapPair.sol";
import "./LiquidityStakingV2.sol";

interface ILiquidityStaking {
    function setRewardRate(uint) external;
    function expandEndTime(uint) external;
    function endTime() external returns (uint);
    function availableRewards() external returns (uint);
    function pause() external;
    function unpause() external;
}

// contract LiquidityPoolFactory is Ownable, AccessControl {
contract LiquidityPoolFactory is Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    enum TokenType { UTILITY, NFT, GAME, REWARD, REFLECTION, DAO, MEME }
    enum PoolType { NORMAL, REFLECTION, DIVIDEND }

    struct PoolInfo {
        address pool;
        address lpToken;
        address rewardToken;
        string urls;
        address owner;
        bool revoked;
        bool launched;
        uint deployed;
    }

    mapping (address => PoolInfo) public poolMap;
    EnumerableSet.AddressSet pools;

    address public constant teamWallet = 0x89352214a56bA80547A2842bbE21AEdD315722Ca;
    uint public priceToStake = 1.55 ether;
    uint public priceToUpdate = 0.15 ether;
    uint public priceToLock = 0.31 ether;

    mapping (address => bool) public referrals;
    uint public referralDiscountRate;
    uint public referralSendingRate;

    // modifier onlyAdmin {
    //     require (hasRole(ADMIN_ROLE, msg.sender) || msg.sender == owner(), "!admin");
    //     _;
    // }

    // constructor() {
    //     _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    //     grantRole(ADMIN_ROLE, msg.sender);
    // }

    function poolCount() external view returns (uint) {
        return pools.length();
    }

    function deploy(
        address _lp,
        address _rewardToken,
        uint _period,
        string memory _urls,
        uint _tokenAmountForPool,
        address _referral
    ) external payable {
        if (_rewardToken != address(0)) { 
            if (referrals[_referral]) {
                require (msg.value >= priceToStake.mul(100-referralDiscountRate).div(100), "!payment");
            } else {
                require (msg.value >= priceToStake, "!payment");
            }
            IUniswapPair pair = IUniswapPair(_lp);
            require (pair.token0() == _rewardToken || pair.token1() == _rewardToken, "!reward token");
        } else {
            if (referrals[_referral]) {
                require (msg.value >= priceToLock.mul(100-referralDiscountRate).div(100), "!payment");
            } else {
                require (msg.value >= priceToLock, "!payment");
            }
        }
        require (bytes(_urls).length <= 700, "invlid social urls size");

        require (_tokenAmountForPool > 0, "!enough token amount1");

        LiquidityStakingV2 pool = new LiquidityStakingV2(_lp, _rewardToken, block.timestamp, block.timestamp.add(_period.mul(1 minutes)));
        
        if (_rewardToken != address(0)) {
            require (_tokenAmountForPool > 0, "!reward");
            pool.setRewardRate(_tokenAmountForPool.div(_period).div(1 minutes));
            IERC20(_rewardToken).safeTransferFrom(msg.sender, address(pool), _tokenAmountForPool);
        }

        pools.add(address(pool));
        pool.transferOwnership(owner());

        poolMap[address(pool)] = PoolInfo({
            pool: address(pool),
            lpToken: _lp,
            rewardToken: _rewardToken,
            urls: _urls,
            owner: msg.sender,
            revoked: false,
            launched: false,
            deployed: block.timestamp
        });

        if (msg.value > 0) {
            uint referralAmount = 0;
            if (referrals[_referral]) {
                referralAmount = (_rewardToken != address(0)?priceToStake:priceToLock).mul(referralSendingRate).div(100);
                address(_referral).call{value: referralAmount}("");
            }
            address(teamWallet).call{value: msg.value.sub(referralAmount)}("");
        }
    }

    function getPools(address _owner) external view returns (address[] memory) {
        uint count = _owner == address(0) ? pools.length() : 0;
        if (_owner != address(0)) {
            for (uint i = 0; i < pools.length(); i++) {
                if (poolMap[pools.at(i)].owner == _owner) count++;
            }
        }
        if (count == 0) return new address[](0);

        address[] memory poolList = new address[](count);
        uint index = 0;
        for (uint i = 0; i < pools.length(); i++) {
            if (_owner != address(0) && poolMap[pools.at(i)].owner != _owner) {
                continue;
            }
            poolList[index] = poolMap[pools.at(i)].pool;
            index++;
        }

        return poolList;
    }

    function updateRewardRate(address _pool, uint _rate) external payable {
        PoolInfo storage pool = poolMap[_pool];

        require (pool.owner == msg.sender, "!owner");
        require (pool.rewardToken != address(0), "!staking pool");
        require (msg.value >= priceToUpdate, "!payment");

        ILiquidityStaking(_pool).setRewardRate(_rate);

        if (msg.value > 0) address(teamWallet).call{value: msg.value}("");
    }

    function supplyRewardToken(address _pool, uint _amount) external payable {
        PoolInfo storage pool = poolMap[_pool];

        require (pool.owner == msg.sender, "!owner");
        require (pool.rewardToken != address(0), "!staking pool");
        require (msg.value >= priceToUpdate, "!payment");
        require (_amount > 0, "!reward");

        ILiquidityStaking poolInst = ILiquidityStaking(_pool);
        require (poolInst.endTime() > block.timestamp, "expired pool");
        uint remaining = poolInst.availableRewards();
        poolInst.setRewardRate(_amount.add(remaining).div(poolInst.endTime().sub(block.timestamp)));
        IERC20(pool.rewardToken).safeTransferFrom(msg.sender, address(_pool), _amount);

        if (msg.value > 0) address(teamWallet).call{value: msg.value}("");
    }

    function expandEndTime(address _pool, uint _mins) external payable {
        PoolInfo storage pool = poolMap[_pool];

        require (pool.owner == msg.sender, "!owner");
        require (pool.rewardToken != address(0), "!staking pool");
        require (msg.value >= priceToUpdate, "!payment");

        ILiquidityStaking(_pool).expandEndTime(_mins);

        if (msg.value > 0) address(teamWallet).call{value: msg.value}("");
    }

    function launch(address _pool) external {
        require (poolMap[_pool].owner == msg.sender, "!owner");
        ILiquidityStaking(_pool).unpause();
        poolMap[_pool].launched = true;
    }

    function revoke(address _pool, bool _flag) external onlyOwner {
        poolMap[_pool].revoked = _flag;
        _flag ? ILiquidityStaking(_pool).pause() : ILiquidityStaking(_pool).unpause();
        poolMap[_pool].launched = !_flag;
    }

    // function setAdmin(address _account, bool _flag) external onlyOwner {
    //     _flag ? grantRole(ADMIN_ROLE, _account) : revokeRole(ADMIN_ROLE, _account);
    // }

    function updatePrices(uint _stake, uint _lock, uint _update) external onlyOwner {
        priceToStake = _stake;
        priceToLock = _lock;
        priceToUpdate = _update;
    }

    function setReferral(address[] memory _wallets, bool _flag) external onlyOwner {
        for (uint i = 0; i < _wallets.length; i++) {
            referrals[_wallets[i]] = _flag;
        }
    }

    function setReferralRates(uint _discountRate, uint _sendingRate) external onlyOwner {
        require (_discountRate <= 30 && _sendingRate <= 30, "exceeded rate");
        referralDiscountRate = _discountRate;
        referralSendingRate = _sendingRate;
    }
}