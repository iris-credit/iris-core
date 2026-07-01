// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {CommonBase} from "forge-std/Base.sol";
import {MarketParams, Id} from "@morpho-blue/interfaces/IMorpho.sol";
import {stdJson} from "forge-std/StdJson.sol";

// NetworkConfig loads config data at construction time.
// This makes config data available to inheriting test contracts when they are constructed.
// But `block.chainid` is not preserved between the constructor and the call to `setUp`. So we store the planned chainid
// in the config to have it available.
struct Config {
    string network;
    uint256 chainid;
    uint256 blockNumber;
    mapping(string name => address) addresses;
    mapping(string name => Id) morphoMarketIds;
    Id[] morphoMarketIdList;
}

abstract contract NetworkConfig is CommonBase {
    using stdJson for string;

    function initializeConfigData() private {
        /* ETHEREUM NETWORK */
        if (config.chainid == 1) {
            config.network = "ethereum";
            config.blockNumber = 25322057;

            string memory json = vm.readFile(string.concat(vm.projectRoot(), "/config/ethereum.json"));

            setAddress("USDC", json.readAddress(".tokens.USDC"));
            setAddress("USDT", json.readAddress(".tokens.USDT"));
            setAddress("WBTC", json.readAddress(".tokens.WBTC"));
            setAddress("cbBTC", json.readAddress(".tokens.cbBTC"));
            setAddress("WETH", json.readAddress(".tokens.WETH"));
            setAddress("stETH", json.readAddress(".tokens.stETH"));
            setAddress("wstETH", json.readAddress(".tokens.wstETH"));
            setAddress("aaveV3Pool", json.readAddress(".venues.aaveV3.address"));
            setAddress("morphoBlue", json.readAddress(".venues.morphoBlue.address"));

            // forgefmt: disable-start
            setMorphoMarketId("cbBTC/USDC", Id.wrap(json.readBytes32(".venues.morphoBlue.markets[\"cbBTC/USDC\"]")));
            setMorphoMarketId("wstETH/USDT", Id.wrap(json.readBytes32(".venues.morphoBlue.markets[\"wstETH/USDT\"]")));
            setMorphoMarketId("WBTC/USDC", Id.wrap(json.readBytes32(".venues.morphoBlue.markets[\"WBTC/USDC\"]")));
            // forgefmt: disable-end
        }
    }

    address public constant UNINITIALIZED_ADDRESS = address(bytes20(bytes32("UNINITIALIZED ADDRESS")));

    Config internal config;

    // Load known addresses before tests try to use them when initializing their state variables.
    bool private initialized = initializeConfig();

    function initializeConfig() internal virtual returns (bool) {
        require(!initialized, "Configured: already initialized");

        vm.label(UNINITIALIZED_ADDRESS, "UNINITIALIZED_ADDRESS");

        // Run tests on Ethereum by default
        if (block.chainid == 31337) {
            config.chainid = 1;
        } else {
            config.chainid = block.chainid;
        }

        initializeConfigData();

        require(
            bytes(config.network).length > 0,
            string.concat("Configured: unknown chain id ", vm.toString(config.chainid))
        );
        return true;
    }

    function getAddress(string memory name) internal view returns (address addr) {
        addr = config.addresses[name];
        return addr == address(0) ? UNINITIALIZED_ADDRESS : addr;
    }

    function hasAddress(string memory name) internal view returns (bool) {
        return config.addresses[name] != address(0);
    }

    function setAddress(string memory name, address addr) internal {
        require(addr != address(0), "NetworkConfig: cannot set address 0");
        config.addresses[name] = addr;
        vm.label(addr, name);
    }

    function getMorphoMarketId(string memory name) internal view returns (Id) {
        return config.morphoMarketIds[name];
    }

    function hasMorphoMarketId(string memory name) internal view returns (bool) {
        return !isEq(config.morphoMarketIds[name], Id.wrap(bytes32(0)));
    }

    function setMorphoMarketId(string memory name, Id id) internal {
        require(!isEq(id, Id.wrap(bytes32(0))), "NetworkConfig: cannot set market id 0");
        config.morphoMarketIdList.push(id);
        config.morphoMarketIds[name] = id;
    }

    /// @dev Equality for `Id` (a user-defined value type, so it has no built-in `==`).
    function isEq(Id a, Id b) internal pure returns (bool) {
        return Id.unwrap(a) == Id.unwrap(b);
    }
}
