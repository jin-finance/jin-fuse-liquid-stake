// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract SFuse is ERC20, Ownable {
    
    constructor() public ERC20('Liquid staked Fuse', 'sFUSE') {
        
    }

    function mint(address recipient_, uint256 amount_) public onlyOwner returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 _amount) public {
        require(_amount > 0, "ERC20: no tokens are burn");
        _burn(msg.sender, _amount);
    }
    
}