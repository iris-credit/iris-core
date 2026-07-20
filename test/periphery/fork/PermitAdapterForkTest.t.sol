// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../helpers/PeripheryForkTest.sol";

contract PermitAdapterForkTest is PeripheryForkTest {
    address internal usdc;

    function setUp() public override {
        super.setUp();

        usdc = getAddress("USDC");
    }

    function testPermit(uint256 amount, address spender, uint256 deadline) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        vm.assume(spender != address(0));
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        deadline = bound(deadline, block.timestamp, type(uint48).max);

        bundle.push(_permit(usdc, privateKey, spender, amount, deadline, false));
        bundle.push(_permit(usdc, privateKey, spender, amount, deadline, true));

        vm.prank(user);
        bundler3.multicall(bundle);

        assertEq(ERC20(usdc).allowance(user, spender), amount, "allowance(user, spender)");
    }

    function testTransferFrom(uint256 amount, uint256 deadline) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        deadline = bound(deadline, block.timestamp, type(uint48).max);

        bundle.push(_permit(usdc, privateKey, address(generalAdapter1), amount, deadline, false));
        bundle.push(_erc20TransferFrom(usdc, amount));

        deal(usdc, user, amount);

        vm.prank(user);
        bundler3.multicall(bundle);

        assertEq(ERC20(usdc).balanceOf(address(generalAdapter1)), amount, "balanceOf(generalAdapter1)");
        assertEq(ERC20(usdc).balanceOf(user), 0, "balanceOf(user)");
    }
}
