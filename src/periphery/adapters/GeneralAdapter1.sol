// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.35;

import {IWNative} from "../interfaces/IWNative.sol";
import {ERC4626} from "@solady/tokens/ERC4626.sol";
import {IMorpho} from "@morpho-blue/interfaces/IMorpho.sol";
import {CoreAdapter, ErrorsLib, SafeTransferLib} from "./CoreAdapter.sol";
import {MathRayLib} from "../libraries/MathRayLib.sol";
import {IIris, Loan, Quote} from "../../interfaces/IIris.sol";

/// @notice Chain agnostic adapter contract n°1.
contract GeneralAdapter1 is CoreAdapter {
    using SafeTransferLib for address;
    using MathRayLib for uint256;

    /* IMMUTABLES */

    /// @notice The address of the Morpho contract.
    IMorpho public immutable MORPHO;

    /// @dev The address of the wrapped native token.
    IWNative public immutable WRAPPED_NATIVE;

    /// @notice The address of the Iris contract.
    IIris public immutable IRIS;

    /* CONSTRUCTOR */

    /// @param bundler3 The address of the Bundler3 contract.
    /// @param morpho The address of the Morpho protocol.
    /// @param wNative The address of the canonical native token wrapper.
    /// @param iris The address of the Iris protocol.
    constructor(address bundler3, address morpho, address wNative, address iris) CoreAdapter(bundler3) {
        require(morpho != address(0), ErrorsLib.ZeroAddress());
        require(wNative != address(0), ErrorsLib.ZeroAddress());
        require(iris != address(0), ErrorsLib.ZeroAddress());

        MORPHO = IMorpho(morpho);
        WRAPPED_NATIVE = IWNative(wNative);
        IRIS = IIris(iris);
    }

    /* ERC4626 ACTIONS */

    /// @notice Mints shares of an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to mint.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Mint(address vault, uint256 shares, uint256 maxSharePriceE27, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(shares != 0, ErrorsLib.ZeroShares());

        address underlyingToken = ERC4626(vault).asset();
        underlyingToken.safeApproveWithRetry(vault, type(uint256).max);

        uint256 assets = ERC4626(vault).mint(shares, receiver);

        underlyingToken.safeApproveWithRetry(vault, 0);

        require(assets.rDivUp(shares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Deposits underlying token in an ERC4626 vault.
    /// @dev Underlying tokens must have been previously sent to the adapter.
    /// @dev Assumes the given vault implements EIP-4626.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to deposit. Pass `type(uint).max` to deposit the adapter's balance.
    /// @param maxSharePriceE27 The maximum amount of assets to pay to get 1 share, scaled by 1e27.
    /// @param receiver The address to which shares will be minted.
    function erc4626Deposit(address vault, uint256 assets, uint256 maxSharePriceE27, address receiver)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address underlyingToken = ERC4626(vault).asset();
        if (assets == type(uint256).max) assets = underlyingToken.balanceOf(address(this));

        require(assets != 0, ErrorsLib.ZeroAmount());

        underlyingToken.safeApproveWithRetry(vault, type(uint256).max);

        uint256 shares = ERC4626(vault).deposit(assets, receiver);

        underlyingToken.safeApproveWithRetry(vault, 0);

        require(assets.rDivUp(shares) <= maxSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Withdraws underlying token from an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param assets The amount of underlying token to withdraw.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the assets are withdrawn. Can only be the adapter or the initiator.
    function erc4626Withdraw(address vault, uint256 assets, uint256 minSharePriceE27, address receiver, address owner)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(owner == address(this) || owner == initiator(), ErrorsLib.UnexpectedOwner());
        require(assets != 0, ErrorsLib.ZeroAmount());

        uint256 shares = ERC4626(vault).withdraw(assets, receiver, owner);
        require(assets.rDivDown(shares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /// @notice Redeems shares of an ERC4626 vault.
    /// @dev Assumes the given `vault` implements EIP-4626.
    /// @dev If `owner` is the initiator, they must have previously approved the adapter to spend their vault shares.
    /// Otherwise, vault shares must have been previously sent to the adapter.
    /// @param vault The address of the vault.
    /// @param shares The amount of vault shares to redeem. Pass `type(uint).max` to redeem the owner's shares.
    /// @param minSharePriceE27 The minimum number of assets to receive per share, scaled by 1e27.
    /// @param receiver The address that will receive the withdrawn assets.
    /// @param owner The address on behalf of which the shares are redeemed. Can only be the adapter or the initiator.
    function erc4626Redeem(address vault, uint256 shares, uint256 minSharePriceE27, address receiver, address owner)
        external
        onlyBundler3
    {
        require(receiver != address(0), ErrorsLib.ZeroAddress());
        require(owner == address(this) || owner == initiator(), ErrorsLib.UnexpectedOwner());

        if (shares == type(uint256).max) shares = ERC4626(vault).balanceOf(owner);

        require(shares != 0, ErrorsLib.ZeroShares());

        uint256 assets = ERC4626(vault).redeem(shares, receiver, owner);
        require(assets.rDivDown(shares) >= minSharePriceE27, ErrorsLib.SlippageExceeded());
    }

    /* MORPHO CALLBACKS */

    /// @notice Receives flashloan callback from the Morpho contract.
    /// @param data Bytes containing an abi-encoded Call[].
    function onMorphoFlashLoan(uint256, bytes calldata data) external {
        morphoCallback(data);
    }

    /* MORPHO ACTIONS */

    /// @notice Triggers a flash loan on Morpho.
    /// @param token The address of the token to flash loan.
    /// @param assets The amount of assets to flash loan.
    /// @param data Arbitrary data to pass to the `onMorphoFlashLoan` callback.
    function morphoFlashLoan(address token, uint256 assets, bytes calldata data) external onlyBundler3 {
        require(assets != 0, ErrorsLib.ZeroAmount());
        // Morpho's allowance is not reset as it is trusted.
        token.safeApproveWithRetry(address(MORPHO), type(uint256).max);

        MORPHO.flashLoan(token, assets, data);
    }

    /* IRIS ACTIONS */

    /// @notice Opens an Iris loan with a solver-signed quote.
    /// @dev Collateral tokens must have been previously sent to the adapter. The bond is pulled by Iris
    /// from the solver directly, not from the adapter.
    /// @dev The quote's borrower is not required to be the initiator: the collateral is paid by the
    /// bundle and accrues to the borrower, so opening on someone else's behalf is a donation.
    /// @param quote The solver-signed quote to take.
    /// @param signature The solver's signature of the quote.
    function irisTake(Quote calldata quote, bytes calldata signature) external onlyBundler3 {
        // Iris's allowance is not reset as it is trusted.
        quote.collateralToken.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.take(quote, signature);
    }

    /// @notice Repays an Iris loan.
    /// @dev Debt tokens must have been previously sent to the adapter; the adapter's balance caps the
    /// pull. The repaid amount accrues per second, so send a small buffer and sweep the leftover at the
    /// end of the bundle.
    /// @dev A `token` not matching the loan's debt token makes the pull revert at Iris's level.
    /// @param pod The pod of the loan to repay.
    /// @param token The loan's debt token.
    function irisRepay(address pod, address token) external onlyBundler3 {
        // Iris's allowance is not reset as it is trusted.
        token.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.repay(pod);
    }

    /// @notice Supplies collateral to an Iris loan.
    /// @dev Collateral tokens must have been previously sent to the adapter.
    /// @dev A `token` not matching the loan's collateral token makes the pull revert at Iris's level.
    /// @param pod The pod of the loan.
    /// @param token The loan's collateral token.
    /// @param amount The amount of collateral to supply. Pass `type(uint).max` to supply the adapter's balance.
    function irisSupplyCollateral(address pod, address token, uint256 amount) external onlyBundler3 {
        if (amount == type(uint256).max) amount = token.balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        // Iris's allowance is not reset as it is trusted.
        token.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.supplyCollateral(pod, amount);
    }

    /// @notice Withdraws collateral from an Iris loan.
    /// @dev Initiator must be the loan's borrower and must have previously authorized the adapter on
    /// Iris. Without this check, anyone could route another borrower's collateral to themselves through
    /// the borrower's standing adapter authorization.
    /// @param pod The pod of the loan.
    /// @param amount The amount of collateral to withdraw.
    /// @param receiver The address that will receive the withdrawn collateral.
    function irisWithdrawCollateral(address pod, uint256 amount, address receiver) external onlyBundler3 {
        require(IRIS.getLoan(pod).borrower == initiator(), ErrorsLib.UnauthorizedInitiator());

        IRIS.withdrawCollateral(pod, amount, receiver);
    }

    /// @notice Supplies bond to an Iris loan.
    /// @dev Debt tokens must have been previously sent to the adapter.
    /// @dev A `token` not matching the loan's debt token makes the pull revert at Iris's level.
    /// @param pod The pod of the loan.
    /// @param token The loan's debt token.
    /// @param amount The amount of bond to supply. Pass `type(uint).max` to supply the adapter's balance.
    function irisSupplyBond(address pod, address token, uint256 amount) external onlyBundler3 {
        if (amount == type(uint256).max) amount = token.balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        // Iris's allowance is not reset as it is trusted.
        token.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.supplyBond(pod, amount);
    }

    /// @notice Withdraws bond from an Iris loan.
    /// @dev Initiator must be the loan's solver and must have previously authorized the adapter on
    /// Iris. Without this check, anyone could route another solver's bond to themselves through the
    /// solver's standing adapter authorization.
    /// @param pod The pod of the loan.
    /// @param amount The amount of bond to withdraw.
    /// @param receiver The address that will receive the withdrawn bond.
    function irisWithdrawBond(address pod, uint256 amount, address receiver) external onlyBundler3 {
        require(IRIS.getLoan(pod).solver == initiator(), ErrorsLib.UnauthorizedInitiator());

        IRIS.withdrawBond(pod, amount, receiver);
    }

    /// @notice Refinances an Iris loan to a new venue.
    /// @dev Initiator must be the loan's solver and must have previously authorized the adapter on
    /// Iris. Without this check, anyone could rebalance an adapter-authorized solver's venue allocation
    /// against their strategy at gas cost only.
    /// @dev Debt tokens covering the current venue debt must have been previously sent to the adapter
    /// (or flash loaned within the bundle); the adapter's balance caps the pull. The new venue's borrow
    /// proceeds are sent to `receiver`.
    /// @param pod The pod of the loan.
    /// @param receiver The address that will receive the new venue's borrow proceeds.
    /// @param newVenueId The id of the venue to refinance to.
    /// @param data The new venue's market data.
    function irisRefinance(address pod, address receiver, uint256 newVenueId, bytes calldata data)
        external
        onlyBundler3
    {
        Loan memory loan = IRIS.getLoan(pod);
        require(loan.solver == initiator(), ErrorsLib.UnauthorizedInitiator());

        // Iris's allowance is not reset as it is trusted.
        loan.debtToken.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.refinance(pod, receiver, newVenueId, data);
    }

    /// @notice Escapes a resolved Iris loan, exiting its venue position to `receiver`.
    /// @dev Initiator must be the loan's borrower and must have previously authorized the adapter on
    /// Iris. Without this check, anyone could route another borrower's venue collateral to themselves
    /// through the borrower's standing adapter authorization.
    /// @dev Debt tokens covering the live venue debt must have been previously sent to the adapter; the
    /// adapter's balance caps the pull. The venue debt accrues per second, so send a small buffer and
    /// sweep the leftover at the end of the bundle.
    /// @param pod The pod of the loan.
    /// @param receiver The address that will receive the venue position's collateral.
    function irisEscape(address pod, address receiver) external onlyBundler3 {
        Loan memory loan = IRIS.getLoan(pod);
        require(loan.borrower == initiator(), ErrorsLib.UnauthorizedInitiator());

        // Iris's allowance is not reset as it is trusted.
        loan.debtToken.safeApproveWithRetry(address(IRIS), type(uint256).max);

        IRIS.escape(pod, receiver);
    }

    /// @notice Claims tokens accrued on Iris on behalf of the initiator.
    /// @dev Initiator must have previously authorized the adapter on Iris.
    /// @param token The address of the token to claim.
    /// @param amount The amount of token to claim.
    /// @param receiver The address that will receive the claimed tokens.
    function irisClaim(address token, uint256 amount, address receiver) external onlyBundler3 {
        IRIS.claim(token, amount, initiator(), receiver);
    }

    /* PERMIT2 ACTIONS */

    /// @notice Transfers with Permit2.
    /// @param token The address of the ERC20 token to transfer.
    /// @param receiver The address that will receive the tokens.
    /// @param amount The amount of token to transfer. Pass `type(uint).max` to transfer the initiator's balance.
    function permit2TransferFrom(address token, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if (amount == type(uint256).max) amount = token.balanceOf(initiator);

        require(amount != 0, ErrorsLib.ZeroAmount());

        token.permit2TransferFrom(initiator, receiver, amount);
    }

    /* TRANSFER ACTIONS */

    /// @notice Transfers ERC20 tokens from the initiator.
    /// @notice Initiator must have given sufficient allowance to the Adapter to spend their tokens.
    /// @param token The address of the ERC20 token to transfer.
    /// @param receiver The address that will receive the tokens.
    /// @param amount The amount of token to transfer. Pass `type(uint).max` to transfer the initiator's balance.
    function erc20TransferFrom(address token, address receiver, uint256 amount) external onlyBundler3 {
        require(receiver != address(0), ErrorsLib.ZeroAddress());

        address initiator = initiator();
        if (amount == type(uint256).max) amount = token.balanceOf(initiator);

        require(amount != 0, ErrorsLib.ZeroAmount());

        token.safeTransferFrom(initiator, receiver, amount);
    }

    /* WRAPPED NATIVE TOKEN ACTIONS */

    /// @notice Wraps native tokens to wNative.
    /// @dev Native tokens must have been previously sent to the adapter.
    /// @param amount The amount of native token to wrap. Pass `type(uint).max` to wrap the adapter's balance.
    /// @param receiver The account receiving the wrapped native tokens.
    function wrapNative(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = address(this).balance;

        require(amount != 0, ErrorsLib.ZeroAmount());

        WRAPPED_NATIVE.deposit{value: amount}();
        if (receiver != address(this)) address(WRAPPED_NATIVE).safeTransfer(receiver, amount);
    }

    /// @notice Unwraps wNative tokens to the native token.
    /// @dev Wrapped native tokens must have been previously sent to the adapter.
    /// @param amount The amount of wrapped native token to unwrap. Pass `type(uint).max` to unwrap the adapter's
    /// balance.
    /// @param receiver The account receiving the native tokens.
    function unwrapNative(uint256 amount, address receiver) external onlyBundler3 {
        if (amount == type(uint256).max) amount = WRAPPED_NATIVE.balanceOf(address(this));

        require(amount != 0, ErrorsLib.ZeroAmount());

        WRAPPED_NATIVE.withdraw(amount);
        if (receiver != address(this)) receiver.safeTransferETH(amount);
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Triggers `_multicall` logic during a callback.
    function morphoCallback(bytes calldata data) internal {
        require(msg.sender == address(MORPHO), ErrorsLib.UnauthorizedSender());
        // No need to approve Morpho to pull tokens because it should already be approved max.

        reenterBundler3(data);
    }
}
