// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/contracts/interfaces/IPriceOracleGetter.sol";
import {DataTypes} from "@aave/contracts/protocol/libraries/types/DataTypes.sol";
import {ReserveConfiguration} from "@aave/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";

import {WAD, ORACLE_PRICE_SCALE} from "../libraries/ConstantsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";

contract AaveV3Adapter is IVenueAdapter {
    using SafeTransferLib for address;
    using MathLib for uint256;

    uint256 internal constant VARIABLE_RATE = 2;

    IPool public immutable POOL;

    constructor(address pool) {
        require(pool != address(0), ZeroAddress());
        POOL = IPool(pool);
    }

    /* DELEGATE FUNCTIONS */

    function supplyCollateral(address token, uint256 amount, bytes calldata) external {
        token.safeApproveWithRetry(address(POOL), amount);
        POOL.supply(token, amount, address(this), 0);
    }

    function withdrawCollateral(address token, uint256 amount, address receiver, bytes calldata) external {
        POOL.withdraw(token, amount, receiver);
    }

    function repay(address token, uint256 amount, bytes calldata) external {
        if (amount == 0) return;
        token.safeApproveWithRetry(address(POOL), amount);
        POOL.repay(token, amount, VARIABLE_RATE, address(this));
    }

    /// @dev Aave sends the borrowed underlying to `msg.sender`.
    function enter(
        address collateralToken,
        uint256 collateral,
        address debtToken,
        uint256 debt,
        address receiver,
        bytes calldata
    ) external {
        collateralToken.safeApproveWithRetry(address(POOL), collateral);
        POOL.supply(collateralToken, collateral, address(this), 0);
        POOL.setUserUseReserveAsCollateral(collateralToken, true);
        POOL.borrow(debtToken, debt, VARIABLE_RATE, 0, address(this));
        debtToken.safeTransfer(receiver, debt);
    }

    function exit(
        address collateralToken,
        uint256 collateral,
        address debtToken,
        uint256 debt,
        address receiver,
        bytes calldata
    ) external {
        if (debt != 0) {
            debtToken.safeApproveWithRetry(address(POOL), debt);
            POOL.repay(debtToken, debt, VARIABLE_RATE, address(this));
        }
        if (collateral != 0) POOL.withdraw(collateralToken, collateral, receiver);
    }

    /* DELEGATE VIEW FUNCTIONS */

    function positionAssets(address pod, address collateralToken, address debtToken, bytes calldata)
        external
        view
        returns (uint256, uint256)
    {
        return (ERC20(_aToken(collateralToken)).balanceOf(pod), ERC20(_variableDebtToken(debtToken)).balanceOf(pod));
    }

    /* VIEW FUNCTIONS */

    function price(address collateralToken, address debtToken, bytes calldata) external view returns (uint256) {
        IPriceOracleGetter oracle = IPriceOracleGetter(POOL.ADDRESSES_PROVIDER().getPriceOracle());
        uint256 collateralPrice = oracle.getAssetPrice(collateralToken);
        uint256 debtPrice = oracle.getAssetPrice(debtToken);
        uint256 collateralUnit = 10 ** ERC20(collateralToken).decimals();
        uint256 debtUnit = 10 ** ERC20(debtToken).decimals();

        return (collateralPrice * debtUnit).mulDivDown(ORACLE_PRICE_SCALE, debtPrice * collateralUnit);
    }

    function lltv(address collateralToken, address, bytes calldata) external view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory configuration = POOL.getConfiguration(collateralToken);
        return ReserveConfiguration.getLiquidationThreshold(configuration).mulDivDown(WAD, 1e4);
    }

    function indices(address collateralToken, address debtToken, bytes calldata)
        external
        view
        returns (uint256, uint256)
    {
        return (POOL.getReserveNormalizedIncome(collateralToken), POOL.getReserveNormalizedVariableDebt(debtToken));
    }

    /* INTERNAL FUNCTIONS */

    function _aToken(address asset) internal view returns (address) {
        return POOL.getReserveData(asset).aTokenAddress;
    }

    function _variableDebtToken(address asset) internal view returns (address) {
        return POOL.getReserveData(asset).variableDebtTokenAddress;
    }
}
