// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ICreditManager.sol";
import "../interfaces/ICreditAccount.sol";
import "../interfaces/IAccountFactory.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/IPriceOracle.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import {CreditAccountHelper} from "../libraries/CreditAccountHelper.sol";
import {ICreditAccount} from "../interfaces/ICreditAccount.sol";
import {IPool} from "../interfaces/IPool.sol";

contract CreditManager is ICreditManager, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;
    using BitMask for uint256;
    using Math for uint256;
    using CreditLogic for CollateralDebtData;
    using SafeERC20 for IERC20;
    using CreditAccountHelper for ICreditAccount;

    /// @notice Address provider contract address
    address public immutable addressProvider;

    /// @notice Account factory contract address
    address public immutable accountFactory;

    /// @notice Underlying token address
    address public immutable underlying;

    /// @notice Address of the pool credit manager is connected to
    address public immutable pool;

    /// @notice Address of the connected credit facade
    address public creditFacade;

    /// @notice Price oracle contract address
    address public priceOracle;

    /// @notice Number of known collateral tokens
    uint8 public collateralTokensCount;

    /// @dev Active credit account which is an account adapters can interfact with
    address internal _activeCreditAccount = INACTIVE_CREDIT_ACCOUNT_ADDRESS;

    /// @dev Mapping collateral token address => mask
    mapping(address => uint256) internal tokenMasksMapInternal;

    /// @notice Mapping adapter => target contract
    mapping(address => address) public adapterToContract;

    /// @notice Mapping target contract => adapter
    mapping(address => address) public contractToAdapter;

    /// @notice Mapping credit account => account info (owner, debt amount, etc.)
    mapping(address => CreditAccountInfo) public creditAccountInfo;

    /// @dev Set of all credit accounts opened in this credit manager
    EnumerableSet.AddressSet internal creditAccountsSet;

    /// @dev Ensures that function caller is the credit facade
    modifier creditFacadeOnly() {
        _checkCreditFacade();
        _;
    }

    /// @notice Constructor
    constructor(address _addressProvider, address _pool) {
        addressProvider = _addressProvider;
        pool = _pool;

        underlying = IPool(_pool).underlyingToken();
        _addToken(underlying);

        // priceOracle = IAddressProvider(addressProvider).getAddressOrRevert(
        //     AP_PRICE_ORACLE
        // );

        accountFactory = IAddressProvider(addressProvider).getAddressOrRevert(
            AP_ACCOUNT_FACTORY
        );
    }

    function name() external pure override returns (string memory) {
        return "CreditManager";
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
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
        creditAccountsSet.add(creditAccount);
    }

    /// @notice Increases or decreases credit account's debt
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

        CollateralDebtData memory collateralDebtData = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            task: CollateralCalcTask.GENERIC_PARAMS
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

            if (IERC20(underlying).balanceOf({account: creditAccount}) <= 1) {
                tokensToDisable = UNDERLYING_TOKEN_MASK;
            }
        }

        currentCreditAccountInfo.debt = newDebt;
        currentCreditAccountInfo.lastDebtUpdate = uint64(block.number);
        currentCreditAccountInfo.cumulativeIndexLastUpdate = newCumulativeIndex;
    }

    /// @notice Adds `amount` of `payer`'s `token` as collateral to `creditAccount`
    function addCollateral(
        address payer,
        address creditAccount,
        address token,
        uint256 amount
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (uint256 tokensToEnable)
    {
        tokensToEnable = getTokenMaskOrRevert({token: token});
        IERC20(token).safeTransferFrom({
            from: payer,
            to: creditAccount,
            value: amount
        });
    }

    /// @notice Withdraws `amount` of `token` collateral from `creditAccount` to `to`
    function withdrawCollateral(
        address creditAccount,
        address token,
        uint256 amount,
        address to
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (uint256 tokensToDisable)
    {
        uint256 tokenMask = getTokenMaskOrRevert({token: token});

        ICreditAccount(creditAccount).safeTransfer({
            token: token,
            to: to,
            amount: amount
        });

        if (IERC20(token).balanceOf({account: creditAccount}) <= 1) {
            tokensToDisable = tokenMask;
        }
    }

    /// @notice Instructs `creditAccount` to make an external call to target with `callData`
    function externalCall(
        address creditAccount,
        address target,
        bytes calldata callData
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (bytes memory result)
    {
        return _execute(creditAccount, target, callData);
    }

    /// @notice Instructs `creditAccount` to approve `amount` of `token` to `spender`
    function approveToken(
        address creditAccount,
        address token,
        address spender,
        uint256 amount
    ) external override nonReentrant creditFacadeOnly {
        _approveSpender({
            creditAccount: creditAccount,
            token: token,
            spender: spender,
            amount: amount
        });
    }

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Instructs active credit account to approve `amount` of `token` to adapter's target contract
    function approveCreditAccount(
        address token,
        uint256 amount
    ) external override nonReentrant {
        address targetContract = _getTargetContractOrRevert();
        address creditAccount = getActiveCreditAccountOrRevert();
        _approveSpender({
            creditAccount: creditAccount,
            token: token,
            spender: targetContract,
            amount: amount
        });
    }

    /// @notice Instructs active credit account to call adapter's target contract with provided data
    function execute(
        bytes calldata data
    ) external override nonReentrant returns (bytes memory result) {
        address targetContract = _getTargetContractOrRevert();
        address creditAccount = getActiveCreditAccountOrRevert();
        return _execute(creditAccount, targetContract, data);
    }

    /// @notice Sets/unsets active credit account adapters can interact with
    function setActiveCreditAccount(
        address creditAccount
    ) external override nonReentrant creditFacadeOnly {
        _activeCreditAccount = creditAccount;
    }

    /// @notice Returns active credit account, reverts if it is not set
    function getActiveCreditAccountOrRevert()
        public
        view
        override
        returns (address creditAccount)
    {
        creditAccount = _activeCreditAccount;
        if (creditAccount == INACTIVE_CREDIT_ACCOUNT_ADDRESS) {
            revert ActiveCreditAccountNotSetException();
        }
    }

    // ----------------- //
    // COLLATERAL CHECKS //
    // ----------------- //

    /// @notice Performs full check of `creditAccount`'s collateral to ensure it is sufficiently collateralized,
    ///         might disable tokens with zero balances
    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (uint256 enabledTokensMaskAfter)
    {
        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMask,
            task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY
        });
        enabledTokensMaskAfter = cdd.enabledTokensMask;
        _saveEnabledTokensMask(creditAccount, enabledTokensMaskAfter);
    }

    /// @notice Returns `creditAccount`'s debt and collateral data with level of detail controlled by `task`
    /// @param creditAccount Credit account to return data for
    /// @param task Calculation mode, see `CollateralCalcTask` for details, can't be `FULL_COLLATERAL_CHECK_LAZY`
    /// @return cdd A struct with debt and collateral data
    /// @dev Reverts if account is not opened in this credit manager
    function calcDebtAndCollateral(
        address creditAccount,
        CollateralCalcTask task
    ) external override returns (CollateralDebtData memory cdd) {
        getBorrowerOrRevert(creditAccount);

        cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            task: task
        });
    }

    // ------------ //
    // ACCOUNT INFO //
    // ------------ //

    /// @notice Returns an array of all credit accounts opened in this credit manager
    function creditAccounts()
        external
        view
        override
        returns (address[] memory)
    {
        return creditAccountsSet.values();
    }

    /// @notice Returns the number of open credit accounts opened in this credit manager
    function creditAccountsLen() external view override returns (uint256) {
        return creditAccountsSet.length();
    }

    /// @notice Returns `creditAccount`'s owner or reverts if account is not opened in this credit manager
    function getBorrowerOrRevert(
        address creditAccount
    ) public view override returns (address borrower) {
        borrower = creditAccountInfo[creditAccount].borrower;
        if (borrower == address(0)) revert CreditAccountDoesNotExistException();
    }

    /// @notice Returns `creditAccount`'s enabled tokens mask
    function enabledTokensMaskOf(
        address creditAccount
    ) public view override returns (uint256) {
        return creditAccountInfo[creditAccount].enabledTokensMask;
    }

    /// @notice Returns `token`'s collateral mask in the credit manager
    /// @param token Token address
    /// @return tokenMask Collateral token mask in the credit manager
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function getTokenMaskOrRevert(
        address token
    ) public view override returns (uint256 tokenMask) {
        if (token == underlying) return UNDERLYING_TOKEN_MASK;

        tokenMask = tokenMasksMapInternal[token];
        if (tokenMask == 0) revert TokenNotAllowedException();
    }

    function setCreditFacade(address _creditFacade) external override {
        creditFacade = _creditFacade;
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds `token` to the list of collateral tokens, see `_addToken` for details
    function addToken(address token) external override {
        _addToken(token);
    }

    /// @notice Sets the link between the adapter and the target contract
    function setContractAllowance(
        address adapter,
        address targetContract
    ) external override {
        adapterToContract[adapter] = targetContract;
        contractToAdapter[targetContract] = adapter;
    }

    /// @notice Sets a new price oracle
    // function setPriceOracle(
    //     address _priceOracle
    // )
    //     external
    //     override
    // {
    //     priceOracle = _priceOracle;
    // }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Saves `creditAccount`'s `enabledTokensMask` in the storage
    function _saveEnabledTokensMask(
        address creditAccount,
        uint256 enabledTokensMask
    ) internal {
        creditAccountInfo[creditAccount].enabledTokensMask = enabledTokensMask;
    }

    /// @dev Returns adapter's target contract, reverts if `msg.sender` is not a registered adapter
    function _getTargetContractOrRevert()
        internal
        view
        returns (address targetContract)
    {
        targetContract = adapterToContract[msg.sender]; // U:[CM-15, 16]
        if (targetContract == address(0)) {
            revert CallerNotAdapterException(); // U:[CM-3]
        }
    }

    /// @dev Approves `amount` of `token` from `creditAccount` to `spender`
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function _approveSpender(
        address creditAccount,
        address token,
        address spender,
        uint256 amount
    ) internal {
        getTokenMaskOrRevert({token: token});
        ICreditAccount(creditAccount).safeApprove({
            token: token,
            spender: spender,
            amount: amount
        });
    }

    /// @dev Internal wrapper for `creditAccount.execute` call to reduce contract size
    function _execute(
        address creditAccount,
        address target,
        bytes calldata callData
    ) internal returns (bytes memory) {
        return ICreditAccount(creditAccount).execute(target, callData);
    }

    /// @dev `addToken` implementation:
    ///      - Ensures that token is not already added
    ///      - Forbids adding more than 255 collateral tokens
    ///      - Adds token with LT = 0
    ///      - Increases the number of collateral tokens
    /// @param token Address of the token to add
    function _addToken(address token) internal {
        if (tokenMasksMapInternal[token] != 0) {
            revert TokenAlreadyAddedException();
        }
        if (collateralTokensCount >= 255) {
            revert TooManyTokensException();
        }

        uint256 tokenMask = 1 << collateralTokensCount;
        tokenMasksMapInternal[token] = tokenMask;

        // collateralTokensData[tokenMask].token = token;
        // collateralTokensData[tokenMask].timestampRampStart = type(uint40).max;

        unchecked {
            ++collateralTokensCount;
        }
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

    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        CollateralCalcTask task
    ) internal returns (CollateralDebtData memory cdd) {
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

        cdd.enabledTokensMask = enabledTokensMask;

        cdd.accruedInterest = CreditLogic.calcAccruedInterest({
            amount: cdd.debt,
            cumulativeIndexLastUpdate: cdd.cumulativeIndexLastUpdate,
            cumulativeIndexNow: cdd.cumulativeIndexNow
        });

        if (task == CollateralCalcTask.DEBT_ONLY) {
            return cdd;
        }
    }

    // function _collateralTokenByMask(
    //     uint256 tokenMask
    // ) internal view returns (address token) {
    //     if (tokenMask == UNDERLYING_TOKEN_MASK) {
    //         token = underlying;
    //     } else {
    //         CollateralTokenData storage tokenData = collateralTokensData[
    //             tokenMask
    //         ];

    //         bytes32 rawData;
    //         assembly {
    //             rawData := sload(tokenData.slot)
    //             token := and(
    //                 rawData,
    //                 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    //             )
    //         }

    //         if (token == address(0)) {
    //             revert TokenNotAllowedException();
    //         }
    //     }
    // }

    function _checkCreditFacade() private view {
        if (msg.sender != creditFacade) revert CallerNotCreditFacadeException();
    }
}
