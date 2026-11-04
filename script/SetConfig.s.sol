// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {BaseScript} from "./Base.s.sol";
import {IrisTimelock} from "./IrisTimelock.sol";
import {Iris} from "../src/Iris.sol";
import {IIris} from "../src/interfaces/IIris.sol";
import {IBlm} from "../src/interfaces/IBlm.sol";
import {BP} from "../src/libraries/ConstantsLib.sol";

/// @dev Every owner governance op, one entrypoint each (select with `forge script --sig`).
/// All route through `ownerExec`, so they broadcast pre-handoff and print Timelock calldata after.
/// Single ops take their values from env (the menu prompts for them); scriptMaster records owner/fee/
/// feeRecipient back into config/<chain>.json on production runs. The launch set is read from config
/// instead: applyLaunchConfig sets it and checkLaunchConfig verifies it before the handoff.
contract SetConfig is BaseScript {
    using stdJson for string;

    function setUp() public override {
        super.setUp();
        iris = load("Iris");
        require(iris != address(0), "Iris not deployed");
    }

    /// @dev Env: VENUE_ID (0-127), ADAPTER (deployment name, e.g. "AaveV3Adapter").
    function addVenue() public {
        address adapter = load(vm.envString("ADAPTER"));
        require(adapter != address(0), "adapter not deployed");
        ownerExec(iris, abi.encodeCall(IIris.setVenueAdapter, (vm.envUint("VENUE_ID"), adapter)));
    }

    /// @dev Env: MARKET = the venue's raw market identifier from config.venues.<v>.markets.<name>.
    /// Iris enables keccak256(quote.data): an empty identifier (Aave-style venues that ignore data) is
    /// hashed here to keccak256(""); a non-empty one is a Morpho-style market id that already equals
    /// keccak256(quote.data) and is enabled directly. Any future venue fits one of these two cases.
    /// Assumption: a non-empty value MUST already be keccak256(quote.data); storing a raw, unhashed
    /// identifier in config would enable the wrong market.
    function enableMarket() public {
        string memory market = vm.envOr("MARKET", string(""));
        bytes32 data = bytes(market).length == 0 ? keccak256("") : vm.parseBytes32(market);
        ownerExec(iris, abi.encodeCall(IIris.enableData, (data)));
    }

    /// @dev Env: BOND_LLTV (wad, multiple of BP).
    function enableBondLltv() public {
        ownerExec(iris, abi.encodeCall(IIris.enableBondLltv, (vm.envUint("BOND_LLTV"))));
    }

    /// @dev Env: BLM (deployment name, "Blm" or "WhitelistBlm").
    function enableBlm() public {
        address blm = load(vm.envString("BLM"));
        require(blm != address(0), "blm not deployed");
        ownerExec(iris, abi.encodeCall(IIris.enableBlm, (blm)));
    }

    /// @dev Env: FEE (wad, multiple of BP). Guards `fee != 0 => feeRecipient != address(0)`.
    function setFee() public {
        uint256 fee = vm.envUint("FEE");
        require(fee == 0 || IIris(iris).feeRecipient() != address(0), "feeRecipient unset");
        ownerExec(iris, abi.encodeCall(IIris.setFee, (fee)));
    }

    /// @dev Env: FEE_RECIPIENT (address).
    function setFeeRecipient() public {
        address recipient = vm.envAddress("FEE_RECIPIENT");
        require(recipient != address(0), "feeRecipient zero");
        ownerExec(iris, abi.encodeCall(IIris.setFeeRecipient, (recipient)));
    }

    /// @dev Hand off the protocol to the Timelock in the address book, the only target: setOwner has no
    /// accept step, so a wrong address would lose governance for good. Deliberate, final step. Refuses
    /// until the launch config is live on-chain (see checkLaunchConfig) and the Timelock matches
    /// config.governance. A later owner change gets its own op when there is one.
    function transferOwnership() public {
        address timelock = load("Timelock");
        require(timelock != address(0), "no Timelock in the book (run DeployTimelock first)");
        require(IIris(iris).owner() != timelock, "Iris is already owned by the Timelock");
        require(_launchConfig(false) == 0, "launch config not live on-chain (gaps listed above)");
        IrisTimelock.check(TimelockController(payable(timelock)), _governance(), broadcaster);
        ownerExec(iris, abi.encodeCall(IIris.setOwner, (timelock)));
    }

    /// @dev Configure a deployed BLM so it is usable (an unconfigured BLM returns bondRequirement 0, which
    /// Iris.take rejects). Targets the BLM directly; gated by Iris's owner via ownerExec.
    /// Env: BLM (deployment name), TOKEN (debt token), SLOPE, INTERCEPT (wad, slope != 0, both < WAD).
    function setBlmParams() public {
        address blm = load(vm.envString("BLM"));
        require(blm != address(0), "blm not deployed");
        ownerExec(
            blm,
            abi.encodeWithSignature(
                "setParams(address,uint256,uint256)",
                vm.envAddress("TOKEN"),
                vm.envUint("SLOPE"),
                vm.envUint("INTERCEPT")
            )
        );
    }

    /// @dev Whitelist (or remove) a solver on a WhitelistBlm. Env: BLM, ACCOUNT, WHITELISTED (bool).
    function setBlmWhitelist() public {
        address blm = load(vm.envString("BLM"));
        require(blm != address(0), "blm not deployed");
        ownerExec(
            blm,
            abi.encodeWithSignature(
                "setIsWhitelisted(address,bool)", vm.envAddress("ACCOUNT"), vm.envBool("WHITELISTED")
            )
        );
    }

    /// @dev Sets every launch parameter in config that is not live yet, in one run: venue adapters, markets,
    /// bond LLTVs, BLMs and their params, then feeRecipient before fee. Config is the single source: write the
    /// launch values there and review them first, then apply, then check. Runs only while this key owns Iris
    /// (before the handoff); later changes go through the single-op menus and the Timelock. Idempotent:
    /// anything already live is skipped, so a re-run after a partial failure fills the gaps. The solver
    /// whitelist is not in config: set it with its own menu before the handoff.
    function applyLaunchConfig() public {
        require(IIris(iris).owner() == broadcaster, "apply runs only while this key owns Iris (before the handoff)");
        console.log("applied %s launch setting(s)", _launchConfig(true));
        require(_launchConfig(false) == 0, "launch config still not live after apply");
        console.log("launch config is live on-chain: ready for transferOwnership()");
    }

    /// @dev Sends nothing. Lists every launch parameter in config that is not live on Iris or its BLMs, with
    /// the menu entry that sets it (applyLaunchConfig sets them all). Config is the launch checklist, not a
    /// mirror, so extra on-chain state (another LLTV, market or BLM) is not flagged. The solver whitelist is
    /// not in config: set it before the handoff too, or each change waits minDelay.
    function checkLaunchConfig() public {
        require(_launchConfig(false) == 0, "launch config not live on-chain (gaps listed above)");
        console.log("launch config is live on-chain: ready for transferOwnership()");
    }

    /// @dev One walk over the launch config, shared by apply and check so both read config the same way.
    /// Every item that is not live on-chain is sent through ownerExec when `sendMissing`, else logged as a gap.
    /// Returns how many items were not live.
    function _launchConfig(bool sendMissing) internal returns (uint256 n) {
        IIris protocol = IIris(iris);

        // The Iris in the book must be this build. A stale book (the pre-audit Iris still recorded) would pass every
        // check below, since its BLMs and adapter are bound to it too, and the handoff would give it to the timelock.
        // Iris's runtime code depends only on its one immutable, POD_IMPL, and the compiler settings (bytecode_hash =
        // none), so a simulation-only deployment of this source reproduces it exactly. It is never broadcast.
        require(
            keccak256(address(new Iris(address(1), protocol.POD_IMPL())).code) == keccak256(iris.code),
            "Iris in the book is not this build (stale deployments/<chainId>.json?)"
        );

        // Undecided launch params block both modes: an absent list would otherwise pass vacuously.
        require(
            vm.keyExistsJson(config, ".bondLltvs") && config.readUintArray(".bondLltvs").length != 0,
            "launch params undecided: add bondLltvs to config/<chain>.json"
        );
        require(
            vm.keyExistsJson(config, ".blmParams") && vm.parseJsonKeys(config, ".blmParams").length != 0,
            "launch params undecided: add blmParams to config/<chain>.json"
        );

        string[] memory venues = vm.parseJsonKeys(config, ".venues");
        for (uint256 i; i < venues.length; i++) {
            string memory venue = string.concat(".venues", _key(venues[i]));
            uint256 venueId = config.readUint(string.concat(venue, ".id"));
            string memory adapterName = config.readString(string.concat(venue, ".adapter"));
            address adapter = load(adapterName);
            require(adapter != address(0), string.concat(adapterName, " not deployed"));
            if (protocol.venueAdapter(venueId) != adapter) {
                n += _fix(
                    sendMissing,
                    string.concat("venue ", venues[i], " -> ", adapterName),
                    "Add / upgrade venue",
                    iris,
                    abi.encodeCall(IIris.setVenueAdapter, (venueId, adapter))
                );
            }

            string[] memory markets = vm.parseJsonKeys(config, string.concat(venue, ".markets"));
            for (uint256 j; j < markets.length; j++) {
                // Same rule as enableMarket: empty = keccak256("") (Aave-style), else the Morpho-style market id.
                string memory raw = config.readString(string.concat(venue, ".markets", _key(markets[j])));
                bytes32 data = bytes(raw).length == 0 ? keccak256("") : vm.parseBytes32(raw);
                if (!protocol.isDataEnabled(data)) {
                    n += _fix(
                        sendMissing,
                        string.concat("market ", venues[i], " / ", markets[j]),
                        "Enable market",
                        iris,
                        abi.encodeCall(IIris.enableData, (data))
                    );
                }
            }
        }

        uint256[] memory bondLltvs = config.readUintArray(".bondLltvs");
        for (uint256 i; i < bondLltvs.length; i++) {
            // Iris accepts 0, and an enabled LLTV can never be disabled.
            require(bondLltvs[i] != 0, "bond LLTV 0 in config");
            if (!protocol.isBondLltvEnabled(bondLltvs[i])) {
                n += _fix(
                    sendMissing,
                    string.concat("bond LLTV ", vm.toString(bondLltvs[i])),
                    "Enable bond LLTV",
                    iris,
                    abi.encodeCall(IIris.enableBondLltv, (bondLltvs[i]))
                );
            }
        }

        // Every BLM with params in config must be enabled: a BLM without params quotes a zero bond, which take
        // rejects, so params are what make an enabled BLM usable.
        string[] memory blms = vm.parseJsonKeys(config, ".blmParams");
        for (uint256 i; i < blms.length; i++) {
            address blm = load(blms[i]);
            require(blm != address(0), string.concat(blms[i], " not deployed"));
            // A BLM gates setParams on its own IRIS's owner. One bound to an older Iris would leave its params with
            // that Iris's owner instead of this Iris's timelock, and no transaction from here can fix that.
            if (address(IBlm(blm).IRIS()) != iris) {
                require(!sendMissing, string.concat(blms[i], " is bound to another Iris - redeploy it for this Iris"));
                n++;
                console.log("gap: BLM %s is bound to another Iris - redeploy it for this Iris", blms[i]);
                continue;
            }
            if (!protocol.isBlmEnabled(blm)) {
                n += _fix(
                    sendMissing,
                    string.concat("BLM ", blms[i]),
                    "Enable BLM",
                    iris,
                    abi.encodeCall(IIris.enableBlm, (blm))
                );
            }

            string memory params = string.concat(".blmParams", _key(blms[i]));
            string[] memory tokens = vm.parseJsonKeys(config, params);
            for (uint256 j; j < tokens.length; j++) {
                string memory entry = string.concat(params, _key(tokens[j]));
                address token = config.readAddress(string.concat(".tokens", _key(tokens[j])));
                uint256 slope = config.readUint(string.concat(entry, ".slope"));
                uint256 intercept = config.readUint(string.concat(entry, ".intercept"));
                // A 0 slope equals unset storage, so it would skip setParams and pass as configured while the BLM
                // quotes a zero bond (take reverts). setParams rejects 0 anyway, and enforces the < WAD bounds itself.
                require(slope != 0, string.concat(blms[i], " slope for ", tokens[j], " is 0 in config"));
                if (IBlm(blm).slope(token) != slope || IBlm(blm).intercept(token) != intercept) {
                    n += _fix(
                        sendMissing,
                        string.concat(blms[i], " params for ", tokens[j]),
                        "Configure BLM params",
                        blm,
                        abi.encodeCall(IBlm.setParams, (token, slope, intercept))
                    );
                }
            }
        }

        // feeRecipient before fee. Iris's header leaves `fee != 0 => feeRecipient != address(0)` to the team, and
        // setFee does not check it: with a zero recipient, _claimable reverts, blocking repay and liquidate.
        address feeRecipient = config.readAddress(".feeRecipient");
        require(
            config.readUint(".fee") == 0 || feeRecipient != address(0), "fee set but feeRecipient is zero in config"
        );
        if (protocol.feeRecipient() != feeRecipient) {
            n += _fix(
                sendMissing,
                "feeRecipient",
                "Set fee recipient",
                iris,
                abi.encodeCall(IIris.setFeeRecipient, (feeRecipient))
            );
        }
        uint256 fee = config.readUint(".fee");
        if (uint256(protocol.fee()) * BP != fee) {
            n += _fix(sendMissing, "fee", "Set fee", iris, abi.encodeCall(IIris.setFee, (fee)));
        }
    }

    /// @dev Send one missing launch item when `sendMissing`, else report it as a gap. Returns 1 either way.
    function _fix(bool sendMissing, string memory item, string memory menu, address target, bytes memory data)
        internal
        returns (uint256)
    {
        if (sendMissing) {
            console.log("apply: %s", item);
            ownerExec(target, data);
        } else {
            console.log("gap: %s - %s", item, menu);
        }
        return 1;
    }

    /// @dev Bracketed JSON key, so config keys like "cbBTC/USDC" stay one path segment.
    function _key(string memory key) private pure returns (string memory) {
        return string.concat("['", key, "']");
    }
}
