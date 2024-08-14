// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

address constant INACTIVE_CREDIT_ACCOUNT_ADDRESS = address(1);
uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals

/// @notice Debt management type
///         - `INCREASE_DEBT` borrows additional funds from the pool, updates account's debt and cumulative interest index
///         - `DECREASE_DEBT` repays debt components (quota interest and fees -> base interest and fees -> debt principal)
///           and updates all corresponding state varibles (base interest index, quota interest and fees, debt).
///           When repaying all the debt, ensures that account has no enabled quotas.
enum ManageDebtAction {
    INCREASE_DEBT,
    DECREASE_DEBT
}

/// @notice Collateral/debt calculation mode
enum CollateralCalcTask {
    GENERIC_PARAMS,
    DEBT_ONLY,
    FULL_COLLATERAL_CHECK_LAZY,
    DEBT_COLLATERAL,
    DEBT_COLLATERAL_SAFE_PRICES
}

struct CreditAccountInfo {
    uint256 debt;
    uint256 cumulativeIndexLastUpdate;
    uint256 enabledTokensMask;
    uint64 lastDebtUpdate;
    address borrower;
}

struct CollateralDebtData {
    uint256 debt;
    uint256 cumulativeIndexNow;
    uint256 cumulativeIndexLastUpdate;
    uint256 accruedInterest;
    uint256 totalValue;
    uint256 enabledTokensMask;
    uint256 quotedTokensMask;
    address[] quotedTokens;
}

struct RevocationPair {
    address spender;
    address token;
}

interface ICreditManager {
    /// @notice Thrown when attempting to close an account with non-zero debt
    error CloseAccountWithNonZeroDebtException();
    /// @notice Thrown when trying to update credit account's debt more than once in the same block
    error DebtUpdatedTwiceInOneBlockException();
    /// @notice Thrown on attempting to call an access restricted function not as configurator
    error CallerNotConfiguratorException();
    /// @notice Thrown on attempting to call an access restricted function not as credit facade
    error CallerNotCreditFacadeException();
    /// @notice Thrown on attempting to receive a token that is not a collateral token or was forbidden
    error TokenNotAllowedException();
    /// @notice Thrown on attempting to set an important address to zero address
    error ZeroAddressException();
    /// @notice Thrown on attempting to call an access restricted function not as allowed adapter
    error CallerNotAdapterException();
    /// @notice Thrown when attempting to execute a protocol interaction without active credit account set
    error ActiveCreditAccountNotSetException();
    /// @notice Thrown when Credit Facade tries to write over a non-zero active Credit Account
    error ActiveCreditAccountOverridenException();
    /// @notice Thrown on failing a full collateral check after multicall
    error NotEnoughCollateralException();
    /// @notice Thrown if more than the maximum number of tokens were enabled on a credit account
    error TooManyEnabledTokensException();
    /// @notice Thrown on incorrect input parameter
    error IncorrectParameterException();
    /// @notice Thrown on attempting to perform an action for a credit account that does not exist
    error CreditAccountDoesNotExistException();
    /// @notice Thrown on attempting to add a token that is already in a collateral list
    error TokenAlreadyAddedException();
    /// @notice Thrown on configurator attempting to add more than 255 collateral tokens
    error TooManyTokensException();

    function pool() external view returns (address);

    function underlying() external view returns (address);

    function creditFacade() external view returns (address);

    // function creditConfigurator() external view returns (address);

    function addressProvider() external view returns (address);

    function accountFactory() external view returns (address);

    function name() external view returns (string memory);

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    function openCreditAccount(address onBehalfOf) external returns (address);


    function manageDebt(
        address creditAccount,
        uint256 amount,
        uint256 enabledTokensMask,
        ManageDebtAction action
    )
        external
        returns (
            uint256 newDebt,
            uint256 tokensToEnable,
            uint256 tokensToDisable
        );

    function addCollateral(
        address payer,
        address creditAccount,
        address token,
        uint256 amount
    ) external returns (uint256 tokensToEnable);

    function withdrawCollateral(
        address creditAccount,
        address token,
        uint256 amount,
        address to
    ) external returns (uint256 tokensToDisable);

    function externalCall(
        address creditAccount,
        address target,
        bytes calldata callData
    ) external returns (bytes memory result);

    function approveToken(
        address creditAccount,
        address token,
        address spender,
        uint256 amount
    ) external;

    // -------- //
    // ADAPTERS //
    // -------- //

    function adapterToContract(
        address adapter
    ) external view returns (address targetContract);

    function contractToAdapter(
        address targetContract
    ) external view returns (address adapter);

    function execute(
        bytes calldata data
    ) external returns (bytes memory result);

    function approveCreditAccount(address token, uint256 amount) external;

    function setActiveCreditAccount(address creditAccount) external;

    function getActiveCreditAccountOrRevert()
        external
        view
        returns (address creditAccount);

    // ----------------- //
    // COLLATERAL CHECKS //
    // ----------------- //

    function priceOracle() external view returns (address);

    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask
    ) external returns (uint256 enabledTokensMaskAfter);

    function calcDebtAndCollateral(
        address creditAccount,
        CollateralCalcTask task
    ) external returns (CollateralDebtData memory cdd);

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    function collateralTokensCount() external view returns (uint8);

    function getTokenMaskOrRevert(
        address token
    ) external view returns (uint256 tokenMask);

    // ------------ //
    // ACCOUNT INFO //
    // ------------ //

    function creditAccountInfo(
        address creditAccount
    )
        external
        view
        returns (
            uint256 debt,
            uint256 cumulativeIndexLastUpdate,
            uint256 enabledTokensMask,
            uint64 lastDebtUpdate,
            address borrower
        );

    function getBorrowerOrRevert(
        address creditAccount
    ) external view returns (address borrower);

    function enabledTokensMaskOf(
        address creditAccount
    ) external view returns (uint256);

    function creditAccounts() external view returns (address[] memory);

    function creditAccountsLen() external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function addToken(address token) external;

    function setContractAllowance(
        address adapter,
        address targetContract
    ) external;

    function setCreditFacade(address) external;

    // function setPriceOracle(address priceOracle) external;
}
