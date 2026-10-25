// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "../BaseTest.t.sol";

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ERC20Mock} from "../unit/helpers/mocks/ERC20Mock.sol";
import {Blm} from "../../src/blm/Blm.sol";

uint256 constant RAY = 1e27;

/// @dev Share-based lending venue. Debt rounds up and collateral rounds down like Morpho/Aave. Health and
/// liquidation use one lltv and a fixed bonus. SOCIALIZE writes off the remaining debt once collateral hits zero
/// (Morpho bad debt, Aave deficit); COLLATERAL_YIELD grows a collateral index (Aave aToken).
contract MockVenue {
    using SafeTransferLib for address;
    using MathLib for uint256;

    address public immutable COLLATERAL;
    address public immutable DEBT;
    bool public immutable COLLATERAL_YIELD;
    bool public immutable SOCIALIZE;

    uint256 public price = 2000e36;
    uint256 public lltv = 0.86e18;
    uint256 public lif = 1.05e18;
    uint256 public borrowRate = 0.05e18;
    uint256 public collateralIndex = RAY;
    uint256 public debtIndex = RAY;
    uint256 public lastAccrual;

    mapping(address => uint256) public collateralShares;
    mapping(address => uint256) public debtShares;

    constructor(address collateral, address debt, bool collateralYield, bool socialize) {
        COLLATERAL = collateral;
        DEBT = debt;
        COLLATERAL_YIELD = collateralYield;
        SOCIALIZE = socialize;
        lastAccrual = block.timestamp;
    }

    function accrue() public {
        uint256 elapsed = block.timestamp - lastAccrual;
        if (elapsed == 0) return;
        lastAccrual = block.timestamp;
        debtIndex += debtIndex.mulDivDown(borrowRate * elapsed, 365 days * WAD);
        if (COLLATERAL_YIELD) collateralIndex += collateralIndex.mulDivDown(borrowRate * elapsed / 2, 365 days * WAD);
    }

    function setBorrowRate(uint256 rate) external {
        accrue();
        borrowRate = rate;
    }

    function setPrice(uint256 newPrice) external {
        price = newPrice;
    }

    function collateralOf(address account) public view returns (uint256) {
        return collateralShares[account].mulDivDown(collateralIndex, RAY);
    }

    function debtOf(address account) public view returns (uint256) {
        return debtShares[account].mulDivUp(debtIndex, RAY);
    }

    function isHealthy(address account) public view returns (bool) {
        return debtOf(account) <= collateralOf(account).mulDivDown(price, 1e36).mulDivDown(lltv, WAD);
    }

    function supplyCollateral(address onBehalf, uint256 amount) external {
        accrue();
        COLLATERAL.safeTransferFrom(msg.sender, address(this), amount);
        collateralShares[onBehalf] += amount.mulDivDown(RAY, collateralIndex);
    }

    function withdrawCollateral(uint256 amount, address receiver) external {
        accrue();
        collateralShares[msg.sender] -= amount.mulDivUp(RAY, collateralIndex);
        require(isHealthy(msg.sender), "MockVenue: unhealthy");
        COLLATERAL.safeTransfer(receiver, amount);
    }

    function borrow(uint256 amount, address receiver) external {
        accrue();
        debtShares[msg.sender] += amount.mulDivUp(RAY, debtIndex);
        require(isHealthy(msg.sender), "MockVenue: unhealthy");
        DEBT.safeTransfer(receiver, amount);
    }

    function repay(address onBehalf, uint256 amount) external returns (uint256) {
        accrue();
        uint256 debt = debtOf(onBehalf);
        if (amount >= debt) {
            debtShares[onBehalf] = 0;
            amount = debt;
        } else {
            debtShares[onBehalf] -= amount.mulDivDown(RAY, debtIndex);
        }
        DEBT.safeTransferFrom(msg.sender, address(this), amount);
        return amount;
    }

    function liquidate(address account, uint256 repayAmount) external returns (uint256 repaid, uint256 seized) {
        accrue();
        require(!isHealthy(account), "MockVenue: healthy");
        uint256 debt = debtOf(account);
        uint256 collateral = collateralOf(account);

        repaid = MathLib.min(repayAmount, debt);
        seized = repaid.mulDivDown(lif, WAD).mulDivDown(1e36, price);
        if (seized >= collateral) {
            seized = collateral;
            repaid = MathLib.min(seized.mulDivUp(price, 1e36).mulDivUp(WAD, lif), debt);
        }

        if (repaid == debt) debtShares[account] = 0;
        else debtShares[account] -= repaid.mulDivDown(RAY, debtIndex);
        if (seized == collateral) collateralShares[account] = 0;
        else collateralShares[account] -= seized.mulDivUp(RAY, collateralIndex);
        if (SOCIALIZE && collateralShares[account] == 0) debtShares[account] = 0;

        DEBT.safeTransferFrom(msg.sender, address(this), repaid);
        COLLATERAL.safeTransfer(msg.sender, seized);
    }
}

