// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

import {BaseScript} from "./Base.s.sol";

import {Iris} from "../src/Iris.sol";
import {IIris} from "../src/interfaces/IIris.sol";
import {BP} from "../src/libraries/ConstantsLib.sol";

/// @dev One-shot Iris redeploy + full setup, reusing every other contract already in the address
/// book (PodImpl, adapters, BLM) — this script never deploys them. Idempotent: Iris is only deployed
/// when absent from the book and every config step no-ops when its state is already set, so
/// re-running after a partial failure just fills the gaps.
/// Env (scriptMaster extracts these from config/<chain>.json): VENUE_IDS and ADAPTERS
/// (comma-separated, aligned; adapters are deployment names), MARKET_DATA (comma-separated final
/// quote-data hashes, i.e. enableData inputs), BOND_LLTV (wad), BLM (deployment name),
/// FEE_RECIPIENT (address), FEE (wad).
contract RedeployIris is BaseScript {
    function run() public {
        address podImpl = load("PodImpl");
        require(podImpl != address(0), "PodImpl not deployed");

        // 1. Iris itself (same idempotent shape as Deploy.s.sol).
        iris = load("Iris");
        if (iris == address(0)) {
            vm.broadcast(broadcaster);
            iris = address(new Iris(broadcaster, podImpl));
            save("Iris", iris);
        } else {
            console.log("Iris already at %s - configuring only", iris);
        }

        // 2. Venues, wired to their already-deployed adapters.
        uint256[] memory venueIds = vm.envUint("VENUE_IDS", ",");
        string[] memory adapters = vm.envString("ADAPTERS", ",");
        require(venueIds.length == adapters.length, "VENUE_IDS/ADAPTERS length mismatch");
        for (uint256 i; i < venueIds.length; i++) {
            address adapter = load(adapters[i]);
            require(adapter != address(0), string.concat(adapters[i], " not deployed"));
            if (IIris(iris).venueAdapter(venueIds[i]) == adapter) {
                console.log("venue %s already -> %s, skipped", venueIds[i], adapters[i]);
            } else {
                ownerExec(iris, abi.encodeCall(IIris.setVenueAdapter, (venueIds[i], adapter)));
            }
        }

        // 3. Markets (each value is already the final enableData input).
        bytes32[] memory marketData = vm.envBytes32("MARKET_DATA", ",");
        for (uint256 i; i < marketData.length; i++) {
            if (IIris(iris).isDataEnabled(marketData[i])) {
                console.log("market data %s already enabled, skipped", vm.toString(marketData[i]));
            } else {
                ownerExec(iris, abi.encodeCall(IIris.enableData, (marketData[i])));
            }
        }

        // 4. Bond LLTV.
        uint256 bondLltv = vm.envUint("BOND_LLTV");
        if (IIris(iris).isBondLltvEnabled(bondLltv)) {
            console.log("bond lltv %s already enabled, skipped", bondLltv);
        } else {
            ownerExec(iris, abi.encodeCall(IIris.enableBondLltv, (bondLltv)));
        }

        // 5. BLM (reused; its params live on the BLM itself and carry over).
        address blm = load(vm.envString("BLM"));
        require(blm != address(0), "blm not deployed");
        if (IIris(iris).isBlmEnabled(blm)) {
            console.log("blm %s already enabled, skipped", blm);
        } else {
            ownerExec(iris, abi.encodeCall(IIris.enableBlm, (blm)));
        }

        // 6. Fee recipient before fee (a non-zero fee without a recipient would burn fees).
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        require(feeRecipient != address(0), "feeRecipient zero");
        if (IIris(iris).feeRecipient() == feeRecipient) {
            console.log("feeRecipient already %s, skipped", feeRecipient);
        } else {
            ownerExec(iris, abi.encodeCall(IIris.setFeeRecipient, (feeRecipient)));
        }

        uint256 fee = vm.envUint("FEE");
        if (uint256(IIris(iris).fee()) * BP == fee) {
            console.log("fee already %s, skipped", fee);
        } else {
            ownerExec(iris, abi.encodeCall(IIris.setFee, (fee)));
        }

        _printState(venueIds, marketData, bondLltv, blm);
    }

    /// @dev Read back everything this script is responsible for, as a post-run sanity check.
    function _printState(uint256[] memory venueIds, bytes32[] memory marketData, uint256 bondLltv, address blm)
        internal
        view
    {
        console.log("--- verification (read back from %s) ---", iris);
        console.log("owner:        %s", IIris(iris).owner());
        for (uint256 i; i < venueIds.length; i++) {
            console.log("venueAdapter(%s): %s", venueIds[i], IIris(iris).venueAdapter(venueIds[i]));
        }
        for (uint256 i; i < marketData.length; i++) {
            console.log(
                "isDataEnabled(%s): %s",
                vm.toString(marketData[i]),
                IIris(iris).isDataEnabled(marketData[i]) ? "true" : "false"
            );
        }
        console.log("isBondLltvEnabled(%s): %s", bondLltv, IIris(iris).isBondLltvEnabled(bondLltv) ? "true" : "false");
        console.log("isBlmEnabled(%s): %s", blm, IIris(iris).isBlmEnabled(blm) ? "true" : "false");
        console.log("feeRecipient: %s", IIris(iris).feeRecipient());
        console.log("fee (wad):    %s", uint256(IIris(iris).fee()) * BP);
    }
}
