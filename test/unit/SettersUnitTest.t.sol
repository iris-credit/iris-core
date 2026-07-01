// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";

contract SettersUnitTest is UnitTest {
    function testSetOwner(address rdm) public {
        vm.assume(rdm != owner);
        address newOwner = makeAddr("newOwner");

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.setOwner(newOwner);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.SetOwner(newOwner);
        iris.setOwner(newOwner);
        assertEq(iris.owner(), newOwner);
    }

    function testSetFee(address rdm, uint256 newFee) public {
        vm.assume(rdm != owner);
        newFee = bound(newFee, 0, MAX_FEE / BP) * BP; // Max fee is 0.4e18 (40%), must be a multiple of BP

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.setFee(newFee);

        // Max fee exceeded
        vm.expectRevert(IIris.FeeTooHigh.selector);
        vm.prank(owner);
        iris.setFee(MAX_FEE + 1);

        // Not multiple of bp
        vm.expectRevert(IIris.NotMultipleOfBp.selector);
        vm.prank(owner);
        iris.setFee(BP + 1);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.SetFee(newFee);
        iris.setFee(newFee);
        assertEq(iris.fee(), newFee / BP);
    }

    function testSetFeeRecipient(address rdm) public {
        vm.assume(rdm != owner);
        address newFeeRecipient = makeAddr("newFeeRecipient");

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.setFeeRecipient(newFeeRecipient);

        // Zero address
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(owner);
        iris.setFeeRecipient(address(0));

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.SetFeeRecipient(newFeeRecipient);
        iris.setFeeRecipient(newFeeRecipient);
        assertEq(iris.feeRecipient(), newFeeRecipient);
    }

    function testSetVenueAdapter(address rdm, uint8 venueId, address newAdapter) public {
        vm.assume(rdm != owner);
        venueId = uint8(bound(venueId, 0, 127)); // valid venue ids are < 128
        newAdapter = makeAddr("newAdapter");

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.setVenueAdapter(venueId, newAdapter);

        // Zero address
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(owner);
        iris.setVenueAdapter(venueId, address(0));

        // Max venue id exceeded
        vm.expectRevert(IIris.VenueIdTooHigh.selector);
        vm.prank(owner);
        iris.setVenueAdapter(type(uint8).max, newAdapter);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.SetVenueAdapter(venueId, newAdapter);
        iris.setVenueAdapter(venueId, newAdapter);
        assertEq(iris.venueAdapter(venueId), newAdapter);
    }

    function testEnableBlm(address rdm, address _blm) public {
        vm.assume(rdm != owner);
        vm.assume(_blm != address(blm));

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.enableBlm(_blm);

        // Already enabled
        vm.expectRevert(IIris.AlreadySet.selector);
        vm.prank(owner);
        iris.enableBlm(address(blm));

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.EnableBlm(_blm);
        iris.enableBlm(_blm);
        assertTrue(iris.isBlmEnabled(_blm));
    }

    function testEnableBondLltv(address rdm, uint256 _bondLltv) public {
        vm.assume(rdm != owner);
        _bondLltv = bound(_bondLltv, 0, WAD / BP - 1) * BP;
        vm.assume(_bondLltv != bondLltv);

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.enableBondLltv(_bondLltv);

        // Already enabled
        vm.expectRevert(IIris.AlreadySet.selector);
        vm.prank(owner);
        iris.enableBondLltv(bondLltv);

        // Max bond lltv exceeded
        vm.expectRevert(IIris.BondLltvTooHigh.selector);
        vm.prank(owner);
        iris.enableBondLltv(WAD);

        // Not multiple of bp
        vm.expectRevert(IIris.NotMultipleOfBp.selector);
        vm.prank(owner);
        iris.enableBondLltv(BP + 1);

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.EnableBondLltv(_bondLltv);
        iris.enableBondLltv(_bondLltv);
        assertTrue(iris.isBondLltvEnabled(_bondLltv));
    }

    function testEnableData(address rdm, bytes32 data) public {
        vm.assume(rdm != owner);
        vm.assume(data != keccak256(""));

        // Access control
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(rdm);
        iris.enableData(data);

        // Already enabled
        vm.expectRevert(IIris.AlreadySet.selector);
        vm.prank(owner);
        iris.enableData(keccak256(""));

        // Normal path
        vm.prank(owner);
        vm.expectEmit();
        emit EventsLib.EnableData(data);
        iris.enableData(data);
        assertTrue(iris.isDataEnabled(data));
    }
}
