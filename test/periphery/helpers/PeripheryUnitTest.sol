// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../../UnitTest.t.sol";

import "./PeripheryTest.sol";

/// @dev Periphery environment against the unit scaffold: venue and tokens are mocked. The Morpho and
/// wrapped native addresses are placeholders since flash loans and native wrapping are fork-only.
abstract contract PeripheryUnitTest is UnitTest, PeripheryTest {
    function setUp() public virtual override(UnitTest, PeripheryTest) {
        super.setUp();

        generalAdapter1 = new GeneralAdapter1(address(bundler3), makeAddr("morpho"), makeAddr("wNative"), address(iris));

        vm.label(address(generalAdapter1), "GeneralAdapter1");
    }
}
