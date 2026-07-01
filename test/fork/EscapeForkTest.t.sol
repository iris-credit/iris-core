// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {StorageUtils} from "../unit/helpers/StorageUtils.sol";

contract EscapeForkTest is ForkTest {
    using SafeTransferLib for address;

    function testEscape(uint256 collateral, uint256 debt, uint256 seed, uint256 venueId) public {
        seed = bound(seed, 0, type(uint256).max);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, venueId, data);
        address pod = _openLoan(quote);

        StorageUtils.setPositionBondRequirement(address(iris), pod, 0);

        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        uint256 receiverBalanceBefore = collateralToken.balanceOf(receiver);

        deal(debtToken, borrower, venueDebt);
        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), venueDebt);
        iris.escape(pod, receiver);
        vm.stopPrank();

        assertApproxEqAbs(collateralToken.balanceOf(receiver), receiverBalanceBefore + venueCollateral, 2);

        Position memory pos = iris.getPosition(pod);
        (venueCollateral, venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);

        assertEq(collateralToken.balanceOf(pod), 0);
        assertEq(debtToken.balanceOf(pod), 0);
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
    }

    /* HELPERS */

    /// @dev Minimal quote build; rates/duration are irrelevant once the loan is resolved before escape.
    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
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
        quote.duration = MIN_DURATION;
        quote.overdueRate = 0.1e18;
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
