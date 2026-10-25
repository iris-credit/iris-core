import IrisFormal.Lemmas

/-!
# Per-call conservation

`debtDelta` and `collDelta` are what one call does to the pool's excess

  `excess = Iris token balance - Σ claimable - Σ bond`   (debt token)
  `excess = Iris token balance - Σ claimable`           (collateral token)

computed from the call's own token movements, claimable credits and bond change. Every entry point
either leaves the excess unchanged or raises it, except the two closing calls, which can lower it only
by what the venue holds against Iris's books (`debtGap`, `collGap`).
-/

namespace Iris

set_option linter.deprecated false

/-- Change of the debt-token excess made by a call on a pod whose bond went `bondBefore -> bondAfter`. -/
def debtDelta (fx : Effects) (bondBefore bondAfter : Nat) : Int :=
  (fx.debtIn : Int) - fx.debtOut - fx.debtCredit - ((bondAfter : Int) - bondBefore)

/-- Change of the collateral-token excess made by a call. -/
def collDelta (fx : Effects) : Int := (fx.collIn : Int) - fx.collOut - fx.collCredit


/-- `repay` changes the debt-token excess by exactly `debt + floatingLeg - venueDebt`, read after
`_rebase`, and leaves the collateral-token excess unchanged. -/
theorem repay_delta {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (hfee : l.fee ≤ MAX_FEE_BP) (h : repay l p v now = some o) :
    debtDelta o.fx p.bond o.pos.bond =
        (((rebase (accrue l p v now) v).1.debt + (rebase (accrue l p v now) v).1.floatingLeg : Nat) : Int)
          - v.debt ∧
      collDelta o.fx = 0 := by
  unfold repay at h
  split at h
  · contradiction
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  have hA := accrue_bond l p v now
  generalize accrue l p v now = a at *
  have hR := rebase_bond a v
  generalize rebase a v = r at *
  obtain ⟨hd, hf, hb, hs, _⟩ := settle_fields l r.1 now
  have hdc := settle_debtCredit (l := l) r.1 now hfee
  have hcc := settle_collCredit (l := l) r.1 now hfee
  generalize settle l r.1 now = s at *
  simp only [debtDelta, collDelta, zeroFloorSub]
  omega

/-- `liquidate` changes the debt-token excess like `repay`. In the collateral token it pulls
`min(seized + surplus, venueCollateral)` from the venue but pays `seized` out and credits `surplus`. -/
theorem liquidate_delta {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (hfee : l.fee ≤ MAX_FEE_BP) (h : liquidate l p v now = some o) :
    debtDelta o.fx p.bond o.pos.bond =
        (((rebase (accrue l p v now) v).1.debt + (rebase (accrue l p v now) v).1.floatingLeg : Nat) : Int)
          - v.debt ∧
      ∃ seized ≤ (rebase (accrue l p v now) v).1.collateral,
        collDelta o.fx = ((min (seized + (rebase (accrue l p v now) v).1.surplus) v.collateral : Nat) : Int)
          - seized - (rebase (accrue l p v now) v).1.surplus := by
  unfold liquidate at h
  split at h
  · contradiction
  split at h
  · contradiction
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  have hA := accrue_bond l p v now
  generalize accrue l p v now = a at *
  have hR := rebase_bond a v
  generalize rebase a v = r at *
  obtain ⟨hd, hf, hb, hs, hc⟩ := settle_fields l r.1 now
  have hdc := settle_debtCredit (l := l) r.1 now hfee
  have hcc := settle_collCredit (l := l) r.1 now hfee
  generalize settle l r.1 now = s at *
  refine ⟨?_, ?_⟩
  · simp only [debtDelta, zeroFloorSub]
    omega
  · generalize mulDivDown (mulDivDown _ _ WAD) ORACLE_PRICE_SCALE v.price = x
    refine ⟨min s.1.collateral x, ?_, ?_⟩
    · rw [← hc]; exact Nat.min_le_left _ _
    · simp only [collDelta]
      rw [hcc, hs, hc]

/-- `liquidateBond` pays out at most the bond it slashes; any leftover stays in Iris as a donation. -/
theorem liquidateBond_delta {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (h : liquidateBond l p v now = some o) :
    0 ≤ debtDelta o.fx p.bond o.pos.bond ∧ collDelta o.fx = 0 := by
  unfold liquidateBond at h
  split at h
  · contradiction
  have hA := accrue_bond l p v now
  generalize accrue l p v now = a at *
  have hR := rebase_bond a v
  generalize rebase a v = r at *
  dsimp only at h
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  generalize hlif : min MAX_BOND_LIF _ = lif
  have hlifw : lif ≤ WAD := by
    rw [← hlif]; simp only [MAX_BOND_LIF, WAD]; omega
  have hseized : mulDivDown r.1.bond lif WAD ≤ r.1.bond := mulDivDown_le hlifw
  generalize mulDivDown r.1.bond lif WAD = seized at *
  simp only [debtDelta, collDelta]
  omega

/-- `take` on a fresh pod pulls exactly the bond it records. -/
theorem take_delta {l : Loan} {collateral debt bond req : Nat} {v : Venue} {now : Nat} {o : Outcome}
    (h : take l collateral debt bond req v now = some o) :
    debtDelta o.fx 0 o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold take at h
  split at h
  · contradiction
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  simp [debtDelta, collDelta]

theorem supplyBond_delta {p : Position} {amount : Nat} {o : Outcome}
    (h : supplyBond p amount = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold supplyBond at h
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  simp only [debtDelta, collDelta]
  omega

theorem withdrawBond_delta {l : Loan} {p : Position} {v : Venue} {now amount : Nat} {o : Outcome}
    (h : withdrawBond l p v now amount = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold withdrawBond at h
  split at h
  · contradiction
  have hA := accrue_bond l p v now
  generalize accrue l p v now = a at *
  have hR := rebase_bond a v
  generalize rebase a v = r at *
  dsimp only at h
  split at h
  · contradiction
  rename_i hle
  split at h
  · simp only [Option.some.injEq] at h
    subst h
    simp only [debtDelta, collDelta]
    omega
  · contradiction

/-- `supplyCollateral`, `withdrawCollateral`, `rebase` and `refinance` only move tokens between the caller,
the pod and the venue; inside Iris they only run `_rebase`, which moves bond into claimable. -/
theorem rebaseOnly_delta {p : Position} {r : Position × Nat} {o : Outcome}
    (hR : r.1.bond + r.2 = p.bond) (hb : o.pos.bond = r.1.bond) (hfx : o.fx = { debtCredit := r.2 }) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  simp only [debtDelta, collDelta, hfx, hb]
  omega

theorem supplyCollateral_delta {l : Loan} {p : Position} {v : Venue} {now amount : Nat} {o : Outcome}
    (h : supplyCollateral l p v now amount = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold supplyCollateral at h
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  have hA := accrue_bond l p v now
  have hR := rebase_bond (accrue l p v now) v
  exact rebaseOnly_delta (r := rebase (accrue l p v now) v) (by omega) rfl rfl

theorem withdrawCollateral_delta {l : Loan} {p : Position} {v : Venue} {now amount : Nat} {o : Outcome}
    (h : withdrawCollateral l p v now amount = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold withdrawCollateral at h
  split at h
  · contradiction
  have hA := accrue_bond l p v now
  have hR := rebase_bond (accrue l p v now) v
  generalize rebase (accrue l p v now) v = r at *
  dsimp only at h
  split at h
  · contradiction
  split at h
  · simp only [Option.some.injEq] at h
    subst h
    exact rebaseOnly_delta (r := r) (by omega) rfl rfl
  · contradiction

theorem rebaseCall_delta {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (h : rebaseCall l p v now = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold rebaseCall at h
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  have hA := accrue_bond l p v now
  have hR := rebase_bond (accrue l p v now) v
  exact rebaseOnly_delta (r := rebase (accrue l p v now) v) (by omega) rfl rfl

theorem refinance_delta {l : Loan} {p : Position} {v newVenue : Venue} {now : Nat} {o : Outcome}
    (h : refinance l p v newVenue now = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold refinance at h
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  have hA := accrue_bond l p v now
  have hR := rebase_bond (accrue l p v now) v
  exact rebaseOnly_delta (r := rebase (accrue l p v now) v) (by omega) rfl rfl

theorem escape_delta {p : Position} {o : Outcome} (h : escape p = some o) :
    debtDelta o.fx p.bond o.pos.bond = 0 ∧ collDelta o.fx = 0 := by
  unfold escape at h
  split at h
  · contradiction
  split at h
  · contradiction
  simp only [Option.some.injEq] at h
  subst h
  simp [debtDelta, collDelta]

/-! ## Bounds in terms of the venue state at the call -/

/-- Venue debt above what Iris tracks (debt + floating leg, accrued) for the pod at this call. -/
def debtGap (l : Loan) (p : Position) (v : Venue) (now : Nat) : Nat :=
  zeroFloorSub v.debt ((accrue l p v now).debt + (accrue l p v now).floatingLeg)

/-- Collateral Iris tracks (collateral + surplus, accrued) above the venue collateral at this call. -/
def collGap (l : Loan) (p : Position) (v : Venue) (now : Nat) : Nat :=
  zeroFloorSub ((accrue l p v now).collateral + (accrue l p v now).surplus) v.collateral

/-- `repay` lowers the debt-token excess by at most the debt gap. -/
theorem repay_bound {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (hfee : l.fee ≤ MAX_FEE_BP) (h : repay l p v now = some o) :
    -(debtGap l p v now : Int) ≤ debtDelta o.fx p.bond o.pos.bond ∧ collDelta o.fx = 0 := by
  obtain ⟨hd, hc⟩ := repay_delta hfee h
  refine ⟨?_, hc⟩
  rw [hd]
  unfold debtGap zeroFloorSub
  rcases rebase_debt (accrue l p v now) v with h1 | ⟨h1, h2, h3⟩ <;> omega

/-- `liquidate` lowers the debt-token excess by at most the debt gap and the collateral-token excess by at
most the collateral gap. The collateral excess drops only when the pod's collateral left the venue while
the venue debt stayed at or above what Iris tracks, so `_rebase` could not recognize it. -/
theorem liquidate_bound {l : Loan} {p : Position} {v : Venue} {now : Nat} {o : Outcome}
    (hfee : l.fee ≤ MAX_FEE_BP) (h : liquidate l p v now = some o) :
    -(debtGap l p v now : Int) ≤ debtDelta o.fx p.bond o.pos.bond ∧
      -(collGap l p v now : Int) ≤ collDelta o.fx ∧
      (collDelta o.fx < 0 →
        (accrue l p v now).debt + (accrue l p v now).floatingLeg ≤ v.debt ∧
          v.collateral < (accrue l p v now).collateral + (accrue l p v now).surplus) := by
  obtain ⟨hd, seized, hseized, hc⟩ := liquidate_delta hfee h
  refine ⟨?_, ?_, ?_⟩
  · rw [hd]
    unfold debtGap zeroFloorSub
    rcases rebase_debt (accrue l p v now) v with h1 | ⟨h1, h2, h3⟩ <;> omega
  · rw [hc]
    unfold collGap zeroFloorSub
    rcases rebase_collateral (accrue l p v now) v with h1 | ⟨h1, h2, h3, h4⟩ <;> omega
  · rw [hc]
    intro hneg
    rcases rebase_collateral (accrue l p v now) v with h1 | ⟨h1, h2, h3, h4⟩
    · omega
    · exact ⟨h3, h4⟩

end Iris
