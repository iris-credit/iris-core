// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {StorageUtils} from "./helpers/StorageUtils.sol";
import {VenueAdapterMock} from "./helpers/mocks/VenueAdapterMock.sol";
import {IrisHarness} from "./helpers/mocks/IrisHarness.sol";

contract InterestUnitTest is UnitTest {
    using MathLib for uint256;

    /// @dev Deploy the harness so _accrueLegs and _settleLegs can be exercised directly
    /// (see testAccrueLegs and testSettleLegs).
    function _newIris(address newOwner, address podImpl_) internal override returns (address) {
        return address(new IrisHarness(newOwner, podImpl_));
    }

    function testAccrueLegsView(
        uint256 collateral,
        uint256 debt,
        uint256 blocks,
        uint256 duration,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 collateralIndex,
        uint256 debtIndex
    ) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        blocks = bound(blocks, 1, MAX_DURATION + MAX_OVERDUE_PERIOD);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP);
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP);
        collateralIndex = bound(collateralIndex, 1e27, 1e28);
        debtIndex = bound(debtIndex, 1e27, 1e28);

        // No loan - lastUpdate == 0
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(2e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(3e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(9e27, 9e27);

        (uint256 newCollateralIndex, uint256 newDebtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            iris.accrueLegsView(pod);
        assertEq(newCollateralIndex, 2e27);
        assertEq(newDebtIndex, 3e27);
        assertEq(fixedLeg, 0);
        assertEq(floatingLeg, 0);
        assertEq(surplus, 0);

        // Before / after maturity
        uint256 maturity = block.timestamp + duration;
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        // Active loan (bondRequirement != 0) so surplus accrues; a resolved loan freezes it.
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(fixedRate));
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(overdueRate));
        VenueAdapterMock(address(venueAdapter)).setIndices(collateralIndex, debtIndex);

        _forward(blocks);

        uint256 expectedFixed = debt.mulDivDown(blocks * fixedRate * BP, SECONDS_PER_YEAR * WAD);
        uint256 expectedFloat = debt.mulDivDown(debtIndex - 1e27, 1e27);
        uint256 expectedSurplus = collateral.mulDivDown(collateralIndex - 1e27, 1e27);

        if (block.timestamp > maturity) {
            uint256 overdueElapsed = block.timestamp - maturity;
            expectedFixed += debt.mulDivDown(overdueElapsed * overdueRate * BP, SECONDS_PER_YEAR * WAD);
        }

        (newCollateralIndex, newDebtIndex, fixedLeg, floatingLeg, surplus) = iris.accrueLegsView(pod);
        assertEq(newCollateralIndex, collateralIndex);
        assertEq(newDebtIndex, debtIndex);
        assertEq(fixedLeg, expectedFixed);
        assertEq(floatingLeg, expectedFloat);
        assertEq(surplus, expectedSurplus);
    }

    /// @dev With zero elapsed (same block) accrual short-circuits and returns the stored indices
    /// without reading the venue, even when the venue indices have since moved.
    function testAccrueLegsViewSameBlock() public {
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(2e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(3e27));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(MAX_FIXED_RATE / BP));
        VenueAdapterMock(address(venueAdapter)).setIndices(9e27, 9e27);

        // No time warp -> elapsed == 0.
        (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            iris.accrueLegsView(pod);
        assertEq(collateralIndex, 2e27);
        assertEq(debtIndex, 3e27);
        assertEq(fixedLeg, 0);
        assertEq(floatingLeg, 0);
        assertEq(surplus, 0);
    }

    /// @dev The floating leg compounds on (debt + stored floatingLeg) and the surplus on
    /// (collateral + stored surplus); the external view also adds the stored legs to the new accrual.
    function testAccrueLegsViewCompounding() public {
        uint256 maturity = block.timestamp + 2 * SECONDS_PER_YEAR;
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(1000)); // 10% APR
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionFixedLeg(address(iris), pod, 0.5e6);
        StorageUtils.setPositionFloatingLeg(address(iris), pod, 0.2e6);
        StorageUtils.setPositionSurplus(address(iris), pod, 0.3e18);
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1); // active loan: surplus accrues
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1.2e27, 1.5e27);

        _forward(SECONDS_PER_YEAR);

        (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            iris.accrueLegsView(pod);
        assertEq(collateralIndex, 1.2e27);
        assertEq(debtIndex, 1.5e27);
        // fixed: stored 0.5e6 + 10% of debt 1e6 over a year (0.1e6)
        assertEq(fixedLeg, 0.6e6);
        // floating: stored 0.2e6 + (debt 1e6 + stored 0.2e6) * 50% index growth (0.6e6)
        assertEq(floatingLeg, 0.8e6);
        // surplus: stored 0.3e18 + (collateral 1e18 + stored 0.3e18) * 20% index growth (0.26e18)
        assertEq(surplus, 0.56e18);
    }

    /// @dev When lastUpdate is already past maturity, overdue interest accrues from lastUpdate
    /// (overdueStart = max(maturity, lastUpdate)), so the post-maturity window is never double-counted.
    function testAccrueLegsViewOverdue() public {
        // Foundry's default block.timestamp is 1
        vm.warp(10 * SECONDS_PER_YEAR);
        uint256 lastUpdate = block.timestamp;
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(lastUpdate));
        // Maturity a full year before lastUpdate: counting overdue from maturity would double the window.
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(lastUpdate - SECONDS_PER_YEAR));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(1000)); // 10% APR
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(2000)); // 20% APR
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionCollateral(address(iris), pod, 0);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);

        _forward(SECONDS_PER_YEAR);

        // Over one year: fixed 10% + overdue 20% of debt 1e6 = 0.1e6 + 0.2e6. Counting overdue from
        // maturity would have charged two years of overdue (0.4e6) for a 0.5e6 total.
        (,, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) = iris.accrueLegsView(pod);
        assertEq(fixedLeg, 0.3e6);
        assertEq(floatingLeg, 0);
        assertEq(surplus, 0);
    }

    /// @dev A zero-debt position accrues no fixed, overdue, or floating interest even past maturity
    /// with moving indices, while the surplus still accrues on the collateral.
    function testAccrueLegsViewZeroDebt() public {
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(block.timestamp)); // already matured
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(MAX_FIXED_RATE / BP));
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(MAX_OVERDUE_RATE / BP));
        StorageUtils.setPositionDebt(address(iris), pod, 0);
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1); // active loan: surplus accrues
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1.2e27, 1.5e27);

        _forward(SECONDS_PER_YEAR);

        (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            iris.accrueLegsView(pod);
        assertEq(collateralIndex, 1.2e27);
        assertEq(debtIndex, 1.5e27);
        assertEq(fixedLeg, 0);
        assertEq(floatingLeg, 0);
        // surplus = collateral 1e18 * 20% index growth
        assertEq(surplus, 0.2e18);
    }

    /// @dev A resolved loan (bondRequirement == 0) freezes surplus accrual so integrators no longer
    /// see phantom collateral yield, while the debt legs keep accruing for bad debt repay/liquidation solvency.
    function testAccrueLegsViewResolvedLoan() public {
        uint256 maturity = block.timestamp + 2 * SECONDS_PER_YEAR;
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(1000)); // 10% APR
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionSurplus(address(iris), pod, 7e17);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        // bondRequirement stays 0 -> loan is resolved.
        VenueAdapterMock(address(venueAdapter)).setIndices(1.2e27, 1.5e27);

        _forward(SECONDS_PER_YEAR);

        (,, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) = iris.accrueLegsView(pod);
        // Debt legs still accrue: fixed = 10% of debt 1e6; floating = 50% debt-index growth on 1e6.
        assertEq(fixedLeg, 0.1e6);
        assertEq(floatingLeg, 0.5e6);
        // Surplus is frozen at its stored value despite collateral and a rising collateral index.
        assertEq(surplus, 0.7e18);
    }

    /// @dev Tests _accrueLegs in isolation through the harness: it adds the accrued deltas onto the
    /// stored legs (+=) and emits the bare deltas.
    function testAccrueLegs(
        uint256 collateral,
        uint256 debt,
        uint256 blocks,
        uint256 duration,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 collateralIndex,
        uint256 debtIndex,
        uint256 fixedLeg,
        uint256 floatingLeg,
        uint256 surplus
    ) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        blocks = bound(blocks, 1, MAX_DURATION + MAX_OVERDUE_PERIOD);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP);
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP);
        collateralIndex = bound(collateralIndex, 1e27, 1e28);
        debtIndex = bound(debtIndex, 1e27, 1e28);
        // Non-zero stored legs so the assertions distinguish `+=` from `=`.
        fixedLeg = bound(fixedLeg, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        floatingLeg = bound(floatingLeg, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        surplus = bound(surplus, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        uint256 maturity = block.timestamp + duration;
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1); // active loan: surplus accrues
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionSurplus(address(iris), pod, uint128(surplus));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(fixedRate));
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(overdueRate));
        VenueAdapterMock(address(venueAdapter)).setIndices(collateralIndex, debtIndex);

        _forward(blocks);

        // accrueLegsView reports the cumulative legs (stored + delta); the Accrue event carries the
        // bare deltas, so subtract the stored legs to recover them.
        (
            uint256 newCollateralIndex,
            uint256 newDebtIndex,
            uint256 newFixedLeg,
            uint256 newFloatingLeg,
            uint256 newSurplus
        ) = iris.accrueLegsView(pod);
        vm.expectEmit();
        emit EventsLib.Accrue(
            pod,
            newCollateralIndex,
            newDebtIndex,
            newFixedLeg - fixedLeg,
            newFloatingLeg - floatingLeg,
            newSurplus - surplus
        );
        IrisHarness(address(iris)).accrueLegs(pod);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateralIndex, newCollateralIndex);
        assertEq(pos.debtIndex, newDebtIndex);
        // `+=`: each leg ends at stored + delta, i.e. the cumulative the view reported.
        assertEq(pos.fixedLeg, newFixedLeg);
        assertEq(pos.floatingLeg, newFloatingLeg);
        assertEq(pos.surplus, newSurplus);
        assertEq(pos.lastUpdate, block.timestamp);
        // _accrueLegs touches only the legs, indices, and lastUpdate — never principal.
        assertEq(pos.collateral, collateral);
        assertEq(pos.debt, debt);
    }

    /// @dev On a zero-elapsed (same block) call _accrueLegs early-returns: no Accrue event is emitted
    /// and the stored indices, legs, and lastUpdate are left untouched (no redundant writes).
    function testAccrueLegsSameBlock() public {
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateral(address(iris), pod, 1e18);
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(MAX_FIXED_RATE / BP));
        // Venue indices have moved, but a zero-elapsed call must neither read nor apply them.
        VenueAdapterMock(address(venueAdapter)).setIndices(5e27, 5e27);

        // _accrueLegs returns before emitting Accrue or writing storage.
        vm.recordLogs();
        IrisHarness(address(iris)).accrueLegs(pod);
        assertEq(vm.getRecordedLogs().length, 0);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateralIndex, 1e27);
        assertEq(pos.debtIndex, 1e27);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.lastUpdate, block.timestamp);
        assertEq(pos.collateral, 1e18);
        assertEq(pos.debt, 1e6);
    }

    /// @dev Tests _settleLegs through the harness. Before maturity it first adds the fixed interest
    /// owed from now through maturity (on principal, not the accrued legs), then settles the net leg.
    function testSettleLegsAddsResidualBeforeMaturity(
        uint256 debt,
        uint256 fixedRate,
        uint256 fixedLeg,
        uint256 timeToMaturity
    ) public {
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP);
        fixedLeg = bound(fixedLeg, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        timeToMaturity = bound(timeToMaturity, 1, MAX_DURATION);

        uint256 maturity = block.timestamp + timeToMaturity;
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(fixedRate));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));

        uint256 residual = debt.mulDivDown(timeToMaturity * fixedRate * BP, SECONDS_PER_YEAR * WAD);
        IrisHarness(address(iris)).settleLegs(pod);

        uint256 settledFixedLeg = fixedLeg + residual;
        assertEq(iris.getPosition(pod).fixedLeg, settledFixedLeg);
        assertEq(iris.claimable(debtToken, solver), settledFixedLeg);
    }

    function testSettleLegsDoesNotAddResidualAtMaturity() public {
        uint256 maturity = block.timestamp + SECONDS_PER_YEAR;
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(1000)); // 10% APR
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionFixedLeg(address(iris), pod, 0.5e6);

        vm.warp(maturity);

        IrisHarness(address(iris)).settleLegs(pod);

        assertEq(iris.getPosition(pod).fixedLeg, 0.5e6);
        assertEq(iris.claimable(debtToken, solver), 0.5e6);
    }

    function testSettleLegsAddsResidualConcrete() public {
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(block.timestamp + SECONDS_PER_YEAR / 2));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(1000)); // 10% APR
        StorageUtils.setPositionDebt(address(iris), pod, 1e6);
        StorageUtils.setPositionFixedLeg(address(iris), pod, 0.5e6);

        IrisHarness(address(iris)).settleLegs(pod);

        // residual = principal 1e6 * 10% APR * 0.5 year = 0.05e6, on principal only; stored 0.5e6 + 0.05e6.
        assertEq(iris.getPosition(pod).fixedLeg, 0.55e6);
        assertEq(iris.claimable(debtToken, solver), 0.55e6);
    }

    function testClaim(uint256 accrued, uint256 amount) public {
        accrued = bound(accrued, 2, type(uint128).max);
        amount = bound(amount, 1, accrued);

        // Zero address (token)
        vm.expectRevert(abi.encodeWithSelector(IIris.ZeroAddress.selector));
        iris.claim(address(0), amount, solver, receiver);

        // Zero amount
        vm.expectRevert(abi.encodeWithSelector(IIris.ZeroAmount.selector));
        iris.claim(debtToken, 0, solver, receiver);

        // Zero address (onBehalf)
        vm.expectRevert(abi.encodeWithSelector(IIris.ZeroAddress.selector));
        iris.claim(debtToken, amount, address(0), receiver);

        // Zero address (receiver)
        vm.expectRevert(abi.encodeWithSelector(IIris.ZeroAddress.selector));
        iris.claim(debtToken, amount, solver, address(0));

        // Unauthorized
        vm.expectRevert(abi.encodeWithSelector(IIris.Unauthorized.selector));
        iris.claim(debtToken, amount, solver, receiver);

        // Normal path
        StorageUtils.setClaimable(address(iris), debtToken, solver, accrued);
        deal(debtToken, address(iris), amount);
        vm.prank(solver);
        iris.setAuthorization(receiver, true);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, amount));
        vm.expectEmit();
        emit EventsLib.Claim(receiver, debtToken, solver, receiver, amount);
        vm.prank(receiver);
        iris.claim(debtToken, amount, solver, receiver);
    }
}
