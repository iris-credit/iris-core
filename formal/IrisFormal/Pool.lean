import IrisFormal.Conservation

/-!
# The pool over any sequence of calls

All bonds and `claimable` balances sit in the one Iris contract, so an accounting error on one pod is paid
from the others. `World` keeps every pod, Iris's token balances and the pooled claimable sums; `step`
runs one entry point. The theorem: over any run, the pool's excess falls by at most the sum of the
venue gaps the closing calls met. With no gap, Iris always holds at least `Σ claimable + Σ bond`.
-/

namespace Iris

structure World where
  count : Nat
  pods : Nat → Position
  loans : Nat → Loan
  balDebt : Int
  balColl : Int
  /-- `Σ claimable[debtToken][account]` over all accounts. -/
  claimDebt : Int
  /-- `Σ claimable[collateralToken][account]` over all accounts. -/
  claimColl : Int

def bondSum (pods : Nat → Position) : Nat → Int
  | 0 => 0
  | n + 1 => bondSum pods n + (pods n).bond

def excessDebt (w : World) : Int := w.balDebt - w.claimDebt - bondSum w.pods w.count

def excessColl (w : World) : Int := w.balColl - w.claimColl

def setPod (pods : Nat → Position) (i : Nat) (q : Position) : Nat → Position :=
  fun j => if j = i then q else pods j

theorem bondSum_setPod (pods : Nat → Position) (i : Nat) (q : Position) :
    ∀ n, bondSum (setPod pods i q) n =
      bondSum pods n + (if i < n then (q.bond : Int) - (pods i).bond else 0)
  | 0 => by simp [bondSum]
  | n + 1 => by
    simp only [bondSum, bondSum_setPod pods i q n, setPod]
    by_cases h1 : n = i
    · subst h1
      simp only [ite_true, Nat.lt_irrefl, ite_false, Nat.lt_succ_self]
      omega
    · by_cases h2 : i < n
      · have : i < n + 1 := Nat.lt_succ_of_lt h2
        simp only [h1, h2, this, ite_true, ite_false]
        omega
      · have : ¬i < n + 1 := by omega
        simp only [h1, h2, this, ite_false]
        omega

/-- Apply a call's outcome to pod `i`. -/
def World.apply (w : World) (i : Nat) (o : Outcome) : World :=
  { w with
    pods := setPod w.pods i o.pos
    balDebt := w.balDebt + o.fx.debtIn - o.fx.debtOut
    balColl := w.balColl + o.fx.collIn - o.fx.collOut
    claimDebt := w.claimDebt + o.fx.debtCredit
    claimColl := w.claimColl + o.fx.collCredit }

theorem apply_excess {w : World} {i : Nat} (o : Outcome) (hi : i < w.count) :
    excessDebt (w.apply i o) = excessDebt w + debtDelta o.fx (w.pods i).bond o.pos.bond ∧
      excessColl (w.apply i o) = excessColl w + collDelta o.fx := by
  simp only [excessDebt, excessColl, World.apply, debtDelta, collDelta, bondSum_setPod, hi, ite_true]
  omega

inductive PodCall
  | repay
  | liquidate
  | supplyCollateral (amount : Nat)
  | withdrawCollateral (amount : Nat)
  | supplyBond (amount : Nat)
  | withdrawBond (amount : Nat)
  | liquidateBond
  | rebase
  | refinance (newVenue : Venue)
  | escape

inductive Call
  | take (l : Loan) (collateral debt bond bondRequirement : Nat)
  | pod (i : Nat) (c : PodCall)
  /-- `claim` of `amount` debt token (`claimable` is checked per account, which only adds reverts). -/
  | claimDebt (amount : Nat)
  | claimColl (amount : Nat)

def PodCall.exec (c : PodCall) (l : Loan) (p : Position) (v : Venue) (now : Nat) : Option Outcome :=
  match c with
  | .repay => Iris.repay l p v now
  | .liquidate => Iris.liquidate l p v now
  | .supplyCollateral a => Iris.supplyCollateral l p v now a
  | .withdrawCollateral a => Iris.withdrawCollateral l p v now a
  | .supplyBond a => Iris.supplyBond p a
  | .withdrawBond a => Iris.withdrawBond l p v now a
  | .liquidateBond => Iris.liquidateBond l p v now
  | .rebase => Iris.rebaseCall l p v now
  | .refinance nv => Iris.refinance l p v nv now
  | .escape => Iris.escape p

