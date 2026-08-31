// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/contracts/interfaces/IPriceOracleGetter.sol";
import {IAToken} from "@aave/contracts/interfaces/IAToken.sol";
import {IVariableDebtToken} from "@aave/contracts/interfaces/IVariableDebtToken.sol";
import {IReserveInterestRateStrategy} from "@aave/contracts/interfaces/IReserveInterestRateStrategy.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {WadRayMath} from "@aave/contracts/protocol/libraries/math/WadRayMath.sol";
import {PercentageMath} from "@aave/contracts/protocol/libraries/math/PercentageMath.sol";
import {TokenMath} from "@aave/contracts/protocol/libraries/helpers/TokenMath.sol";
import {Errors as AaveV3Errors} from "@aave/contracts/protocol/libraries/helpers/Errors.sol";
import {MathUtils} from "@aave/contracts/protocol/libraries/math/MathUtils.sol";

import {MathLib} from "../../../src/libraries/MathLib.sol";
import {WAD, SECONDS_PER_YEAR} from "../../../src/libraries/ConstantsLib.sol";

library AaveV3Utils {
    using MathLib for uint128;
    using MathLib for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using TokenMath for uint256;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    /* MIN/MAX AMOUNT */

    /// @dev Returns the minimum collateral amount required to borrow a given amount of debt at the current block.
    function minCollateralAmount(uint256 amount, address pool, address collateralToken, address debtToken)
        internal
        view
        returns (uint256)
    {
        return minCollateralAmount(0, amount, pool, collateralToken, debtToken);
    }

    /// @dev `elapsed` projects the reserve indices forward to a future (e.g. refinance) time, so the rounding
    /// reflects the indices Aave will use then. Index growth shrinks the collateral's borrowing capacity, so a
    /// floor sized at the current indices comes up short once time has passed. Pass 0 for the current block.
    function minCollateralAmount(
        uint256 elapsed,
        uint256 amount,
        address pool,
        address collateralToken,
        address debtToken
    ) internal view returns (uint256) {
        IPool aavePool = IPool(pool);
        DataTypes.ReserveDataLegacy memory collateralReserve = aavePool.getReserveData(collateralToken);
        DataTypes.ReserveDataLegacy memory debtReserve = aavePool.getReserveData(debtToken);
        IPriceOracleGetter oracle = IPriceOracleGetter(aavePool.ADDRESSES_PROVIDER().getPriceOracle());

        uint256 ltv = collateralReserve.configuration.getLtv();
        require(ltv != 0, "AaveV3Utils: Zero collateral ltv");

        uint256 debtUnit = 10 ** ERC20(debtToken).decimals();
        uint256 collateralUnit = 10 ** ERC20(collateralToken).decimals();
        uint256 debtPrice = oracle.getAssetPrice(debtToken);
        uint256 collateralPrice = oracle.getAssetPrice(collateralToken);

        // Project both indices to refinance time, mirroring `maxSupplyCapacity`: the variable borrow index
        // compounds (rounded up, conservative); the collateral liquidity index is rebuilt from the stored
        // index over a single floored span (`getReserveNormalizedIncome × (1 + rate*elapsed)` would split it
        // into two floored steps and can land 1 ulp low, under-sizing the floor by a wei).
        uint256 debtIndex = aavePool.getReserveNormalizedVariableDebt(debtToken)
            .rayMulCeil(MathUtils.calculateCompoundedInterest(debtReserve.currentVariableBorrowRate, 0, elapsed));
        uint256 liquidityIndex = (WadRayMath.RAY
                + collateralReserve.currentLiquidityRate
                    .mulDivDown(block.timestamp + elapsed - collateralReserve.lastUpdateTimestamp, SECONDS_PER_YEAR))
        .rayMul(collateralReserve.liquidityIndex);

        uint256 actualDebt = amount.getVTokenMintScaledAmount(debtIndex).getVTokenBalance(debtIndex);
        uint256 debtBase = actualDebt.mulDivUp(debtPrice, debtUnit);
        uint256 requiredCollateralBase = debtBase.percentDivCeil(ltv);
        uint256 requiredCollateralBalance = requiredCollateralBase.mulDivUp(collateralUnit, collateralPrice);

        // Account for Aave's two floor roundings: supply amount to aToken shares, then shares to balance.
        return requiredCollateralBalance.rayDivCeil(liquidityIndex).rayMulCeil(liquidityIndex);
    }

    /// @dev Returns the maximum borrow amount for a given collateral amount.
    function maxBorrowAmount(uint256 amount, address pool, address collateralToken, address debtToken)
        internal
        view
        returns (uint256)
    {
        DataTypes.ReserveConfigurationMap memory configuration = IPool(pool).getConfiguration(collateralToken);
        return _maxDebtAmount(amount, pool, collateralToken, debtToken, configuration.getLtv());
    }

    /// @dev Returns the maximum debt amount for a given collateral amount.
    function maxDebtAmount(uint256 amount, address pool, address collateralToken, address debtToken)
        internal
        view
        returns (uint256)
    {
        DataTypes.ReserveConfigurationMap memory configuration = IPool(pool).getConfiguration(collateralToken);
        return _maxDebtAmount(amount, pool, collateralToken, debtToken, configuration.getLiquidationThreshold());
    }

    function _maxDebtAmount(uint256 amount, address pool, address collateralToken, address debtToken, uint256 ltv)
        private
        view
        returns (uint256)
    {
        if (amount == 0 || ltv == 0) return 0;

        IPool aavePool = IPool(pool);
        IPriceOracleGetter oracle = IPriceOracleGetter(aavePool.ADDRESSES_PROVIDER().getPriceOracle());

        uint256 debtUnit = 10 ** ERC20(debtToken).decimals();
        uint256 collateralUnit = 10 ** ERC20(collateralToken).decimals();
        uint256 debtPrice = oracle.getAssetPrice(debtToken);
        uint256 collateralPrice = oracle.getAssetPrice(collateralToken);
        uint256 liquidityIndex = aavePool.getReserveNormalizedIncome(collateralToken);
        uint256 scaledCollateral = amount.getATokenMintScaledAmount(liquidityIndex);

        if (scaledCollateral == 0) return 0;

        uint256 collateralBalance = scaledCollateral.getATokenBalance(liquidityIndex);
        uint256 collateralBase = collateralBalance.mulDivDown(collateralPrice, collateralUnit);
        uint256 maxDebtBase = collateralBase.percentMulFloor(ltv);
        uint256 maxActualDebt = maxDebtBase.mulDivDown(debtUnit, debtPrice);
        uint256 debtIndex = aavePool.getReserveNormalizedVariableDebt(debtToken);
        // Account for Aave's two ceil roundings: borrow amount to vToken shares, then shares to debt.
        return maxActualDebt.rayDivFloor(debtIndex).rayMulFloor(debtIndex);
    }

    /* MAX SUPPLY/BORROW CAPACITY */

    /// @dev Improved version of Aave-Vault's `_maxAssetsSuppliableToAave()`. The difference is it reflects fresh
    /// liquidityIndex and accrueToTreasury to calculate the precise max suppliable amount.
    /// @dev Ref:
    /// https://github.com/aave/Aave-Vault/blob/dc25b5a1b57a7b206757fdcb849ccd09ca765fd9/src/ATokenVault.sol#L571-L600
    /// @dev Returns the maximum supply capacity for a given token.
    function maxSupplyCapacity(address pool, address token) internal view returns (uint256) {
        return maxSupplyCapacity(0, pool, token);
    }

    /// @dev `elapsed` advances the liquidity index, so the headroom reflects the existing supply grown to a
    /// future (e.g. refinance) time rather than now. Pass 0 for the current block.
    function maxSupplyCapacity(uint256 elapsed, address pool, address token) internal view returns (uint256) {
        IPool aavePool = IPool(pool);
        DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(token);

        (bool isActive, bool isFrozen,, bool isPaused) = reserveData.configuration.getFlags();
        uint256 supplyCap = reserveData.configuration.getSupplyCap();

        if (!isActive || isFrozen || isPaused) {
            return 0;
        } else if (supplyCap == 0) {
            return type(uint256).max;
        } else {
            // Reproduce Aave's `getReserveNormalizedIncome` at the future (refinance) timestamp with a single
            // floored span, exactly as Aave will. Multiplying `getReserveNormalizedIncome(token)` by
            // `(1 + rate*elapsed)` instead splits the span into two floored steps, which can land 1 ulp low
            // and over-state the headroom by a wei.
            uint256 liquidityIndex = (WadRayMath.RAY
                    + reserveData.currentLiquidityRate
                        .mulDivDown(block.timestamp + elapsed - reserveData.lastUpdateTimestamp, SECONDS_PER_YEAR))
            .rayMul(reserveData.liquidityIndex);
            uint256 newAccruedToTreasury =
                _accrueToTreasury(aavePool, reserveData, token, liquidityIndex, reserveData.accruedToTreasury, elapsed);
            uint256 supplyCapWithDecimals = supplyCap * (10 ** reserveData.configuration.getDecimals());
            // max total scaled supply such that ensures:
            // `floor(totalScaledSupply * liquidityIndex / RAY) <= supplyCapWithDecimals`.
            uint256 totalScaledSupply = (supplyCapWithDecimals + 1).rayDivCeil(liquidityIndex) - 1;
            uint256 currentScaledSupply = IAToken(reserveData.aTokenAddress).scaledTotalSupply() + newAccruedToTreasury;

            if (totalScaledSupply <= currentScaledSupply) return 0;
            // max supply capacity such that ensures:
            // `floor(maxSupplyCapacity * RAY / liquidityIndex) <= totalScaledSupply - currentScaledSupply`.
            return (totalScaledSupply - currentScaledSupply + 1).rayMulCeil(liquidityIndex) - 1;
        }
    }

    /// @dev Returns the maximum borrow capacity for a given token.
    function maxBorrowCapacity(address pool, address token) internal view returns (uint256) {
        IPool aavePool = IPool(pool);
        DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(token);

        (bool isActive, bool isFrozen, bool borrowingEnabled, bool isPaused) = reserveData.configuration.getFlags();
        uint256 liquidity =
            MathLib.min(ERC20(token).balanceOf(reserveData.aTokenAddress), aavePool.getVirtualUnderlyingBalance(token));

        if (!isActive || isFrozen || !borrowingEnabled || isPaused) {
            return 0;
        }

        uint256 debtIndex = aavePool.getReserveNormalizedVariableDebt(token);
        // Mirror Aave's totalSupply >= rounded debt check
        uint256 maxBorrow = MathLib.min(
            liquidity, ERC20(reserveData.aTokenAddress).totalSupply().rayDivFloor(debtIndex).rayMulFloor(debtIndex)
        );

        uint256 borrowCap = reserveData.configuration.getBorrowCap();
        if (borrowCap != 0) {
            uint256 borrowCapWithDecimals = borrowCap * (10 ** reserveData.configuration.getDecimals());
            uint256 maxTotalScaledDebt = borrowCapWithDecimals.rayDivFloor(debtIndex);
            uint256 currentScaledDebt = IVariableDebtToken(reserveData.variableDebtTokenAddress).scaledTotalSupply();

            if (maxTotalScaledDebt <= currentScaledDebt) return 0;

            maxBorrow = MathLib.min(maxBorrow, (maxTotalScaledDebt - currentScaledDebt).rayMulFloor(debtIndex));
        }

        return maxBorrow;
    }

    function _accrueToTreasury(
        IPool pool,
        DataTypes.ReserveDataLegacy memory reserveData,
        address token,
        uint256 nextLiquidityIndex,
        uint256 currentlyAccrued,
        uint256 elapsed
    ) private view returns (uint256) {
        uint256 reserveFactor = reserveData.configuration.getReserveFactor();

        if (reserveFactor == 0) return currentlyAccrued;

        // Project the variable borrow index forward by `elapsed` so the treasury reflects the debt interest
        // accrued over the window, not just up to now. Rounded up so the resulting headroom stays conservative.
        uint256 nextVariableBorrowIndex = pool.getReserveNormalizedVariableDebt(token)
            .rayMulCeil(MathUtils.calculateCompoundedInterest(reserveData.currentVariableBorrowRate, 0, elapsed));
        uint256 currentScaledDebt = IVariableDebtToken(reserveData.variableDebtTokenAddress).scaledTotalSupply();
        uint256 totalDebtAccrued =
            currentScaledDebt.rayMulFloor(nextVariableBorrowIndex - reserveData.variableBorrowIndex);

        uint256 amountToMint = totalDebtAccrued.percentMul(reserveFactor);

        uint256 delta;
        if (amountToMint != 0) {
            delta = amountToMint.rayDivFloor(nextLiquidityIndex);
        }

        return currentlyAccrued + delta;
    }

    /* GROWTH FACTOR */

    /// @dev Returns the factor (WAD-scaled) by which `amount` of supplied collateral grows over `elapsed`
    /// seconds. Supplying lowers utilization, so the liquidity rate is re-derived at the post-supply
    /// utilization (via Aave's rate strategy) and applied with the linear interest formula.
    function collateralGrossFactor(address pool, address token, uint256 amount, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        IPool aavePool = IPool(pool);
        DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(token);
        uint256 debtIndex = aavePool.getReserveNormalizedVariableDebt(token);
        uint256 totalDebt =
            IVariableDebtToken(reserveData.variableDebtTokenAddress).scaledTotalSupply().getVTokenBalance(debtIndex);

        (uint256 liquidityRate,) = IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress)
            .calculateInterestRates(
                DataTypes.CalculateInterestRatesParams({
                unbacked: 0,
                liquidityAdded: amount,
                liquidityTaken: 0,
                totalDebt: totalDebt,
                reserveFactor: reserveData.configuration.getReserveFactor(),
                reserve: token,
                usingVirtualBalance: true,
                virtualUnderlyingBalance: aavePool.getVirtualUnderlyingBalance(token)
            })
            );
        uint256 factor = WadRayMath.RAY + (liquidityRate * elapsed) / SECONDS_PER_YEAR;

        return factor.rayToWad();
    }

    /// @dev Returns the factor (WAD-scaled) by which `amount` of variable debt grows over `elapsed` seconds.
    /// Borrowing lifts utilization, so the variable borrow rate is re-derived at the post-borrow utilization
    /// (via Aave's rate strategy) and applied with the compounded interest formula.
    function debtGrossFactor(address pool, address token, uint256 amount, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        IPool aavePool = IPool(pool);
        DataTypes.ReserveDataLegacy memory reserveData = aavePool.getReserveData(token);
        uint256 debtIndex = aavePool.getReserveNormalizedVariableDebt(token);
        // Mirror Aave: scale the borrow delta to vToken shares, add to scaled supply, then unscale to a balance.
        uint256 scaledTotalDebt = IVariableDebtToken(reserveData.variableDebtTokenAddress).scaledTotalSupply()
            + amount.getVTokenMintScaledAmount(debtIndex);
        uint256 totalDebt = scaledTotalDebt.getVTokenBalance(debtIndex);

        (, uint256 variableBorrowRate) = IReserveInterestRateStrategy(reserveData.interestRateStrategyAddress)
            .calculateInterestRates(
                DataTypes.CalculateInterestRatesParams({
                unbacked: 0,
                liquidityAdded: 0,
                liquidityTaken: amount,
                totalDebt: totalDebt,
                reserveFactor: reserveData.configuration.getReserveFactor(),
                reserve: token,
                usingVirtualBalance: true,
                virtualUnderlyingBalance: aavePool.getVirtualUnderlyingBalance(token)
            })
            );

        return MathUtils.calculateCompoundedInterest(variableBorrowRate, 0, elapsed).rayToWad();
    }
}
