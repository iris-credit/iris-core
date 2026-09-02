// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {StorageUtils} from "./helpers/StorageUtils.sol";

contract CollateralUnitTest is UnitTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testSupplyCollateral(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        // Zero amount
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.supplyCollateral(pod, 0);

        // Not entered
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.supplyCollateral(pod, amount);

        // Normal path
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        deal(collateralToken, borrower, amount);

        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), amount);
        vm.expectCall(collateralToken, abi.encodeWithSelector(ERC20.transferFrom.selector, borrower, pod, amount));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(IVenueAdapter.supplyCollateral.selector, collateralToken, amount, "")
        );
        vm.expectEmit();
        emit EventsLib.SupplyCollateral(borrower, pod, amount);
        iris.supplyCollateral(pod, amount);
        vm.stopPrank();

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, amount);
    }

    function testWithdrawCollateralReservesBadBond() public {
        uint256 collateral = 150e18;
        uint256 debt = 100e18;
        uint256 bond = 10e18;
        uint256 floatingLeg = 18e18; // badBond = floatingLeg - fixedLeg - bond = 8e18

        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(block.timestamp + 30 days));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, debt);
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);

        // Without the bad bond reserve, debt / lltv = 125e18 would allow withdrawing 25e18.
        assertLe(debt, _maxDebt(collateral - 20e18, ""));
        vm.expectRevert(IIris.InsufficientCollateral.selector);
        vm.prank(borrower);
        iris.withdrawCollateral(pod, 20e18, receiver);

        // (debt + badBond) / lltv = 135e18 leaves 15e18 withdrawable.
        vm.prank(borrower);
        iris.withdrawCollateral(pod, 15e18, receiver);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, collateral - 15e18);
        assertEq(pos.bond, bond);
        assertEq(pos.floatingLeg, floatingLeg);
    }

    function testWithdrawCollateral(
        uint256 collateral,
        uint256 debt,
        uint256 amount,
        uint256 duration,
        uint256 overduePeriod,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 debtIndex,
        uint256 blocks
    ) public {
        (collateral, debt) = _boundHealthyPosition(collateral, debt, "");
        amount = bound(amount, MIN_TEST_AMOUNT, collateral);
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP);
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP);
        debtIndex = bound(debtIndex, 1e27, 1e28);
        blocks = bound(blocks, 0, MAX_DURATION + MAX_OVERDUE_PERIOD);

        // Zero amount
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.withdrawCollateral(pod, 0, receiver);

        // Zero address - No receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.withdrawCollateral(pod, amount, address(0));

        // Zero address - Not entered
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.withdrawCollateral(pod, amount, receiver);

        uint256 maturity = block.timestamp + duration;

        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanOverduePeriod(address(iris), pod, uint32(overduePeriod));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(fixedRate));
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(overdueRate));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(debtIndex));
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, debt);
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, debtIndex);

        // No receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.withdrawCollateral(pod, amount, address(0));

        // Unauthorized
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(solver);
        iris.withdrawCollateral(pod, amount, receiver);

        _forward(blocks);

        (,, uint256 fixedLeg,,) = iris.accrueLegsView(pod);
        uint256 timeToLiquidation = (maturity + overduePeriod).zeroFloorSub(block.timestamp);
        uint256 residual = debt.mulDivDown(
            timeToLiquidation * fixedRate * BP + MathLib.min(timeToLiquidation, overduePeriod) * overdueRate * BP,
            SECONDS_PER_YEAR * WAD
        );

        if (debt + fixedLeg + residual > _maxDebt(collateral - amount, "")) {
            // Insufficient collateral - remaining collateral does not cover debt + fixed interest owed
            vm.expectRevert(IIris.InsufficientCollateral.selector);
            vm.prank(borrower);
            iris.withdrawCollateral(pod, amount, receiver);
        } else {
            // Normal path
            vm.prank(borrower);
            vm.expectCall(
                address(venueAdapter),
                abi.encodeWithSelector(IVenueAdapter.withdrawCollateral.selector, collateralToken, amount, receiver, "")
            );
            vm.expectEmit();
            emit EventsLib.WithdrawCollateral(borrower, pod, receiver, amount);
            iris.withdrawCollateral(pod, amount, receiver);

            Position memory pos = iris.getPosition(pod);

            assertEq(pos.collateral, collateral - amount);
            assertEq(pos.debt, debt);
            assertEq(pos.fixedLeg, fixedLeg);
            assertEq(pos.lastUpdate, block.timestamp);
        }
    }
}
