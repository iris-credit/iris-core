// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {ErrorsLib} from "../../../src/periphery/libraries/ErrorsLib.sol";
import {StorageUtils} from "../../unit/helpers/StorageUtils.sol";
import {VenueAdapterMock} from "../../unit/helpers/mocks/VenueAdapterMock.sol";
import {BlmMock} from "../../unit/helpers/mocks/BlmMock.sol";

import "../helpers/PeripheryUnitTest.sol";

contract IrisAdapterUnitTest is PeripheryUnitTest {
    using SafeTransferLib for address;

    uint256 internal constant LOAN_DURATION = 30 days;

    address internal immutable USER = makeAddr("User");
    address internal immutable RECEIVER = makeAddr("Receiver");

    function setUp() public override {
        super.setUp();

        // The initiator stages funds through the adapter in every flow.
        vm.startPrank(borrower);
        collateralToken.safeApprove(address(generalAdapter1), type(uint256).max);
        debtToken.safeApprove(address(generalAdapter1), type(uint256).max);
        vm.stopPrank();
    }

    /* TAKE */

    function testIrisTake(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (Quote memory quote, bytes memory signature) = _signedQuote(collateral, debt, bond);

        deal(collateralToken, borrower, collateral);
        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_erc20TransferFrom(collateralToken, collateral));
        bundle.push(_irisTake(quote, signature));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        Loan memory loan = iris.getLoan(pod);
        assertEq(loan.borrower, borrower, "loan.borrower");
        assertEq(loan.solver, solver, "loan.solver");

        Position memory position = iris.getPosition(pod);
        assertEq(position.collateral, collateral, "position.collateral");
        assertEq(position.debt, debt, "position.debt");
        assertEq(position.bond, bond, "position.bond");

        assertEq(ERC20(collateralToken).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
        assertEq(ERC20(collateralToken).balanceOf(pod), collateral, "collateral.balanceOf(pod)");
        assertEq(ERC20(debtToken).balanceOf(address(iris)), bond, "debt.balanceOf(iris)");
    }

    /// @dev Opening a loan for another borrower is allowed: the staged collateral accrues to the
    /// borrower, so it is a donation.
    function testIrisTakeOnBehalf(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (Quote memory quote, bytes memory signature) = _signedQuote(collateral, debt, bond);

        vm.prank(borrower);
        iris.setAuthorization(address(generalAdapter1), true);

        deal(collateralToken, USER, collateral);
        vm.prank(USER);
        collateralToken.safeApprove(address(generalAdapter1), type(uint256).max);

        address pod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        bundle.push(_erc20TransferFrom(collateralToken, collateral));
        bundle.push(_irisTake(quote, signature));

        vm.prank(USER);
        bundler3.multicall(bundle);

        assertEq(iris.getLoan(pod).borrower, borrower, "loan.borrower");
        assertEq(ERC20(collateralToken).balanceOf(USER), 0, "collateral.balanceOf(USER)");
    }

    /* REPAY */

    function testIrisRepay(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod, Quote memory quote) = _openLoan(collateral, debt, bond);

        deal(debtToken, borrower, debt);

        bundle.push(_erc20TransferFrom(debtToken, debt));
        bundle.push(_irisRepay(pod, debtToken));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        Position memory position = iris.getPosition(pod);
        assertEq(position.debt, 0, "position.debt");
        assertEq(position.bondRequirement, 0, "position.bondRequirement");
        assertEq(ERC20(debtToken).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");
        // The staged debt funds the pod's venue repayment, so Iris nets to the bond it already held.
        assertEq(ERC20(debtToken).balanceOf(address(iris)), quote.bond, "debt.balanceOf(iris)");
        assertEq(ERC20(debtToken).balanceOf(pod), debt, "debt.balanceOf(pod)");
    }

    /* COLLATERAL MANAGEMENT */

    function testIrisSupplyCollateral(uint256 collateral, uint256 debt, uint256 bond, uint256 amount) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        (address pod,) = _openLoan(collateral, debt, bond);

        deal(collateralToken, borrower, amount);

        bundle.push(_erc20TransferFrom(collateralToken, amount));
        bundle.push(_irisSupplyCollateral(pod, collateralToken, amount));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).collateral, collateral + amount, "position.collateral");
        assertEq(ERC20(collateralToken).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
    }

    function testIrisSupplyCollateralMax(uint256 collateral, uint256 debt, uint256 bond, uint256 amount) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        (address pod,) = _openLoan(collateral, debt, bond);

        deal(collateralToken, borrower, amount);

        bundle.push(_erc20TransferFrom(collateralToken, amount));
        bundle.push(_irisSupplyCollateral(pod, collateralToken, type(uint256).max));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).collateral, collateral + amount, "position.collateral");
        assertEq(ERC20(collateralToken).balanceOf(address(generalAdapter1)), 0, "collateral.balanceOf(adapter)");
    }

    function testIrisSupplyCollateralZero(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        bundle.push(_irisSupplyCollateral(pod, collateralToken, 0));

        vm.prank(borrower);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testIrisWithdrawCollateral(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        // Withdrawable under the health check: lltv 0.8 and price 1 leave collateral - debt / 0.8 headroom.
        uint256 amount = MIN_TEST_AMOUNT / 2;

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 1, false));
        bundle.push(_irisWithdrawCollateral(pod, amount, RECEIVER));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).collateral, collateral - amount, "position.collateral");
    }

    function testIrisWithdrawCollateralUnauthorizedInitiator(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        bundle.push(_irisWithdrawCollateral(pod, MIN_TEST_AMOUNT / 2, RECEIVER));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.UnauthorizedInitiator.selector);
        bundler3.multicall(bundle);
    }

    /* BOND MANAGEMENT */

    function testIrisSupplyBond(uint256 collateral, uint256 debt, uint256 bond, uint256 amount) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        (address pod,) = _openLoan(collateral, debt, bond);

        deal(debtToken, borrower, amount);

        bundle.push(_erc20TransferFrom(debtToken, amount));
        bundle.push(_irisSupplyBond(pod, debtToken, amount));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).bond, bond + amount, "position.bond");
        assertEq(ERC20(debtToken).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");
    }

    function testIrisSupplyBondMax(uint256 collateral, uint256 debt, uint256 bond, uint256 amount) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        (address pod,) = _openLoan(collateral, debt, bond);

        deal(debtToken, borrower, amount);

        bundle.push(_erc20TransferFrom(debtToken, amount));
        bundle.push(_irisSupplyBond(pod, debtToken, type(uint256).max));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).bond, bond + amount, "position.bond");
        assertEq(ERC20(debtToken).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");
    }

    function testIrisSupplyBondZero(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        bundle.push(_irisSupplyBond(pod, debtToken, 0));

        vm.prank(borrower);
        vm.expectRevert(ErrorsLib.ZeroAmount.selector);
        bundler3.multicall(bundle);
    }

    function testIrisWithdrawBond(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        // Stays healthy: the mock bond requirement is half the bond.
        uint256 amount = bond / 4;

        // The solver's nonce 0 was consumed by the quote.
        bundle.push(_irisSetAuthorizationWithSig(solverPk, true, 1, false));
        bundle.push(_irisWithdrawBond(pod, amount, RECEIVER));

        vm.prank(solver);
        bundler3.multicall(bundle);

        assertEq(iris.getPosition(pod).bond, bond - amount, "position.bond");
        assertEq(ERC20(debtToken).balanceOf(RECEIVER), amount, "debt.balanceOf(RECEIVER)");
    }

    function testIrisWithdrawBondUnauthorizedInitiator(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        bundle.push(_irisWithdrawBond(pod, bond / 4, RECEIVER));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.UnauthorizedInitiator.selector);
        bundler3.multicall(bundle);
    }

    /* VENUE MANAGEMENT */

    function testIrisRefinance(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);
        bytes memory newData = _enableNewVenue();

        deal(debtToken, solver, debt);
        vm.prank(solver);
        debtToken.safeApprove(address(generalAdapter1), type(uint256).max);

        // The solver's nonce 0 was consumed by the quote.
        bundle.push(_irisSetAuthorizationWithSig(solverPk, true, 1, false));
        bundle.push(_erc20TransferFrom(debtToken, debt));
        bundle.push(_irisRefinance(pod, RECEIVER, 1, newData));

        vm.prank(solver);
        bundler3.multicall(bundle);

        Position memory position = iris.getPosition(pod);
        assertEq(position.venueId, 1, "position.venueId");
        assertEq(position.data, newData, "position.data");
    }

    function testIrisRefinanceUnauthorizedInitiator(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);
        bytes memory newData = _enableNewVenue();

        bundle.push(_irisRefinance(pod, RECEIVER, 1, newData));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.UnauthorizedInitiator.selector);
        bundler3.multicall(bundle);
    }

    function testIrisEscape(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        // A resolved loan (zero bond requirement) is escapable by the borrower.
        StorageUtils.setPositionBondRequirement(address(iris), pod, 0);

        deal(debtToken, borrower, debt);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 1, false));
        bundle.push(_erc20TransferFrom(debtToken, debt));
        bundle.push(_irisEscape(pod, RECEIVER));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        Position memory position = iris.getPosition(pod);
        assertEq(position.collateral, 0, "position.collateral");
        assertEq(position.debt, 0, "position.debt");
        assertEq(ERC20(debtToken).balanceOf(address(generalAdapter1)), 0, "debt.balanceOf(adapter)");
    }

    function testIrisEscapeUnauthorizedInitiator(uint256 collateral, uint256 debt, uint256 bond) public {
        (collateral, debt, bond) = _boundQuoteAmounts(collateral, debt, bond);
        (address pod,) = _openLoan(collateral, debt, bond);

        StorageUtils.setPositionBondRequirement(address(iris), pod, 0);

        bundle.push(_irisEscape(pod, RECEIVER));

        vm.prank(USER);
        vm.expectRevert(ErrorsLib.UnauthorizedInitiator.selector);
        bundler3.multicall(bundle);
    }

    /* INTEREST */

    function testIrisClaim(uint256 amount) public {
        amount = bound(amount, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);

        StorageUtils.setClaimable(address(iris), debtToken, borrower, amount);
        deal(debtToken, address(iris), amount);

        bundle.push(_irisSetAuthorizationWithSig(borrowerPk, true, 0, false));
        bundle.push(_irisClaim(debtToken, amount, RECEIVER));

        vm.prank(borrower);
        bundler3.multicall(bundle);

        assertEq(iris.claimable(debtToken, borrower), 0, "claimable(borrower)");
        assertEq(ERC20(debtToken).balanceOf(RECEIVER), amount, "debt.balanceOf(RECEIVER)");
    }

    /* ACCESS */

    function testIrisTakeUnauthorized() public {
        Quote memory quote;

        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisTake(quote, hex"");
    }

    function testIrisRepayUnauthorized(address pod) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisRepay(pod, debtToken);
    }

    function testIrisSupplyCollateralUnauthorized(address pod, uint256 amount) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisSupplyCollateral(pod, collateralToken, amount);
    }

    function testIrisWithdrawCollateralUnauthorized(address pod, uint256 amount) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisWithdrawCollateral(pod, amount, RECEIVER);
    }

    function testIrisSupplyBondUnauthorized(address pod, uint256 amount) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisSupplyBond(pod, debtToken, amount);
    }

    function testIrisWithdrawBondUnauthorized(address pod, uint256 amount) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisWithdrawBond(pod, amount, RECEIVER);
    }

    function testIrisRefinanceUnauthorized(address pod) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisRefinance(pod, RECEIVER, 1, "");
    }

    function testIrisEscapeUnauthorized(address pod) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisEscape(pod, RECEIVER);
    }

    function testIrisClaimUnauthorized(uint256 amount) public {
        vm.expectRevert(ErrorsLib.UnauthorizedSender.selector);
        generalAdapter1.irisClaim(debtToken, amount, RECEIVER);
    }

    /* HELPERS */

    /// @dev Bounds quote amounts so the position stays healthy (lltv 0.8, price 1) with withdraw headroom.
    function _boundQuoteAmounts(uint256 collateral, uint256 debt, uint256 bond)
        internal
        pure
        returns (uint256, uint256, uint256)
    {
        collateral = bound(collateral, MIN_TEST_AMOUNT * 10, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, collateral / 2);
        bond = bound(bond, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        return (collateral, debt, bond);
    }

    function _signedQuote(uint256 collateral, uint256 debt, uint256 bond)
        internal
        returns (Quote memory quote, bytes memory signature)
    {
        BlmMock(address(blm)).setBondRequirement(bond / 2 + 1);

        quote = Quote({
            borrower: borrower,
            solver: solver,
            receiver: receiver,
            blm: address(blm),
            collateralToken: collateralToken,
            debtToken: debtToken,
            collateral: collateral,
            debt: debt,
            fixedRate: 0,
            duration: LOAN_DURATION,
            overdueRate: 0,
            overduePeriod: 0,
            bond: bond,
            bondLltv: bondLltv,
            venueBitmap: 3,
            venueId: 0,
            deadline: block.timestamp,
            nonce: 0,
            data: ""
        });
        signature = _signQuote(solverPk, quote);

        deal(debtToken, solver, bond);
        vm.prank(solver);
        debtToken.safeApprove(address(iris), bond);
    }

    /// @dev Opens a loan directly (outside a bundle) and mirrors it on the venue mock so rebase no-ops.
    function _openLoan(uint256 collateral, uint256 debt, uint256 bond)
        internal
        returns (address pod, Quote memory quote)
    {
        bytes memory signature;
        (quote, signature) = _signedQuote(collateral, debt, bond);

        deal(collateralToken, borrower, collateral);

        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), collateral);
        pod = iris.take(quote, signature);
        vm.stopPrank();

        VenueAdapterMock(address(venueAdapter)).setPosition(collateral, debt);
    }

    /// @dev Registers a second venue mock and enables its market data; returns the new data.
    function _enableNewVenue() internal returns (bytes memory newData) {
        newData = "0xHenlo";

        VenueAdapterMock newAdapter = new VenueAdapterMock();
        newAdapter.setLltv(DEFAULT_TEST_LLTV);
        newAdapter.setPrice(ORACLE_PRICE_SCALE);

        vm.startPrank(owner);
        iris.setVenueAdapter(1, address(newAdapter));
        iris.enableData(keccak256(newData));
        vm.stopPrank();
    }
}
