// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract RCCToken is ERC20, ERC20Permit {
    address owner;
    constructor() ERC20("RCCToken", "RCK") ERC20Permit("RCCToken") {
        owner = msg.sender;
    }

    modifier onlyOwner(){
        require(msg.sender == owner);
        _;
    }

    function mint(address to, uint amount) public onlyOwner() {
        _mint(to, amount);
    }
}
