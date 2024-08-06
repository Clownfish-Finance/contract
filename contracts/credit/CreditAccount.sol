// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";

contract CreditAccount is ICreditAccount {
    using SafeERC20 for IERC20;
    using Address for address;

    address public immutable override factory;

    address public immutable override creditManager;

    modifier factoryOnly() {
        if (msg.sender != factory) {
            revert CallerNotAccountFactoryException();
        }
        _;
    }

    modifier creditManagerOnly() {
        _revertIfNotCreditManager();
        _;
    }

    function _revertIfNotCreditManager() internal view {
        if (msg.sender != creditManager) {
            revert CallerNotCreditManagerException();
        }
    }

    constructor(address _creditManager) {
        creditManager = _creditManager;
        factory = msg.sender;
    }

    function safeTransfer(address token, address to, uint256 amount)
        external
        override
        creditManagerOnly
    {
        IERC20(token).safeTransfer(to, amount);
    }

    function execute(address target, bytes calldata data)
        external
        override
        creditManagerOnly
        returns (bytes memory result)
    {
        result = target.functionCall(data);
    }
}
