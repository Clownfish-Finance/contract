// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract UnderlyingToken is ERC20, ERC20Permit {
    constructor() ERC20("UnderlyingToken", "UDY") ERC20Permit("UnderlyingToken") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}