/-- What a call can take from the debt-token excess: the debt gap, for the two closing calls. -/
def Call.debtRisk (w : World) (c : Call) (v : Venue) (now : Nat) : Nat :=
  match c with
  | .pod i .repay | .pod i .liquidate => debtGap (w.loans i) (w.pods i) v now
  | _ => 0

/-- What a call can take from the collateral-token excess: the collateral gap, for `liquidate`. -/
def Call.collRisk (w : World) (c : Call) (v : Venue) (now : Nat) : Nat :=
  match c with
  | .pod i .liquidate => collGap (w.loans i) (w.pods i) v now
  | _ => 0

/-- One entry point. `v` is the venue as the call sees it, `now` the block timestamp. -/
def step (w : World) (c : Call) (v : Venue) (now : Nat) : Option World :=
  match c with
  | .take l collateral debt bond bondRequirement =>
    (take l collateral debt bond bondRequirement v now).map fun o =>
      { w.apply w.count o with
        count := w.count + 1
        loans := fun j => if j = w.count then l else w.loans j }
  | .pod i pc => if i < w.count then (pc.exec (w.loans i) (w.pods i) v now).map (w.apply i) else none
  | .claimDebt a => some { w with balDebt := w.balDebt - a, claimDebt := w.claimDebt - a }
  | .claimColl a => some { w with balColl := w.balColl - a, claimColl := w.claimColl - a }

/-- `setFee` keeps `fee <= MAX_FEE`, and `take` snapshots it into the loan. -/
def FeesOk (w : World) : Prop := ∀ i, i < w.count → (w.loans i).fee ≤ MAX_FEE_BP

theorem podCall_bound {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome} (c : PodCall)
    (hfee : l.fee ≤ MAX_FEE_BP) (h : c.exec l p v now = some o) :
    -((match c with | .repay | .liquidate => debtGap l p v now | _ => 0 : Nat) : Int) ≤
        debtDelta o.fx p.bond o.pos.bond ∧
      -((match c with | .liquidate => collGap l p v now | _ => 0 : Nat) : Int) ≤ collDelta o.fx := by
  cases c with
  | repay =>
    obtain ⟨h1, h2⟩ := repay_bound hfee h
    exact ⟨h1, by simp [h2]⟩
  | liquidate =>
    obtain ⟨h1, h2, -⟩ := liquidate_bound hfee h
    exact ⟨h1, h2⟩
  | supplyCollateral a =>
    obtain ⟨h1, h2⟩ := supplyCollateral_delta h
    simp [h1, h2]
  | withdrawCollateral a =>
    obtain ⟨h1, h2⟩ := withdrawCollateral_delta h
    simp [h1, h2]
  | supplyBond a =>
    obtain ⟨h1, h2⟩ := supplyBond_delta h
    simp [h1, h2]
  | withdrawBond a =>
    obtain ⟨h1, h2⟩ := withdrawBond_delta h
    simp [h1, h2]
  | liquidateBond =>
    obtain ⟨h1, h2⟩ := liquidateBond_delta h
    simp only [h2]
    omega
  | rebase =>
    obtain ⟨h1, h2⟩ := rebaseCall_delta h
    simp [h1, h2]
  | refinance nv =>
    obtain ⟨h1, h2⟩ := refinance_delta h
    simp [h1, h2]
  | escape =>
    obtain ⟨h1, h2⟩ := escape_delta h
    simp [h1, h2]

