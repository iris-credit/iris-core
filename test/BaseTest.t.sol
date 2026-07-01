// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "@solady/tokens/ERC20.sol";
import "@solady/utils/LibClone.sol";

import "../src/interfaces/IIris.sol";
import "../src/interfaces/IPod.sol";
import "../src/Iris.sol";
import "../src/Pod.sol";

import {SigUtils} from "./unit/helpers/SigUtils.sol";

/// @dev Venue-agnostic base shared by unit and fork test environments. Only the system under
/// test (Iris and pods) is deployed here; the environment wires tokens, blm and venue adapter.
abstract contract BaseTest is Test {
    using MathLib for uint256;

    uint256 internal constant BLOCK_TIME = 1;
    /// @dev Amounts below this are unrealistic dust for any supported token.
    uint256 internal constant MIN_TEST_AMOUNT = 10_000;
    /// @dev Routine fuzzing envelope. The protocol itself supports amounts up to ~1e32.
    uint256 internal constant MAX_TEST_AMOUNT = 1e28;
    /// @dev Enabled bond lltvs must be at least MAX_BOND_LIF so that bondSlashed >= seized on bond liquidation.
    uint256 internal constant MIN_TEST_BOND_LLTV = MAX_BOND_LIF;
    uint256 internal constant MAX_TEST_BOND_LLTV = WAD - BP;
    uint256 internal constant DEFAULT_TEST_BOND_LLTV = 0.9e18;

    address immutable owner = makeAddr("owner");
    address borrower;
    uint256 borrowerPk;
    address solver;
    uint256 solverPk;
    address immutable receiver = makeAddr("receiver");
    address immutable feeRecipient = makeAddr("feeRecipient");

    uint256 bondLltv;

    address collateralToken;
    address debtToken;
    IBlm blm;
    IVenueAdapter venueAdapter;
    IPod podImpl;
    IIris iris;

    function setUp() public virtual {
        vm.label(address(this), "TestContract");

        (borrower, borrowerPk) = makeAddrAndKey("borrower");
        (solver, solverPk) = makeAddrAndKey("solver");

        bondLltv = vm.envOr("BOND_LLTV", DEFAULT_TEST_BOND_LLTV);

        podImpl = IPod(new Pod());
        iris = IIris(_newIris(owner, address(podImpl)));

        vm.startPrank(owner);
        iris.enableBondLltv(bondLltv);
        iris.enableData(keccak256(""));
        iris.setFeeRecipient(feeRecipient);
        vm.stopPrank();

        vm.label(address(podImpl), "PodImpl");
        vm.label(address(iris), "Iris");
    }

    /// @dev Overridable so a suite can deploy an Iris test harness that exposes internal hooks.
    function _newIris(address newOwner, address podImpl_) internal virtual returns (address) {
        return address(new Iris(newOwner, podImpl_));
    }

    /// @dev Rolls & warps the given number of blocks forward the blockchain.
    function _forward(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks * BLOCK_TIME); // Block speed should depend on test network.
    }

    /// @dev Bounds the fuzzing input to a realistic number of blocks.
    function _boundBlocks(uint256 blocks) internal pure returns (uint256) {
        return bound(blocks, 1, type(uint32).max);
    }

    /// @dev Bounds the fuzzing input to a valid BP-granular bond lltv.
    function _boundBondLltv(uint256 bondLltv_) internal pure returns (uint256) {
        return bound(bondLltv_, MIN_TEST_BOND_LLTV / BP, MAX_TEST_BOND_LLTV / BP) * BP;
    }

    /// @dev Bounds collateral and debt to a healthy position which keeps at least MIN_TEST_AMOUNT
    /// of collateral withdrawable under the health check.
    function _boundHealthyPosition(uint256 collateral, uint256 debt, bytes memory data)
        internal
        view
        returns (uint256, uint256)
    {
        collateral = bound(collateral, MIN_TEST_AMOUNT + 1, MAX_TEST_AMOUNT);
        debt = bound(debt, 0, MathLib.min(_maxDebt(collateral - MIN_TEST_AMOUNT, data), MAX_TEST_AMOUNT));
        return (collateral, debt);
    }

    /// @dev Returns the maximum debt the given collateral supports under the venue's lltv and price.
    function _maxDebt(uint256 collateral, bytes memory data) internal view returns (uint256) {
        uint256 collateralPrice = venueAdapter.price(collateralToken, debtToken, data);
        uint256 lltv = venueAdapter.lltv(collateralToken, debtToken, data);
        return collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).mulDivDown(lltv, WAD);
    }

    /// @dev Signs a quote with the given private key for EIP-712 submission to `take`. Shared by the
    /// unit and fork suites.
    function _signQuote(uint256 privateKey, Quote memory quote) internal view returns (bytes memory) {
        bytes32 digest = SigUtils.getTypedDataHash(iris.DOMAIN_SEPARATOR(), quote);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
