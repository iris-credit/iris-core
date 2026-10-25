import IrisFormal.Pool

/-!
# Concrete runs

The theorems are not vacuous: these calls succeed, and the bounds are reached.
-/

namespace Iris

private def loan : Loan :=
  { maturity := 1000, overduePeriod := 0, fixedRate := 500, overdueRate := 0, bondLltv := 9000, fee := 1000 }

private def pos (collateral debt floatingLeg bondRequirement : Nat) : Position :=
  { collateral, debt, bond := 10, bondRequirement, collateralIndex := 10 ^ 27, debtIndex := 10 ^ 27
    fixedLeg := 0, floatingLeg, surplus := 0, lastUpdate := 2000 }

private def venue (collateral debt : Nat) : Venue :=
  { collateral, debt, price := 10 ^ 36, lltv := 86 * 10 ^ 16
    collateralIndex := 10 ^ 27, debtIndex := 10 ^ 27 }

-- Venue debt equal to Iris's books: repay leaves the pool excess unchanged.
#eval (repay loan (pos 5000 1000 50 1) (venue 5000 1050) 2000).map fun o =>
  (debtDelta o.fx 10 o.pos.bond, collDelta o.fx)
-- some (0, 0)

-- Venue debt 1 wei above Iris's books (the per-accrual round-down gap): the pool pays that wei.
#eval (repay loan (pos 5000 1000 50 1) (venue 5000 1051) 2000).map fun o =>
  (debtDelta o.fx 10 o.pos.bond, collDelta o.fx, debtGap loan (pos 5000 1000 50 1) (venue 5000 1051) 2000)
-- some (-1, 0, 1)

-- The invariant campaign's case: the venue seized all collateral while repaying no more than Iris
-- under-tracked, so `_rebase` returns early and `liquidate` pays the tracked collateral from the pool.
#eval (liquidate loan (pos 100 1000 0 0) (venue 0 1000) 2000).map fun o =>
  (collDelta o.fx, debtGap loan (pos 100 1000 0 0) (venue 0 1000) 2000,
    collGap loan (pos 100 1000 0 0) (venue 0 1000) 2000)
-- some (-100, 0, 100)

end Iris
