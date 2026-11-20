import Main

/-!
Independent check of the project's headline results.

`RiemannHypothesis` below is resolved in the root namespace, so it is Mathlib's
definition, not anything the project defines. `#print axioms` lists every axiom
each proof depends on. A clean result is exactly
`[propext, Classical.choice, Quot.sound]`; `sorryAx` or any project-declared
axiom means the result is not proved.
-/

example : _root_.RiemannHypothesis := riemannHypothesis

#print axioms riemannHypothesis
#print axioms riemannZeta_eq_zero_re
#print axioms LFunction_ne_zero_of_half_lt_re
#print axioms LFunction_eq_zero_re
#print axioms LFunction_eq_zero_re_of_isPrimitive
