pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../interfaces/ICreditAccount.sol";

/// @title Credit account helper library
/// @notice Provides helper functions for managing assets on a credit account
library CreditAccountHelper {
    using SafeERC20 for IERC20;

    error AllowanceFailedException();

    /// @dev Safely approves token transfers
    /// @param creditAccount The credit account
    /// @param token The token address
    /// @param spender The address to approve
    /// @param amount The amount to approve
    function safeApprove(
        ICreditAccount creditAccount,
        address token,
        address spender,
        uint256 amount
    ) internal {
        if (!_approve(creditAccount, token, spender, amount, false)) {
            _approve(creditAccount, token, spender, 0, true); // Handle tokens that do not allow non-zero allowance changes
            _approve(creditAccount, token, spender, amount, true); // Re-approve the token
        }
    }

    /// @dev Internal function to approve tokens
    /// @param creditAccount The credit account
    /// @param token The token address
    /// @param spender The address to approve
    /// @param amount The amount to approve
    /// @param revertIfFailed Whether to revert if the approval fails
    function _approve(
        ICreditAccount creditAccount,
        address token,
        address spender,
        uint256 amount,
        bool revertIfFailed
    ) private returns (bool) {
        // Low-level call to approve and check the result
        try
            creditAccount.execute(
                token,
                abi.encodeCall(IERC20.approve, (spender, amount))
            )
        returns (bytes memory result) {
            if (result.length == 0 || abi.decode(result, (bool))) return true;
        } catch {}

        // On failure, handle according to the revertIfFailed flag
        if (revertIfFailed) revert AllowanceFailedException();
        return false;
    }

    /// @dev Transfers tokens from a credit account
    /// @param creditAccount The credit account
    /// @param token The token address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    function transfer(
        ICreditAccount creditAccount,
        address token,
        address to,
        uint256 amount
    ) internal {
        creditAccount.safeTransfer(token, to, amount);
    }

    /// @dev Transfers tokens and returns the actual amount delivered
    /// @param creditAccount The credit account
    /// @param token The token address
    /// @param to The recipient address
    /// @param amount The amount to transfer
    /// @return delivered The actual amount delivered
    function transferDeliveredBalanceControl(
        ICreditAccount creditAccount,
        address token,
        address to,
        uint256 amount
    ) internal returns (uint256 delivered) {
        uint256 balanceBefore = IERC20(token).balanceOf(to);
        transfer(creditAccount, token, to, amount);
        delivered = IERC20(token).balanceOf(to) - balanceBefore;
    }
}
