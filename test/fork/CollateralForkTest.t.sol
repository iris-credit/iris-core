// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

contract CollateralForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testSupplyCollateral(uint256 collateral, uint256 debt, uint256 amount, uint256 seed, uint256 venueId)
        public
    {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, 0, venueId, data);
        address pod = _openLoan(quote);

        // Re-read headroom after the open: the open's own collateral supply can consume the venue's supply cap,
        // leaving less than MIN_TEST_AMOUNT (or none) for the top-up. Skip those draws.
        uint256 maxSupply = _maxSuppliable(collateralToken, venueId, data);
        vm.assume(maxSupply >= MIN_TEST_AMOUNT);
        amount = bound(amount, MIN_TEST_AMOUNT, maxSupply);

        Position memory pos = iris.getPosition(pod);
        (uint256 venueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);

        deal(collateralToken, borrower, amount);
        uint256 borrowerBalanceBefore = collateralToken.balanceOf(borrower);
        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), amount);
        iris.supplyCollateral(pod, amount);
        vm.stopPrank();

        (uint256 newVenueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);

        assertApproxEqAbs(newVenueCollateral, venueCollateral + amount, 2);
        assertEq(iris.getPosition(pod).collateral, pos.collateral + amount);
        assertEq(collateralToken.balanceOf(borrower), borrowerBalanceBefore - amount);
    }

    function testWithdrawCollateral(
        uint256 collateral,
        uint256 debt,
        uint256 amount,
        uint256 duration,
        uint256 overduePeriod,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, duration, overduePeriod, venueId, data);
        address pod = _openLoan(quote);

        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        uint256 lltv = adapter.lltv(collateralToken, debtToken, data);
        uint256 price = adapter.price(collateralToken, debtToken, data);
        uint256 timeToLiquidation = uint256(loan.maturity + loan.overduePeriod).zeroFloorSub(block.timestamp);
        uint256 residual = pos.debt
            .mulDivDown(
                timeToLiquidation * loan.fixedRate * BP + MathLib.min(timeToLiquidation, loan.overduePeriod)
                    * loan.overdueRate * BP,
                SECONDS_PER_YEAR * WAD
            );
        uint256 minCollateral =
            (pos.debt + pos.fixedLeg + residual).mulDivUp(WAD, lltv).mulDivUp(ORACLE_PRICE_SCALE, price);

        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        uint256 venueMinCollateral = _minCollateralAmount(venueDebt, collateralToken, debtToken, venueId, data);

        vm.assume(pos.collateral > minCollateral + MIN_TEST_AMOUNT);
        vm.assume(venueCollateral > venueMinCollateral + MIN_TEST_AMOUNT);
        amount = bound(
            amount, MIN_TEST_AMOUNT, MathLib.min(pos.collateral - minCollateral, venueCollateral - venueMinCollateral)
        );

        uint256 receiverBalanceBefore = collateralToken.balanceOf(receiver);

        vm.prank(borrower);
        iris.withdrawCollateral(pod, amount, receiver);

        (uint256 newVenueCollateral,) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        assertEq(collateralToken.balanceOf(receiver), receiverBalanceBefore + amount);
        assertApproxEqAbs(newVenueCollateral, venueCollateral - amount, 2);
        assertEq(iris.getPosition(pod).collateral, pos.collateral - amount);
    }

    /* HELPERS */

    /// @dev Minimal quote build; duration/overduePeriod feed the residual term of the withdraw health gate.
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
