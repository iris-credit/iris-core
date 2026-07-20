// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";

import "../helpers/PeripheryUnitTest.sol";

contract TransferAdapterUnitTest is PeripheryUnitTest {
    address internal immutable USER = makeAddr("User");
    address internal immutable RECEIVER = makeAddr("Receiver");

    function testTransferFrom(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20TransferFrom(debtToken, amount));

        deal(debtToken, USER, amount);

        vm.startPrank(USER);
        ERC20(debtToken).approve(address(generalAdapter1), type(uint256).max);
        bundler3.multicall(bundle);
        vm.stopPrank();

        assertEq(ERC20(debtToken).balanceOf(address(generalAdapter1)), amount, "debt.balanceOf(generalAdapter1)");
        assertEq(ERC20(debtToken).balanceOf(USER), 0, "debt.balanceOf(USER)");
    }

    function testTransferFromZeroAddress(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20TransferFrom(debtToken, address(0), amount));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        bundler3.multicall(bundle);
    }

    function testTransferFromUnauthorized(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.erc20TransferFrom(debtToken, RECEIVER, amount);
    }

    function testTransferFromZeroAmount() public {
        bundle.push(_erc20TransferFrom(debtToken, 0));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }
}