/// @dev Delegatecalled by pods for the state-changing entries; called directly by Iris for the views.
contract MockVenueAdapter is IVenueAdapter {
    using SafeTransferLib for address;

    MockVenue public immutable VENUE;

    constructor(MockVenue venue) {
        VENUE = venue;
    }

    function supplyCollateral(address token, uint256 amount, bytes calldata) external {
        token.safeApproveWithRetry(address(VENUE), amount);
        VENUE.supplyCollateral(address(this), amount);
    }

    function withdrawCollateral(address, uint256 amount, address receiver, bytes calldata) external {
        VENUE.withdrawCollateral(amount, receiver);
    }

    function repay(address token, uint256 amount, bytes calldata) external {
        if (amount == 0) return;
        token.safeApproveWithRetry(address(VENUE), amount);
        VENUE.repay(address(this), amount);
    }

    function enter(address collateralToken, uint256 collateral, address, uint256 debt, address receiver, bytes calldata)
        external
    {
        collateralToken.safeApproveWithRetry(address(VENUE), collateral);
        VENUE.supplyCollateral(address(this), collateral);
        VENUE.borrow(debt, receiver);
    }

    function exit(address, uint256 collateral, address debtToken, uint256 debt, address receiver, bytes calldata)
        external
    {
        if (debt != 0) {
            debtToken.safeApproveWithRetry(address(VENUE), debt);
            VENUE.repay(address(this), debt);
        }
        if (collateral != 0) VENUE.withdrawCollateral(collateral, receiver);
    }

    function positionAssets(address pod, address, address, bytes calldata) external view returns (uint256, uint256) {
        return (VENUE.collateralOf(pod), VENUE.debtOf(pod));
    }

    function price(address, address, bytes calldata) external view returns (uint256) {
        return VENUE.price();
    }

    function lltv(address, address, bytes calldata) external view returns (uint256) {
        return VENUE.lltv();
    }

    function indices(address, address, bytes calldata) external view returns (uint256, uint256) {
        return (VENUE.collateralIndex(), VENUE.debtIndex());
    }
}

