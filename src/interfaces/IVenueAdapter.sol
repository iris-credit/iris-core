// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

interface IVenueAdapter {
    error ZeroAddress();
    error CollateralTokenMismatch();
    error DebtTokenMismatch();

    // forgefmt: disable-start
    function supplyCollateral(address token, uint256 amount, bytes calldata data) external;
    function withdrawCollateral(address token, uint256 amount, address receiver, bytes calldata data) external;
		/// @dev Returns early if amount is 0.
    function repay(address token, uint256 amount, bytes calldata data) external;
    function enter(address collateralToken, uint256 collateral, address debtToken, uint256 debt, address receiver, bytes calldata data) external;
    /// @dev Allows collateral, debt to pass zero amount. That case, only the `amount > 0` function is triggered.
    /// It is useful when it's not sure whether to repay debt or withdraw collateral.
    function exit(address collateralToken, uint256 collateral, address debtToken, uint256 debt, address receiver, bytes calldata data) external;
    function positionAssets(address pod, address collateralToken, address debtToken, bytes calldata data) external view returns (uint256 collateral, uint256 debt);
    /// @notice Returns the price of 1 asset of collateral token quoted in 1 asset of debt token, scaled by 1e36.
    /// @dev It corresponds to the price of 10**(collateral token decimals) assets of collateral token quoted in
    /// 10**(debt token decimals) assets of debt token with `36 + debt token decimals - collateral token decimals`
    /// decimals of precision.
    function price(address collateralToken, address debtToken, bytes calldata data) external view returns (uint256 price);
		function lltv(address collateralToken, address debtToken, bytes calldata data) external view returns (uint256 lltv);
		function indices(address collateralToken, address debtToken, bytes calldata data) external view returns (uint256 collateralIndex, uint256 debtIndex);
		// forgefmt: disable-end
}
