// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IPod {
    error Unauthorized();
    error ZeroAddress();

    function owner() external view returns (address);
    function delegateCall(address target, bytes memory data) external returns (bytes memory response);
}
