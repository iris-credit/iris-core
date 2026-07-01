// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {IIris, Quote} from "./IIris.sol";

interface IBlm {
    // Events
    event SetParams(address token, uint256 newSlope, uint256 newIntercept);

    // Errors
    error ParamsTooHigh();
    error Unauthorized();
    error ZeroAddress();
    error ZeroAmount();

    // Immutables
    function IRIS() external view returns (IIris);

    // Functions
    function slope(address token) external view returns (uint256);
    function intercept(address token) external view returns (uint256);
    /// @dev A linear function scaled by debt: A(mx + b) = debt * (duration * slope + intercept).
    function bondRequirement(Quote calldata quote) external view returns (uint256 bondRequirement);
    function setParams(address token, uint256 newSlope, uint256 newIntercept) external;
}
