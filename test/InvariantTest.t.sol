// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";

import "./ForkTest.t.sol";

abstract contract InvariantTest is ForkTest {
    using SafeTransferLib for address;
    using MathLib for uint256;

    bytes4[] internal selectors;
    address[] internal pods;

    mapping(address user => uint256 pk) internal userPk;
    mapping(address user => uint256 nonce) internal userNonce;

    /* Setup */

    function setUp() public virtual override {
        super.setUp();

        // Cap Morpho borrow sizing below full utilization: at 100% the Adaptive Curve IRM ramps the borrow
        // index high enough to overflow a uint128 venue-index snapshot under the suite's time warps.
        targetMorphoUtilization = 0.95e18;
        _supplyMorpho();
        _setDefaultBlmParams();

        _targetSenders();

        _weightSelector(this.mine.selector, 100);

        targetContract(address(this));
        targetSelector(FuzzSelector({addr: address(this), selectors: selectors}));
    }

    modifier logCall(string memory name) {
        console.log(msg.sender, "->", name);

        _;
    }

    // supply to morpho so invariant runs can reach take paths more often.
    function _supplyMorpho() internal {
        uint256 amount = 20 * MAX_TEST_AMOUNT;
        for (uint256 i; i < config.morphoMarketIdList.length; ++i) {
            MarketParams memory marketParams =
                MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            deal(marketParams.loanToken, address(this), amount);
            MorphoBlueUtils.supply(morphoBlue, marketParams, amount, address(this));
        }
    }

    /// @dev Realize Morpho interest on every time jump. The adapter derives the Morpho debt index by
    /// extrapolating stale market totals through the Adaptive Curve IRM's average-rate approximation,
    /// which is only quasi-monotonic in the extrapolation window: over a long warp with no market write
    /// (impossible on live markets, which are touched continuously) the derived index can dip below a
    /// pod's stored snapshot and revert accrual. Writing the market at each warp keeps every index the
    /// suite reads a realized, monotone value.
    function _forward(uint256 blocks) internal override {
        super._forward(blocks);
        for (uint256 i; i < config.morphoMarketIdList.length; ++i) {
            IMorpho(morphoBlue)
                .accrueInterest(MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]));
        }
    }

    function _setDefaultBlmParams() internal {
        vm.startPrank(owner);
        for (uint256 i; i < config.morphoMarketIdList.length; ++i) {
            MarketParams memory marketParams =
                MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            address token = marketParams.loanToken;
            // 1bp slope, 1bp intercept (Make bond liquidation more likely.)
            if (blm.slope(token) == 0) blm.setParams(token, 0.0001e18, 0.0001e18);
        }
        vm.stopPrank();
    }

    function _targetSenders() internal virtual {
        _targetSender("Sender1");
        _targetSender("Sender2");
        _targetSender("Sender3");
        _targetSender("Sender4");
        _targetSender("Sender5");
        _targetSender("Sender6");
        _targetSender("Sender7");
        _targetSender("Sender8");
    }

    function _targetSender(string memory name) internal {
        (address user, uint256 userPk_) = makeAddrAndKey(name);
        userPk[user] = userPk_;
        targetSender(user);
    }

    function _weightSelector(bytes4 selector, uint256 weight) internal {
        for (uint256 i; i < weight; ++i) {
            selectors.push(selector);
        }
    }

    function _approveIris(address token, address account, uint256 amount) internal {
        vm.startPrank(account);
        token.safeApproveWithRetry(address(iris), amount);
        vm.stopPrank();
    }

    /* Handlers */

    function mine(uint256 blocks) external {
        blocks = bound(blocks, 1, 1 days / BLOCK_TIME);

        _forward(blocks);
    }

    /* Random selections */

    function _randomMarket(uint256 seed)
        internal
        view
        returns (address collateralToken_, address debtToken_, bytes memory data_, uint256 venueId_)
    {
        venueId_ = bound(seed, 0, uint256(type(VenueId).max));
        (collateralToken_, debtToken_, data_,) = _randomMarket(seed, venueId_);
    }

    function _randomUser(uint256 seed) internal view returns (address user, uint256 pk) {
        address[] memory users = targetSenders();
        user = users[seed % users.length];
        pk = userPk[user];
    }

    function _randomClaimable(uint256 seed) internal view returns (address token, address onBehalf) {
        address[] memory users = targetSenders();
        address[] memory tokens = new address[](pods.length * 2 * (users.length + 1));
        address[] memory onBehalfs = new address[](tokens.length);
        uint256 count;

        for (uint256 i; i < pods.length; ++i) {
            Loan memory loan = iris.getLoan(pods[i]);
            address[2] memory loanTokens = [loan.collateralToken, loan.debtToken];

            for (uint256 j; j < loanTokens.length; ++j) {
                for (uint256 k; k < users.length; ++k) {
                    if (iris.claimable(loanTokens[j], users[k]) == 0) continue;
                    tokens[count] = loanTokens[j];
                    onBehalfs[count++] = users[k];
                }
                if (iris.claimable(loanTokens[j], feeRecipient) != 0) continue;
                tokens[count] = loanTokens[j];
                onBehalfs[count++] = feeRecipient;
            }
        }
        if (count == 0) return (address(0), address(0));

        uint256 index = bound(seed, 0, count - 1);
        return (tokens[index], onBehalfs[index]);
    }

    function _randomPod(uint256 seed, function(address) internal view returns (bool) predicate)
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

        return candidates[bound(seed, 0, count - 1)];
    }

    function _randomOpenPod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isOpenPod);
    }

    function _randomResolvedPod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isResolvedPod);
    }

    function _randomEarlyRepayablePod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isEarlyRepayablePod);
    }

    function _randomMaturedRepayablePod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isMaturedRepayablePod);
    }

    function _randomLiquidatablePod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isLiquidatablePod);
    }

    function _randomBondLiquidatablePod(uint256 seed) internal view returns (address) {
        return _randomPod(seed, _isBondLiquidatablePod);
    }

    function _refinanceTarget(address pod) internal view returns (uint256 newVenueId, bytes memory data) {
        Loan memory loan = iris.getLoan(pod);
        Position memory pos = iris.getPosition(pod);

        if (pos.venueId == uint8(VenueId.MORPHO_BLUE)) return (uint256(VenueId.AAVE_V3), "");

        for (uint256 i; i < config.morphoMarketIdList.length; ++i) {
            MarketParams memory marketParams =
                MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            if (marketParams.collateralToken == loan.collateralToken && marketParams.loanToken == loan.debtToken) {
                return (uint256(VenueId.MORPHO_BLUE), abi.encode(marketParams));
            }
        }
        revert("IrisInvariantTest: no Morpho market for pair");
    }

    /* Pod states */

    function _isCreatedPod(address pod) internal view returns (bool) {
        return iris.getPosition(pod).lastUpdate != 0;
    }

    function _isOpenPod(address pod) internal view returns (bool) {
        return iris.getPosition(pod).bondRequirement != 0;
    }

    function _isResolvedPod(address pod) internal view returns (bool) {
        Position memory pos = iris.getPosition(pod);

        return pos.lastUpdate != 0 && pos.bondRequirement == 0;
    }

    function _isRepayablePod(address pod) internal view returns (bool) {
        if (!_isCreatedPod(pod)) return false;

        Position memory pos = iris.getPosition(pod);

        return uint256(pos.debt) + pos.fixedLeg != 0 || pos.bondRequirement != 0;
    }

    function _isEarlyRepayablePod(address pod) internal view returns (bool) {
        return _isRepayablePod(pod) && block.timestamp < iris.getLoan(pod).maturity;
    }

    function _isMaturedRepayablePod(address pod) internal view returns (bool) {
        return _isRepayablePod(pod) && block.timestamp >= iris.getLoan(pod).maturity;
    }

    function _isLiquidatablePod(address pod) internal view returns (bool) {
        if (!_isCreatedPod(pod)) return false;

        Position memory pos = iris.getPosition(pod);
        Loan memory loan = iris.getLoan(pod);

        if (uint256(pos.debt) + pos.fixedLeg == 0) return false;

        return block.timestamp > uint256(loan.maturity) + loan.overduePeriod;
    }

    function _isBondLiquidatablePod(address pod) internal view returns (bool) {
        if (!_isCreatedPod(pod)) return false;

        Position memory pos = iris.getPosition(pod);
        Loan memory loan = iris.getLoan(pod);

        if (pos.bondRequirement == 0) return false;
        if (pos.bond < pos.bondRequirement) return true;

        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        if (floatingLeg <= fixedLeg) return false;

        return (floatingLeg - fixedLeg).mulDivUp(WAD, pos.bond) > uint256(loan.bondLltv) * BP;
    }

    /* Amounts */

    function _repayAmount(address pod) internal view returns (uint256) {
        Position memory pos = iris.getPosition(pod);
        if (pos.lastUpdate == 0) return 0;

        Loan memory loan = iris.getLoan(pod);

        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);
        if (block.timestamp < loan.maturity) {
            uint256 timeToMaturity = uint256(loan.maturity) - block.timestamp;
            fixedLeg += uint256(pos.debt)
                .mulDivDown(timeToMaturity * uint256(loan.fixedRate) * BP, SECONDS_PER_YEAR * WAD);
        }

        uint256 negativeNet = floatingLeg > fixedLeg ? floatingLeg - fixedLeg : 0;
        uint256 badBond = negativeNet.zeroFloorSub(pos.bond);

        return uint256(pos.debt) + fixedLeg + badBond;
    }

    function _maxWithdrawCollateral(address pod) internal view returns (uint256) {
        Position memory pos = iris.getPosition(pod);
        if (pos.lastUpdate == 0) return 0;

        Loan memory loan = iris.getLoan(pod);
        IVenueAdapter adapter = IVenueAdapter(iris.venueAdapter(pos.venueId));
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);

        uint256 price = adapter.price(loan.collateralToken, loan.debtToken, pos.data);
        uint256 lltv = adapter.lltv(loan.collateralToken, loan.debtToken, pos.data);
        uint256 timeToLiquidation = uint256(loan.maturity + loan.overduePeriod).zeroFloorSub(block.timestamp);
        uint256 residual = uint256(pos.debt)
            .mulDivDown(
                timeToLiquidation * loan.fixedRate * BP + MathLib.min(timeToLiquidation, loan.overduePeriod)
                    * loan.overdueRate * BP,
                SECONDS_PER_YEAR * WAD
            );
        uint256 exposure = MathLib.max(fixedLeg + residual, floatingLeg.zeroFloorSub(pos.bond));
        uint256 irisMin = (uint256(pos.debt) + exposure).mulDivUp(WAD, lltv).mulDivUp(ORACLE_PRICE_SCALE, price);

        (uint256 venueCollateral, uint256 venueDebt) =
            adapter.positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        uint256 venueMin = _minCollateralAmount(venueDebt, loan.collateralToken, loan.debtToken, pos.venueId, pos.data);

        return MathLib.min(uint256(pos.collateral).zeroFloorSub(irisMin), venueCollateral.zeroFloorSub(venueMin));
    }

    function _maxWithdrawBond(address pod) internal view returns (uint256) {
        Position memory pos = iris.getPosition(pod);
        if (pos.bondRequirement == 0) return pos.bond;

        Loan memory loan = iris.getLoan(pod);
        (,, uint256 fixedLeg, uint256 floatingLeg,) = iris.accrueLegsView(pod);

        uint256 minBond = pos.bondRequirement;
        if (floatingLeg > fixedLeg) {
            minBond = MathLib.max(minBond, (floatingLeg - fixedLeg).mulDivUp(WAD, uint256(loan.bondLltv) * BP));
        }

        return uint256(pos.bond).zeroFloorSub(minBond);
    }
}
