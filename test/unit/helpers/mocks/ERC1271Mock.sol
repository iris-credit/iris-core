// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ECDSA} from "lib/solady/src/utils/ECDSA.sol";

contract ERC1271Mock {
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (ECDSA.tryRecoverCalldata(hash, signature) == owner) {
            return MAGIC_VALUE;
        }
        return 0xffffffff;
    }
}
