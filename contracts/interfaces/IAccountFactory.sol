// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

interface IAccountFactory {
    error CallerNotCreditManagerException();
    error CreditAccountIsInUseException();
    error MasterCreditAccountAlreadyDeployedException();
    event DeployCreditAccount(
        address indexed creditAccount,
        address indexed creditManager
    );

    event TakeCreditAccount(
        address indexed creditAccount,
        address indexed creditManager
    );

    event ReturnCreditAccount(
        address indexed creditAccount,
        address indexed creditManager
    );

    event AddCreditManager(
        address indexed creditManager,
        address masterCreditAccount
    );

    function takeCreditAccount() external returns (address creditAccount);

    function returnCreditAccount(address creditAccount) external;

    function addCreditManager(address creditManager) external;
}
