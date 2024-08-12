// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/ICreditManager.sol";
import "../interfaces/ICreditAccount.sol";
import "../interfaces/IAccountFactory.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/IPriceOracle.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UNDERLYING_TOKEN_MASK, BitMask} from "../libraries/BitMask.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import "../libraries/CollateralLogic.sol";
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
    address public immutable addressProvider;

    /// @notice Account factory contract address
    address public immutable accountFactory;

    /// @notice Underlying token address
    address public immutable underlying;

    /// @notice Address of the pool credit manager is connected to
    address public immutable pool;

    /// @notice Address of the connected credit facade
    address public creditFacade;

    /// @notice Address of the connected credit configurator
    address public creditConfigurator;

    /// @notice Price oracle contract address
    address public priceOracle;

    /// @notice Maximum number of tokens that a credit account can have enabled as collateral
    uint8 public maxEnabledTokens = DEFAULT_MAX_ENABLED_TOKENS;

    /// @notice Number of known collateral tokens
    uint8 public collateralTokensCount;

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
    uint256 public quotedTokensMask;

    /// @dev Mapping collateral token mask => data (packed address and LT parameters)
    mapping(uint256 => CollateralTokenData) internal collateralTokensData;

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

    /// @dev Ensures that function caller is the credit configurator
    modifier creditConfiguratorOnly() {
        _checkCreditConfigurator();
        _;
    }

    /// @notice Constructor
    /// @param _addressProvider Address provider contract address
    /// @param _pool Address of the lending pool to connect this credit manager to
    /// @dev Adds pool's underlying as collateral token with LT = 0
    /// @dev Sets `msg.sender` as credit configurator
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

        creditConfigurator = msg.sender;
    }

    function name() external pure override returns (string memory) {
        return "CreditManager";
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

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
    /// @param payer Address to transfer token from
    /// @param creditAccount Account to add collateral to
    /// @param token Token to add as collateral
    /// @param amount Amount to add
    /// @return tokensToEnable Mask of tokens that should be enabled after the operation (always `token` mask)
    /// @dev Requires approval for `token` from `payer` to this contract
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
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
    /// @param creditAccount Credit account to withdraw collateral from
    /// @param token Token to withdraw
    /// @param amount Amount to withdraw
    /// @param to Address to transfer token to
    /// @return tokensToDisable Mask of tokens that should be disabled after the operation
    ///         (`token` mask if withdrawing the entire balance, zero otherwise)
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
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
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
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

    /// @notice Revokes credit account's allowances for specified spender/token pairs
    /// @param creditAccount Account to revoke allowances for
    /// @param revocations Array of spender/token pairs
    /// @dev Exists primarily to allow users to revoke allowances on accounts from old account factory on mainnet
    /// @dev Reverts if any of provided tokens is not recognized as collateral in the credit manager
    function revokeAdapterAllowances(
        address creditAccount,
        RevocationPair[] calldata revocations
    ) external override nonReentrant creditFacadeOnly {
        uint256 numRevocations = revocations.length;
        unchecked {
            for (uint256 i; i < numRevocations; ++i) {
                address spender = revocations[i].spender;
                address token = revocations[i].token;
                if (spender == address(0) || token == address(0)) {
                    revert ZeroAddressException();
                }
                _approveSpender({
                    creditAccount: creditAccount,
                    token: token,
                    spender: spender,
                    amount: 0
                });
            }
        }
    }

    // -------- //
    // ADAPTERS //
    // -------- //

    /// @notice Instructs active credit account to approve `amount` of `token` to adater's target contract
    /// @param token Token to approve
    /// @param amount Amount to approve
    /// @dev Reverts if active credit account is not set
    /// @dev Reverts if `msg.sender` is not a registered adapter
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
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
        }); // U:[CM-14]
    }

    /// @notice Instructs active credit account to call adapter's target contract with provided data
    /// @param data Data to call the target contract with
    /// @return result Call result
    /// @dev Reverts if active credit account is not set
    /// @dev Reverts if `msg.sender` is not a registered adapter
    function execute(
        bytes calldata data
    ) external override nonReentrant returns (bytes memory result) {
        address targetContract = _getTargetContractOrRevert();
        address creditAccount = getActiveCreditAccountOrRevert();
        return _execute(creditAccount, targetContract, data);
    }

    /// @notice Sets/unsets active credit account adapters can interact with
    /// @param creditAccount Credit account to set as active or `INACTIVE_CREDIT_ACCOUNT_ADDRESS` to unset it
    function setActiveCreditAccount(
        address creditAccount
    ) external override nonReentrant creditFacadeOnly {
        if (
            _activeCreditAccount != INACTIVE_CREDIT_ACCOUNT_ADDRESS &&
            creditAccount != INACTIVE_CREDIT_ACCOUNT_ADDRESS
        ) {
            revert ActiveCreditAccountOverridenException();
        }
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
    /// @param creditAccount Credit account to check
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
    ///        when known subset of account's collateral tokens covers all the debt
    /// @return enabledTokensMaskAfter Bitmask of account's enabled collateral tokens after potential cleanup
    /// @dev Even when `collateralHints` are specified, quoted tokens are evaluated before non-quoted ones
    /// @custom:expects Credit facade ensures that `creditAccount` is opened in this credit manager
    function fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] calldata collateralHints
    )
        external
        override
        nonReentrant
        creditFacadeOnly
        returns (uint256 enabledTokensMaskAfter)
    {
        CollateralDebtData memory cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            collateralHints: collateralHints,
            enabledTokensMask: enabledTokensMask,
            // task: CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY,
            task: CollateralCalcTask.GENERIC_PARAMS
        });

        // if (
        //     cdd.twvUSD <
        //     (cdd.totalDebtUSD * minHealthFactor) / PERCENTAGE_FACTOR
        // ) {
        //     revert NotEnoughCollateralException();
        // }

        enabledTokensMaskAfter = cdd.enabledTokensMask;
        _saveEnabledTokensMask(creditAccount, enabledTokensMaskAfter); // U:[CM-18]
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
        if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
            revert IncorrectParameterException();
        }

        bool useSafePrices;
        if (task == CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES) {
            task = CollateralCalcTask.DEBT_COLLATERAL;
            useSafePrices = true;
        }

        getBorrowerOrRevert(creditAccount);

        uint256[] memory collateralHints;
        cdd = _calcDebtAndCollateral({
            creditAccount: creditAccount,
            enabledTokensMask: enabledTokensMaskOf(creditAccount),
            collateralHints: collateralHints,
            task: task
        });
    }

    // --------------------- //
    // CREDIT MANAGER PARAMS //
    // --------------------- //

    /// @notice Returns credit manager's fee parameters (all fields in bps)
    /// @return _feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @return _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @return _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @return _feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @return _liquidationDiscountExpired Percentage of liquidated expired account value that is used to repay debt
    function fees()
        external
        view
        override
        returns (
            uint16 _feeInterest,
            uint16 _feeLiquidation,
            uint16 _liquidationDiscount,
            uint16 _feeLiquidationExpired,
            uint16 _liquidationDiscountExpired
        )
    {
        _feeInterest = feeInterest; // U:[CM-41]
        _feeLiquidation = feeLiquidation; // U:[CM-41]
        _liquidationDiscount = liquidationDiscount; // U:[CM-41]
        _feeLiquidationExpired = feeLiquidationExpired; // U:[CM-41]
        _liquidationDiscountExpired = liquidationDiscountExpired; // U:[CM-41]
    }

    /// @notice Returns `token`'s liquidation threshold ramp parameters
    /// @param token Token to get parameters for
    /// @return ltInitial LT at the beginning of the ramp in bps
    /// @return ltFinal LT at the end of the ramp in bps
    /// @return timestampRampStart Timestamp of the beginning of the ramp
    /// @return rampDuration Ramp duration in seconds
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function ltParams(
        address token
    )
        external
        view
        override
        returns (
            uint16 ltInitial,
            uint16 ltFinal,
            uint40 timestampRampStart,
            uint24 rampDuration
        )
    {
        uint256 tokenMask = getTokenMaskOrRevert(token);
        CollateralTokenData memory tokenData = collateralTokensData[tokenMask];

        return (
            tokenData.ltInitial,
            tokenData.ltFinal,
            tokenData.timestampRampStart,
            tokenData.rampDuration
        );
    }

    /// @notice Returns collateral token's address by its mask in the credit manager
    /// @param tokenMask Collateral token mask in the credit manager
    /// @return token Token address
    /// @dev Reverts if `tokenMask` doesn't correspond to any known collateral token
    function getTokenByMask(
        uint256 tokenMask
    ) public view override returns (address token) {
        token = _collateralTokenByMask({tokenMask: tokenMask});
    }

    /// @notice Returns collateral token's address and liquidation threshold by its mask
    /// @param tokenMask Collateral token mask in the credit manager
    /// @return token Token address
    /// @dev Reverts if `tokenMask` doesn't correspond to any known collateral token
    function collateralTokenByMask(
        uint256 tokenMask
    ) public view override returns (address token) {
        return _collateralTokenByMask({tokenMask: tokenMask});
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

    /// @notice Returns chunk of up to `limit` credit accounts opened in this credit manager starting from `offset`
    function creditAccounts(
        uint256 offset,
        uint256 limit
    ) external view override returns (address[] memory result) {
        uint256 len = creditAccountsSet.length();
        uint256 resultLen = offset + limit > len
            ? (offset > len ? 0 : len - offset)
            : limit;

        result = new address[](resultLen);
        unchecked {
            for (uint256 i = 0; i < resultLen; ++i) {
                result[i] = creditAccountsSet.at(offset + i);
            }
        }
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
    /// @dev Does not revert if `creditAccount` is not opened to this credit manager
    function enabledTokensMaskOf(
        address creditAccount
    ) public view override returns (uint256) {
        return creditAccountInfo[creditAccount].enabledTokensMask; // U:[CM-37]
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

    function setCreditFacade(
        address _creditFacade
    ) external override creditConfiguratorOnly {
        creditFacade = _creditFacade;
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Adds `token` to the list of collateral tokens, see `_addToken` for details
    function addToken(address token) external override creditConfiguratorOnly {
        _addToken(token);
    }

    /// @notice Sets credit manager's fee parameters (all fields in bps)
    /// @param _feeInterest Percentage of accrued interest taken by the protocol as profit
    /// @param _feeLiquidation Percentage of liquidated account value taken by the protocol as profit
    /// @param _liquidationDiscount Percentage of liquidated account value that is used to repay debt
    /// @param _feeLiquidationExpired Percentage of liquidated expired account value taken by the protocol as profit
    /// @param _liquidationDiscountExpired Percentage of liquidated expired account value that is used to repay debt
    function setFees(
        uint16 _feeInterest,
        uint16 _feeLiquidation,
        uint16 _liquidationDiscount,
        uint16 _feeLiquidationExpired,
        uint16 _liquidationDiscountExpired
    )
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        feeInterest = _feeInterest; // U:[CM-40]
        feeLiquidation = _feeLiquidation; // U:[CM-40]
        liquidationDiscount = _liquidationDiscount; // U:[CM-40]
        feeLiquidationExpired = _feeLiquidationExpired; // U:[CM-40]
        liquidationDiscountExpired = _liquidationDiscountExpired; // U:[CM-40]
    }

    /// @notice Sets a new max number of enabled tokens
    /// @param _maxEnabledTokens The new max number of enabled tokens
    function setMaxEnabledTokens(
        uint8 _maxEnabledTokens
    )
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        maxEnabledTokens = _maxEnabledTokens; // U:[CM-44]
    }

    /// @notice Sets `token`'s liquidation threshold ramp parameters
    /// @param token Token to set parameters for
    /// @param ltInitial LT at the beginning of the ramp in bps
    /// @param ltFinal LT at the end of the ramp in bps
    /// @param timestampRampStart Timestamp of the beginning of the ramp
    /// @param rampDuration Ramp duration in seconds
    /// @dev If `token` is `underlying`, sets LT to `ltInitial` and ignores other parameters
    /// @dev Reverts if `token` is not recognized as collateral in the credit manager
    function setCollateralTokenData(
        address token,
        uint16 ltInitial,
        uint16 ltFinal,
        uint40 timestampRampStart,
        uint24 rampDuration
    )
        external
        override
        creditConfiguratorOnly // U:[CM-4]
    {
        if (token == underlying) {
            ltUnderlying = ltInitial; // U:[CM-42]
        } else {
            uint256 tokenMask = getTokenMaskOrRevert({token: token}); // U:[CM-41]
            CollateralTokenData storage tokenData = collateralTokensData[
                tokenMask
            ];

            tokenData.ltInitial = ltInitial; // U:[CM-42]
            tokenData.ltFinal = ltFinal; // U:[CM-42]
            tokenData.timestampRampStart = timestampRampStart; // U:[CM-42]
            tokenData.rampDuration = rampDuration; // U:[CM-42]
        }
    }

    /// @notice Sets the link between the adapter and the target contract
    /// @param adapter Address of the adapter contract to use to access the third-party contract,
    ///        passing `address(0)` will forbid accessing `targetContract`
    /// @param targetContract Address of the third-pary contract for which the adapter is set,
    ///        passing `address(0)` will forbid using `adapter`
    /// @dev Reverts if `targetContract` or `adapter` is this contract's address
    function setContractAllowance(
        address adapter,
        address targetContract
    ) external override creditConfiguratorOnly {
        // if (targetContract == address(this) || adapter == address(this)) {
        //     revert TargetContractNotAllowedException();
        // } // U:[CM-45]
        // if (adapter != address(0)) {
        //     adapterToContract[adapter] = targetContract; // U:[CM-45]
        // }
        // if (targetContract != address(0)) {
        //     contractToAdapter[targetContract] = adapter; // U:[CM-45]
        // }
    }

    /// @notice Sets a new price oracle
    /// @param _priceOracle Address of the new price oracle
    function setPriceOracle(
        address _priceOracle
    )
        external
        override
        creditConfiguratorOnly // U: [CM-4]
    {
        priceOracle = _priceOracle; // U:[CM-46]
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Saves `creditAccount`'s `enabledTokensMask` in the storage
    /// @dev Ensures that the number of enabled tokens excluding underlying does not exceed `maxEnabledTokens`
    function _saveEnabledTokensMask(
        address creditAccount,
        uint256 enabledTokensMask
    ) internal {
        if (
            enabledTokensMask
                .disable(UNDERLYING_TOKEN_MASK)
                .calcEnabledTokens() > maxEnabledTokens
        ) {
            revert TooManyEnabledTokensException();
        }
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

        collateralTokensData[tokenMask].token = token;
        collateralTokensData[tokenMask].timestampRampStart = type(uint40).max;

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

    /// @dev `calcDebtAndCollateral` implementation
    /// @param creditAccount Credit account to return data for
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens
    /// @param collateralHints Optional array of token masks specifying the order of checking collateral tokens
    /// @param task Calculation mode, see `CollateralCalcTask` for details
    /// @return cdd A struct with debt and collateral data
    function _calcDebtAndCollateral(
        address creditAccount,
        uint256 enabledTokensMask,
        uint256[] memory collateralHints,
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

        address _priceOracle = priceOracle;

        {
            uint256 totalDebt = _amountWithFee(cdd.calcTotalDebt());
            if (totalDebt != 0) {
                cdd.totalDebtUSD = _convertToUSD(
                    _priceOracle,
                    totalDebt,
                    underlying
                );
            } else if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
                return cdd;
            }
        }

        // uint256 targetUSD = (task ==
        //     CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY)
        //     ? (cdd.totalDebtUSD * minHealthFactor) / PERCENTAGE_FACTOR
        //     : type(uint256).max;

        // uint256 tokensToDisable;
        // (cdd.totalValueUSD, cdd.twvUSD, tokensToDisable) = cdd.calcCollateral({
        //     creditAccount: creditAccount,
        //     twvUSDTarget: targetUSD,
        //     collateralHints: collateralHints,
        //     collateralTokenByMaskFn: _collateralTokenByMask,
        //     convertToUSDFn: _safeConvertToUSD,
        //     priceOracle: _priceOracle
        // });
        // cdd.enabledTokensMask = enabledTokensMask.disable(tokensToDisable);

        // if (task == CollateralCalcTask.FULL_COLLATERAL_CHECK_LAZY) {
        //     return cdd;
        // }

        // cdd.totalValue = _convertFromUSD(
        //     _priceOracle,
        //     cdd.totalValueUSD,
        //     underlying
        // );
    }

    /// @dev Internal wrapper for `priceOracle.convertFromUSD` call to reduce contract size
    function _convertFromUSD(
        address _priceOracle,
        uint256 amountInUSD,
        address token
    ) internal returns (uint256 amountInToken) {
        amountInToken = IPriceOracle(_priceOracle).convertFromUSD(
            amountInUSD,
            token
        );
    }

    /// @dev Internal wrapper for `priceOracle.safeConvertToUSD` call to reduce contract size
    /// @dev `underlying` is always converted with default conversion function
    function _safeConvertToUSD(
        address _priceOracle,
        uint256 amountInToken,
        address token
    ) internal view returns (uint256 amountInUSD) {
        amountInUSD = (token == underlying)
            ? _convertToUSD(_priceOracle, amountInToken, token)
            : IPriceOracle(_priceOracle).safeConvertToUSD(amountInToken, token);
    }

    function _collateralTokenByMask(
        uint256 tokenMask
    ) internal view returns (address token) {
        if (tokenMask == UNDERLYING_TOKEN_MASK) {
            token = underlying;
        } else {
            CollateralTokenData storage tokenData = collateralTokensData[
                tokenMask
            ];

            bytes32 rawData;
            assembly {
                rawData := sload(tokenData.slot)
                token := and(
                    rawData,
                    0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
                )
            }

            if (token == address(0)) {
                revert TokenNotAllowedException();
            }
        }
    }

    function _convertToUSD(
        address _priceOracle,
        uint256 amountInToken,
        address token
    ) internal view returns (uint256 amountInUSD) {
        amountInUSD = IPriceOracle(_priceOracle).safeConvertToUSD(
            amountInToken,
            token
        );
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
