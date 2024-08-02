pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {CreditAccount} from "../credit/CreditAccount.sol";
import {CreditManager} from "../credit/CreditManager.sol";
import {IAccountFactory} from "../interfaces/IAccountFactory.sol";

struct FactoryParams {
    address masterCreditAccount;
    uint40 head;
    uint40 tail;
}

struct QueuedAccount {
    address creditAccount;
}

contract AccountFactory is IAccountFactory {
    mapping(address => FactoryParams) internal _factoryParams;

    mapping(address => mapping(uint256 => QueuedAccount))
        internal _queuedAccounts;

    constructor() {}

    function takeCreditAccount(
        uint256,
        uint256
    ) external override returns (address creditAccount) {
        FactoryParams storage fp = _factoryParams[msg.sender];

        address masterCreditAccount = fp.masterCreditAccount;
        if (masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        uint256 head = fp.head;
        if (head == fp.tail) {
            creditAccount = Clones.clone(masterCreditAccount);
            emit DeployCreditAccount({
                creditAccount: creditAccount,
                creditManager: msg.sender
            });
        } else {
            creditAccount = _queuedAccounts[msg.sender][head].creditAccount;
            delete _queuedAccounts[msg.sender][head];
            ++fp.head;
        }

        emit TakeCreditAccount({
            creditAccount: creditAccount,
            creditManager: msg.sender
        });
    }

    function returnCreditAccount(address creditAccount) external override {
        FactoryParams storage fp = _factoryParams[msg.sender];

        if (fp.masterCreditAccount == address(0)) {
            revert CallerNotCreditManagerException();
        }

        _queuedAccounts[msg.sender][fp.tail] = QueuedAccount({
            creditAccount: creditAccount
        });

        ++fp.tail;

        emit ReturnCreditAccount({
            creditAccount: creditAccount,
            creditManager: msg.sender
        });
    }

    function addCreditManager(address creditManager) external override {
        if (_factoryParams[creditManager].masterCreditAccount != address(0)) {
            revert MasterCreditAccountAlreadyDeployedException();
        }
        address masterCreditAccount = address(new CreditAccount(creditManager));
        _factoryParams[creditManager].masterCreditAccount = masterCreditAccount;
        emit AddCreditManager(creditManager, masterCreditAccount);
    }
}