/-- One call lowers each excess by at most its risk, and keeps fees within `MAX_FEE`. -/
theorem step_excess {w w' : World} {c : Call} {v : Venue} {now : Nat}
    (hw : FeesOk w) (h : step w c v now = some w') :
    excessDebt w - c.debtRisk w v now ≤ excessDebt w' ∧
      excessColl w - c.collRisk w v now ≤ excessColl w' ∧ FeesOk w' := by
  cases c with
  | take l collateral debt bond bondRequirement =>
    simp only [step, Option.map_eq_some_iff] at h
    obtain ⟨o, ho, rfl⟩ := h
    obtain ⟨h1, h2⟩ := take_delta ho
    have hfee : l.fee ≤ MAX_FEE_BP := by
      unfold take at ho
      split at ho
      · contradiction
      · omega
    have hbond : (w.pods w.count).bond = (w.pods w.count).bond := rfl
    refine ⟨?_, ?_, ?_⟩
    · simp only [excessDebt, World.apply, bondSum, bondSum_setPod, Nat.lt_irrefl, ite_false, setPod,
        ite_true, Call.debtRisk]
      simp only [debtDelta] at h1
      omega
    · simp only [excessColl, World.apply, Call.collRisk]
      simp only [collDelta] at h2
      omega
    · intro j hj
      simp only at hj ⊢
      by_cases hjc : j = w.count
      · simp [hjc, hfee]
      · simp only [hjc, ite_false]
        exact hw j (by omega)
  | pod i pc =>
    simp only [step] at h
    split at h
    · rename_i hi
      simp only [Option.map_eq_some_iff] at h
      obtain ⟨o, ho, rfl⟩ := h
      obtain ⟨e1, e2⟩ := apply_excess (w := w) o hi
      obtain ⟨b1, b2⟩ := podCall_bound pc (hw i hi) ho
      refine ⟨?_, ?_, ?_⟩
      · rw [e1]
        cases pc <;> simp only [Call.debtRisk] at b1 ⊢ <;> omega
      · rw [e2]
        cases pc <;> simp only [Call.collRisk] at b2 ⊢ <;> omega
      · exact hw
    · contradiction
  | claimDebt a =>
    simp only [step, Option.some.injEq] at h
    subst h
    exact ⟨by simp [excessDebt, Call.debtRisk]; omega, by simp [excessColl, Call.collRisk], hw⟩
  | claimColl a =>
    simp only [step, Option.some.injEq] at h
    subst h
    exact ⟨by simp [excessDebt, Call.debtRisk], by simp [excessColl, Call.collRisk]; omega, hw⟩

/-- Run a sequence of calls, each with the venue state and timestamp it sees, and sum their risks. -/
def run : World → List (Call × Venue × Nat) → Option (World × Nat × Nat)
  | w, [] => some (w, 0, 0)
  | w, (c, v, now) :: cs =>
    match step w c v now with
    | none => none
    | some w' =>
      (run w' cs).map fun r => (r.1, r.2.1 + c.debtRisk w v now, r.2.2 + c.collRisk w v now)

/-- **Pool conservation.** Over any run, each excess falls by at most the summed venue gaps that the
closing calls met. -/
theorem run_excess :
    ∀ (cs : List (Call × Venue × Nat)) (w w' : World) (d k : Nat),
      FeesOk w → run w cs = some (w', d, k) →
        excessDebt w - d ≤ excessDebt w' ∧ excessColl w - k ≤ excessColl w'
  | [], w, w', d, k, _, h => by
    simp only [run, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl, rfl⟩ := h
    omega
  | (c, v, now) :: cs, w, w', d, k, hw, h => by
    simp only [run] at h
    split at h
    · contradiction
    · rename_i w1 h1
      simp only [Option.map_eq_some_iff] at h
      obtain ⟨⟨w2, d2, k2⟩, hr, he⟩ := h
      simp only [Prod.mk.injEq] at he
      obtain ⟨rfl, rfl, rfl⟩ := he
      obtain ⟨s1, s2, hw1⟩ := step_excess hw h1
      obtain ⟨r1, r2⟩ := run_excess cs w1 w2 d2 k2 hw1 hr
      constructor <;> push_cast <;> omega

/-- The deployed contract: no pods, no balances, no claims. -/
def World.empty : World :=
  { count := 0, pods := fun _ => default, loans := fun _ => default
    balDebt := 0, balColl := 0, claimDebt := 0, claimColl := 0 }

/-- **Solvency.** From deployment, if no closing call ever meets a venue gap, Iris always holds at least
`Σ claimable + Σ bond` in the debt token and `Σ claimable` in the collateral token. -/
theorem solvent_of_no_gap (cs : List (Call × Venue × Nat)) (w : World)
    (h : run World.empty cs = some (w, 0, 0)) :
    0 ≤ excessDebt w ∧ 0 ≤ excessColl w := by
  have hw : FeesOk World.empty := fun i hi => absurd hi (Nat.not_lt_zero i)
  obtain ⟨h1, h2⟩ := run_excess cs World.empty w 0 0 hw h
  have e1 : excessDebt World.empty = 0 := by simp [excessDebt, World.empty, bondSum]
  have e2 : excessColl World.empty = 0 := by simp [excessColl, World.empty]
  rw [e1] at h1
  rw [e2] at h2
  omega

end Iris
