// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";

import {IPool} from "@aave/contracts/interfaces/IPool.sol";

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

        address aaveV3Pool = config.readAddress(".venues.aaveV3.address");
        if (load("AaveV3Adapter") == address(0)) {
            vm.broadcast(broadcaster);
            save("AaveV3Adapter", address(new AaveV3Adapter(aaveV3Pool)));
        }
        _checkAaveV3Adapter("AaveV3Adapter", aaveV3Pool);

        if (load("MorphoBlueAdapter") == address(0)) {
            vm.broadcast(broadcaster);
            save("MorphoBlueAdapter", address(new MorphoBlueAdapter(config.readAddress(".venues.morphoBlue.address"))));
        }

        // SparkLend runs an Aave V3.0 core fork that the same adapter serves. It gets its own book key, which
        // config.venues.sparkLend.adapter names, so its venue can never resolve to the Aave V3 adapter.
        address sparkLendPool = config.readAddress(".venues.sparkLend.address");
        if (load("SparkLendAdapter") == address(0)) {
            vm.broadcast(broadcaster);
            save("SparkLendAdapter", address(new AaveV3Adapter(sparkLendPool)));
        }
        _checkAaveV3Adapter("SparkLendAdapter", sparkLendPool);

        if (load("Blm") == address(0)) {
            vm.broadcast(broadcaster);
            save("Blm", address(new Blm(iris)));
        }

        if (load("WhitelistBlm") == address(0)) {
            vm.broadcast(broadcaster);
            save("WhitelistBlm", address(new WhitelistBlm(iris)));
        }
    }

    /// @dev The book's Aave V3 family adapter must wrap the pool config names, and that pool must be the one its own
    /// addresses provider registers. A wrong address only makes every take revert, but another live pool (Aave's in
    /// place of SparkLend's) would be served without an error.
    function _checkAaveV3Adapter(string memory name, address pool) internal view {
        require(address(AaveV3Adapter(load(name)).POOL()) == pool, string.concat(name, " wraps another pool"));
        require(
            IPool(pool).ADDRESSES_PROVIDER().getPool() == pool,
            string.concat(name, ": config pool is not its addresses provider's pool")
        );
    }
}
