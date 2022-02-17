// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

interface IMarsAutoFarm {
    
    struct PoolInfo {
        address want; 
        uint256 accPerShare;
        address strat;
        uint256 lastEarnBlock;
    }

    function chargePool(uint256 _pid,uint256 amount,uint256 sharesTotal) external returns (bool);
    function updateLastEarnBlock(uint256 _pid) external;
    function poolLastEarnBlock(uint256 _pid) external view returns(uint256);
    function getStratThatNeedsEarnings() external view returns(address,uint256);
    function  poolInfo(uint256  _pid) external view returns(PoolInfo memory);
    function poolLength() external view returns (uint256);
    function getGovernance() external view returns (address);
}