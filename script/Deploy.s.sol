// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";

import {BaseScript} from "./Base.s.sol";

import {Pod} from "../src/Pod.sol";
import {Iris} from "../src/Iris.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {MorphoBlueAdapter} from "../src/adapters/MorphoBlueAdapter.sol";
import {Blm} from "../src/blm/Blm.sol";
import {WhitelistBlm} from "../src/blm/WhitelistBlm.sol";

/// @dev Deploys the protocol. Idempotent: only contracts missing from the address book are
/// deployed, so re-running fills gaps. Iris is owned by the deployer at genesis; hand off to
/// the timelock afterwards with `SetConfig --sig transferOwnership()`.
contract Deploy is BaseScript {
    using stdJson for string;

    function run() public {
        address podImpl = load("PodImpl");
        if (podImpl == address(0)) {
            vm.broadcast(broadcaster);
            podImpl = address(new Pod());
            save("PodImpl", podImpl);
        }

        address iris = load("Iris");
        if (iris == address(0)) {
            vm.broadcast(broadcaster);
            iris = address(new Iris(broadcaster, podImpl));
            save("Iris", iris);
        }

        if (load("AaveV3Adapter") == address(0)) {
            vm.broadcast(broadcaster);
            save("AaveV3Adapter", address(new AaveV3Adapter(config.readAddress(".venues.aaveV3.address"))));
        }

        if (load("MorphoBlueAdapter") == address(0)) {
            vm.broadcast(broadcaster);
            save("MorphoBlueAdapter", address(new MorphoBlueAdapter(config.readAddress(".venues.morphoBlue.address"))));
        }

        if (load("Blm") == address(0)) {
            vm.broadcast(broadcaster);
            save("Blm", address(new Blm(iris)));
        }

        if (load("WhitelistBlm") == address(0)) {
            vm.broadcast(broadcaster);
            save("WhitelistBlm", address(new WhitelistBlm(iris)));
        }
    }
}
