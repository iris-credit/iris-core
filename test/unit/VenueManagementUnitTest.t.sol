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

        // Zero receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.refinance(pod, address(0), newVenueId, newData);

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.refinance(pod, receiver, newVenueId, newData);

        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));

        // Zero bond requirement
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.refinance(pod, receiver, newVenueId, newData);

        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);

        // Liquidatable loan
        vm.expectRevert(IIris.LiquidatableLoan.selector);
        iris.refinance(pod, receiver, newVenueId, newData);

        StorageUtils.setLoanMaturity(address(iris), pod, uint32(block.timestamp + 1 days));

        // Unauthorized
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(borrower);
        iris.refinance(pod, receiver, newVenueId, newData);

        // Adapter not set
        vm.expectRevert(IIris.AdapterNotSet.selector);
        vm.prank(solver);
        iris.refinance(pod, receiver, newVenueId, newData);

        // Not allowed venue
        VenueAdapterMock newAdapter = new VenueAdapterMock();
        newAdapter.setIndices(newVenueCollateralIndex, newVenueDebtIndex);
        vm.prank(owner);
        iris.setVenueAdapter(newVenueId, address(newAdapter));

        vm.expectRevert(IIris.NotAllowedVenue.selector);
        vm.prank(solver);
        iris.refinance(pod, receiver, newVenueId, newData);

        // Invalid data - refinance is only possible to whitelisted (enabled) markets
        StorageUtils.setLoanVenueBitmap(address(iris), pod, type(uint256).max);
        vm.expectRevert(IIris.InvalidData.selector);
        vm.prank(solver);
        iris.refinance(pod, receiver, newVenueId, newData);

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
                IVenueAdapter.enter.selector, collateralToken, collateral, debtToken, debt, receiver, newData
            )
        );
        vm.expectEmit();
        emit EventsLib.Refinance(
            solver, pod, receiver, newVenueId, address(newAdapter), newVenueCollateralIndex, newVenueDebtIndex, newData
        );
        iris.refinance(pod, receiver, newVenueId, newData);
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
    /// Legs and bond are fuzzed so the venue debt can fall below the accrued floating leg. the repayment recognized
    /// above the principal nets the fixed leg and the excess is slashed from the bond into the borrower's claimable.
    function testRebase(
        uint256 blocks,
        uint256 collateral,
        uint256 debt,
        uint256 fixedLeg,
        uint256 floatingLeg,
        uint256 bond,
        uint256 venueCollateral,
        uint256 venueDebt,
        uint256 price
    ) public {
        blocks = bound(blocks, 1, type(uint32).max - block.timestamp - 1);
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        fixedLeg = bound(fixedLeg, 0, MAX_TEST_AMOUNT);
        floatingLeg = bound(floatingLeg, 0, MAX_TEST_AMOUNT);
        bond = bound(bond, 1, MAX_TEST_AMOUNT);
        venueCollateral = bound(venueCollateral, 0, collateral - 1);
        venueDebt = bound(venueDebt, 0, debt + floatingLeg - 1);
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
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPrice(price);

        _forward(blocks);

        // Already rebased - only the venue collateral fell below expected (one-sided change is ignored)
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, debt + floatingLeg);
        iris.rebase(pod);
        assertEq(iris.getPosition(pod).collateral, collateral);

        // Already rebased - only the venue debt fell below expected (one-sided change is ignored)
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, venueDebt);
        iris.rebase(pod);
        assertEq(iris.getPosition(pod).debt, debt);
        assertEq(iris.getPosition(pod).fixedLeg, fixedLeg);

        // Normal path - both venue collateral and venue debt fell below expected
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
        uint256 liquidated = collateral - venueCollateral;
        uint256 repaid = MathLib.min(debt + floatingLeg - venueDebt, liquidated.mulDivDown(price, ORACLE_PRICE_SCALE));
        uint256 badDebt = venueDebt.zeroFloorSub(venueCollateral.mulDivDown(price, ORACLE_PRICE_SCALE));

        bool resolved = badDebt != 0 || (venueDebt == 0 && venueCollateral == 0);
        // The repayment recognized above the principal is floating interest the collateral paid: it nets the fixed
        // leg first and the excess is slashed from the bond into the borrower's claimable. A resolved loan nets
        // nothing.
        uint256 overpaid = resolved ? 0 : repaid.zeroFloorSub(debt);
        uint256 bondSlashed = MathLib.min(overpaid.zeroFloorSub(fixedLeg), bond);
        uint256 expectedCollateral = collateral.zeroFloorSub(liquidated);
        uint256 expectedDebt = debt.zeroFloorSub(repaid);
        uint256 expectedBond = bond - bondSlashed;

        if (bondSlashed != 0) {
            vm.expectEmit();
            emit EventsLib.Claimable(debtToken, borrower, bondSlashed);
        }
        vm.expectEmit();
        emit EventsLib.Rebase(
            borrower,
            pod,
            expectedCollateral,
            expectedDebt,
            fixedLeg.zeroFloorSub(overpaid),
            expectedBond,
            venueCollateral,
            venueDebt,
            badDebt
        );
        vm.prank(borrower);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, expectedCollateral);
        assertEq(pos.debt, expectedDebt);
        assertEq(pos.fixedLeg, fixedLeg.zeroFloorSub(overpaid));
        assertEq(pos.floatingLeg, MathLib.min(floatingLeg, venueDebt));
        assertEq(pos.bond, expectedBond);
        assertEq(pos.lastUpdate, block.timestamp);
        assertEq(iris.claimable(debtToken, borrower), bondSlashed);
        // A slash that exhausts the bond resolves the loan like a bond liquidation would.
        assertEq(pos.bondRequirement, resolved || expectedBond == 0 ? 0 : 1);
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
        emit EventsLib.Rebase(
            address(this), pod, 0, 0, 0, 0, venueCollateral, venueDebt, venueDebt.zeroFloorSub(venueCollateral)
        );
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
    /// The fixed leg and the bond are untouched and the borrower is refunded no floating, even though
    /// the liquidated collateral (2e18 at par) would otherwise recognize the 0.1e18 above the principal.
    function testRebaseFullLiquidationZeroesBondRequirement() public {
        uint256 collateral = 2e18;
        uint256 debt = 1e18;
        uint256 fixedLeg = 0.05e18;
        uint256 floatingLeg = 0.1e18;
        uint256 bond = 0.02e18;
        uint256 bondRequirement = 1;
        uint256 venueCollateral = 0;
        uint256 venueDebt = 0;

        _setupRebaseState(collateral, debt, fixedLeg, floatingLeg, bond, bondRequirement, venueCollateral, venueDebt);

        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, 0, 0, fixedLeg, bond, 0, 0, 0);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, fixedLeg);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.bond, bond);
        assertEq(pos.bondRequirement, 0);
        assertEq(iris.claimable(debtToken, borrower), 0);
    }

    /// @dev REBASE: the repayment recognized above the principal nets the fixed leg first and only the excess is
    /// slashed from the bond into the borrower's claimable.
    ///
    /// debt 100, floating 10, fixed 5, bond 8.
    /// A venue liquidation that retires the whole venue debt nets the fixed leg to zero and slashes 5, leaving the bond
    /// below bondRequirement, which is a withdrawal floor and not a liquidation trigger.
    function testRebaseSlashesBondAfterNettingFixedLeg() public {
        uint256 collateral = 200e18;
        uint256 debt = 100e18;
        uint256 fixedLeg = 5e18;
        uint256 floatingLeg = 10e18;
        uint256 bond = 8e18;
        uint256 bondRequirement = 4e18;
        uint256 venueCollateral = 85e18; // 115e18 liquidated covers the 110e18 venue debt at par
        uint256 venueDebt = 0;
        uint256 bondSlashed = floatingLeg - fixedLeg;

        _setupRebaseState(collateral, debt, fixedLeg, floatingLeg, bond, bondRequirement, venueCollateral, venueDebt);

        vm.expectEmit();
        emit EventsLib.Claimable(debtToken, borrower, bondSlashed);
        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, venueCollateral, 0, 0, bond - bondSlashed, venueCollateral, 0, 0);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, venueCollateral);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.bond, bond - bondSlashed);
        assertLt(pos.bond, pos.bondRequirement);
        assertEq(pos.bondRequirement, bondRequirement);
        assertEq(iris.claimable(debtToken, borrower), bondSlashed);

        // Netted legs leave no drawdown: the bond stays healthy below the requirement.
        // bond 3e18, venueDebt 0
        vm.expectRevert(IIris.HealthyBond.selector);
        iris.liquidateBond(pod, receiver);
    }

    /// @dev REBASE: a slash that exhausts the bond resolves the loan like a bond liquidation would. The excess the
    /// bond cannot cover is bad bond borne by the borrower, so the claimable is capped at the bond. With debt, legs
    /// and bondRequirement all zero, every close path is shut and only escape (and the claim) remain.
    function testRebaseExhaustsBondAndResolves() public {
        uint256 collateral = 200e18;
        uint256 debt = 100e18;
        uint256 fixedLeg = 5e18;
        uint256 floatingLeg = 10e18;
        uint256 bond = 3e18; // below the 5e18 excess
        uint256 bondRequirement = 4e18;
        uint256 venueCollateral = 85e18;
        uint256 venueDebt = 0;

        _setupRebaseState(collateral, debt, fixedLeg, floatingLeg, bond, bondRequirement, venueCollateral, venueDebt);
        deal(debtToken, address(iris), bond);

        vm.expectEmit();
        emit EventsLib.Claimable(debtToken, borrower, bond);
        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, venueCollateral, 0, 0, 0, venueCollateral, 0, 0);
        iris.rebase(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, venueCollateral);
        assertEq(pos.debt, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.bond, 0);
        assertEq(pos.bondRequirement, 0);
        assertEq(iris.claimable(debtToken, borrower), bond);

        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.rebase(pod);
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.repay(pod);
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.liquidate(pod, receiver);
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.liquidateBond(pod, receiver);

        vm.startPrank(borrower);
        iris.claim(debtToken, bond, borrower, receiver);
        vm.expectEmit();
        emit EventsLib.Escape(borrower, pod, receiver, venueCollateral, 0);
        iris.escape(pod, receiver);
        vm.stopPrank();

        assertEq(debtToken.balanceOf(receiver), bond);
        assertEq(iris.getPosition(pod).collateral, 0);
    }

    /// @dev REBASE: a resolved loan nets nothing, even when a later rebase recognizes a repayment above the
    /// principal. `rebase` itself is shut on a resolved loan, so the rebase runs through `withdrawBond`, which
    /// the solver may call on a resolved loan whatever the net.
    function testRebaseResolvedLoanNetsNothing() public {
        uint256 collateral = 100e18;
        uint256 debt = 0;
        uint256 fixedLeg = 20e18;
        uint256 floatingLeg = 100e18;
        uint256 bond = 5e18;
        uint256 bondRequirement = 0;
        uint256 venueCollateral = 50e18;
        uint256 venueDebt = 40e18; // no bad debt at par

        // Resolved earlier (bondRequirement 0) with the principal already retired.
        _setupRebaseState(collateral, debt, fixedLeg, floatingLeg, bond, bondRequirement, venueCollateral, venueDebt);
        deal(debtToken, address(iris), bond);

        vm.expectEmit();
        emit EventsLib.Rebase(solver, pod, venueCollateral, 0, fixedLeg, bond, venueCollateral, venueDebt, 0);
        vm.expectEmit();
        emit EventsLib.WithdrawBond(solver, pod, receiver, bond);
        vm.prank(solver);
        iris.withdrawBond(pod, bond, receiver);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, venueCollateral);
        assertEq(pos.debt, 0);
        // The 50e18 recognized above the zero principal is not netted: the fixed leg is untouched and the whole
        // bond is still withdrawable, which a slash would have made underflow.
        assertEq(pos.fixedLeg, fixedLeg);
        assertEq(pos.floatingLeg, venueDebt);
        assertEq(pos.bond, 0);
        assertEq(debtToken.balanceOf(receiver), bond);
        assertEq(pos.bondRequirement, 0);
        assertEq(iris.claimable(debtToken, borrower), 0);
    }

    /* HELPERS */

    /// @dev Stored indices match the venue's so accrual contributes nothing; the price is par.
    function _setupRebaseState(
        uint256 collateral,
        uint256 debt,
        uint256 fixedLeg,
        uint256 floatingLeg,
        uint256 bond,
        uint256 bondRequirement,
        uint256 venueCollateral,
        uint256 venueDebt
    ) internal {
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bondRequirement));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
    }
}
