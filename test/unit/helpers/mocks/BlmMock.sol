// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IIris, Quote} from "../../../../src/interfaces/IIris.sol";
import {IBlm} from "../../../../src/interfaces/IBlm.sol";

contract BlmMock is IBlm {
    IIris public IRIS;
    uint256 _bondRequirement;

    constructor(IIris _iris) {
        IRIS = _iris;
    }

    function setBondRequirement(uint256 __bondRequirement) external {
        _bondRequirement = __bondRequirement;
    }

    function bondRequirement(Quote calldata) external view returns (uint256) {
        return _bondRequirement;
    }

    function slope(address) external pure returns (uint256) {
        return 0;
    }

    function intercept(address) external pure returns (uint256) {
        return 0;
    }

    function setParams(address, uint256, uint256) external {}
}
