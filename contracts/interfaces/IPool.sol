// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
// import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
uint256 constant WAD = 1e18;
uint256 constant RAY = 1e27;
uint16 constant PERCENTAGE_FACTOR = 1e4; //percentage plus two decimals

/// @title Pool  interface
interface IPool {
    /// @notice Emitted when depositing liquidity with referral code
    event Refer(
        address indexed onBehalfOf,
        uint256 indexed referralCode,
        uint256 amount
    );

    /// @notice Emitted when credit account borrows funds from the pool
    event Borrow(
        address indexed creditManager,
        address indexed creditAccount,
        uint256 amount
    );

    /// @notice Emitted when credit account's debt is repaid to the pool
    event Repay(
        address indexed creditManager,
        uint256 borrowedAmount,
        uint256 profit,
        uint256 loss
    );

    /// @notice Emitted when incurred loss can't be fully covered by burning treasury's shares
    event IncurUncoveredLoss(address indexed creditManager, uint256 loss);

    /// @notice Emitted when new interest rate model contract is set
    event SetInterestRateModel(address indexed newInterestRateModel);

    /// @notice Emitted when new pool quota keeper contract is set
    event SetPoolQuotaKeeper(address indexed newPoolQuotaKeeper);

    /// @notice Emitted when new total debt limit is set
    event SetTotalDebtLimit(uint256 limit);

    /// @notice Emitted when new credit manager is connected to the pool
    event AddCreditManager(address indexed creditManager);

    /// @notice Emitted when new debt limit is set for a credit manager
    event SetCreditManagerDebtLimit(
        address indexed creditManager,
        uint256 newLimit
    );
    /// @notice Thrown when a credit manager attempts to borrow more than its limit in the current block, or in general
    error CreditManagerCantBorrowException();

    /// @notice Emitted when new withdrawal fee is set
    event SetWithdrawFee(uint256 fee);

    function addressProvider() external view returns (address);

    function underlyingToken() external view returns (address);

    function treasury() external view returns (address);

    function withdrawFee() external view returns (uint16);

    function creditManagers() external view returns (address[] memory);

    function availableLiquidity() external view returns (uint256);

    function expectedLiquidity() external view returns (uint256);

    function expectedLiquidityLU() external view returns (uint256);

    // ---------------- //
    // ERC-4626 LENDING //
    // ---------------- //

    function depositWithReferral(
        uint256 assets,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 shares);

    function mintWithReferral(
        uint256 shares,
        address receiver,
        uint256 referralCode
    ) external returns (uint256 assets);

    // --------- //
    // BORROWING //
    // --------- //

    function totalBorrowed() external view returns (uint256);

    function totalDebtLimit() external view returns (uint256);

    function creditManagerBorrowed(
        address creditManager
    ) external view returns (uint256);

    function creditManagerDebtLimit(
        address creditManager
    ) external view returns (uint256);

    function creditManagerBorrowable(
        address creditManager
    ) external view returns (uint256 borrowable);

    function lendCreditAccount(
        uint256 borrowedAmount,
        address creditAccount
    ) external;

    function repayCreditAccount(
        uint256 repaidAmount,
        uint256 profit,
        uint256 loss
    ) external;

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    function interestRateModel() external view returns (address);

    function baseInterestRate() external view returns (uint256);

    function supplyRate() external view returns (uint256);

    function baseInterestIndex() external view returns (uint256);

    function baseInterestIndexLU() external view returns (uint256);

    function lastBaseInterestUpdate() external view returns (uint40);

    // ------ //
    // QUOTAS //
    // ------ //

    function poolQuotaKeeper() external view returns (address);

    function quotaRevenue() external view returns (uint256);

    function lastQuotaRevenueUpdate() external view returns (uint40);

    function updateQuotaRevenue(int256 quotaRevenueDelta) external;

    function setQuotaRevenue(uint256 newQuotaRevenue) external;

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setInterestRateModel(address newInterestRateModel) external;

    function setPoolQuotaKeeper(address newPoolQuotaKeeper) external;

    function setTotalDebtLimit(uint256 newLimit) external;

    function setCreditManagerDebtLimit(
        address creditManager,
        uint256 newLimit
    ) external;

    function setWithdrawFee(uint256 newWithdrawFee) external;
}
