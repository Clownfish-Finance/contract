// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

struct PriceFeedParams {
    address priceFeed;
    uint32 stalenessPeriod;
    bool skipCheck;
    uint8 decimals;
    bool useReserve;
    bool trusted;
}

/// @title Price oracle  interface
interface IPriceOracle {
    /// @notice Emitted when new price feed is set for token
    event SetPriceFeed(
        address indexed token,
        address indexed priceFeed,
        uint32 stalenessPeriod,
        bool skipCheck,
        bool trusted
    );

    /// @notice Emitted when new reserve price feed is set for token
    event SetReservePriceFeed(
        address indexed token,
        address indexed priceFeed,
        uint32 stalenessPeriod,
        bool skipCheck
    );

    /// @notice Emitted when new reserve price feed status is set for a token
    event SetReservePriceFeedStatus(address indexed token, bool active);

    function getPriceSafe(address token) external view returns (uint256);

    function getPriceRaw(
        address token,
        bool reserve
    ) external view returns (uint256);

    function priceFeedsRaw(
        address token,
        bool reserve
    ) external view returns (address);

    function priceFeedParams(
        address token
    )
        external
        view
        returns (
            address priceFeed,
            uint32 stalenessPeriod,
            bool skipCheck,
            uint8 decimals,
            bool trusted
        );

    function safeConvertToUSD(
        uint256 amount,
        address token
    ) external view returns (uint256);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setPriceFeed(
        address token,
        address priceFeed,
        uint32 stalenessPeriod,
        bool trusted
    ) external;

    function setReservePriceFeed(
        address token,
        address priceFeed,
        uint32 stalenessPeriod
    ) external;

    function setReservePriceFeedStatus(address token, bool active) external;

    function convertFromUSD(
        uint256 amount,
        address token
    ) external returns (uint256);
}
