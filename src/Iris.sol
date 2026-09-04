// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {SignatureCheckerLib} from "@solady/utils/SignatureCheckerLib.sol";
import {LibClone} from "@solady/utils/LibClone.sol";

import "./libraries/ConstantsLib.sol"; // forge-lint: disable-line(unaliased-plain-import)
import {MathLib} from "./libraries/MathLib.sol";
import {EventsLib} from "./libraries/EventsLib.sol";
import {IIris, Loan, Position, Authorization, Quote} from "./interfaces/IIris.sol";
import {IBlm} from "./interfaces/IBlm.sol";
import {IPod} from "./interfaces/IPod.sol";
import {IVenueAdapter} from "./interfaces/IVenueAdapter.sol";

/// TAKE
/// @dev Borrower can open multiple loans for the same intent with different quotes.
/// @dev Iris pulls the collateral from the caller via transferFrom and the bond from the solver via
/// transferFrom with a canonical Permit2 fallback, since the solver is not in the call path to stage
/// approvals. Batched approvals, permits and token wrapping are left to periphery contracts.
///
/// REPAY
/// @dev Early repay still owes fixed interest through maturity.
/// @dev Repay also closes a loan whose debt and fixedLeg are already zero but bondRequirement is
/// non-zero (for example after a venue-side wipe), letting the solver withdraw the remaining bond.
/// @dev A borrower has no incentive to repay once the bad bond they must cover exceeds their remaining
/// collateral, since they would pay in more than they get back.
/// @dev Bad-debt loans (venue debt exceeds the debt-token value of the remaining venue collateral) can
/// still be closed permissionlessly: repay anytime, or liquidate once past maturity + overduePeriod.
/// The caller covers the venue debt to close the position.
/// @dev A borrower repay can be front-run by liquidation once the loan is past maturity + overduePeriod.
///
/// COLLATERAL
/// @dev Iris lets borrowers withdraw collateral up to the underlying venue's LLTV edge. It only checks that
/// the remaining collateral covers the borrower's debt, fixed interest through maturity + overduePeriod, and
/// any bad bond. Managing venue health is the borrower's responsibility.
/// @dev Once the loan is liquidatable, withdrawCollateral reverts, so a borrower cannot withdraw against a
/// pending liquidation.
/// @dev The reserve is the projected liquidation exposure: fixed interest through the liquidation window, or
/// the floating leg beyond the bond if that is larger. Fixed interest accruing shrinks the bad bond one-for-one,
/// so the two are never summed.
/// @dev The withdrawCollateral check counts interest only through maturity + overduePeriod, but interest
/// keeps accruing until the loan is closed. Interest accruing between liquidation becoming possible and
/// being executed is therefore unchecked. It is expected to be small and covered by the venue LLTV buffer.
/// @dev To withdraw the full collateral, repay the loan then escape, since escape exits the live venue
/// balance. A full-amount withdrawCollateral can revert when underlying-venue rounding leaves the stored
/// amount above the real balance.
///
/// LIQUIDATION
/// @dev Once the loan passes maturity + overduePeriod, it becomes liquidatable.
/// @dev The overdue-liquidation Liquidation Incentive Factor (LIF) grows linearly from 0 (no bonus) at
/// maturity + overduePeriod to MAX_LIF over ~15 minutes (TIME_TO_MAX_LIF).
/// @dev When the remaining venue collateral is less than the full seize amount (repaid plus bonus), seized
/// is capped at the available collateral and the liquidator receives a reduced or zero bonus. When the cap binds
/// and the collateral has accrued ~no yield, supply-share rounding can leave stored collateral a wei above the
/// real venue balance and revert the seize transfer; repay then closes the loan.
/// @dev The liquidation incentive is capped, while venue debt may keep accruing after overduePeriod.
/// Deeply overdue loans can become uneconomic to liquidate.
///
/// BOND
/// @dev Bad bond is when the negative net (floating minus fixed) outgrows the whole bond, so the bond cannot
/// cover the solver's settlement at close. It requires realized divergence beyond the BLM's bond sizing
/// (uncommon with conservative params).
/// @dev In case of bad bond, borrower bears the bad bond.
/// @dev Since the solver controls bond withdrawals, withdrawBond can leave the bond at the bondLltv edge, letting
/// the solver self-liquidate to exit the fixed position without penalty. It's accepted as the BLM sizes
/// bondRequirement with enough buffer that normal accrual does not immediately make the bond liquidatable.
///
/// BOND LIQUIDATION
/// @dev Small positions may not be liquidated due to the liquidation incentive <= gas cost.
/// @dev The bond liquidation incentive factor is min(MAX_BOND_LIF, 1 / (1 - cursor * (1 - bondLltv)) - 1).
/// @dev After bond liquidation, the borrower's loan position sits on the underlying venue getting variable interest
/// rate.
/// @dev On bond liquidation the solver forfeits the surplus. It is not settled to the solver, and the
/// underlying collateral with its yield stays in the venue for the borrower, compensating the borrower for
/// being forced to variable rate. It stays tracked as the borrower's collateral, so the borrower can withdraw
/// it with withdrawCollateral or close the venue position with escape.
/// @dev On bond liquidation the bond covers two things: the settlement the solver owes (floatingLeg minus
/// fixedLeg), which repays the venue, and the liquidator bonus (seized). Both come out of the bond, so the
/// solver pays the incentive. The borrower bears bad bond only when settlement plus bonus exceeds the bond.
/// @dev The loan position between solver and borrower pays fixed interest until the moment of the bond liquidation.
/// @dev Even in bad bond, bond liquidation incentive is still paid from the slashed bond. This may
/// increase the amount of bad bond. Otherwise the loan may stay open until maturity/overdue liquidation
/// while negative net keeps increasing.
/// @dev To remove bad bond, either solver supplies additional bond or borrower absorbs the bad bond
/// by repaying the debt including bad bond.
/// @dev Bond liquidation repays the venue with the settlement portion of the slashed bond, capped at the
/// current venue debt. If that portion is larger than the venue debt (for example the venue debt was already
/// mostly repaid), the leftover stays in Iris with no owner and counts as a donation.
///
/// REFINANCE
/// @dev It's only possible to refinance to whitelisted markets (enabled data).
/// @dev The borrower does not constrain which enabled market a refinance selects, so any enabled data
/// matching the loan's tokens can be bound to any loan on that venue. enableData must therefore only admit
/// markets whose oracle and lltv are acceptable for every loan that can reach them.
/// @dev The CEI pattern is not enforced given the token (non-reentrant), venue and its adapter is trusted.
/// @dev Refinance may introduce venue rounding dust: collateral can round down and debt can round up.
/// Repeated invocations can slightly worsen the position, but this is economically infeasible due to gas cost.
/// @dev One-sided collateral or debt changes directly on the venue before refinance
/// are not reconciled and remain governed by the external venue change assumptions.
/// @dev Refinance does not health-check the new market, so a solver can move the loan to a market whose
/// lltv or price leaves it immediately liquidatable on the underlying venue.
///
/// REBASE
/// @dev Rebase acts only when both venue collateral and venue debt have fallen below their expected values
/// (collateral + surplus, debt + floatingLeg), that is, a venue liquidation. A direct debt repay on a pod is out
/// of scope and may be treated as an unrecoverable donation.
/// @dev Live collateral above the tracked collateral and surplus is a direct venue supply. Rebase tracks it as
/// the borrower's collateral, so a withdrawal backed by it cannot pull tracked principal out of the surplus
/// base or the liquidation seize cap.
/// @dev Order is accrue, then rebase, then settle. Settlement runs on post-rebase (real venue) amounts, so the
/// solver's claimable for net and surplus can never exceed what the pod can actually withdraw.
/// @dev Legs accrue on the last synced collateral and debt, so after a venue liquidation they keep accruing
/// on stale bases until rebase runs. The longer the delay, the further settlement drifts. Any resulting
/// shift between borrower, solver, and bond is accepted.
/// @dev A direct collateral supply to a pod's venue position (by anyone) raises venueCollateral, which can zero
/// the liquidated term and make rebase skip a venue liquidation that occurred since the last sync.
/// @dev After a venue liquidation, Iris recognizes venue debt reduction against the debt-token
/// value of collateral lost since the last sync. A standard venue liquidation removes collateral
/// worth the repaid debt plus liquidation bonus while reducing venue debt only by the repaid debt,
/// so the liquidation-bonus buffer is the headroom for borrower direct venue repayment to be
/// recognized by rebase. Extra one-sided venue repayment is outside rebase.
/// @dev Rebase prices the lost collateral at the adapter's current oracle price, not at the price used
/// by the venue liquidation. Large price moves between the venue liquidation and the rebase call can
/// change how much debt reduction is recognized and whether bad debt is detected.
/// @dev Debt that rebase does not recognize, from either cause above, leaves the stored debt above the real
/// venue debt. At close the closer repays the stored amount while only the venue debt is forwarded to the
/// venue, so the difference stays in Iris with no owner and counts as a donation.
/// @dev Surplus can be greater than the venue collateral in an extreme case where most of the collateral got
/// liquidated in the underlying venue. In such a case, the surplus shrinks to venue collateral.
/// @dev If rebase detects bad debt, bondRequirement is set to zero. In that state,
/// the solver can withdraw bond even when net is negative but does not receive
/// surplus or fixed interest because the loan is not expected to be repaid.
/// @dev If a bad-debt loan is nonetheless closed via repay or liquidate, legs settle normally and the
/// solver receives net and surplus, since the closer repays the debt and fixed interest in full.
///
/// POD
/// @dev No receive / fallback in pod. Rewards that are coming to pod will be handled offchain
/// and be directly accumulated to user.
/// @dev There can be dust (a few wei) tokens stranded in a pod due to the roundings.
///
/// VENUE ADAPTERS
/// @dev The adapter should not revert price.
/// @dev The adapter should not return 0 on price.
/// @dev The adapter should return a price with the correct scaling.
/// @dev Adapters that do not require data, such as Aave, require enabling keccak256("") before use.
/// @dev venueAdapter can be updated even for active loans.
/// @dev Iris stores venue index snapshots as uint128. adapters must not return indexes above that bound.
/// With a 1e27 base index, the cap is ~3.4e11x accumulated borrow-index growth.
/// @dev Invariant `index >= lastIndex`: borrow interest only raises the venue debt index. A bad-debt
/// liquidation lowers it by at most a `toAssetsUp` rounding (<=1 unit) that interest covers within a
/// block. The IRM's approximate average rate can also dip the index on a long-unwritten, near-idle
/// market. Whitelisting only blue-chip markets excludes that state. Hence the unchecked index deltas
/// never underflow.
/// @dev An idle Aave reserve with a nonzero base rate keeps growing its reported index while the stored index
/// does not move until the first borrow, so a take on it snapshots a higher index than the one the pod's debt
/// is minted at. Do not use Aave debt assets that can reach that state.
///
/// TOKEN REQUIREMENTS
/// @dev List of assumptions on the token that guarantees that the token behaves as expected:
/// - It should be ERC-20 compliant, except that it can omit return values on transfer and transferFrom.
/// - The token balance should only decrease on transfer and transferFrom. In particular, tokens with
/// burn functions are not supported.
/// - It should not re-enter the Iris on transfer or transferFrom.
/// - The balance of the sender (resp. receiver) should decrease (resp. increase) by exactly the given amount on
/// transfer and transferFrom. In particular, tokens with fees on transfer are not supported.
///
/// FEES
/// @dev Fee unit is WAD.
/// @dev This invariant holds for the fee: fee != 0 => feeRecipient != address(0).
/// @dev This invariant will be ensured by the team.
///
/// LIVENESS
/// @dev If an underlying venue oracle reverts on price or returns 0 price, functions requiring collateral valuation
/// may revert, including liquidate, withdrawCollateral, and rebase.
/// @dev If an underlying venue oracle returns a price such that the user's collateral quoted in debt token is
/// greater than type(uint128).max, then liquidate could revert.
/// @dev If a token sent/pulled by Iris reverts or returns false on transfer/transferFrom, related function will
/// revert when it tries to send/pull that token.
/// @dev If the underlying venue pauses or blocks repay/withdraw/exit, Iris has no bypass and related
/// functions may revert until the venue is live again.
///
/// MISC
/// @dev Iris trusts the venue adapter's price and lltv for collateral valuation. No extra oracle
/// staleness check or fair-value bound is applied.
/// @dev NatSpec comments are included only when they bring clarity.
/// @dev The amount of token supplied and borrowed should not be too high (max ~1e32), otherwise the numbers
/// might not fit within 128 bits.
/// @dev If MAX_FIXED_RATE or MAX_OVERDUE_RATE changes, keep their sum within type(uint16).max * BP.
/// @dev fixedLeg, floatingLeg and surplus are not up to date. Use accrueLegsView to get the up-to-date values.
/// @dev Expect owner to be a timelock contract.

