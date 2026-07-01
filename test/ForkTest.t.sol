// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "./BaseTest.t.sol";

import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {MorphoBlueAdapter} from "../src/adapters/MorphoBlueAdapter.sol";
import {Blm} from "../src/blm/Blm.sol";

import "./fork/helpers/NetworkConfig.sol";
import {MorphoBlueUtils, MorphoBlueErrors} from "./fork/helpers/MorphoBlueUtils.sol";
import {AaveV3Utils, AaveV3Errors} from "./fork/helpers/AaveV3Utils.sol";

/// @dev Minimal Lido interface used by the `deal` override to mint stETH (it cannot be `deal`t directly
/// because its balance is derived from internal shares).
interface IStEth {
    function submit(address referral) external payable returns (uint256);
}

abstract contract ForkTest is BaseTest, NetworkConfig {
    using stdJson for string;
    using MathLib for uint256;
    using SafeTransferLib for address;

    enum VenueId {
        AAVE_V3,
        MORPHO_BLUE
    }

    string internal chain;
    uint256 internal forkBlock;
    address internal aaveV3Pool;
    address internal morphoBlue;

    uint256 internal constant DEFAULT_SLOPE = 0.01e18; // 100 bp
    uint256 internal constant DEFAULT_INTERCEPT = 0.005e18; // 50 bp

    AaveV3Adapter internal aaveV3Adapter;
    MorphoBlueAdapter internal morphoBlueAdapter;

    uint256 internal targetMorphoUtilization = WAD;

    function setUp() public virtual override {
        string memory rpc = vm.rpcUrl(config.network);

        if (config.blockNumber == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, config.blockNumber);

        // Deploys Iris + pod impl and enables bondLltv, data("") and feeRecipient.
        super.setUp();

        aaveV3Pool = getAddress("aaveV3Pool");
        morphoBlue = getAddress("morphoBlue");

        aaveV3Adapter = new AaveV3Adapter(aaveV3Pool);
        morphoBlueAdapter = new MorphoBlueAdapter(morphoBlue);
        blm = IBlm(address(new Blm(address(iris))));

        setAddress("aaveV3Adapter", address(aaveV3Adapter));
        setAddress("morphoBlueAdapter", address(morphoBlueAdapter));
        setAddress("blm", address(blm));

        vm.startPrank(owner);
        iris.setVenueAdapter(uint256(VenueId.AAVE_V3), address(aaveV3Adapter));
        iris.setVenueAdapter(uint256(VenueId.MORPHO_BLUE), address(morphoBlueAdapter));
        iris.enableBlm(address(blm));

        for (uint256 i; i < config.morphoMarketIdList.length; i++) {
            MarketParams memory marketParams =
                MorphoBlueUtils.idToMarketParams(morphoBlue, config.morphoMarketIdList[i]);
            require(
                marketParams.collateralToken != address(0) && marketParams.loanToken != address(0),
                "ForkTest: unknown morpho market id"
            );
            iris.enableData(keccak256(abi.encode(marketParams)));
        }

        vm.stopPrank();
    }

    /* LOAN OPEN */

    /// @dev Funds (deal collateral to borrower, bond to solver), approves, signs as `solver`, and takes.
    /// The caller builds the quote (quote.solver must be `solver`).
    function _openLoan(Quote memory quote) internal returns (address pod) {
        bytes memory signature = _signQuote(solverPk, quote);

        deal(quote.collateralToken, quote.borrower, quote.collateral);
        deal(quote.debtToken, quote.solver, quote.bond);

        vm.prank(quote.solver);
        quote.debtToken.safeApprove(address(iris), quote.bond);

        vm.startPrank(quote.borrower);
        quote.collateralToken.safeApprove(address(iris), quote.collateral);
        pod = iris.take(quote, signature);
        vm.stopPrank();
    }

    /* MARKET SELECTION */

    /// @dev Two-venue (Aave/Morpho) only: markets are sourced from Morpho and `data` is branched per venue.
    /// @dev NOTE: Update the market sourcing and the if/else when a 3rd venue or new chain is added.
    function _randomMarket(uint256 seed, uint256 venueId)
        internal
        view
        returns (address collateralToken, address debtToken, bytes memory data, IVenueAdapter adapter)
    {
        MarketParams memory marketParams =
            MorphoBlueUtils.randomMarketParams(morphoBlue, seed, config.morphoMarketIdList);
        collateralToken = marketParams.collateralToken;
        debtToken = marketParams.loanToken;
        adapter = IVenueAdapter(iris.venueAdapter(venueId));

        if (venueId == uint256(VenueId.AAVE_V3)) {
            vm.assume(aaveV3Adapter.lltv(collateralToken, debtToken, "") != 0);
            data = "";
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            data = abi.encode(marketParams);
        } else {
            revert("ForkTest: Invalid venue ID");
        }
    }

    /* HELPERS */

    function deal(address asset, address recipient, uint256 amount) internal virtual override {
        address wEth = getAddress("WETH");
        address stEth = getAddress("stETH");

        if (amount == 0) return;
        if (asset == wEth) super.deal(wEth, wEth.balance + amount); // Refill wrapped Ether.
        if (asset == stEth) {
            deal(recipient, amount);
            vm.prank(recipient);
            uint256 stEthAmount = IStEth(stEth).submit{value: amount}(address(0));
            vm.assume(stEthAmount != 0);
            return;
        }

        return super.deal(asset, recipient, amount);
    }

    function _mockPositionAssets(
        IVenueAdapter adapter,
        address pod,
        address collateralToken,
        address debtToken,
        bytes memory data,
        uint256 venueCollateral,
        uint256 venueDebt
    ) internal {
        vm.mockCall(
            address(adapter),
            abi.encodeWithSelector(IVenueAdapter.positionAssets.selector, pod, collateralToken, debtToken, data),
            abi.encode(venueCollateral, venueDebt)
        );
    }

    /* BOUNDS */

    /// @dev Bounds (collateral, debt) to a position openable on `venueId` at the current block.
    function _boundHealthyPosition(
        address collateralToken,
        address debtToken,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 venueId,
        bytes memory data
    ) internal view returns (uint256, uint256) {
        uint256 maxBorrow = _maxBorrowable(collateralToken, debtToken, venueId, data);
        uint256 maxCollateral = _maxSuppliable(collateralToken, venueId, data);

        // Skip draws where the venue can't support a meaningful borrow (a reserve at its supply cap, or a
        // thin Morpho market), which would otherwise make the borrowAmount bound empty.
        vm.assume(maxBorrow >= MIN_TEST_AMOUNT);
        vm.assume(maxCollateral >= MIN_TEST_AMOUNT);

        borrowAmount = bound(borrowAmount, MIN_TEST_AMOUNT, maxBorrow);
        uint256 minCollateralAmount = _minCollateralAmount(borrowAmount, collateralToken, debtToken, venueId, data);
        // Unreachable, kept as an explicit sanity check for easier debugging.
        // If this fails, check the min/max collateral-borrow inverse math for the selected venue.
        require(minCollateralAmount <= maxCollateral, "ForkTest: minCollateral > maxCollateral");

        collateralAmount = bound(collateralAmount, minCollateralAmount, maxCollateral);

        return (collateralAmount, borrowAmount);
    }

    /* MIN/MAX SUPPLIABLE/BORROWABLE */

    /// @dev Maximum suppliable amount supported at the venue, read from venue state.
    function _maxSuppliable(address token, uint256 venueId, bytes memory data) internal view returns (uint256) {
        uint256 maxSupplyCapacity;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            maxSupplyCapacity = AaveV3Utils.maxSupplyCapacity(0, aaveV3Pool, token);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            maxSupplyCapacity = MorphoBlueUtils.maxSupplyCapacity(0, morphoBlue, data);
        } else {
            revert("ForkTest: Invalid venue ID");
        }

        return MathLib.min(maxSupplyCapacity, MAX_TEST_AMOUNT);
    }

    /// @dev Maximum borrowable amount supported at the venue, read from venue state.
    function _maxBorrowable(address collateralToken, address debtToken, uint256 venueId, bytes memory data)
        internal
        view
        returns (uint256)
    {
        uint256 maxCollateralAmount = _maxSuppliable(collateralToken, venueId, data);
        uint256 maxBorrowAmount = _maxBorrowAmount(maxCollateralAmount, collateralToken, debtToken, venueId, data);
        uint256 maxBorrowCapacity;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            maxBorrowCapacity = AaveV3Utils.maxBorrowCapacity(aaveV3Pool, debtToken);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowCapacity = MorphoBlueUtils.maxBorrowCapacity(morphoBlue, data, targetMorphoUtilization);
        } else {
            revert("ForkTest: Invalid venue ID");
        }

        return MathLib.min(MathLib.min(maxBorrowAmount, maxBorrowCapacity), MAX_TEST_AMOUNT);
    }

    /* MIN/MAX AMOUNT */

    /// @dev Minimum collateral amount required to borrow `amount` of debt token
    function _minCollateralAmount(
        uint256 amount,
        address collateralToken,
        address debtToken,
        uint256 venueId,
        bytes memory data
    ) internal view returns (uint256) {
        uint256 minCollateralAmount;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            minCollateralAmount = AaveV3Utils.minCollateralAmount(amount, aaveV3Pool, collateralToken, debtToken);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            minCollateralAmount = MorphoBlueUtils.minCollateralAmount(amount, morphoBlue, data);
        } else {
            revert("ForkTest: Invalid venue ID");
        }

        return MathLib.max(minCollateralAmount, MIN_TEST_AMOUNT);
    }

    /// @dev Calculate max borrow amount (using max ltv in the case of Aave) for given `amount` of collateral token.
    function _maxBorrowAmount(
        uint256 amount,
        address collateralToken,
        address debtToken,
        uint256 venueId,
        bytes memory data
    ) internal view returns (uint256) {
        uint256 maxBorrowAmount;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            maxBorrowAmount = AaveV3Utils.maxBorrowAmount(amount, aaveV3Pool, collateralToken, debtToken);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            maxBorrowAmount = MorphoBlueUtils.maxBorrowAmount(amount, morphoBlue, data);
        } else {
            revert("ForkTest: Invalid venue ID");
        }

        return MathLib.min(maxBorrowAmount, MAX_TEST_AMOUNT);
    }

    /// @dev Calculate max debt for given `amount` of collateral token.
    function _maxDebtAmount(
        uint256 amount,
        address collateralToken,
        address debtToken,
        uint256 venueId,
        bytes memory data
    ) internal view returns (uint256) {
        uint256 maxDebtAmount;

        if (venueId == uint256(VenueId.AAVE_V3)) {
            maxDebtAmount = AaveV3Utils.maxDebtAmount(amount, aaveV3Pool, collateralToken, debtToken);
        } else if (venueId == uint256(VenueId.MORPHO_BLUE)) {
            maxDebtAmount = MorphoBlueUtils.maxDebtAmount(amount, morphoBlue, data);
        } else {
            revert("ForkTest: Invalid venue ID");
        }

        return MathLib.min(maxDebtAmount, MAX_TEST_AMOUNT);
    }
}
