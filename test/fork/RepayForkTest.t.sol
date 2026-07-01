// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

contract RepayForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testRepay(
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
        blocks = bound(blocks, 0, duration + overduePeriod); // span pre- and post-maturity
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
        // overdue close leaves (repay is funded to the exact tracked debt). Without it that close reverts.
        deal(debtToken, address(iris), debtToken.balanceOf(address(iris)) + MIN_TEST_AMOUNT);

        // Exact repay charge = accrued legs + the pre-maturity residual that _settleLegs adds + any bad bond.
        Position memory pos = iris.getPosition(pod);
        Loan memory loan = iris.getLoan(pod);
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        if (block.timestamp < loan.maturity) {
            fixedLeg += pos.debt
            .mulDivDown((loan.maturity - block.timestamp) * loan.fixedRate * BP, SECONDS_PER_YEAR * WAD);
        }
        uint256 repaid = pos.debt + fixedLeg + floatingLeg.zeroFloorSub(fixedLeg).zeroFloorSub(pos.bond);

        deal(debtToken, borrower, repaid);
        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), repaid);
        iris.repay(pod);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(borrower), 0);

        // Venue debt cleared; only the surplus is pulled, principal collateral stays supplied (full exit is escape's).
        (uint256 newVenueCollateral, uint256 newVenueDebt) =
            adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(newVenueDebt, 0);
        assertApproxEqAbs(newVenueCollateral, collateral, 2);

        pos = iris.getPosition(pod);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.collateral, collateral);
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
