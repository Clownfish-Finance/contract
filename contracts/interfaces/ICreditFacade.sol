// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "../libraries/Multicall.sol";
import "./ICreditFacadeMulticall.sol";

/// @notice Debt limits packed into a single slot
/// @param minDebt Minimum debt amount per credit account
/// @param maxDebt Maximum debt amount per credit account
struct DebtLimits {
    uint128 minDebt;
    uint128 maxDebt;
}

/// @notice Collateral check params
struct FullCheckParams {
    uint256 enabledTokensMaskAfter;
}

/// @title Credit facade  interface
interface ICreditFacade {
    /// @notice Thrown when trying to close an account with enabled tokens
    error CloseAccountWithEnabledTokensException();
    /// @notice Emitted when a new credit account is opened
    event OpenCreditAccount(
        address indexed creditAccount,
        address indexed onBehalfOf,
        address indexed caller
        // uint256 referralCode
    );

    /// @notice Emitted when account is closed
    event CloseCreditAccount(
        address indexed creditAccount,
        address indexed borrower
    );

    /// @notice Emitted when account's debt is increased
    event IncreaseDebt(address indexed creditAccount, uint256 amount);

    /// @notice Emitted when account's debt is decreased
    event DecreaseDebt(address indexed creditAccount, uint256 amount);

    /// @notice Emitted when collateral is added to account
    event AddCollateral(
        address indexed creditAccount,
        address indexed token,
        uint256 amount
    );

    /// @notice Emitted when collateral is withdrawn from account
    event WithdrawCollateral(
        address indexed creditAccount,
        address indexed token,
        uint256 amount,
        address to
    );

    /// @notice Emitted when a multicall is started
    event StartMultiCall(address indexed creditAccount, address indexed caller);

    /// @notice Emitted when a call from account to an external contract is made during a multicall
    event Execute(
        address indexed creditAccount,
        address indexed targetContract
    );

    /// @notice Emitted when a multicall is finished
    event FinishMultiCall();
    /// @notice Thrown on attempting to call an access restricted function not as credit account owner
    error CallerNotCreditAccountOwnerException();
    /// @notice Thrown if balance of at least one token is less than expected during a slippage check
    error BalanceLessThanExpectedException();
    /// @notice Thrown on attempting to interact with an address that is not a valid target contract
    error TargetContractNotAllowedException();
    /// @notice Thrown if a selector that doesn't match any allowed function is passed to the credit facade in a multicall
    error UnknownMethodException();
    /// @notice Thrown when submitted collateral hint is not a valid token mask
    error InvalidCollateralHintException();
    /// @notice Thrown if attempting to perform a slippage check when excepted balances are not set
    error ExpectedBalancesNotSetException();
    /// @notice Thrown if expected balances are attempted to be set twice without performing a slippage check
    error ExpectedBalancesAlreadySetException();
    /// @notice Thrown when trying to perform an action that is forbidden when credit account has enabled forbidden tokens
    error ForbiddenTokensException();

    function creditManager() external view returns (address);




    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(
        address onBehalfOf
    ) external payable returns (address creditAccount);

    function multicall(
        address creditAccount,
        MultiCall[] calldata calls
    ) external;


    // ------------- //
    // CONFIGURATION //
    // ------------- //
}
