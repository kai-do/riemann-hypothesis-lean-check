import Lean

/-!
# axiomcheck

Independent axiom audit for the theorems in `lean/src/Main.lean`.

Why not just `#print axioms`?
* `#print axioms` runs inside an elaborated file that imports the project, so any syntax or
  elaborator the project defines is live and could in principle alter the command.
* Lean's `collectAxioms` reads *pre-computed* axiom lists for imported declarations from data
  stored in `.olean` files at build time, which code running during the build could tamper with.

This tool avoids both: it is a compiled program that loads the `.olean` files with
`loadExts := false` (no environment extensions initialised, no interpreter, no project code
runs) and walks every constant's type and value itself.

Usage (run from `lean/` via `lake env` so the search path includes the build):
  axiomcheck                          -- default: module Main, the five Main theorems
  axiomcheck --module M name1 name2   -- custom module and constants (used for self-test)

Exit code: 0 if every target exists and uses only the standard axioms, 1 otherwise.
-/

open Lean

def standardAxioms : List Name := [``propext, ``Classical.choice, ``Quot.sound]

def defaultTargets : List Name :=
  [`riemannHypothesis, `riemannZeta_eq_zero_re, `LFunction_ne_zero_of_half_lt_re,
   `LFunction_eq_zero_re, `LFunction_eq_zero_re_of_isPrimitive]

/-- Transitively collect axioms reachable from `root`, walking types, values and constructors.
Also returns names referenced but absent from the environment (should always be empty). -/
def collectAxiomsDirect (env : Environment) (root : Name) : NameSet × Array Name × Nat := Id.run do
  let mut seen : NameHashSet := {}
  let mut stack : Array Name := #[root]
  let mut axioms : NameSet := {}
  let mut missing : Array Name := #[]
  while h : stack.size > 0 do
    let c := stack.back
    stack := stack.pop
    if seen.contains c then continue
    seen := seen.insert c
    match env.constants.find? c with
    | none => missing := missing.push c
    | some ci =>
      if ci matches .axiomInfo _ then axioms := axioms.insert c
      let mut exprs := #[ci.type]
      if let some v := ci.value? (allowOpaque := true) then exprs := exprs.push v
      for e in exprs do
        for d in e.getUsedConstants do
          unless seen.contains d do stack := stack.push d
      match ci with
      | .inductInfo v => for d in v.ctors do stack := stack.push d
      | .ctorInfo v => stack := stack.push v.induct
      | .recInfo v => for d in v.all do stack := stack.push d
      | _ => pure ()
  return (axioms, missing, seen.size)

def moduleOf (env : Environment) (n : Name) : String :=
  match env.getModuleIdxFor? n with
  | some idx => toString (env.header.moduleNames[idx.toNat]!)
  | none => "<not imported>"

def kindOf : ConstantInfo → String
  | .thmInfo _ => "theorem" | .defnInfo _ => "def" | .axiomInfo _ => "axiom"
  | .opaqueInfo _ => "opaque" | .quotInfo _ => "quot" | .inductInfo _ => "inductive"
  | .ctorInfo _ => "constructor" | .recInfo _ => "recursor"

def main (args : List String) : IO UInt32 := do
  let (module, targets) := match args with
    | "--module" :: m :: rest => (m.toName, if rest.isEmpty then defaultTargets else rest.map String.toName)
    | [] => (`Main, defaultTargets)
    | rest => (`Main, rest.map String.toName)
  initSearchPath (← findSysroot)
  IO.println s!"Loading {module} (no extensions, no project code executed)..."
  let env ← importModules #[{ module }] {} (loadExts := false)
  IO.println s!"Loaded {env.constants.fold (fun n _ _ => n + 1) 0} constants from {env.header.moduleNames.size} modules.\n"
  let mut ok := true

  -- The headline claim must be Mathlib's own statement, not a project redefinition.
  if module == `Main then
    match env.constants.find? `riemannHypothesis, env.constants.find? `RiemannHypothesis with
    | some thm, some rh =>
      let exact := thm.type == mkConst `RiemannHypothesis
      IO.println s!"Statement check: riemannHypothesis : {thm.type}"
      IO.println s!"  RiemannHypothesis is defined in module {moduleOf env `RiemannHypothesis} ({kindOf rh})"
      IO.println s!"  type is exactly Mathlib's RiemannHypothesis constant: {exact}"
      unless exact && (moduleOf env `RiemannHypothesis).startsWith "Mathlib." do
        ok := false
        IO.println "  FAIL: statement is not Mathlib's RiemannHypothesis"
      IO.println ""
    | _, _ =>
      ok := false
      IO.println "FAIL: riemannHypothesis or Mathlib's RiemannHypothesis not found\n"

  for t in targets do
    match env.constants.find? t with
    | none =>
      ok := false
      IO.println s!"{t}: NOT FOUND"
    | some ci =>
      let (axs, missing, visited) := collectAxiomsDirect env t
      let axList := axs.toList.map toString |>.toArray.qsort (· < ·)
      let nonstandard := axs.toList.filter (!standardAxioms.contains ·)
      let verdict := if nonstandard.isEmpty && missing.isEmpty then "OK" else "FAIL"
      if verdict == "FAIL" then ok := false
      IO.println s!"{t} [{kindOf ci}, module {moduleOf env t}]"
      IO.println s!"  constants visited: {visited}"
      IO.println s!"  axioms: {axList.toList}"
      unless nonstandard.isEmpty do IO.println s!"  NON-STANDARD AXIOMS: {nonstandard}"
      unless missing.isEmpty do IO.println s!"  MISSING CONSTANTS: {missing.toList.take 20}"
      IO.println s!"  verdict: {verdict}\n"

  IO.println (if ok then "RESULT: PASS (only propext, Classical.choice, Quot.sound)" else "RESULT: FAIL")
  return if ok then 0 else 1
