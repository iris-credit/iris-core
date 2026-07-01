// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {StorageUtils} from "./helpers/StorageUtils.sol";
import {VenueAdapterMock} from "./helpers/mocks/VenueAdapterMock.sol";

contract VenueManagementUnitTest is UnitTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testRefinance(uint256 collateral, uint256 debt, uint8 newVenueId) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        newVenueId = uint8(bound(newVenueId, 1, 127));
        bytes memory newData = "0xHenlo";
        uint256 newVenueCollateralIndex = 1.3e27;
        uint256 newVenueDebtIndex = 1.5e27;

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.refinance(pod, newVenueId, newData);

        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));

        // Zero bond requirement
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.refinance(pod, newVenueId, newData);

        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);

        // Unauthorized
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(borrower);
        iris.refinance(pod, newVenueId, newData);

        // Adapter not set
        vm.expectRevert(IIris.AdapterNotSet.selector);
        vm.prank(solver);
        iris.refinance(pod, newVenueId, newData);

        // Not allowed venue
        VenueAdapterMock newAdapter = new VenueAdapterMock();
        newAdapter.setIndices(newVenueCollateralIndex, newVenueDebtIndex);
        vm.prank(owner);
        iris.setVenueAdapter(newVenueId, address(newAdapter));

        vm.expectRevert(IIris.NotAllowedVenue.selector);
        vm.prank(solver);
        iris.refinance(pod, newVenueId, newData);

        // Invalid data - refinance is only possible to whitelisted (enabled) markets
        StorageUtils.setLoanVenueBitmap(address(iris), pod, type(uint256).max);
        vm.expectRevert(IIris.InvalidData.selector);
        vm.prank(solver);
        iris.refinance(pod, newVenueId, newData);

        // Normal path
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, debt);

        vm.prank(owner);
        iris.enableData(keccak256(newData));

        deal(debtToken, solver, debt);
        vm.startPrank(solver);
        debtToken.safeApprove(address(iris), debt);

        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, solver, pod, debt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(IVenueAdapter.exit.selector, collateralToken, collateral, debtToken, debt, pod, "")
        );
        vm.expectCall(
            address(newAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.enter.selector, collateralToken, collateral, debtToken, debt, solver, newData
            )
        );
        vm.expectEmit();
        emit EventsLib.Refinance(solver, pod, newVenueId, address(newAdapter), newData);
        iris.refinance(pod, newVenueId, newData);
        vm.stopPrank();

        Position memory pos = iris.getPosition(pod);
        assertEq(iris.venueAdapter(pos.venueId), address(newAdapter));
        assertEq(pos.data, newData);
        assertEq(pos.collateralIndex, newVenueCollateralIndex);
        assertEq(pos.debtIndex, newVenueDebtIndex);
    }

    function testEscape(uint256 venueDebt, uint256 venueCollateral) public {
        venueDebt = bound(venueDebt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        venueCollateral = bound(venueCollateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        // Zero receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.escape(pod, address(0));

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.escape(pod, receiver);

        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);

        // Unauthorized
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(solver);
        iris.escape(pod, receiver);

        // Loan not resolved
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        vm.expectRevert(IIris.LoanNotResolved.selector);
        vm.prank(borrower);
        iris.escape(pod, receiver);
        StorageUtils.setPositionBondRequirement(address(iris), pod, 0);

        // Normal path
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionFixedLeg(address(iris), pod, 1);
        StorageUtils.setPositionFloatingLeg(address(iris), pod, 1);
        StorageUtils.setPositionSurplus(address(iris), pod, 1);
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(venueCollateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(venueDebt));
        StorageUtils.setPositionBond(address(iris), pod, 1);
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
        deal(debtToken, borrower, venueDebt);

        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), venueDebt);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, borrower, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.exit.selector, collateralToken, venueCollateral, debtToken, venueDebt, receiver, ""
            )
        );
        vm.expectEmit();
        emit EventsLib.Escape(borrower, pod, receiver, venueCollateral, venueDebt);
        iris.escape(pod, receiver);
        vm.stopPrank();

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
        // Escape must not touch the solver's bond or the loan marker.
        assertEq(pos.bond, 1);
        assertEq(pos.lastUpdate, block.timestamp);
    }

    /// @dev Stored indices match the venue's so accrual contributes nothing and the rebase logic is
    /// isolated. Price is fuzzed so the bad-debt collateral quoting (the price scaling) is exercised.
    function testRebase(
        uint256 blocks,
        uint256 collateral,
        uint256 debt,
        uint256 venueCollateral,
        uint256 venueDebt,
        uint256 price
    ) public {
        blocks = bound(blocks, 1, type(uint32).max - block.timestamp - 1);
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        venueCollateral = bound(venueCollateral, 0, collateral - 1);
        venueDebt = bound(venueDebt, 0, debt - 1);
        price = bound(price, MIN_TEST_COLLATERAL_PRICE, MAX_TEST_COLLATERAL_PRICE);

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.rebase(pod);

        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));

        // Zero bond requirement
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.rebase(pod);

        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);

        // Early return or Normal path
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPrice(price);

        _forward(blocks);

        // Already rebased - only the venue collateral fell below expected (one-sided change is ignored)
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, debt);
        iris.rebase(pod);
        assertEq(iris.getPosition(pod).collateral, collateral);

        // Already rebased - only the venue debt fell below expected (one-sided change is ignored)
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, venueDebt);
        iris.rebase(pod);
        assertEq(iris.getPosition(pod).debt, debt);

        // Normal path - both venue collateral and venue debt fell below expected
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
        uint256 liquidated = collateral - venueCollateral;
        uint256 repaid = debt - venueDebt;
        uint256 expectedCollateral = collateral.zeroFloorSub(liquidated);
        uint256 expectedDebt = debt.zeroFloorSub(MathLib.min(repaid, liquidated.mulDivDown(price, ORACLE_PRICE_SCALE)));
        uint256 badDebt = venueDebt.zeroFloorSub(venueCollateral.mulDivDown(price, ORACLE_PRICE_SCALE));
        vm.expectEmit();
        emit EventsLib.Rebase(borrower, pod, expectedCollateral, expectedDebt, badDebt);
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, expectedCollateral);
        assertEq(pos.debt, expectedDebt);
        assertEq(pos.lastUpdate, block.timestamp);
        // Bad debt (or a fully liquidated venue position) resolves the loan by zeroing bondRequirement.
        uint256 expectedBondRequirement = (badDebt != 0 || (venueDebt == 0 && venueCollateral == 0)) ? 0 : 1;
        assertEq(pos.bondRequirement, expectedBondRequirement);
    }

    /// @dev REBASE: "Surplus can be greater than the venue collateral ... the surplus shrinks to venue
    /// collateral." The same clamping applies to the floating leg, and bad debt zeroes bondRequirement.
    function testRebaseShrinksSurplusAndFloatingLegToVenueAmounts() public {
        uint256 surplus = 100e18;
        uint256 floatingLeg = 100e18;
        uint256 venueCollateral = 30e18;
        uint256 venueDebt = 40e18;

        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        // Collateral and debt already fully accrued into surplus and floatingLeg.
        StorageUtils.setPositionCollateral(address(iris), pod, 0);
        StorageUtils.setPositionDebt(address(iris), pod, 0);
        StorageUtils.setPositionSurplus(address(iris), pod, uint128(surplus));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);

        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, 0, 0, venueDebt.zeroFloorSub(venueCollateral));
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        // Surplus shrinks to the remaining venue collateral; collateral itself is zero.
        assertEq(pos.collateral, 0);
        assertEq(pos.surplus, venueCollateral);
        // Floating leg shrinks to the remaining venue debt; debt itself is zero.
        assertEq(pos.debt, 0);
        assertEq(pos.floatingLeg, venueDebt);
        // venueDebt (40e18) > venueCollateral (30e18) is bad debt, which resolves the loan.
        assertEq(pos.bondRequirement, 0);
    }

    /// @dev REBASE: a fully liquidated venue position (zero collateral and zero debt) marks the loan
    /// resolved by zeroing bondRequirement, which is what later lets the borrower escape.
    function testRebaseFullLiquidationZeroesBondRequirement() public {
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionDebt(address(iris), pod, 1e18);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPosition(0, 0);

        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, 0, 0, 0);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
        assertEq(pos.bondRequirement, 0);
    }
}
