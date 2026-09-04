// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";
import {StorageUtils} from "../../unit/helpers/StorageUtils.sol";
import {MorphoBlueUtils} from "../../fork/helpers/MorphoBlueUtils.sol";

import "../helpers/PeripheryForkTest.sol";

contract IrisAdapterForkTest is PeripheryForkTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    address internal immutable RECEIVER = makeAddr("Receiver");

    address internal wEth;
    address internal usdc;

    function setUp() public override {
        super.setUp();

        wEth = getAddress("WETH");
        usdc = getAddress("USDC");

        vm.prank(owner);
        blm.setParams(usdc, DEFAULT_SLOPE, DEFAULT_INTERCEPT);
    }

    /* TAKE */

    function testTake(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        bytes memory signature = _signQuote(solverPk, quote);
        _fundSolverBond(quote);

        deal(wEth, borrower, quote.collateral);
        vm.prank(borrower);
        wEth.safeApprove(address(generalAdapter1), quote.collateral);

        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));
        uint256 receiverDebtBefore = ERC20(usdc).balanceOf(receiver);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_erc20TransferFrom(wEth, quote.collateral));
        bundle.push(_irisTake(quote, signature));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getLoan(pod).borrower, borrower, "loan.borrower");
        assertEq(iris.getPosition(pod).collateral, quote.collateral, "position.collateral");
        assertEq(ERC20(usdc).balanceOf(receiver), receiverDebtBefore + quote.debt, "debt.balanceOf(receiver)");
        assertEq(ERC20(wEth).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
    }

    function testTakeWithPermit2(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        bytes memory signature = _signQuote(solverPk, quote);
        _fundSolverBond(quote);

        // The borrower only holds the universal Permit2 approval; the per-take allowance is granted by
        // signature inside the bundle.
        deal(wEth, borrower, quote.collateral);
        vm.prank(borrower);
        wEth.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_approve2(borrowerPk, wEth, quote.collateral, 0, false));
        bundle.push(_permit2TransferFrom(wEth, quote.collateral));
        bundle.push(_irisTake(quote, signature));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getLoan(pod).borrower, borrower, "loan.borrower");
        assertEq(ERC20(wEth).balanceOf(borrower), 0, "collateral.balanceOf(borrower)");
        assertEq(ERC20(wEth).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
    }

    function testTakeWithSolverPermit2(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        bytes memory signature = _signQuote(solverPk, quote);

        // The solver only holds the universal Permit2 approval; the bond allowance for Iris is granted
        // by a signature submitted inside the bundle, as a direct call to canonical Permit2.
        deal(usdc, solver, quote.bond);
        vm.prank(solver);
        usdc.safeApprove(PermitUtils.PERMIT2, type(uint256).max);

        deal(wEth, borrower, quote.collateral);
        vm.prank(borrower);
        wEth.safeApprove(address(generalAdapter1), quote.collateral);

        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        bundle.push(_approve2(solverPk, usdc, quote.bond, 0, address(iris), false));
        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_erc20TransferFrom(wEth, quote.collateral));
        bundle.push(_irisTake(quote, signature));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getLoan(pod).borrower, borrower, "loan.borrower");
        assertEq(iris.getPosition(pod).bond, quote.bond, "position.bond");
        assertEq(ERC20(usdc).balanceOf(solver), 0, "debt.balanceOf(solver)");
        // The bond flowed through Permit2: no direct allowance existed and the in-bundle one is consumed.
        assertEq(ERC20(usdc).allowance(solver, address(iris)), 0, "direct allowance");
        (uint160 permit2Allowance,,) = IPermit2(PermitUtils.PERMIT2).allowance(solver, usdc, address(iris));
        assertEq(permit2Allowance, 0, "permit2 allowance");
    }

    /* REPAY */

    function testRepay(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        address pod = _openLoan(quote);

        // The repaid amount includes the fixed leg through maturity, so stage a buffer and sweep back.
        uint256 staged = quote.debt * 2;
        deal(usdc, borrower, staged);
        vm.prank(borrower);
        usdc.safeApprove(address(generalAdapter1), staged);

        bundle.push(_erc20TransferFrom(usdc, staged));
        bundle.push(_irisRepay(pod, usdc));
        bundle.push(_erc20Transfer(usdc, borrower, type(uint256).max, generalAdapter1));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        Position memory position = iris.getPosition(pod);
        assertEq(position.debt, 0, "position.debt");
        assertEq(position.bondRequirement, 0, "position.bondRequirement");
        assertEq(ERC20(usdc).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");

        // The sweep returned everything above the actual repaid amount.
        uint256 repaid = staged - ERC20(usdc).balanceOf(borrower);
        assertGe(repaid, quote.debt, "repaid >= debt");
        assertLt(repaid, staged, "leftover swept");
    }

    /* COLLATERAL MANAGEMENT */

    function testWithdrawCollateralToNative(uint256 collateral, uint256 debt, uint256 amount) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);

        uint256 minCollateral = _minCollateralAmount(quote.debt, wEth, usdc, quote.venueId, quote.data);
        vm.assume(quote.collateral / 2 > minCollateral);
        amount = bound(amount, 1, quote.collateral / 2 - minCollateral + 1);

        address pod = _openLoan(quote);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_irisWithdrawCollateral(pod, amount, address(generalAdapter1)));
        bundle.push(_unwrapNative(type(uint256).max, borrower));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(borrower.balance, amount, "borrower.balance");
        assertEq(iris.getPosition(pod).collateral, quote.collateral - amount, "position.collateral");
        assertEq(ERC20(wEth).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
    }

    /* VENUE MANAGEMENT */

    function testRefinance(uint256 collateral, uint256 debt) public {
        (Quote memory quote, bytes memory morphoData) = _buildHopQuote(collateral, debt);
        address pod = _openLoan(quote);

        (, uint256 venueDebt) = aaveV3Adapter.positionAssets(pod, quote.collateralToken, quote.debtToken, quote.data);

        deal(quote.debtToken, solver, venueDebt);
        vm.prank(solver);
        quote.debtToken.safeApprove(address(generalAdapter1), venueDebt);

        // The solver's nonce 0 was consumed by the quote.
        bundle.push(_irisSetAuthorizationWithSig(solverPk, true, 0, false));
        bundle.push(_erc20TransferFrom(quote.debtToken, venueDebt));
        bundle.push(_irisRefinance(pod, solver, uint256(VenueId.MORPHO_BLUE), morphoData));

        vm.prank(solver);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).venueId, uint8(VenueId.MORPHO_BLUE), "position.venueId");
        // The new venue's borrow reimbursed the solver's fronted float.
        assertEq(ERC20(quote.debtToken).balanceOf(solver), venueDebt, "debt.balanceOf(solver)");
    }

    function testRefinanceWithFlashLoan(uint256 collateral, uint256 debt) public {
        (Quote memory quote, bytes memory morphoData) = _buildHopQuote(collateral, debt);
        address pod = _openLoan(quote);

        (, uint256 venueDebt) = aaveV3Adapter.positionAssets(pod, quote.collateralToken, quote.debtToken, quote.data);
        vm.assume(venueDebt <= ERC20(quote.debtToken).balanceOf(morphoBlue));

        // Capital-free rotation: the flash loan fronts the venue debt, the refinance proceeds return to
        // the adapter, and Morpho reclaims them when the callback returns.
        callbackBundle.push(_irisRefinance(pod, address(generalAdapter1), uint256(VenueId.MORPHO_BLUE), morphoData));

        // The solver's nonce 0 was consumed by the quote.
        bundle.push(_irisSetAuthorizationWithSig(solverPk, true, 0, false));
        bundle.push(_morphoFlashLoan(quote.debtToken, venueDebt));

        vm.prank(solver);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).venueId, uint8(VenueId.MORPHO_BLUE), "position.venueId");
        assertEq(ERC20(quote.debtToken).balanceOf(solver), 0, "debt.balanceOf(solver)");
        assertEq(ERC20(quote.debtToken).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");
    }

    function testEscapeToNative(uint256 collateral, uint256 debt) public {
        Quote memory quote = _buildAaveV3Quote(collateral, debt);
        address pod = _openLoan(quote);

        // A resolved loan (zero bond requirement) is escapable by the borrower.
        StorageUtils.setPositionBondRequirement(address(iris), pod, 0);

        (uint256 venueCollateral, uint256 venueDebt) =
            aaveV3Adapter.positionAssets(pod, quote.collateralToken, quote.debtToken, quote.data);

        deal(usdc, borrower, venueDebt);
        vm.prank(borrower);
        usdc.safeApprove(address(generalAdapter1), venueDebt);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_erc20TransferFrom(usdc, venueDebt));
        bundle.push(_irisEscape(pod, address(generalAdapter1)));
        bundle.push(_unwrapNative(type(uint256).max, borrower));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertApproxEqAbs(borrower.balance, venueCollateral, 2, "borrower.balance");
        assertEq(iris.getPosition(pod).collateral, 0, "position.collateral");
    }

    /* INTEREST */

    function testClaim(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        StorageUtils.setClaimable(address(iris), usdc, borrower, amount);
        deal(usdc, address(iris), amount);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_irisClaim(usdc, amount, RECEIVER));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.claimable(usdc, borrower), 0, "claimable(borrower)");
        assertEq(ERC20(usdc).balanceOf(RECEIVER), amount, "debt.balanceOf(RECEIVER)");
    }

    /* FLASH LOAN */

    function testFlashLoanZero() public {
        callbackBundle.push(_call(address(iris), abi.encodeCall(iris.getLoan, (address(0)))));
        bundle.push(_morphoFlashLoan(usdc, 0));

        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testFlashLoan(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, ERC20(usdc).balanceOf(morphoBlue));

        callbackBundle.push(_call(address(iris), abi.encodeCall(iris.getLoan, (address(0)))));
        bundle.push(_morphoFlashLoan(usdc, amount));

        bundler3.multicall(bundle);

        assertEq(ERC20(usdc).balanceOf(address(generalAdapter1)), 0, "usdc.balanceOf(adapter)");
    }

    /* HELPERS */

    function _buildAaveV3Quote(uint256 collateral, uint256 debt) internal returns (Quote memory quote) {
        (collateral, debt) = _boundHealthyPosition(wEth, usdc, collateral, debt, uint256(VenueId.AAVE_V3), "");
        return _buildQuote(wEth, usdc, collateral, debt, uint256(VenueId.AAVE_V3), "");
    }

    /// @dev Builds a quote on Aave for the first Morpho market whose collateral Aave also supports, so
    /// the loan can hop to Morpho.
    function _buildHopQuote(uint256 collateral, uint256 debt)
        internal
        returns (Quote memory quote, bytes memory morphoData)
    {
        MarketParams memory marketParams;
        bool found;
        for (uint256 i; i < config.morphoMarketIdList.length; i++) {
            marketParams = MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            if (aaveV3Adapter.lltv(marketParams.collateralToken, marketParams.loanToken, "") != 0) {
                found = true;
                break;
            }
        }
        require(found, "IrisAdapterForkTest: no hop market");

        vm.prank(owner);
        blm.setParams(marketParams.loanToken, DEFAULT_SLOPE, DEFAULT_INTERCEPT);

        (collateral, debt) = _boundHealthyPosition(
            marketParams.collateralToken, marketParams.loanToken, collateral, debt, uint256(VenueId.AAVE_V3), ""
        );
        // Cross-venue: bound the debt to the destination's borrowable liquidity as well.
        morphoData = abi.encode(marketParams);
        uint256 maxHopBorrow = _maxBorrowable(
            marketParams.collateralToken, marketParams.loanToken, uint256(VenueId.MORPHO_BLUE), morphoData
        );
        vm.assume(maxHopBorrow >= MIN_TEST_AMOUNT);
        if (debt > maxHopBorrow) debt = maxHopBorrow;
        // Back off the exact borrow-capacity edge: venue rounding (debt up) can overshoot the
        // destination's liquidity by a wei at the boundary, which is not what these tests are about.
        debt -= debt / 100;

        quote = _buildQuote(marketParams.collateralToken, marketParams.loanToken, collateral, debt, 0, "");
    }

    function _buildQuote(
        address collateralToken_,
        address debtToken_,
        uint256 collateral,
        uint256 debt,
        uint256 venueId,
        bytes memory data
    ) internal view returns (Quote memory quote) {
        quote.borrower = borrower;
        quote.solver = solver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken_;
        quote.debtToken = debtToken_;
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
        quote.nonce = 0;
        quote.data = data;
    }

    function _fundSolverBond(Quote memory quote) internal {
        deal(quote.debtToken, solver, quote.bond);
        vm.prank(solver);
        quote.debtToken.safeApprove(address(iris), quote.bond);
    }
}
