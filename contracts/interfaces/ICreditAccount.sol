// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICreditAccount {
    error CallerNotCreditManagerException();

    error CallerNotAccountFactoryException();

    function factory() external view returns (address);

    function creditManager() external view returns (address);

    function safeTransfer(address token, address to, uint256 amount) external;

    function execute(
        address target,
        bytes calldata data
    ) external returns (bytes memory result);

    
}
