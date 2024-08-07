// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CreditAccount} from "../credit/CreditAccount.sol";
import {CreditManager} from "../credit/CreditManager.sol";
import {IAccountFactory} from "../interfaces/IAccountFactory.sol";

/// @title AccountFactory
/// @notice This contract manages the creation, queueing, and returning of Credit Accounts for Credit Managers.
contract AccountFactory is IAccountFactory {
    /// @dev Struct to hold factory parameters for each Credit Manager
    struct FactoryParams {
        address masterCreditAccount; // Address of the master Credit Account
        uint40 head; // Head of the queue
        uint40 tail; // Tail of the queue
    }

    /// @dev Struct to hold a queued Credit Account
    struct QueuedAccount {
        address creditAccount; // Address of the queued Credit Account
    }

    /// @dev Mapping from Credit Manager to its FactoryParams
    mapping(address => FactoryParams) internal _factoryParams;

    /// @dev Mapping from Credit Manager to queued Credit Accounts
    mapping(address => mapping(uint256 => QueuedAccount))
        internal _queuedAccounts;

    /// @notice Constructor for the AccountFactory contract
    constructor() {}

    /// @notice Takes a Credit Account from the queue or creates a new one if the queue is empty
    /// @return creditAccount Address of the taken or newly created Credit Account
    function takeCreditAccount()
        external
        override
        returns (address creditAccount)
    {
        FactoryParams storage fp = _factoryParams[msg.sender];

        // Ensure the caller is a Credit Manager with an initialized master Credit Account
        address masterCreditAccount = fp.masterCreditAccount;
        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        // Get the head of the queue
        uint256 head = fp.head;

        // If the queue is empty, create a new Credit Account by cloning the master Credit Account
        if (head == fp.tail) {
            creditAccount = Clones.clone(masterCreditAccount);
            emit DeployCreditAccount({
                creditAccount: creditAccount,
                creditManager: msg.sender
            });
        } else {
            // Otherwise, take the Credit Account from the head of the queue
            creditAccount = _queuedAccounts[msg.sender][head].creditAccount;
            delete _queuedAccounts[msg.sender][head];
            ++fp.head;
        }

        emit TakeCreditAccount({
            creditAccount: creditAccount,
            creditManager: msg.sender
        });
    }

    /// @notice Returns a Credit Account to the queue
    /// @param creditAccount The address of the Credit Account to return
    function returnCreditAccount(address creditAccount) external override {
        FactoryParams storage fp = _factoryParams[msg.sender];

        // Ensure the caller is a Credit Manager with an initialized master Credit Account
        if (fp.masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        // Add the Credit Account to the queue at the tail position
        _queuedAccounts[msg.sender][fp.tail] = QueuedAccount({
            creditAccount: creditAccount
        });

        ++fp.tail;

        emit ReturnCreditAccount({
            creditAccount: creditAccount,
            creditManager: msg.sender
        });
    }

    /// @notice Adds a new Credit Manager and initializes its master Credit Account
    /// @param creditManager The address of the new Credit Manager
    function addCreditManager(address creditManager) external override {
        // Ensure the Credit Manager doesn't already have a master Credit Account
        if (_factoryParams[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException();
        }

        // Create a new master Credit Account for the Credit Manager
        address masterCreditAccount = address(new CreditAccount(creditManager));
        _factoryParams[creditManager].masterCreditAccount = masterCreditAccount;

        emit AddCreditManager(creditManager, masterCreditAccount);
    }
}
