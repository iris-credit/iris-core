// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";

import "../helpers/PeripheryForkTest.sol";

contract WNativeAdapterForkTest is PeripheryForkTest {
    using SafeTransferLib for address;

    address internal immutable USER = makeAddr("User");
    address internal immutable RECEIVER = makeAddr("Receiver");

    address internal wEth;

    function setUp() public override {
        super.setUp();

        wEth = getAddress("WETH");

        vm.prank(USER);
        wEth.safeApprove(address(generalAdapter1), type(uint256).max);
    }

    function testWrapZeroAmount(address receiver) public {
        bundle.push(_wrapNative(0, receiver));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testWrapNative(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_transferNativeToAdapter(payable(generalAdapter1), amount));
        bundle.push(_wrapNative(amount, RECEIVER));

        deal(USER, amount);

        vm.prank(USER);
        bundler3.multicall{value: amount}(bundle);

        assertEq(ERC20(wEth).balanceOf(address(generalAdapter1)), 0, "Adapter's wrapped token balance");
        assertEq(ERC20(wEth).balanceOf(USER), 0, "User's wrapped token balance");
        assertEq(ERC20(wEth).balanceOf(RECEIVER), amount, "Receiver's wrapped token balance");

        assertEq(address(generalAdapter1).balance, 0, "Adapter's native token balance");
        assertEq(USER.balance, 0, "User's native token balance");
        assertEq(RECEIVER.balance, 0, "Receiver's native token balance");
    }

    function testUnwrapZeroAmount(address receiver) public {
        bundle.push(_unwrapNative(0, receiver));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testUnwrapNative(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20TransferFrom(wEth, amount));
        bundle.push(_unwrapNative(amount, RECEIVER));

        deal(wEth, USER, amount);

        vm.prank(USER);
        bundler3.multicall(bundle);

        assertEq(ERC20(wEth).balanceOf(address(generalAdapter1)), 0, "Adapter's wrapped token balance");
        assertEq(ERC20(wEth).balanceOf(USER), 0, "User's wrapped token balance");
        assertEq(ERC20(wEth).balanceOf(RECEIVER), 0, "Receiver's wrapped token balance");

        assertEq(address(generalAdapter1).balance, 0, "Adapter's native token balance");
        assertEq(USER.balance, 0, "User's native token balance");
        assertEq(RECEIVER.balance, amount, "Receiver's native token balance");
    }
}
