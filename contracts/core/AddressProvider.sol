// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.17;

import "../interfaces/IAddressProvider.sol";

/// @title Address provider 
/// @notice Stores addresses of important contracts
contract AddressProvider is IAddressProvider {
    /// @notice Mapping from key to contract addresses
    mapping(bytes32 => address) public override addresses;
    
    /// @notice Returns the address of a contract with a given key and version
    function getAddressOrRevert(
        bytes32 key
    ) public view virtual override returns (address result) {
        result = addresses[key];
        if (result == address(0)) revert AddressNotFoundException();
    }

    /// @notice Sets the address for the passed contract key
    /// @param key Contract key
    /// @param value Contract address
    function setAddress(bytes32 key, address value) external override {
        _setAddress(key, value);
    }

    /// @dev Implementation of `setAddress`
    function _setAddress(bytes32 key, address value) internal virtual {
        addresses[key] = value;
        emit SetAddress(key, value);
    }

    /// @notice Contracts register contract address
    function getContractsRegister() external view returns (address) {
        return getAddressOrRevert(AP_CONTRACTS_REGISTER);
    }

    /// @notice Price oracle contract address
    function getPriceOracle() external view returns (address) {
        return getAddressOrRevert(AP_PRICE_ORACLE);
    }

    /// @notice Account factory contract address
    function getAccountFactory() external view returns (address) {
        return getAddressOrRevert(AP_ACCOUNT_FACTORY);
    }

    /// @notice Data compressor contract address
    function getDataCompressor() external view returns (address) {
        return getAddressOrRevert(AP_DATA_COMPRESSOR);
    }

    /// @notice Treasury contract address
    function getTreasuryContract() external view returns (address) {
        return getAddressOrRevert(AP_TREASURY);
    }

    /// @notice WETH token address
    function getWethToken() external view returns (address) {
        return getAddressOrRevert(AP_WETH_TOKEN);
    }

    /// @notice WETH gateway contract address
    function getWETHGateway() external view returns (address) {
        return getAddressOrRevert(AP_WETH_GATEWAY);
    }

    /// @notice Router contract address
    function getLeveragedActions() external view returns (address) {
        return getAddressOrRevert(AP_ROUTER);
    }
}
