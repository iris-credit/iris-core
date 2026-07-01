// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {ERC1271Mock} from "./helpers/mocks/ERC1271Mock.sol";

contract AuthorizationUnitTest is UnitTest {
    function testSetAuthorization(address rdm) public {
        vm.assume(rdm != address(this));

        iris.setAuthorization(rdm, true);
        assertTrue(iris.isAuthorized(address(this), rdm));

        iris.setAuthorization(rdm, false);
        assertFalse(iris.isAuthorized(address(this), rdm));
    }

    function testRevertSetAuthorizationAlreadySet(address rdm) public {
        vm.expectRevert(IIris.AlreadySet.selector);
        iris.setAuthorization(rdm, false);

        iris.setAuthorization(rdm, true);

        vm.expectRevert(IIris.AlreadySet.selector);
        iris.setAuthorization(rdm, true);
    }

    // WITH SIGNATURE

    function testAuthorizationWithSig(Authorization memory authorization, uint256 privateKey) public {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        // Private key must be less than the secp256k1 curve order.
        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;
        authorization.authorizer = vm.addr(privateKey);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        iris.setAuthorizationWithSig(authorization, signature);

        assertTrue(iris.isAuthorized(authorization.authorizer, authorization.authorized));
        assertTrue(iris.isNonceUsed(authorization.authorizer, authorization.nonce));
    }

    function testRevertSetAuthorizationWithSig_DeadlineOutdated(
        Authorization memory authorization,
        uint256 privateKey,
        uint256 blocks
    ) public {
        authorization.isAuthorized = true;
        blocks = _boundBlocks(blocks);
        authorization.deadline = block.timestamp - 1;

        // Private key must be less than the secp256k1 curve order.
        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;
        authorization.authorizer = vm.addr(privateKey);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        _forward(blocks);

        vm.expectRevert(IIris.SignatureExpired.selector);
        iris.setAuthorizationWithSig(authorization, signature);
    }

    function testRevertSetAuthorizationWithSig_WrongPK(Authorization memory authorization, uint256 privateKey) public {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        // Private key must be less than the secp256k1 curve order.
        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IIris.InvalidSignature.selector);
        iris.setAuthorizationWithSig(authorization, signature);
    }

    function testRevertSetAuthorizationWithSig_ReusedSig(Authorization memory authorization, uint256 privateKey)
        public
    {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        // Private key must be less than the secp256k1 curve order.
        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;
        authorization.authorizer = vm.addr(privateKey);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        iris.setAuthorizationWithSig(authorization, signature);

        authorization.isAuthorized = false;
        vm.expectRevert(IIris.InvalidNonce.selector);
        iris.setAuthorizationWithSig(authorization, signature);
    }

    // ERC1271

    function testSetAuthorizationWithSig_ERC1271(Authorization memory authorization, uint256 privateKey) public {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        // Private key must be less than the secp256k1 curve order.
        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;

        ERC1271Mock wallet = new ERC1271Mock(vm.addr(privateKey));
        authorization.authorizer = address(wallet);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        iris.setAuthorizationWithSig(authorization, signature);

        assertTrue(iris.isAuthorized(authorization.authorizer, authorization.authorized));
        assertTrue(iris.isNonceUsed(authorization.authorizer, authorization.nonce));
    }

    function testRevertSetAuthorizationWithSig_ERC1271_WrongMagic(
        Authorization memory authorization,
        uint256 privateKey,
        uint256 wrongKey
    ) public {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        // Private keys must be less than the secp256k1 curve order, and distinct so the wallet rejects.
        privateKey = bound(privateKey, 1, type(uint32).max);
        wrongKey = bound(wrongKey, 1, type(uint32).max);
        vm.assume(privateKey != wrongKey);
        authorization.nonce = 0;

        ERC1271Mock wallet = new ERC1271Mock(vm.addr(privateKey));
        authorization.authorizer = address(wallet);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(IIris.InvalidSignature.selector);
        iris.setAuthorizationWithSig(authorization, signature);
    }

    function testRevertSetAuthorizationWithSig_ERC1271_ReusedSig(Authorization memory authorization, uint256 privateKey)
        public
    {
        authorization.isAuthorized = true;
        authorization.deadline = bound(authorization.deadline, block.timestamp, type(uint256).max);

        privateKey = bound(privateKey, 1, type(uint32).max);
        authorization.nonce = 0;

        ERC1271Mock wallet = new ERC1271Mock(vm.addr(privateKey));
        authorization.authorizer = address(wallet);

        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), authorization);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        iris.setAuthorizationWithSig(authorization, signature);

        authorization.isAuthorized = false;
        vm.expectRevert(IIris.InvalidNonce.selector);
        iris.setAuthorizationWithSig(authorization, signature);
    }
}
