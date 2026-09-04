// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {StorageUtils} from "./helpers/StorageUtils.sol";

contract BondUnitTest is UnitTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    function testSupplyBond(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        // Zero amount
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.supplyBond(pod, 0);

        // Not entered
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.supplyBond(pod, amount);

        // Normal path
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        deal(debtToken, solver, amount);

        vm.startPrank(solver);
        debtToken.safeApprove(address(iris), amount);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, solver, address(iris), amount));
        vm.expectEmit();
        emit EventsLib.SupplyBond(solver, pod, amount);
        iris.supplyBond(pod, amount);
        vm.stopPrank();

        assertEq(iris.getPosition(pod).bond, amount);
    }

    function testWithdrawBond(uint256 amount, uint256 bond, uint256 bondRequirement, uint256 negativeNet) public {
        bond = bound(bond, MIN_TEST_AMOUNT + 1, MAX_TEST_AMOUNT);
        bondRequirement = bound(bondRequirement, 0, bond);
        amount = bound(amount, MIN_TEST_AMOUNT, bond);
        negativeNet = bound(negativeNet, 0, MAX_TEST_AMOUNT);

        // Zero amount
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.withdrawBond(pod, 0, receiver);

        // No receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.withdrawBond(pod, bond, address(0));

        // No enter
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.withdrawBond(pod, bond, receiver);

        // Unauthorized
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(borrower);
        iris.withdrawBond(pod, bond, receiver);

        // Insufficient bond - post-withdrawal bond falls below bondRequirement
        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bond));
        vm.expectRevert(IIris.InsufficientBond.selector);
        vm.prank(solver);
        iris.withdrawBond(pod, amount, receiver);

        // "Normal path" or "Insufficient bond"
        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bondRequirement));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(negativeNet));
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setLoanBondLltv(address(iris), pod, uint16(bondLltv / BP));

        // The bond health is checked on the post-withdrawal bond (bond - amount).
        if (!_isHealthyBond(bond - amount, bondRequirement, negativeNet)) {
            // Insufficient bond - remaining bond below requirement, or drawdown exceeds bondLltv
            vm.expectRevert(IIris.InsufficientBond.selector);
            vm.prank(solver);
            iris.withdrawBond(pod, amount, receiver);
        } else {
            // Normal path
            deal(debtToken, address(iris), amount);
            vm.prank(solver);
            vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, amount));
            vm.expectEmit();
            emit EventsLib.WithdrawBond(solver, pod, receiver, amount);
            iris.withdrawBond(pod, amount, receiver);

            assertEq(iris.getPosition(pod).bond, bond - amount);
            assertEq(debtToken.balanceOf(receiver), amount);
        }
    }

    function testLiquidateBond(uint256 bond, uint256 venueDebt, uint256 bondRequirement, uint256 negativeNet) public {
        bond = bound(bond, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        venueDebt = bound(venueDebt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        bondRequirement = bound(bondRequirement, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT); // Non-zero to enable liquidation
        negativeNet = bound(negativeNet, 0, MAX_TEST_AMOUNT);

        // Zero receiver
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.liquidateBond(pod, address(0));

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.liquidateBond(pod, receiver);

        // Zero amount - bondRequirement is zero
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.liquidateBond(pod, receiver);

        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bondRequirement));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));

        // "Healthy bond" or "Normal path"
        uint256 surplus = 1e18;
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanBondLltv(address(iris), pod, uint16(bondLltv / BP));
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(1e18));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(negativeNet + 1e18));
        StorageUtils.setPositionSurplus(address(iris), pod, uint128(surplus));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        // Set the venue collateral to pos.collateral + pos.surplus to satisfy the early-return condition in _rebase.
        VenueAdapterMock(address(venueAdapter)).setPosition(surplus, venueDebt);
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);

        uint256 lif = MathLib.min(
            MAX_BOND_LIF, WAD.mulDivDown(WAD, WAD - LIQUIDATION_CURSOR.mulDivDown(WAD - bondLltv, WAD)) - WAD
        );
        uint256 seized = bond.mulDivDown(lif, WAD);
        uint256 bondSlashed = MathLib.min(negativeNet + seized, bond);
        uint256 repaid = MathLib.min(bondSlashed - seized, venueDebt);

        if (_isHealthyBond(bond, bondRequirement, negativeNet)) {
            // Healthy bond - liquidation not allowed
            vm.expectRevert(IIris.HealthyBond.selector);
            iris.liquidateBond(pod, receiver);
        } else {
            // Normal path
            deal(debtToken, address(iris), bond);
            vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, repaid));
            vm.expectCall(
                address(venueAdapter), abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, repaid, "")
            );
            vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, seized));
            vm.expectEmit();
            emit EventsLib.LiquidateBond(address(this), pod, receiver, seized);
            uint256 collateralBefore = iris.getPosition(pod).collateral;
            uint256 returned = iris.liquidateBond(pod, receiver);

            Position memory pos = iris.getPosition(pod);
            assertEq(returned, seized);
            assertEq(pos.bond, bond - bondSlashed);
            assertEq(pos.bondRequirement, 0);
            // Collateral stays tracked for the borrower to withdraw or escape.
            assertEq(pos.collateral, collateralBefore);
            assertEq(pos.debt, 0);
            assertEq(pos.fixedLeg, 0);
            assertEq(pos.floatingLeg, 0);
            assertEq(pos.surplus, 0);
            assertEq(debtToken.balanceOf(receiver), seized);
        }
    }

    /// @dev BOND LIQUIDATION: "If slashed bond exceeds current venue debt plus incentive, only current
    /// venue debt is repaid. Any excess remains in Iris is treated as donation."
    function testLiquidateBondDonatesExcessToIris() public {
        uint256 bond = 1e18;
        uint256 negativeNet = 0.92e18; // liquidatable, and slashed-minus-incentive exceeds the venue debt
        uint256 venueDebt = 1e6;

        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(negativeNet));
        StorageUtils.setLoanBondLltv(address(iris), pod, uint16(bondLltv / BP));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setIndices(1e27, 1e27);
        VenueAdapterMock(address(venueAdapter)).setPosition(0, venueDebt);
        deal(debtToken, address(iris), bond);

        uint256 lif = MathLib.min(
            MAX_BOND_LIF, WAD.mulDivDown(WAD, WAD - LIQUIDATION_CURSOR.mulDivDown(WAD - bondLltv, WAD)) - WAD
        );
        uint256 seized = bond.mulDivDown(lif, WAD);

        // Only the venue debt is repaid; the repayment is capped at venueDebt, not the larger slashed amount.
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter), abi.encodeWithSelector(IVenueAdapter.repay.selector, debtToken, venueDebt, "")
        );
        iris.liquidateBond(pod, receiver);

        // The slashed-but-unrepaid remainder stays in Iris as a donation.
        assertEq(debtToken.balanceOf(address(iris)), bond - seized - venueDebt);
        assertEq(debtToken.balanceOf(receiver), seized);
        assertEq(debtToken.balanceOf(pod), venueDebt);
    }

    function testWithdrawBondRebaseAllowsLargerWithdrawal() public {
        uint256 bond = 1e18;
        uint256 bondRequirement = 0.1e18;
        uint256 staleFloatingLeg = 0.5e18;
        uint256 venueCollateral = 1e18;
        uint256 venueDebt = 0.01e18; // live debt has fallen well below the stale floating leg
        uint256 amount = 0.9e18;

        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanBondLltv(address(iris), pod, uint16(bondLltv / BP));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bondRequirement));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(staleFloatingLeg));
        StorageUtils.setPositionCollateral(address(iris), pod, 10e18);
        StorageUtils.setPositionDebt(address(iris), pod, 5e18);
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);

        assertFalse(_isHealthyBond(bond - amount, bondRequirement, staleFloatingLeg));
        assertTrue(_isHealthyBond(bond - amount, bondRequirement, venueDebt));

        deal(debtToken, address(iris), amount);

        vm.prank(solver);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, amount));
        vm.expectEmit();
        emit EventsLib.WithdrawBond(solver, pod, receiver, amount);
        iris.withdrawBond(pod, amount, receiver);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.bond, bond - amount);
        assertEq(pos.floatingLeg, venueDebt);
        assertEq(pos.debt, 0);
        assertEq(pos.collateral, venueCollateral);
        assertEq(pos.bondRequirement, bondRequirement);
        assertEq(debtToken.balanceOf(receiver), amount);
    }

    function testLiquidateBondRebaseRestoresHealth() public {
        uint256 bond = 1e18;
        uint256 bondRequirement = 0.1e18;
        uint256 staleFloatingLeg = 1e18;
        uint256 venueCollateral = 1e18;
        uint256 venueDebt = 0.01e18; // live debt has fallen well below the stale floating leg

        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanBondLltv(address(iris), pod, uint16(bondLltv / BP));
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        StorageUtils.setPositionBondRequirement(address(iris), pod, uint128(bondRequirement));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(staleFloatingLeg));
        StorageUtils.setPositionCollateral(address(iris), pod, 10e18);
        StorageUtils.setPositionDebt(address(iris), pod, 5e18);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(1e27));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(1e27));
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);

        assertFalse(_isHealthyBond(bond, bondRequirement, staleFloatingLeg));
        assertTrue(_isHealthyBond(bond, bondRequirement, venueDebt));

        vm.expectRevert(IIris.HealthyBond.selector);
        iris.liquidateBond(pod, receiver);
    }

    function _isHealthyBond(uint256 bond, uint256 bondRequirement, uint256 negativeNet) internal view returns (bool) {
        if (bondRequirement == 0) return true;
        if (bond < bondRequirement) return false;
        if (negativeNet == 0) return true;
        return negativeNet.mulDivUp(WAD, bond) <= bondLltv;
    }
}
