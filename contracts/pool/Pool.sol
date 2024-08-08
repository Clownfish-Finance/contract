// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "../interfaces/IPool.sol";

/// @dev Struct that holds borrowed amount and debt limit
struct DebtParams {
    uint128 borrowed;
    uint128 limit;
}

/// @title Pool
/// @notice Pool contract that implements lending and borrowing logic, compatible with ERC-4626 standard
/// @notice Pool shares implement EIP-2612 permits
// contract Pool is ERC4626, ERC20Permit, IPool {

// }
