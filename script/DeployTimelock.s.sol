// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {BaseScript} from "./Base.s.sol";
import {IrisTimelock} from "./IrisTimelock.sol";

/// @dev Deploys the TimelockController that becomes Iris's owner, per `IrisTimelock` from
/// `config.governance`, in one transaction with no external admin. Idempotent: a Timelock already in
/// the address book is only re-checked. Does not hand off ownership: that is
/// `SetConfig --sig transferOwnership()`, run after this.
contract DeployTimelock is BaseScript {
    function run() public {
        IrisTimelock.Governance memory governance = _governance();

        address timelock = load("Timelock");
        if (timelock == address(0)) {
            vm.broadcast(broadcaster);
            timelock = address(IrisTimelock.deploy(governance, broadcaster));
            save("Timelock", timelock);
        }

        IrisTimelock.check(TimelockController(payable(timelock)), governance, broadcaster);
        console.log("Timelock %s matches config.governance", timelock);
        console.log("next: SetConfig --sig transferOwnership() hands Iris to it");
    }
}
