
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/// @title Collateral logic Library
/// @notice Implements functions that compute value of collateral on a credit account
library CollateralLogic {
    using SafeERC20 for IERC20;

    /// @notice Calculates the total collateral value in USD and TWV (Total Weighted Value) for non-quoted tokens
    /// @param creditAccount The address of the credit account
    /// @param twvUSDTarget The target TWV in USD
    /// @param collateralHints Hints for the collateral tokens
    /// @param collateralTokenByMaskFn Function to get the token address and liquidation threshold by mask
    /// @param convertToUSDFn Function to convert token value to USD
    /// @param priceOracle The address of the price oracle
    /// @return totalValueUSD The total collateral value in USD
    /// @return twvUSD The total weighted value in USD
    /// @return tokensToDisable The mask of tokens to disable
    function calcCollateral(
        address creditAccount,
        uint256 twvUSDTarget,
        uint256[] memory collateralHints,
        function(uint256, bool)
            view
            returns (address, uint16) collateralTokenByMaskFn,
        function(address, uint256, address)
            view
            returns (uint256) convertToUSDFn,
        address priceOracle
    )
        internal
        view
        returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable)
    {
        uint256 tokensToCheckMask = collateralHints[0]; // Assuming first element as tokens mask for simplicity

        uint256 tvDelta; // Temporary variable for total value delta
        uint256 twvDelta; // Temporary variable for total weighted value delta

        // Calculate collateral for non-quoted tokens
        (tvDelta, twvDelta, tokensToDisable) = calcNonQuotedTokensCollateral({
            tokensToCheckMask: tokensToCheckMask,
            priceOracle: priceOracle,
            creditAccount: creditAccount,
            twvUSDTarget: twvUSDTarget,
            collateralHints: collateralHints,
            collateralTokenByMaskFn: collateralTokenByMaskFn,
            convertToUSDFn: convertToUSDFn
        });

        totalValueUSD += tvDelta; // Add the total value delta to totalValueUSD
        twvUSD += twvDelta; // Add the total weighted value delta to twvUSD
    }

    /// @notice Calculates the total collateral value and TWV for non-quoted tokens
    /// @param tokensToCheckMask The mask of tokens to check
    /// @param priceOracle The address of the price oracle
    /// @param creditAccount The address of the credit account
    /// @param twvUSDTarget The target TWV in USD
    /// @param collateralHints Hints for the collateral tokens
    /// @param collateralTokenByMaskFn Function to get the token address and liquidation threshold by mask
    /// @param convertToUSDFn Function to convert token value to USD
    /// @return totalValueUSD The total collateral value in USD
    /// @return twvUSD The total weighted value in USD
    /// @return tokensToDisable The mask of tokens to disable
    function calcNonQuotedTokensCollateral(
        address creditAccount,
        uint256 twvUSDTarget,
        uint256[] memory collateralHints,
        function(address, uint256, address)
            view
            returns (uint256) convertToUSDFn,
        function(uint256, bool)
            view
            returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokensToCheckMask,
        address priceOracle
    )
        internal
        view
        returns (uint256 totalValueUSD, uint256 twvUSD, uint256 tokensToDisable)
    {
        uint256 len = collateralHints.length; // Get the length of collateral hints array

        address ca = creditAccount;
        uint256 i;
        while (tokensToCheckMask != 0) {
            uint256 tokenMask;

            if (i < len) {
                tokenMask = collateralHints[i];
                unchecked {
                    ++i;
                }
                if (tokensToCheckMask & tokenMask == 0) continue;
            } else {
                tokenMask =
                    tokensToCheckMask &
                    uint256(-int256(tokensToCheckMask));
            }

            bool nonZero;
            {
                uint256 valueUSD;
                uint256 weightedValueUSD;
                // Calculate value for one non-quoted token
                (
                    valueUSD,
                    weightedValueUSD,
                    nonZero
                ) = calcOneNonQuotedCollateral({
                    priceOracle: priceOracle,
                    creditAccount: ca,
                    tokenMask: tokenMask,
                    convertToUSDFn: convertToUSDFn,
                    collateralTokenByMaskFn: collateralTokenByMaskFn
                });
                totalValueUSD += valueUSD; // Add value to totalValueUSD
                twvUSD += weightedValueUSD; // Add weighted value to twvUSD
            }
            if (nonZero) {
                if (twvUSD >= twvUSDTarget) {
                    break; // Break loop if target TWV is reached
                }
            } else {
                tokensToDisable = tokensToDisable | tokenMask; // Mark token to disable if balance is zero
            }
            tokensToCheckMask = tokensToCheckMask & ~tokenMask; // Update mask to check next token
        }
    }

    /// @notice Calculates the collateral value for one non-quoted token
    /// @param priceOracle The address of the price oracle
    /// @param creditAccount The address of the credit account
    /// @param tokenMask The mask of the token
    /// @param convertToUSDFn Function to convert token value to USD
    /// @param collateralTokenByMaskFn Function to get the token address and liquidation threshold by mask
    /// @return valueUSD The collateral value in USD
    /// @return weightedValueUSD The weighted collateral value in USD
    /// @return nonZeroBalance True if the token balance is non-zero
    function calcOneNonQuotedCollateral(
        address creditAccount,
        function(address, uint256, address)
            view
            returns (uint256) convertToUSDFn,
        function(uint256, bool)
            view
            returns (address, uint16) collateralTokenByMaskFn,
        uint256 tokenMask,
        address priceOracle
    )
        internal
        view
        returns (
            uint256 valueUSD,
            uint256 weightedValueUSD,
            bool nonZeroBalance
        )
    {
        (address token, uint16 liquidationThreshold) = collateralTokenByMaskFn(
            tokenMask,
            true
        ); // Get token address and liquidation threshold

        // Calculate collateral for one token
        (valueUSD, weightedValueUSD, nonZeroBalance) = calcOneTokenCollateral({
            priceOracle: priceOracle,
            creditAccount: creditAccount,
            token: token,
            liquidationThreshold: liquidationThreshold,
            convertToUSDFn: convertToUSDFn
        });
    }

    /// @notice Calculates the collateral value and weighted value for one token
    /// @param priceOracle The address of the price oracle
    /// @param creditAccount The address of the credit account
    /// @param token The address of the token
    /// @param liquidationThreshold The liquidation threshold of the token
    /// @param convertToUSDFn Function to convert token value to USD
    /// @return valueUSD The collateral value in USD
    /// @return weightedValueUSD The weighted collateral value in USD
    /// @return nonZeroBalance True if the token balance is non-zero
    function calcOneTokenCollateral(
        address creditAccount,
        function(address, uint256, address)
            view
            returns (uint256) convertToUSDFn,
        address priceOracle,
        address token,
        uint16 liquidationThreshold
    )
        internal
        view
        returns (
            uint256 valueUSD,
            uint256 weightedValueUSD,
            bool nonZeroBalance
        )
    {
        uint256 balance = IERC20(token).balanceOf({account: creditAccount}); // Get token balance from credit account

        if (balance > 1) {
            unchecked {
                valueUSD = convertToUSDFn(priceOracle, balance - 1, token); // Convert token balance to USD
            }
            weightedValueUSD = (valueUSD * liquidationThreshold) / 10000; // Calculate weighted value
            nonZeroBalance = true; // Set non-zero balance flag
        }
    }
}
