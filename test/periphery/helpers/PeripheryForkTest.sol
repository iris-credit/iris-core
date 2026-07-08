// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../ForkTest.t.sol";

import "./PeripheryTest.sol";

import {EthereumGeneralAdapter1} from "../../../src/periphery/adapters/EthereumGeneralAdapter1.sol";

/// @dev Periphery environment against the fork scaffold: real venues, the Ethereum adapter variant.
abstract contract PeripheryForkTest is ForkTest, PeripheryTest {
    EthereumGeneralAdapter1 internal ethereumGeneralAdapter1;

    function setUp() public virtual override(ForkTest, PeripheryTest) {
        super.setUp();

        ethereumGeneralAdapter1 = new EthereumGeneralAdapter1(
            address(bundler3), morphoBlue, getAddress("WETH"), getAddress("wstETH"), address(iris)
        );
        generalAdapter1 = GeneralAdapter1(payable(address(ethereumGeneralAdapter1)));

        vm.label(address(generalAdapter1), "EthereumGeneralAdapter1");
    }

    /// @dev Disambiguates the diamond between ForkTest's override and StdCheats' original.
    function deal(address asset, address recipient, uint256 amount) internal virtual override(StdCheats, ForkTest) {
        super.deal(asset, recipient, amount);
    }

    /* LIDO ACTIONS */

    function _stakeEth(uint256 amount, uint256 maxSharePriceE27, address referral, address receiver)
        internal
        view
        returns (Call memory)
    {
        return _call(
            ethereumGeneralAdapter1,
            abi.encodeCall(EthereumGeneralAdapter1.stakeEth, (amount, maxSharePriceE27, referral, receiver))
        );
    }

    function _wrapStEth(uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(ethereumGeneralAdapter1, abi.encodeCall(EthereumGeneralAdapter1.wrapStEth, (amount, receiver)));
    }

    function _unwrapStEth(uint256 amount, address receiver) internal view returns (Call memory) {
        return _call(ethereumGeneralAdapter1, abi.encodeCall(EthereumGeneralAdapter1.unwrapStEth, (amount, receiver)));
    }
}
