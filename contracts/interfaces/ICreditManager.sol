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
    // uint16 ltInitial;          // Initial liquidation threshold (in basis points).
    // uint16 ltFinal;            // Final liquidation threshold (in basis points) after the ramp period.
    // uint40 timestampRampStart; // The start timestamp for the ramp period when the liquidation threshold starts changing.
    // uint24 rampDuration;       // Duration (in seconds) over which the liquidation threshold changes from ltInitial to ltFinal.
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

    function openCreditAccount(address onBehalfOf) external returns (address);

    function closeCreditAccount(address creditAccount) external;

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

    function setCreditFacade(address _creditFacade) external;

    function addCollateral(
        address payer,
        address creditAccount,
        address token,
        uint256 amount
    ) external returns (uint256);

    function getTokenMaskOrRevert(
        address token
    ) external returns (uint256 tokenMask);

    function withdrawCollateral(
        address creditAccount,
        address token,
        uint256 amount,
        address to
    ) external returns (uint256);

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

    function approveCreditAccount(address token, uint256 amount) external;

    function getActiveCreditAccountOrRevert()
        external
        returns (address creditAccount);

    function execute(
        bytes calldata data
    ) external returns (bytes memory result);

    function setActiveCreditAccount(address creditAccount) external;

    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] calldata collateralHints,
        uint16 minHealthFactor
    ) external returns (uint256 enabledTokensMaskAfter);
}
