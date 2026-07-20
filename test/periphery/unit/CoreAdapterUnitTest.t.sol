// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";

import "../helpers/PeripheryUnitTest.sol";

contract ConcreteCoreAdapter is CoreAdapter {
    constructor(address bundler3) CoreAdapter(bundler3) {}
}

contract CoreAdapterUnitTest is PeripheryUnitTest {
    address internal immutable USER = makeAddr("User");
    address internal immutable RECEIVER = makeAddr("Receiver");
    CoreAdapter internal coreAdapter;

    function setUp() public override {
        super.setUp();
        coreAdapter = new ConcreteCoreAdapter(address(bundler3));
    }

    function testTransfer(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20Transfer(debtToken, RECEIVER, amount, coreAdapter));

        deal(debtToken, address(coreAdapter), amount);

        bundler3.multicall(bundle);

        assertEq(ERC20(debtToken).balanceOf(address(coreAdapter)), 0, "debt.balanceOf(coreAdapter)");
        assertEq(ERC20(debtToken).balanceOf(RECEIVER), amount, "debt.balanceOf(RECEIVER)");
    }

    function testTransferZeroAddress(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20Transfer(debtToken, address(0), amount, coreAdapter));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        bundler3.multicall(bundle);
    }

    function testTransferAdapterAddress(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_erc20Transfer(debtToken, address(coreAdapter), amount, coreAdapter));

        vm.expectRevert(ErrorsLib.AdapterAddress.selector);
        bundler3.multicall(bundle);
    }

    function testTransferZeroExactAmount() public {
        bundle.push(_erc20Transfer(debtToken, RECEIVER, 0, coreAdapter));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testTransferZeroBalanceAmount() public {
        bundle.push(_erc20Transfer(debtToken, RECEIVER, type(uint256).max, coreAdapter));

        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testNativeTransfer(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_transferNativeToAdapter(payable(coreAdapter), amount));
        bundle.push(_nativeTransfer(RECEIVER, amount, coreAdapter));

        deal(address(bundler3), amount);

        bundler3.multicall(bundle);

        assertEq(address(coreAdapter).balance, 0, "coreAdapter.balance");
        assertEq(RECEIVER.balance, amount, "RECEIVER.balance");
    }

    function testNativeTransferZeroAddress(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_nativeTransferNoFunding(address(0), amount, coreAdapter));

        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        bundler3.multicall(bundle);
    }

    function testNativeTransferAdapterAddress(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_nativeTransferNoFunding(address(coreAdapter), amount, coreAdapter));

        vm.expectRevert(ErrorsLib.AdapterAddress.selector);
        bundler3.multicall(bundle);
    }

    function testNativeTransferZeroExactAmount() public {
        bundle.push(_nativeTransferNoFunding(RECEIVER, 0, coreAdapter));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testNativeTransferZeroBalanceAmount() public {
        bundle.push(_nativeTransferNoFunding(RECEIVER, type(uint256).max, coreAdapter));

        bundler3.multicall(bundle);
    }
}
