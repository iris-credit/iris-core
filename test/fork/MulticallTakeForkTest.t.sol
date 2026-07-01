// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../ForkTest.t.sol";

import {MarketParams} from "@morpho-blue/interfaces/IMorpho.sol";

import {MorphoBlueUtils} from "./helpers/MorphoBlueUtils.sol";
import {IPermit2, PermitUtils} from "./helpers/PermitUtils.sol";

contract MulticallTakeForkTest is ForkTest {
    using SafeTransferLib for address;

    uint256 internal constant DUST = 2;
    uint256 internal nextNonce;

    // Opens an Aave V3 loan through a multicall.
    function testMulticallTakeAaveV3(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);

        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        address pod = _multicall(quote);

        _assertOpen(pod, quote, aaveV3Adapter, receiverDebtBefore);
    }

    // Opens a Morpho Blue loan through a multicall.
    function testMulticallTakeMorphoBlue(uint256 collateral, uint256 debt, uint256 seed) public {
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
        address pod = _multicall(quote);

        _assertOpen(pod, quote, morphoBlueAdapter, receiverDebtBefore);
    }

    // Opens a loan through an authorized operator multicall.
    function testMulticallTakeAuthorizedOperator(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        (address operator, uint256 operatorPk) = makeAddrAndKey("operator");

        vm.prank(quote.borrower);
        iris.setAuthorization(operator, true);

        bytes[] memory calls = _buildMulticall(quote, operator, operatorPk);

        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));
        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        uint256 operatorCollateralBefore = collateralToken.balanceOf(operator);
        uint256 borrowerCollateralBefore = collateralToken.balanceOf(quote.borrower);

        vm.prank(operator);
        iris.multicall(calls);

        (uint160 operatorAllowance,,) =
            IPermit2(PermitUtils.PERMIT2).allowance(operator, quote.collateralToken, address(iris));
        (uint160 solverAllowance,,) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));
        assertEq(operatorAllowance, 0);
        assertEq(solverAllowance, 0);

        assertEq(collateralToken.balanceOf(operator), operatorCollateralBefore - quote.collateral);
        assertEq(collateralToken.balanceOf(quote.borrower), borrowerCollateralBefore);

        _assertOpen(pod, quote, aaveV3Adapter, receiverDebtBefore);
    }

    // Opens multiple loans.
    function testMulticallTakeMultipleLoans(uint256 collateral, uint256 debt) public {
        Quote memory quote1 = _buildAaveV3Quote(collateral, debt);
        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        address pod1 = _multicall(quote1);

        Quote memory quote2 = _buildAaveV3Quote(collateral, debt);
        address pod2 = _multicall(quote2);

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

    // Reverts after opening a venue-unhealthy position and rolls back the multicall.
    function testRevertMulticallTake(uint256 collateral, uint256 debt) public {
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
        bytes[] memory calls = _buildMulticall(quote);

        (uint160 borrowerAllowanceBefore, uint48 borrowerExpirationBefore, uint48 borrowerPermitNonceBefore) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.borrower, quote.collateralToken, address(iris));
        (uint160 solverAllowanceBefore, uint48 solverExpirationBefore, uint48 solverPermitNonceBefore) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));
        uint256 irisNonceBefore = vm.getNonce(address(iris));
        address expectedPod = vm.computeCreateAddress(address(iris), irisNonceBefore);
        uint256 receiverDebtBefore = debtToken.balanceOf(receiver);
        uint256 irisBondBefore = debtToken.balanceOf(address(iris));
        uint256 borrowerCollateralBefore = collateralToken.balanceOf(quote.borrower);
        uint256 solverDebtBefore = debtToken.balanceOf(quote.solver);

        vm.expectRevert();
        vm.prank(quote.borrower);
        iris.multicall(calls);

        (uint160 borrowerAllowanceAfter, uint48 borrowerExpirationAfter, uint48 borrowerPermitNonceAfter) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.borrower, quote.collateralToken, address(iris));
        (uint160 solverAllowanceAfter, uint48 solverExpirationAfter, uint48 solverPermitNonceAfter) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));

        assertEq(borrowerAllowanceAfter, borrowerAllowanceBefore);
        assertEq(borrowerExpirationAfter, borrowerExpirationBefore);
        assertEq(borrowerPermitNonceAfter, borrowerPermitNonceBefore);
        assertEq(solverAllowanceAfter, solverAllowanceBefore);
        assertEq(solverExpirationAfter, solverExpirationBefore);
        assertEq(solverPermitNonceAfter, solverPermitNonceBefore);
        assertFalse(iris.isNonceUsed(quote.solver, quote.nonce));
        assertEq(vm.getNonce(address(iris)), irisNonceBefore);
        assertEq(expectedPod.code.length, 0);
        assertEq(debtToken.balanceOf(receiver), receiverDebtBefore);
        assertEq(debtToken.balanceOf(address(iris)), irisBondBefore);
        assertEq(collateralToken.balanceOf(quote.borrower), borrowerCollateralBefore);
        assertEq(debtToken.balanceOf(quote.solver), solverDebtBefore);

        (uint256 venueCollateral, uint256 venueDebt) =
            aaveV3Adapter.positionAssets(expectedPod, quote.collateralToken, quote.debtToken, data);
        assertEq(venueCollateral, 0);
        assertEq(venueDebt, 0);
    }

    // Reverts unauthorized multicall caller.
    function testRevertMulticallTakeUnauthorized(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        bytes[] memory calls = _buildMulticall(quote);

        (uint160 borrowerAllowanceBefore, uint48 borrowerExpirationBefore, uint48 borrowerPermitNonceBefore) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.borrower, quote.collateralToken, address(iris));
        (uint160 solverAllowanceBefore, uint48 solverExpirationBefore, uint48 solverPermitNonceBefore) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));

        address unauthorizer = makeAddr("unauthorizer");
        vm.expectRevert(IIris.Unauthorized.selector);
        vm.prank(unauthorizer);
        iris.multicall(calls);

        (uint160 borrowerAllowanceAfter, uint48 borrowerExpirationAfter, uint48 borrowerPermitNonceAfter) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.borrower, quote.collateralToken, address(iris));
        (uint160 solverAllowanceAfter, uint48 solverExpirationAfter, uint48 solverPermitNonceAfter) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));

        assertEq(borrowerAllowanceAfter, borrowerAllowanceBefore);
        assertEq(borrowerExpirationAfter, borrowerExpirationBefore);
        assertEq(borrowerPermitNonceAfter, borrowerPermitNonceBefore);
        assertEq(solverAllowanceAfter, solverAllowanceBefore);
        assertEq(solverExpirationAfter, solverExpirationBefore);
        assertEq(solverPermitNonceAfter, solverPermitNonceBefore);
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

    function _multicall(Quote memory quote) internal returns (address pod) {
        bytes[] memory calls = _buildMulticall(quote);
        pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        vm.prank(quote.borrower);
        iris.multicall(calls);

        (uint160 borrowerAllowance,,) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.borrower, quote.collateralToken, address(iris));
        (uint160 solverAllowance,,) =
            IPermit2(PermitUtils.PERMIT2).allowance(quote.solver, quote.debtToken, address(iris));

        assertEq(borrowerAllowance, 0);
        assertEq(solverAllowance, 0);
    }

    function _buildMulticall(Quote memory quote) internal returns (bytes[] memory data) {
        return _buildMulticall(quote, quote.borrower, borrowerPk);
    }

    function _buildMulticall(Quote memory quote, address caller, uint256 callerPk)
        internal
        returns (bytes[] memory calls)
    {
        bytes memory quoteSignature = _signQuote(solverPk, quote);
        uint256 permitDeadline = quote.deadline;

        deal(quote.collateralToken, caller, quote.collateral);
        deal(quote.debtToken, quote.solver, quote.bond);

        vm.prank(caller);
        quote.collateralToken.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        vm.prank(quote.solver);
        quote.debtToken.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        (uint8 callerV, bytes32 callerR, bytes32 callerS) =
            _signPermit2(callerPk, caller, quote.collateralToken, quote.collateral, permitDeadline);
        (uint8 solverV, bytes32 solverR, bytes32 solverS) =
            _signPermit2(solverPk, quote.solver, quote.debtToken, quote.bond, permitDeadline);

        calls = new bytes[](3);
        calls[0] = abi.encodeCall(
            IIris.permit2, (quote.collateralToken, caller, quote.collateral, permitDeadline, callerV, callerR, callerS)
        );
        calls[1] = abi.encodeCall(
            IIris.permit2, (quote.debtToken, quote.solver, quote.bond, permitDeadline, solverV, solverR, solverS)
        );
        calls[2] = abi.encodeCall(IIris.take, (quote, quoteSignature));
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

    function _signPermit2(uint256 privateKey, address signer, address token, uint256 amount, uint256 sigDeadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        require(amount <= type(uint160).max, "MulticallTakeForkTest: Permit2 amount overflow");

        (,, uint48 nonce) = IPermit2(PermitUtils.PERMIT2).allowance(signer, token, address(iris));
        bytes32 digest = PermitUtils.getTypedDataHash(
            IPermit2(PermitUtils.PERMIT2).DOMAIN_SEPARATOR(),
            token,
            uint160(amount),
            type(uint48).max,
            nonce,
            address(iris),
            sigDeadline
        );

        (v, r, s) = vm.sign(privateKey, digest);
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
