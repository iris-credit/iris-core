// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

contract GettersUnitTest is UnitTest {
    function testDomainSeparator(uint64 chainId) public {
        vm.chainId(chainId);
        assertEq(iris.DOMAIN_SEPARATOR(), computeDomainSeparator(DOMAIN_TYPEHASH, block.chainid, address(iris)));
    }

    function computeDomainSeparator(bytes32 domainTypehash, uint256 chainId, address account)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(domainTypehash, chainId, account));
    }
}
