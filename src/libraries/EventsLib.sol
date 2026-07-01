// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Quote} from "../interfaces/IIris.sol";

library EventsLib {
    // forgefmt: disable-start
		// Configuration events
    event SetOwner(address indexed newOwner);
    event SetFee(uint256 newFee);
    event SetFeeRecipient(address indexed newFeeRecipient);
    event SetVenueAdapter(uint256 indexed venueId, address indexed adapter);
    event EnableBlm(address indexed blm);
    event EnableBondLltv(uint256 lltv);
    event EnableData(bytes32 data);
    // Authorization events
    event SetNonce(address indexed caller, address indexed authorizer, uint256 nonce);
    event SetAuthorization(address indexed caller, address indexed authorizer, address indexed authorized, bool isAuthorized);
    // Loan events
    event Take(address indexed caller, address indexed pod, Quote quote);
    event Repay(address indexed caller, address indexed pod, uint256 repaid, uint256 badBond);
    event Liquidate(address indexed caller, address indexed pod, address indexed receiver, uint256 repaid, uint256 seized, uint256 badBond);
    // Collateral events
    event SupplyCollateral(address indexed caller, address indexed pod, uint256 amount);
    event WithdrawCollateral(address indexed caller, address indexed pod, address indexed receiver, uint256 amount);
    // Bond events
    event SupplyBond(address indexed caller, address indexed pod, uint256 amount);
    event WithdrawBond(address indexed caller, address indexed pod, address indexed receiver, uint256 amount);
    event LiquidateBond(address indexed caller, address indexed pod, address indexed receiver, uint256 seized);
    // Venue management events
    event Refinance(address indexed caller, address indexed pod, uint256 indexed newVenueId, address newVenueAdapter, bytes data);
    event Rebase(address indexed caller, address indexed pod, uint256 newCollateral, uint256 newDebt, uint256 badDebt);
    event Escape(address indexed caller, address indexed pod, address indexed receiver, uint256 venueCollateral, uint256 venueDebt);
    // Interest events
    event Accrue(address indexed pod, uint256 newCollateralIndex, uint256 newDebtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus);
    event Claim(address indexed caller, address indexed token, address indexed onBehalf, address receiver, uint256 amount);
    event Claimable(address indexed token, address indexed account, uint256 amount);
// forgefmt: disable-end
}
