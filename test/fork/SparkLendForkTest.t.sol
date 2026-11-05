// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {IPool} from "@aave/contracts/interfaces/IPool.sol";
import {IPriceOracleGetter} from "@aave/contracts/interfaces/IPriceOracleGetter.sol";

/// @dev SparkLend's v3.0 PoolConfigurator: `setReservePause` predates the grace-period argument of later Aave releases.
interface ISparkLendPoolConfigurator {
    function setReserveFreeze(address asset, bool freeze) external;
    function setReservePause(address asset, bool paused) external;
}

/// @dev SparkLend (an Aave V3.0 core fork) as venue 2, served by the unmodified AaveV3Adapter, on the real pool.
/// Where SparkLend differs from Aave v3.6: token amounts round half up, reverts carry Error(string) codes, the
/// residual debt of a full liquidation stays on the borrower, and the ETH and BTC prices come from medians that
/// revert once every source is 25 h old. A fork's feeds stop at its block, so every test that moves time pins the
/// prices SparkLend reads.
contract SparkLendForkTest is ForkTest {
    using MathLib for uint128;
    using MathLib for uint256;
    using SafeTransferLib for address;

    uint256 internal constant SPARK_LEND = 2;
    /// @dev Spark's governance executor (the Sky SubProxy), SparkLend's pool admin.
    address internal constant SPARK_LEND_ADMIN = 0x3300f198988e4C9C63F75dF86De36421f06af8c4;

    address immutable liquidator = makeAddr("liquidator");

    IPool internal sparkLendPool;
    address internal sparkLendOracle;
    AaveV3Adapter internal sparkLendAdapter;

    address internal usdc;
    address internal usdt;
    address internal weth;
    address internal wstEth;
    address internal cbBtc;

    function setUp() public override {
        super.setUp();

        sparkLendPool = IPool(getAddress("sparkLendPool"));
        sparkLendOracle = sparkLendPool.ADDRESSES_PROVIDER().getPriceOracle();
        sparkLendAdapter = new AaveV3Adapter(address(sparkLendPool));
        vm.label(sparkLendOracle, "sparkLendOracle");
        vm.label(address(sparkLendAdapter), "sparkLendAdapter");

        usdc = getAddress("USDC");
        usdt = getAddress("USDT");
        weth = getAddress("WETH");
        wstEth = getAddress("wstETH");
        cbBtc = getAddress("cbBTC");

        vm.startPrank(owner);
        iris.setVenueAdapter(SPARK_LEND, address(sparkLendAdapter));
        blm.setParams(usdc, DEFAULT_SLOPE, DEFAULT_INTERCEPT);
        blm.setParams(usdt, DEFAULT_SLOPE, DEFAULT_INTERCEPT);
        vm.stopPrank();
    }

    /* LIFECYCLE */

    function testSparkLendTakeRepayEscapeCbBtcUsdc() public {
        _takeRepayEscape(cbBtc, usdc, 1e8, 30_000e6, 0.1e8);
    }

    function testSparkLendTakeRepayEscapeWstEthUsdt() public {
        _takeRepayEscape(wstEth, usdt, 10e18, 10_000e6, 1e18);
    }

    function testSparkLendRefinanceFromAndToAaveV3() public {
        _pinSparkLendPrice(weth);
        uint256 aaveV3 = uint256(VenueId.AAVE_V3);
        address pod = _openLoan(_quote(weth, usdc, 10e18, 8_000e6, 30 days, aaveV3, (1 << aaveV3) | (1 << SPARK_LEND)));

        _forward(1 hours);
        _refinance(pod, aaveV3, SPARK_LEND);
        _forward(1 hours);
        _refinance(pod, SPARK_LEND, aaveV3);

        _forward(1 days);
        _repay(pod, borrower);
        vm.prank(borrower);
        iris.escape(pod, receiver);

        (uint256 venueCollateral, uint256 venueDebt) = aaveV3Adapter.positionAssets(pod, weth, usdc, "");
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
    }

    /* LIQUIDATIONS */

    function testSparkLendLiquidateOverdue() public {
        _pinSparkLendPrice(weth);
        address pod = _openLoan(_quote(weth, usdc, 10e18, 8_000e6, MIN_DURATION, SPARK_LEND, 1 << SPARK_LEND));

        _forward(MIN_DURATION + TIME_TO_MAX_LIF + 1);

        // Stand in for the pooled balance a live Iris holds, as in LiquidateForkTest.
        deal(usdc, address(iris), usdc.balanceOf(address(iris)) + MIN_TEST_AMOUNT);
        Position memory pos = iris.getPosition(pod);
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        uint256 repaid = pos.debt + fixedLeg + floatingLeg.zeroFloorSub(fixedLeg).zeroFloorSub(pos.bond);

        deal(usdc, liquidator, repaid);
        uint256 receiverBalanceBefore = weth.balanceOf(receiver);
        vm.startPrank(liquidator);
        usdc.safeApproveWithRetry(address(iris), repaid);
        (, uint256 seized) = iris.liquidate(pod, receiver);
        vm.stopPrank();

        assertEq(usdc.balanceOf(liquidator), 0);
        assertEq(weth.balanceOf(receiver) - receiverBalanceBefore, seized);
        (uint256 venueCollateral, uint256 venueDebt) = sparkLendAdapter.positionAssets(pod, weth, usdc, "");
        assertEq(venueDebt, 0);
        assertApproxEqAbs(venueCollateral, 10e18 - seized, 2);

        pos = iris.getPosition(pod);
        assertEq(pos.debt, 0);
        assertEq(pos.bondRequirement, 0);
        assertApproxEqAbs(pos.collateral, 10e18 - seized, 2);
    }

    function testSparkLendLiquidateBond() public {
        _pinSparkLendPrice(cbBtc);
        // A near-zero bond and no fixed leg: two days of SparkLend's floating rate put the bond underwater. cbBTC earns
        // next to no supply yield, so no surplus offsets it.
        vm.prank(owner);
        blm.setParams(usdc, 1e12, 0);
        Quote memory quote = _quote(cbBtc, usdc, 1e8, 30_000e6, 30 days, SPARK_LEND, 1 << SPARK_LEND);
        quote.fixedRate = 0;
        quote.bond = blm.bondRequirement(quote);
        address pod = _openLoan(quote);

        _forward(2 days);

        (, uint256 venueDebtBefore) = sparkLendAdapter.positionAssets(pod, cbBtc, usdc, "");
        uint256 receiverBalanceBefore = usdc.balanceOf(receiver);
        uint256 seized = iris.liquidateBond(pod, receiver);

        assertEq(usdc.balanceOf(receiver) - receiverBalanceBefore, seized);
        (, uint256 venueDebt) = sparkLendAdapter.positionAssets(pod, cbBtc, usdc, "");
        assertLe(venueDebt, venueDebtBefore);
        Position memory pos = iris.getPosition(pod);
        assertEq(pos.debt, 0);
        assertEq(pos.bondRequirement, 0);

        // The loan is resolved for Iris; the borrower closes the variable-rate venue position with escape.
        deal(usdc, borrower, venueDebt);
        vm.startPrank(borrower);
        usdc.safeApproveWithRetry(address(iris), venueDebt);
        iris.escape(pod, receiver);
        vm.stopPrank();
        _assertVenueClosed(pod, cbBtc, usdc);
    }

    function testSparkLendRebaseAfterPartialVenueLiquidation() public {
        uint256 wethPrice = _pinSparkLendPrice(weth);
        // 84% of the collateral's value, under SparkLend's 85% WETH LTV: a 5% drop takes the pod below health factor 1,
        // where SparkLend closes half the debt.
        uint256 debt = wethPrice * 10 * 84 / 10_000; // 10 WETH at an 8-decimal USD price, in 6-decimal USDC
        address pod = _openLoan(_quote(weth, usdc, 10e18, debt, 30 days, SPARK_LEND, 1 << SPARK_LEND));

        _forward(3 days);
        _setSparkLendPrice(weth, wethPrice * 95 / 100);
        (,,,,, uint256 healthFactor) = sparkLendPool.getUserAccountData(pod);
        assertLt(healthFactor, 1e18);

        (uint256 venueCollateral, uint256 venueDebt) = sparkLendAdapter.positionAssets(pod, weth, usdc, "");
        _venueLiquidate(pod, weth, usdc, venueDebt);
        (uint256 newVenueCollateral, uint256 newVenueDebt) = sparkLendAdapter.positionAssets(pod, weth, usdc, "");
        assertLt(newVenueCollateral, venueCollateral);
        assertLt(newVenueDebt, venueDebt);
        assertGt(newVenueDebt, 0);

        Position memory before = iris.getPosition(pod);
        iris.rebase(pod);
        Position memory pos = iris.getPosition(pod);
        assertLt(pos.collateral, before.collateral);
        assertLt(pos.debt, before.debt);
        assertGt(pos.bondRequirement, 0);

        _repay(pod, borrower);
        vm.prank(borrower);
        iris.escape(pod, receiver);
        _assertVenueClosed(pod, weth, usdc);
    }

    function testSparkLendRebaseAfterFullVenueLiquidation() public {
        uint256 wethPrice = _pinSparkLendPrice(weth);
        uint256 debt = wethPrice * 10 * 84 / 10_000;
        address pod = _openLoan(_quote(weth, usdc, 10e18, debt, 30 days, SPARK_LEND, 1 << SPARK_LEND));

        _forward(1 days);
        // After a 20% drop the collateral is worth less than the debt. SparkLend seizes all of it and, unlike Aave
        // v3.6, burns no deficit: the residual debt stays on the pod.
        _setSparkLendPrice(weth, wethPrice * 80 / 100);
        _venueLiquidate(pod, weth, usdc, debt);
        (uint256 venueCollateral, uint256 venueDebt) = sparkLendAdapter.positionAssets(pod, weth, usdc, "");
        assertEq(venueCollateral, 0);
        assertGt(venueDebt, 0);

        iris.rebase(pod);
        assertEq(iris.getPosition(pod).bondRequirement, 0);

        // Anyone can close the residual debt.
        deal(usdc, liquidator, debt);
        vm.startPrank(liquidator);
        usdc.safeApproveWithRetry(address(iris), debt);
        iris.repay(pod);
        vm.stopPrank();
        (, venueDebt) = sparkLendAdapter.positionAssets(pod, weth, usdc, "");
        assertEq(venueDebt, 0);
    }

    /* VENUE FAILURES */

    function testSparkLendStaleOracleBlocksPricedPathsOnly() public {
        address pod = _openLoan(_quote(weth, usdc, 10e18, 5_000e6, 30 days, SPARK_LEND, 1 << SPARK_LEND));

        // No price pinned: 26 hours on, every source behind SparkLend's ETH median is past its 25 h age limit.
        _forward(26 hours);
        bytes memory noPrice = abi.encodeWithSignature("CanNotPickMedianOfEmptyArray()");
        vm.expectRevert(noPrice);
        IPriceOracleGetter(sparkLendOracle).getAssetPrice(weth);

        vm.prank(borrower);
        vm.expectRevert(noPrice);
        iris.withdrawCollateral(pod, 1e18, receiver);

        // Repay and escape read no price, so the borrower can still leave.
        _repay(pod, borrower);
        vm.prank(borrower);
        iris.escape(pod, receiver);
        _assertVenueClosed(pod, weth, usdc);
    }

    function testSparkLendFrozenAndPausedReserves() public {
        address pod = _openLoan(_quote(weth, usdc, 10e18, 5_000e6, 30 days, SPARK_LEND, 1 << SPARK_LEND));
        ISparkLendPoolConfigurator configurator =
            ISparkLendPoolConfigurator(sparkLendPool.ADDRESSES_PROVIDER().getPoolConfigurator());

        // A frozen collateral reserve takes no more supply ("28", RESERVE_FROZEN) but still lets collateral out.
        vm.prank(SPARK_LEND_ADMIN);
        configurator.setReserveFreeze(weth, true);
        deal(weth, borrower, 1e18);
        vm.startPrank(borrower);
        weth.safeApprove(address(iris), 1e18);
        vm.expectRevert(bytes("28"));
        iris.supplyCollateral(pod, 1e18);
        iris.withdrawCollateral(pod, 1e18, receiver);
        vm.stopPrank();

        // A paused debt reserve blocks the repayment ("29", RESERVE_PAUSED) until it is unpaused.
        vm.prank(SPARK_LEND_ADMIN);
        configurator.setReservePause(usdc, true);
        _fundRepay(pod, borrower);
        vm.prank(borrower);
        vm.expectRevert(bytes("29"));
        iris.repay(pod);

        vm.prank(SPARK_LEND_ADMIN);
        configurator.setReservePause(usdc, false);
        vm.prank(borrower);
        iris.repay(pod);
        vm.prank(borrower);
        iris.escape(pod, receiver);
        _assertVenueClosed(pod, weth, usdc);
    }

    /* HELPERS */

    /// @dev Take on SparkLend, top up and withdraw collateral, repay ten days in, then escape.
    function _takeRepayEscape(
        address collateralAsset,
        address debtAsset,
        uint256 collateral,
        uint256 debt,
        uint256 topUp
    ) internal {
        _pinSparkLendPrice(collateralAsset);
        uint256 receiverDebtBefore = debtAsset.balanceOf(receiver);
        address pod =
            _openLoan(_quote(collateralAsset, debtAsset, collateral, debt, 30 days, SPARK_LEND, 1 << SPARK_LEND));

        // The position lives on SparkLend, each leg within its half-up rounding of the quote.
        (uint256 venueCollateral, uint256 venueDebt) =
            sparkLendAdapter.positionAssets(pod, collateralAsset, debtAsset, "");
        assertApproxEqAbs(venueCollateral, collateral, 1);
        assertApproxEqAbs(venueDebt, debt, 1);
        assertEq(debtAsset.balanceOf(receiver) - receiverDebtBefore, debt);

        uint256 receiverCollateralBefore = collateralAsset.balanceOf(receiver);
        deal(collateralAsset, borrower, topUp);
        vm.startPrank(borrower);
        collateralAsset.safeApprove(address(iris), topUp);
        iris.supplyCollateral(pod, topUp);
        iris.withdrawCollateral(pod, 2 * topUp, receiver);
        vm.stopPrank();
        assertEq(collateralAsset.balanceOf(receiver) - receiverCollateralBefore, 2 * topUp);

        _forward(10 days);
        _repay(pod, borrower);

        receiverCollateralBefore = collateralAsset.balanceOf(receiver);
        vm.prank(borrower);
        iris.escape(pod, receiver);
        assertApproxEqAbs(collateralAsset.balanceOf(receiver) - receiverCollateralBefore, collateral - topUp, 2);
        _assertVenueClosed(pod, collateralAsset, debtAsset);
    }

    /// @dev Refinances the WETH/USDC pod from one venue to the other, funded by the solver as in RefinanceForkTest.
    function _refinance(address pod, uint256 fromVenueId, uint256 toVenueId) internal {
        IVenueAdapter fromAdapter = IVenueAdapter(iris.venueAdapter(fromVenueId));
        IVenueAdapter toAdapter = IVenueAdapter(iris.venueAdapter(toVenueId));
        (uint256 venueCollateral, uint256 venueDebt) = fromAdapter.positionAssets(pod, weth, usdc, "");

        deal(usdc, solver, venueDebt);
        vm.startPrank(solver);
        usdc.safeApproveWithRetry(address(iris), venueDebt);
        iris.refinance(pod, solver, toVenueId, "");
        vm.stopPrank();

        (uint256 newVenueCollateral, uint256 newVenueDebt) = toAdapter.positionAssets(pod, weth, usdc, "");
        assertApproxEqAbs(newVenueCollateral, venueCollateral, 2);
        assertApproxEqAbs(newVenueDebt, venueDebt, 2);
        assertEq(usdc.balanceOf(solver), venueDebt);
        (venueCollateral, venueDebt) = fromAdapter.positionAssets(pod, weth, usdc, "");
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
        assertEq(iris.getPosition(pod).venueId, uint8(toVenueId));
    }

    /// @dev A liquidator closes as much of the pod's SparkLend debt as SparkLend allows, outside Iris.
    function _venueLiquidate(address pod, address collateralAsset, address debtAsset, uint256 budget) internal {
        deal(debtAsset, liquidator, budget);
        vm.startPrank(liquidator);
        debtAsset.safeApproveWithRetry(address(sparkLendPool), budget);
        sparkLendPool.liquidationCall(collateralAsset, debtAsset, pod, type(uint256).max, false);
        vm.stopPrank();
    }

    /// @dev Funds `payer` with the exact repay charge, then repays.
    function _repay(address pod, address payer) internal {
        _fundRepay(pod, payer);
        vm.prank(payer);
        iris.repay(pod);
        assertEq(iris.getLoan(pod).debtToken.balanceOf(payer), 0);
    }

    /// @dev Funds and approves the exact repay charge: the accrued legs, the pre-maturity residual _settleLegs adds and
    /// any bad bond, as in RepayForkTest. Iris also gets the pooled balance a live Iris holds, which absorbs the
    /// wei-level gap between its tracked debt and SparkLend's half-up venue debt.
    function _fundRepay(address pod, address payer) internal {
        Loan memory loan = iris.getLoan(pod);
        deal(loan.debtToken, address(iris), loan.debtToken.balanceOf(address(iris)) + MIN_TEST_AMOUNT);

        Position memory pos = iris.getPosition(pod);
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        if (block.timestamp < loan.maturity) {
            fixedLeg += pos.debt
            .mulDivDown((loan.maturity - block.timestamp) * loan.fixedRate * BP, SECONDS_PER_YEAR * WAD);
        }
        uint256 charge = pos.debt + fixedLeg + floatingLeg.zeroFloorSub(fixedLeg).zeroFloorSub(pos.bond);

        deal(loan.debtToken, payer, charge);
        vm.prank(payer);
        loan.debtToken.safeApproveWithRetry(address(iris), charge);
    }

    function _assertVenueClosed(address pod, address collateralAsset, address debtAsset) internal view {
        (uint256 venueCollateral, uint256 venueDebt) =
            sparkLendAdapter.positionAssets(pod, collateralAsset, debtAsset, "");
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
    }

    /// @dev Pins SparkLend's price for `asset` at its current value, so it survives warps past the 25 h age limit.
    function _pinSparkLendPrice(address asset) internal returns (uint256 assetPrice) {
        assetPrice = IPriceOracleGetter(sparkLendOracle).getAssetPrice(asset);
        _setSparkLendPrice(asset, assetPrice);
    }

    function _setSparkLendPrice(address asset, uint256 assetPrice) internal {
        vm.mockCall(sparkLendOracle, abi.encodeCall(IPriceOracleGetter.getAssetPrice, (asset)), abi.encode(assetPrice));
    }

    function _quote(
        address collateralAsset,
        address debtAsset,
        uint256 collateral,
        uint256 debt,
        uint256 duration,
        uint256 venueId_,
        uint256 venueBitmap
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralAsset;
        quote.debtToken = debtAsset;
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = duration;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = 0;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = venueBitmap;
        quote.venueId = venueId_;
        quote.deadline = block.timestamp;
        quote.nonce = 0;
        quote.data = "";
        quote.bond = blm.bondRequirement(quote);
    }
}
