// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {Blm} from "../../src/blm/Blm.sol";
import {WhitelistBlm} from "../../src/blm/WhitelistBlm.sol";
import {IBlm} from "../../src/interfaces/IBlm.sol";
import {IWhitelistBlm} from "../../src/interfaces/IWhitelistBlm.sol";

contract BlmTest is UnitTest {
    using MathLib for uint256;

    WhitelistBlm internal whitelistBlm;

    function setUp() public virtual override {
        super.setUp();

        blm = new Blm(address(iris));
        whitelistBlm = new WhitelistBlm(address(iris));
    }

    /* BLM */

    function testConstructor() public {
        // Zero address
        vm.expectRevert(IBlm.ZeroAddress.selector);
        new Blm(address(0));

        // Normal path
        blm = new Blm(address(iris));
        assertEq(address(blm.IRIS()), address(iris));
    }

    function testSetParams(address rdm, address token, uint256 newSlope, uint256 newIntercept) public {
        vm.assume(rdm != owner);
        vm.assume(token != address(0));
        newSlope = bound(newSlope, 1, WAD - 1);
        newIntercept = bound(newIntercept, 0, WAD - 1);

        // Access control
        vm.expectRevert(IBlm.Unauthorized.selector);
        vm.prank(rdm);
        blm.setParams(token, newSlope, newIntercept);

        // Zero address
        vm.expectRevert(IBlm.ZeroAddress.selector);
        vm.prank(owner);
        blm.setParams(address(0), newSlope, newIntercept);

        // Zero slope
        vm.expectRevert(IBlm.ZeroAmount.selector);
        vm.prank(owner);
        blm.setParams(token, 0, newIntercept);

        // Slope too high
        vm.expectRevert(IBlm.ParamsTooHigh.selector);
        vm.prank(owner);
        blm.setParams(token, WAD, newIntercept);

        // Intercept too high
        vm.expectRevert(IBlm.ParamsTooHigh.selector);
        vm.prank(owner);
        blm.setParams(token, newSlope, WAD);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit IBlm.SetParams(token, newSlope, newIntercept);
        blm.setParams(token, newSlope, newIntercept);
        assertEq(blm.slope(token), newSlope);
        assertEq(blm.intercept(token), newIntercept);
    }

    function testBondRequirement(uint256 newSlope, uint256 newIntercept, uint256 debt, uint256 duration) public {
        newSlope = bound(newSlope, 1, WAD - 1);
        newIntercept = bound(newIntercept, 0, WAD - 1);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION);

        Quote memory quote = _quote(solver, debtToken, debt, duration);

        // Params unset
        assertEq(blm.bondRequirement(quote), 0);

        // Params fuzz
        vm.prank(owner);
        blm.setParams(debtToken, newSlope, newIntercept);

        uint256 ratio = newSlope.mulDivDown(duration, 1 days) + newIntercept;
        assertEq(blm.bondRequirement(quote), debt.mulDivDown(ratio, WAD));

        // debt 1000, duration 30 days, slope 100bp, intercept 50bp
        // ratio = 0.01 * (30 days / 1 days) + 0.005 = 0.305
        // bond = 1000 * 0.305 = 305
        quote = _quote(solver, debtToken, 1000e6, 30 days);

        vm.prank(owner);
        blm.setParams(debtToken, 0.01e18, 0.005e18);

        assertEq(blm.bondRequirement(quote), 305e6);
    }

    /* WHITELIST BLM */

    function testWhitelistConstructor() public {
        // Zero address
        vm.expectRevert(IBlm.ZeroAddress.selector);
        new WhitelistBlm(address(0));

        // Normal path
        whitelistBlm = new WhitelistBlm(address(iris));
        assertEq(address(whitelistBlm.IRIS()), address(iris));
    }

    function testWhitelistSetParams(address rdm, address token, uint256 newSlope, uint256 newIntercept) public {
        vm.assume(rdm != owner);
        vm.assume(token != address(0));
        newSlope = bound(newSlope, 1, WAD - 1);
        newIntercept = bound(newIntercept, 0, WAD - 1);

        // Access control
        vm.expectRevert(IBlm.Unauthorized.selector);
        vm.prank(rdm);
        whitelistBlm.setParams(token, newSlope, newIntercept);

        // Zero address
        vm.expectRevert(IBlm.ZeroAddress.selector);
        vm.prank(owner);
        whitelistBlm.setParams(address(0), newSlope, newIntercept);

        // Zero slope
        vm.expectRevert(IBlm.ZeroAmount.selector);
        vm.prank(owner);
        whitelistBlm.setParams(token, 0, newIntercept);

        // Slope too high
        vm.expectRevert(IBlm.ParamsTooHigh.selector);
        vm.prank(owner);
        whitelistBlm.setParams(token, WAD, newIntercept);

        // Intercept too high
        vm.expectRevert(IBlm.ParamsTooHigh.selector);
        vm.prank(owner);
        whitelistBlm.setParams(token, newSlope, WAD);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit IBlm.SetParams(token, newSlope, newIntercept);
        whitelistBlm.setParams(token, newSlope, newIntercept);
        assertEq(whitelistBlm.slope(token), newSlope);
        assertEq(whitelistBlm.intercept(token), newIntercept);
    }

    function testSetIsWhitelisted(address rdm, address account) public {
        vm.assume(rdm != owner);

        // Access control
        vm.expectRevert(IBlm.Unauthorized.selector);
        vm.prank(rdm);
        whitelistBlm.setIsWhitelisted(account, true);

        // Normal path - enable
        vm.prank(owner);
        vm.expectEmit();
        emit IWhitelistBlm.SetIsWhitelisted(account, true);
        whitelistBlm.setIsWhitelisted(account, true);
        assertTrue(whitelistBlm.isWhitelisted(account));

        // Normal path - disable
        vm.prank(owner);
        vm.expectEmit();
        emit IWhitelistBlm.SetIsWhitelisted(account, false);
        whitelistBlm.setIsWhitelisted(account, false);
        assertFalse(whitelistBlm.isWhitelisted(account));
    }

    function testWhitelistBondRequirement(uint256 newSlope, uint256 newIntercept, uint256 debt, uint256 duration)
        public
    {
        newSlope = bound(newSlope, 1, WAD - 1);
        newIntercept = bound(newIntercept, 0, WAD - 1);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        duration = bound(duration, MIN_DURATION, MAX_DURATION);

        Quote memory quote = _quote(solver, debtToken, debt, duration);

        // Unauthorized
        vm.expectRevert(IBlm.Unauthorized.selector);
        whitelistBlm.bondRequirement(quote);

        // Params unset
        vm.prank(owner);
        whitelistBlm.setIsWhitelisted(solver, true);

        assertEq(whitelistBlm.bondRequirement(quote), 0);

        // Params fuzz
        vm.prank(owner);
        whitelistBlm.setParams(debtToken, newSlope, newIntercept);

        uint256 ratio = newSlope.mulDivDown(duration, 1 days) + newIntercept;
        assertEq(whitelistBlm.bondRequirement(quote), debt.mulDivDown(ratio, WAD));

        // debt 1000, duration 30 days, slope 100bp, intercept 50bp
        // ratio = 0.01 * (30 days / 1 days) + 0.005 = 0.305
        // bond = 1000 * 0.305 = 305
        quote = _quote(solver, debtToken, 1000e6, 30 days);

        vm.prank(owner);
        whitelistBlm.setParams(debtToken, 0.01e18, 0.005e18);

        assertEq(whitelistBlm.bondRequirement(quote), 305e6);
    }

    /* HELPERS */

    function _quote(address solver_, address debtToken_, uint256 debt_, uint256 duration_)
        internal
        pure
        returns (Quote memory quote)
    {
        quote.solver = solver_;
        quote.debtToken = debtToken_;
        quote.debt = debt_;
        quote.duration = duration_;
    }
}
