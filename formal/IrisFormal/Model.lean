/-!
# Iris accounting model

A line-by-line transcription of the value-moving paths of `src/Iris.sol` into `Nat` functions.

* `mulDivDown`/`mulDivUp`/`zeroFloorSub` are the EVM integer operations, so every round-down and
  round-up of the contract is kept, not abstracted away.
* A call either returns `none` (the contract reverts on a `require` or a checked underflow that can
  actually trigger) or `some` outcome: the new `Position` of the pod and the `Effects` of the call on
  Iris's token balances and on the pooled `claimable` sums.
* `uint128` casts and checked additions are not modeled: they only add reverts, and every theorem is
  about successful calls.
* The venue adapter is an input. `Venue` is what its views return during the call; no Iris call moves
  the venue before its last view read, so one snapshot covers the whole call.
* One debt token and one collateral token. Every effect of a pod is in its loan's tokens, so with more
  tokens the accounting splits per token.
-/

namespace Iris

def WAD : Nat := 10 ^ 18
def BP : Nat := 10 ^ 14
def ORACLE_PRICE_SCALE : Nat := 10 ^ 36
def SECONDS_PER_YEAR : Nat := 31536000
def MAX_LIF : Nat := 15 * 10 ^ 16
def TIME_TO_MAX_LIF : Nat := 900
def MAX_BOND_LIF : Nat := 5 * 10 ^ 16
def LIQUIDATION_CURSOR : Nat := 5 * 10 ^ 17
/-- `MAX_FEE / BP`: `setFee` keeps `fee <= MAX_FEE` and stores `fee / BP`. -/
def MAX_FEE_BP : Nat := 4000

/-- `MathLib.mulDivDown`. `Nat` division by zero is `0` where the EVM reverts; that only adds runs. -/
def mulDivDown (x y d : Nat) : Nat := x * y / d

/-- `MathLib.mulDivUp`. -/
def mulDivUp (x y d : Nat) : Nat := (x * y + (d - 1)) / d

/-- `MathLib.zeroFloorSub` is truncated `Nat` subtraction. -/
def zeroFloorSub (x y : Nat) : Nat := x - y

/-- `struct Loan`, the fields the value paths read. Rates, `bondLltv` and `fee` are stored in BP units. -/
structure Loan where
  maturity : Nat
  overduePeriod : Nat
  fixedRate : Nat
  overdueRate : Nat
  bondLltv : Nat
  fee : Nat
  deriving Inhabited

/-- `struct Position`. -/
structure Position where
  collateral : Nat
  debt : Nat
  bond : Nat
  bondRequirement : Nat
  collateralIndex : Nat
  debtIndex : Nat
  fixedLeg : Nat
  floatingLeg : Nat
  surplus : Nat
  lastUpdate : Nat
  deriving Inhabited

/-- The venue adapter views during one call: `positionAssets`, `price`, `lltv`, `indices`. -/
structure Venue where
  collateral : Nat
  debt : Nat
  price : Nat
  lltv : Nat
  collateralIndex : Nat
  debtIndex : Nat

/-- What one call does to Iris's own token balances and to the pooled `claimable` sums. -/
structure Effects where
  debtIn : Nat := 0
  debtOut : Nat := 0
  collIn : Nat := 0
  collOut : Nat := 0
  debtCredit : Int := 0
  collCredit : Int := 0

structure Outcome where
  pos : Position
  fx : Effects

/-! ## Internal functions -/

/-- `_accrueLegsView`: the indices and the leg increments since `lastUpdate`. -/
def accrueView (l : Loan) (p : Position) (v : Venue) (now : Nat) : Nat × Nat × Nat × Nat × Nat :=
  let elapsed := now - p.lastUpdate
  if p.lastUpdate = 0 ∨ elapsed = 0 then (p.collateralIndex, p.debtIndex, 0, 0, 0)
  else
    let fixedLeg := mulDivDown p.debt (elapsed * l.fixedRate * BP) (SECONDS_PER_YEAR * WAD)
    let floatingLeg := mulDivDown (p.debt + p.floatingLeg) (v.debtIndex - p.debtIndex) p.debtIndex
    let surplus :=
      if p.bondRequirement ≠ 0 then
        mulDivDown (p.collateral + p.surplus) (v.collateralIndex - p.collateralIndex) p.collateralIndex
      else 0
    let fixedLeg :=
      if now > l.maturity then
        fixedLeg + mulDivDown p.debt ((now - max l.maturity p.lastUpdate) * l.overdueRate * BP)
          (SECONDS_PER_YEAR * WAD)
      else fixedLeg
    (v.collateralIndex, v.debtIndex, fixedLeg, floatingLeg, surplus)

