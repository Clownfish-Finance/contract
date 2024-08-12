// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {CreditLogic} from "../libraries/CreditLogic.sol";
import "../interfaces/IPool.sol";
import "../interfaces/IAddressProvider.sol";
import "../interfaces/ILinearInterestRateModel.sol";

/// @dev Struct that holds borrowed amount and debt limit
struct DebtParams {
    uint128 borrowed;
    uint128 limit;
}

/// @title Pool
/// @notice Pool contract that implements lending and borrowing logic, compatible with ERC-4626 standard
/// @notice Pool shares implement EIP-2612 permits
contract Pool is ERC4626, ERC20Permit, IPool, ReentrancyGuard {
    using Math for uint256;
    using SafeCast for int256;
    using SafeCast for uint256;
    using CreditLogic for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /// @notice Contract version
    // uint256 public constant  version = 3_00;

    /// @notice Address provider contract address
    address public immutable addressProvider;

    /// @notice Underlying token address
    address public immutable underlyingToken;

    /// @notice Protocol treasury address
    address public immutable treasury;

    /// @notice Interest rate model contract address
    address public interestRateModel;
    /// @notice Timestamp of the last base interest rate and index update
    uint40 public lastBaseInterestUpdate;
    /// @notice Timestamp of the last quota revenue update
    uint40 public lastQuotaRevenueUpdate;
    /// @notice Withdrawal fee in bps
    uint16 public withdrawFee;

    /// @notice Pool quota keeper contract address
    address public poolQuotaKeeper;
    /// @dev Current quota revenue
    uint96 internal _quotaRevenue;

    /// @dev Current base interest rate in ray
    uint128 internal _baseInterestRate;
    /// @dev Cumulative base interest index stored as of last update in ray
    uint128 internal _baseInterestIndexLU;

    /// @dev Expected liquidity stored as of last update
    uint128 internal _expectedLiquidityLU;

    /// @dev Aggregate debt params
    DebtParams internal _totalDebt;

    /// @dev Mapping credit manager => debt params
    mapping(address => DebtParams) internal _creditManagerDebt;

    /// @dev List of all connected credit managers
    EnumerableSet.AddressSet internal _creditManagerSet;

    /// @dev Ensures that function can only be called by the pool quota keeper
    // modifier poolQuotaKeeperOnly() {
    //     _revertIfCallerIsNotPoolQuotaKeeper();
    //     _;
    // }

    // function _revertIfCallerIsNotPoolQuotaKeeper() internal view {
    //     if (msg.sender != poolQuotaKeeper)
    //         revert CallerNotPoolQuotaKeeperException(); // U:[LP-2C]
    // }

    /// @notice Constructor
    /// @param addressProvider_ Address provider contract address
    /// @param underlyingToken_ Pool underlying token address
    /// @param interestRateModel_ Interest rate model contract address
    /// @param name_ Name of the pool
    /// @param symbol_ Symbol of the pool's LP token
    constructor(
        address addressProvider_,
        address underlyingToken_,
        address interestRateModel_,
        string memory name_,
        string memory symbol_
    )
        ERC4626(IERC20(underlyingToken_))
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        addressProvider = addressProvider_;
        underlyingToken = underlyingToken_;

        // treasury = IAddressProvider(addressProvider_).getAddressOrRevert({
        //     key: AP_TREASURY
        // });

        lastBaseInterestUpdate = uint40(block.timestamp);
        _baseInterestIndexLU = uint128(RAY);

        interestRateModel = interestRateModel_;
        emit SetInterestRateModel(interestRateModel_);
    }

    /// @notice Pool shares decimals, matches underlying token decimals
    function decimals() public view override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }

    /// @notice Addresses of all connected credit managers
    function creditManagers()
        external
        view
        override
        returns (address[] memory)
    {
        return _creditManagerSet.values();
    }

    /// @notice Available liquidity in the pool
    function availableLiquidity() public view override returns (uint256) {
        return IERC20(underlyingToken).balanceOf(address(this));
    }

    /// @notice Amount of underlying that would be in the pool if debt principal, base interest
    ///         and quota revenue were fully repaid
    function expectedLiquidity() public view override returns (uint256) {
        // return _expectedLiquidityLU + _calcBaseInterestAccrued() + _calcQuotaRevenueAccrued(); // U:[LP-4]
        return _expectedLiquidityLU + _calcBaseInterestAccrued();
    }

    /// @notice Expected liquidity stored as of last update
    function expectedLiquidityLU() public view override returns (uint256) {
        return _expectedLiquidityLU;
    }

    // ---------------- //
    // ERC-4626 LENDING //
    // ---------------- //

    /// @notice Total amount of underlying tokens managed by the pool, same as `expectedLiquidity`
    /// @dev Since `totalAssets` doesn't depend on underlying balance, pool is not vulnerable to the inflation attack
    function totalAssets() public view override returns (uint256 assets) {
        return expectedLiquidity();
    }

    /// @notice Deposits given amount of underlying tokens to the pool in exchange for pool shares
    /// @param assets Amount of underlying to deposit
    /// @param receiver Account to mint pool shares to
    /// @return shares Number of shares minted
    function deposit(
        uint256 assets,
        address receiver
    ) public override nonReentrant returns (uint256 shares) {
        uint256 assetsReceived = _amountMinusFee(assets);
        shares = _convertToShares(assetsReceived, Math.Rounding.Floor);
        _deposit(receiver, assets, assetsReceived, shares);
    }

    /// @notice Deposits underlying tokens to the pool in exhcange for given number of pool shares
    /// @param shares Number of shares to mint
    /// @param receiver Account to mint pool shares to
    /// @return assets Amount of underlying transferred from caller
    function mint(
        uint256 shares,
        address receiver
    ) public override nonReentrant returns (uint256 assets) {
        uint256 assetsReceived = _convertToAssets(shares, Math.Rounding.Ceil);
        assets = _amountWithFee(assetsReceived);
        _deposit(receiver, assets, assetsReceived, shares);
    }

    function mintWithReferral(
        uint256 shares,
        address receiver,
        uint256 referralCode
    ) external override returns (uint256 assets){
        return 0;
    }

    function depositWithReferral(
        uint256 assets,
        address receiver,
        uint256 referralCode
    ) external override returns (uint256 shares){
        return 0;
    }

    /// @notice Withdraws pool shares for given amount of underlying tokens
    /// @param assets Amount of underlying to withdraw
    /// @param receiver Account to send underlying to
    /// @param owner Account to burn pool shares from
    /// @return shares Number of pool shares burned
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        uint256 assetsToUser = _amountWithFee(assets);
        uint256 assetsSent = _amountWithWithdrawalFee(assetsToUser);
        shares = _convertToShares(assetsSent, Math.Rounding.Ceil);
        _withdraw(receiver, owner, assetsSent, assets, assetsToUser, shares);
    }

    /// @notice Redeems given number of pool shares for underlying tokens
    /// @param shares Number of pool shares to redeem
    /// @param receiver Account to send underlying to
    /// @param owner Account to burn pool shares from
    /// @return assets Amount of underlying withdrawn
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 assets) {
        uint256 assetsSent = _convertToAssets(shares, Math.Rounding.Floor);
        uint256 assetsToUser = _amountMinusWithdrawalFee(assetsSent);
        assets = _amountMinusFee(assetsToUser);
        _withdraw(receiver, owner, assetsSent, assets, assetsToUser, shares);
    }

    /// @notice Number of pool shares that would be minted on depositing `assets`
    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256 shares) {
        shares = _convertToShares(_amountMinusFee(assets), Math.Rounding.Floor);
    }

    /// @notice Amount of underlying that would be spent to mint `shares`
    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        return _amountWithFee(_convertToAssets(shares, Math.Rounding.Ceil));
    }

    /// @notice Number of pool shares that would be burned on withdrawing `assets`
    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        return
            _convertToShares(
                _amountWithWithdrawalFee(_amountWithFee(assets)),
                Math.Rounding.Ceil
            );
    }

    /// @notice Amount of underlying that would be received after redeeming `shares`
    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        return
            _amountMinusFee(
                _amountMinusWithdrawalFee(
                    _convertToAssets(shares, Math.Rounding.Floor)
                )
            );
    }

    /// @notice Maximum amount of underlying that can be deposited to the pool, 0 if pool is on pause
    function maxDeposit() public view returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum number of pool shares that can be minted, 0 if pool is on pause
    function maxMint(address) public view override returns (uint256) {
        return type(uint256).max;
    }

    /// @notice Maximum amount of underlying that can be withdrawn from the pool by `owner`, 0 if pool is on pause
    function maxWithdraw(address owner) public view override returns (uint256) {
        return
            _amountMinusFee(
                _amountMinusWithdrawalFee(
                    Math.min(
                        availableLiquidity(),
                        _convertToAssets(balanceOf(owner), Math.Rounding.Floor)
                    )
                )
            );
    }

    /// @notice Maximum number of shares that can be redeemed for underlying by `owner`, 0 if pool is on pause
    function maxRedeem(address owner) public view override returns (uint256) {
        return
            Math.min(
                balanceOf(owner),
                _convertToShares(availableLiquidity(), Math.Rounding.Floor)
            );
    }

    /// @dev `withdraw` / `redeem` implementation
    ///      - burns pool shares from `owner`
    ///      - updates base interest rate and index
    ///      - transfers underlying to `receiver` and, if withdrawal fee is activated, to the treasury
    function _withdraw(
        address receiver,
        address owner,
        uint256 assetsSent,
        uint256 assetsReceived,
        uint256 amountToUser,
        uint256 shares
    ) internal {
        if (msg.sender != owner)
            _spendAllowance({
                owner: owner,
                spender: msg.sender,
                value: shares
            });
        _burn(owner, shares);

        _updateBaseInterest({
            expectedLiquidityDelta: -assetsSent.toInt256(),
            availableLiquidityDelta: -assetsSent.toInt256()
        });

        IERC20(underlyingToken).safeTransfer({
            to: receiver,
            value: amountToUser
        });
        // if (assetsSent > amountToUser) {
        //     unchecked {
        //         IERC20(underlyingToken).safeTransfer({
        //             to: treasury,
        //             value: assetsSent - amountToUser
        //         });
        //     }
        // }
        emit Withdraw(msg.sender, receiver, owner, assetsReceived, shares);
    }

    /// @dev Internal conversion function (from shares to assets) with support for rounding direction
    /// @dev Pool is not vulnerable to the inflation attack, so the simplified implementation w/o virtual shares is used
    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256 assets) {
        uint256 supply = totalSupply();
        return
            (supply == 0)
                ? shares
                : shares.mulDiv(totalAssets(), supply, rounding);
    }

    /// @dev `deposit` / `mint` implementation
    ///      - transfers underlying from the caller
    ///      - updates base interest rate and index
    ///      - mints pool shares to `receiver`
    function _deposit(
        address receiver,
        uint256 assetsSent,
        uint256 assetsReceived,
        uint256 shares
    ) internal {
        IERC20(underlyingToken).safeTransferFrom({
            from: msg.sender,
            to: address(this),
            value: assetsSent
        });

        _updateBaseInterest({
            expectedLiquidityDelta: assetsReceived.toInt256(),
            availableLiquidityDelta: 0
        });

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assetsSent, shares);
    }

    /// @dev Internal conversion function (from assets to shares) with support for rounding direction
    /// @dev Pool is not vulnerable to the inflation attack, so the simplified implementation w/o virtual shares is used
    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256 shares) {
        uint256 supply = totalSupply();
        return
            (assets == 0 || supply == 0)
                ? assets
                : assets.mulDiv(supply, totalAssets(), rounding);
    }

    // --------- //
    // BORROWING //
    // --------- //

    /// @notice Total borrowed amount (principal only)
    function totalBorrowed() external view override returns (uint256) {
        return _totalDebt.borrowed;
    }

    /// @notice Total debt limit, `type(uint256).max` means no limit
    function totalDebtLimit() external view override returns (uint256) {
        return 0;
    }

    /// @notice Amount borrowed by a given credit manager
    function creditManagerBorrowed(
        address creditManager
    ) external view override returns (uint256) {
        return _creditManagerDebt[creditManager].borrowed;
    }

    /// @notice Debt limit for a given credit manager, `type(uint256).max` means no limit
    function creditManagerDebtLimit(
        address creditManager
    ) external view override returns (uint256) {
        return 0;
    }

    /// @notice Amount available to borrow for a given credit manager
    function creditManagerBorrowable(
        address creditManager
    ) external view override returns (uint256 borrowable) {
        return 0;
    }

    /// @notice Lends funds to a credit account, can only be called by credit managers
    /// @param borrowedAmount Amount to borrow
    /// @param creditAccount Credit account to send the funds to
    function lendCreditAccount(
        uint256 borrowedAmount,
        address creditAccount
    ) external override nonReentrant {
        uint128 borrowedAmountU128 = borrowedAmount.toUint128();

        DebtParams storage cmDebt = _creditManagerDebt[msg.sender];
        uint128 totalBorrowed_ = _totalDebt.borrowed + borrowedAmountU128;
        uint128 cmBorrowed_ = cmDebt.borrowed + borrowedAmountU128;
        if (
            borrowedAmount == 0 ||
            cmBorrowed_ > cmDebt.limit ||
            totalBorrowed_ > _totalDebt.limit
        ) {
            revert CreditManagerCantBorrowException();
        }

        _updateBaseInterest({
            expectedLiquidityDelta: 0,
            availableLiquidityDelta: -borrowedAmount.toInt256()
        });

        cmDebt.borrowed = cmBorrowed_;
        _totalDebt.borrowed = totalBorrowed_;

        IERC20(underlyingToken).safeTransfer({
            to: creditAccount,
            value: borrowedAmount
        });
        emit Borrow(msg.sender, creditAccount, borrowedAmount);
    }

    /// @notice Updates pool state to indicate debt repayment, can only be called by credit managers
    ///         after transferring underlying from a credit account to the pool.
    ///         - If transferred amount exceeds debt principal + base interest + quota interest,
    ///           the difference is deemed protocol's profit and the respective number of shares
    ///           is minted to the treasury.
    ///         - If, however, transferred amount is insufficient to repay debt and interest,
    ///           which may only happen during liquidation, treasury's shares are burned to
    ///           cover as much of the loss as possible.
    /// @param repaidAmount Amount of debt principal repaid
    /// @param profit Pool's profit in underlying after repaying
    /// @param loss Pool's loss in underlying after repaying
    /// @custom:expects Credit manager transfers underlying from a credit account to the pool before calling this function
    /// @custom:expects Profit/loss computed in the credit manager are cosistent with pool's implicit calculations
    function repayCreditAccount(
        uint256 repaidAmount,
        uint256 profit,
        uint256 loss
    ) external override nonReentrant {}

    /// @dev Returns borrowable amount based on debt limit and current borrowed amount
    function _borrowable(
        DebtParams storage debt
    ) internal view returns (uint256) {
        uint256 limit = debt.limit;
        if (limit == type(uint128).max) {
            return type(uint256).max;
        }
        uint256 borrowed = debt.borrowed;
        if (borrowed >= limit) return 0;
        unchecked {
            return limit - borrowed;
        }
    }

    // ------------- //
    // INTEREST RATE //
    // ------------- //

    /// @notice Annual interest rate in ray that credit account owners pay per unit of borrowed capital
    function baseInterestRate() public view override returns (uint256) {
        return _baseInterestRate;
    }

    /// @notice Annual interest rate in ray that liquidity providers receive per unit of deposited capital,
    ///         consists of base interest and quota revenue
    function supplyRate() external view override returns (uint256) {
        return 0;
    }

    /// @notice Current cumulative base interest index in ray
    function baseInterestIndex() public view override returns (uint256) {
        return 0;
    }

    /// @notice Cumulative base interest index stored as of last update in ray
    function baseInterestIndexLU() external view override returns (uint256) {
        return _baseInterestIndexLU;
    }

    /// @dev Updates base interest rate based on expected and available liquidity deltas
    ///      - Adds expected liquidity delta to stored expected liquidity
    ///      - If time has passed since the last base interest update, adds accrued interest
    ///        to stored expected liquidity, updates interest index and last update timestamp
    ///      - If time has passed since the last quota revenue update, adds accrued revenue
    ///        to stored expected liquidity and updates last update timestamp
    function _updateBaseInterest(
        int256 expectedLiquidityDelta,
        int256 availableLiquidityDelta
    ) internal {
        uint256 expectedLiquidity_ = (expectedLiquidity().toInt256() +
            expectedLiquidityDelta).toUint256();
        uint256 availableLiquidity_ = (availableLiquidity().toInt256() +
            availableLiquidityDelta).toUint256();

        uint256 lastBaseInterestUpdate_ = lastBaseInterestUpdate;
        if (block.timestamp != lastBaseInterestUpdate_) {
            _baseInterestIndexLU = _calcBaseInterestIndex(
                lastBaseInterestUpdate_
            ).toUint128();
            lastBaseInterestUpdate = uint40(block.timestamp);
        }

        // if (block.timestamp != lastQuotaRevenueUpdate) {
        //     lastQuotaRevenueUpdate = uint40(block.timestamp);
        // }

        _expectedLiquidityLU = expectedLiquidity_.toUint128();
        _baseInterestRate = ILinearInterestRateModel(interestRateModel)
            .calcBorrowRate({
                expectedLiquidity: expectedLiquidity_,
                availableLiquidity: availableLiquidity_
            })
            .toUint128();
    }

    

    /// @dev Computes base interest accrued since the last update
    function _calcBaseInterestAccrued() internal view returns (uint256) {
        uint256 timestampLU = lastBaseInterestUpdate;
        if (block.timestamp == timestampLU) return 0;
        return _calcBaseInterestAccrued(timestampLU);
    }

    /// @dev Computes base interest accrued since given timestamp
    function _calcBaseInterestAccrued(
        uint256 timestamp
    ) private view returns (uint256) {
        return
            (_totalDebt.borrowed *
                baseInterestRate().calcLinearGrowth(timestamp)) / RAY;
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Returns amount of token that will be received if `amount` is transferred
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountMinusFee(
        uint256 amount
    ) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that should be transferred to receive `amount`
    ///      Pools with fee-on-transfer underlying should override this method
    function _amountWithFee(
        uint256 amount
    ) internal view virtual returns (uint256) {
        return amount;
    }

    /// @dev Returns amount of token that should be withdrawn so that `amount` is actually sent to the receiver
    function _amountWithWithdrawalFee(
        uint256 amount
    ) internal view returns (uint256) {
        return (amount * PERCENTAGE_FACTOR) / (PERCENTAGE_FACTOR - withdrawFee);
    }

    /// @dev Returns amount of token that would actually be sent to the receiver when withdrawing `amount`
    function _amountMinusWithdrawalFee(
        uint256 amount
    ) internal view returns (uint256) {
        return (amount * (PERCENTAGE_FACTOR - withdrawFee)) / PERCENTAGE_FACTOR;
    }

    /// @dev Computes current value of base interest index
    function _calcBaseInterestIndex(uint256 timestamp) private view returns (uint256) {
        return _baseInterestIndexLU * (RAY + baseInterestRate().calcLinearGrowth(timestamp)) / RAY;
    }

    // ------ //
    // QUOTAS //
    // ------ //

    /// @notice Current annual quota revenue in underlying tokens
    function quotaRevenue() public view override returns (uint256) {
        return _quotaRevenue;
    }

    /// @notice Updates quota revenue value by given delta
    /// @param quotaRevenueDelta Quota revenue delta
    function updateQuotaRevenue(
        int256 quotaRevenueDelta
    ) external override nonReentrant {}

    /// @notice Sets new quota revenue value
    /// @param newQuotaRevenue New quota revenue value
    function setQuotaRevenue(
        uint256 newQuotaRevenue
    )
        external
        override
        nonReentrant // U:[LP-2B]
    {
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    function setInterestRateModel(
        address newInterestRateModel
    ) external override {}

    function setPoolQuotaKeeper(address newPoolQuotaKeeper) external override {}

    function setTotalDebtLimit(uint256 newLimit) external override {}

    function setCreditManagerDebtLimit(
        address creditManager,
        uint256 newLimit
    ) external override {}

    function setWithdrawFee(uint256 newWithdrawFee) external override {}
}