/// @dev Stateful campaign that adds the venue side the fork campaign lacks: venue liquidations (partial, full,
/// bad debt with and without write-off), price moves, floating-rate changes and direct collateral supply on a pod.
/// Effects already acknowledged in the audits or the Iris header are kept out by construction, so a failure here
/// is not explained by them:
/// - every venue event is rebased in the same block at the same price (no delayed rebase, M-02 / M-03, and no
///   price move between a venue liquidation and its rebase),
/// - there is no direct venue repay on a pod (L-01),
/// - a direct collateral supply is synced right away (header: supply masking a later liquidation).
contract VenueAdversaryInvariantTest is BaseTest {
    using MathLib for uint256;
    using SafeTransferLib for address;

    /// @dev Dust allowance in wei for 18-decimal tokens. Covers the per-accrual round-down gap and share rounding.
    uint256 internal constant TOL = 1e9;
    uint256 internal constant MAX_ACTIVE_PODS = 6;
    uint256 internal constant MAX_PODS = 80;

    MockVenue[2] internal venues;
    MockVenueAdapter[2] internal adapters;
    Blm internal realBlm;

    address[] internal borrowers;
    address[] internal solvers;
    uint256[] internal solverPks;
    address[] internal keepers;
    address[] internal pods;

    mapping(address solver => uint256) internal solverNonce;

    /// @dev Debt-token value, at the liquidation price, of everything a venue liquidation seized from the pod.
    mapping(address pod => uint256) internal ghostLostValue;
    /// @dev Debt-token claimable credited to the pod's borrower (only the rebase netting refund does that).
    mapping(address pod => uint256) internal ghostRefund;

    string[] internal failures;
    bytes4[] internal selectors;

    /// @dev Coverage counters, printed after each run so a pass can be told apart from a handler that never fires.
    mapping(string => uint256) internal hits;
    string[] internal hitKeys;

    function _collateralGap() internal view returns (int256) {
        address[] memory accounts = _accounts();
        uint256 liabilities;
        for (uint256 i; i < accounts.length; ++i) {
            liabilities += iris.claimable(collateralToken, accounts[i]);
        }
        return int256(liabilities) - int256(ERC20(collateralToken).balanceOf(address(iris)));
    }

    modifier probe(string memory name) {
        int256 gapBefore = _collateralGap();
        _;
        int256 gapAfter = _collateralGap();
        if (gapAfter > gapBefore + int256(TOL)) {
            failures.push(
                string.concat("PROBE ", name, " collateral gap ", vm.toString(gapBefore), " -> ", vm.toString(gapAfter))
            );
        }
    }

    function _hit(string memory key) internal {
        if (hits[key] == 0) hitKeys.push(key);
        ++hits[key];
    }

    function afterInvariant() external view {
        string memory line;
        for (uint256 i; i < hitKeys.length; ++i) {
            line = string.concat(line, hitKeys[i], "=", vm.toString(hits[hitKeys[i]]), " ");
        }
        console.log(line);
    }

    function setUp() public override {
        super.setUp();

        collateralToken = address(new ERC20Mock("Collateral", "COLL", 18));
        debtToken = address(new ERC20Mock("Debt", "DEBT", 18));

        venues[0] = new MockVenue(collateralToken, debtToken, false, true);
        venues[1] = new MockVenue(collateralToken, debtToken, true, false);
        for (uint256 i; i < 2; ++i) {
            adapters[i] = new MockVenueAdapter(venues[i]);
            ERC20Mock(collateralToken).mint(address(venues[i]), 1e40);
            ERC20Mock(debtToken).mint(address(venues[i]), 1e40);
        }

        realBlm = new Blm(address(iris));
        blm = IBlm(address(realBlm));

        vm.startPrank(owner);
        iris.enableBlm(address(realBlm));
        iris.setVenueAdapter(0, address(adapters[0]));
        iris.setVenueAdapter(1, address(adapters[1]));
        iris.setFee(0.1e18);
        realBlm.setParams(debtToken, 0.0001e18, 0.0001e18);
        vm.stopPrank();

        // Stand in for the pooled balance a live Iris always holds (the known <=2 wei close round-up).
        ERC20Mock(collateralToken).mint(address(iris), 1e6);
        ERC20Mock(debtToken).mint(address(iris), 1e6);

        for (uint256 i; i < 3; ++i) {
            borrowers.push(makeAddr(string.concat("Borrower", vm.toString(i))));
            keepers.push(makeAddr(string.concat("Keeper", vm.toString(i))));
        }
        for (uint256 i; i < 2; ++i) {
            (address s, uint256 pk) = makeAddrAndKey(string.concat("Solver", vm.toString(i)));
            solvers.push(s);
            solverPks.push(pk);
        }

        _weight(this.take.selector, 30);
        _weight(this.warp.selector, 30);
        _weight(this.setRate.selector, 10);
        _weight(this.movePrice.selector, 25);
        _weight(this.venueLiquidate.selector, 30);
        _weight(this.directSupply.selector, 8);
        _weight(this.supplyCollateral.selector, 8);
        _weight(this.withdrawCollateral.selector, 15);
        _weight(this.supplyBond.selector, 8);
        _weight(this.withdrawBond.selector, 12);
        _weight(this.repay.selector, 12);
        _weight(this.liquidate.selector, 12);
        _weight(this.liquidateBond.selector, 12);
        _weight(this.rebase.selector, 6);
        _weight(this.refinance.selector, 10);
        _weight(this.escape.selector, 8);
        _weight(this.claim.selector, 10);

        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    /* Helpers */

    function _weight(bytes4 selector, uint256 weight) internal {
        for (uint256 i; i < weight; ++i) {
            selectors.push(selector);
        }
    }

    function _fail(string memory where, address pod, bytes memory err) internal {
        failures.push(string.concat(where, " pod=", vm.toString(pod), " err=", vm.toString(err)));
    }

    function _mintApprove(address token, address account, address spender, uint256 amount) internal {
        ERC20Mock(token).mint(account, amount);
        vm.prank(account);
        token.safeApproveWithRetry(spender, type(uint256).max);
    }

    modifier trackRefund(address pod) {
        address b = pod == address(0) ? address(0) : iris.getLoan(pod).borrower;
        uint256 before = b == address(0) ? 0 : iris.claimable(debtToken, b);
        _;
        if (b != address(0)) {
            uint256 afterwards = iris.claimable(debtToken, b);
            if (afterwards > before) {
                ghostRefund[pod] += afterwards - before;
                _hit("refund");
            }
        }
    }

    function _venue(address pod) internal view returns (MockVenue) {
        return venues[iris.getPosition(pod).venueId];
    }

    function _pick(uint256 seed, function(address) internal view returns (bool) predicate)
        internal
        view
        returns (address)
    {
        address[] memory candidates = new address[](pods.length);
        uint256 count;
        for (uint256 i; i < pods.length; ++i) {
            if (predicate(pods[i])) candidates[count++] = pods[i];
        }
        if (count == 0) return address(0);
        return candidates[seed % count];
    }

    function _isAny(address) internal pure returns (bool) {
        return true;
    }

    function _hasVenueDebt(address pod) internal view returns (bool) {
        return _venue(pod).debtOf(pod) != 0 && _venue(pod).collateralOf(pod) != 0;
    }

    function _isOpen(address pod) internal view returns (bool) {
        return iris.getPosition(pod).bondRequirement != 0;
    }

    function _isRepayable(address pod) internal view returns (bool) {
        Position memory pos = iris.getPosition(pod);
        return uint256(pos.debt) + pos.fixedLeg != 0 || pos.bondRequirement != 0 || pos.surplus != 0;
    }

    function _isLiquidatable(address pod) internal view returns (bool) {
        Loan memory loan = iris.getLoan(pod);
        return _isRepayable(pod) && block.timestamp > uint256(loan.maturity) + loan.overduePeriod;
    }

    function _isResolved(address pod) internal view returns (bool) {
        Position memory pos = iris.getPosition(pod);
        return pos.bondRequirement == 0 && uint256(pos.debt) + pos.fixedLeg + pos.surplus == 0;
    }

    function _isBondLiquidatable(address pod) internal view returns (bool) {
        Position memory pos = iris.getPosition(pod);
        if (pos.bondRequirement == 0) return false;
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        if (floatingLeg <= fixedLeg) return false;
        return (floatingLeg - fixedLeg).mulDivUp(WAD, pos.bond) > uint256(iris.getLoan(pod).bondLltv) * BP;
    }

    /// @dev Rebase a pod right after a venue event, at the same block and price.
    function _sync(address pod, string memory where) internal {
        if (_isOpen(pod)) {
            try iris.rebase(pod) {}
            catch (bytes memory err) {
                _fail(string.concat(where, ":rebase"), pod, err);
            }
        } else if (_isRepayable(pod)) {
            // rebase() is closed once bondRequirement is zero; supplyCollateral still runs _rebase.
            address k = keepers[0];
            _mintApprove(collateralToken, k, address(iris), 1);
            _hit("try:supplyCollateral");
            vm.prank(k);
            try iris.supplyCollateral(pod, 1) {}
            catch (bytes memory err) {
                _fail(string.concat(where, ":supplySync"), pod, err);
            }
        }
    }

    /* Venue-side handlers */

    function take(uint256 venueSeed, uint256 actorSeed, uint256 collSeed, uint256 ltvSeed, uint256 termsSeed)
        external
        probe("take")
    {
        uint256 active;
        for (uint256 i; i < pods.length; ++i) {
            if (_isRepayable(pods[i])) ++active;
        }
        if (active >= MAX_ACTIVE_PODS || pods.length >= MAX_PODS) return;

        uint256 venueId = venueSeed % 2;
        MockVenue v = venues[venueId];
        address b = borrowers[actorSeed % borrowers.length];
        uint256 si = (actorSeed / 7) % solvers.length;

        uint256 collateral = bound(collSeed, 1e18, 1e22);
        uint256 maxDebt = collateral.mulDivDown(v.price(), 1e36).mulDivDown(v.lltv(), WAD);
        uint256 debt = maxDebt.mulDivDown(bound(ltvSeed, 0.3e18, 0.99e18), WAD);
        if (debt < 1e15) return;

        Quote memory q;
        q.borrower = b;
        q.solver = solvers[si];
        q.receiver = b;
        q.blm = address(realBlm);
        q.collateralToken = collateralToken;
        q.debtToken = debtToken;
        q.collateral = collateral;
        q.debt = debt;
        q.fixedRate = (termsSeed % 3001) * BP;
        q.duration = bound(termsSeed >> 16, 1 days, 90 days);
        q.overdueRate = ((termsSeed >> 48) % 2001) * BP;
        q.overduePeriod = (termsSeed >> 80) % (7 days + 1);
        q.bondLltv = bondLltv;
        q.venueBitmap = 3;
        q.venueId = venueId;
        q.deadline = block.timestamp;
        q.nonce = solverNonce[q.solver]++;
        q.data = "";

        uint256 requirement = realBlm.bondRequirement(q);
        if (requirement == 0) return;
        q.bond = bound(termsSeed >> 112, requirement, requirement * 4);

        _mintApprove(collateralToken, b, address(iris), collateral);
        _mintApprove(debtToken, q.solver, address(iris), q.bond);
        bytes memory signature = _signQuote(solverPks[si], q);

        vm.prank(b);
        try iris.take(q, signature) returns (address pod) {
            pods.push(pod);
            _hit("take");
        } catch (bytes memory err) {
            _fail("take", address(0), err);
        }
    }

    function warp(uint256 secondsSeed) external probe("warp") {
        uint256 dt = bound(secondsSeed, 1, 5 days);
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1);
        venues[0].accrue();
        venues[1].accrue();
    }

    function setRate(uint256 venueSeed, uint256 rateSeed) external probe("setRate") {
        venues[venueSeed % 2].setBorrowRate(bound(rateSeed, 0, 0.6e18));
    }

    function movePrice(uint256 seed) external probe("movePrice") {
        uint256 p = venues[0].price().mulDivDown(bound(seed, 0.8e18, 1.2e18), WAD);
        if (p < 1e36) p = 1e36;
        if (p > 100_000e36) p = 100_000e36;
        venues[0].setPrice(p);
        venues[1].setPrice(p);
    }

    function venueLiquidate(uint256 podSeed, uint256 fracSeed, uint256 actorSeed) external probe("venueLiquidate") {
        address pod = _pick(podSeed, _hasVenueDebt);
        if (pod == address(0)) return;
        MockVenue v = _venue(pod);
        uint256 debt = v.debtOf(pod);
        uint256 collateral = v.collateralOf(pod);
        if (debt == 0 || collateral == 0) return;

        if (v.isHealthy(pod)) {
            // Move the shared price just past this pod's liquidation price (1% to 30% below), as a market move would.
            uint256 liquidationPrice = debt.mulDivUp(1e36, collateral).mulDivUp(WAD, v.lltv());
            uint256 p = liquidationPrice.mulDivDown(WAD - bound(actorSeed >> 8, 0.01e18, 0.3e18), WAD);
            // Keep the shared price in a realistic band: a near-zero price turns the known wei-level round-down
            // gap into large collateral-token amounts of no value.
            if (p < 1e36 || p > 100_000e36) return;
            venues[0].setPrice(p);
            venues[1].setPrice(p);
            if (v.isHealthy(pod)) return;
            _hit("vliq:priceMoved");
        }

        uint256 fraction = fracSeed % 2 == 0 ? WAD : bound(fracSeed, 0.01e18, 1e18);
        _venueLiquidate(pod, v, debt.mulDivUp(fraction, WAD), keepers[actorSeed % 3]);
    }

    function _venueLiquidate(address pod, MockVenue v, uint256 amount, address liquidator) internal trackRefund(pod) {
        _mintApprove(debtToken, liquidator, address(v), amount);
        uint256 priceAtLiquidation = v.price();
        bool wasOpen = _isOpen(pod);
        vm.prank(liquidator);
        (, uint256 seized) = v.liquidate(pod, amount);
        ghostLostValue[pod] += seized.mulDivDown(priceAtLiquidation, 1e36);
        _hit(v.debtOf(pod) == 0 ? (v.collateralOf(pod) == 0 ? "vliq:wipe" : "vliq:full") : "vliq:partial");
        if (v.collateralOf(pod) == 0 && v.debtOf(pod) != 0) _hit("vliq:badDebtLeft");

        _sync(pod, "venueLiquidate");
        if (wasOpen && !_isOpen(pod)) _hit("rebase:resolvedBondReq");
        if (!wasOpen) _hit("vliq:afterBondReqZero");
    }

    function directSupply(uint256 podSeed, uint256 amountSeed) external probe("directSupply") {
        address pod = _pick(podSeed, _isOpen);
        if (pod == address(0)) return;
        _directSupply(pod, bound(amountSeed, 1e15, 1e20));
    }

    function _directSupply(address pod, uint256 amount) internal trackRefund(pod) {
        MockVenue v = _venue(pod);
        address k = keepers[1];
        _mintApprove(collateralToken, k, address(v), amount);
        vm.prank(k);
        v.supplyCollateral(pod, amount);
        _sync(pod, "directSupply");
    }

    /* Iris handlers */

    function supplyCollateral(uint256 podSeed, uint256 amountSeed) external probe("supplyCollateral") {
        address pod = _pick(podSeed, podSeed % 4 == 0 ? _isAny : _isRepayable);
        if (pod == address(0)) return;
        _supplyCollateral(pod, bound(amountSeed, 1e15, 1e20));
    }

    function _supplyCollateral(address pod, uint256 amount) internal trackRefund(pod) {
        address k = keepers[2];
        _mintApprove(collateralToken, k, address(iris), amount);
        vm.prank(k);
        try iris.supplyCollateral(pod, amount) {}
        catch (bytes memory err) {
            _fail("supplyCollateral", pod, err);
        }
    }

    function withdrawCollateral(uint256 podSeed, uint256 fracSeed) external probe("withdrawCollateral") {
        address pod = _pick(podSeed, podSeed % 4 == 0 ? _isAny : _isRepayable);
        if (pod == address(0)) return;
        uint256 amount = uint256(iris.getPosition(pod).collateral).mulDivDown(bound(fracSeed, 0.01e18, 1e18), WAD);
        if (amount == 0) return;
        _withdrawCollateral(pod, amount);
    }

    function _withdrawCollateral(address pod, uint256 amount) internal trackRefund(pod) {
        address b = iris.getLoan(pod).borrower;
        vm.prank(b);
        try iris.withdrawCollateral(pod, amount, b) {
            _hit("ok:withdrawCollateral");
        } catch {}
    }

    function supplyBond(uint256 podSeed, uint256 amountSeed) external probe("supplyBond") {
        address pod = _pick(podSeed, _isOpen);
        if (pod == address(0)) return;
        uint256 amount = bound(amountSeed, 1e12, 1e21);
        address s = iris.getLoan(pod).solver;
        _mintApprove(debtToken, s, address(iris), amount);
        _hit("try:supplyBond");
        vm.prank(s);
        try iris.supplyBond(pod, amount) {}
        catch (bytes memory err) {
            _fail("supplyBond", pod, err);
        }
    }

    function withdrawBond(uint256 podSeed, uint256 fracSeed) external probe("withdrawBond") {
        address pod = _pick(podSeed, podSeed % 4 == 0 ? _isAny : _isRepayable);
        if (pod == address(0)) return;
        uint256 amount = uint256(iris.getPosition(pod).bond).mulDivDown(bound(fracSeed, 0.01e18, 1e18), WAD);
        if (amount == 0) return;
        _withdrawBond(pod, amount);
    }

    function _withdrawBond(address pod, uint256 amount) internal trackRefund(pod) {
        address s = iris.getLoan(pod).solver;
        vm.prank(s);
        try iris.withdrawBond(pod, amount, s) {
            _hit(_isOpen(pod) ? "ok:withdrawBond" : "ok:withdrawBondResolved");
        } catch {}
    }

    function repay(uint256 podSeed, uint256 payerSeed) external probe("repay") {
        address pod = _pick(podSeed, _isRepayable);
        if (pod == address(0)) return;
        address payer = payerSeed % 2 == 0 ? iris.getLoan(pod).borrower : keepers[payerSeed % 3];
        _repay(pod, payer);
    }

    function _repay(address pod, address payer) internal trackRefund(pod) {
        _mintApprove(debtToken, payer, address(iris), 1e30);
        _hit("try:repay");
        vm.prank(payer);
        try iris.repay(pod) {}
        catch (bytes memory err) {
            _fail("repay", pod, err);
        }
    }

    function liquidate(uint256 podSeed, uint256 actorSeed) external probe("liquidate") {
        address pod = _pick(podSeed, _isLiquidatable);
        if (pod == address(0)) return;
        _liquidate(pod, keepers[actorSeed % 3]);
    }

    function _liquidate(address pod, address liquidator) internal trackRefund(pod) {
        _mintApprove(debtToken, liquidator, address(iris), 1e30);
        _hit("try:liquidate");
        vm.prank(liquidator);
        try iris.liquidate(pod, liquidator) {}
        catch (bytes memory err) {
            _fail("liquidate", pod, err);
        }
    }

    function liquidateBond(uint256 podSeed, uint256 actorSeed) external probe("liquidateBond") {
        address pod = _pick(podSeed, _isBondLiquidatable);
        if (pod == address(0)) return;
        _liquidateBond(pod, actorSeed % 2 == 0 ? iris.getLoan(pod).borrower : keepers[actorSeed % 3]);
    }

    function _liquidateBond(address pod, address liquidator) internal trackRefund(pod) {
        _hit("try:liquidateBond");
        vm.prank(liquidator);
        try iris.liquidateBond(pod, liquidator) {}
        catch (bytes memory err) {
            _fail("liquidateBond", pod, err);
        }
    }

    function rebase(uint256 podSeed) external probe("rebase") {
        address pod = _pick(podSeed, _isOpen);
        if (pod == address(0)) return;
        _rebase(pod);
    }

    function _rebase(address pod) internal trackRefund(pod) {
        try iris.rebase(pod) {}
        catch (bytes memory err) {
            _fail("rebase", pod, err);
        }
    }

    function refinance(uint256 podSeed) external probe("refinance") {
        address pod = _pick(podSeed, _isOpen);
        if (pod == address(0)) return;
        _refinance(pod);
    }

    function _refinance(address pod) internal trackRefund(pod) {
        Position memory pos = iris.getPosition(pod);
        address s = iris.getLoan(pod).solver;
        _mintApprove(debtToken, s, address(iris), venues[pos.venueId].debtOf(pod) + 1e18);
        vm.prank(s);
        try iris.refinance(pod, s, 1 - pos.venueId, "") {
            _hit("ok:refinance");
        } catch {}
    }

    function escape(uint256 podSeed) external probe("escape") {
        address pod = _pick(podSeed, _isResolved);
        if (pod == address(0)) return;
        MockVenue v = _venue(pod);
        if (v.collateralOf(pod) == 0 && v.debtOf(pod) == 0) return;
        address b = iris.getLoan(pod).borrower;
        _mintApprove(debtToken, b, address(iris), v.debtOf(pod) + 1e18);
        _hit("try:escape");
        vm.prank(b);
        try iris.escape(pod, b) {}
        catch (bytes memory err) {
            _fail("escape", pod, err);
        }
    }

    function claim(uint256 actorSeed, uint256 tokenSeed) external probe("claim") {
        address token = tokenSeed % 2 == 0 ? debtToken : collateralToken;
        address[] memory accounts = _accounts();
        address account = accounts[actorSeed % accounts.length];
        uint256 amount = iris.claimable(token, account);
        if (amount == 0) return;
        _hit("try:claim");
        vm.prank(account);
        try iris.claim(token, amount, account, account) {}
        catch (bytes memory err) {
            _fail("claim", address(0), err);
        }
    }

    function _accounts() internal view returns (address[] memory accounts) {
        accounts = new address[](borrowers.length + solvers.length + keepers.length + 1);
        uint256 n;
        for (uint256 i; i < borrowers.length; ++i) {
            accounts[n++] = borrowers[i];
        }
        for (uint256 i; i < solvers.length; ++i) {
            accounts[n++] = solvers[i];
        }
        for (uint256 i; i < keepers.length; ++i) {
            accounts[n++] = keepers[i];
        }
        accounts[n] = feeRecipient;
    }

    /* Invariants */

    function invariantLiveness() public view {
        for (uint256 i; i < failures.length; ++i) {
            console.log(failures[i]);
        }
        assertEq(failures.length, 0, "a call that must succeed reverted");
    }

    function invariantSolvency() public view {
        address[] memory accounts = _accounts();
        uint256 debtLiabilities;
        uint256 collateralLiabilities;
        for (uint256 i; i < accounts.length; ++i) {
            debtLiabilities += iris.claimable(debtToken, accounts[i]);
            collateralLiabilities += iris.claimable(collateralToken, accounts[i]);
        }
        for (uint256 i; i < pods.length; ++i) {
            debtLiabilities += iris.getPosition(pods[i]).bond;
        }
        assertGe(ERC20(debtToken).balanceOf(address(iris)) + TOL, debtLiabilities, "debt-token solvency");
        assertGe(ERC20(collateralToken).balanceOf(address(iris)) + TOL, collateralLiabilities, "collateral solvency");
    }

    /// @dev Repay/liquidate forward venueDebt while charging debt + fixedLeg + badBond, so the pool stays whole only
    /// if the tracked debt and floating leg cover the venue debt.
    function invariantTrackedDebtCoversVenue() public view {
        for (uint256 i; i < pods.length; ++i) {
            address pod = pods[i];
            Position memory pos = iris.getPosition(pod);
            if (pos.bondRequirement == 0) continue;
            (,,, uint256 floatingLeg,) = iris.accrueLegsView(pod);
            uint256 venueDebt = _venue(pod).debtOf(pod);
            assertGe(uint256(pos.debt) + floatingLeg + TOL, venueDebt, "tracked debt + floating below venue debt");
        }
    }

    /// @dev Liquidate exits min(seized + surplus, venueCollateral) but pays out seized and surplus in full.
    function invariantTrackedCollateralWithinVenue() public view {
        for (uint256 i; i < pods.length; ++i) {
            address pod = pods[i];
            if (!_isRepayable(pod)) continue;
            Position memory pos = iris.getPosition(pod);
            (,,,, uint256 surplus) = iris.accrueLegsView(pod);
            uint256 venueCollateral = _venue(pod).collateralOf(pod);
            assertLe(uint256(pos.collateral) + surplus, venueCollateral + TOL, "tracked collateral above venue");
        }
    }

    /// @dev Header: the borrower is credited at most the value of the collateral they lost.
    function invariantRefundWithinLoss() public view {
        for (uint256 i; i < pods.length; ++i) {
            assertLe(ghostRefund[pods[i]], ghostLostValue[pods[i]] + TOL, "borrower refund above collateral lost");
        }
    }

    function invariantBondRequirementHoldsBond() public view {
        for (uint256 i; i < pods.length; ++i) {
            Position memory pos = iris.getPosition(pods[i]);
            if (pos.bondRequirement != 0) assertGt(pos.bond, 0, "bondRequirement without bond");
        }
    }
}
