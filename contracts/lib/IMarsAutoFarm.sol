// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IMarsAutoFarm {
    function chargePool(uint256 _pid,uint256 amount,uint256 sharesTotal) external returns (bool);
    function updateLastEarnBlock(uint256 _pid) external;
    function poolLastEarnBlock(uint256 _pid) external view returns(uint256);
    function getStratThatNeedsEarnings() external view returns(address,uint256);
}