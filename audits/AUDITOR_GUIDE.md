# Iris Auditor Guide

Orientation for the external audit of the Iris protocol.

The header NatSpec in [`Iris.sol`](../src/Iris.sol) (lines 16-205) is the protocol's accepted-risk
register and documents the per-feature design decisions. This guide does not repeat it; it points
at where the real risk sits and answers the architectural questions that NatSpec block is not
organized to answer.

## Scope

In scope: everything under [`src/`](../src/) except [`src/libraries/`](../src/libraries/) and
[`src/periphery/`](../src/periphery/).

- [`Iris.sol`](../src/Iris.sol) - the core accountant and fund custodian (primary target).
- [`Pod.sol`](../src/Pod.sol) - the per-loan clone holding venue positions.
- [`adapters/`](../src/adapters/) - venue adapters (Morpho Blue, Aave V3).
- [`blm/`](../src/blm/) - bond lock modules.
- [`interfaces/`](../src/interfaces/) - interfaces and the shared `Loan` / `Position` / `Quote` structs.

Out of scope: [`src/libraries/`](../src/libraries/) (`ConstantsLib`, `MathLib`, `EventsLib`) and
[`src/periphery/`](../src/periphery/) (the vendored Bundler3 fork and its adapters).

## Critical area: the venue boundary and rebase

The novel risk is the seam between Iris's stored `Position` and the real venue balance. The venue
moves the position on its own (interest accrual, and a liquidation that wipes collateral and debt),
and `_rebase` (840) is the single point that reconciles the two before `_settleLegs` (944) credits
the solver. Because all bonds and `claimable` balances are pooled in the one Iris contract, a
reconciliation error is paid out of other loans' funds. The sensitive path:

**venue liquidation -> `_rebase` mis-reconciles -> corrupted `collateral` / `debt` / `surplus` /
`floatingLeg` / `fixedLeg` / `bond` / `bondRequirement` -> `_settleLegs` over-credits the solver ->
shared pool drained.**

`_rebase` also moves value, not just the inputs to settlement. Recognized repayment over the
principal nets against the fixed leg, and the excess is refunded from the bond to the borrower's
claimable.

Points along this path that warrant attention:
- `_rebase` (840-887) behaves differently across venue transitions: partial liquidation, full
  liquidation, bad debt, a wipe of both collateral and debt, and donations (one-sided supply or
  repay on the pod). Its recognized debt reduction (`maxRepaid`), the `borrowerRepaid` cap that
  keeps repayment funded by a seized surplus out of the netting, the surplus/`floatingLeg` clamps,
  the three ways `bondRequirement` flips to zero (bad debt, wipe, a slash that exhausts the bond),
  and the `zeroFloorSub` / `toUint128` chains each carry value-corrupting edge cases.
- Statement order inside `_rebase` is load-bearing. `overpaid` reads `bondRequirement` after the
  resolve flip, so a loan resolved by this or an earlier rebase nets nothing, and it reads `pos.debt`
  before the principal is written down.
- The protocol rests on the invariant that post-rebase settlement never credits more than the pod
  can withdraw (header 124-125); oracle movement, venue rounding, and adapter behavior all feed it.
- Legs accrue on the last synced balances, so the longer a venue liquidation goes un-rebased the
  further the recognized amounts drift (header 126-128). Nothing on-chain forces a timely rebase.
- The adapter views consumed directly by rebase and settlement (`positionAssets`, `price`,
  `indices`, `lltv`) are trusted inputs, and `setVenueAdapter` can swap an adapter on a live loan,
  running arbitrary code in every pod via delegatecall.

The rest of the surface (bond math, EIP-712 signatures, access control, fees) is conventional.

## Common questions

