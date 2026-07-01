// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IVenueAdapter} from "../../../../src/interfaces/IVenueAdapter.sol";

contract VenueAdapterMock is IVenueAdapter {
    uint256 public venueCollateral;
    uint256 public venueDebt;
    uint256 public _price;
    uint256 public _lltv;
    uint256 public collateralIndex;
    uint256 public debtIndex;

    /// @dev Default indices to 1e27 (RAY) so accrual is zero until a test moves them, matching the
    /// `index >= lastIndex` invariant assumed by Iris (see Iris.sol VENUE ADAPTERS).
    constructor() {
        collateralIndex = 1e27;
        debtIndex = 1e27;
    }

    function setPosition(uint256 venueCollateral_, uint256 venueDebt_) external {
        venueCollateral = venueCollateral_;
        venueDebt = venueDebt_;
    }

    function setPrice(uint256 price_) external {
        _price = price_;
    }

    function setLltv(uint256 lltv_) external {
        _lltv = lltv_;
    }

    /// @dev Set the venue indices to simulate accrual. Raising an index since the position's stored
    /// index accrues the corresponding leg; lowering it is only for underflow/revert tests.
    function setIndices(uint256 collateralIndex_, uint256 debtIndex_) external {
        collateralIndex = collateralIndex_;
        debtIndex = debtIndex_;
    }

    function positionAssets(address, address, address, bytes calldata) external view returns (uint256, uint256) {
        return (venueCollateral, venueDebt);
    }

    function price(address, address, bytes calldata) external view returns (uint256) {
        return _price;
    }

    function lltv(address, address, bytes calldata) external view returns (uint256) {
        return _lltv;
    }

    function indices(address, address, bytes calldata) external view returns (uint256, uint256) {
        return (collateralIndex, debtIndex);
    }

    function supplyCollateral(address, uint256, bytes calldata) external {}
    function withdrawCollateral(address, uint256, address, bytes calldata) external {}
    function repay(address, uint256, bytes calldata) external {}
    function enter(address, uint256, address, uint256, address, bytes calldata) external {}
    function exit(address, uint256, address, uint256, address, bytes calldata) external {}
}
