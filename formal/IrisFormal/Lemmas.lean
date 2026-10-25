import IrisFormal.Model

/-!
# Facts about the internal functions

What the conservation proofs need from `_accrueLegs`, `_rebase` and `_settleLegs`.
-/

namespace Iris

set_option linter.deprecated false

theorem accrue_bond (l : Loan) (p : Position) (v : Venue) (now : Nat) :
    (accrue l p v now).bond = p.bond := by
  unfold accrue
  split <;> rfl

/-! ## `_rebase` -/

/-- The bond `_rebase` slashes is exactly what leaves the position's bond. -/
theorem rebase_bond (q : Position) (v : Venue) : (rebase q v).1.bond + (rebase q v).2 = q.bond := by
  unfold rebase
  dsimp only
  by_cases h : (zeroFloorSub (q.collateral + q.surplus) v.collateral = 0 ∨ zeroFloorSub (q.debt + q.floatingLeg) v.debt = 0)
  · rw [if_pos h]
    by_cases h2 : v.collateral > q.collateral + q.surplus
    · rw [if_pos h2]; dsimp only; omega
    · rw [if_neg h2]; dsimp only; omega
  · rw [if_neg h]
    exact Nat.sub_add_cancel (Nat.min_le_right _ _)

/-- After `_rebase`, Iris's debt plus floating leg covers the venue debt, unless `_rebase` took the
early return with the venue debt already at or above what Iris tracked (`repaid == 0`). -/
theorem rebase_debt (q : Position) (v : Venue) :
    v.debt ≤ (rebase q v).1.debt + (rebase q v).1.floatingLeg ∨
      ((rebase q v).1.debt = q.debt ∧ (rebase q v).1.floatingLeg = q.floatingLeg ∧
        q.debt + q.floatingLeg ≤ v.debt) := by
  unfold rebase
  dsimp only
  by_cases h : (zeroFloorSub (q.collateral + q.surplus) v.collateral = 0 ∨ zeroFloorSub (q.debt + q.floatingLeg) v.debt = 0)
  · rw [if_pos h]
    simp only [zeroFloorSub] at h
    by_cases h2 : v.collateral > q.collateral + q.surplus
    · rw [if_pos h2]; dsimp only; omega
    · rw [if_neg h2]; dsimp only; omega
  · rw [if_neg h]
    left
    dsimp only
    simp only [zeroFloorSub] at h ⊢
    generalize mulDivDown _ _ _ = m
    by_cases h3 : v.debt ≤ q.floatingLeg
    · rw [if_pos h3]; omega
    · rw [if_neg h3]; omega

/-- After `_rebase`, Iris's collateral plus surplus is within the venue collateral, unless `_rebase`
took the early return with collateral gone from the venue but the venue debt at or above what Iris
tracked: then collateral and surplus are left as they were. -/
theorem rebase_collateral (q : Position) (v : Venue) :
    (rebase q v).1.collateral + (rebase q v).1.surplus ≤ v.collateral ∨
      ((rebase q v).1.collateral = q.collateral ∧ (rebase q v).1.surplus = q.surplus ∧
        q.debt + q.floatingLeg ≤ v.debt ∧ v.collateral < q.collateral + q.surplus) := by
  unfold rebase
  dsimp only
  by_cases h : (zeroFloorSub (q.collateral + q.surplus) v.collateral = 0 ∨ zeroFloorSub (q.debt + q.floatingLeg) v.debt = 0)
  · rw [if_pos h]
    simp only [zeroFloorSub] at h
    by_cases h2 : v.collateral > q.collateral + q.surplus
    · rw [if_pos h2]; dsimp only; omega
    · rw [if_neg h2]; dsimp only; omega
  · rw [if_neg h]
    left
    dsimp only
    simp only [zeroFloorSub] at h ⊢
    have key : ∀ (c : Prop) [Decidable c], (if c then 0 else if v.collateral ≤ q.surplus then v.collateral else q.surplus) ≤
        (if v.collateral ≤ q.surplus then v.collateral else q.surplus) := by
      intro c _; split <;> omega
    refine Nat.le_trans (Nat.add_le_add_left (key _) _) ?_
    split <;> omega

theorem mulDivDown_le {x y d : Nat} (h : y ≤ d) : mulDivDown x y d ≤ x := by
  unfold mulDivDown
  rcases Nat.eq_zero_or_pos d with hd | hd
  · simp [hd]
  · apply Nat.div_le_of_le_mul
    rw [Nat.mul_comm d x]
    exact Nat.mul_le_mul_left x h

theorem fee_le_wad {l : Loan} (h : l.fee ≤ MAX_FEE_BP) : l.fee * BP ≤ WAD := by
  simp only [MAX_FEE_BP] at h
  simp only [BP, WAD]
  omega

/-! ## `_settleLegs` -/

theorem settle_fields (l : Loan) (p : Position) (now : Nat) :
    (settle l p now).1.debt = p.debt ∧ (settle l p now).1.floatingLeg = p.floatingLeg ∧
      (settle l p now).1.bond = p.bond ∧ (settle l p now).1.surplus = p.surplus ∧
      (settle l p now).1.collateral = p.collateral := by
  unfold settle
  dsimp only
  by_cases h : now < l.maturity
  · rw [if_pos h]; exact ⟨rfl, rfl, rfl, rfl, rfl⟩
  · rw [if_neg h]; exact ⟨rfl, rfl, rfl, rfl, rfl⟩

theorem credit_split (x f : Nat) (hf : f ≤ WAD) :
    ((if x ≠ 0 then x - (if x ≠ 0 ∧ f ≠ 0 then mulDivDown x f WAD else 0) else 0) +
      (if x ≠ 0 ∧ f ≠ 0 then mulDivDown x f WAD else 0)) = x := by
  have hle : mulDivDown x f WAD ≤ x := mulDivDown_le hf
  by_cases hx : x = 0
  · subst hx; simp
  · by_cases hf0 : f = 0
    · simp [hx, hf0]
    · simp only [hx, hf0, ne_eq, not_false_eq_true, and_self, ite_true]; omega

/-- With `fee <= MAX_FEE`, solver and fee recipient are credited exactly `net` in the debt token. -/
theorem settle_debtCredit {l : Loan} (p : Position) (now : Nat) (hfee : l.fee ≤ MAX_FEE_BP) :
    (settle l p now).2.1 = (settle l p now).1.fixedLeg - (settle l p now).1.floatingLeg := by
  unfold settle
  dsimp only
  exact credit_split _ _ (fee_le_wad hfee)

/-- With `fee <= MAX_FEE`, solver and fee recipient are credited exactly the surplus in the collateral
token. -/
theorem settle_collCredit {l : Loan} (p : Position) (now : Nat) (hfee : l.fee ≤ MAX_FEE_BP) :
    (settle l p now).2.2 = (settle l p now).1.surplus := by
  unfold settle
  dsimp only
  have hw := fee_le_wad hfee
  generalize (if now < l.maturity then _ else p) = q
  have hle : mulDivDown q.surplus (l.fee * BP) WAD ≤ q.surplus := mulDivDown_le hw
  by_cases hs : q.surplus = 0
  · simp [hs, mulDivDown]
  · by_cases hf0 : l.fee * BP = 0
    · simp [hs, hf0]
    · simp only [hs, hf0, ne_eq, not_false_eq_true, ite_true]; omega

end Iris
