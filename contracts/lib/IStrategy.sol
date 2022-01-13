// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

// For interacting with our own strategy
interface IStrategy {

    function burnRate() external view returns (uint256);
    //setup the ID and activate the strategy( only once execution)
    function activateStrategy(uint256 poolId,
                            address _wantAddress,
                            uint256 _farmPid) external returns (bool);
    // Total want tokens managed by stratfegy
    function wantLockedTotal() external view returns (uint256);

    // Sum of all shares of users to wantLockedTotal
    function sharesTotal() external view returns (uint256);

    // Main want token compounding function
    function earn() external;
   
   //charged pool and burned rewardToken
    function distributeReward() external;

    // Transfer want tokens autoFarm -> strategy
    function deposit(address _userAddress, uint256 _wantAmt)
        external
        returns (uint256);

    // Transfer want tokens strategy -> autoFarm
    function withdraw(address _userAddress, uint256 _wantAmt, bool isEmergency)
        external
        returns (uint256);

}