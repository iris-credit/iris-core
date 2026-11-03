// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @dev Governance layout for the TimelockController that owns Iris. Single source for the deploy
/// script, the ownership handoff check, and the tests, so what the tests prove is what gets deployed.
///
/// Iris keeps its plain `owner` check and the BLMs check `IRIS.owner()`, so making the timelock the
/// owner puts all ten owner functions (Iris: setOwner, setFee, setFeeRecipient, setVenueAdapter,
/// enableBlm, enableBondLltv, enableData; Blm/WhitelistBlm: setParams; WhitelistBlm: setIsWhitelisted)
/// behind one `minDelay`.
///
/// Roles (OZ TimelockController):
/// - PROPOSER: the team Safe. Schedules operations, and also gets CANCELLER from the constructor.
/// - EXECUTOR: runs an operation once its delay has passed. `address(0)` in `executors` opens the
///   role to anyone, so the Safe signs only the schedule and a bot or any EOA executes.
/// - DEFAULT_ADMIN: the timelock itself only. The constructor's optional admin is always
///   `address(0)`: an external admin could grant roles with no delay and bypass the timelock. Every
///   role change and every `updateDelay` is therefore a timelocked self-call that waits `minDelay`.
///
/// A ready operation never expires: it stays executable until executed or cancelled, so cancel
/// anything that should not land.
library IrisTimelock {
    struct Governance {
        address proposer;
        address[] executors;
        uint256 minDelay;
    }

    function validate(Governance memory g, address deployer) internal pure {
        require(g.proposer != address(0), "governance: proposer unset");
        require(g.proposer != deployer, "governance: proposer must not be the deployer");
        require(g.executors.length != 0, "governance: no executor (use address(0) for anyone)");
        require(g.minDelay != 0, "governance: minDelay is zero");
    }

    /// @dev One transaction: the constructor grants every role, and no external admin is set.
    function deploy(Governance memory g, address deployer) internal returns (TimelockController) {
        validate(g, deployer);
        address[] memory proposers = new address[](1);
        proposers[0] = g.proposer;
        return new TimelockController(g.minDelay, proposers, g.executors, address(0));
    }

    /// @dev Reverts unless the timelock matches `g`. OZ's AccessControl does not enumerate members,
    /// so this proves the expected grants exist and `deployer` holds none, not that no other account
    /// was ever granted a role.
    function check(TimelockController timelock, Governance memory g, address deployer) internal view {
        validate(g, deployer);

        require(timelock.getMinDelay() == g.minDelay, "governance: minDelay mismatch");
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), g.proposer), "governance: proposer missing");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), g.proposer), "governance: proposer cannot cancel");
        for (uint256 i; i < g.executors.length; i++) {
            require(timelock.hasRole(timelock.EXECUTOR_ROLE(), g.executors[i]), "governance: executor missing");
        }

        bytes32 adminRole = timelock.DEFAULT_ADMIN_ROLE();
        require(timelock.hasRole(adminRole, address(timelock)), "governance: timelock is not self-administered");
        require(!timelock.hasRole(adminRole, deployer), "governance: deployer holds admin");
        require(!timelock.hasRole(timelock.PROPOSER_ROLE(), deployer), "governance: deployer can propose");
        require(!timelock.hasRole(timelock.CANCELLER_ROLE(), deployer), "governance: deployer can cancel");
    }
}
