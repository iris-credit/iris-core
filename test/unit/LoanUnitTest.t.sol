// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../UnitTest.t.sol";

import {EventsLib} from "../../src/libraries/EventsLib.sol";
import {StorageUtils} from "./helpers/StorageUtils.sol";
import {VenueAdapterMock} from "./helpers/mocks/VenueAdapterMock.sol";
import {BlmMock} from "./helpers/mocks/BlmMock.sol";
import {ERC1271Mock} from "./helpers/mocks/ERC1271Mock.sol";

contract LoanUnitTest is UnitTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    uint256 internal constant LOAN_DURATION = 30 days;

    function testTake(
        uint256 collateral,
        uint256 debt,
        uint256 bond,
        uint256 requirement,
        uint256 fixedRate,
        uint256 duration,
        uint256 overdueRate,
        uint256 overduePeriod
    ) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        bond = bound(bond, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        requirement = bound(requirement, MIN_TEST_AMOUNT, bond);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP) * BP;
        duration = bound(duration, MIN_DURATION, MAX_DURATION);
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP) * BP;
        overduePeriod = bound(overduePeriod, 0, MAX_OVERDUE_PERIOD);

        uint256 fee = 0.1e18;
        vm.prank(owner);
        iris.setFee(fee);

        Quote memory quote = Quote({
            borrower: borrower,
            solver: solver,
            receiver: receiver,
            blm: address(blm),
            collateralToken: collateralToken,
            debtToken: debtToken,
            collateral: collateral,
            debt: debt,
            fixedRate: fixedRate,
            duration: duration,
            overdueRate: overdueRate,
            overduePeriod: overduePeriod,
            bond: bond,
            bondLltv: bondLltv,
            venueBitmap: 1,
            venueId: 0,
            deadline: block.timestamp,
            nonce: 0,
            data: ""
        });
        bytes memory signature = _signQuote(solverPk, quote);
        address expectedPod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        // Unauthorized
        vm.expectRevert(IIris.Unauthorized.selector);
        iris.take(quote, signature);

        // Quote expired
        quote.deadline = block.timestamp - 1;
        vm.expectRevert(IIris.QuoteExpired.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.deadline = block.timestamp;

        // Invalid nonce
        StorageUtils.setIsNonceUsed(address(iris), solver, quote.nonce, true);
        vm.expectRevert(IIris.InvalidNonce.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        StorageUtils.setIsNonceUsed(address(iris), solver, quote.nonce, false);

        // Invalid signature
        bytes memory wrongSignature = _signQuote(borrowerPk, quote);
        vm.expectRevert(IIris.InvalidSignature.selector);
        vm.prank(borrower);
        iris.take(quote, wrongSignature);

        // Zero address - borrower
        quote.borrower = address(0);
        signature = _signQuote(solverPk, quote);
        StorageUtils.setIsAuthorized(address(iris), address(0), borrower, true);
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        StorageUtils.setIsAuthorized(address(iris), address(0), borrower, false);
        quote.borrower = borrower;

        // Zero address - receiver
        quote.receiver = address(0);
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.receiver = receiver;

        // Blm not enabled
        quote.blm = address(0);
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.BlmNotEnabled.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.blm = address(blm);

        // Zero address - collateral token
        quote.collateralToken = address(0);
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.collateralToken = collateralToken;

        // Zero address - debt token
        quote.debtToken = address(0);
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAddress.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.debtToken = debtToken;

        // Zero amount - collateral
        quote.collateral = 0;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAmount.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.collateral = collateral;

        // Zero amount - debt
        quote.debt = 0;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAmount.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.debt = debt;

        // Fixed rate too high
        quote.fixedRate = MAX_FIXED_RATE + BP;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.FixedRateTooHigh.selector);
        vm.prank(borrower);
        iris.take(quote, signature);

        // Not multiple of bp - fixed rate
        quote.fixedRate = BP + 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.NotMultipleOfBp.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.fixedRate = fixedRate;

        // Invalid duration - too short
        quote.duration = MIN_DURATION - 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.InvalidDuration.selector);
        vm.prank(borrower);
        iris.take(quote, signature);

        // Invalid duration - too long
        quote.duration = MAX_DURATION + 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.InvalidDuration.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.duration = duration;

        // Overdue rate too high
        quote.overdueRate = MAX_OVERDUE_RATE + BP;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.OverdueRateTooHigh.selector);
        vm.prank(borrower);
        iris.take(quote, signature);

        // Not multiple of bp - overdue rate
        quote.overdueRate = BP + 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.NotMultipleOfBp.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.overdueRate = overdueRate;

        // Overdue period too high
        quote.overduePeriod = MAX_OVERDUE_PERIOD + 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.OverduePeriodTooHigh.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.overduePeriod = overduePeriod;

        // Zero amount - bond
        quote.bond = 0;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.ZeroAmount.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.bond = bond;

        // Bond lltv not enabled
        quote.bondLltv = bondLltv + BP;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.BondLltvNotEnabled.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.bondLltv = bondLltv;

        // Not allowed venue
        quote.venueBitmap = 0;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.NotAllowedVenue.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.venueBitmap = 1;

        // Adapter not set
        quote.venueId = 1;
        quote.venueBitmap = 3;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.AdapterNotSet.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.venueId = 0;
        quote.venueBitmap = 1;

        // Adapter not set - venue id out of range
        quote.venueId = 128;
        quote.venueBitmap = (uint256(1) << 128) | 1;
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.AdapterNotSet.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.venueId = 0;
        quote.venueBitmap = 1;

        // Invalid data
        quote.data = "invalid data";
        signature = _signQuote(solverPk, quote);
        vm.expectRevert(IIris.InvalidData.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
        quote.data = "";
        signature = _signQuote(solverPk, quote);

        // Insufficient bond - blm requirement is zero
        vm.expectRevert(IIris.InsufficientBond.selector);
        vm.prank(borrower);
        iris.take(quote, signature);

        // Insufficient bond - bond below requirement
        BlmMock(address(blm)).setBondRequirement(bond + 1);
        vm.expectRevert(IIris.InsufficientBond.selector);
        vm.prank(borrower);
        iris.take(quote, signature);

        // Normal path
        BlmMock(address(blm)).setBondRequirement(requirement);
        deal(debtToken, solver, bond);
        deal(collateralToken, borrower, collateral);

        vm.prank(solver);
        debtToken.safeApprove(address(iris), bond);

        vm.startPrank(borrower);
        collateralToken.safeApprove(address(iris), collateral);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, solver, address(iris), bond));
        vm.expectCall(
            collateralToken, abi.encodeWithSelector(ERC20.transferFrom.selector, borrower, expectedPod, collateral)
        );
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.enter.selector, collateralToken, collateral, debtToken, debt, receiver, bytes("")
            )
        );
        vm.expectEmit();
        emit EventsLib.SetNonce(borrower, solver, quote.nonce);
        vm.expectEmit();
        emit EventsLib.Take(borrower, expectedPod, quote, DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_DEBT_INDEX);
        address newPod = iris.take(quote, signature);
        vm.stopPrank();

        assertEq(newPod, expectedPod);
        assertTrue(iris.isNonceUsed(solver, quote.nonce));

        Loan memory loan = iris.getLoan(newPod);
        assertEq(loan.borrower, borrower);
        assertEq(loan.solver, solver);
        assertEq(loan.collateralToken, collateralToken);
        assertEq(loan.debtToken, debtToken);
        assertEq(loan.venueBitmap, 1);
        assertEq(loan.maturity, block.timestamp + duration);
        assertEq(loan.overduePeriod, overduePeriod);
        assertEq(loan.fixedRate, fixedRate / BP);
        assertEq(loan.overdueRate, overdueRate / BP);
        assertEq(loan.bondLltv, bondLltv / BP);
        assertEq(loan.fee, fee / BP);

        Position memory position = iris.getPosition(newPod);
        assertEq(position.collateral, collateral);
        assertEq(position.debt, debt);
        assertEq(position.bond, bond);
        assertEq(position.bondRequirement, requirement);
        assertEq(position.collateralIndex, DEFAULT_TEST_COLLATERAL_INDEX);
        assertEq(position.debtIndex, DEFAULT_TEST_DEBT_INDEX);
        assertEq(position.fixedLeg, 0);
        assertEq(position.floatingLeg, 0);
        assertEq(position.surplus, 0);
        assertEq(position.lastUpdate, block.timestamp);
        assertEq(position.venueId, 0);
        assertEq(position.data, "");

        assertEq(debtToken.balanceOf(address(iris)), bond);
        assertEq(collateralToken.balanceOf(newPod), collateral);

        // Invalid nonce - quote replay
        vm.expectRevert(IIris.InvalidNonce.selector);
        vm.prank(borrower);
        iris.take(quote, signature);
    }

    function testTakeAuthorizedOperator() public {
        (address operator,) = makeAddrAndKey("operator");
        Quote memory quote = _defaultTakeQuote(borrower, solver, 0);
        bytes memory signature = _signQuote(solverPk, quote);
        address expectedPod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        BlmMock(address(blm)).setBondRequirement(quote.bond);
        deal(debtToken, quote.solver, quote.bond);
        deal(collateralToken, operator, quote.collateral);

        vm.prank(quote.solver);
        debtToken.safeApprove(address(iris), quote.bond);

        vm.prank(operator);
        collateralToken.safeApprove(address(iris), quote.collateral);

        vm.prank(borrower);
        iris.setAuthorization(operator, true);

        uint256 borrowerCollateralBefore = collateralToken.balanceOf(borrower);

        vm.prank(operator);
        address newPod = iris.take(quote, signature);

        assertEq(newPod, expectedPod);
        assertTrue(iris.isNonceUsed(solver, quote.nonce));

        Loan memory loan = iris.getLoan(newPod);
        assertEq(loan.borrower, borrower);
        assertEq(loan.solver, solver);

        Position memory position = iris.getPosition(newPod);
        assertEq(position.collateral, quote.collateral);
        assertEq(position.debt, quote.debt);
        assertEq(position.bond, quote.bond);
        assertEq(position.bondRequirement, quote.bond);

        assertEq(collateralToken.balanceOf(operator), 0);
        assertEq(collateralToken.balanceOf(borrower), borrowerCollateralBefore);
        assertEq(collateralToken.balanceOf(newPod), quote.collateral);
        assertEq(debtToken.balanceOf(address(iris)), quote.bond);
    }

    function testTakeERC1271Solver() public {
        (address walletOwner, uint256 walletOwnerPk) = makeAddrAndKey("walletOwner");
        ERC1271Mock erc1271 = new ERC1271Mock(walletOwner);

        Quote memory quote = _defaultTakeQuote(borrower, address(erc1271), 0);
        BlmMock(address(blm)).setBondRequirement(quote.bond);

        bytes memory wrongSignature = _signQuote(borrowerPk, quote);
        vm.expectRevert(IIris.InvalidSignature.selector);
        vm.prank(borrower);
        iris.take(quote, wrongSignature);
        assertFalse(iris.isNonceUsed(address(erc1271), quote.nonce));

        bytes memory signature = _signQuote(walletOwnerPk, quote);
        address expectedPod = vm.computeCreateAddress(address(iris), vm.getNonce(address(iris)));

        deal(debtToken, address(erc1271), quote.bond);
        deal(collateralToken, borrower, quote.collateral);

        vm.prank(address(erc1271));
        debtToken.safeApprove(address(iris), quote.bond);

        vm.prank(borrower);
        collateralToken.safeApprove(address(iris), quote.collateral);

        vm.prank(borrower);
        address newPod = iris.take(quote, signature);

        assertEq(newPod, expectedPod);
        assertTrue(iris.isNonceUsed(address(erc1271), quote.nonce));

        Loan memory loan = iris.getLoan(newPod);
        assertEq(loan.borrower, borrower);
        assertEq(loan.solver, address(erc1271));

        Position memory position = iris.getPosition(newPod);
        assertEq(position.collateral, quote.collateral);
        assertEq(position.debt, quote.debt);
        assertEq(position.bond, quote.bond);
        assertEq(position.bondRequirement, quote.bond);

        assertEq(debtToken.balanceOf(address(iris)), quote.bond);
        assertEq(collateralToken.balanceOf(newPod), quote.collateral);
    }

    function testRepay(
        uint256 collateral,
        uint256 debt,
        uint256 bond,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 floatingLeg,
        uint256 surplus,
        uint256 fee,
        uint256 blocks,
        uint256 collateralIndex,
        uint256 debtIndex
    ) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        bond = bound(bond, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP) * BP;
        overdueRate = bound(overdueRate, 0, MAX_OVERDUE_RATE / BP) * BP;
        floatingLeg = bound(floatingLeg, 0, MAX_TEST_AMOUNT);
        surplus = bound(surplus, 0, MAX_TEST_AMOUNT);
        fee = bound(fee, 0, MAX_FEE / BP) * BP;
        // 3 * LOAN_DURATION = maturity + overdue period + after overdue period
        blocks = bound(blocks, 1, 3 * LOAN_DURATION);
        collateralIndex = bound(collateralIndex, DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_COLLATERAL_INDEX * 2);
        debtIndex = bound(debtIndex, DEFAULT_TEST_DEBT_INDEX, DEFAULT_TEST_DEBT_INDEX * 2);

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.repay(pod);

        // Zero amount ((debt + fixedLeg == 0) && (bondRequirement == 0))
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.repay(pod);

        // Normal path ((debt + fixedLeg == 0) && (bondRequirement != 0))
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        assertEq(iris.repay(pod), 0);
        assertEq(iris.getPosition(pod).bondRequirement, 0);

        // Normal path (debt + fixedLeg != 0)
        uint256 startTime = vm.getBlockTimestamp();
        uint256 maturity = startTime + LOAN_DURATION;
        _setupLoanState(collateral, debt, bond, maturity, startTime, fixedRate, overdueRate, fee, floatingLeg, surplus);

        uint256 newSurplus = surplus
            + (collateral + surplus)
            .mulDivDown(collateralIndex - DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_COLLATERAL_INDEX);
        uint256 newFloating =
            floatingLeg + (debt + floatingLeg).mulDivDown(debtIndex - DEFAULT_TEST_DEBT_INDEX, DEFAULT_TEST_DEBT_INDEX);

        VenueAdapterMock(address(venueAdapter)).setIndices(collateralIndex, debtIndex);
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral + newSurplus, debt + newFloating);
        _forward(blocks);

        // Read through the cheatcode: with via-ir the compiler caches `block.timestamp` across `vm.warp`.
        uint256 timestamp = vm.getBlockTimestamp();
        uint256 accruedFixed = debt.mulDivDown((timestamp - startTime) * (fixedRate / BP) * BP, SECONDS_PER_YEAR * WAD);
        if (timestamp > maturity) {
            accruedFixed += debt.mulDivDown((timestamp - maturity) * (overdueRate / BP) * BP, SECONDS_PER_YEAR * WAD);
        }
        uint256 residual = timestamp < maturity
            ? debt.mulDivDown((maturity - timestamp) * (fixedRate / BP) * BP, SECONDS_PER_YEAR * WAD)
            : 0;
        uint256 fixedLeg = accruedFixed + residual;

        uint256 net = fixedLeg > newFloating ? fixedLeg - newFloating : 0;
        uint256 negativeNet = newFloating > fixedLeg ? newFloating - fixedLeg : 0;
        uint256 bondSlashed = MathLib.min(negativeNet, bond);
        uint256 badBond = negativeNet.zeroFloorSub(bond);
        uint256 repaid = debt + fixedLeg + badBond;
        uint256 venueDebt = debt + newFloating;
        uint256 performanceFee = (net != 0 && fee != 0) ? net.mulDivDown(fee, WAD) : 0;
        uint256 surplusFee = fee != 0 ? newSurplus.mulDivDown(fee, WAD) : 0;

        deal(debtToken, borrower, repaid);
        deal(debtToken, address(iris), bond);

        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), repaid);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, borrower, address(iris), repaid));
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.exit.selector, collateralToken, newSurplus, debtToken, venueDebt, address(iris), bytes("")
            )
        );
        vm.expectEmit();
        emit EventsLib.Accrue(
            pod, collateralIndex, debtIndex, accruedFixed, newFloating - floatingLeg, newSurplus - surplus
        );
        vm.expectEmit();
        emit EventsLib.Repay(borrower, pod, repaid, badBond);
        uint256 returned = iris.repay(pod);
        vm.stopPrank();

        assertEq(returned, repaid);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, collateral);
        assertEq(pos.debt, 0);
        assertEq(pos.bond, bond - bondSlashed);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.collateralIndex, collateralIndex);
        assertEq(pos.debtIndex, debtIndex);
        assertEq(pos.lastUpdate, uint32(timestamp));

        assertEq(iris.claimable(debtToken, solver), net != 0 ? net - performanceFee : 0);
        assertEq(iris.claimable(collateralToken, solver), newSurplus != 0 ? newSurplus - surplusFee : 0);
        assertEq(iris.claimable(debtToken, feeRecipient), performanceFee);
        assertEq(iris.claimable(collateralToken, feeRecipient), surplusFee);

        assertEq(debtToken.balanceOf(address(iris)), bond - bondSlashed + net);
        assertEq(debtToken.balanceOf(pod), venueDebt);
        assertEq(debtToken.balanceOf(borrower), 0);
    }

    function testLiquidate(
        uint256 collateral,
        uint256 debt,
        uint256 bond,
        uint256 fixedRate,
        uint256 floatingLeg,
        uint256 surplus,
        uint256 blocks,
        uint256 price,
        uint256 fee,
        uint256 collateralIndex,
        uint256 debtIndex
    ) public {
        collateral = bound(collateral, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        debt = bound(debt, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        bond = bound(bond, MIN_TEST_AMOUNT, MAX_TEST_AMOUNT);
        fixedRate = bound(fixedRate, 0, MAX_FIXED_RATE / BP) * BP;
        floatingLeg = bound(floatingLeg, 0, MAX_TEST_AMOUNT);
        surplus = bound(surplus, 0, MAX_TEST_AMOUNT);
        blocks = bound(blocks, LOAN_DURATION + MAX_OVERDUE_PERIOD + 1, type(uint32).max);
        price = bound(price, MIN_TEST_COLLATERAL_PRICE, MAX_TEST_COLLATERAL_PRICE);
        fee = bound(fee, 0, MAX_FEE / BP) * BP;
        collateralIndex = bound(collateralIndex, DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_COLLATERAL_INDEX * 2);
        debtIndex = bound(debtIndex, DEFAULT_TEST_DEBT_INDEX, DEFAULT_TEST_DEBT_INDEX * 2);

        // Zero address
        vm.expectRevert(IIris.ZeroAddress.selector);
        iris.liquidate(pod, address(0));

        // Loan not created
        vm.expectRevert(IIris.LoanNotCreated.selector);
        iris.liquidate(pod, receiver);

        // Zero amount
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(block.timestamp));
        vm.expectRevert(IIris.ZeroAmount.selector);
        iris.liquidate(pod, receiver);

        // Healthy loan - exactly at the overdue threshold (strict `>` keeps it healthy at the boundary).
        uint256 startTime = vm.getBlockTimestamp();
        uint256 maturity = startTime + LOAN_DURATION;
        _setupLoanState(
            collateral, debt, bond, maturity, startTime, fixedRate, MAX_OVERDUE_RATE, fee, floatingLeg, surplus
        );
        VenueAdapterMock(address(venueAdapter)).setPrice(price);

        uint256 newSurplus = surplus
            + (collateral + surplus)
            .mulDivDown(collateralIndex - DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_COLLATERAL_INDEX);
        uint256 newFloating =
            floatingLeg + (debt + floatingLeg).mulDivDown(debtIndex - DEFAULT_TEST_DEBT_INDEX, DEFAULT_TEST_DEBT_INDEX);

        VenueAdapterMock(address(venueAdapter)).setIndices(collateralIndex, debtIndex);
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral + newSurplus, debt + newFloating);

        vm.warp(maturity + MAX_OVERDUE_PERIOD);
        vm.expectRevert(IIris.HealthyLoan.selector);
        iris.liquidate(pod, receiver);

        // Normal path
        vm.warp(startTime + blocks);
        // Read through the cheatcode: with via-ir the compiler caches `block.timestamp` across `vm.warp`.
        uint256 timestamp = vm.getBlockTimestamp();
        uint256 fixedLeg = debt.mulDivDown((timestamp - startTime) * (fixedRate / BP) * BP, SECONDS_PER_YEAR * WAD)
            + debt.mulDivDown((timestamp - maturity) * (MAX_OVERDUE_RATE / BP) * BP, SECONDS_PER_YEAR * WAD);

        uint256 net = fixedLeg > newFloating ? fixedLeg - newFloating : 0;
        uint256 negativeNet = newFloating > fixedLeg ? newFloating - fixedLeg : 0;
        uint256 bondSlashed = MathLib.min(negativeNet, bond);
        uint256 badBond = negativeNet.zeroFloorSub(bond);
        uint256 repaid = debt + fixedLeg + badBond;
        uint256 venueDebt = debt + newFloating;
        uint256 performanceFee = (net != 0 && fee != 0) ? net.mulDivDown(fee, WAD) : 0;
        uint256 surplusFee = fee != 0 ? newSurplus.mulDivDown(fee, WAD) : 0;
        uint256 lif =
            MathLib.min(MAX_LIF, MAX_LIF.mulDivDown(timestamp - (maturity + MAX_OVERDUE_PERIOD), TIME_TO_MAX_LIF));
        uint256 seized =
            MathLib.min(collateral, repaid.mulDivDown(WAD + lif, WAD).mulDivDown(ORACLE_PRICE_SCALE, price));

        deal(debtToken, address(this), repaid);
        deal(debtToken, address(iris), bond);
        deal(collateralToken, address(iris), seized);

        debtToken.safeApprove(address(iris), repaid);
        vm.expectCall(
            debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, address(this), address(iris), repaid)
        );
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.exit.selector,
                collateralToken,
                seized + newSurplus,
                debtToken,
                venueDebt,
                address(iris),
                bytes("")
            )
        );
        vm.expectCall(collateralToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, seized));
        vm.expectEmit();
        emit EventsLib.Accrue(
            pod, collateralIndex, debtIndex, fixedLeg, newFloating - floatingLeg, newSurplus - surplus
        );
        vm.expectEmit();
        emit EventsLib.Liquidate(address(this), pod, receiver, repaid, seized, badBond);
        (uint256 returnedRepaid, uint256 returnedSeized) = iris.liquidate(pod, receiver);

        assertEq(returnedRepaid, repaid);
        assertEq(returnedSeized, seized);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, collateral - seized);
        assertEq(pos.debt, 0);
        assertEq(pos.bond, bond - bondSlashed);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.collateralIndex, collateralIndex);
        assertEq(pos.debtIndex, debtIndex);
        assertEq(pos.lastUpdate, uint32(timestamp));

        assertEq(iris.claimable(debtToken, solver), net != 0 ? net - performanceFee : 0);
        assertEq(iris.claimable(collateralToken, solver), newSurplus != 0 ? newSurplus - surplusFee : 0);
        assertEq(iris.claimable(debtToken, feeRecipient), performanceFee);
        assertEq(iris.claimable(collateralToken, feeRecipient), surplusFee);

        assertEq(collateralToken.balanceOf(receiver), seized);
        assertEq(debtToken.balanceOf(address(iris)), bond - bondSlashed + net);
        assertEq(debtToken.balanceOf(pod), venueDebt);
        assertEq(debtToken.balanceOf(address(this)), 0);
    }

    /// @dev Ensure `claimable` equals the post-rebase surplus and leg, not the pre-rebase surplus and leg.
    function testRepaySettlesOnRebasedLegs() public {
        uint256 collateral = 0;
        uint256 debt = 0;
        uint256 surplus = 100e18;
        uint256 floatingLeg = 100e18;
        uint256 fixedLeg = 50e18;
        uint256 bond = 5e18;
        uint256 fee = 0.1e18;
        // The venue holds less than the fully accrued surplus/floatingLeg
        uint256 venueCollateral = 30e18;
        uint256 venueDebt = 40e18;

        uint256 startTime = vm.getBlockTimestamp();
        // maturity == now, so `_settleLegs` adds no residual (block.timestamp is not < maturity)
        _setupLoanState(collateral, debt, bond, startTime, startTime, 0, 0, fee, floatingLeg, surplus);
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
        VenueAdapterMock(address(venueAdapter)).setPrice(ORACLE_PRICE_SCALE);

        // Rebase clamps the legs down to the venue amounts; settlement then runs on these post-rebase values.
        uint256 rebasedSurplus = venueCollateral;
        uint256 badDebt = venueDebt.zeroFloorSub(venueCollateral);
        uint256 repaid = debt + fixedLeg;

        deal(debtToken, borrower, repaid);
        deal(debtToken, address(iris), bond);

        vm.startPrank(borrower);
        debtToken.safeApprove(address(iris), repaid);
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, borrower, address(iris), repaid));
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.exit.selector,
                collateralToken,
                rebasedSurplus,
                debtToken,
                venueDebt,
                address(iris),
                bytes("")
            )
        );
        vm.expectEmit();
        emit EventsLib.Rebase(borrower, pod, 0, 0, venueCollateral, venueDebt, badDebt);
        vm.expectEmit();
        emit EventsLib.Repay(borrower, pod, repaid, 0);
        uint256 returned = iris.repay(pod);
        vm.stopPrank();

        assertEq(returned, repaid);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, 0);
        assertEq(pos.debt, 0);
        assertEq(pos.bond, bond);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.collateralIndex, DEFAULT_TEST_COLLATERAL_INDEX);
        assertEq(pos.debtIndex, DEFAULT_TEST_DEBT_INDEX);
        assertEq(pos.lastUpdate, startTime);

        // solver net = fixed leg (50e18) - rebased floating leg (40e18) = 10e18
        // solver surplus = rebased surplus (30e18)
        assertEq(iris.claimable(debtToken, solver), 9e18);
        assertEq(iris.claimable(collateralToken, solver), 27e18);
        assertEq(iris.claimable(debtToken, feeRecipient), 1e18);
        assertEq(iris.claimable(collateralToken, feeRecipient), 3e18);

        assertEq(debtToken.balanceOf(address(iris)), 15e18); // bond 5e18 + net 10e18
        assertEq(debtToken.balanceOf(pod), venueDebt);
        assertEq(debtToken.balanceOf(borrower), 0);
    }

    /// @dev Ensure `claimable` equals the post-rebase leg, not the pre-rebase leg.
    function testLiquidateSettlesOnRebasedLegs() public {
        uint256 collateral = 100e18;
        uint256 debt = 0;
        uint256 surplus = 0;
        uint256 floatingLeg = 100e18;
        uint256 fixedLeg = 50e18;
        uint256 bond = 5e18;
        uint256 fee = 0.1e18;
        uint256 price = ORACLE_PRICE_SCALE;
        // Venue debt fell below the floating leg; venue collateral still covers it, so there is no bad debt
        uint256 venueCollateral = 60e18;
        uint256 venueDebt = 40e18;

        uint256 startTime = vm.getBlockTimestamp();
        _setupLoanState(collateral, debt, bond, startTime, startTime, 0, 0, fee, floatingLeg, surplus);
        StorageUtils.setPositionFixedLeg(address(iris), pod, uint128(fixedLeg));
        VenueAdapterMock(address(venueAdapter)).setPosition(venueCollateral, venueDebt);
        VenueAdapterMock(address(venueAdapter)).setPrice(price);

        vm.warp(startTime + MAX_OVERDUE_PERIOD + TIME_TO_MAX_LIF);
        // Read through the cheatcode: with via-ir the compiler caches `block.timestamp` across `vm.warp`.
        uint256 timestamp = vm.getBlockTimestamp();
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(timestamp));

        uint256 liquidated = (collateral + surplus).zeroFloorSub(venueCollateral);
        uint256 rebasedCollateral = collateral.zeroFloorSub(liquidated);
        uint256 repaid = debt + fixedLeg;
        uint256 lif =
            MathLib.min(MAX_LIF, MAX_LIF.mulDivDown(timestamp - (startTime + MAX_OVERDUE_PERIOD), TIME_TO_MAX_LIF));
        uint256 seized =
            MathLib.min(rebasedCollateral, repaid.mulDivDown(WAD + lif, WAD).mulDivDown(ORACLE_PRICE_SCALE, price));

        deal(debtToken, address(this), repaid);
        deal(debtToken, address(iris), bond);
        deal(collateralToken, address(iris), seized);

        debtToken.safeApprove(address(iris), repaid);
        vm.expectCall(
            debtToken, abi.encodeWithSelector(ERC20.transferFrom.selector, address(this), address(iris), repaid)
        );
        vm.expectCall(debtToken, abi.encodeWithSelector(ERC20.transfer.selector, pod, venueDebt));
        vm.expectCall(
            address(venueAdapter),
            abi.encodeWithSelector(
                IVenueAdapter.exit.selector,
                collateralToken,
                seized + surplus,
                debtToken,
                venueDebt,
                address(iris),
                bytes("")
            )
        );
        vm.expectCall(collateralToken, abi.encodeWithSelector(ERC20.transfer.selector, receiver, seized));
        vm.expectEmit();
        emit EventsLib.Rebase(address(this), pod, rebasedCollateral, 0, venueCollateral, venueDebt, 0);
        vm.expectEmit();
        emit EventsLib.Liquidate(address(this), pod, receiver, repaid, seized, 0);
        (uint256 returnedRepaid, uint256 returnedSeized) = iris.liquidate(pod, receiver);

        assertEq(returnedRepaid, repaid);
        assertEq(returnedSeized, seized);

        Position memory pos = iris.getPosition(pod);
        assertEq(pos.collateral, rebasedCollateral - seized);
        assertEq(pos.debt, 0);
        assertEq(pos.bond, bond);
        assertEq(pos.bondRequirement, 0);
        assertEq(pos.fixedLeg, 0);
        assertEq(pos.floatingLeg, 0);
        assertEq(pos.surplus, 0);
        assertEq(pos.lastUpdate, uint32(timestamp));

        // solver net = fixed leg (50e18) - rebased floating leg (40e18) = 10e18
        assertEq(iris.claimable(debtToken, solver), 9e18);
        assertEq(iris.claimable(collateralToken, solver), 0);
        assertEq(iris.claimable(debtToken, feeRecipient), 1e18);
        assertEq(iris.claimable(collateralToken, feeRecipient), 0);

        assertEq(collateralToken.balanceOf(receiver), seized);
        assertEq(debtToken.balanceOf(address(iris)), 15e18); // bond 5e18 + net 10e18
        assertEq(debtToken.balanceOf(pod), venueDebt);
        assertEq(debtToken.balanceOf(address(this)), 0);
    }

    /* HELPERS */

    function _defaultTakeQuote(address quoteBorrower, address quoteSolver, uint256 nonce)
        internal
        view
        returns (Quote memory quote)
    {
        quote.borrower = quoteBorrower;
        quote.solver = quoteSolver;
        quote.receiver = receiver;
        quote.blm = address(blm);
        quote.collateralToken = collateralToken;
        quote.debtToken = debtToken;
        quote.collateral = 1e18;
        quote.debt = 1e6;
        quote.fixedRate = 0.05e18;
        quote.duration = LOAN_DURATION;
        quote.overdueRate = 0.1e18;
        quote.overduePeriod = 7 days;
        quote.bond = 1e5;
        quote.bondLltv = bondLltv;
        quote.venueBitmap = 1;
        quote.venueId = 0;
        quote.deadline = block.timestamp + 1;
        quote.nonce = nonce;
        quote.data = "";
    }

    function _setupLoanState(
        uint256 collateral,
        uint256 debt,
        uint256 bond,
        uint256 maturity,
        uint256 lastUpdate,
        uint256 fixedRate,
        uint256 overdueRate,
        uint256 fee,
        uint256 floatingLeg,
        uint256 surplus
    ) internal {
        StorageUtils.setLoanSolver(address(iris), pod, solver);
        StorageUtils.setLoanCollateralToken(address(iris), pod, collateralToken);
        StorageUtils.setLoanDebtToken(address(iris), pod, debtToken);
        StorageUtils.setLoanMaturity(address(iris), pod, uint32(maturity));
        StorageUtils.setLoanOverduePeriod(address(iris), pod, uint32(MAX_OVERDUE_PERIOD));
        StorageUtils.setLoanFixedRate(address(iris), pod, uint16(fixedRate / BP));
        StorageUtils.setLoanOverdueRate(address(iris), pod, uint16(overdueRate / BP));
        StorageUtils.setLoanFee(address(iris), pod, uint16(fee / BP));
        StorageUtils.setPositionCollateral(address(iris), pod, uint128(collateral));
        StorageUtils.setPositionDebt(address(iris), pod, uint128(debt));
        StorageUtils.setPositionBond(address(iris), pod, uint128(bond));
        StorageUtils.setPositionBondRequirement(address(iris), pod, 1);
        StorageUtils.setPositionCollateralIndex(address(iris), pod, uint128(DEFAULT_TEST_COLLATERAL_INDEX));
        StorageUtils.setPositionDebtIndex(address(iris), pod, uint128(DEFAULT_TEST_DEBT_INDEX));
        StorageUtils.setPositionFloatingLeg(address(iris), pod, uint128(floatingLeg));
        StorageUtils.setPositionSurplus(address(iris), pod, uint128(surplus));
        StorageUtils.setPositionLastUpdate(address(iris), pod, uint32(lastUpdate));
        VenueAdapterMock(address(venueAdapter)).setPosition(collateral + surplus, debt + floatingLeg);
        VenueAdapterMock(address(venueAdapter)).setIndices(DEFAULT_TEST_COLLATERAL_INDEX, DEFAULT_TEST_DEBT_INDEX);
    }
}