contract Iris is IIris {
    using SafeTransferLib for address;
    using MathLib for uint128;
    using MathLib for uint256;

    /* IMMUTABLES */

    address public immutable POD_IMPL;

    /* STORAGE */

    mapping(address pod => Loan) internal _loan;
    mapping(address pod => Position) internal _position;
    mapping(uint256 venueId => address adapter) public venueAdapter;
    mapping(address token => mapping(address account => uint256)) public claimable;
    mapping(address blm => bool) public isBlmEnabled;
    mapping(uint256 lltv => bool) public isBondLltvEnabled;
    mapping(bytes32 data => bool) public isDataEnabled;
    mapping(address authorizer => mapping(address authorized => bool)) public isAuthorized;
    mapping(address solver => mapping(uint256 nonce => bool)) public isQuoteNonceUsed;
    mapping(address authorizer => uint256) public nonce;
    address public owner;
    address public feeRecipient;
    uint16 public fee;

    /* GETTERS */

    /// forge-lint: disable-next-item(mixed-case-function)
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, block.chainid, address(this)));
    }

    function getLoan(address pod) external view returns (Loan memory) {
        return _loan[pod];
    }

    function getPosition(address pod) external view returns (Position memory) {
        return _position[pod];
    }

    /* CONSTRUCTOR */

    constructor(address newOwner, address podImpl) {
        require(newOwner != address(0), ZeroAddress());
        require(podImpl != address(0), ZeroAddress());
        owner = newOwner;
        POD_IMPL = podImpl;
        emit EventsLib.SetOwner(newOwner);
    }

    /* MODIFIERS */

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, Unauthorized());
    }

    /* OWNER FUNCTIONS */

    function setOwner(address newOwner) external onlyOwner {
        require(newOwner != owner, AlreadySet());
        owner = newOwner;
        emit EventsLib.SetOwner(newOwner);
    }

    function setFee(uint256 newFee) external onlyOwner {
        require(newFee <= MAX_FEE, FeeTooHigh());
        require(newFee % BP == 0, NotMultipleOfBp());
        // forge-lint: disable-next-item(unsafe-typecast) as newFee <= MAX_FEE <= uint16.max * BP
        fee = uint16(newFee / BP);
        emit EventsLib.SetFee(newFee);
    }

    function setFeeRecipient(address newFeeRecipient) external onlyOwner {
        require(newFeeRecipient != address(0), ZeroAddress());
        feeRecipient = newFeeRecipient;
        emit EventsLib.SetFeeRecipient(newFeeRecipient);
    }

    function setVenueAdapter(uint256 venueId, address adapter) external onlyOwner {
        require(adapter != address(0), ZeroAddress());
        require(venueId < 128, VenueIdTooHigh());
        venueAdapter[venueId] = adapter;
        emit EventsLib.SetVenueAdapter(venueId, adapter);
    }

    function enableBlm(address blm) external onlyOwner {
        require(!isBlmEnabled[blm], AlreadySet());
        isBlmEnabled[blm] = true;
        emit EventsLib.EnableBlm(blm);
    }

    function enableBondLltv(uint256 lltv) external onlyOwner {
        require(!isBondLltvEnabled[lltv], AlreadySet());
        require(lltv < WAD, BondLltvTooHigh());
        require(lltv % BP == 0, NotMultipleOfBp());
        isBondLltvEnabled[lltv] = true;
        emit EventsLib.EnableBondLltv(lltv);
    }

    function enableData(bytes32 data) external onlyOwner {
        require(!isDataEnabled[data], AlreadySet());
        isDataEnabled[data] = true;
        emit EventsLib.EnableData(data);
    }

    /* AUTHORIZATION FUNCTIONS */

    function setAuthorization(address authorized, bool newIsAuthorized) external {
        require(newIsAuthorized != isAuthorized[msg.sender][authorized], AlreadySet());
        isAuthorized[msg.sender][authorized] = newIsAuthorized;
        emit EventsLib.SetAuthorization(msg.sender, msg.sender, authorized, newIsAuthorized);
    }

    function setAuthorizationWithSig(Authorization calldata authorization, bytes calldata signature) external {
        require(block.timestamp <= authorization.deadline, SignatureExpired());
        require(authorization.nonce == nonce[authorization.authorizer]++, InvalidNonce());

        bytes32 hashStruct = keccak256(abi.encode(AUTHORIZATION_TYPEHASH, authorization));
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR(), hashStruct));

        require(
            SignatureCheckerLib.isValidSignatureNowCalldata(authorization.authorizer, digest, signature),
            InvalidSignature()
        );

        isAuthorized[authorization.authorizer][authorization.authorized] = authorization.isAuthorized;

        emit EventsLib.SetNonce(msg.sender, authorization.authorizer, authorization.nonce);
        emit EventsLib.SetAuthorization(
            msg.sender, authorization.authorizer, authorization.authorized, authorization.isAuthorized
        );
    }

    /// @dev Returns whether the sender is authorized to manage onBehalf's positions.
    function _isSenderAuthorized(address onBehalf) internal view returns (bool) {
        return msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender];
    }

    /* LOAN FUNCTIONS */

    function take(Quote calldata quote, bytes calldata signature) external returns (address) {
        address pod = LibClone.clone(POD_IMPL, abi.encodePacked(address(this)));
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(_isSenderAuthorized(quote.borrower), Unauthorized());
        require(block.timestamp <= quote.deadline, QuoteExpired());
        require(!isQuoteNonceUsed[quote.solver][quote.nonce], InvalidNonce());

        bytes32 hashStruct = keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.borrower,
                quote.solver,
                quote.receiver,
                quote.blm,
                quote.collateralToken,
                quote.debtToken,
                quote.collateral,
                quote.debt,
                quote.fixedRate,
                quote.duration,
                quote.overdueRate,
                quote.overduePeriod,
                quote.bond,
                quote.bondLltv,
                quote.venueBitmap,
                quote.venueId,
                quote.deadline,
                quote.nonce,
                keccak256(quote.data)
            )
        );
        bytes32 digest = keccak256(bytes.concat("\x19\x01", DOMAIN_SEPARATOR(), hashStruct));
        address adapter = venueAdapter[quote.venueId];

        require(SignatureCheckerLib.isValidSignatureNowCalldata(quote.solver, digest, signature), InvalidSignature());
        require(quote.borrower != address(0), ZeroAddress());
        require(quote.receiver != address(0), ZeroAddress());
        require(isBlmEnabled[quote.blm], BlmNotEnabled());
        require(quote.collateralToken != address(0), ZeroAddress());
        require(quote.debtToken != address(0), ZeroAddress());
        require(quote.collateral != 0, ZeroAmount());
        require(quote.debt != 0, ZeroAmount());
        require(quote.fixedRate <= MAX_FIXED_RATE, FixedRateTooHigh());
        require(quote.fixedRate % BP == 0, NotMultipleOfBp());
        require(quote.duration >= MIN_DURATION && quote.duration <= MAX_DURATION, InvalidDuration());
        require(quote.overdueRate <= MAX_OVERDUE_RATE, OverdueRateTooHigh());
        require(quote.overdueRate % BP == 0, NotMultipleOfBp());
        require(quote.overduePeriod <= MAX_OVERDUE_PERIOD, OverduePeriodTooHigh());
        require(quote.bond != 0, ZeroAmount());
        require(isBondLltvEnabled[quote.bondLltv], BondLltvNotEnabled());
        require((quote.venueBitmap >> quote.venueId) & 1 == 1, NotAllowedVenue());
        require(adapter != address(0), AdapterNotSet());
        require(isDataEnabled[keccak256(quote.data)], InvalidData());

        isQuoteNonceUsed[quote.solver][quote.nonce] = true;

        loan.borrower = quote.borrower;
        loan.solver = quote.solver;
        loan.collateralToken = quote.collateralToken;
        loan.debtToken = quote.debtToken;
        loan.venueBitmap = quote.venueBitmap.toUint128();
        // forge-lint: disable-next-item(unsafe-typecast) as duration <= MAX_DURATION <= uint32.max
        loan.maturity = uint32(block.timestamp + quote.duration);
        // forge-lint: disable-next-item(unsafe-typecast) as overduePeriod <= MAX_OVERDUE_PERIOD <= uint32.max
        loan.overduePeriod = uint32(quote.overduePeriod);
        // forge-lint: disable-next-item(unsafe-typecast) as fixedRate <= MAX_FIXED_RATE <= uint16.max * BP
        loan.fixedRate = uint16(quote.fixedRate / BP);
        // forge-lint: disable-next-item(unsafe-typecast) as overdueRate <= MAX_OVERDUE_RATE <= uint16.max * BP
        loan.overdueRate = uint16(quote.overdueRate / BP);
        // forge-lint: disable-next-item(unsafe-typecast) as bondLltv <= WAD <= uint16.max * BP
        loan.bondLltv = uint16(quote.bondLltv / BP);
        loan.fee = fee;

        (uint256 collateralIndex, uint256 debtIndex) =
            IVenueAdapter(adapter).indices(quote.collateralToken, quote.debtToken, quote.data);

        pos.collateral = quote.collateral.toUint128();
        pos.debt = quote.debt.toUint128();
        pos.collateralIndex = collateralIndex.toUint128();
        pos.debtIndex = debtIndex.toUint128();
        pos.bond = quote.bond.toUint128();
        pos.bondRequirement = IBlm(quote.blm).bondRequirement(quote).toUint128();
        // forge-lint: disable-next-item(unsafe-typecast) as timestamp <= uint32.max
        pos.lastUpdate = uint32(block.timestamp);
        // forge-lint: disable-next-item(unsafe-typecast) as venueId <= uint8.max
        pos.venueId = uint8(quote.venueId);
        pos.data = quote.data;

        require(pos.bondRequirement != 0 && quote.bond >= pos.bondRequirement, InsufficientBond());

        quote.debtToken.safeTransferFrom2(quote.solver, address(this), quote.bond);
        quote.collateralToken.safeTransferFrom(msg.sender, pod, quote.collateral);
        IPod(pod)
            .delegateCall(
                adapter,
                abi.encodeWithSelector(
                    IVenueAdapter.enter.selector,
                    quote.collateralToken,
                    quote.collateral,
                    quote.debtToken,
                    quote.debt,
                    quote.receiver,
                    quote.data
                )
            );

        emit EventsLib.SetQuoteNonce(msg.sender, quote.solver, quote.nonce);
        emit EventsLib.Take(msg.sender, pod, quote, collateralIndex, debtIndex);

        return pod;
    }

    function repay(address pod) external returns (uint256) {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(pos.lastUpdate != 0, LoanNotCreated());
        require(pos.debt + pos.fixedLeg != 0 || pos.bondRequirement != 0, ZeroAmount());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);
        _settleLegs(loan, pos);

        address adapter = venueAdapter[pos.venueId];
        uint256 negativeNet = pos.floatingLeg.zeroFloorSub(pos.fixedLeg);
        uint256 bondSlashed = MathLib.min(negativeNet, pos.bond);
        uint256 badBond = negativeNet.zeroFloorSub(pos.bond);
        uint256 repaid = pos.debt + pos.fixedLeg + badBond;
        (, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        uint256 surplus = pos.surplus;

        pos.debt = 0;
        pos.bond -= bondSlashed.toUint128();
        pos.bondRequirement = 0;
        pos.fixedLeg = 0;
        pos.floatingLeg = 0;
        if (surplus != 0) pos.surplus = 0;

        loan.debtToken.safeTransferFrom(msg.sender, address(this), repaid);
        loan.debtToken.safeTransfer(pod, venueDebt);
        IPod(pod)
            .delegateCall(
                adapter,
                abi.encodeWithSelector(
                    IVenueAdapter.exit.selector,
                    loan.collateralToken,
                    surplus,
                    loan.debtToken,
                    venueDebt,
                    address(this),
                    pos.data
                )
            );

        emit EventsLib.Repay(msg.sender, pod, repaid, badBond);

        return repaid;
    }

    function liquidate(address pod, address receiver) external returns (uint256, uint256) {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(receiver != address(0), ZeroAddress());
        require(pos.lastUpdate != 0, LoanNotCreated());
        require(pos.debt + pos.fixedLeg != 0, ZeroAmount());
        require(block.timestamp > loan.maturity + loan.overduePeriod, HealthyLoan());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);
        _settleLegs(loan, pos);

        address adapter = venueAdapter[pos.venueId];
        uint256 negativeNet = pos.floatingLeg.zeroFloorSub(pos.fixedLeg);
        uint256 bondSlashed = MathLib.min(negativeNet, pos.bond);
        uint256 badBond = negativeNet.zeroFloorSub(pos.bond);
        uint256 repaid = pos.debt + pos.fixedLeg + badBond;
        (uint256 venueCollateral, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        uint256 surplus = pos.surplus;
        uint256 lif = MathLib.min(
            MAX_LIF, MAX_LIF.mulDivDown(block.timestamp - (loan.maturity + loan.overduePeriod), TIME_TO_MAX_LIF)
        );
        uint256 collateralPrice = IVenueAdapter(adapter).price(loan.collateralToken, loan.debtToken, pos.data);
        uint256 seized = MathLib.min(
            pos.collateral, repaid.mulDivDown(WAD + lif, WAD).mulDivDown(ORACLE_PRICE_SCALE, collateralPrice)
        );

        pos.collateral -= seized.toUint128();
        pos.debt = 0;
        pos.bond -= bondSlashed.toUint128();
        pos.bondRequirement = 0;
        pos.fixedLeg = 0;
        pos.floatingLeg = 0;
        pos.surplus = 0;

        loan.debtToken.safeTransferFrom(msg.sender, address(this), repaid);
        loan.debtToken.safeTransfer(pod, venueDebt);
        // seized + surplus can exceed the venue balance by <=1 wei.
        IPod(pod)
            .delegateCall(
                adapter,
                abi.encodeWithSelector(
                    IVenueAdapter.exit.selector,
                    loan.collateralToken,
                    MathLib.min(seized + surplus, venueCollateral),
                    loan.debtToken,
                    venueDebt,
                    address(this),
                    pos.data
                )
            );
        loan.collateralToken.safeTransfer(receiver, seized);

        emit EventsLib.Liquidate(msg.sender, pod, receiver, repaid, seized, badBond);

        return (repaid, seized);
    }

    /* COLLATERAL MANAGEMENT */

    function supplyCollateral(address pod, uint256 amount) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(amount != 0, ZeroAmount());
        require(loan.collateralToken != address(0), ZeroAddress());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);

        pos.collateral += amount.toUint128();

        loan.collateralToken.safeTransferFrom(msg.sender, pod, amount);
        IPod(pod)
            .delegateCall(
                venueAdapter[pos.venueId],
                abi.encodeWithSelector(IVenueAdapter.supplyCollateral.selector, loan.collateralToken, amount, pos.data)
            );

        emit EventsLib.SupplyCollateral(msg.sender, pod, amount);
    }

    function withdrawCollateral(address pod, uint256 amount, address receiver) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];
        address adapter = venueAdapter[pos.venueId];

        require(amount != 0, ZeroAmount());
        require(receiver != address(0), ZeroAddress());
        require(loan.collateralToken != address(0), ZeroAddress());
        require(_isSenderAuthorized(loan.borrower), Unauthorized());
        require(block.timestamp <= loan.maturity + loan.overduePeriod, LiquidatableLoan());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);

        pos.collateral -= amount.toUint128();

        uint256 lltv = IVenueAdapter(adapter).lltv(loan.collateralToken, loan.debtToken, pos.data);
        uint256 collateralPrice = IVenueAdapter(adapter).price(loan.collateralToken, loan.debtToken, pos.data);
        uint256 maxDebt = pos.collateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE).mulDivDown(lltv, WAD);
        uint256 timeToLiquidation = uint256(loan.maturity + loan.overduePeriod).zeroFloorSub(block.timestamp);
        uint256 residual = pos.debt
            .mulDivDown(
                timeToLiquidation * loan.fixedRate * BP + MathLib.min(timeToLiquidation, loan.overduePeriod)
                    * loan.overdueRate * BP,
                SECONDS_PER_YEAR * WAD
            );
        uint256 exposure = MathLib.max(pos.fixedLeg + residual, pos.floatingLeg.zeroFloorSub(pos.bond));

        require(pos.debt + exposure <= maxDebt, InsufficientCollateral());

        IPod(pod)
            .delegateCall(
                adapter,
                abi.encodeWithSelector(
                    IVenueAdapter.withdrawCollateral.selector, loan.collateralToken, amount, receiver, pos.data
                )
            );

        emit EventsLib.WithdrawCollateral(msg.sender, pod, receiver, amount);
    }

    /* BOND MANAGEMENT */

    function supplyBond(address pod, uint256 amount) external {
        require(amount != 0, ZeroAmount());
        require(_loan[pod].debtToken != address(0), ZeroAddress());

        _position[pod].bond += amount.toUint128();

        _loan[pod].debtToken.safeTransferFrom(msg.sender, address(this), amount);

        emit EventsLib.SupplyBond(msg.sender, pod, amount);
    }

    function withdrawBond(address pod, uint256 amount, address receiver) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(amount != 0, ZeroAmount());
        require(receiver != address(0), ZeroAddress());
        require(loan.debtToken != address(0), ZeroAddress());
        require(_isSenderAuthorized(loan.solver), Unauthorized());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);

        pos.bond -= amount.toUint128();

        require(_isHealthyBond(loan, pos), InsufficientBond());

        loan.debtToken.safeTransfer(receiver, amount);

        emit EventsLib.WithdrawBond(msg.sender, pod, receiver, amount);
    }

    function liquidateBond(address pod, address receiver) external returns (uint256) {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];
        address adapter = venueAdapter[pos.venueId];

        require(receiver != address(0), ZeroAddress());
        require(pos.lastUpdate != 0, LoanNotCreated());
        require(pos.bondRequirement != 0, ZeroAmount());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);

        require(!_isHealthyBond(loan, pos), HealthyBond());

        (, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        // lif = min(MAX_BOND_LIF, 1 / (1 - cursor * (1 - bondLltv)) - 1)
        uint256 lif = MathLib.min(
            MAX_BOND_LIF, WAD.mulDivDown(WAD, WAD - LIQUIDATION_CURSOR.mulDivDown(WAD - loan.bondLltv * BP, WAD)) - WAD
        );
        uint256 seized = pos.bond.mulDivDown(lif, WAD);
        uint256 negativeNet = pos.floatingLeg - pos.fixedLeg;
        uint256 bondSlashed = MathLib.min(negativeNet + seized, pos.bond);
        uint256 repaid = MathLib.min(bondSlashed - seized, venueDebt);

        pos.debt = 0;
        pos.bond -= bondSlashed.toUint128();
        pos.bondRequirement = 0;
        pos.fixedLeg = 0;
        pos.floatingLeg = 0;
        pos.surplus = 0;

        loan.debtToken.safeTransfer(pod, repaid);
        IPod(pod)
            .delegateCall(
                adapter, abi.encodeWithSelector(IVenueAdapter.repay.selector, loan.debtToken, repaid, pos.data)
            );
        loan.debtToken.safeTransfer(receiver, seized);

        emit EventsLib.LiquidateBond(msg.sender, pod, receiver, seized);

        return seized;
    }

    /// @dev closing loan will set bondRequirement to 0
    function _isHealthyBond(Loan storage loan, Position storage pos) internal view returns (bool) {
        if (pos.bondRequirement == 0) return true;
        if (pos.bond < pos.bondRequirement) return false;
        if (pos.floatingLeg <= pos.fixedLeg) return true;

        uint256 negativeNet = pos.floatingLeg - pos.fixedLeg;
        uint256 drawdown = negativeNet.mulDivUp(WAD, pos.bond);

        return drawdown <= loan.bondLltv * BP;
    }

    /* VENUE MANAGEMENT */

    function refinance(address pod, address receiver, uint256 newVenueId, bytes calldata data) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];
        address adapter = venueAdapter[pos.venueId];
        address newAdapter = venueAdapter[newVenueId];

        require(receiver != address(0), ZeroAddress());
        require(pos.lastUpdate != 0, LoanNotCreated());
        require(pos.bondRequirement != 0, ZeroAmount());
        require(block.timestamp <= loan.maturity + loan.overduePeriod, LiquidatableLoan());
        require(_isSenderAuthorized(loan.solver), Unauthorized());
        require(newAdapter != address(0), AdapterNotSet());
        require((loan.venueBitmap >> newVenueId) & 1 == 1, NotAllowedVenue());
        require(isDataEnabled[keccak256(data)], InvalidData());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);

        (uint256 venueCollateral, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);

        loan.debtToken.safeTransferFrom(msg.sender, pod, venueDebt);
        IPod(pod)
            .delegateCall(
                adapter,
                abi.encodeWithSelector(
                    IVenueAdapter.exit.selector,
                    loan.collateralToken,
                    venueCollateral,
                    loan.debtToken,
                    venueDebt,
                    pod,
                    pos.data
                )
            );
        IPod(pod)
            .delegateCall(
                newAdapter,
                abi.encodeWithSelector(
                    IVenueAdapter.enter.selector,
                    loan.collateralToken,
                    venueCollateral,
                    loan.debtToken,
                    venueDebt,
                    receiver,
                    data
                )
            );

        (uint256 newCollateralIndex, uint256 newDebtIndex) =
            IVenueAdapter(newAdapter).indices(loan.collateralToken, loan.debtToken, data);

        pos.collateralIndex = newCollateralIndex.toUint128();
        pos.debtIndex = newDebtIndex.toUint128();
        // forge-lint: disable-next-item(unsafe-typecast) as newVenueId <= uint8.max
        pos.venueId = uint8(newVenueId);
        pos.data = data;

        emit EventsLib.Refinance(
            msg.sender, pod, receiver, newVenueId, newAdapter, newCollateralIndex, newDebtIndex, data
        );
    }

    function escape(address pod, address receiver) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(receiver != address(0), ZeroAddress());
        require(pos.lastUpdate != 0, LoanNotCreated());
        require(_isSenderAuthorized(loan.borrower), Unauthorized());
        require(pos.bondRequirement == 0, LoanNotResolved());

        (uint256 venueCollateral, uint256 venueDebt) =
            IVenueAdapter(venueAdapter[pos.venueId]).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);

        pos.collateral = 0;
        pos.debt = 0;
        pos.fixedLeg = 0;
        pos.floatingLeg = 0;
        pos.surplus = 0;

        loan.debtToken.safeTransferFrom(msg.sender, pod, venueDebt);
        IPod(pod)
            .delegateCall(
                venueAdapter[pos.venueId],
                abi.encodeWithSelector(
                    IVenueAdapter.exit.selector,
                    loan.collateralToken,
                    venueCollateral,
                    loan.debtToken,
                    venueDebt,
                    receiver,
                    pos.data
                )
            );

        emit EventsLib.Escape(msg.sender, pod, receiver, venueCollateral, venueDebt);
    }

    function rebase(address pod) external {
        Loan storage loan = _loan[pod];
        Position storage pos = _position[pod];

        require(pos.lastUpdate != 0, LoanNotCreated());
        require(pos.bondRequirement != 0, ZeroAmount());

        _accrueLegs(loan, pos, pod);
        _rebase(loan, pos, pod);
    }

    function _rebase(Loan storage loan, Position storage pos, address pod) internal {
        address adapter = venueAdapter[pos.venueId];
        (uint256 venueCollateral, uint256 venueDebt) =
            IVenueAdapter(adapter).positionAssets(pod, loan.collateralToken, loan.debtToken, pos.data);
        uint256 liquidated = (pos.collateral + pos.surplus).zeroFloorSub(venueCollateral);
        uint256 repaid = (pos.debt + pos.floatingLeg).zeroFloorSub(venueDebt);

        if (liquidated == 0 || repaid == 0) {
            if (venueCollateral > pos.collateral + pos.surplus) {
                pos.collateral = (venueCollateral - pos.surplus).toUint128();
                emit EventsLib.Rebase(msg.sender, pod, pos.collateral, pos.debt, venueCollateral, venueDebt, 0);
            }
            return;
        }

        uint256 collateralPrice = IVenueAdapter(adapter).price(loan.collateralToken, loan.debtToken, pos.data);
        uint256 maxRepaid = liquidated.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE);
        uint256 badDebt = venueDebt.zeroFloorSub(venueCollateral.mulDivDown(collateralPrice, ORACLE_PRICE_SCALE));

        if (venueCollateral <= pos.surplus) pos.surplus = venueCollateral.toUint128();
        if (venueDebt <= pos.floatingLeg) pos.floatingLeg = venueDebt.toUint128();
        if (badDebt != 0 || (venueDebt == 0 && venueCollateral == 0)) pos.bondRequirement = 0;
        pos.collateral = pos.collateral.zeroFloorSub(liquidated).toUint128();
        pos.debt = pos.debt.zeroFloorSub(MathLib.min(repaid, maxRepaid)).toUint128();

        emit EventsLib.Rebase(msg.sender, pod, pos.collateral, pos.debt, venueCollateral, venueDebt, badDebt);
    }

    /* INTEREST FUNCTIONS */

    function accrueLegsView(address pod) external view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 collateralIndex, uint256 debtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            _accrueLegsView(_loan[pod], _position[pod]);
        return (
            collateralIndex,
            debtIndex,
            fixedLeg + _position[pod].fixedLeg,
            floatingLeg + _position[pod].floatingLeg,
            surplus + _position[pod].surplus
        );
    }

    function _accrueLegsView(Loan storage loan, Position storage pos)
        internal
        view
        returns (uint256, uint256, uint256, uint256, uint256)
    {
        uint256 elapsed = block.timestamp - pos.lastUpdate;
        if (pos.lastUpdate == 0 || elapsed == 0) return (pos.collateralIndex, pos.debtIndex, 0, 0, 0);

        (uint256 newCollateralIndex, uint256 newDebtIndex) =
            IVenueAdapter(venueAdapter[pos.venueId]).indices(loan.collateralToken, loan.debtToken, pos.data);
        uint256 fixedLeg = pos.debt.mulDivDown(elapsed * loan.fixedRate * BP, SECONDS_PER_YEAR * WAD);
        uint256 floatingLeg = (pos.debt + pos.floatingLeg).mulDivDown(newDebtIndex - pos.debtIndex, pos.debtIndex);
        uint256 surplus = pos.bondRequirement != 0
            ? (pos.collateral + pos.surplus).mulDivDown(newCollateralIndex - pos.collateralIndex, pos.collateralIndex)
            : 0;

        if (block.timestamp > loan.maturity) {
            uint256 overdueStart = MathLib.max(loan.maturity, pos.lastUpdate);
            uint256 overdueElapsed = block.timestamp - overdueStart;
            fixedLeg += pos.debt.mulDivDown(overdueElapsed * loan.overdueRate * BP, SECONDS_PER_YEAR * WAD);
        }

        return (newCollateralIndex, newDebtIndex, fixedLeg, floatingLeg, surplus);
    }

    function _accrueLegs(Loan storage loan, Position storage pos, address pod) internal {
        if (block.timestamp == pos.lastUpdate) return;
        (uint256 newCollateralIndex, uint256 newDebtIndex, uint256 fixedLeg, uint256 floatingLeg, uint256 surplus) =
            _accrueLegsView(loan, pos);

        emit EventsLib.Accrue(pod, newCollateralIndex, newDebtIndex, fixedLeg, floatingLeg, surplus);

        pos.collateralIndex = newCollateralIndex.toUint128();
        pos.debtIndex = newDebtIndex.toUint128();
        pos.fixedLeg += fixedLeg.toUint128();
        pos.floatingLeg += floatingLeg.toUint128();
        pos.surplus += surplus.toUint128();
        // forge-lint: disable-next-item(unsafe-typecast) as timestamp <= uint32.max
        pos.lastUpdate = uint32(block.timestamp);
    }

    function _settleLegs(Loan storage loan, Position storage pos) internal {
        if (block.timestamp < loan.maturity) {
            uint256 timeToMaturity = uint256(loan.maturity).zeroFloorSub(block.timestamp);
            uint256 residual = pos.debt.mulDivDown(timeToMaturity * loan.fixedRate * BP, SECONDS_PER_YEAR * WAD);
            pos.fixedLeg += residual.toUint128();
        }

        uint256 net = pos.fixedLeg.zeroFloorSub(pos.floatingLeg);
        uint256 _fee = loan.fee * BP;
        uint256 performanceFee = net != 0 && _fee != 0 ? net.mulDivDown(_fee, WAD) : 0;
        uint256 surplusFee = _fee != 0 ? pos.surplus.mulDivDown(_fee, WAD) : 0;

        if (net != 0) _claimable(loan.debtToken, net - performanceFee, loan.solver);
        if (pos.surplus != 0) _claimable(loan.collateralToken, pos.surplus - surplusFee, loan.solver);
        if (performanceFee != 0) _claimable(loan.debtToken, performanceFee, feeRecipient);
        if (surplusFee != 0) _claimable(loan.collateralToken, surplusFee, feeRecipient);
    }

    function claim(address token, uint256 amount, address onBehalf, address receiver) external {
        require(token != address(0), ZeroAddress());
        require(amount != 0, ZeroAmount());
        require(onBehalf != address(0), ZeroAddress());
        require(receiver != address(0), ZeroAddress());
        require(_isSenderAuthorized(onBehalf), Unauthorized());
        claimable[token][onBehalf] -= amount;
        token.safeTransfer(receiver, amount);
        emit EventsLib.Claim(msg.sender, token, onBehalf, receiver, amount);
    }

    function _claimable(address token, uint256 amount, address account) internal {
        require(token != address(0), ZeroAddress());
        require(account != address(0), ZeroAddress());
        claimable[token][account] += amount;
        emit EventsLib.Claimable(token, account, amount);
    }
}
