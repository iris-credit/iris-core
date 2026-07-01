// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

// Everything here resolves to morpho-blue-irm's own nested copy of morpho-blue (`@morpho-blue-irm-mb`) — the
// same physical files `AdaptiveCurveIrmLib` imports via its relative path, so the types unify with the IRM's
// signatures. Keeping this projection in its own file lets it use that type-world with plain names: callers in
// the `@morpho-blue` world reach it through MorphoBlueUtils, passing only raw `bytes`/`uint256`, so the two
// (byte-identical but nominally distinct) morpho-blue type sets never meet in a single file.
import {Id, IMorpho, MarketParams} from "@morpho-blue-irm-mb/interfaces/IMorpho.sol";
import {MarketParamsLib} from "@morpho-blue-irm-mb/libraries/MarketParamsLib.sol";
import {MathLib as MorphoMathLib, WAD} from "@morpho-blue-irm-mb/libraries/MathLib.sol";

import {AdaptiveCurveIrmLib} from "@morpho-blue-irm/adaptive-curve-irm/libraries/periphery/AdaptiveCurveIrmLib.sol";
import {ConstantsLib} from "@morpho-blue-irm/adaptive-curve-irm/libraries/ConstantsLib.sol";
import {MathLib, WAD_INT} from "@morpho-blue-irm/adaptive-curve-irm/libraries/MathLib.sol";

library MorphoBlueIrmUtils {
    using MathLib for int256;
    using MorphoMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /// @dev Returns the factor (WAD-scaled) by which `amount` of borrow debt grows over `elapsed` seconds.
    /// Reproduces Morpho's two-step accrual exactly, with no state mutation. The plain IRM only exposes the
    /// average rate seeded from its *stored* `rateAtTarget` (stale by the gap since the last touch), so the
    /// projection would under-shoot. Instead:
    ///   Hop 1 — the open's accrual advances `rateAtTarget`; the periphery lib's `_borrowRate` is the only
    ///           view that returns that post-accrual `endRateAtTarget` (the bare IRM hides it behind its
    ///           state-writing `borrowRate`).
    ///   Hop 2 — the [open, refinance] window accrues from that seed at the post-borrow utilization, using
    ///           the lib's own `_curve`/`_newRateAtTarget` (so no exp/curve/constants are re-implemented).
    function debtGrossFactor(address morpho, bytes memory marketParamsData, uint256 amount, uint256 elapsed)
        internal
        view
        returns (uint256)
    {
        MarketParams memory marketParams = abi.decode(marketParamsData, (MarketParams));
        Id id = marketParams.id();

        // Hop 1: the `rateAtTarget` the open advances to (seeded from the IRM's live stored value).
        (, int256 startRateAtTarget) = AdaptiveCurveIrmLib._borrowRate(id, IMorpho(morpho).market(id), marketParams.irm);

        // Hop 2: average borrow rate over `elapsed`, seeded from `startRateAtTarget` at the post-borrow
        // utilization (the position's `amount` added to the balances accrued to now).
        (uint256 totalSupplyAssets,, uint256 totalBorrowAssets,) =
            AdaptiveCurveIrmLib.expectedMarketBalances(morpho, Id.unwrap(id), marketParams.irm);
        totalBorrowAssets += amount;

        int256 utilization = int256(totalSupplyAssets > 0 ? totalBorrowAssets.wDivDown(totalSupplyAssets) : 0);
        int256 errNormFactor = utilization > ConstantsLib.TARGET_UTILIZATION
            ? WAD_INT - ConstantsLib.TARGET_UTILIZATION
            : ConstantsLib.TARGET_UTILIZATION;
        int256 err = (utilization - ConstantsLib.TARGET_UTILIZATION).wDivToZero(errNormFactor);

        int256 avgRateAtTarget;
        int256 speed = ConstantsLib.ADJUSTMENT_SPEED.wMulToZero(err);
        int256 linearAdaptation = speed * int256(elapsed);

        if (linearAdaptation == 0) {
            avgRateAtTarget = startRateAtTarget;
        } else {
            int256 endRateAtTarget = AdaptiveCurveIrmLib._newRateAtTarget(startRateAtTarget, linearAdaptation);
            int256 midRateAtTarget = AdaptiveCurveIrmLib._newRateAtTarget(startRateAtTarget, linearAdaptation / 2);
            avgRateAtTarget = (startRateAtTarget + endRateAtTarget + 2 * midRateAtTarget) / 4;
        }

        uint256 borrowRate = uint256(AdaptiveCurveIrmLib._curve(avgRateAtTarget, err));

        return WAD + MorphoMathLib.wTaylorCompounded(borrowRate, elapsed);
    }
}
