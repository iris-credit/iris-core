// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {IIris} from "../src/interfaces/IIris.sol";

/// @dev Shared base for every Iris script.
/// - loads `config/<chain>.json` into `config` (subclasses read fields inline with stdJson)
/// - `save`/`load` the deployed address book at `deployments/<chainId>.json`
/// - `ownerExec` broadcasts an owner call when the caller IS the owner, otherwise prints the
///   calldata for the timelock to queue. Same script works before and after the handoff.
abstract contract BaseScript is Script {
    using stdJson for string;

    string internal config;
    address internal broadcaster;
    address internal iris; // protocol address; set by scripts that perform owner ops, read by ownerExec

    function setUp() public virtual {
        config = vm.readFile(string.concat(vm.projectRoot(), "/config/", _chain(), ".json"));
        broadcaster = _broadcaster();
    }

    function _chain() internal view returns (string memory) {
        if (block.chainid == 1 || block.chainid == 31337) return "ethereum";
        revert(string.concat("no config for chainid ", vm.toString(block.chainid)));
    }

    /// @dev Ledger first: when USE_LEDGER is set, sign as ETH_FROM and ignore PRIVATE_KEY. Otherwise derive
    /// from PRIVATE_KEY: a `0x` + 64-hex key is used directly, a bare 64-hex key is 0x-prefixed first (forge
    /// accepts both), and an empty/unset value falls back to ETH_FROM (unlocked sender). Any other non-empty
    /// value reverts, so the broadcaster can never silently disagree with the key forge actually signs with.
    function _broadcaster() internal view returns (address) {
        if (vm.envOr("USE_LEDGER", false)) return vm.envAddress("ETH_FROM");
        string memory pk = vm.envOr("PRIVATE_KEY", string(""));
        if (bytes(pk).length == 0) return vm.envAddress("ETH_FROM"); // no key set: unlocked / ledger sender
        if (bytes(pk).length == 64) pk = string.concat("0x", pk); // tolerate a bare 64-hex key
        require(bytes(pk).length == 66, "PRIVATE_KEY must be 0x + 64 hex, or set USE_LEDGER=true");
        return vm.addr(uint256(vm.parseBytes32(pk)));
    }

    /// @dev Merge-write `name => addr` into deployments/<chainId>.json, preserving existing keys.
    function save(string memory name, address addr) internal {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        if (vm.exists(path)) vm.serializeJson("book", vm.readFile(path));
        vm.writeJson(vm.serializeAddress("book", name, addr), path);
        console.log("saved %s = %s", name, addr);
    }

    /// @dev Returns address(0) when the file or key is absent (the idempotency signal).
    function load(string memory name) internal view returns (address) {
        string memory path = string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json");
        if (!vm.exists(path)) return address(0);
        string memory json = vm.readFile(path);
        string memory key = string.concat(".", name);
        if (!vm.keyExistsJson(json, key)) return address(0);
        return json.readAddress(key);
    }

    /// @dev Run an owner-gated call to `target` (the Iris protocol, or a BLM that is gated by Iris's
    /// owner). Broadcasts when the caller is the protocol owner, else prints the calldata for the timelock.
    function ownerExec(address target, bytes memory data) internal {
        address owner = IIris(iris).owner();
        if (owner == broadcaster) {
            vm.broadcast(broadcaster);
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            console.log("broadcast owner call to %s", target);
        } else {
            console.log("owner is timelock %s - queue this call:", owner);
            console.log("  to:   %s", target);
            console.log("  data:");
            console.logBytes(data);
        }
    }
}
