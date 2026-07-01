// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {LibClone} from "@solady/utils/LibClone.sol";

import {IPod} from "./interfaces/IPod.sol";

/// @dev rewawrds that are coming to pod will be distributed directly to the users
contract Pod is IPod {
    function owner() public view returns (address) {
        return address(bytes20(LibClone.argsOnClone(address(this), 0, 20)));
    }

    function delegateCall(address target, bytes memory data) external returns (bytes memory response) {
        require(msg.sender == owner(), Unauthorized());
        require(target != address(0), ZeroAddress());

        assembly {
            let succeeded := delegatecall(gas(), target, add(data, 0x20), mload(data), 0, 0)
            let size := returndatasize()

            response := mload(0x40)
            mstore(0x40, add(response, and(add(size, 0x3f), not(0x1f))))
            mstore(response, size)
            returndatacopy(add(response, 0x20), 0, size)

            switch iszero(succeeded)
            case 1 {
                // throw if delegatecall failed
                returndatacopy(response, 0x00, size)
                revert(response, size)
            }
        }
    }
}
