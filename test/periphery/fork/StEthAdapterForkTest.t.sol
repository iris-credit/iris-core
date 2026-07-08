// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";
import {MathRayLib} from "../../../src/periphery/libraries/MathRayLib.sol";
import {IWstEth} from "../../../src/periphery/interfaces/IWstEth.sol";
// Aliased since ForkTest exposes its own minimal IStEth for its deal override.
import {IStEth as IStEthLido} from "../../../src/periphery/interfaces/IStEth.sol";

import "../helpers/PeripheryForkTest.sol";

/// @dev Lido's staking rate limit caps single-block submissions, so amounts are bounded well below it.
uint256 constant MAX_STAKE_AMOUNT = 10_000 ether;

contract StEthAdapterForkTest is PeripheryForkTest {
    using SafeTransferLib for address;
    using MathRayLib for uint256;

    address internal immutable USER = makeAddr("User");
    address internal immutable RECEIVER = makeAddr("Receiver");

    address internal stEth;
    address internal wstEth;

    function setUp() public override {
        super.setUp();

        stEth = getAddress("stETH");
        wstEth = getAddress("wstETH");
    }

    function testStakeEthZeroAmount(address receiver) public {
        bundle.push(_stakeEth(0, type(uint256).max, address(0), receiver));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testStakeEth(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_STAKE_AMOUNT);

        uint256 shares = IStEthLido(stEth).getSharesByPooledEth(amount);

        bundle.push(_transferNativeToAdapter(payable(generalAdapter1), amount));
        bundle.push(_stakeEth(amount, amount.rDivDown(shares - 2), address(0), RECEIVER));

        deal(USER, amount);

        vm.prank(USER);
        bundler3.multicall{value: amount}(bundle);

        assertEq(USER.balance, 0, "USER.balance");
        assertEq(RECEIVER.balance, 0, "RECEIVER.balance");
        assertEq(address(ethereumGeneralAdapter1).balance, 0, "ethereumGeneralAdapter1.balance");
        assertEq(ERC20(stEth).balanceOf(USER), 0, "balanceOf(USER)");
        assertApproxEqAbs(
            ERC20(stEth).balanceOf(address(ethereumGeneralAdapter1)), 0, 1, "balanceOf(ethereumGeneralAdapter1)"
        );
        assertApproxEqAbs(ERC20(stEth).balanceOf(RECEIVER), amount, 3, "balanceOf(RECEIVER)");
    }

    function testStakeEthSlippageExceeded(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_STAKE_AMOUNT);

        uint256 shares = IStEthLido(stEth).getSharesByPooledEth(amount);

        // Demand half the real share price so the stake trips the guard.
        bundle.push(_transferNativeToAdapter(payable(generalAdapter1), amount));
        bundle.push(_stakeEth(amount, amount.rDivDown(shares * 2), address(0), address(ethereumGeneralAdapter1)));

        deal(USER, amount);

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.SlippageExceeded.selector);
        bundler3.multicall{value: amount}(bundle);
    }

    function testWrapZeroAmount(address receiver) public {
        bundle.push(_wrapStEth(0, receiver));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testWrapStEth(uint256 amount) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_STAKE_AMOUNT);

        deal(stEth, user, amount);

        amount = ERC20(stEth).balanceOf(user);

        bundle.push(_approve2(privateKey, stEth, amount, 0, false));
        bundle.push(_permit2TransferFrom(stEth, address(ethereumGeneralAdapter1), amount));
        bundle.push(_wrapStEth(amount, RECEIVER));

        uint256 wstEthExpectedAmount = IStEthLido(stEth).getSharesByPooledEth(ERC20(stEth).balanceOf(user));

        vm.startPrank(user);
        stEth.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        bundler3.multicall(bundle);
        vm.stopPrank();

        assertEq(ERC20(wstEth).balanceOf(address(ethereumGeneralAdapter1)), 0, "wstEth.balanceOf(adapter)");
        assertEq(ERC20(wstEth).balanceOf(user), 0, "wstEth.balanceOf(user)");
        assertApproxEqAbs(ERC20(wstEth).balanceOf(RECEIVER), wstEthExpectedAmount, 1, "wstEth.balanceOf(RECEIVER)");

        assertApproxEqAbs(ERC20(stEth).balanceOf(address(ethereumGeneralAdapter1)), 0, 1, "stEth.balanceOf(adapter)");
        assertApproxEqAbs(ERC20(stEth).balanceOf(user), 0, 1, "stEth.balanceOf(user)");
        assertEq(ERC20(stEth).balanceOf(RECEIVER), 0, "stEth.balanceOf(RECEIVER)");
    }

    function testUnwrapZeroAmount(address receiver) public {
        bundle.push(_unwrapStEth(0, receiver));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        vm.prank(USER);
        bundler3.multicall(bundle);
    }

    function testUnwrapWstEth(uint256 amount) public {
        uint256 privateKey = _boundPrivateKey(pickUint());
        address user = vm.addr(privateKey);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_STAKE_AMOUNT);

        bundle.push(_approve2(privateKey, wstEth, amount, 0, false));
        bundle.push(_permit2TransferFrom(wstEth, address(ethereumGeneralAdapter1), amount));
        bundle.push(_unwrapStEth(amount, RECEIVER));

        deal(wstEth, user, amount);

        vm.startPrank(user);
        wstEth.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        bundler3.multicall(bundle);
        vm.stopPrank();

        uint256 expectedUnwrappedAmount = IWstEth(wstEth).getStETHByWstETH(amount);

        assertEq(ERC20(wstEth).balanceOf(address(ethereumGeneralAdapter1)), 0, "wstEth.balanceOf(adapter)");
        assertEq(ERC20(wstEth).balanceOf(user), 0, "wstEth.balanceOf(user)");
        assertEq(ERC20(wstEth).balanceOf(RECEIVER), 0, "wstEth.balanceOf(RECEIVER)");

        assertApproxEqAbs(ERC20(stEth).balanceOf(address(ethereumGeneralAdapter1)), 0, 1, "stEth.balanceOf(adapter)");
        assertEq(ERC20(stEth).balanceOf(user), 0, "stEth.balanceOf(user)");
        assertApproxEqAbs(ERC20(stEth).balanceOf(RECEIVER), expectedUnwrappedAmount, 3, "stEth.balanceOf(RECEIVER)");
    }
}
