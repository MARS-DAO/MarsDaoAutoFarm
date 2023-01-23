// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/Ownable.sol";
import "./lib/SafeMath.sol";
import "./lib/IERC20.sol";
import "./lib/IERC20Metadata.sol";
import "./lib/SafeERC20.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/ERC20.sol";
import "./lib/IStrategy.sol";
import "./AutofarmVault.sol";

pragma experimental ABIEncoderV2;

contract MarsAutoFarm is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    modifier onlyNativeStrategy(uint256 _pid) {
        require(poolInfo[_pid].strat == msg.sender, "unavailable");
        _;
    }

    struct UserInfo {
        uint256 shares;
        uint256 marsRewardDebt;
        mapping(uint256 => uint256) boostRewardDebt;
    }

    struct Boost {
        address token;
        uint256 startBlock;
        uint256 boostPeriodInBlocks;
        uint256 startPerBlockAmount;
        uint256 endPerBlockAmount;
        uint256 lastRewardBlock;
        uint256 accPerShare;
    }

    struct PendingBoost {
        address token;
        uint256 amount;
    }

    struct PoolInfo {
        bool autoCompound;
        address want; // Address of the want token.
        uint256 accPerShare; // Accumulated per share, times PRECISION. See below.
        address strat; // Strategy address that will auto compound want tokens
        uint256 lastEarnBlock;
        address boostVault;
    }

    struct StaticPoolInfo {
        bool compatible;
        uint256 pancakePID;
        string poolName;
        address lpToken; // Address of the want token.
    }

    IERC20 public immutable marsToken;
    address public govAddress;
    uint256 public constant PRECISION = 1e18;

    PoolInfo[] public poolInfo; // Info of each pool.
    mapping(uint256 => Boost[]) public boostTokens;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => bool)) public boostTokenAdded;

    event Launched(address governance);
    event PoolCharged(uint256 indexed pid, uint256 amount);
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Paused(uint256 indexed pid, bool status);

    constructor(address _marsTokenAddress) public {
        marsToken = IERC20(_marsTokenAddress);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getGovernance() external view returns (address) {
        return govAddress;
    }

    function setGovernance(address _govAddress) external onlyOwner {
        require(govAddress == address(0), "governance address already set");
        govAddress = _govAddress;
        emit Launched(govAddress);
    }


    function addBoostToken(
        uint256 _pid,
        Boost memory _boostToken
    ) public onlyOwner {
        require(
            boostTokenAdded[_pid][_boostToken.token] == false,
            "found dublicate"
        );

        Boost[] memory bTokens = boostTokens[_pid];
        if (bTokens.length == 0) {
            bytes32 deploymentSalt = keccak256(
                abi.encodePacked(address(this), block.number, _pid)
            );
            poolInfo[_pid].boostVault = address(
                new Vault{salt: deploymentSalt}(_pid)
            );
        }

        _boostToken.startBlock = block.number > _boostToken.startBlock
            ? block.number
            : _boostToken.startBlock;

        _boostToken.lastRewardBlock = _boostToken.startBlock;
        _boostToken.accPerShare = 0;
        boostTokens[_pid].push(_boostToken);
        boostTokenAdded[_pid][_boostToken.token] = true;

        uint256 totalboostAmount = calculateBoostReward(
            _boostToken.boostPeriodInBlocks,
            _boostToken.boostPeriodInBlocks,
            _boostToken.startPerBlockAmount,
            _boostToken.endPerBlockAmount
        );
        IERC20(_boostToken.token).safeTransferFrom(msg.sender,poolInfo[_pid].boostVault,totalboostAmount);
    }

    function editBoostToken(
        uint256 _pid,
        uint256 index,
        uint256 startBlock,
        uint256 boostPeriodInBlocks,
        uint256 startPerBlockAmount,
        uint256 endPerBlockAmount
    ) public onlyOwner {
        updateBoost(_pid);
        Boost memory _boostToken = boostTokens[_pid][index];
        PoolInfo memory pool = poolInfo[_pid];
        startBlock = block.number > startBlock ? block.number : startBlock;

        _boostToken.startBlock = startBlock;
        _boostToken.boostPeriodInBlocks = boostPeriodInBlocks;
        _boostToken.lastRewardBlock = startBlock;
        _boostToken.startPerBlockAmount = startPerBlockAmount;
        _boostToken.endPerBlockAmount = endPerBlockAmount;
        boostTokens[_pid][index] = _boostToken;

        uint256 vaultBalance = IERC20(_boostToken.token).balanceOf(
            pool.boostVault
        );
        uint256 totalboostAmount = calculateBoostReward(
            _boostToken.boostPeriodInBlocks,
            _boostToken.boostPeriodInBlocks,
            _boostToken.startPerBlockAmount,
            _boostToken.endPerBlockAmount
        );

        if (totalboostAmount > vaultBalance) {
            IERC20(_boostToken.token).safeTransferFrom(
                msg.sender,
                pool.boostVault,
                totalboostAmount - vaultBalance
            );
        } else if (totalboostAmount < vaultBalance) {
            Vault(pool.boostVault).safeRewardsTransfer(
                _boostToken.token,
                msg.sender,
                vaultBalance - totalboostAmount
            );
        }
    }

    function add(
        address _stratAddress,
        address _wantAddress,
        uint256 _farmPid,
        Boost[] memory _boostTokens
    ) external onlyOwner {
        uint256 _pid = poolInfo.length;

        require(
            IStrategy(_stratAddress).activateStrategy(
                _pid, //id
                _wantAddress,
                _farmPid
            ),
            "cant activate a strategy contract"
        );

        address _boostVault;
        if (_boostTokens.length > 0) {
            bytes32 deploymentSalt = keccak256(
                abi.encodePacked(address(this), block.number, _pid)
            );
            _boostVault = address(new Vault{salt: deploymentSalt}(_pid));

            for (uint256 i = 0; i < _boostTokens.length; i++) {
                Boost memory bToken = _boostTokens[i];
                require(
                    boostTokenAdded[_pid][bToken.token] == false,
                    "found dublicate"
                );
                bToken.startBlock = block.number > bToken.startBlock
                    ? block.number
                    : bToken.startBlock;
                bToken.lastRewardBlock = bToken.startBlock;
                bToken.accPerShare = 0;
                boostTokens[_pid].push(bToken);
                boostTokenAdded[_pid][bToken.token] = true;

                uint256 totalboostAmount = calculateBoostReward(
                    bToken.boostPeriodInBlocks,
                    bToken.boostPeriodInBlocks,
                    bToken.startPerBlockAmount,
                    bToken.endPerBlockAmount
                );
                IERC20(bToken.token).safeTransferFrom(
                    msg.sender,
                    _boostVault,
                    totalboostAmount
                );
            }
        }

        PoolInfo memory pInfo = PoolInfo({
            autoCompound: true,
            want: _wantAddress,
            accPerShare: 0,
            strat: _stratAddress,
            lastEarnBlock: block.number,
            boostVault: _boostVault
        });

        poolInfo.push(pInfo);
    }

    function chargePool(
        uint256 _pid,
        uint256 amount,
        uint256 sharesTotal
    ) external onlyNativeStrategy(_pid) returns (bool) {
        PoolInfo storage pool = poolInfo[_pid];

        marsToken.safeTransferFrom(address(msg.sender), address(this), amount);

        pool.accPerShare = pool.accPerShare.add(
            amount.mul(PRECISION).div(sharesTotal)
        );

        emit PoolCharged(_pid, amount);
        return true;
    }

    function updateLastEarnBlock(
        uint256 _pid
    ) external onlyNativeStrategy(_pid) {
        poolInfo[_pid].lastEarnBlock = block.number;
    }

    function poolLastEarnBlock(uint256 _pid) public view returns (uint256) {
        return poolInfo[_pid].lastEarnBlock;
    }

    function getStratThatNeedsEarnings() external view returns (address) {
        uint256 _i = 0;
        for (uint256 i = 1; i < poolInfo.length; i++) {
            if (
                poolInfo[i].lastEarnBlock < poolInfo[_i].lastEarnBlock &&
                poolInfo[i].autoCompound
            ) {
                _i = i;
            }
        }
        return (poolInfo[_i].strat);
    }

    function calculateBoostReward(
        uint256 blocksNum,
        uint256 period,
        uint256 startPerBlockAmount,
        uint256 endPerBlockAmount
    ) public pure returns (uint256 totalReward) {
        if (period > 0) {
            if (blocksNum > period) {
                blocksNum = period;
            }
            uint256 stepPerBlock = 0;
            if (startPerBlockAmount > endPerBlockAmount) {
                stepPerBlock =
                    (startPerBlockAmount - endPerBlockAmount) /
                    period;
                totalReward = blocksNum.mul(
                    startPerBlockAmount.add(stepPerBlock).sub(
                        stepPerBlock.mul(blocksNum.add(1)).div(2)
                    )
                );
            } else {
                stepPerBlock =
                    (endPerBlockAmount - startPerBlockAmount) /
                    period;
                totalReward = blocksNum.mul(
                    startPerBlockAmount.sub(stepPerBlock).add(
                        stepPerBlock.mul(blocksNum.add(1)).div(2)
                    )
                );
            }
        }
    }

    function getBoostReward(
        Boost memory _boostToken
    ) private view returns (uint256 amountReward) {
        amountReward = 0;

        uint256 currentBlocksNum = block.number.sub(_boostToken.startBlock);
        uint256 prevBlocksNum = _boostToken.lastRewardBlock -
            _boostToken.startBlock;

        amountReward = calculateBoostReward(
            currentBlocksNum,
            _boostToken.boostPeriodInBlocks,
            _boostToken.startPerBlockAmount,
            _boostToken.endPerBlockAmount
        ).sub(
                calculateBoostReward(
                    prevBlocksNum,
                    _boostToken.boostPeriodInBlocks,
                    _boostToken.startPerBlockAmount,
                    _boostToken.endPerBlockAmount
                )
            );
    }

    function updateBoost(uint256 _pid) public {
        PoolInfo memory pool = poolInfo[_pid];
        Boost[] memory bTokens = boostTokens[_pid];
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (sharesTotal > 0) {
            for (uint256 i = 0; i < bTokens.length; i++) {
                if (block.number > bTokens[i].lastRewardBlock) {
                    uint256 amountReward = getBoostReward(bTokens[i]);
                    amountReward = Vault(pool.boostVault).safeRewardsTransfer(
                        bTokens[i].token,
                        address(this),
                        amountReward
                    );
                    boostTokens[_pid][i].accPerShare = bTokens[i]
                        .accPerShare
                        .add(amountReward.mul(PRECISION).div(sharesTotal));
                    boostTokens[_pid][i].lastRewardBlock = block.number;
                }
            }
        }
    }

    function deposit(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updateBoost(_pid);
        PoolInfo memory pool = poolInfo[_pid];
        Boost[] memory bTokens = boostTokens[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        IStrategy(pool.strat).distributeReward();

        if (user.shares > 0) {
            uint256 pending = user
                .shares
                .mul(pool.accPerShare)
                .div(PRECISION)
                .sub(user.marsRewardDebt);
            if (pending > 0) {
                safeMarsTransfer(msg.sender, pending);
            }
            for (uint256 i = 0; i < bTokens.length; i++) {
                pending = user
                    .shares
                    .mul(bTokens[i].accPerShare)
                    .div(PRECISION)
                    .sub(user.boostRewardDebt[i]);
                if (pending > 0) {
                    safeBoostTransfer(bTokens[i].token, msg.sender, pending);
                }
            }
        }
        if (_wantAmt > 0) {
            require(
                IERC20(pool.want).allowance(msg.sender, pool.strat) >= _wantAmt,
                "Increase the allowance first,call the approve method for strategy contract"
            );

            uint256 sharesAdded = IStrategy(pool.strat).deposit(
                msg.sender,
                _wantAmt
            );
            user.shares = user.shares.add(sharesAdded);
        } else {
            IStrategy(pool.strat).earn();
        }
        user.marsRewardDebt = user.shares.mul(pool.accPerShare).div(PRECISION);
        for (uint256 i = 0; i < bTokens.length; i++) {
            user.boostRewardDebt[i] = user
                .shares
                .mul(bTokens[i].accPerShare)
                .div(PRECISION);
        }

        emit Deposit(msg.sender, _pid, _wantAmt);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _wantAmt) public nonReentrant {
        updateBoost(_pid);
        PoolInfo memory pool = poolInfo[_pid];
        Boost[] memory bTokens = boostTokens[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        IStrategy(pool.strat).distributeReward();

        bool withoutHelpToEarn = IStrategy(pool.strat).earn();

        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();

        require(user.shares > 0, "user.shares is 0");
        require(sharesTotal > 0, "sharesTotal is 0");

        uint256 pending = user.shares.mul(pool.accPerShare).div(PRECISION).sub(
            user.marsRewardDebt
        );
        if (pending > 0) {
            safeMarsTransfer(msg.sender, pending);
        }
        for (uint256 i = 0; i < bTokens.length; i++) {
            pending = user
                .shares
                .mul(bTokens[i].accPerShare)
                .div(PRECISION)
                .sub(user.boostRewardDebt[i]);
            if (pending > 0) {
                safeBoostTransfer(bTokens[i].token, msg.sender, pending);
            }
        }

        // Withdraw want tokens
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        if (_wantAmt > amount) {
            _wantAmt = amount;
        }
        if (_wantAmt > 0) {
            uint256 sharesRemoved = IStrategy(pool.strat).withdraw(
                msg.sender,
                _wantAmt,
                withoutHelpToEarn
            );
            user.shares = sharesRemoved > user.shares
                ? 0
                : user.shares.sub(sharesRemoved);
        } else {
            IStrategy(pool.strat).earn();
        }
        user.marsRewardDebt = user.shares.mul(pool.accPerShare).div(PRECISION);
        for (uint256 i = 0; i < bTokens.length; i++) {
            user.boostRewardDebt[i] = user
                .shares
                .mul(bTokens[i].accPerShare)
                .div(PRECISION);
        }

        emit Withdraw(msg.sender, _pid, _wantAmt);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        Boost[] memory bTokens = boostTokens[_pid];
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 wantLockedTotal = IStrategy(pool.strat).wantLockedTotal();
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        uint256 amount = user.shares.mul(wantLockedTotal).div(sharesTotal);
        user.shares = 0;
        user.marsRewardDebt = 0;
        for (uint256 i = 0; i < bTokens.length; i++) {
            user.boostRewardDebt[i] = 0;
        }
        IStrategy(pool.strat).withdraw(msg.sender, amount, true);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function safeMarsTransfer(address _to, uint256 _marsAmt) internal {
        uint256 MARSBal = marsToken.balanceOf(address(this));
        marsToken.safeTransfer(_to, _marsAmt > MARSBal ? MARSBal : _marsAmt);
    }

    function safeBoostTransfer(
        address _token,
        address _to,
        uint256 _amt
    ) internal {
        uint256 bal = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(_to, _amt > bal ? bal : _amt);
    }

    // View function to see pending Reward on frontend.

    function pendingReward(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo memory user = userInfo[_pid][_user];

        uint256 rewardAmount = marsToken.balanceOf(pool.strat);
        uint256 burnAmount = rewardAmount
            .mul(IStrategy(pool.strat).burnRate())
            .div(10000);
        rewardAmount = rewardAmount.sub(burnAmount);
        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (sharesTotal == 0) {
            return 0;
        }
        uint256 accPerShare = pool.accPerShare.add(
            rewardAmount.mul(PRECISION).div(sharesTotal)
        );
        return
            user.shares.mul(accPerShare).div(PRECISION).sub(
                user.marsRewardDebt
            );
    }

    function pendingBoostReward(
        uint256 _pid,
        address _user
    ) external view returns (PendingBoost[] memory) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        Boost[] memory bTokens = boostTokens[_pid];
        PendingBoost[] memory pendingBoost = new PendingBoost[](bTokens.length);

        uint256 sharesTotal = IStrategy(pool.strat).sharesTotal();
        if (sharesTotal > 0) {
            uint256 amount;
            uint256 amountReward;
            for (uint256 i = 0; i < bTokens.length; i++) {
                amount = 0;
                amountReward = 0;
                if (block.number > bTokens[i].lastRewardBlock) {
                    amountReward = getBoostReward(bTokens[i]);
                    uint256 vBalance = IERC20(bTokens[i].token).balanceOf(
                        pool.boostVault
                    );
                    amountReward = vBalance > amountReward
                        ? amountReward
                        : vBalance;
                    bTokens[i].accPerShare = bTokens[i].accPerShare.add(
                        amountReward.mul(PRECISION).div(sharesTotal)
                    );
                }
                amount = user
                    .shares
                    .mul(bTokens[i].accPerShare)
                    .div(PRECISION)
                    .sub(user.boostRewardDebt[i]);

                pendingBoost[i] = PendingBoost(bTokens[i].token, amount);
            }
        }
        return pendingBoost;
    }

    // View function to see staked Want tokens on frontend.
    function stakedWantTokens(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
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

    function setAutocompound(
        uint256 _pid,
        bool _autoCompound
    ) external onlyOwner {
        PoolInfo storage pool = poolInfo[_pid];
        pool.autoCompound = _autoCompound;
        IStrategy(pool.strat).setAutocompound(_autoCompound);
    }

    function getVaultTokens(
        uint256 _pid,
        address token,
        uint256 _amount,
        address _to
    ) external onlyOwner returns (uint256) {
        return
            Vault(poolInfo[_pid].boostVault).safeRewardsTransfer(
                token,
                _to,
                _amount
            );
    }
}
