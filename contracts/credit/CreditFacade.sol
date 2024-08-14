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
contract CreditFacade is ICreditFacade, ReentrancyGuard {
    using Address for address;
    using Address for address payable;
    using BitMask for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;

    /// @notice Credit manager connected to this credit facade
    address public immutable override creditManager;

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
    }

    // ------------------ //
    // ACCOUNT MANAGEMENT //
    // ------------------ //

    /// @notice Opens a new credit account
    function openCreditAccount(
        address onBehalfOf
    ) external payable override nonReentrant returns (address creditAccount) {
        creditAccount = ICreditManager(creditManager).openCreditAccount({
            onBehalfOf: onBehalfOf
        });

        emit OpenCreditAccount(creditAccount, onBehalfOf, msg.sender);
    }

    /// @notice Executes a batch of calls allowing user to manage their credit account
    function multicall(
        address creditAccount,
        MultiCall[] calldata calls
    ) external override creditAccountOwnerOnly(creditAccount) nonReentrant {
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
        uint256 enabledTokensMaskBefore = _enabledTokensMaskOf(creditAccount); // U:[FA-18]

        FullCheckParams memory fullCheckParams = _multicall(
            creditAccount,
            calls,
            enabledTokensMaskBefore
        );

        _fullCollateralCheck({
            creditAccount: creditAccount,
            enabledTokensMaskBefore: enabledTokensMaskBefore,
            fullCheckParams: fullCheckParams
        });
    }

    /// @dev Multicall implementation
    function _multicall(
        address creditAccount,
        MultiCall[] calldata calls,
        uint256 enabledTokensMask
    ) internal returns (FullCheckParams memory fullCheckParams) {
        emit StartMultiCall({creditAccount: creditAccount, caller: msg.sender});

        unchecked {
            uint256 len = calls.length;
            for (uint256 i = 0; i < len; ++i) {
                MultiCall calldata mcall = calls[i];
                // credit facade calls
                if (mcall.target == address(this)) {
                    bytes4 method = bytes4(mcall.callData);
                    // addCollateral
                    if (
                        method == ICreditFacadeMulticall.addCollateral.selector
                    ) {
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _addCollateral(
                                creditAccount,
                                mcall.callData[4:]
                            )
                        });
                    }
                    // withdrawCollateral
                    else if (
                        method ==
                        ICreditFacadeMulticall.withdrawCollateral.selector
                    ) {
                        uint256 tokensToDisable = _withdrawCollateral(
                            creditAccount,
                            mcall.callData[4:]
                        );

                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: tokensToDisable
                        });
                    }
                    // increaseDebt
                    else if (
                        method == ICreditFacadeMulticall.increaseDebt.selector
                    ) {
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
                    // enableToken
                    else if (
                        method == ICreditFacadeMulticall.enableToken.selector
                    ) {
                        address token = abi.decode(
                            mcall.callData[4:],
                            (address)
                        );
                        enabledTokensMask = enabledTokensMask.enable({
                            bitsToEnable: _getTokenMaskOrRevert(token)
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
                        enabledTokensMask = enabledTokensMask.disable({
                            bitsToDisable: _getTokenMaskOrRevert(token)
                        });
                    }
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

                    enabledTokensMask = enabledTokensMask.enableDisable({
                        bitsToEnable: tokensToEnable,
                        bitsToDisable: tokensToDisable
                    });
                }
            }
        }

        fullCheckParams.enabledTokensMaskAfter = enabledTokensMask;
        emit FinishMultiCall();
    }

    /// @dev Performs collateral check to ensure that
    function _fullCollateralCheck(
        address creditAccount,
        uint256 enabledTokensMaskBefore,
        FullCheckParams memory fullCheckParams
    ) internal {
        uint256 enabledTokensMask = ICreditManager(creditManager).fullCollateralCheck(
            creditAccount,
            fullCheckParams.enabledTokensMaskAfter
        );
    }

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

        uint256 newDebt;
        (newDebt, tokensToEnable, tokensToDisable) = ICreditManager(
            creditManager
        ).manageDebt(creditAccount, amount, enabledTokensMask, action);

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
    function _getBorrowerOrRevert(
        address creditAccount
    ) internal view returns (address) {
        return
            ICreditManager(creditManager).getBorrowerOrRevert({
                creditAccount: creditAccount
            });
    }

    /// @dev Internal wrapper for `creditManager.enabledTokensMaskOf` call to reduce contract size
    function _enabledTokensMaskOf(
        address creditAccount
    ) internal view returns (uint256) {
        return ICreditManager(creditManager).enabledTokensMaskOf(creditAccount);
    }

    /// @dev Internal wrapper for `creditManager.setActiveCreditAccount` call to reduce contract size
    function _setActiveCreditAccount(address creditAccount) internal {
        ICreditManager(creditManager).setActiveCreditAccount(creditAccount);
    }
}
