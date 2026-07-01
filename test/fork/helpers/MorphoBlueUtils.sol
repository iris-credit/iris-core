// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMorpho, MarketParams, Id} from "@morpho-blue/interfaces/IMorpho.sol";
import {IOracle} from "@morpho-blue/interfaces/IOracle.sol";
import {SharesMathLib} from "@morpho-blue/libraries/SharesMathLib.sol";
import {MathLib, WAD} from "@morpho-blue/libraries/MathLib.sol";
import {UtilsLib} from "@morpho-blue/libraries/UtilsLib.sol";
import {ErrorsLib as MorphoBlueErrors} from "@morpho-blue/libraries/ErrorsLib.sol";
import {MorphoBalancesLib} from "@morpho-blue/libraries/periphery/MorphoBalancesLib.sol";
import {ORACLE_PRICE_SCALE} from "@morpho-blue/libraries/ConstantsLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {MorphoBlueIrmUtils} from "./MorphoBlueIrmUtils.sol";

library MorphoBlueUtils {
    using MathLib for uint256;
    using UtilsLib for uint256;
    using SharesMathLib for uint256;
    using SafeTransferLib for address;

    /* MIN/MAX AMOUNT */

    /// @dev Returns the minimum collateral amount required to borrow a given amount of debt.
    function minCollateralAmount(uint256 amount, address morpho, bytes memory marketParamsData)
        internal
        view
        returns (uint256)
    {
        return minCollateralAmount(0, amount, morpho, marketParamsData);
    }

    /// @dev Returns the minimum collateral amount required to borrow a given amount of debt.
    function minCollateralAmount(uint256, uint256 amount, address morpho, bytes memory marketParamsData)
        internal
        view
        returns (uint256)
    {
        MarketParams memory marketParams = abi.decode(marketParamsData, (MarketParams));
        uint256 collateralPrice = IOracle(marketParams.oracle).price();

        amount = expectedBorrowAssets(amount, morpho, marketParamsData);

        return amount.mulDivUp(WAD, marketParams.lltv).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice);
    }

    /// @dev Returns the maximum debt amount that can be borrowed with a given collateral amount.
    function maxDebtAmount(uint256 amount, address morpho, bytes memory marketParamsData)
        internal
        view
        returns (uint256)
    {
        return maxBorrowAmount(amount, morpho, marketParamsData);
    }

    /// @dev Returns the maximum borrow amount that can be borrowed with a given collateral amount.
    function maxBorrowAmount(uint256 amount, address morpho, bytes memory marketParamsData)
        internal
        view
        returns (uint256)
    {
        MarketParams memory marketParams = abi.decode(marketParamsData, (MarketParams));
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), marketParams);
        uint256 collateralPrice = IOracle(marketParams.oracle).price();
        uint256 maxBorrow = amount.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).mulDivDown(marketParams.lltv, WAD);
        // Account for Morpho's share/asset rounding: a borrow of `assets` is checked as
        // toAssetsUp(toSharesUp(assets)) >= assets, so round down to stay within maxBorrow.
        uint256 shares = maxBorrow.toSharesDown(totalBorrowAssets, totalBorrowShares);

        return shares.toAssetsDown(totalBorrowAssets, totalBorrowShares);
    }

    /* MAX SUPPLY/BORROW CAPACITY */

    /// @dev Returns the maximum supply capacity for a given market.
    /// @dev Since Morpho doesn't have a supply cap, this function always returns max uint256.
    function maxSupplyCapacity(address, bytes memory) internal pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev Morpho has no supply cap, so the projection window `elapsed` is irrelevant.
    function maxSupplyCapacity(uint256, address, bytes memory) internal pure returns (uint256) {
        return type(uint256).max;
    }

    /// @dev Returns the maximum borrow capacity for a given market (full supply utilization).
    function maxBorrowCapacity(address morpho, bytes memory marketParamsData) internal view returns (uint256) {
        return maxBorrowCapacity(morpho, marketParamsData, WAD);
    }

    /// @dev Returns the maximum borrow capacity before the market exceeds Morpho's target utilization.
    function maxBorrowCapacity(address morpho, bytes memory marketParamsData, uint256 targetUtilization)
        internal
        view
        returns (uint256)
    {
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), abi.decode(marketParamsData, (MarketParams)));
        uint256 targetBorrowAssets = totalSupplyAssets.mulDivDown(targetUtilization, WAD);
        uint256 available = targetBorrowAssets.zeroFloorSub(totalBorrowAssets);
        // Round down through shares so the borrow's toSharesUp/toAssetsUp round-trip stays within `available`.
        uint256 shares = available.toSharesDown(totalBorrowAssets, totalBorrowShares);

        return shares.toAssetsDown(totalBorrowAssets, totalBorrowShares);
    }

    /* GROWTH FACTOR */

    /// @dev Collateral on Morpho does not accrue, so its growth factor over any period is 1x (WAD).
    function collateralGrossFactor(address, bytes memory, uint256, uint256) internal pure returns (uint256) {
        return WAD;
    }

    /// @dev Returns the factor (WAD-scaled) by which `amount` of borrow debt grows over `elapsed` seconds.
    // The Adaptive Curve IRM projection is type-isolated in AdaptiveCurveProjectionLib: it resolves morpho-blue
    // to the IRM's own nested copy, whose `Id`/`MarketParams` are distinct types from this file's `@morpho-blue`
    // ones. Only the raw `marketParamsData` bytes cross that boundary, so neither file has to alias the dup types.
    function debtGrossFactor(address morpho, bytes memory marketParamsData, uint256 amount, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        return MorphoBlueIrmUtils.debtGrossFactor(morpho, marketParamsData, amount, elapsed);
    }

    /* HELPERS */

    /// @dev The assets a borrow of `amount` actually owes after Morpho's share/asset round-trip.
    function expectedBorrowAssets(uint256 amount, address morpho, bytes memory marketParamsData)
        internal
        view
        returns (uint256)
    {
        (,, uint256 totalBorrowAssets, uint256 totalBorrowShares) =
            MorphoBalancesLib.expectedMarketBalances(IMorpho(morpho), abi.decode(marketParamsData, (MarketParams)));
        return amount.toSharesUp(totalBorrowAssets, totalBorrowShares).toAssetsUp(totalBorrowAssets, totalBorrowShares);
    }

    function idToMarketParams(address morpho, Id id) internal view returns (MarketParams memory) {
        return IMorpho(morpho).idToMarketParams(id);
    }

    function randomMarketParams(address morpho, uint256 seed, Id[] memory marketIdList)
        internal
        view
        returns (MarketParams memory)
    {
        return IMorpho(morpho).idToMarketParams(marketIdList[seed % marketIdList.length]);
    }

    function supply(address morpho, MarketParams memory marketParams, uint256 amount, address onBehalf) internal {
        marketParams.loanToken.safeApproveWithRetry(morpho, amount);
        IMorpho(morpho).supply(marketParams, amount, 0, onBehalf, "");
    }
}
