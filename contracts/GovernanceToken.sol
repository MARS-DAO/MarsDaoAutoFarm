// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./lib/ERC20.sol";
import "./lib/IERC20.sol";
import "./lib/Ownable.sol";
import "./lib/SafeERC20.sol";

contract GovernanceMarsDAO is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public newMarsDAOToken;
    address public constant burnAddress =
        0x000000000000000000000000000000000000dEaD;

    constructor(address _newMarsDAOToken) public ERC20("GMARSDAO", "GMARSDAO")  {
        newMarsDAOToken=IERC20(_newMarsDAOToken);
    }

    function mint(uint256 amount) external{
        require(newMarsDAOToken.allowance(msg.sender, address(this)) >=amount,
            "Increase the allowance first,call the approve method"
        );
        newMarsDAOToken.safeTransferFrom(address(msg.sender),burnAddress,amount);
        _mint(msg.sender, amount);
    }

}