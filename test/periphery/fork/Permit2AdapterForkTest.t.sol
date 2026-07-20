// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";

import "../helpers/PeripheryForkTest.sol";

/// @dev Canonical Permit2's nonce error.
error InvalidNonce();

contract Permit2AdapterForkTest is PeripheryForkTest {
    using SafeTransferLib for address;

    address internal usdc;

    function setUp() public override {
        super.setUp();

        usdc = getAddress("USDC");
    }

    function testTransferWithPermit2(uint256 amount) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);

        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_approve2(privateKey, usdc, amount, 0, false));
        bundle.push(_permit2TransferFrom(usdc, amount));

        deal(usdc, user, amount);

        vm.startPrank(user);
        usdc.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        bundler3.multicall(bundle);
        vm.stopPrank();

        assertEq(ERC20(usdc).balanceOf(address(generalAdapter1)), amount, "usdc.balanceOf(generalAdapter1)");
        assertEq(ERC20(usdc).balanceOf(user), 0, "usdc.balanceOf(user)");
    }

    function testApprove2(uint256 amount) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_approve2(privateKey, usdc, amount, 0, false));
        bundle.push(_approve2(privateKey, usdc, amount, 0, true));

        vm.startPrank(user);
        usdc.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        bundler3.multicall(bundle);
        vm.stopPrank();

        (uint160 permit2Allowance,,) = IPermit2(PermitUtils.PERMIT2).allowance(user, usdc, address(generalAdapter1));

        assertEq(permit2Allowance, amount, "PERMIT2.allowance(user, generalAdapter1)");
        assertEq(ERC20(usdc).allowance(user, address(generalAdapter1)), 0, "usdc.allowance(user, generalAdapter1)");
    }

    function testApprove2InvalidNonce(uint256 amount) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        bundle.push(_approve2(privateKey, usdc, amount, 0, false));
        bundle.push(_approve2(privateKey, usdc, amount, 0, false));

        vm.prank(user);
        vm.expectRevert(InvalidNonce.selector);
        bundler3.multicall(bundle);
    }

    function testPermit2TransferFromZeroAmount() public {
        bundle.push(_permit2TransferFrom(usdc, 0));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testPermit2TransferFromUnauthorized() public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.permit2TransferFrom(address(0), address(0), 0);
    }
}