| Question | Answer |
| --- | --- |
| Who is trusted? | The owner/timelock (whitelists adapters, BLMs, bond LLTVs, market `data`), the venue adapters (delegatecalled into pods), the underlying venues, conforming ERC-20s, and the BLM. Solver and borrower are trust-minimized against each other via the signed quote and the bond. |
| What can the owner do, and is there a pause? | `setOwner`, `setFee`, `setFeeRecipient`, `setVenueAdapter`, `enableBlm`, `enableBondLltv`, `enableData`. There is no pause. The strongest power is swapping a venue adapter on active loans. |
| How are funds isolated between loans? | Venue exposure is isolated in a per-loan `Pod` clone, but all bonds and `claimable` balances live in the single Iris contract. So accounting correctness, not pod isolation, is what stops one loan draining another, which is why the rebase/settlement path is the critical area. |
| Can settlement over-credit a solver? | By design it should not: `accrue -> rebase -> settle` runs settlement on post-rebase venue-real amounts. Whether a venue, oracle, or rounding path can let `claimable` exceed what the pod can withdraw is the central solvency question. |
| How is replay prevented? | EIP-712 with a domain bound to chainId + contract address. Solver quotes (`take`) burn unordered `isQuoteNonceUsed[solver][nonce]` entries. Authorizer signatures (`setAuthorizationWithSig`) consume a sequential per-authorizer `nonce`, so at most one outstanding signature is valid; a direct `setAuthorization` does not advance it, and an outstanding signed authorization is canceled by consuming its nonce with a newer signed one. |
| Is there reentrancy protection? | No explicit guard. Safety relies on non-reentrant tokens and trusted venues/adapters; CEI is intentionally not enforced. |
| Where are the tests? | [`test/unit/`](../test/unit/) for logic, [`test/fork/`](../test/fork/) for mainnet-fork integration against real Morpho Blue and Aave V3, [`test/invariant/`](../test/invariant/) for the stateful campaign (solvency, bond, fixed-leg monotonicity). |

## Glossary

- **Pod**: single-use minimal clone holding one loan's venue position; isolated per loan.
- **Loan** ([`IIris.sol`](../src/interfaces/IIris.sol) 4-16): immutable-after-take terms (parties,
  tokens, rates, maturity, `bondLltv`, `fee`); only the venue changes, via refinance.
- **Position** ([`IIris.sol`](../src/interfaces/IIris.sol) 18-31): live accounting (collateral, debt, bond, bondRequirement, indices,
  fixedLeg, floatingLeg, surplus, lastUpdate, venueId, data).
- **fixedLeg**: fixed interest the borrower owes the solver, including residual through maturity.
- **floatingLeg**: variable interest the venue charges, owed by the solver.
- **net**: `fixedLeg - floatingLeg`, the solver's profit when positive.
- **negativeNet**: `floatingLeg - fixedLeg`, the solver's loss, covered by the bond.
- **surplus**: collateral venue yield, owed to the solver.
- **bond**: the solver's posted debt-token stake covering the negative net.
- **bondRequirement**: minimum bond from the BLM; a withdrawal floor, not a liquidation trigger;
  `0` means the loan is resolved/closed.
- **bad bond**: `negativeNet` exceeds the whole bond, so the borrower bears the remainder. Also
  arises inside `_rebase` when the bond cannot cover the netting excess.
- **bad debt**: venue debt exceeds the debt-token value of remaining venue collateral.
- **overpaid**: repayment `_rebase` recognizes above the tracked principal; floating interest the
  borrower's collateral paid, netted against `fixedLeg` and then slashed from the bond to the
  borrower.
- **resolved**: `bondRequirement == 0` on a loan that was never closed by repay or liquidate,
  reached by bad debt, a venue wipe, a bond liquidation, or a slash that exhausts the bond. `rebase`
  and the close paths shut down; the borrower's remaining exits are `escape` and `claim`.
- **claimable**: pooled per (token, account) credit held inside Iris and withdrawn with `claim`.
  Solvers, the fee recipient, and, since the netting refund, borrowers hold balances in it.
