// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";

contract RebaseForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    // An untouched venue position keeps rebase a no-op
    function testRebaseNoOp(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 blocks,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        blocks = bound(blocks, 1, (duration + MAX_OVERDUE_PERIOD) / BLOCK_TIME);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data,) = _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, duration, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        _forward(blocks);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, pos.collateral);
        assertEq(newPos.debt, pos.debt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    // External collateral supply is synced into the borrower's collateral.
    // (venue collateral > position collateral + surplus)
    function testRebaseExternalSupplyCollateral(
        uint256 collateral,
        uint256 debt,
        uint256 supplied,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data,) = _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        uint256 maxSupply = _maxSuppliable(collateralToken, venueId, data);
        vm.assume(maxSupply >= MIN_TEST_AMOUNT);
        supplied = bound(supplied, MIN_TEST_AMOUNT, maxSupply);

        _externalSupplyCollateral(venueId, collateralToken, data, pod, supplied);

        iris.rebase(pod);

        // The direct supply is tracked as the borrower's collateral.
        (uint256 venueCollateral,) =
            IVenueAdapter(iris.venueAdapter(venueId)).positionAssets(pod, collateralToken, debtToken, data);
        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, venueCollateral - newPos.surplus);
        assertGe(newPos.collateral, pos.collateral);
        assertEq(newPos.debt, pos.debt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    // External debt repay is one-sided. rebase no-ops.
    // (venue collateral >= position collateral + surplus, venue debt < position debt + floating leg)
    function testRebaseExternalRepay(uint256 collateral, uint256 debt, uint256 repaid, uint256 seed, uint256 venueId)
        public
    {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        (uint256 venueCollateral, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        vm.assume(venueCollateral >= pos.collateral);
        vm.assume(venueDebt > MIN_TEST_AMOUNT);

        repaid = bound(repaid, MIN_TEST_AMOUNT, venueDebt - 1);
        _externalRepay(venueId, debtToken, data, pod, repaid);

        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, pos.collateral);
        assertEq(newPos.debt, pos.debt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    // External Aave repay can combine with aToken collateral rounding down.
    // Rebase caps debt reduction by the value of the rounded collateral dust instead of the full external repay.
    function testRebaseExternalRepayAaveCollateralRoundingDown(
        uint256 collateral,
        uint256 debt,
        uint256 externalRepaid,
        uint256 seed
    ) public {
        uint256 venueId = uint256(VenueId.AAVE_V3);

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        (, uint256 venueDebt) = adapter.positionAssets(pod, collateralToken, debtToken, data);
        vm.assume(venueDebt > MIN_TEST_AMOUNT);

        externalRepaid = bound(externalRepaid, MIN_TEST_AMOUNT, venueDebt - 1);
        _externalRepay(venueId, debtToken, data, pod, externalRepaid);

        (uint256 newVenueCollateral, uint256 newVenueDebt) =
            adapter.positionAssets(pod, collateralToken, debtToken, data);
        uint256 price = adapter.price(collateralToken, debtToken, data);
        uint256 liquidated = uint256(pos.collateral).zeroFloorSub(newVenueCollateral);
        uint256 repaid = uint256(pos.debt).zeroFloorSub(newVenueDebt);
        uint256 maxRepaid = liquidated.mulDivDown(price, ORACLE_PRICE_SCALE);
        uint256 expectedDebt = uint256(pos.debt).zeroFloorSub(maxRepaid);

        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, newVenueCollateral, expectedDebt, newVenueCollateral, newVenueDebt, 0);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, newVenueCollateral);
        assertEq(newPos.debt, expectedDebt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
        assertEq(uint256(pos.debt) - newPos.debt, maxRepaid);
        assertLt(maxRepaid, repaid);
        assertLt(maxRepaid, externalRepaid);
    }

    // Partial liquidation with no bad debt rebases collateral to live, caps the debt reduction by
    // the liquidated collateral value, and keeps bondRequirement.
    function testRebaseVenuePartialLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 remainingDebt,
        uint256 remainingCollateral,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        uint256 price = adapter.price(collateralToken, debtToken, data);
        remainingDebt = bound(remainingDebt, 1, pos.debt - 1);
        uint256 minRemainingCollateral = remainingDebt.mulDivUp(ORACLE_PRICE_SCALE, price);
        uint256 minLiquidatedCollateral = (pos.debt - remainingDebt).mulDivUp(ORACLE_PRICE_SCALE, price);
        vm.assume(minLiquidatedCollateral < pos.collateral);
        uint256 maxRemainingCollateral = pos.collateral - minLiquidatedCollateral;
        vm.assume(minRemainingCollateral <= maxRemainingCollateral);
        remainingCollateral = bound(remainingCollateral, minRemainingCollateral, maxRemainingCollateral);

        _mockPositionAssets(adapter, pod, collateralToken, debtToken, data, remainingCollateral, remainingDebt);

        uint256 liquidated = pos.collateral - remainingCollateral;
        uint256 repaid = pos.debt - remainingDebt;
        uint256 expectedDebt =
            uint256(pos.debt).zeroFloorSub(MathLib.min(repaid, liquidated.mulDivDown(price, ORACLE_PRICE_SCALE)));

        vm.expectEmit();
        emit EventsLib.Rebase(borrower, pod, remainingCollateral, expectedDebt, remainingCollateral, remainingDebt, 0);
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, remainingCollateral);
        assertEq(newPos.debt, expectedDebt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    // Liquidation to zero venue debt but collateral remains. bondRequirement is kept.
    function testRebaseVenueFullLiquidation(
        uint256 collateral,
        uint256 debt,
        uint256 remainingCollateral,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        uint256 price = adapter.price(collateralToken, debtToken, data);
        uint256 minLiquidatedCollateral = pos.debt.mulDivUp(ORACLE_PRICE_SCALE, price);
        remainingCollateral = bound(remainingCollateral, 1, pos.collateral - minLiquidatedCollateral);
        _mockPositionAssets(adapter, pod, collateralToken, debtToken, data, remainingCollateral, 0);

        uint256 liquidated = pos.collateral - remainingCollateral;
        uint256 expectedDebt = uint256(pos.debt)
            .zeroFloorSub(MathLib.min(uint256(pos.debt), liquidated.mulDivDown(price, ORACLE_PRICE_SCALE)));

        vm.expectEmit();
        emit EventsLib.Rebase(borrower, pod, remainingCollateral, expectedDebt, remainingCollateral, 0, 0);
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, remainingCollateral);
        assertEq(newPos.debt, expectedDebt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    // Liquidation to zero venue position (zero collateral, debt) resolves the loan.
    function testRebaseVenueFullLiquidationToZeroCollateral(
        uint256 collateral,
        uint256 debt,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);
        assertGt(pos.bondRequirement, 0);

        _mockPositionAssets(adapter, pod, collateralToken, debtToken, data, 0, 0);

        vm.expectEmit();
        emit EventsLib.Rebase(borrower, pod, 0, 0, 0, 0, 0);
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, 0);
        assertEq(newPos.debt, 0);
        assertEq(newPos.bondRequirement, 0);
    }

    // Bad debt situation. rebases debt and collateral and resolves the loan.
    function testRebaseVenueBadDebt(
        uint256 collateral,
        uint256 debt,
        uint256 remainingDebt,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);
        assertGt(pos.bondRequirement, 0);

        uint256 price = adapter.price(collateralToken, debtToken, data);
        remainingDebt = bound(remainingDebt, 2, pos.debt - 1);
        uint256 remainingCollateral = (remainingDebt - 1).mulDivDown(ORACLE_PRICE_SCALE, price);
        vm.assume(remainingCollateral < pos.collateral);
        uint256 badDebt = remainingDebt.zeroFloorSub(remainingCollateral.mulDivDown(price, ORACLE_PRICE_SCALE));

        _mockPositionAssets(adapter, pod, collateralToken, debtToken, data, remainingCollateral, remainingDebt);

        uint256 liquidated = pos.collateral - remainingCollateral;
        uint256 repaid = pos.debt - remainingDebt;
        uint256 expectedDebt =
            uint256(pos.debt).zeroFloorSub(MathLib.min(repaid, liquidated.mulDivDown(price, ORACLE_PRICE_SCALE)));

        vm.expectEmit();
        emit EventsLib.Rebase(
            borrower, pod, remainingCollateral, expectedDebt, remainingCollateral, remainingDebt, badDebt
        );
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, remainingCollateral);
        assertEq(newPos.debt, expectedDebt);
        assertEq(newPos.bondRequirement, 0);
    }

    // External supply collateral with venue debt reduction (external repay or liquidated). rebase syncs the
    // supply and leaves the one-sided debt reduction unreconciled.
    function testRebaseExternalSupplyCollateralWithDebtReduction(
        uint256 collateral,
        uint256 debt,
        uint256 supplied,
        uint256 debtReduction,
        uint256 seed,
        uint256 venueId
    ) public {
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter) =
            _randomMarket(seed, venueId);

        vm.prank(owner);
        blm.setParams(debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);

        Quote memory quote = _buildQuote(collateralToken, debtToken, collateral, debt, MIN_DURATION, venueId, data);
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        supplied = bound(supplied, 1, MAX_TEST_AMOUNT);
        debtReduction = bound(debtReduction, 1, pos.debt);
        _mockPositionAssets(
            adapter, pod, collateralToken, debtToken, data, pos.collateral + supplied, pos.debt - debtReduction
        );

        iris.rebase(pod);

        // The direct supply is tracked as collateral; the one-sided debt reduction stays unreconciled.
        Position memory newPos = iris.getPosition(pod);
        assertEq(newPos.collateral, pos.collateral + supplied);
        assertEq(newPos.debt, pos.debt);
        assertEq(newPos.bondRequirement, pos.bondRequirement);
    }

    /* HELPERS */

    function _externalSupplyCollateral(
        uint256 venueId,
        address collateralToken,
        bytes memory data,
        address pod,
        uint256 amount
    ) internal {
        deal(collateralToken, address(this), amount);

        if (venueId == uint256(VenueId.AAVE_V3)) {
            collateralToken.safeApprove(aaveV3Pool, amount);
            IPool(aaveV3Pool).supply(collateralToken, amount, pod, 0);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            MarketParams memory marketParams = abi.decode(data, (MarketParams));
            collateralToken.safeApprove(morphoBlue, amount);
            IMorpho(morphoBlue).supplyCollateral(marketParams, amount, pod, "");
        } else {
            revert("RebaseForkTest: Invalid venue ID");
        }
    }

    function _externalRepay(uint256 venueId, address debtToken, bytes memory data, address pod, uint256 amount)
        internal
    {
        deal(debtToken, address(this), amount);

        if (venueId == uint256(VenueId.AAVE_V3)) {
            debtToken.safeApprove(aaveV3Pool, amount);
            IPool(aaveV3Pool).repay(debtToken, amount, 2, pod);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            MarketParams memory marketParams = abi.decode(data, (MarketParams));
            debtToken.safeApprove(morphoBlue, amount);
            IMorpho(morphoBlue).repay(marketParams, amount, 0, pod, "");
        } else {
            revert("RebaseForkTest: Invalid venue ID");
        }
    }

    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
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
        quote.fixedRate = 0.05e18;
        quote.duration = duration;
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
