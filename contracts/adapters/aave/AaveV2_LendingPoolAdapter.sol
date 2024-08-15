// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../AbstractAdapter.sol";
import "../../integrations/aave/ILendingPool.sol";
import "../../interfaces/aave/IAaveV2_LendingPoolAdapter.sol";

/// @title Aave V2 LendingPool adapter
/// @notice Implements logic allowing CAs to interact with Aave's lending pool
contract AaveV2_LendingPoolAdapter is AbstractAdapter, IAaveV2_LendingPoolAdapter {
    /// @notice Constructor
    /// @param _creditManager Credit manager address
    /// @param _lendingPool Lending pool address
    constructor(address _creditManager, address _lendingPool)
        AbstractAdapter(_creditManager, _lendingPool)
    {}

    /// @dev Returns aToken address for given underlying token
    function _aToken(address underlying) internal view returns (address) {
        return ILendingPool(targetContract).getReserveData(underlying).aTokenAddress;
        // return ILendingPool(targetContract).getReserveData(underlying);
    }

    // -------- //
    // DEPOSITS //
    // -------- //

    /// @notice Deposit underlying tokens into Aave in exchange for aTokens
    /// @param asset Address of underlying token to deposit
    /// @param amount Amount of underlying tokens to deposit
    /// @dev Last two parameters are ignored as `onBehalfOf` can only be credit account,
    ///      and `referralCode` is set to zero
    function deposit(address asset, uint256 amount)
        external
        override
        creditFacadeOnly
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        address creditAccount = _creditAccount();
        (tokensToEnable, tokensToDisable) = _deposit(creditAccount, asset, amount, false);
    }

    /// @notice Deposit all underlying tokens except a specified amount into Aave in exchange for aTokens
    /// @param asset Address of underlying token to deposit
    /// @param leftoverAmount Amount of asset to leave at the end of operation
    function depositDiff(address asset, uint256 leftoverAmount)
        external
        override
        creditFacadeOnly
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        address creditAccount = _creditAccount();

        uint256 amount = IERC20(asset).balanceOf(creditAccount);
        if (amount <= leftoverAmount) return (0, 0);
        unchecked {
            amount -= leftoverAmount;
        }

        (tokensToEnable, tokensToDisable) = _deposit(creditAccount, asset, amount, leftoverAmount <= 1);
    }

    /// @dev Internal implementation of all deposit functions
    ///      - using `_executeSwap` because need to check if tokens are recognized by the system
    ///      - underlying is approved before the call because lending pool needs permission to transfer it
    ///      - aToken is enabled after the call
    ///      - underlying is only disabled when depositing the entire balance
    function _deposit(address creditAccount, address asset, uint256 amount, bool disableTokenIn)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (tokensToEnable, tokensToDisable,) = _executeSwapSafeApprove(
            asset,
            _aToken(asset),
            abi.encodeCall(ILendingPool.deposit, (asset, amount, creditAccount)),
            disableTokenIn
        ); 
    }

    // ----------- //
    // WITHDRAWALS //
    // ----------- //

    /// @notice Withdraw underlying tokens from Aave and burn aTokens
    /// @param asset Address of underlying token to deposit
    /// @param amount Amount of underlying tokens to withdraw
    ///        If `type(uint256).max`, will withdraw the full amount
    /// @dev Last parameter is ignored because underlying recepient can only be credit account
    function withdraw(address asset, uint256 amount, address)
        external
        override
        creditFacadeOnly 
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        address creditAccount = _creditAccount(); 
        if (amount == type(uint256).max) {
            (tokensToEnable, tokensToDisable) = _withdrawDiff(creditAccount, asset, 1); 
        } else {
            (tokensToEnable, tokensToDisable) = _withdraw(creditAccount, asset, amount); 
        }
    }

    /// @notice Burn all aTokens except the specified amount and convert to underlying
    /// @param asset Address of underlying token to withdraw
    /// @param leftoverAmount Amount of asset to leave after the operation
    function withdrawDiff(address asset, uint256 leftoverAmount)
        external
        override
        creditFacadeOnly 
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        address creditAccount = _creditAccount(); 
        (tokensToEnable, tokensToDisable) = _withdrawDiff(creditAccount, asset, leftoverAmount); 
    }

    /// @dev Internal implementation of `withdraw` functionality
    ///      - using `_executeSwap` because need to check if tokens are recognized by the system
    ///      - aToken is not approved before the call because lending pool doesn't need permission to burn it
    ///      - underlying is enabled after the call
    ///      - aToken is not disabled because operation doesn't spend the entire balance
    function _withdraw(address creditAccount, address asset, uint256 amount)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        (tokensToEnable, tokensToDisable,) =
            _executeSwapNoApprove(_aToken(asset), asset, _encodeWithdraw(creditAccount, asset, amount), false); 
    }

    /// @dev Internal implementation of `withdrawDiff` functionality
    ///      - using `_executeSwap` because need to check if tokens are recognized by the system
    ///      - aToken is not approved before the call because lending pool doesn't need permission to burn it
    ///      - underlying is enabled after the call
    ///      - aToken is disabled if the leftover is 0 or 1
    function _withdrawDiff(address creditAccount, address asset, uint256 leftoverAmount)
        internal
        returns (uint256 tokensToEnable, uint256 tokensToDisable)
    {
        address aToken = _aToken(asset);
        uint256 amount = IERC20(aToken).balanceOf(creditAccount); 
        if (amount <= leftoverAmount) return (0, 0);
        unchecked {
            amount -= leftoverAmount; 
        }

        (tokensToEnable, tokensToDisable,) =
            _executeSwapNoApprove(aToken, asset, _encodeWithdraw(creditAccount, asset, amount), leftoverAmount <= 1); 
    }

    /// @dev Returns calldata for `ILendingPool.withdraw` call
    function _encodeWithdraw(address creditAccount, address asset, uint256 amount)
        internal
        pure
        returns (bytes memory callData)
    {
        callData = abi.encodeCall(ILendingPool.withdraw, (asset, amount, creditAccount));
    }
}
