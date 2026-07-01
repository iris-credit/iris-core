// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

struct Hop {
    address collateralToken;
    address debtToken;
    uint256 venueId;
    uint256 newVenueId;
    bytes data;
    bytes newData;
    IVenueAdapter adapter;
    IVenueAdapter newAdapter;
}

contract RefinanceForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    Id[] internal hopIds;

    function setUp() public virtual override {
        delete hopIds;

        super.setUp();
    }

    function testRefinanceCrossVenue(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 blocks,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        blocks = bound(blocks, 0, duration + overduePeriod);
        seed = bound(seed, 0, type(uint256).max);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        Hop memory hop = _randomHop(seed, venueId);

        vm.prank(owner);
        blm.setParams(hop.debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(
            hop.collateralToken,
            hop.debtToken,
            collateral,
            debt,
            hop.venueId,
            hop.newVenueId,
            hop.data,
            hop.newData,
            blocks * BLOCK_TIME
        );

        Quote memory quote = _buildQuote(
            hop.collateralToken, hop.debtToken, collateral, debt, duration, overduePeriod, hop.venueId, hop.data
        );
        address pod = _openLoan(quote);

        _forward(blocks);

        (uint256 venueCollateral, uint256 venueDebt) =
            hop.adapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.data);

        deal(hop.debtToken, solver, venueDebt);
        vm.startPrank(solver);
        hop.debtToken.safeApprove(address(iris), venueDebt);
        iris.refinance(pod, hop.newVenueId, hop.newData);
        vm.stopPrank();

        (uint256 newVenueCollateral, uint256 newVenueDebt) =
            hop.newAdapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.newData);
        (uint256 newCollateralIndex, uint256 newDebtIndex) =
            hop.newAdapter.indices(hop.collateralToken, hop.debtToken, hop.newData);

        assertApproxEqAbs(newVenueCollateral, venueCollateral, 2);
        assertApproxEqAbs(newVenueDebt, venueDebt, 2);
        assertEq(hop.debtToken.balanceOf(solver), venueDebt);

        Position memory pos = iris.getPosition(pod);
        (venueCollateral, venueDebt) = hop.adapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.data);
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
        assertEq(pos.venueId, uint8(hop.newVenueId));
        assertEq(pos.data, hop.newData);
        assertEq(pos.collateralIndex, newCollateralIndex);
        assertEq(pos.debtIndex, newDebtIndex);
    }

    function testRefinanceSameVenue(
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        seed = bound(seed, 0, type(uint256).max);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        Hop memory hop = _randomHop(seed, venueId);

        vm.prank(owner);
        blm.setParams(hop.debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        // Destination == source.
        (collateral, debt) = _boundHealthyPosition(
            hop.collateralToken, hop.debtToken, collateral, debt, hop.venueId, hop.venueId, hop.data, hop.data, 0
        );

        Quote memory quote = _buildQuote(
            hop.collateralToken, hop.debtToken, collateral, debt, duration, overduePeriod, hop.venueId, hop.data
        );
        address pod = _openLoan(quote);
        (uint256 venueCollateral, uint256 venueDebt) =
            hop.adapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.data);

        deal(hop.debtToken, solver, venueDebt);
        vm.prank(solver);
        hop.debtToken.safeApprove(address(iris), venueDebt);

        vm.prank(solver);
        try iris.refinance(pod, hop.venueId, hop.data) {
            (uint256 newVenueCollateral, uint256 newVenueDebt) =
                hop.adapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.data);
            (uint256 newCollateralIndex, uint256 newDebtIndex) =
                hop.adapter.indices(hop.collateralToken, hop.debtToken, hop.data);
            Position memory pos = iris.getPosition(pod);

            assertLe(newVenueCollateral, venueCollateral);
            assertGe(newVenueDebt, venueDebt);
            assertApproxEqAbs(newVenueCollateral, venueCollateral, 2);
            assertApproxEqAbs(newVenueDebt, venueDebt, 2);
            assertEq(pos.venueId, uint8(hop.venueId));
            assertEq(pos.collateralIndex, newCollateralIndex);
            assertEq(pos.debtIndex, newDebtIndex);
            assertEq(hop.debtToken.balanceOf(solver), venueDebt);
        } catch (bytes memory err) {
            // Expected only at the LTV edge: at max borrow the round-trip rounding (debt up, colla
            // teral down) which overs the venue's borrow limit.
            if (hop.venueId == uint256(VenueId.AAVE_V3)) {
                assertEq(err, abi.encodeWithSelector(AaveV3Errors.CollateralCannotCoverNewBorrow.selector));
            } else if (hop.venueId == uint256(VenueId.MORPHO_BLUE)) {
                assertEq(err, abi.encodeWithSignature("Error(string)", MorphoBlueErrors.INSUFFICIENT_COLLATERAL));
            } else {
                revert("RefinanceForkTest: Invalid venueId");
            }
        }
    }

    function testRefinanceWithRebase(
        uint256 collateral,
        uint256 debt,
        uint256 repaid,
        uint256 lif,
        uint256 duration,
        uint256 overduePeriod,
        uint256 seed,
        uint256 venueId
    ) public {
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);
        seed = bound(seed, 0, type(uint256).max);
        venueId = bound(venueId, 0, uint256(type(VenueId).max));

        Hop memory hop = _randomHop(seed, venueId);

        vm.prank(owner);
        blm.setParams(hop.debtToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(
            hop.collateralToken, hop.debtToken, collateral, debt, hop.venueId, hop.newVenueId, hop.data, hop.newData, 0
        );

        Quote memory quote = _buildQuote(
            hop.collateralToken, hop.debtToken, collateral, debt, duration, overduePeriod, hop.venueId, hop.data
        );
        address pod = _openLoan(quote);
        Position memory pos = iris.getPosition(pod);

        (uint256 venueCollateral, uint256 venueDebt) =
            hop.adapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.data);

        repaid = bound(repaid, MIN_TEST_AMOUNT, venueDebt);
        lif = bound(lif, 100 * BP, 500 * BP); // 1% to 5%

        uint256 collateralPrice = hop.adapter.price(hop.collateralToken, hop.debtToken, hop.data);
        uint256 liquidated = repaid.mulDivUp(WAD + lif, WAD).mulDivUp(ORACLE_PRICE_SCALE, collateralPrice);
        uint256 remainingCollateral = venueCollateral - liquidated;
        uint256 remainingDebt = venueDebt - repaid;

        vm.assume(remainingDebt != 0);

        uint256 rebaseLiquidated = uint256(pos.collateral).zeroFloorSub(remainingCollateral);
        uint256 rebaseRepaid = uint256(pos.debt).zeroFloorSub(remainingDebt);
        uint256 expectedDebt = uint256(pos.debt)
            .zeroFloorSub(MathLib.min(rebaseRepaid, rebaseLiquidated.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE)));

        bytes memory exitData = abi.encodeWithSelector(
            IVenueAdapter.exit.selector,
            hop.collateralToken,
            remainingCollateral,
            hop.debtToken,
            remainingDebt,
            pod,
            hop.data
        );
        _mockPositionAssets(
            hop.adapter, pod, hop.collateralToken, hop.debtToken, hop.data, remainingCollateral, remainingDebt
        );
        vm.mockCall(
            pod,
            abi.encodeWithSelector(IPod.delegateCall.selector, address(hop.adapter), exitData),
            abi.encode(bytes(""))
        );

        // Assume exit happened
        deal(hop.collateralToken, pod, remainingCollateral);
        deal(hop.debtToken, solver, remainingDebt);
        vm.startPrank(solver);
        hop.debtToken.safeApprove(address(iris), remainingDebt);
        iris.refinance(pod, hop.newVenueId, hop.newData);
        vm.stopPrank();

        (uint256 newVenueCollateral, uint256 newVenueDebt) =
            hop.newAdapter.positionAssets(pod, hop.collateralToken, hop.debtToken, hop.newData);
        (uint256 newCollateralIndex, uint256 newDebtIndex) =
            hop.newAdapter.indices(hop.collateralToken, hop.debtToken, hop.newData);

        Position memory newPos = iris.getPosition(pod);

        assertEq(newPos.collateral, remainingCollateral);
        assertEq(newPos.debt, expectedDebt);
        assertEq(newPos.collateralIndex, newCollateralIndex);
        assertEq(newPos.debtIndex, newDebtIndex);
        assertApproxEqAbs(newVenueCollateral, remainingCollateral, 2);
        assertApproxEqAbs(newVenueDebt, remainingDebt, 2);
        assertEq(hop.debtToken.balanceOf(solver), remainingDebt);
    }

    /* MARKET SELECTION */

    /// @dev Find a Morpho market whose collateral Aave also supports. (required for cross-venue refinance).
    /// Then
    function _randomHop(uint256 seed, uint256 venueId) internal returns (Hop memory hop) {
        MarketParams memory marketParams;

        for (uint256 i; i < config.morphoMarketIdList.length; i++) {
            Id id = config.morphoMarketIdList[i];
            marketParams = MorphoBlueUtils.idToMarketParams(morphoBlue, id);
            if (aaveV3Adapter.lltv(marketParams.collateralToken, marketParams.loanToken, "") != 0) {
                hopIds.push(id);
            }
        }

        require(hopIds.length != 0, "RefinanceForkTest: No hop (refinanceable) markets");

        marketParams = MorphoBlueUtils.randomMarketParams(morphoBlue, seed, hopIds);

        hop.collateralToken = marketParams.collateralToken;
        hop.debtToken = marketParams.loanToken;
        hop.venueId = venueId;
        /// @dev on a new venue addition, this logic will be broken.
        assertLe(venueId, 1);
        hop.newVenueId = 1 - venueId;
        hop.adapter = IVenueAdapter(iris.venueAdapter(hop.venueId));
        hop.newAdapter = IVenueAdapter(iris.venueAdapter(hop.newVenueId));

        if (venueId == uint256(VenueId.AAVE_V3)) {
            hop.data = "";
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            hop.data = abi.encode(marketParams);
        } else {
            revert("RefinanceForkTest: Invalid venueId");
        }

        if (hop.newVenueId == uint256(VenueId.AAVE_V3)) {
            hop.newData = "";
        } else if (hop.newVenueId == uint256(VenueId.MORPHO_BLUE)) {
            hop.newData = abi.encode(marketParams);
        } else {
            revert("RefinanceForkTest: Invalid newVenueId");
        }

        return hop;
    }

    /// @dev A configured Morpho market whose collateral differs from this loan's, so refinancing into it
    /// trips the adapter's collateral-token check.
    function _morphoBlueForeignMarket() internal view returns (MarketParams memory) {
        for (uint256 i; i < config.morphoMarketIdList.length; i++) {
            MarketParams memory marketParams =
                MorphoBlueUtils.randomMarketParams(morphoBlue, i, config.morphoMarketIdList);
            if (marketParams.collateralToken != collateralToken) return marketParams;
        }
        revert("RefinanceForkTest: No Morpho Blue market with a different collateral token");
    }

    /* HELPERS */

    function _buildQuote(
        address collateralToken,
        address debtToken,
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 overduePeriod,
        uint256 venueId_,
        bytes memory data
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken;
        quote.debtToken = debtToken;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = duration;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = overduePeriod;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3; // bit0 Aave | bit1 Morpho
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = data;
        quote.bond = blm.bondRequirement(quote);
    }

    /* BOUND */

    function _boundHealthyPosition(
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 srcId,
        uint256 dstId,
        bytes memory srcData,
        bytes memory dstData,
        uint256 elapsed
    ) internal view returns (uint256, uint256) {
        uint256 maxCollateral = _maxSuppliable(elapsed, collateralToken, srcId, dstId, srcData, dstData);
        uint256 maxBorrow = _maxBorrowable(elapsed, collateralToken, debtToken, srcId, dstId, srcData, dstData);

        vm.assume(maxBorrow >= MIN_TEST_AMOUNT);
        vm.assume(maxCollateral >= MIN_TEST_AMOUNT);

        borrowAmount = bound(borrowAmount, MIN_TEST_AMOUNT, maxBorrow);
        collateralAmount = bound(
            collateralAmount,
            _minCollateralAmount(elapsed, borrowAmount, collateralToken, debtToken, srcId, dstId, srcData, dstData),
            maxCollateral
        );

        return (collateralAmount, borrowAmount);
    }

    /* MAX SUPPLIABLE/BORROWABLE */

    /// @dev `elapsed` projects the destination's supply headroom to refinance time; the source is supplied at
    /// open, so it stays at the current block.
    function _maxSuppliable(
        uint256 elapsed,
        address token,
        uint256 srcId,
        uint256 dstId,
        bytes memory srcData,
        bytes memory dstData
    ) internal view returns (uint256) {
        uint256 suppliable = MathLib.min(
            _maxSuppliable(token, srcId, srcData), _maxSuppliable(elapsed, token, dstId, dstData)
        );
        return suppliable.mulDivDown(WAD, _collateralGrossFactor(token, suppliable, elapsed, srcId, srcData));
    }

    function _maxSuppliable(uint256 elapsed, address token, uint256 venueId, bytes memory data)
        internal
        view
        returns (uint256)
    {
        uint256 maxSupplyCapacity;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            maxSupplyCapacity = AaveV3Utils.maxSupplyCapacity(elapsed, aaveV3Pool, token);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            maxSupplyCapacity = MorphoBlueUtils.maxSupplyCapacity(elapsed, morphoBlue, data);
        } else {
            revert("RefinanceForkTest: Invalid venue ID");
        }

        return MathLib.min(maxSupplyCapacity, MAX_TEST_AMOUNT);
    }

    /// @dev `elapsed` projects the destination's borrow headroom to refinance time.
    function _maxBorrowable(
        uint256 elapsed,
        address collateralToken,
        address debtToken,
        uint256 srcId,
        uint256 dstId,
        bytes memory srcData,
        bytes memory dstData
    ) internal view returns (uint256) {
        uint256 maxCollateral = _maxSuppliable(elapsed, collateralToken, srcId, dstId, srcData, dstData);
        uint256 maxBorrow = _maxBorrowAmount(maxCollateral, collateralToken, debtToken, srcId, dstId, srcData, dstData);
        uint256 maxBorrowCapacity;
        uint256 maxBorrowCapacity1;
        uint256 maxBorrowCapacity2;

        if (srcId == uint256(VenueId.AAVE_V3)) {
            maxBorrowCapacity1 = AaveV3Utils.maxBorrowCapacity(aaveV3Pool, debtToken);
        } else if (srcId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowCapacity1 = MorphoBlueUtils.maxBorrowCapacity(morphoBlue, srcData);
        } else {
            revert("RefinanceForkTest: Invalid src venue ID");
        }

        if (dstId == uint256(VenueId.AAVE_V3)) {
            maxBorrowCapacity2 = AaveV3Utils.maxBorrowCapacity(aaveV3Pool, debtToken);
        } else if (dstId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowCapacity2 = MorphoBlueUtils.maxBorrowCapacity(morphoBlue, dstData);
        } else {
            revert("RefinanceForkTest: Invalid dst venue ID");
        }

        maxBorrowCapacity = MathLib.min(maxBorrowCapacity1, maxBorrowCapacity2);
        maxBorrowCapacity =
            maxBorrowCapacity.mulDivDown(WAD, _debtGrossFactor(debtToken, maxBorrowCapacity, elapsed, srcId, srcData));

        return MathLib.min(MathLib.min(maxBorrow, maxBorrowCapacity), MAX_TEST_AMOUNT);
    }

    /* MIN/MAX COLLATERAL/BORROW AMOUNT */

    function _minCollateralAmount(
        uint256 elapsed,
        uint256 amount,
        address collateralToken,
        address debtToken,
        uint256 srcId,
        uint256 dstId,
        bytes memory srcData,
        bytes memory dstData
    ) internal view returns (uint256) {
        uint256 minCollateral;
        uint256 minCollateralSrc;
        uint256 minCollateralDst;

        amount = amount.mulDivUp(_debtGrossFactor(debtToken, amount, elapsed, srcId, srcData), WAD);

        // Source collateral is supplied at open (elapsed 0); destination collateral lands at refinance, so
        // project the destination's Aave indices forward by `elapsed` (index growth shrinks its capacity).
        if (srcId == uint256(VenueId.AAVE_V3)) {
            minCollateralSrc = AaveV3Utils.minCollateralAmount(0, amount, aaveV3Pool, collateralToken, debtToken);
        } else if (srcId == uint256(VenueId.MORPHO_BLUE)) {
            minCollateralSrc = MorphoBlueUtils.minCollateralAmount(0, amount, morphoBlue, srcData);
            // Adjust amount to account for Morpho's share/asset rounding
            amount = MorphoBlueUtils.expectedBorrowAssets(amount, morphoBlue, srcData);
        } else {
            revert("RefinanceForkTest: Invalid src venue ID");
        }

        if (dstId == uint256(VenueId.AAVE_V3)) {
            minCollateralDst = AaveV3Utils.minCollateralAmount(elapsed, amount, aaveV3Pool, collateralToken, debtToken);
        } else if (dstId == uint256(VenueId.MORPHO_BLUE)) {
            minCollateralDst = MorphoBlueUtils.minCollateralAmount(elapsed, amount, morphoBlue, dstData);
        } else {
            revert("RefinanceForkTest: Invalid dst venue ID");
        }

        minCollateral = MathLib.max(minCollateralSrc, minCollateralDst);

        return MathLib.max(minCollateral, MIN_TEST_AMOUNT);
    }

    function _maxBorrowAmount(
        uint256 amount,
        address collateralToken,
        address debtToken,
        uint256 srcId,
        uint256 dstId,
        bytes memory srcData,
        bytes memory dstData
    ) internal view returns (uint256) {
        uint256 maxBorrowAmount;
        uint256 maxBorrowAmountSrc;
        uint256 maxBorrowAmountDst;

        if (srcId == uint256(VenueId.AAVE_V3)) {
            maxBorrowAmountSrc = AaveV3Utils.maxBorrowAmount(amount, aaveV3Pool, collateralToken, debtToken);
        } else if (srcId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowAmountSrc = MorphoBlueUtils.maxBorrowAmount(amount, morphoBlue, srcData);
        } else {
            revert("RefinanceForkTest: Invalid src venue ID");
        }

        if (dstId == uint256(VenueId.AAVE_V3)) {
            maxBorrowAmountDst = AaveV3Utils.maxBorrowAmount(amount, aaveV3Pool, collateralToken, debtToken);
        } else if (dstId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowAmountDst = MorphoBlueUtils.maxBorrowAmount(amount, morphoBlue, dstData);
        } else {
            revert("RefinanceForkTest: Invalid dst venue ID");
        }

        maxBorrowAmount = MathLib.min(maxBorrowAmountSrc, maxBorrowAmountDst);

        return MathLib.min(maxBorrowAmount, MAX_TEST_AMOUNT);
    }

    /* GROSS FACTOR */

    /// @dev Growth factor (WAD) of collateral on `venueId` over `elapsed`; 1x on Morpho (collateral is inert).
    function _collateralGrossFactor(address token, uint256 amount, uint256 elapsed, uint256 venueId, bytes memory data)
        internal
        view
        returns (uint256)
    {
        if (venueId == uint256(VenueId.AAVE_V3)) {
            return AaveV3Utils.collateralGrossFactor(aaveV3Pool, token, amount, elapsed);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            return MorphoBlueUtils.collateralGrossFactor(morphoBlue, data, amount, elapsed);
        } else {
            revert("RefinanceForkTest: Invalid venue ID");
        }
    }

    /// @dev Growth factor (WAD) of debt on `venueId` over `elapsed`, accounting for the position's own borrow.
    function _debtGrossFactor(address token, uint256 amount, uint256 elapsed, uint256 venueId, bytes memory data)
        internal
        view
        returns (uint256)
    {
        if (venueId == uint256(VenueId.AAVE_V3)) {
            return AaveV3Utils.debtGrossFactor(aaveV3Pool, token, amount, elapsed);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            return MorphoBlueUtils.debtGrossFactor(morphoBlue, data, amount, elapsed);
        } else {
            revert("RefinanceForkTest: Invalid venue ID");
        }
    }
}
