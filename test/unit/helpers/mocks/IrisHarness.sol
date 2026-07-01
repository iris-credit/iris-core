// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Iris} from "../../../../src/Iris.sol";

/// @dev Test-only harness exposing internal Iris hooks so they can be unit-tested directly, without
/// routing through a state-changing entrypoint. Adds no storage, so the layout (and StorageUtils)
/// stays identical to Iris.
contract IrisHarness is Iris {
    constructor(address newOwner, address podImpl) Iris(newOwner, podImpl) {}

    function accrueLegs(address pod) external {
        _accrueLegs(_loan[pod], _position[pod], pod);
    }

    function settleLegs(address pod) external {
        _settleLegs(_loan[pod], _position[pod]);
    }
}
