// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseScript} from "./Base.s.sol";
import {IIris} from "../src/interfaces/IIris.sol";

/// @dev Every owner governance op, one entrypoint each (select with `forge script --sig`).
/// All route through `ownerExec`, so they broadcast pre-handoff and print timelock calldata after.
/// Values are passed in via env (the menu prompts for them); scriptMaster records owner/fee/
/// feeRecipient back into config/<chain>.json on production runs.
contract SetConfig is BaseScript {
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

    /// @dev Env: OWNER (the timelock). Hand off the protocol. Deliberate, final step.
    function transferOwnership() public {
        address newOwner = vm.envAddress("OWNER");
        require(newOwner != address(0), "owner zero");
        ownerExec(iris, abi.encodeCall(IIris.setOwner, (newOwner)));
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
}
