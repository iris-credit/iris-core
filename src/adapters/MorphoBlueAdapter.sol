// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {IMorpho, Id, MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {MarketParamsLib} from "@morpho-blue/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-blue/libraries/periphery/MorphoLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {IVenueAdapter} from "../interfaces/IVenueAdapter.sol";

/// @dev Morpho's allowance is not reset as it is trusted.
contract MorphoBlueAdapter is IVenueAdapter {
    using SafeTransferLib for address;
    using MathLib for uint256;

    uint256 internal constant INDEX_SCALE = 1e33;

    IMorpho public immutable MORPHO;

    constructor(address morpho) {
        require(morpho != address(0), ZeroAddress());
        MORPHO = IMorpho(morpho);
    }

    /* DELEGATE FUNCTIONS */

    function supplyCollateral(address token, uint256 amount, bytes calldata data) external {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        require(marketParams.collateralToken == token, CollateralTokenMismatch());
        token.safeApproveWithRetry(address(MORPHO), amount);
        MORPHO.supplyCollateral(marketParams, amount, address(this), "");
    }

    function withdrawCollateral(address token, uint256 amount, address receiver, bytes calldata data) external {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        require(marketParams.collateralToken == token, CollateralTokenMismatch());
        MORPHO.withdrawCollateral(marketParams, amount, address(this), receiver);
    }

    /// @dev expects `expectedBorrowAssets` for `amount` input to avoid reverts in allowance of `transferFrom`
    /// due to conversion roundings between shares and assets.
    function repay(address token, uint256 amount, bytes calldata data) external {
        if (amount == 0) return;

        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        Id id = MarketParamsLib.id(marketParams);

        require(marketParams.loanToken == token, DebtTokenMismatch());

        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);
        uint256 debtShares = MorphoLib.borrowShares(MORPHO, id, address(this));
        uint256 debt = SharesMathLib.toAssetsUp(debtShares, totalBorrowAssets, totalBorrowShares);
        uint256 shares;

        token.safeApproveWithRetry(address(MORPHO), debt);

        if (amount == debt) {
            shares = debtShares;
            amount = 0;
        }

        MORPHO.repay(marketParams, amount, shares, address(this), "");
    }

    function enter(
        address collateralToken,
        uint256 collateral,
        address debtToken,
        uint256 debt,
        address receiver,
        bytes calldata data
    ) external {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));

        require(marketParams.collateralToken == collateralToken, CollateralTokenMismatch());
        require(marketParams.loanToken == debtToken, DebtTokenMismatch());

        collateralToken.safeApproveWithRetry(address(MORPHO), collateral);
        MORPHO.supplyCollateral(marketParams, collateral, address(this), "");
        MORPHO.borrow(marketParams, debt, 0, address(this), receiver);
    }

    /// @dev expects `expectedBorrowAssets` for `amount` input to avoid reverts in allowance of `transferFrom`
    /// due to conversion roundings between shares and assets.
    /// @dev It is advised to use the `shares` input when repaying the full position to avoid reverts
    /// due to conversion roundings between shares and assets.
    function exit(
        address collateralToken,
        uint256 collateral,
        address debtToken,
        uint256 debt,
        address receiver,
        bytes calldata data
    ) external {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        Id id = MarketParamsLib.id(marketParams);

        require(marketParams.loanToken == debtToken, DebtTokenMismatch());
        require(marketParams.collateralToken == collateralToken, CollateralTokenMismatch());

        uint256 borrowShares = MorphoLib.borrowShares(MORPHO, id, address(this));

        debtToken.safeApproveWithRetry(address(MORPHO), debt);
        if (debt != 0) MORPHO.repay(marketParams, 0, borrowShares, address(this), "");
        if (collateral != 0) MORPHO.withdrawCollateral(marketParams, collateral, address(this), receiver);
    }

    /* DELEGATE VIEW FUNCTIONS */

    function positionAssets(address pod, address, address, bytes calldata data)
        external
        view
        returns (uint256, uint256)
    {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        Id id = MarketParamsLib.id(marketParams);
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);

        uint256 collateral = MorphoLib.collateral(MORPHO, id, pod);
        uint256 debtShares = MorphoLib.borrowShares(MORPHO, id, pod);
        uint256 debt = SharesMathLib.toAssetsUp(debtShares, totalBorrowAssets, totalBorrowShares);

        return (collateral, debt);
    }

    /* VIEW FUNCTIONS */

    function price(address, address, bytes calldata data) external view returns (uint256) {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        return IOracle(marketParams.oracle).price();
    }

    function lltv(address, address, bytes calldata data) external pure returns (uint256) {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        return marketParams.lltv;
    }

    /// @dev Pinned collateral index to 1e27.
    /// @dev Morpho Blue collateral is idle, so the collateral index never grows.
    function indices(address, address, bytes calldata data) external view returns (uint256, uint256) {
        MarketParams memory marketParams = abi.decode(data, (MarketParams));
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(MORPHO, marketParams);

        uint256 debtIndex = (totalBorrowAssets + SharesMathLib.VIRTUAL_ASSETS)
        .mulDivDown(INDEX_SCALE, totalBorrowShares + SharesMathLib.VIRTUAL_SHARES);

        return (1e27, debtIndex);
    }
}
