import Mathlib

/-!
# Challenge statements for the Lean RH project

Trusted, human-reviewed statements. This file imports only Mathlib. Each theorem is stated with `sorry`;
Comparator checks that the project's `Main` proves the theorem of the same name with exactly this statement,
using only `propext`, `Quot.sound` and `Classical.choice`.

The four `Prop`s below must be term-for-term identical to the project's definitions of the same name,
because Comparator requires every definition a challenge statement depends on to match in the solution.
-/

/-- Every zero of `ζ` that is not a trivial zero `-2, -4, -6, …` and not `s = 1` has real part `1/2`.
(This is the body of Mathlib's `RiemannHypothesis`, written out.) -/
def RiemannZetaZerosOnLine : Prop :=
  ∀ s : ℂ, riemannZeta s = 0 → (¬∃ n : ℕ, s = -2 * ((n : ℂ) + 1)) → s ≠ 1 → s.re = 1 / 2

/-- For every modulus `N ≥ 1` and every Dirichlet character `χ` mod `N`, `L(χ, s) ≠ 0` whenever
`Re s > 1/2`, except at the pole `χ = 1, s = 1`. -/
def DirichletLNonvanishingRightOfHalf : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N) (s : ℂ),
    1 / 2 < s.re → (χ ≠ 1 ∨ s ≠ 1) → DirichletCharacter.LFunction χ s ≠ 0

/-- Every zero of every Dirichlet L-function in the critical strip `0 < Re s < 1` has `Re s = 1/2`. -/
def DirichletLZerosOnLine : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N) (s : ℂ),
    0 < s.re → s.re < 1 → DirichletCharacter.LFunction χ s = 0 → s.re = 1 / 2

/-- The same, restricted to primitive characters. -/
def PrimitiveDirichletLZerosOnLine : Prop :=
  ∀ (N : ℕ) [NeZero N] (χ : DirichletCharacter ℂ N), χ.IsPrimitive →
    ∀ s : ℂ, 0 < s.re → s.re < 1 → DirichletCharacter.LFunction χ s = 0 → s.re = 1 / 2

/-- The headline claim, stated with Mathlib's own definition `RiemannHypothesis`. -/
theorem riemannHypothesis : RiemannHypothesis := by sorry

theorem riemannZeta_eq_zero_re : RiemannZetaZerosOnLine := by sorry

theorem LFunction_ne_zero_of_half_lt_re : DirichletLNonvanishingRightOfHalf := by sorry

theorem LFunction_eq_zero_re : DirichletLZerosOnLine := by sorry

theorem LFunction_eq_zero_re_of_isPrimitive : PrimitiveDirichletLZerosOnLine := by sorry
