// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;


import "./IAddressProvider.sol";
import "./ICreditManager.sol";

interface IAdapterExceptions {
    /// @notice Thrown when adapter tries to use a token that's not a collateral token of the connected Credit Manager
    error TokenNotAllowedException();

    /// @notice Thrown when caller of a `creditFacadeOnly` function is not the Credit Facade
    error CreditFacadeOnlyException();

    /// @notice Thrown when caller of a `configuratorOnly` function is not configurator
    error CallerNotConfiguratorException();
}

interface IAdapter is IAdapterExceptions {
    /// @notice Credit Manager the adapter is connected to
    // function creditManager() external view returns (ICreditManager);

    /// @notice Address of the contract the adapter is interacting with
    function targetContract() external view returns (address);

    /// @notice Address provider
    // function addressProvider() external view returns (IAddressProvider);
}