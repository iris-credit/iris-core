// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

contract LiquidateForkTest is ForkTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    address immutable liquidator = makeAddr("liquidator");

    function testLiquidate(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 blocks,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        blocks = bound(blocks, duration + overduePeriod + 1, duration + overduePeriod + 2 * TIME_TO_MAX_LIF);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, duration, overduePeriod, venueId, data);
        address pod = _openLoan(quote);

        _forward(blocks);

        // Stand in for the pooled balance a live Iris always holds: it absorbs the <=2 wei round-up gap a bad-bond
        // overdue close leaves (liquidation is funded to the exact tracked debt). Without it that close reverts.
        deal(debtToken, address(iris), debtToken.balanceOf(address(iris)) + MIN_TEST_AMOUNT);

        // Exact liquidation charge = accrued legs + any bad bond (the loan is overdue, so no pre-maturity residual).
        Position memory pos = iris.getPosition(pod);
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        uint256 repaid = pos.debt + fixedLeg + floatingLeg.zeroFloorSub(fixedLeg).zeroFloorSub(pos.bond);

        deal(debtToken, liquidator, repaid);
        uint256 receiverBalanceBefore = collateralToken.balanceOf(receiver);
        vm.startPrank(liquidator);
        debtToken.safeApprove(address(iris), repaid);
        (, uint256 seized) = iris.liquidate(pod, receiver);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(liquidator), 0);
        assertEq(collateralToken.balanceOf(receiver) - receiverBalanceBefore, seized);

        // Venue debt cleared; seized + surplus are pulled, the un-seized principal stays supplied (debt zeroed).
        (uint256 newVenueCollateral, uint256 newVenueDebt) =
            adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(newVenueDebt, 0);
        assertApproxEqAbs(newVenueCollateral, collateral - seized, 2);

        pos = iris.getPosition(pod);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.collateral, collateral - seized);
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