/-- `_accrueLegs`. -/
def accrue (l : Loan) (p : Position) (v : Venue) (now : Nat) : Position :=
  if now = p.lastUpdate then p
  else
    let a := accrueView l p v now
    { p with
      collateralIndex := a.1
      debtIndex := a.2.1
      fixedLeg := p.fixedLeg + a.2.2.1
      floatingLeg := p.floatingLeg + a.2.2.2.1
      surplus := p.surplus + a.2.2.2.2
      lastUpdate := now }

/-- `_rebase`. Returns the new position and the bond slashed into the borrower's claimable. -/
def rebase (p : Position) (v : Venue) : Position × Nat :=
  let liquidated := zeroFloorSub (p.collateral + p.surplus) v.collateral
  let repaid := zeroFloorSub (p.debt + p.floatingLeg) v.debt
  if liquidated = 0 ∨ repaid = 0 then
    if v.collateral > p.collateral + p.surplus then
      ({ p with collateral := v.collateral - p.surplus }, 0)
    else (p, 0)
  else
    let maxRepaid := mulDivDown liquidated v.price ORACLE_PRICE_SCALE
    let badDebt := zeroFloorSub v.debt (mulDivDown v.collateral v.price ORACLE_PRICE_SCALE)
    let repaid := min repaid maxRepaid
    let borrowerRepaid :=
      min repaid (mulDivDown (min liquidated p.collateral) v.price ORACLE_PRICE_SCALE)
    let overpaid := if p.bondRequirement = 0 then 0 else zeroFloorSub borrowerRepaid p.debt
    let bondSlashed := min (zeroFloorSub overpaid p.fixedLeg) p.bond
    let surplus := if v.collateral ≤ p.surplus then v.collateral else p.surplus
    let floatingLeg := if v.debt ≤ p.floatingLeg then v.debt else p.floatingLeg
    let bondRequirement := if badDebt ≠ 0 ∨ v.debt = 0 then 0 else p.bondRequirement
    let bond := p.bond - bondSlashed
    let exhausted := bondSlashed ≠ 0 ∧ bond = 0
    ({ p with
        collateral := zeroFloorSub p.collateral liquidated
        debt := zeroFloorSub p.debt repaid
        fixedLeg := if overpaid ≠ 0 then zeroFloorSub p.fixedLeg overpaid else p.fixedLeg
        floatingLeg := floatingLeg
        bond := bond
        surplus := if exhausted then 0 else surplus
        bondRequirement := if exhausted then 0 else bondRequirement },
      bondSlashed)

/-- `_settleLegs`. Returns the position with the residual added, and the debt-token and collateral-token
amounts it credits to `claimable` (solver plus fee recipient). -/
def settle (l : Loan) (p : Position) (now : Nat) : Position × Nat × Nat :=
  let p :=
    if now < l.maturity then
      { p with
        fixedLeg := p.fixedLeg +
          mulDivDown p.debt ((l.maturity - now) * l.fixedRate * BP) (SECONDS_PER_YEAR * WAD) }
    else p
  let net := zeroFloorSub p.fixedLeg p.floatingLeg
  let fee := l.fee * BP
  let performanceFee := if net ≠ 0 ∧ fee ≠ 0 then mulDivDown net fee WAD else 0
  let surplusFee := if fee ≠ 0 then mulDivDown p.surplus fee WAD else 0
  let debtCredit := (if net ≠ 0 then net - performanceFee else 0) + performanceFee
  let collCredit := (if p.surplus ≠ 0 then p.surplus - surplusFee else 0) + surplusFee
  (p, debtCredit, collCredit)

