// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

import {MorphoBlueUtils} from "./helpers/MorphoBlueUtils.sol";

contract TakeForkTest is ForkTest {
    using SafeTransferLib for address;

    uint256 internal constant DUST = 2;
    uint256 internal nextNonce;

    // Opens an Aave V3 loan.
    function testTakeAaveV3(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);

        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        address pod = _take(quote);

        _assertOpen(pod, quote, aaveV3Adapter, receiverDebtBefore);
    }

    // Opens a Morpho Blue loan.
    function testTakeMorphoBlue(uint256 collateral, uint256 debt, uint256 seed) public {
        MarketParams memory market = MorphoBlueUtils.randomMarketParams(morphoBlue, seed, config.morphoMarketIdList);

        collateralToken = market.collateralToken;
        debtToken = market.loanToken;
        uint256 venueId = uint256(VenueId.MORPHO_BLUE);
        bytes memory data = abi.encode(market);

        vm.prank(owner);
        blm.setParams(address(debtToken), DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);
        Quote memory quote = _buildQuote(uint256(VenueId.MORPHO_BLUE), data, collateral, debt);

        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        address pod = _take(quote);

        _assertOpen(pod, quote, morphoBlueAdapter, receiverDebtBefore);
    }

    // Opens a loan through an authorized operator supplying the collateral.
    function testTakeAuthorizedOperator(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        address operator = makeAddr("operator");

        vm.prank(quote.borrower);
        iris.setAuthorization(operator, true);

        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        uint256 borrowerCollateralBefore = collateralToken.balanceOf(quote.borrower);

        address pod = _take(quote, operator);

        // The operator paid the collateral; the borrower paid nothing.
        assertEq(collateralToken.balanceOf(operator), 0);
        assertEq(collateralToken.balanceOf(quote.borrower), borrowerCollateralBefore);

        _assertOpen(pod, quote, aaveV3Adapter, receiverDebtBefore);
    }

    // Opens multiple loans for the same intent with different quotes.
    function testTakeMultipleLoans(uint256 collateral, uint256 debt) public {
        Quote memory quote1 = _buildAaveV3Quote(collateral, debt);
        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        address pod1 = _take(quote1);

        Quote memory quote2 = _buildAaveV3Quote(collateral, debt);
        address pod2 = _take(quote2);

        assertTrue(pod1 != pod2);
        assertTrue(quote1.nonce != quote2.nonce);
        assertTrue(iris.isNonceUsed(quote1.solver, quote1.nonce));
        assertTrue(iris.isNonceUsed(quote2.solver, quote2.nonce));

        Loan memory loan1 = iris.getLoan(pod1);
        Loan memory loan2 = iris.getLoan(pod2);
        assertEq(loan1.borrower, quote1.borrower);
        assertEq(loan2.borrower, quote2.borrower);
        assertEq(loan1.solver, quote1.solver);
        assertEq(loan2.solver, quote2.solver);

        Position memory position1 = iris.getPosition(pod1);
        Position memory position2 = iris.getPosition(pod2);
        assertEq(position1.collateral, quote1.collateral);
        assertEq(position2.collateral, quote2.collateral);
        assertEq(position1.debt, quote1.debt);
        assertEq(position2.debt, quote2.debt);
        assertEq(position1.bond, quote1.bond);
        assertEq(position2.bond, quote2.bond);

        (uint256 venueCollateral1, uint256 venueDebt1) =
            aaveV3Adapter.positionAssets(pod1, quote1.collateralToken, quote1.debtToken, quote1.data);
        (uint256 venueCollateral2, uint256 venueDebt2) =
            aaveV3Adapter.positionAssets(pod2, quote2.collateralToken, quote2.debtToken, quote2.data);
        assertApproxEqAbs(venueCollateral1, quote1.collateral, DUST);
        assertApproxEqAbs(venueCollateral2, quote2.collateral, DUST);
        assertApproxEqAbs(venueDebt1, quote1.debt, DUST);
        assertApproxEqAbs(venueDebt2, quote2.debt, DUST);

        assertEq(debtToken.balanceOf(receiver), receiverDebtBefore + quote1.debt + quote2.debt);
        assertEq(debtToken.balanceOf(address(iris)), quote1.bond + quote2.bond);
    }

    /* REVERTS */

    // Reverts opening a venue-unhealthy position, leaving no trace.
    function testRevertTakeVenueUnhealthy(uint256 collateral, uint256 debt) public {
        collateralToken = getAddress("WETH");
        debtToken = getAddress("USDC");
        uint256 venueId = uint256(VenueId.AAVE_V3);
        bytes memory data = "";

        vm.prank(owner);
        blm.setParams(address(debtToken), DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        uint256 maxBorrowCapacity = _maxBorrowable(collateralToken, debtToken, venueId, data);
        uint256 minDebt = _maxBorrowAmount(MIN_TEST_AMOUNT, collateralToken, debtToken, venueId, data) + 1;
        if (minDebt < MIN_TEST_AMOUNT) minDebt = MIN_TEST_AMOUNT;
        vm.assume(maxBorrowCapacity >= minDebt);

        debt = bound(debt, minDebt, maxBorrowCapacity);

        uint256 minHealthyCollateral = _minCollateralAmount(debt, collateralToken, debtToken, venueId, data);
        vm.assume(minHealthyCollateral > MIN_TEST_AMOUNT);

        uint256 maxSupplyCapacity = _maxSuppliable(collateralToken, venueId, data);
        if (maxSupplyCapacity > MAX_TEST_AMOUNT) maxSupplyCapacity = MAX_TEST_AMOUNT;

        uint256 maxCollateral = minHealthyCollateral - 1;
        if (maxCollateral > maxSupplyCapacity) maxCollateral = maxSupplyCapacity;
        vm.assume(maxCollateral >= MIN_TEST_AMOUNT);

        collateral = bound(collateral, MIN_TEST_AMOUNT, maxCollateral);

        Quote memory quote = _buildQuote(venueId, data, collateral, debt);
        bytes memory signature = _signQuote(solverPk, quote);

        deal(quote.collateralToken, quote.borrower, quote.collateral);
        deal(quote.debtToken, quote.solver, quote.bond);

        vm.prank(quote.solver);
        quote.debtToken.safeApprove(address(iris), quote.bond);
        vm.prank(quote.borrower);
        quote.collateralToken.safeApprove(address(iris), quote.collateral);

        uint256 irisNonceBefore = vm.getNonce(address(iris));
        address expectedPod = vm.computeCreateAddress(address(iris), irisNonceBefore);
        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        uint256 irisBondBefore = debtToken.balanceOf(address(iris));

        vm.expectRevert();
        vm.prank(quote.borrower);
        iris.take(quote, signature);

        assertEq(ERC20(quote.collateralToken).allowance(quote.borrower, address(iris)), quote.collateral);
        assertEq(ERC20(quote.debtToken).allowance(quote.solver, address(iris)), quote.bond);
        assertFalse(iris.isNonceUsed(quote.solver, quote.nonce));
        assertEq(vm.getNonce(address(iris)), irisNonceBefore);
        assertEq(expectedPod.code.length, 0);
        assertEq(debtToken.balanceOf(receiver), receiverDebtBefore);
        assertEq(debtToken.balanceOf(address(iris)), irisBondBefore);
        assertEq(collateralToken.balanceOf(quote.borrower), quote.collateral);
        assertEq(debtToken.balanceOf(quote.solver), quote.bond);

        (uint256 venueCollateral, uint256 venueDebt) =
            aaveV3Adapter.positionAssets(expectedPod, quote.collateralToken, quote.debtToken, data);
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
    }

    // Reverts unauthorized take caller.
    function testRevertTakeUnauthorized(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        bytes memory signature = _signQuote(solverPk, quote);

        address unauthorizer = makeAddr("unauthorizer");
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(unauthorizer);
        iris.take(quote, signature);

        assertFalse(iris.isNonceUsed(quote.solver, quote.nonce));
    }

    /* HELPERS */

    function _buildAaveV3Quote(uint256 collateral, uint256 debt) internal returns (Quote memory quote) {
        collateralToken = getAddress("WETH");
        debtToken = getAddress("USDC");
        uint256 venueId = uint256(VenueId.AAVE_V3);
        bytes memory data = "";

        vm.prank(owner);
        blm.setParams(address(debtToken), DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(collateralToken, debtToken, collateral, debt, venueId, data);
        return _buildQuote(uint256(VenueId.AAVE_V3), data, collateral, debt);
    }

    function _take(Quote memory quote) internal returns (address pod) {
        pod = _take(quote, quote.borrower);
    }

    /// @dev Funds and approves exactly, takes as `caller`, and checks both approvals were fully consumed.
    function _take(Quote memory quote, address caller) internal returns (address pod) {
        bytes memory signature = _signQuote(solverPk, quote);

        deal(quote.collateralToken, caller, quote.collateral);
        deal(quote.debtToken, quote.solver, quote.bond);

        vm.prank(quote.solver);
        quote.debtToken.safeApprove(address(iris), quote.bond);

        vm.startPrank(caller);
        quote.collateralToken.safeApprove(address(iris), quote.collateral);
        pod = iris.take(quote, signature);
        vm.stopPrank();

        assertEq(ERC20(quote.collateralToken).allowance(caller, address(iris)), 0);
        assertEq(ERC20(quote.debtToken).allowance(quote.solver, address(iris)), 0);
    }

    function _buildQuote(uint256 venueId, bytes memory data, uint256 collateral, uint256 debt)
        internal
        returns (Quote memory quote)
    {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = address(collateralToken);
        quote.debtToken = address(debtToken);
        quote.collateral = collateral;
        quote.debt = debt;
        quote.fixedRate = 0.05e18;
        quote.duration = 30 days;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = 7 days;
        quote.bond = blm.bondRequirement(quote);
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 3;
        quote.venueId = venueId;
        quote.deadline = block.timestamp;
        quote.nonce = nextNonce++;
        quote.data = data;
    }

    function _assertOpen(address pod, Quote memory quote, IVenueAdapter adapter, uint256 receiverDebtBefore)
        internal
        view
    {
        assertTrue(iris.isNonceUsed(quote.solver, quote.nonce));

        Loan memory loan = iris.getLoan(pod);
        assertEq(loan.borrower, quote.borrower);
        assertEq(loan.solver, quote.solver);
        assertEq(loan.collateralToken, quote.collateralToken);
        assertEq(loan.debtToken, quote.debtToken);
        assertEq(loan.venueBitmap, quote.venueBitmap);
        assertEq(loan.maturity, block.timestamp + quote.duration);
        assertEq(loan.overduePeriod, quote.overduePeriod);
        assertEq(loan.fixedRate, quote.fixedRate / BP);
        assertEq(loan.overdueRate, quote.overdueRate / BP);
        assertEq(loan.bondLltv, quote.bondLltv / BP);
        assertEq(loan.fee, iris.fee());

        Position memory position = iris.getPosition(pod);
        assertEq(position.collateral, quote.collateral);
        assertEq(position.debt, quote.debt);
        assertEq(position.bond, quote.bond);
        assertEq(position.bondRequirement, blm.bondRequirement(quote));
        assertGt(position.collateralIndex, 0);
        assertGt(position.debtIndex, 0);
        assertEq(position.fixedLeg, 0);
        assertEq(position.floatingLeg, 0);
        assertEq(position.surplus, 0);
        assertEq(position.lastUpdate, block.timestamp);
        assertEq(position.venueId, uint8(quote.venueId));
        assertEq(position.data, quote.data);

        (uint256 venueCollateral, uint256 venueDebt) =
            adapter.positionAssets(pod, quote.collateralToken, quote.debtToken, quote.data);
        assertApproxEqAbs(venueCollateral, quote.collateral, DUST);
        assertApproxEqAbs(venueDebt, quote.debt, DUST);

        assertEq(quote.debtToken.balanceOf(receiver), receiverDebtBefore + quote.debt);
        assertEq(quote.debtToken.balanceOf(address(iris)), quote.bond);
        assertEq(quote.collateralToken.balanceOf(pod), 0);
        assertEq(quote.debtToken.balanceOf(pod), 0);
    }
}
