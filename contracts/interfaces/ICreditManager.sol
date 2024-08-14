// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

address constant INACTIVE_CREDIT_ACCOUNT_ADDRESS = address(1);
uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals
uint8 constant DEFAULT_MAX_ENABLED_TOKENS = 4;

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
///         - `GENERIC_PARAMS` returns generic data like account debt and cumulative indexes
///         - `DEBT_ONLY` is same as `GENERIC_PARAMS` but includes more detailed debt info, like accrued base/quota
///           interest and fees
///         - `FULL_COLLATERAL_CHECK_LAZY` checks whether account is sufficiently collateralized in a lazy fashion,
///           i.e. it stops iterating over collateral tokens once TWV reaches the desired target.
///           Since it may return underestimated TWV, it's only available for internal use.
///         - `DEBT_COLLATERAL` is same as `DEBT_ONLY` but also returns total value and total LT-weighted value of
///           account's tokens, this mode is used during account liquidation
///         - `DEBT_COLLATERAL_SAFE_PRICES` is same as `DEBT_COLLATERAL` but uses safe prices from price oracle
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
    uint128 cumulativeQuotaInterest;
    uint128 quotaFees;
    uint256 enabledTokensMask;
    uint16 flags;
    uint64 lastDebtUpdate;
    address borrower;
}

struct CollateralTokenData {
    address token; // The address of the collateral token.
    uint16 ltInitial;          // Initial liquidation threshold (in basis points).
    uint16 ltFinal;            // Final liquidation threshold (in basis points) after the ramp period.
    uint40 timestampRampStart; // The start timestamp for the ramp period when the liquidation threshold starts changing.
    uint24 rampDuration;       // Duration (in seconds) over which the liquidation threshold changes from ltInitial to ltFinal.
}

struct CollateralDebtData {
    uint256 debt;
    uint256 cumulativeIndexNow;
    uint256 cumulativeIndexLastUpdate;
    uint128 cumulativeQuotaInterest;
    uint256 accruedInterest;
    uint256 accruedFees;
    uint256 totalDebtUSD;
    uint256 totalValue;
    uint256 totalValueUSD;
    uint256 twvUSD;
    uint256 enabledTokensMask;
    uint256 quotedTokensMask;
    address[] quotedTokens;
    address _poolQuotaKeeper;
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

    function closeCreditAccount(address creditAccount) external;

    // function liquidateCreditAccount(
    //     address creditAccount,
    //     CollateralDebtData calldata collateralDebtData,
    //     address to,
    //     bool isExpired
    // ) external returns (uint256 remainingFunds, uint256 loss);

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

    function revokeAdapterAllowances(
        address creditAccount,
        RevocationPair[] calldata revocations
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
        uint256 enabledTokensMask,
        uint256[] calldata collateralHints
    )
        external
        returns (
            // uint16 minHealthFactor,
            // bool useSafePrices
            uint256 enabledTokensMaskAfter
        );

    // function isLiquidatable(
    //     address creditAccount,
    //     uint16 minHealthFactor
    // ) external view returns (bool);

    function calcDebtAndCollateral(
        address creditAccount,
        CollateralCalcTask task
    ) external returns (CollateralDebtData memory cdd);

    // ------ //
    // QUOTAS //
    // ------ //

    // function poolQuotaKeeper() external view returns (address);

    function quotedTokensMask() external view returns (uint256);

    // function updateQuota(address creditAccount, address token, int96 quotaChange, uint96 minQuota, uint96 maxQuota)
    //     external
    //     returns (uint256 tokensToEnable, uint256 tokensToDisable);

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    function maxEnabledTokens() external view returns (uint8);

    function fees()
        external
        view
        returns (
            uint16 feeInterest,
            uint16 feeLiquidation,
            uint16 liquidationDiscount,
            uint16 feeLiquidationExpired,
            uint16 liquidationDiscountExpired
        );

    function collateralTokensCount() external view returns (uint8);

    function getTokenMaskOrRevert(
        address token
    ) external view returns (uint256 tokenMask);

    function getTokenByMask(
        uint256 tokenMask
    ) external view returns (address token);

    // function liquidationThresholds(
    //     address token
    // ) external view returns (uint16 lt);

    function ltParams(
        address token
    )
        external
        view
        returns (
            uint16 ltInitial,
            uint16 ltFinal,
            uint40 timestampRampStart,
            uint24 rampDuration
        );

    function collateralTokenByMask(
        uint256 tokenMask
    ) external view returns (address token);

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
            uint128 cumulativeQuotaInterest,
            uint128 quotaFees,
            uint256 enabledTokensMask,
            uint16 flags,
            uint64 lastDebtUpdate,
            address borrower
        );

    function getBorrowerOrRevert(
        address creditAccount
    ) external view returns (address borrower);

    // function flagsOf(address creditAccount) external view returns (uint16);

    // function setFlagFor(address creditAccount, uint16 flag, bool value) external;

    function enabledTokensMaskOf(
        address creditAccount
    ) external view returns (uint256);

    function creditAccounts() external view returns (address[] memory);

    function creditAccounts(
        uint256 offset,
        uint256 limit
    ) external view returns (address[] memory);

    function creditAccountsLen() external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function addToken(address token) external;

    function setCollateralTokenData(
        address token,
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    ) external;

    function setFees(
        uint16 feeInterest,
        uint16 feeLiquidation,
        uint16 liquidationDiscount,
        uint16 feeLiquidationExpired,
        uint16 liquidationDiscountExpired
    ) external;

    // Exclusion of base tokens
    // function setQuotedMask(uint256 quotedTokensMask) external;

    function setMaxEnabledTokens(uint8 maxEnabledTokens) external;

    function setContractAllowance(
        address adapter,
        address targetContract
    ) external;

    function setCreditFacade(address) external;

    function setPriceOracle(address priceOracle) external;

    // function setCreditConfigurator(address creditConfigurator) external;
}
