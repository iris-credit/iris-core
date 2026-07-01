// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseTest.t.sol";

import {ERC20Mock} from "./unit/helpers/mocks/ERC20Mock.sol";
import {BlmMock} from "./unit/helpers/mocks/BlmMock.sol";
import {VenueAdapterMock} from "./unit/helpers/mocks/VenueAdapterMock.sol";

abstract contract UnitTest is BaseTest {
    uint256 internal constant MIN_TEST_COLLATERAL_PRICE = 1e10;
    uint256 internal constant MAX_TEST_COLLATERAL_PRICE = 1e40;
    uint256 internal constant DEFAULT_TEST_LLTV = 0.8e18;
    /// @dev Realistic accrued indices (RAY-scaled), distinct so a collateral/debt index mix-up is caught.
    uint256 internal constant DEFAULT_TEST_COLLATERAL_INDEX = 1.1e27;
    uint256 internal constant DEFAULT_TEST_DEBT_INDEX = 1.2e27;
    uint8 internal constant DEFAULT_TEST_COLL_DECIMALS = 18;
    uint8 internal constant DEFAULT_TEST_DEBT_DECIMALS = 6;

    address pod;

    function setUp() public virtual override {
        super.setUp();

        pod = LibClone.clone(address(podImpl), abi.encodePacked(address(iris)));

        collateralToken = address(new ERC20Mock("Collateral Token", "COLL", DEFAULT_TEST_COLL_DECIMALS));
        debtToken = address(new ERC20Mock("Debt Token", "DEBT", DEFAULT_TEST_DEBT_DECIMALS));
        blm = new BlmMock(iris);
        venueAdapter = new VenueAdapterMock();

        vm.startPrank(owner);
        iris.enableBlm(address(blm));
        iris.setVenueAdapter(0, address(venueAdapter));
        vm.stopPrank();

        VenueAdapterMock(address(venueAdapter)).setLltv(DEFAULT_TEST_LLTV);
        VenueAdapterMock(address(venueAdapter)).setPrice(ORACLE_PRICE_SCALE);
        VenueAdapterMock(address(venueAdapter)).setIndices(DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_DEBT_INDEX);

        vm.label(collateralToken, "CollateralToken");
        vm.label(debtToken, "DebtToken");
        vm.label(address(venueAdapter), "VenueAdapter");
        vm.label(address(blm), "Blm");
        vm.label(pod, "Pod");
    }
}
