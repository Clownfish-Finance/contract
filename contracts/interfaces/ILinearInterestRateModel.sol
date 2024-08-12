// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;



/// @title Linear interest rate model  interface
interface ILinearInterestRateModel {
    /// @notice Thrown on incorrect input parameter
    error IncorrectParameterException();
    /// @notice Thrown when attempting to borrow more than the second point on a two-point curve
    error BorrowingMoreThanU2ForbiddenException();

    function calcBorrowRate(
        uint256 expectedLiquidity,
        uint256 availableLiquidity
    ) external view returns (uint256);

    function availableToBorrow(
        uint256 expectedLiquidity,
        uint256 availableLiquidity
    ) external view returns (uint256);

    function isBorrowingMoreU2Forbidden() external view returns (bool);

    function getModelParameters()
        external
        view
        returns (
            uint16 U_1,
            uint16 U_2,
            uint16 R_base,
            uint16 R_slope1,
            uint16 R_slope2,
            uint16 R_slope3
        );
}
