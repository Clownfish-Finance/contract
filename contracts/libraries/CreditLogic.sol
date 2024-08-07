// SPDX-License-Identifier: BUSL-1.1
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2023.
pragma solidity ^0.8.17;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CollateralDebtData} from "../interfaces/ICreditManager.sol";
import {BitMask} from "./BitMask.sol";

uint256 constant INDEX_PRECISION = 10 ** 9;
uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant SECONDS_PER_ONE_AND_HALF_YEAR = (SECONDS_PER_YEAR * 3) / 2;
uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals

/// @title Credit logic library
/// @notice Implements functions used for debt and repayment calculations
library CreditLogic {
    using BitMask for uint256;
    using SafeCast for uint256;

    // ----------------- //
    // DEBT AND INTEREST //
    // ----------------- //

    /// @dev Computes growth since last update given yearly growth
    function calcLinearGrowth(uint256 value, uint256 timestampLastUpdate) internal view returns (uint256) {
        return value * (block.timestamp - timestampLastUpdate) / SECONDS_PER_YEAR;
    }

    /// @dev Computes interest accrued since the last update
    function calcAccruedInterest(uint256 amount, uint256 cumulativeIndexLastUpdate, uint256 cumulativeIndexNow)
        internal
        pure
        returns (uint256)
    {
        if (amount == 0) return 0;
        return (amount * cumulativeIndexNow) / cumulativeIndexLastUpdate - amount;
    }

    /// @dev Computes total debt, given raw debt data
    /// @param collateralDebtData See `CollateralDebtData` (must have debt data filled)
    function calcTotalDebt(CollateralDebtData memory collateralDebtData) internal pure returns (uint256) {
        return collateralDebtData.debt + collateralDebtData.accruedInterest;
    }

    // ----------- //
    // MANAGE DEBT //
    // ----------- //

    /// @dev Computes new debt principal and interest index after increasing debt
    ///      - The new debt principal is simply `debt + amount`
    ///      - The new credit account's interest index is a solution to the equation
    ///        `debt * (indexNow / indexLastUpdate - 1) = (debt + amount) * (indexNow / indexNew - 1)`,
    ///        which essentially writes that interest accrued since last update remains the same
    /// @param amount Amount to increase debt by
    /// @param debt Debt principal before increase
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after increase
    /// @return newCumulativeIndex New credit account's interest index
    function calcIncrease(uint256 amount, uint256 debt, uint256 cumulativeIndexNow, uint256 cumulativeIndexLastUpdate)
        internal
        pure
        returns (uint256 newDebt, uint256 newCumulativeIndex)
    {
        if (debt == 0) return (amount, cumulativeIndexNow);
        newDebt = debt + amount;
        newCumulativeIndex = (
            (cumulativeIndexNow * newDebt * INDEX_PRECISION)
                / ((INDEX_PRECISION * cumulativeIndexNow * debt) / cumulativeIndexLastUpdate + INDEX_PRECISION * amount)
        );
    }

    /// @dev Computes new debt principal and interest index (and other values) after decreasing debt
    ///      - Debt comprises of multiple components which are repaid in the following order:
    ///        quota update fees => quota interest => base interest => debt principal.
    ///        New values for all these components depend on what portion of each was repaid.
    ///      - Debt principal, for example, only decreases if all previous components were fully repaid
    ///      - The new credit account's interest index stays the same if base interest was not repaid at all,
    ///        is set to the current interest index if base interest was repaid fully, and is a solution to
    ///        the equation `debt * (indexNow / indexLastUpdate - 1) - delta = debt * (indexNow / indexNew - 1)`
    ///        when only `delta` of accrued interest was repaid
    /// @param amount Amount of debt to repay
    /// @param debt Debt principal before repayment
    /// @param cumulativeIndexNow The current interest index
    /// @param cumulativeIndexLastUpdate Credit account's interest index as of last update
    /// @return newDebt Debt principal after repayment
    /// @return newCumulativeIndex Credit account's interest index after repayment
    function calcDecrease(
        uint256 amount,
        uint256 debt,
        uint256 cumulativeIndexNow,
        uint256 cumulativeIndexLastUpdate
    )
        internal
        pure
        returns (
            uint256 newDebt,
            uint256 newCumulativeIndex
        )
    {
        uint256 amountToRepay = amount;

        // Handle repayment of debt principal
        newDebt = debt - amountToRepay;
        
        if (amountToRepay != 0) {
            uint256 interestAccrued = calcAccruedInterest({
                amount: debt,
                cumulativeIndexLastUpdate: cumulativeIndexLastUpdate,
                cumulativeIndexNow: cumulativeIndexNow
            });

            if (amountToRepay >= interestAccrued) {
                amountToRepay -= interestAccrued;
                newCumulativeIndex = cumulativeIndexNow;
            } else {
                newCumulativeIndex = (INDEX_PRECISION * cumulativeIndexNow * cumulativeIndexLastUpdate)
                    / (
                        INDEX_PRECISION * cumulativeIndexNow
                            - (INDEX_PRECISION * amountToRepay * cumulativeIndexLastUpdate) / debt
                    );
            }
        } else {
            newCumulativeIndex = cumulativeIndexLastUpdate;
        }
    }
}
