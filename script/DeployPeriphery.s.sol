// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./Base.s.sol";

import {Bundler3} from "../src/periphery/Bundler3.sol";
import {GeneralAdapter1} from "../src/periphery/adapters/GeneralAdapter1.sol";
import {EthereumGeneralAdapter1} from "../src/periphery/adapters/EthereumGeneralAdapter1.sol";

/// @dev Deploys the periphery (Bundler3 + the chain's general adapter). No Iris owner op is involved:
/// the periphery is permissionless, so this script exists for constructor wiring and book bookkeeping.
/// Idempotent with binding awareness: Bundler3 is deployed only when absent from the book; the adapter
/// is redeployed whenever its immutable IRIS or BUNDLER3 binding no longer matches the book, since an
/// Iris redeploy leaves the previous adapter pointing at the dead core.
contract DeployPeriphery is BaseScript {
    using stdJson for string;

    function run() public {
        iris = load("Iris");
        require(iris != address(0), "Iris not deployed");

        address bundler3 = load("Bundler3");
        if (bundler3 == address(0)) {
            vm.broadcast(broadcaster);
            bundler3 = address(new Bundler3());
            save("Bundler3", bundler3);
        } else {
            console.log("Bundler3 already at %s - skipped", bundler3);
        }

        address adapter = load("EthereumGeneralAdapter1");
        bool fresh = adapter != address(0) && adapter.code.length != 0
            && address(GeneralAdapter1(payable(adapter)).IRIS()) == iris
            && GeneralAdapter1(payable(adapter)).BUNDLER3() == bundler3;

        if (fresh) {
            console.log("EthereumGeneralAdapter1 already at %s - skipped", adapter);
        } else {
            if (adapter != address(0)) console.log("EthereumGeneralAdapter1 bindings stale - redeploying");
            vm.broadcast(broadcaster);
            adapter = address(
                new EthereumGeneralAdapter1(
                    bundler3,
                    config.readAddress(".venues.morphoBlue.address"),
                    config.readAddress(".tokens.WETH"),
                    config.readAddress(".tokens.wstETH"),
                    iris
                )
            );
            save("EthereumGeneralAdapter1", adapter);
        }

        _printState(adapter);
    }

    /// @dev Read back every binding of the deployed adapter, as a post-run sanity check.
    function _printState(address adapter) internal view {
        GeneralAdapter1 general = GeneralAdapter1(payable(adapter));
        EthereumGeneralAdapter1 ethereum_ = EthereumGeneralAdapter1(payable(adapter));

        console.log("--- verification (read back from %s) ---", adapter);
        console.log("BUNDLER3:       %s", general.BUNDLER3());
        console.log("IRIS:           %s", address(general.IRIS()));
        console.log("MORPHO:         %s", address(general.MORPHO()));
        console.log("WRAPPED_NATIVE: %s", address(general.WRAPPED_NATIVE()));
        console.log("ST_ETH:         %s", ethereum_.ST_ETH());
        console.log("WST_ETH:        %s", ethereum_.WST_ETH());
    }
}
