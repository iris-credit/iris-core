// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

struct Loan {
    address borrower;
    address solver;
    address collateralToken;
    address debtToken;
    uint128 venueBitmap;
    uint32 maturity;
    uint32 overduePeriod;
    uint16 fixedRate;
    uint16 overdueRate; // added to fixedRate after maturity
    uint16 bondLltv;
    uint16 fee;
}

struct Position {
    uint128 collateral;
    uint128 debt;
    uint128 bond;
    uint128 bondRequirement;
    uint128 collateralIndex;
    uint128 debtIndex;
    uint128 fixedLeg;
    uint128 floatingLeg;
    uint128 surplus;
    uint32 lastUpdate;
    uint8 venueId;
    bytes data;
}

struct Authorization {
    address authorizer;
    address authorized;
    bool isAuthorized;
    uint256 nonce;
    uint256 deadline;
}

struct Quote {
    address borrower;
    address solver;
    address receiver;
    address blm;
    address collateralToken;
    address debtToken;
    uint256 collateral;
    uint256 debt;
    uint256 fixedRate;
    uint256 duration;
    uint256 overdueRate;
    uint256 overduePeriod;
    uint256 bond;
    uint256 bondLltv;
    uint256 venueBitmap;
    uint256 venueId;
    uint256 deadline;
    uint256 nonce;
    bytes data;
}

interface IIris {
    // Errors
    error AdapterNotSet();
    error AlreadySet();
    error BlmNotEnabled();
    error BondLltvNotEnabled();
    error BondLltvTooHigh();
    error FeeTooHigh();
    error FixedRateTooHigh();
    error HealthyBond();
    error HealthyLoan();
    error InsufficientBond();
    error InsufficientCollateral();
    error InvalidData();
    error InvalidDuration();
    error InvalidNonce();
    error InvalidSignature();
    error LoanNotCreated();
    error LoanNotResolved();
    error NotAllowedVenue();
    error NotMultipleOfBp();
    error OverduePeriodTooHigh();
    error OverdueRateTooHigh();
    error QuoteExpired();
    error SignatureExpired();
    error Unauthorized();
    error VenueIdTooHigh();
    error ZeroAddress();
    error ZeroAmount();

    // Multicall
    function multicall(bytes[] calldata data) external;

    // Getters
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function getLoan(address pod) external view returns (Loan memory);
    function getPosition(address pod) external view returns (Position memory);

    // State variables
    function POD_IMPL() external view returns (address);
    function owner() external view returns (address);
    function fee() external view returns (uint16);
    function feeRecipient() external view returns (address);
    function claimable(address token, address account) external view returns (uint256);
    function isBlmEnabled(address blm) external view returns (bool);
    function isBondLltvEnabled(uint256 lltv) external view returns (bool);
    function isDataEnabled(bytes32 data) external view returns (bool);
    function isAuthorized(address authorizer, address authorized) external view returns (bool);
    function isNonceUsed(address authorizer, uint256 nonce) external view returns (bool);
    function venueAdapter(uint256 venueId) external view returns (address);

    // Owner functions
    function setOwner(address newOwner) external;
    function setFee(uint256 newFee) external;
    function setFeeRecipient(address newFeeRecipient) external;
    function setVenueAdapter(uint256 venueId, address adapter) external;
    function enableBlm(address blm) external;
    function enableBondLltv(uint256 lltv) external;
    function enableData(bytes32 data) external;
    function setAuthorization(address authorized, bool newIsAuthorized) external;
    function setAuthorizationWithSig(Authorization calldata authorization, bytes calldata signature) external;

    // Loan functions
    function take(Quote calldata quote, bytes calldata signature) external returns (address pod);
    function repay(address pod) external returns (uint256 repaid);
    function liquidate(address pod, address receiver) external returns (uint256 repaid, uint256 seized);

    // Collateral functions
    function supplyCollateral(address pod, uint256 amount) external;
    function withdrawCollateral(address pod, uint256 amount, address receiver) external;

    // Bond functions
    function supplyBond(address pod, uint256 amount) external;
    function withdrawBond(address pod, uint256 amount, address receiver) external;
    function liquidateBond(address pod, address receiver) external returns (uint256 seized);

    // Venue management
    function refinance(address pod, uint256 venueId, bytes calldata data) external;
    function escape(address pod, address receiver) external;
    function rebase(address pod) external;

    // Interest
		// forgefmt: disable-next-line
    function accrueLegsView(address pod) external view returns (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus);
    function claim(address token, uint256 amount, address onBehalf, address receiver) external;

    // Permit2
    function permit2(address token, address owner, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
}