/-- `_isHealthyBond`. -/
def isHealthyBond (l : Loan) (p : Position) : Bool :=
  if p.bondRequirement = 0 then true
  else if p.floatingLeg ≤ p.fixedLeg then true
  else decide (mulDivUp (p.floatingLeg - p.fixedLeg) WAD p.bond ≤ l.bondLltv * BP)

/-! ## Entry points -/

/-- `take` on a fresh pod. The collateral goes from the caller to the pod, the bond into Iris. -/
def take (l : Loan) (collateral debt bond bondRequirement : Nat) (v : Venue) (now : Nat) :
    Option Outcome :=
  if collateral = 0 ∨ debt = 0 ∨ bond = 0 ∨ l.fee > MAX_FEE_BP then none
  else if bondRequirement = 0 ∨ bond < bondRequirement then none
  else
    some {
      pos := {
        collateral, debt, bond, bondRequirement
        collateralIndex := v.collateralIndex
        debtIndex := v.debtIndex
        fixedLeg := 0, floatingLeg := 0, surplus := 0
        lastUpdate := now }
      fx := { debtIn := bond } }

def repay (l : Loan) (p : Position) (v : Venue) (now : Nat) : Option Outcome :=
  if p.lastUpdate = 0 then none
  else if p.debt + p.fixedLeg = 0 ∧ p.bondRequirement = 0 ∧ p.surplus = 0 then none
  else
    let r := rebase (accrue l p v now) v
    let s := settle l r.1 now
    let q := s.1
    let negativeNet := zeroFloorSub q.floatingLeg q.fixedLeg
    let bondSlashed := min negativeNet q.bond
    let badBond := zeroFloorSub negativeNet q.bond
    let repaid := q.debt + q.fixedLeg + badBond
    some {
      pos := { q with
        debt := 0, bond := q.bond - bondSlashed, bondRequirement := 0
        fixedLeg := 0, floatingLeg := 0, surplus := 0 }
      -- pull `repaid`, send `venueDebt` to the pod, exit withdraws `surplus` collateral to Iris
      fx := {
        debtIn := repaid, debtOut := v.debt, collIn := q.surplus
        debtCredit := r.2 + s.2.1, collCredit := s.2.2 } }

def liquidate (l : Loan) (p : Position) (v : Venue) (now : Nat) : Option Outcome :=
  if p.lastUpdate = 0 then none
  else if p.debt + p.fixedLeg = 0 ∧ p.bondRequirement = 0 ∧ p.surplus = 0 then none
  else if now ≤ l.maturity + l.overduePeriod then none
  else
    let r := rebase (accrue l p v now) v
    let s := settle l r.1 now
    let q := s.1
    let negativeNet := zeroFloorSub q.floatingLeg q.fixedLeg
    let bondSlashed := min negativeNet q.bond
    let badBond := zeroFloorSub negativeNet q.bond
    let repaid := q.debt + q.fixedLeg + badBond
    let lif := min MAX_LIF (mulDivDown MAX_LIF (now - (l.maturity + l.overduePeriod)) TIME_TO_MAX_LIF)
    let seized :=
      min q.collateral (mulDivDown (mulDivDown repaid (WAD + lif) WAD) ORACLE_PRICE_SCALE v.price)
    some {
      pos := { q with
        collateral := q.collateral - seized, debt := 0, bond := q.bond - bondSlashed
        bondRequirement := 0, fixedLeg := 0, floatingLeg := 0, surplus := 0 }
      -- exit withdraws `min(seized + surplus, venueCollateral)` to Iris, then Iris sends `seized` out
      fx := {
        debtIn := repaid, debtOut := v.debt
        collIn := min (seized + q.surplus) v.collateral, collOut := seized
        debtCredit := r.2 + s.2.1, collCredit := s.2.2 } }

/-- Collateral moves between the caller and the pod, never through Iris. -/
def supplyCollateral (l : Loan) (p : Position) (v : Venue) (now amount : Nat) : Option Outcome :=
  if amount = 0 then none
  else
    let r := rebase (accrue l p v now) v
    some { pos := { r.1 with collateral := r.1.collateral + amount }, fx := { debtCredit := r.2 } }

