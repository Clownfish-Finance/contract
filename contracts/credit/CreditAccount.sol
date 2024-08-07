// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";

/// @title CreditAccount
/// @notice This contract represents a Credit Account that can hold and transfer ERC20 tokens, and execute calls to other contracts.
contract CreditAccount is ICreditAccount {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Address of the factory that created this Credit Account
    address public immutable override factory;

    /// @notice Address of the Credit Manager that manages this Credit Account
    address public immutable override creditManager;

    /// @dev Modifier to restrict functions to be callable only by the factory
    modifier factoryOnly() {
        if (msg.sender != factory) {
            revert CallerNotAccountFactoryException();
        }
        _;
    }

    /// @dev Modifier to restrict functions to be callable only by the Credit Manager
    modifier creditManagerOnly() {
        _revertIfNotCreditManager();
        _;
    }

    /// @dev Internal function to revert if the caller is not the Credit Manager
    function _revertIfNotCreditManager() internal view {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
    }

    /// @notice Constructor to set the Credit Manager and factory addresses
    /// @param _creditManager Address of the Credit Manager
    constructor(address _creditManager) {
        creditManager = _creditManager;
        factory = msg.sender;
    }

    /// @notice Transfers tokens from this account to another address
    /// @param token Address of the ERC20 token contract
    /// @param to Address to transfer the tokens to
    /// @param amount Amount of tokens to transfer
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) external override creditManagerOnly {
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Executes a call to another contract
    /// @param target Address of the target contract
    /// @param data Calldata to send to the target contract
    /// @return result The return data from the call to the target contract
    function execute(
        address target,
        bytes calldata data
    ) external override creditManagerOnly returns (bytes memory result) {
        result = target.functionCall(data);
    }
}
