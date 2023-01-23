// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/Ownable.sol";
import "./lib/IPancakeRouter.sol";
import "./lib/IPancakeswapFarmV2.sol";
import "./lib/IPancakePair.sol";
import "./lib/IPancakeFactory.sol";
import "./lib/IERC20.sol";
import "./lib/SafeERC20.sol";
import "./lib/Pausable.sol";
import "./lib/ReentrancyGuard.sol";
import "./lib/SafeMath.sol";
import "./lib/IMarsAutoFarm.sol";
import "./lib/IStrategy.sol";

pragma experimental ABIEncoderV2;

contract Strat2X is Ownable, ReentrancyGuard, Pausable {
    // Maximises yields in pancakeswap

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    bool public autoCompound = true;
    uint256 public pid; // pid of pool in farmContractAddress
    uint256 public marsPid; //// id of pool in marsAutoFarmAddress
    address public wantAddress;
    address public token0Address;
    address public token1Address;
    address public constant earnedAddress =
        0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82; //CAKE
    address public constant farmContractAddress =
        0xa5f8C5Dbd5F286960b9d90548680aE5ebFf07652; // address of farm, eg, PCS, Thugs etc.
    address public constant uniRouterAddress =
        0x10ED43C718714eb63d5aA57B78B54704E256024E; // uniswap, pancakeswap etc
    IPancakeFactory public constant uniFactory =
        IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);
    address public constant wbnbAddress =
        0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant busdAddress =
        0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address public constant usdtAddress =
        0x55d398326f99059fF775485246999027B3197955;
    address public immutable marsAutoFarmAddress;
    address public immutable marsTokenAddress;
    address public governanceAddress;
    uint256 public constant MINIMUM_CAKE_AMOUNT = 1e12;
    uint256 public constant MINIMUM_MARS_AMOUNT = 1e6;

    uint256 public wantLockedTotal = 0;
    uint256 public sharesTotal = 0;

    address public immutable dev25;
    address public immutable dev75;

    uint256 public constant MaxBP = 10000; // 100%

    uint256 public buyBackRate = 4845; //48,45%
    uint256 public constant buyBackRateUL = 7000; //70%
    uint256 public constant buyBackRateLL = 3000; //30%
    uint256 public swapSlippageBP = 900;

    uint256 public burnRate = 2000; //20%
    uint256 public constant burnRateUL = 4500; //45%
    uint256 public constant burnRateLL = 1000; //10%
    address public constant burnAddress =
        0x000000000000000000000000000000000000dEaD;

    address[] public token0ToEarnedPath;
    address[] public token1ToEarnedPath;
    address[][] public router0;
    address[][] public router1;
    address[][] public router2;

    modifier onlyGovernanceAddress() {
        require(msg.sender == governanceAddress, "Not authorised");
        _;
    }

    constructor(
        address _marsAutoFarmAddress,
        address _marsTokenAddress,
        address _dev25,
        address _dev75
    ) public {
        governanceAddress = IMarsAutoFarm(_marsAutoFarmAddress).getGovernance();
        require(governanceAddress != address(0), "governanceAddress is 0");
        marsAutoFarmAddress = _marsAutoFarmAddress;
        marsTokenAddress = _marsTokenAddress;
        dev25 = _dev25;
        dev75 = _dev75;

        transferOwnership(_marsAutoFarmAddress);
    }

    function activateStrategy(
        uint256 poolId, //marsAutoFarm
        address _wantAddress,
        uint256 _farmPid
    ) external onlyOwner returns (bool) {
        require(wantAddress == address(0), "already activated");
        require(
            marsTokenAddress != _wantAddress,
            "marsTokenAddress address cannot be equal to _wantAddress"
        );

        marsPid = poolId;
        wantAddress = _wantAddress;

        pid = _farmPid;
        router2.push([earnedAddress, busdAddress, marsTokenAddress]);
        router2.push(
            [earnedAddress, wbnbAddress, busdAddress, marsTokenAddress]
        );

        token0Address = IPancakePair(_wantAddress).token0();
        token1Address = IPancakePair(_wantAddress).token1();

        require(
            address(uniFactory) == IPancakePair(_wantAddress).factory(),
            "LP token V2 only"
        );
        token0ToEarnedPath = [token0Address, wbnbAddress, earnedAddress];
        token1ToEarnedPath = [token1Address, wbnbAddress, earnedAddress];

        if (token0Address == wbnbAddress) {
            router0.push([earnedAddress, token0Address]);
            token0ToEarnedPath = [token0Address, earnedAddress];
        } else {
            if (
                uniFactory.getPair(earnedAddress, token0Address) != address(0)
            ) {
                router0.push([earnedAddress, token0Address]);
                router1.push([earnedAddress, token0Address, token1Address]);
            }
            router0.push([earnedAddress, wbnbAddress, token0Address]);
            if (
                token0Address != busdAddress &&
                uniFactory.getPair(busdAddress, token0Address) != address(0)
            ) {
                router0.push([earnedAddress, busdAddress, token0Address]);
            }
            if (
                token0Address != usdtAddress &&
                uniFactory.getPair(usdtAddress, token0Address) != address(0)
            ) {
                router0.push([earnedAddress, usdtAddress, token0Address]);
            }
        }

        if (token1Address == wbnbAddress) {
            router1.push([earnedAddress, token1Address]);
            token1ToEarnedPath = [token1Address, earnedAddress];
        } else {
            if (
                uniFactory.getPair(earnedAddress, token1Address) != address(0)
            ) {
                router1.push([earnedAddress, token1Address]);
                router0.push([earnedAddress, token1Address, token0Address]);
            }
            router1.push([earnedAddress, wbnbAddress, token1Address]);
            if (
                token1Address != busdAddress &&
                uniFactory.getPair(busdAddress, token1Address) != address(0)
            ) {
                router1.push([earnedAddress, busdAddress, token1Address]);
            }
            if (
                token1Address != usdtAddress &&
                uniFactory.getPair(usdtAddress, token1Address) != address(0)
            ) {
                router1.push([earnedAddress, usdtAddress, token1Address]);
            }
        }

        return true;
    }

    function _getBestPath(
        uint256 amountIn,
        address[][] memory router
    ) internal view returns (address[] memory, uint256) {
        uint256 amountOut = 0;
        uint256 bestI = 0;
        for (uint256 i = 0; i < router.length; i++) {
            try
                IPancakeRouter02(uniRouterAddress).getAmountsOut(
                    amountIn,
                    router[i]
                )
            returns (uint256[] memory amounts) {
                if (amounts[amounts.length.sub(1)] > amountOut) {
                    amountOut = amounts[amounts.length.sub(1)];
                    bestI = i;
                }
            } catch {
                continue;
            }
        }
        return (router[bestI], amountOut);
    }

    function getEarnedToBusdPath(
        uint256 amountIn
    ) public view returns (address[] memory, uint256) {
        return _getBestPath(amountIn, router2);
    }

    function getPathForToken0(
        uint256 amountIn
    ) public view returns (address[] memory, uint256) {
        return _getBestPath(amountIn, router0);
    }

    function getPathForToken1(
        uint256 amountIn
    ) public view returns (address[] memory, uint256) {
        return _getBestPath(amountIn, router1);
    }

    function _approveTokenIfNeeded(
        address _token,
        address _spender,
        uint256 _amount
    ) private {
        if (IERC20(_token).allowance(address(this), _spender) < _amount) {
            IERC20(_token).safeIncreaseAllowance(
                _spender,
                type(uint256).max - _amount
            );
        }
    }

    // Receives new deposits from user
    function deposit(
        address _userAddress,
        uint256 _wantAmt
    ) external onlyOwner whenNotPaused returns (uint256) {
        IERC20(wantAddress).safeTransferFrom(
            _userAddress,
            address(this),
            _wantAmt
        );

        _approveTokenIfNeeded(wantAddress, farmContractAddress, _wantAmt);
        IPancakeswapFarmV2(farmContractAddress).deposit(pid, _wantAmt);

        uint256 earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
        if (earnedAmt > MINIMUM_CAKE_AMOUNT) {
            _earn(false, earnedAmt);
        } else {
            IMarsAutoFarm(marsAutoFarmAddress).updateLastEarnBlock(marsPid);
            _helpToEarn();
        }

        uint256 sharesAdded = _wantAmt;
        if (wantLockedTotal > 0 && sharesTotal > 0) {
            sharesAdded = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        }
        sharesTotal = sharesTotal.add(sharesAdded);
        wantLockedTotal = wantLockedTotal.add(_wantAmt);

        return sharesAdded;
    }

    function farm() external nonReentrant {
        _farm();
    }

    function _farm() internal {
        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (wantAmt > 0) {
            wantLockedTotal = wantLockedTotal.add(wantAmt);
            IERC20(wantAddress).safeIncreaseAllowance(
                farmContractAddress,
                wantAmt
            );

            IPancakeswapFarmV2(farmContractAddress).deposit(pid, wantAmt);
        }
    }

    function withdraw(
        address _userAddress,
        uint256 _wantAmt,
        bool isEmergency
    ) external onlyOwner nonReentrant returns (uint256) {
        require(_wantAmt > 0, "_wantAmt <= 0");

        IPancakeswapFarmV2(farmContractAddress).withdraw(pid, _wantAmt);

        uint256 wantAmt = IERC20(wantAddress).balanceOf(address(this));
        if (_wantAmt > wantAmt) {
            _wantAmt = wantAmt;
        }

        if (wantLockedTotal < _wantAmt) {
            _wantAmt = wantLockedTotal;
        }

        uint256 sharesRemoved = _wantAmt.mul(sharesTotal).div(wantLockedTotal);
        if (sharesRemoved > sharesTotal) {
            sharesRemoved = sharesTotal;
        }
        sharesTotal = sharesTotal.sub(sharesRemoved);
        wantLockedTotal = wantLockedTotal.sub(_wantAmt);

        IERC20(wantAddress).safeTransfer(_userAddress, _wantAmt);
        if (!isEmergency) {
            _helpToEarn();
        }
        return sharesRemoved;
    }

    function lastEarnBlock() public view returns (uint256) {
        return IMarsAutoFarm(marsAutoFarmAddress).poolLastEarnBlock(marsPid);
    }

    function earn() external returns (bool) {
        if (paused()) {
            IMarsAutoFarm(marsAutoFarmAddress).updateLastEarnBlock(marsPid);
            return false;
        } else {
            return _earn(true, 0);
        }
    }

    function _helpToEarn() internal {
        if (autoCompound) {
            address stratThatNeedsEarnings = IMarsAutoFarm(marsAutoFarmAddress)
                .getStratThatNeedsEarnings();
            if (stratThatNeedsEarnings != address(this)) {
                IStrategy(stratThatNeedsEarnings).earn();
            }
        }
    }

    function _earn(bool harvest, uint256 earnedAmt) internal returns (bool) {
        IMarsAutoFarm(marsAutoFarmAddress).updateLastEarnBlock(marsPid);

        if (harvest) {
            IPancakeswapFarmV2(farmContractAddress).withdraw(pid, 0);
            earnedAmt = IERC20(earnedAddress).balanceOf(address(this));
            if (earnedAmt <= MINIMUM_CAKE_AMOUNT) {
                return false;
            }
        }

        earnedAmt = distributeFees(earnedAmt);
        earnedAmt = buyBack(earnedAmt);

        // Converts farm tokens into want tokens

        IERC20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            earnedAmt
        );
        (uint256 reserveA, uint256 reserveB, ) = IPancakePair(wantAddress)
            .getReserves();
        uint256 halfAmount0 = earnedAmt.mul(reserveA).div(reserveA + reserveB);
        uint256 halfAmount1 = earnedAmt - halfAmount0;
        address[] memory path;
        uint256 amountOut;
        if (earnedAddress != token0Address) {
            // Swap half earned to token0
            (path, amountOut) = getPathForToken0(halfAmount0);
            _swap(halfAmount0, amountOut, path);
        }

        if (earnedAddress != token1Address) {
            // Swap half earned to token1
            (path, amountOut) = getPathForToken1(halfAmount1);
            _swap(halfAmount1, amountOut, path);
        }

        // Get want tokens, ie. add liquidity
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token0Amt > 0 && token1Amt > 0) {
            IERC20(token0Address).safeIncreaseAllowance(
                uniRouterAddress,
                token0Amt
            );
            IERC20(token1Address).safeIncreaseAllowance(
                uniRouterAddress,
                token1Amt
            );
            IPancakeRouter02(uniRouterAddress).addLiquidity(
                token0Address,
                token1Address,
                token0Amt,
                token1Amt,
                0,
                0,
                address(this),
                block.timestamp.add(600)
            );
        }

        _farm();
        return true;
    }

    function buyBack(uint256 _earnedAmt) internal returns (uint256) {
        uint256 buyBackAmt = _earnedAmt.mul(buyBackRate).div(MaxBP);

        if (buyBackAmt == 0) {
            return _earnedAmt;
        }

        IERC20(earnedAddress).safeIncreaseAllowance(
            uniRouterAddress,
            buyBackAmt
        );

        (address[] memory path, uint256 amountOut) = getEarnedToBusdPath(
            buyBackAmt
        );

        _swap(buyBackAmt, amountOut, path);

        return _earnedAmt.sub(buyBackAmt);
    }

    function distributeReward() external {
        uint256 rewardAmount = IERC20(marsTokenAddress).balanceOf(
            address(this)
        );

        if (rewardAmount > MINIMUM_MARS_AMOUNT && sharesTotal > 0) {
            uint256 burnAmount = rewardAmount.mul(burnRate).div(MaxBP);
            IERC20(marsTokenAddress).safeTransfer(burnAddress, burnAmount);
            rewardAmount = rewardAmount.sub(burnAmount);
            IERC20(marsTokenAddress).safeIncreaseAllowance(
                marsAutoFarmAddress,
                rewardAmount
            );
            require(
                IMarsAutoFarm(marsAutoFarmAddress).chargePool(
                    marsPid,
                    rewardAmount,
                    sharesTotal
                ),
                "pool charging fail"
            );
        }
    }

    function distributeFees(uint256 _earnedAmt) internal returns (uint256) {
        if (_earnedAmt > 0) {
            uint256 fee75 = _earnedAmt.mul(300).div(MaxBP); //3%
            uint256 fee25 = _earnedAmt.mul(100).div(MaxBP); //1%
            IERC20(earnedAddress).safeTransfer(dev75, fee75);
            IERC20(earnedAddress).safeTransfer(dev25, fee25);
            _earnedAmt = _earnedAmt.sub(fee75.add(fee25));
        }

        return _earnedAmt;
    }

    function convertDustToEarned() external whenNotPaused {
        // Converts dust tokens into earned tokens, which will be reinvested on the next earn().

        // Converts token0 dust (if any) to earned tokens
        uint256 token0Amt = IERC20(token0Address).balanceOf(address(this));
        if (token0Address != earnedAddress && token0Amt > 0) {
            IERC20(token0Address).safeIncreaseAllowance(
                uniRouterAddress,
                token0Amt
            );

            // Swap all dust tokens to earned tokens
            _swap(token0Amt, 0, token0ToEarnedPath);
        }

        // Converts token1 dust (if any) to earned tokens
        uint256 token1Amt = IERC20(token1Address).balanceOf(address(this));
        if (token1Address != earnedAddress && token1Amt > 0) {
            IERC20(token1Address).safeIncreaseAllowance(
                uniRouterAddress,
                token1Amt
            );
            // Swap all dust tokens to earned tokens
            _swap(token1Amt, 0, token1ToEarnedPath);
        }
    }

    function setAutocompound(bool _autoCompound) external onlyOwner {
        autoCompound = _autoCompound;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRouter0(
        address[][] memory _router0
    ) external onlyGovernanceAddress {
        for (uint256 i = 0; i < _router0.length; i++) {
            require(_router0[i][0] == earnedAddress);
            require(_router0[i][_router0[i].length.sub(1)] == token0Address);
        }

        router0 = _router0;
    }

    function setRouter1(
        address[][] memory _router1
    ) external onlyGovernanceAddress {
        for (uint256 i = 0; i < _router1.length; i++) {
            require(_router1[i][0] == earnedAddress);
            require(_router1[i][_router1[i].length.sub(1)] == token1Address);
        }

        router1 = _router1;
    }

    function setRouter2(
        address[][] memory _router2
    ) external onlyGovernanceAddress {
        for (uint256 i = 0; i < _router2.length; i++) {
            require(_router2[i][0] == earnedAddress);
            require(_router2[i][_router2[i].length.sub(1)] == marsTokenAddress);
        }

        router2 = _router2;
    }

    function setBurnRate(uint256 _burnRate) external onlyGovernanceAddress {
        require(burnRate <= burnRateUL, "too high");
        require(burnRate >= burnRateLL, "too low");
        burnRate = _burnRate;
    }

    function setbuyBackRate(
        uint256 _buyBackRate
    ) external onlyGovernanceAddress {
        require(buyBackRate <= buyBackRateUL, "too high");
        require(buyBackRate >= buyBackRateLL, "too low");
        buyBackRate = _buyBackRate;
    }

    function setSwapSlippageBP(
        uint256 _swapSlippageBP
    ) external onlyGovernanceAddress {
        require(_swapSlippageBP < 1000, "should be between 0-1000");
        swapSlippageBP = _swapSlippageBP;
    }

    function inCaseTokensGetStuck(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyGovernanceAddress {
        require(_token != earnedAddress, "!safe");
        require(_token != token0Address, "!safe");
        require(_token != token1Address, "!safe");
        require(_token != wantAddress, "!safe");
        require(_token != marsTokenAddress, "!safe");
        IERC20(_token).safeTransfer(_to, _amount);
    }

    function _swap(
        uint256 _amountIn,
        uint256 _amountOut,
        address[] memory _path
    ) internal {
        if (_amountIn > 0) {
            uint256 amountOut = _amountOut.mul(swapSlippageBP).div(1000);

            IPancakeRouter02(uniRouterAddress)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    _amountIn,
                    amountOut,
                    _path,
                    address(this),
                    block.timestamp.add(600)
                );
        }
    }
}
