pragma solidity ^0.8.24;

import "../interfaces/ICreditManager.sol";
import "../interfaces/ICreditAccount.sol";
import "../interfaces/IAccountFactory.sol";
import "../interfaces/IAddressProvider.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CollateralLogic} from "../libraries/CollateralLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";
import {IPool} from "../interfaces/IPool.sol";

contract CreditManager is ICreditManager, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using Math for uint256;
    using CreditLogic for CollateralDebtData;
    using CollateralLogic for CollateralDebtData;
    using SafeERC20 for IERC20;
    using CreditAccountHelper for ICreditAccount;

    /// @notice Address provider contract address
    address public immutable  addressProvider;

    /// @notice Account factory contract address
    address public immutable  accountFactory;

    /// @notice Underlying token address
    address public immutable  underlying;

    /// @notice Address of the pool credit manager is connected to
    address public immutable  pool;

    /// @notice Address of the connected credit facade
    address public  creditFacade;

    /// @notice Address of the connected credit configurator
    address public  creditConfigurator;

    /// @notice Price oracle contract address
    address public  priceOracle;

    /// @notice Maximum number of tokens that a credit account can have enabled as collateral
    uint8 public  maxEnabledTokens = DEFAULT_MAX_ENABLED_TOKENS;

    /// @notice Number of known collateral tokens
    uint8 public  collateralTokensCount;

    /// @dev Liquidation threshold for the underlying token in bps
    uint16 internal ltUnderlying;

    /// @dev Percentage of accrued interest in bps taken by the protocol as profit
    uint16 internal feeInterest;

    /// @dev Percentage of liquidated account value in bps taken by the protocol as profit
    uint16 internal feeLiquidation;

    /// @dev Percentage of liquidated account value in bps that is used to repay debt
    uint16 internal liquidationDiscount;

    /// @dev Percentage of liquidated expired account value in bps taken by the protocol as profit
    uint16 internal feeLiquidationExpired;

    /// @dev Percentage of liquidated expired account value in bps that is used to repay debt
    uint16 internal liquidationDiscountExpired;

    /// @dev Active credit account which is an account adapters can interfact with
    address internal _activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    /// @notice Bitmask of quoted tokens
    uint256 public  quotedTokensMask;

    /// @dev Mapping collateral token mask => data (packed address and LT parameters)
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

    /// @dev Mapping collateral token address => mask
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// @notice Mapping adapter => target contract
    mapping(address => address) public  adapterToContract;

    /// @notice Mapping target contract => adapter
    mapping(address => address) public  contractToAdapter;

    /// @notice Mapping credit account => account info (owner, debt amount, etc.)
    mapping(address => CreditAccountInfo) public  creditAccountInfo;

    /// @dev Set of all credit accounts opened in this credit manager
    EnumerableSet.AddressSet internal creditAccountsSet;

    /// @notice Credit manager name
    string public  name;

    /// @dev Ensures that function caller is the credit facade
    modifier creditFacadeOnly() {
        _checkCreditFacade();
        _;
    }

    /// @dev Ensures that function caller is the credit configurator
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address provider contract address
    /// @param _pool Address of the lending pool to connect this credit manager to
    /// @param _name Credit manager name
    /// @dev Adds pool's underlying as collateral token with LT = 0
    /// @dev Sets `msg.sender` as credit configurator
    constructor(address _addressProvider, address _pool, string memory _name) {
        addressProvider = _addressProvider;
        pool = _pool;

        underlying = IPool(_pool).underlyingToken();
        _addToken(underlying);

        priceOracle = IAddressProvider(addressProvider).getAddressOrRevert(
            AP_PRICE_ORACLE
        );
        accountFactory = IAddressProvider(addressProvider).getAddressOrRevert(
                AP_ACCOUNT_FACTORY
            );

        creditConfigurator = msg.sender;

        name = _name;
    }

    /// @notice Opens a new credit account
    /// @param onBehalfOf Owner of a newly opened credit account
    /// @return creditAccount Address of the newly opened credit account
    function openCreditAccount(
        address onBehalfOf
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (address creditAccount)
    {
        creditAccount = IAccountFactory(accountFactory).takeCreditAccount();

        CreditAccountInfo storage newCreditAccountInfo = creditAccountInfo[
            creditAccount
        ];
        newCreditAccountInfo.borrower = onBehalfOf;
        newCreditAccountInfo.cumulativeQuotaInterest = 1;
        creditAccountsSet.add(creditAccount);
    }

    /// @notice Closes a credit account
    /// @param creditAccount Account to close
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function closeCreditAccount(
        address creditAccount
    ) external override nonReentrant creditFacadeOnly {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[
            creditAccount
        ];
        if (currentCreditAccountInfo.debt != 0) {
            revert CloseAccountWithNonZeroDebtException();
        }

        currentCreditAccountInfo.borrower = address(0);

        currentCreditAccountInfo.enabledTokensMask = 0;

        IAccountFactory(accountFactory).returnCreditAccount({
            creditAccount: creditAccount
        });
        creditAccountsSet.remove(creditAccount);
    }

    /// @notice Increases or decreases credit account's debt
    /// @param creditAccount Account to increase/decrease debr for
    /// @param amount Amount of underlying to change the total debt by
    /// @param enabledTokensMask  Bitmask of account's enabled collateral tokens
    /// @param action Manage debt type, see `ManageDebtAction`
    /// @return newDebt Debt principal after update
    /// @return tokensToEnable Tokens that should be enabled after the operation
    ///         (underlying mask on increase, zero on decrease)
    /// @return tokensToDisable Tokens that should be disabled after the operation
    ///         (zero on increase, underlying mask on decrease if account has no underlying after repayment)
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function manageDebt(
        address creditAccount,
        uint256 amount,
        uint256 enabledTokensMask,
        ManageDebtAction action
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (
            uint256 newDebt,
            uint256 tokensToEnable,
            uint256 tokensToDisable
        )
    {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[
            creditAccount
        ];
        if (currentCreditAccountInfo.lastDebtUpdate == block.number) {
            revert DebtUpdatedTwiceInOneBlockException();
        }
        if (amount == 0) return (currentCreditAccountInfo.debt, 0, 0);

        uint256[] memory collateralHints;
        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            collateralHints: collateralHints,
            minHealthFactor: PERCENTAGE_FACTOR,
            task: CollateralCalcTask.GENERIC_PARAMS,
            useSafePrices: false
        });

        uint256 newCumulativeIndex;
        if (action == ManageDebtAction.INCREASE_DEBT) {
            (newDebt, newCumulativeIndex) = CreditLogic.calcIncrease({
                amount: amount,
                debt: collateralDebtData.debt,
                cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                cumulativeIndexLastUpdate: collateralDebtData
                    .cumulativeIndexLastUpdate
            });

            _poolLendCreditAccount(amount, creditAccount);
            tokensToEnable = UNDERLYING_TOKEN_MASK;
        } else {
            uint256 maxRepayment = _amountWithFee(
                collateralDebtData.calcTotalDebt()
            );
            if (amount >= maxRepayment) {
                amount = maxRepayment;
            }

            ICreditAccount(creditAccount).safeTransfer({
                token: underlying,
                to: pool,
                amount: amount
            });

            if (amount == maxRepayment) {
                newDebt = 0;
                newCumulativeIndex = collateralDebtData.cumulativeIndexNow;
            } else {
                (newDebt, newCumulativeIndex) = CreditLogic.calcDecrease({
                    amount: _amountMinusFee(amount),
                    debt: collateralDebtData.debt,
                    cumulativeIndexNow: collateralDebtData.cumulativeIndexNow,
                    cumulativeIndexLastUpdate: collateralDebtData
                        .cumulativeIndexLastUpdate
                });
            }

            if (
                IERC20(underlying).balanceOf({account: creditAccount}) <= 1
            ) {
                tokensToDisable = UNDERLYING_TOKEN_MASK;
            }
        }

        currentCreditAccountInfo.debt = newDebt;
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number);
        currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex;
    }

    /// @dev `addToken` implementation:
    ///      - Ensures that token is not already added
    ///      - Forbids adding more than 255 collateral tokens
    ///      - Adds token with LT = 0
    ///      - Increases the number of collateral tokens
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        
    }

    /// @dev Returns amount of token that should be transferred to receive `amount`
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountWithFee(
        uint256 amount
    ) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that will be received if `amount` is transferred
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountMinusFee(
        uint256 amount
    ) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Internal wrapper for `pool.lendCreditAccount` call to reduce contract size
    function _poolLendCreditAccount(
        uint256 amount,
        address creditAccount
    ) internal {
        IPool(pool).lendCreditAccount(amount, creditAccount);
    }

    /// @dev `calcDebtAndCollateral` implementation
    /// @param creditAccount Credit account to return data for
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks specifying the order of checking collateral tokens
    /// @param minHealthFactor Health factor in bps to stop the calculations after when performing collateral check
    /// @param task Calculation mode, see `CollateralCalcTask` for details
    /// @param useSafePrices Whether to use safe prices when evaluating collateral
    /// @return cdd A struct with debt and collateral data
    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
        uint16 minHealthFactor,
        CollateralCalcTask task,
        bool useSafePrices
    ) internal view returns (CollateralDebtData memory cdd) {
        CreditAccountInfo storage currentCreditAccountInfo = creditAccountInfo[
            creditAccount
        ];

        cdd.debt = currentCreditAccountInfo.debt;
        cdd.cumulativeIndexLastUpdate = currentCreditAccountInfo
            .cumulativeIndexLastUpdate;
        cdd.cumulativeIndexNow = IPool(pool).baseInterestIndex();

        if (task == CollateralCalcTask.GENERIC_PARAMS) {
            return cdd;
        }

        //other CollateralCalcTask
    }

    function setCreditFacade(
        address _creditFacade
    )
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        creditFacade = _creditFacade; // U:[CM-46]
    }

    function _checkCreditFacade() private view {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
    }

    /// @dev Reverts if `msg.sender` is not the credit configurator
    function _checkCreditConfigurator() private view {
        if (msg.sender != creditConfigurator)
            revert CallerNotConfiguratorException();
    }
}