def withdrawCollateral (l : Loan) (p : Position) (v : Venue) (now amount : Nat) : Option Outcome :=
  if amount = 0 ∨ now > l.maturity + l.overduePeriod then none
  else
    let r := rebase (accrue l p v now) v
    let q := r.1
    if amount > q.collateral then none
    else
      let q : Position := { q with collateral := q.collateral - amount }
      let maxDebt := mulDivDown (mulDivDown q.collateral v.price ORACLE_PRICE_SCALE) v.lltv WAD
      let timeToLiquidation := zeroFloorSub (l.maturity + l.overduePeriod) now
      let residual := mulDivDown q.debt
        (timeToLiquidation * l.fixedRate * BP + min timeToLiquidation l.overduePeriod * l.overdueRate * BP)
        (SECONDS_PER_YEAR * WAD)
      let exposure := max (q.fixedLeg + residual) (zeroFloorSub q.floatingLeg q.bond)
      if q.debt + exposure ≤ maxDebt then some { pos := q, fx := { debtCredit := r.2 } } else none

def supplyBond (p : Position) (amount : Nat) : Option Outcome :=
  if amount = 0 then none else some { pos := { p with bond := p.bond + amount }, fx := { debtIn := amount } }

def withdrawBond (l : Loan) (p : Position) (v : Venue) (now amount : Nat) : Option Outcome :=
  if amount = 0 then none
  else
    let r := rebase (accrue l p v now) v
    if amount > r.1.bond then none
    else
      let q : Position := { r.1 with bond := r.1.bond - amount }
      if q.bond ≥ q.bondRequirement ∧ isHealthyBond l q then
        some { pos := q, fx := { debtOut := amount, debtCredit := r.2 } }
      else none

def liquidateBond (l : Loan) (p : Position) (v : Venue) (now : Nat) : Option Outcome :=
  if p.lastUpdate = 0 ∨ p.bondRequirement = 0 then none
  else
    let r := rebase (accrue l p v now) v
    let q := r.1
    if isHealthyBond l q then none
    else
      let lif := min MAX_BOND_LIF
        (mulDivDown WAD WAD (WAD - mulDivDown LIQUIDATION_CURSOR (WAD - l.bondLltv * BP) WAD) - WAD)
      let seized := mulDivDown q.bond lif WAD
      let negativeNet := q.floatingLeg - q.fixedLeg
      let bondSlashed := min (negativeNet + seized) q.bond
      let repaid := min (bondSlashed - seized) v.debt
      some {
        pos := { q with
          debt := 0, bond := q.bond - bondSlashed, bondRequirement := 0
          fixedLeg := 0, floatingLeg := 0, surplus := 0 }
        -- send `repaid` to the pod for the venue, send `seized` to the receiver
        fx := { debtOut := repaid + seized, debtCredit := r.2 } }

def rebaseCall (l : Loan) (p : Position) (v : Venue) (now : Nat) : Option Outcome :=
  if p.lastUpdate = 0 ∨ p.bondRequirement = 0 then none
  else
    let r := rebase (accrue l p v now) v
    some { pos := r.1, fx := { debtCredit := r.2 } }

/-- The caller funds the venue debt straight into the pod; only the indices change in Iris. -/
def refinance (l : Loan) (p : Position) (v newVenue : Venue) (now : Nat) : Option Outcome :=
  if p.lastUpdate = 0 ∨ p.bondRequirement = 0 ∨ now > l.maturity + l.overduePeriod then none
  else
    let r := rebase (accrue l p v now) v
    some {
      pos := { r.1 with collateralIndex := newVenue.collateralIndex, debtIndex := newVenue.debtIndex }
      fx := { debtCredit := r.2 } }

/-- The caller funds the venue debt straight into the pod; the venue position exits to the receiver. -/
def escape (p : Position) : Option Outcome :=
  if p.lastUpdate = 0 then none
  else if ¬(p.bondRequirement = 0 ∧ p.debt + p.fixedLeg + p.surplus = 0) then none
  else
    some { pos := { p with collateral := 0, debt := 0, fixedLeg := 0, floatingLeg := 0, surplus := 0 }, fx := {} }

end Iris
