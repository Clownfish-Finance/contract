// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../libraries/BalancesLogic.sol";
import "../libraries/BitMask.sol";
import "../interfaces/ICreditFacade.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/ICreditManager.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/IPriceFeed.sol";

/// @title Credit facade
/// @notice Provides a user interface to open, close and liquidate leveraged positions in the credit manager,
///         and implements the main entry-point for credit accounts management: multicall.
/// @notice Multicall allows account owners to batch all the desired operations (adding or withdrawing collateral,
///         changing debt size, interacting with external protocols via adapters or increasing quotas) into one call,
///         followed by the collateral check that ensures that account is sufficiently collateralized.
///         For more details on what one can achieve with multicalls, see `_multicall` and  `ICreditFacadeMulticall`.
/// @notice Users can also let external bots manage their accounts via `botMulticall`. Bots can be relatively general,
///         the facade only ensures that they can do no harm to the protocol by running the collateral check after the
///         multicall and checking the permissions given to them by users. See `BotList` for additional details.
/// @notice Credit facade implements a few safeguards on top of those present in the credit manager, including debt and
///         quota size validation, pausing on large protocol losses, Degen NFT whitelist mode, and forbidden tokens
///         (they count towards account value, but having them enabled as collateral restricts available actions and
///         activates a safer version of collateral check).
contract CreditFacade is ICreditFacade, ReentrancyGuard {
    using Address for address;
    using Address for address payable;
    using BitMask for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Maximum quota size, as a multiple of `maxDebt`
    // uint256 public constant override maxQuotaMultiplier = 2;

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

    /// @notice WETH token address
    address public immutable override weth;

    /// @notice Expiration timestamp
    uint40 public override expirationDate;

    /// @notice Maximum amount that can be borrowed by a credit manager in a single block, as a multiple of `maxDebt`
    uint8 public override maxDebtPerBlockMultiplier;

    /// @notice Last block when underlying was borrowed by a credit manager
    uint64 internal lastBlockBorrowed;

    /// @notice The total amount borrowed by a credit manager in `lastBlockBorrowed`
    uint128 internal totalBorrowedInBlock;

    /// @notice Credit account debt limits packed into a single slot
    DebtLimits public override debtLimits;

    /// @notice Bit mask encoding a set of forbidden tokens
    uint256 public override forbiddenTokenMask;

    /// @notice Info on bad debt liquidation losses packed into a single slot
    CumulativeLossParams public override lossParams;

    /// @notice Mapping account => emergency liquidator status
    mapping(address => bool) public override canLiquidateWhilePaused;

    /// @dev Ensures that function caller is `creditAccount`'s owner
    modifier creditAccountOwnerOnly(address creditAccount) {
        _checkCreditAccountOwner(creditAccount);
        _;
    }

    /// @notice Constructor
    /// @param _creditManager Credit manager to connect this facade to
    constructor(address _creditManager) {
        creditManager = _creditManager;

        address addressProvider = ICreditManager(_creditManager)
            .addressProvider();
        // weth = IAddressProvider(addressProvider).getAddressOrRevert(
        //     AP_WETH_TOKEN
        // );
        // botList = IAddressProvider(addressProvider).getAddressOrRevert(
        //     AP_BOT_LIST,
        //     3_00
        // );
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - If Degen NFT is enabled, burns one from the caller
    ///         - Opens an account in the credit manager
    ///         - Performs a multicall (all calls allowed except debt decrease and withdrawals)
    ///         - Runs the collateral check
    /// @param onBehalfOf Address on whose behalf to open the account
    /// @param calls List of calls to perform after opening the account
    /// @return creditAccount Address of the newly opened account
    /// @dev Reverts if credit facade is paused or expired
    /// @dev Reverts if `onBehalfOf` is not caller while Degen NFT is enabled
    function openCreditAccount(
        address onBehalfOf,
        MultiCall[] calldata calls
    ) external payable override nonReentrant returns (address creditAccount) {
        creditAccount = ICreditManager(creditManager).openCreditAccount({
            onBehalfOf: onBehalfOf
        });

        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender);

        if (calls.length != 0) {
            // same as `_multicallFullCollateralCheck` but leverages the fact that account is freshly opened to save gas
            BalanceWithMask[] memory forbiddenBalances;

            // uint256 skipCalls = _applyOnDemandPriceUpdates(calls);
            FullCheckParams memory fullCheckParams = _multicall({
                creditAccount: creditAccount,
                calls: calls,
                enabledTokensMask: 0
            });

            // _fullCollateralCheck({
            //     creditAccount: creditAccount,
            //     enabledTokensMaskBefore: 0,
            //     fullCheckParams: fullCheckParams,
            //     forbiddenBalances: forbiddenBalances,
            //     forbiddenTokensMask: forbiddenTokenMask
            // });
        }
    }

    /// @notice Closes a credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Performs a multicall (all calls are allowed except debt increase)
    ///         - Closes a credit account in the credit manager
    ///         - Erases all bots permissions
    /// @param creditAccount Account to close
    /// @param calls List of calls to perform before closing the account
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager by caller
    /// @dev Reverts if facade is paused
    /// @dev Reverts if account has enabled tokens after executing `calls`
    /// @dev Reverts if account's debt is not zero after executing `calls`
    function closeCreditAccount(
        address creditAccount,
        MultiCall[] calldata calls
    )
        external
        payable
        override
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        uint256 enabledTokensMask = _enabledTokensMaskOf(creditAccount);

        if (calls.length != 0) {
            FullCheckParams memory fullCheckParams = _multicall(
                creditAccount,
                calls,
                enabledTokensMask
            );
            enabledTokensMask = fullCheckParams.enabledTokensMaskAfter;
        }

        if (enabledTokensMask != 0)
            revert CloseAccountWithEnabledTokensException();

        ICreditManager(creditManager).closeCreditAccount(creditAccount);

        emit CloseCreditAccount(creditAccount, msg.sender);
    }

    /// @notice Executes a batch of calls allowing user to manage their credit account
    ///         - Wraps any ETH sent in the function call and sends it back to the caller
    ///         - Performs a multicall (all calls are allowed)
    ///         - Runs the collateral check
    /// @param creditAccount Account to perform the calls on
    /// @param calls List of calls to perform
    /// @dev Reverts if `creditAccount` is not opened in connected credit manager by caller
    /// @dev Reverts if credit facade is paused or expired
    function multicall(
        address creditAccount,
        MultiCall[] calldata calls
    )
        external
        payable
        override
        creditAccountOwnerOnly(creditAccount)
        nonReentrant
    {
        _multicallFullCollateralCheck(creditAccount, calls);
    }

    // --------- //
    // MULTICALL //
    // --------- //

    /// @dev Batches price feed updates, multicall and collateral check into a single function
    function _multicallFullCollateralCheck(
        address creditAccount,
        MultiCall[] calldata calls
    ) internal {
        uint256 forbiddenTokensMask = forbiddenTokenMask;
        uint256 enabledTokensMaskBefore = _enabledTokensMaskOf(creditAccount);
        BalanceWithMask[] memory forbiddenBalances = BalancesLogic
            .storeBalances({
                creditAccount: creditAccount,
                tokensMask: forbiddenTokensMask & enabledTokensMaskBefore,
                getTokenByMaskFn: _getTokenByMask
            });

        // uint256 skipCalls = _applyOnDemandPriceUpdates(calls);
        FullCheckParams memory fullCheckParams = _multicall(
            creditAccount,
            calls,
            enabledTokensMaskBefore
        );

        // _fullCollateralCheck({
        //     creditAccount: creditAccount,
        //     enabledTokensMaskBefore: enabledTokensMaskBefore,
        //     fullCheckParams: fullCheckParams,
        //     forbiddenBalances: forbiddenBalances,
        //     forbiddenTokensMask: forbiddenTokensMask
        // });
    }

    /// @dev Multicall implementation
    /// @param creditAccount Account to perform actions with
    /// @param calls Array of `(target, callData)` tuples representing a sequence of calls to perform
    ///        - if `target` is this contract's address, `callData` must be an ABI-encoded calldata of a method
    ///          from `ICreditFacadeMulticall`, which is dispatched and handled appropriately
    ///        - otherwise, `target` must be an allowed adapter, which is called with `callData`, and is expected to
    ///          return two ABI-encoded `uint256` masks of tokens that should be enabled/disabled after the call
    /// @param enabledTokensMask Bitmask of account's enabled collateral tokens before the multicall
    /// @return fullCheckParams Collateral check parameters, see `FullCheckParams` for details
    function _multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        uint256 enabledTokensMask
    ) internal returns (FullCheckParams memory fullCheckParams) {
        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender});

        uint256 quotedTokensMaskInverted;
        Balance[] memory expectedBalances;

        unchecked {
            uint256 len = calls.length;
            for (uint256 i = 0; i < len; ++i) {
                MultiCall calldata mcall = calls[i];

                // credit facade calls
                if (mcall.target == address(this)) {
                    bytes4 method = bytes4(mcall.callData);

                    // storeExpectedBalances
                    if (
                        method ==
                        ICreditFacadeMulticall.storeExpectedBalances.selector
                    ) {
                        if (expectedBalances.length != 0)
                            revert ExpectedBalancesAlreadySetException();

                        BalanceDelta[] memory balanceDeltas = abi.decode(
                            mcall.callData[4:],
                            (BalanceDelta[])
                        );
                        expectedBalances = BalancesLogic.storeBalances(
                            creditAccount,
                            balanceDeltas
                        );
                    }
                    // compareBalances
                    else if (
                        method ==
                        ICreditFacadeMulticall.compareBalances.selector
                    ) {
                        if (expectedBalances.length == 0)
                            revert ExpectedBalancesNotSetException();

                        if (
                            !BalancesLogic.compareBalances(
                                creditAccount,
                                expectedBalances,
                                Comparison.GREATER
                            )
                        ) {
                            revert BalanceLessThanExpectedException();
                        }
                        expectedBalances = new Balance[](0);
                    }
                    // addCollateral
                    else if (
                        method == ICreditFacadeMulticall.addCollateral.selector
                    ) {
                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                            quotedTokensMaskInverted
                        );

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(
                                creditAccount,
                                mcall.callData[4:]
                            ),
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    // addCollateralWithPermit
                    // else if (
                    //     method ==
                    //     ICreditFacadeMulticall.addCollateralWithPermit.selector
                    // ) {
                    //     quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                    //         quotedTokensMaskInverted
                    //     );
                    //     enabledTokensMask = enabledTokensMask.enable({
                    //         bitsToEnable: _addCollateralWithPermit(
                    //             creditAccount,
                    //             mcall.callData[4:]
                    //         ),
                    //         invertedSkipMask: quotedTokensMaskInverted
                    //     }); // U:[FA-26B]
                    // }
                    // updateQuota
                    // else if (
                    //     method == ICreditFacadeMulticall.updateQuota.selector
                    // ) {
                    //     (
                    //         uint256 tokensToEnable,
                    //         uint256 tokensToDisable
                    //     ) = _updateQuota(
                    //             creditAccount,
                    //             mcall.callData[4:],
                    //             flags & FORBIDDEN_TOKENS_BEFORE_CALLS != 0
                    //         ); // U:[FA-34]
                    //     enabledTokensMask = enabledTokensMask.enableDisable(
                    //         tokensToEnable,
                    //         tokensToDisable
                    //     ); // U:[FA-34]
                    // }
                    // withdrawCollateral
                    else if (
                        method ==
                        ICreditFacadeMulticall.withdrawCollateral.selector
                    ) {
                        fullCheckParams.revertOnForbiddenTokens = true;
                        fullCheckParams.useSafePrices = true;

                        uint256 tokensToDisable = _withdrawCollateral(
                            creditAccount,
                            mcall.callData[4:]
                        );

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                            quotedTokensMaskInverted
                        );

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable,
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    // increaseDebt
                    else if (
                        method == ICreditFacadeMulticall.increaseDebt.selector
                    ) {
                        fullCheckParams.revertOnForbiddenTokens = true;

                        (uint256 tokensToEnable, ) = _manageDebt(
                            creditAccount,
                            mcall.callData[4:],
                            enabledTokensMask,
                            ManageDebtAction.INCREASE_DEBT
                        );
                        enabledTokensMask = enabledTokensMask.enable(
                            tokensToEnable
                        );
                    }
                    // decreaseDebt
                    else if (
                        method == ICreditFacadeMulticall.decreaseDebt.selector
                    ) {
                        (, uint256 tokensToDisable) = _manageDebt(
                            creditAccount,
                            mcall.callData[4:],
                            enabledTokensMask,
                            ManageDebtAction.DECREASE_DEBT
                        );
                        enabledTokensMask = enabledTokensMask.disable(
                            tokensToDisable
                        );
                    }
                    // setFullCheckParams
                    else if (
                        method ==
                        ICreditFacadeMulticall.setFullCheckParams.selector
                    ) {
                        // (
                        //     fullCheckParams.collateralHints,
                        //     fullCheckParams.minHealthFactor
                        // ) = abi.decode(mcall.callData[4:], (uint256[], uint16));

                        // if (
                        //     fullCheckParams.minHealthFactor < PERCENTAGE_FACTOR
                        // ) {
                        //     revert CustomHealthFactorTooLowException(); // U:[FA-24]
                        // }

                        (fullCheckParams.collateralHints) = abi.decode(
                            mcall.callData[4:],
                            (uint256[])
                        );

                        uint256 hintsLen = fullCheckParams
                            .collateralHints
                            .length;
                        for (uint256 j; j < hintsLen; ++j) {
                            uint256 mask = fullCheckParams.collateralHints[j];
                            // 是否为 2 的幂次方
                            if (mask == 0 || mask & (mask - 1) != 0)
                                revert InvalidCollateralHintException();
                        }
                    }
                    // enableToken
                    else if (
                        method == ICreditFacadeMulticall.enableToken.selector
                    ) {
                        address token = abi.decode(
                            mcall.callData[4:],
                            (address)
                        );

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                            quotedTokensMaskInverted
                        );

                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    // disableToken
                    else if (
                        method == ICreditFacadeMulticall.disableToken.selector
                    ) {
                        address token = abi.decode(
                            mcall.callData[4:],
                            (address)
                        );

                        quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                            quotedTokensMaskInverted
                        );

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token),
                            invertedSkipMask: quotedTokensMaskInverted
                        });
                    }
                    // revokeAdapterAllowances
                    // else if (
                    //     method ==
                    //     ICreditFacadeMulticall
                    //         .revokeAdapterAllowances
                    //         .selector
                    // ) {
                    //     _revokeAdapterAllowances(
                    //         creditAccount,
                    //         mcall.callData[4:]
                    //     ); // U:[FA-36]
                    // }
                    // unknown method
                    else {
                        revert UnknownMethodException();
                    }
                }
                // adapter calls
                else {
                    bytes memory result;
                    {
                        address targetContract = ICreditManager(creditManager)
                            .adapterToContract(mcall.target);
                            
                        if (targetContract == address(0)) {
                            revert TargetContractNotAllowedException();
                        }

                        _setActiveCreditAccount(creditAccount);

                        result = mcall.target.functionCall(mcall.callData);

                        emit Execute({
                            creditAccount: creditAccount,
                            targetContract: targetContract
                        });
                    }

                    (uint256 tokensToEnable, uint256 tokensToDisable) = abi
                        .decode(result, (uint256, uint256));

                    quotedTokensMaskInverted = _quotedTokensMaskInvertedLoE(
                        quotedTokensMaskInverted
                    );

                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable,
                        invertedSkipMask: quotedTokensMaskInverted
                    });
                }
            }
        }

        if (expectedBalances.length != 0) {
            if (
                !BalancesLogic.compareBalances(
                    creditAccount,
                    expectedBalances,
                    Comparison.GREATER
                )
            ) {
                revert BalanceLessThanExpectedException();
            }
        }

        if (enabledTokensMask & forbiddenTokenMask != 0) {
            fullCheckParams.useSafePrices = true;
        }

        // if (flags & EXTERNAL_CONTRACT_WAS_CALLED != 0) {
        //     _unsetActiveCreditAccount(); // U:[FA-38]
        // }

        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask; // U:[FA-38]

        emit FinishMultiCall(); // U:[FA-18]
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    // --------- //
    // MULTICALL //
    // --------- //

    /// @dev `ICreditFacadeMulticall.{increase|decrease}Debt` implementation
    function _manageDebt(
        address creditAccount,
        bytes calldata callData,
        uint256 enabledTokensMask,
        ManageDebtAction action
    ) internal returns (uint256 tokensToEnable, uint256 tokensToDisable) {
        uint256 amount = abi.decode(callData, (uint256));

        // if (action == ManageDebtAction.INCREASE_DEBT) {
        //     _revertIfOutOfBorrowingLimit(amount);
        // }

        uint256 newDebt;
        (newDebt, tokensToEnable, tokensToDisable) = ICreditManager(
            creditManager
        ).manageDebt(creditAccount, amount, enabledTokensMask, action);

        // _revertIfOutOfDebtLimits(newDebt);

        if (action == ManageDebtAction.INCREASE_DEBT) {
            emit IncreaseDebt({creditAccount: creditAccount, amount: amount});
        } else {
            emit DecreaseDebt({creditAccount: creditAccount, amount: amount});
        }
    }

    /// @dev `ICreditFacadeMulticall.withdrawCollateral` implementation
    function _withdrawCollateral(
        address creditAccount,
        bytes calldata callData
    ) internal returns (uint256 tokensToDisable) {
        (address token, uint256 amount, address to) = abi.decode(
            callData,
            (address, uint256, address)
        );

        if (amount == type(uint256).max) {
            amount = IERC20(token).balanceOf(creditAccount);
            if (amount <= 1) return 0;
            unchecked {
                --amount;
            }
        }
        tokensToDisable = ICreditManager(creditManager).withdrawCollateral(
            creditAccount,
            token,
            amount,
            to
        );

        emit WithdrawCollateral(creditAccount, token, amount, to);
    }

    /// @dev Load-on-empty function to read price oracle at most once if it's needed,
    ///      returns its argument if it's not empty or `priceOracle` from credit manager otherwise
    /// @dev Non-empty price oracle always has non-zero address
    function _priceOracleLoE(
        address priceOracleOrEmpty
    ) internal view returns (address) {
        return
            priceOracleOrEmpty == address(0)
                ? ICreditManager(creditManager).priceOracle()
                : priceOracleOrEmpty;
    }

    /// @dev Load-on-empty function to read inverted quoted tokens mask at most once if it's needed,
    ///      returns its argument if it's not empty or inverted `quotedTokensMask` from credit manager otherwise
    /// @dev Non-empty inverted quoted tokens mask always has it's LSB set to 1 since underlying can't be quoted
    function _quotedTokensMaskInvertedLoE(
        uint256 quotedTokensMaskInvertedOrEmpty
    ) internal view returns (uint256) {
        return
            quotedTokensMaskInvertedOrEmpty == 0
                ? ~ICreditManager(creditManager).quotedTokensMask()
                : quotedTokensMaskInvertedOrEmpty;
    }

    /// @dev `ICreditFacadeMulticall.addCollateral` implementation
    function _addCollateral(
        address creditAccount,
        bytes calldata callData
    ) internal returns (uint256 tokensToEnable) {
        (address token, uint256 amount) = abi.decode(
            callData,
            (address, uint256)
        );
        tokensToEnable = _addCollateral({
            payer: msg.sender,
            creditAccount: creditAccount,
            token: token,
            amount: amount
        });

        emit AddCollateral(creditAccount, token, amount);
    }

    /// @dev Internal wrapper for `creditManager.addCollateral` call to reduce contract size
    function _addCollateral(
        address payer,
        address creditAccount,
        address token,
        uint256 amount
    ) internal returns (uint256 tokenMask) {
        tokenMask = ICreditManager(creditManager).addCollateral({
            payer: payer,
            creditAccount: creditAccount,
            token: token,
            amount: amount
        });
    }

    /// @dev Internal wrapper for `creditManager.getTokenMaskOrRevert` call to reduce contract size
    function _getTokenMaskOrRevert(
        address token
    ) internal view returns (uint256) {
        return ICreditManager(creditManager).getTokenMaskOrRevert(token);
    }

    /// @dev Reverts if `msg.sender` is not `creditAccount` owner
    function _checkCreditAccountOwner(address creditAccount) internal view {
        if (msg.sender != _getBorrowerOrRevert(creditAccount)) {
            revert CallerNotCreditAccountOwnerException();
        }
    }

    /// @dev Internal wrapper for `creditManager.getBorrowerOrRevert` call to reduce contract size
    function _getBorrowerOrRevert(address creditAccount) internal view returns (address) {
        return ICreditManager(creditManager).getBorrowerOrRevert({creditAccount: creditAccount});
    }

     /// @dev Internal wrapper for `creditManager.enabledTokensMaskOf` call to reduce contract size
    function _enabledTokensMaskOf(address creditAccount) internal view returns (uint256) {
        return ICreditManager(creditManager).enabledTokensMaskOf(creditAccount);
    }

    /// @dev Internal wrapper for `creditManager.getTokenByMask` call to reduce contract size
    function _getTokenByMask(uint256 mask) internal view returns (address) {
        return ICreditManager(creditManager).getTokenByMask(mask);
    }

    /// @dev Performs collateral check to ensure that
    ///      - account is sufficiently collateralized
    ///      - account has no forbidden tokens after risky operations
    ///      - no forbidden tokens have been enabled during the multicall
    ///      - no enabled forbidden token balance has increased during the multicall
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams,
        BalanceWithMask[] memory forbiddenBalances,
        uint256 forbiddenTokensMask
    ) internal {
        uint256 enabledTokensMask = ICreditManager(creditManager).fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter,
            fullCheckParams.collateralHints
            // fullCheckParams.minHealthFactor,
            // fullCheckParams.useSafePrices
        );

        uint256 enabledForbiddenTokensMask = enabledTokensMask & forbiddenTokensMask;
        if (enabledForbiddenTokensMask != 0) {
            if (fullCheckParams.revertOnForbiddenTokens) revert ForbiddenTokensException();

            // uint256 enabledForbiddenTokensMaskBefore = enabledTokensMaskBefore & forbiddenTokensMask;
            // if (enabledForbiddenTokensMask & ~enabledForbiddenTokensMaskBefore != 0) {
            //     revert ForbiddenTokenEnabledException();
            // }

            // bool success = BalancesLogic.compareBalances({
            //     creditAccount: creditAccount,
            //     tokensMask: enabledForbiddenTokensMask,
            //     balances: forbiddenBalances,
            //     comparison: Comparison.LESS
            // });

            // if (!success) revert ForbiddenTokenBalanceIncreasedException();
        }
    }

    /// @dev Internal wrapper for `creditManager.setActiveCreditAccount` call to reduce contract size
    function _setActiveCreditAccount(address creditAccount) internal {
        ICreditManager(creditManager).setActiveCreditAccount(creditAccount);
    }
}
