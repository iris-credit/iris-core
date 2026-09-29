// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {StorageUtils} from "../unit/helpers/StorageUtils.sol";

contract LiquidateBondForkTest is ForkTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testLiquidateBond(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 drawdown,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        // Dynamic drawdown above the bond lltv edge, up into bad-bond territory (>100%).
        drawdown = bound(drawdown, bondLltv + 0.02e18, 3e18);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, duration, overduePeriod, venueId, data);
        address pod = _openLoan(quote);

        // Drive the bond `drawdown` underwater: set the floating leg directly (fixed leg stays 0) and pin Iris
        // collateral to the venue balance so _rebase early-returns.
        uint256 bond = quote.bond;
        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        uint256 negativeNet = bond.mulDivDown(drawdown, WAD);
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(venueCollateral));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(negativeNet));

        uint256 lif = MathLib.min(
            MAX_BOND_LIF, WAD.mulDivDown(WAD, WAD - LIQUIDATION_CURSOR.mulDivDown(WAD - bondLltv, WAD)) - WAD
        );
        uint256 seized = bond.mulDivDown(lif, WAD);
        uint256 bondSlashed = MathLib.min(negativeNet + seized, bond);
        uint256 repaid = MathLib.min(bondSlashed - seized, venueDebt);

        uint256 receiverBalanceBefore = debtToken.balanceOf(receiver);
        uint256 collateralBefore = iris.getPosition(pod).collateral;
        iris.liquidateBond(pod, receiver);

        assertEq(debtToken.balanceOf(receiver) - receiverBalanceBefore, seized);

        // Venue debt drops by repaid; the collateral stays supplied for the borrower to escape later.
        (, uint256 newVenueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertApproxEqAbs(newVenueDebt, venueDebt - repaid, 2);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.bond, bond - bondSlashed);
        assertEq(pos.bondRequirement, 0);
        // Collateral stays tracked for the borrower to withdraw or escape.
        assertApproxEqAbs(pos.collateral, collateralBefore, 2);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
    }

    // After bond liquidation the venue position persists; the borrower escapes to recover the collateral.
    function testLiquidateBondThenEscape(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 drawdown,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        drawdown = bound(drawdown, bondLltv + 0.02e18, 3e18);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, duration, overduePeriod, venueId, data);
        address pod = _openLoan(quote);

        // Drive the bond into bad bond and liquidate; the venue position persists for the borrower to escape.
        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(venueCollateral));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(quote.bond.mulDivDown(drawdown, WAD)));
        iris.liquidateBond(pod, receiver);

        (venueCollateral, venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        uint256 receiverBalanceBefore = collateralToken.balanceOf(receiver);

        deal(debtToken, borrower, venueDebt);
        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), venueDebt);
        iris.escape(pod, receiver);
        vm.stopPrank();

        assertApproxEqAbs(collateralToken.balanceOf(receiver), receiverBalanceBefore + venueCollateral, 2);

        Position memory pos = iris.getPosition(pod);
        (venueCollateral, venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
    }

    /* HELPERS */

    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 venueId_,
        bytes memory data
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken;
        quote.debtToken = debtToken;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = duration;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = overduePeriod;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3; // bit0 Aave | bit1 Morpho
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = data;
        quote.bond = blm.bondRequirement(quote);
    }
}
