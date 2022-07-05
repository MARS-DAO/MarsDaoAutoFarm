// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/Ownable.sol";
import "./lib/SafeMath.sol";
import "./lib/IERC20.sol";
import "./lib/SafeERC20.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/ERC20.sol";
import "./lib/ERC721.sol";
import "./lib/IStrategy.sol";


contract MarsAutoFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    modifier onlyNativeStrategy(uint256 _pid) {
        require(poolInfo[_pid].strat == msg.sender,"unavailable");
        _;
    }

    struct UserInfo {
        uint256 shares; 
        uint256 rewardDebt;
    }

    struct PoolInfo {
        address want; // Address of the want token.
        uint256 accPerShare; // Accumulated per share, times 1e12. See below.
        address strat; // Strategy address that will auto compound want tokens 
        uint256 lastEarnBlock;
    }

    IERC20 immutable public marsToken;
    address public govAddress;


    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    
    event Launched(address governance);
    event PoolCharged(uint256 indexed pid,uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Paused(uint256 indexed pid, bool status);

    constructor(address _marsTokenAddress) public {
        marsToken=IERC20(_marsTokenAddress);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getGovernance() external view returns (address) {
        return govAddress;
    }

    function setGovernance(address _govAddress) external onlyOwner {
        require(govAddress==address(0),"governance address already set");
        govAddress=_govAddress;
        emit Launched(govAddress);
    }

    
    function add(address _stratAddress,
                address _wantAddress,
                uint256 _farmPid) public onlyOwner {
        
        require(IStrategy(_stratAddress).activateStrategy(
            poolInfo.length,//id
            _wantAddress,
            _farmPid),
        "cant activate a strategy contract");
        
        poolInfo.push(
            PoolInfo({
                want: _wantAddress,
                accPerShare: 0,
                strat: _stratAddress,
                lastEarnBlock: block.number
            })
        );
    }

    function chargePool(uint256 _pid,uint256 amount,uint256 sharesTotal)
         external 
         onlyNativeStrategy(_pid) returns (bool){

        PoolInfo storage pool = poolInfo[_pid];

        marsToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );

        pool.accPerShare=pool.accPerShare.add(amount.mul(1e12).div(sharesTotal));
        
        emit PoolCharged(_pid,amount);
        return true;

    }

    function updateLastEarnBlock(uint256 _pid) external onlyNativeStrategy(_pid){
        poolInfo[_pid].lastEarnBlock=block.number;
    }

    function poolLastEarnBlock(uint256 _pid) public view returns(uint256){
        return poolInfo[_pid].lastEarnBlock;
    }

    function getStratThatNeedsEarnings() external view returns(address, uint256) {
        uint256 _i = 0;
        for (uint256 i = 1; i < poolInfo.length; i++) {
            if (poolInfo[i].lastEarnBlock < poolInfo[_i].lastEarnBlock && !IStrategy(poolInfo[i].strat).paused()) {
                _i = i;
            }
        }
        return (poolInfo[_i].strat, poolInfo[_i].lastEarnBlock);
    }

    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        IStrategy(pool.strat).distributeReward();

        if (user.shares > 0) {
            uint256 pending =
                user.shares.mul(pool.accPerShare).div(1e12).sub(
                    user.rewardDebt
                );
            if (pending > 0) {
                safeMarsTransfer(msg.sender, pending);
            }
        }
        if (_wantAmt > 0) {
            require(IERC20(pool.want).allowance(msg.sender, pool.strat) >=_wantAmt,
            "Increase the allowance first,call the approve method for strategy contract"
            );
            
            uint256 sharesAdded = IStrategy(pool.strat).deposit(msg.sender, _wantAmt);
            user.shares = user.shares.add(sharesAdded);
        }else {
            IStrategy(pool.strat).earn(); 
        }
        user.rewardDebt = user.shares.mul(pool.accPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        IStrategy(pool.strat).distributeReward();
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        uint256 pending =
            user.shares.mul(pool.accPerShare).div(1e12).sub(
                user.rewardDebt
            );
        if (pending > 0) {
            safeMarsTransfer(msg.sender, pending);
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {

            uint256 sharesRemoved = IStrategy(pool.strat).withdraw(msg.sender, _wantAmt, false);
            user.shares = sharesRemoved > user.shares ? 0:user.shares.sub(sharesRemoved);

        }else {
            IStrategy(pool.strat).earn(); 
        }
        user.rewardDebt = user.shares.mul(pool.accPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        user.shares = 0;
        user.rewardDebt = 0;
        IStrategy(pool.strat).withdraw(msg.sender, amount, true);
        
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function safeMarsTransfer(address _to, uint256 _marsAmt) internal {
        uint256 MARSBal = marsToken.balanceOf(address(this));
        marsToken.safeTransfer(_to, _marsAmt > MARSBal ? MARSBal:_marsAmt);
    }

       // View function to see pending Reward on frontend.

    function pendingReward(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 rewardAmount=marsToken.balanceOf(pool.strat);
        uint256 burnAmount=rewardAmount.mul(IStrategy(pool.strat).burnRate()).div(10000);
        rewardAmount=rewardAmount.sub(burnAmount);
        uint256 sharesTotal=IStrategy(pool.strat).sharesTotal();
        if(sharesTotal==0){return 0;}
        uint256 accPerShare=pool.accPerShare.add(rewardAmount.mul(1e12).div(sharesTotal));
        return user.shares.mul(accPerShare).div(1e12).sub(user.rewardDebt);
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        return user.shares.mul(wantLockedTotal).div(sharesTotal);
    }

    function pause(uint256 _pid) external onlyOwner {
        IStrategy(poolInfo[_pid].strat).pause();
        emit Paused(_pid, true);
    }

    function unpause(uint256 _pid) external onlyOwner {
        IStrategy(poolInfo[_pid].strat).unpause();
        emit Paused(_pid, false);
    }

}
