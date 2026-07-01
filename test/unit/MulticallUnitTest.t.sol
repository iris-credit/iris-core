// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {StorageUtils} from "./helpers/StorageUtils.sol";

contract MulticallUnitTest is UnitTest {
    using SafeTransferLib for address;

    function testMulticall(uint256 supplyAmount, uint256 withdrawAmount) public {
        supplyAmount = bound(supplyAmount, MIN_TEST_AMOUNT + 1, MAX_TEST_AMOUNT);
        withdrawAmount = bound(withdrawAmount, MIN_TEST_AMOUNT, supplyAmount);

        deal(collateralToken, borrower, supplyAmount);
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanBorrower(address(iris), pod, borrower);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(IIris.supplyCollateral, (pod, supplyAmount));
        data[1] = abi.encodeCall(IIris.withdrawCollateral, (pod, withdrawAmount, receiver));

        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), supplyAmount);
        Iris(address(iris)).multicall(data);
        vm.stopPrank();

        assertEq(iris.getPosition(pod).collateral, supplyAmount - withdrawAmount);
    }

    function testRevertMulticallFailing(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        deal(collateralToken, borrower, amount);
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeCall(IIris.supplyCollateral, (pod, 0));
        data[1] = abi.encodeCall(IIris.withdrawCollateral, (pod, amount, receiver));

        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), amount);
        vm.expectRevert(IIris.ZeroAmount.selector);
        Iris(address(iris)).multicall(data);
        vm.stopPrank();
    }
}
