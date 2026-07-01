// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

contract AccrueInterestForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;

    function testAccrueInterest(
        uint256 collateral,
        uint256 debt,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 duration,
        uint256 blocks,
        uint256 seed,
        uint256 venueId
    ) public {
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP) * BP; // WAD, multiple of BP, <= MAX_FIXED_RATE
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP) * BP;
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        blocks = bound(blocks, 1, (duration + MAX_OVERDUE_PERIOD) / BLOCK_TIME);
        seed = bound(seed, 0, type(uint256).max);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote =
            _buildQuote(collateralToken, debtToken, collateral, debt, fixedRate, overdueRate, duration, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        _forward(blocks);

        (uint256 expectedCollateralIndex, uint256 expectedDebtIndex) = adapter.indices(collateralToken, debtToken, data);
        uint256 elapsed = blocks * BLOCK_TIME;

        Loan memory loan = iris.getLoan(pod);
        uint256 expectedFixed = pos.debt.mulDivDown(elapsed * loan.fixedRate * BP, SECONDS_PER_YEAR * WAD);

        if (block.timestamp > loan.maturity) {
            uint256 overdueElapsed = block.timestamp - loan.maturity;
            expectedFixed += pos.debt.mulDivDown(overdueElapsed * loan.overdueRate * BP, SECONDS_PER_YEAR * WAD);
        }
        uint256 expectedFloating = pos.debt.mulDivDown(expectedDebtIndex - pos.debtIndex, pos.debtIndex);
        uint256 expectedSurplus =
            pos.collateral.mulDivDown(expectedCollateralIndex - pos.collateralIndex, pos.collateralIndex);

        (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            iris.accrueLegsView(pod);

        // Legs match the contract formula computed against the live venue indices.
        assertEq(collateralIndex, expectedCollateralIndex);
        assertEq(debtIndex, expectedDebtIndex);
        assertEq(fixedLeg, expectedFixed);
        assertEq(floatingLeg, expectedFloating);
        assertEq(surplus, expectedSurplus);
        // Venue indices only rise, so the floating delta never underflows.
        assertGe(collateralIndex, pos.collateralIndex);
        assertGe(debtIndex, pos.debtIndex);

        // Morpho collateral is inert: the index never moves, so no surplus ever accrues.
        if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            assertEq(surplus, 0);
        }
    }

    /* HELPERS */

    /// @dev Like the refinance build, but exposes `fixedRate` / `overdueRate` since interest accrual depends on
    /// them (a constant would defeat the test).
    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 duration,
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
        quote.fixedRate = fixedRate;
        quote.duration = duration;
        quote.overdueRate = overdueRate;
        // overduePeriod gates liquidation timing only; it never enters the accrual legs, so pin it to 0.
        quote.overduePeriod = 0;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3; // bit0 Aave | bit1 Morpho
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = data;
        quote.bond = blm.bondRequirement(quote);
    }
}
