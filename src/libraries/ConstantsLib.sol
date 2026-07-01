// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

uint256 constant WAD = 1e18;
uint256 constant BP = 1e14;
uint256 constant ORACLE_PRICE_SCALE = 1e36;
uint256 constant SECONDS_PER_YEAR = 365 days;
uint256 constant MIN_DURATION = 1 days;
uint256 constant MAX_DURATION = 730 days; // 2 years
uint256 constant MAX_FIXED_RATE = 1e18; // 100%
uint256 constant MAX_OVERDUE_RATE = 1e18;
uint256 constant MAX_OVERDUE_PERIOD = 30 days;
uint256 constant MAX_LIF = 0.15e18;
uint256 constant TIME_TO_MAX_LIF = 15 minutes;
uint256 constant MAX_BOND_LIF = 0.05e18;
uint256 constant LIQUIDATION_CURSOR = 0.5e18;
uint256 constant MAX_FEE = 0.4e18; // 40%

bytes32 constant DOMAIN_TYPEHASH = keccak256("EIP712Domain(uint256 chainId,address verifyingContract)");
bytes32 constant AUTHORIZATION_TYPEHASH =
    keccak256("Authorization(address authorizer,address authorized,bool isAuthorized,uint256 nonce,uint256 deadline)");
bytes32 constant QUOTE_TYPEHASH = keccak256(
    "Quote(address borrower,address solver,address receiver,address blm,address collateralToken,address debtToken,uint256 collateral,uint256 debt,uint256 fixedRate,uint256 duration,uint256 overdueRate,uint256 overduePeriod,uint256 bond,uint256 bondLltv,uint256 venueBitmap,uint256 venueId,uint256 deadline,uint256 nonce,bytes data)"
);
