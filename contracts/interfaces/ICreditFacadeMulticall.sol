// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BalanceDelta} from "../libraries/BalancesLogic.sol";
import {RevocationPair} from "./ICreditManager.sol";

// ----- //
// FLAGS //
// ----- //

/// @dev Indicates that there are enabled forbidden tokens on the account before multicall
uint256 constant FORBIDDEN_TOKENS_BEFORE_CALLS = 1 << 192;

/// @dev Indicates that external calls from credit account to adapters were made during multicall,
///      set to true on the first call to the adapter
uint256 constant EXTERNAL_CONTRACT_WAS_CALLED = 1 << 193;

/// @title Credit facade  multicall interface
/// @dev Unless specified otherwise, all these methods are only available in `openCreditAccount`,
///      `closeCreditAccount`, `multicall`, and, with account owner's permission, `botMulticall`
interface ICreditFacadeMulticall {

    /// @notice Updates the price for a token with on-demand updatable price feed
    function onDemandPriceUpdate(address token, bool reserve, bytes calldata data) external;

    /// @notice Stores expected token balances (current balance + delta) after operations for a slippage check.
    function storeExpectedBalances(BalanceDelta[] calldata balanceDeltas) external;

    /// @notice Performs a slippage check ensuring that current token balances are greater than saved expected ones
    function compareBalances() external;

    /// @notice Adds collateral to account
    function addCollateral(address token, uint256 amount) external;

    /// @notice Increases account's debt
    function increaseDebt(uint256 amount) external;

    /// @notice Decreases account's debt
    function decreaseDebt(uint256 amount) external;

    /// @notice Withdraws collateral from account
    function withdrawCollateral(address token, uint256 amount, address to) external;

    /// @notice Sets advanced collateral check parameters
    /// @param collateralHints Optional array of token masks to check first to reduce the amount of computation
    ///        when known subset of account's collateral tokens covers all the debt
    /// @param minHealthFactor Min account's health factor in bps in order not to revert, must be at least 10000
    function setFullCheckParams(uint256[] calldata collateralHints, uint16 minHealthFactor) external;

    /// @notice Enables token as account's collateral, which makes it count towards account's total value
    /// @param token Token to enable as collateral
    /// @dev Enabling forbidden tokens is prohibited
    /// @dev Quoted tokens can only be enabled via `updateQuota`, this method is no-op for them
    function enableToken(address token) external;

    /// @notice Disables token as account's collateral
    /// @param token Token to disable as collateral
    /// @dev Quoted tokens can only be disabled via `updateQuota`, this method is no-op for them
    function disableToken(address token) external;

    /// @notice Revokes account's allowances for specified spender/token pairs
    /// @param revocations Array of spender/token pairs
    /// @dev Exists primarily to allow users to revoke allowances on accounts from old account factory on mainnet
    function revokeAdapterAllowances(RevocationPair[] calldata revocations) external;
}
