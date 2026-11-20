#!/usr/bin/env bash
# Verify, build and audit the project in lean/. Re-run to resume an interrupted build.
#
#   scripts/check.sh              # full run
#   scripts/check.sh --preflight  # everything up to (not including) the build; minutes, not days
#
# Each run writes results/<timestamp>/ with SUMMARY.txt (PASS/FAIL per stage), build.log,
# axiomcheck.txt, print-axioms.txt. results/LATEST names the most recent run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEAN="$ROOT/lean"
WORK="$ROOT/.check"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="$ROOT/results/$STAMP"
SUMMARY="$RUN/SUMMARY.txt"
MATHLIB_URL="https://github.com/leanprover-community/mathlib4"
FAILED=0
PREFLIGHT=0
[ "${1:-}" = "--preflight" ] && PREFLIGHT=1

mkdir -p "$RUN"
echo "$STAMP" > "$ROOT/results/LATEST"
for d in "$HOME/.elan/bin" "${USERPROFILE:-/nonexistent}/.elan/bin"; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done

log()   { echo "$*" | tee -a "$SUMMARY"; }
pass()  { log "PASS  $*"; }
fail()  { log "FAIL  $*"; FAILED=1; }
abort() { log "FAIL  $*"; log "RESULT: ABORTED (see $RUN)"; exit 1; }
stage() { echo; echo "=== $*"; }

log "Run $STAMP on $(uname -srm), $(nproc 2>/dev/null || echo '?') threads"

# ---------------------------------------------------------------- 0. tooling
stage "Tooling"
command -v lake >/dev/null 2>&1 || abort "lake not found; run scripts/bootstrap.sh"
[ -n "$PY" ] || abort "python3 not found"
[ -f "$WORK/lean.sha256sums" ] || abort "lean/ not set up; run scripts/setup.sh"
want_tc="$(tr -d '[:space:]' < "$LEAN/lean-toolchain")"
tool_tc="$(tr -d '[:space:]' < "$ROOT/tools/axiomcheck/lean-toolchain")"
[ "$want_tc" = "$tool_tc" ] || abort "tools/axiomcheck/lean-toolchain ($tool_tc) != lean/lean-toolchain ($want_tc)"
pass "toolchain $want_tc"

if git -C "$ROOT" rev-parse --verify -q HEAD >/dev/null; then
  if git -C "$ROOT" diff --quiet HEAD -- scripts checks tools ARCHIVE.sha256; then
    pass "checker files match git commit $(git -C "$ROOT" rev-parse --short HEAD)"
  else
    fail "checker files differ from git HEAD (run: git diff HEAD -- scripts checks tools ARCHIVE.sha256)"
  fi
else
  log "NOTE  repo has no commits; cannot verify checker files against git"
fi

# ---------------------------------------------------------------- 1. sources (pre-build)
stage "Source integrity (pre-build)"
if ( cd "$LEAN" && sha256sum -c --quiet "$WORK/lean.sha256sums" ); then
  pass "all $(wc -l < "$WORK/lean.sha256sums") source files match the archive manifest"
else
  abort "source files changed since extraction; re-run scripts/setup.sh --force"
fi

cd "$LEAN"

# ---------------------------------------------------------------- 2. dependencies
stage "Dependencies (prebuilt Mathlib)"
if lake exe cache get > "$RUN/cache.log" 2>&1; then
  pass "Mathlib cache fetched (log: cache.log)"
else
  tail -20 "$RUN/cache.log"
  abort "lake exe cache get failed (see $RUN/cache.log)"
fi

stage "Dependency provenance"
M="$LEAN/.lake/packages/mathlib"
mathlib_rev="$("$PY" -I "$ROOT/scripts/manifest_revs.py" "$LEAN/lake-manifest.json" | awk -F'\t' '$1=="mathlib"{print $2}')"
origin="$(git -C "$M" remote get-url origin)"
[ "${origin%.git}" = "$MATHLIB_URL" ] && pass "mathlib origin is $MATHLIB_URL" || fail "mathlib origin is $origin"
[ "$(git -C "$M" rev-parse HEAD)" = "$mathlib_rev" ] && pass "mathlib checked out at pinned $mathlib_rev" \
  || fail "mathlib HEAD $(git -C "$M" rev-parse HEAD) != pinned $mathlib_rev"
git -C "$M" fetch --quiet origin '+refs/heads/master:refs/remotes/origin/master' '+refs/tags/*:refs/tags/*' 2>/dev/null \
  || log "NOTE  could not fetch mathlib master/tags; provenance check uses local refs"
if git -C "$M" merge-base --is-ancestor "$mathlib_rev" origin/master 2>/dev/null; then
  pass "pinned mathlib commit is on official master"
else
  tag="$(git -C "$M" tag --points-at "$mathlib_rev" | head -1)"
  base="$(git -C "$M" merge-base "$mathlib_rev" origin/master 2>/dev/null || true)"
  extra="$( [ -n "$base" ] && git -C "$M" diff --name-only "$base" "$mathlib_rev" | grep -vxE 'lean-toolchain|lake-manifest\.json' )"
  if [ -n "$tag" ] && [ -n "$base" ] && [ -z "$extra" ]; then
    pass "pinned mathlib commit is official tag $tag (differs from master only in lean-toolchain/lake-manifest.json)"
  else
    fail "pinned mathlib commit is neither on master nor an official toolchain-only tag (tag='$tag', extra files: $extra)"
  fi
fi
# Every other package must be at the revision Mathlib's own manifest pins.
while IFS=$'\t' read -r name rev _; do
  [ "$name" = "mathlib" ] && continue
  want="$("$PY" -I "$ROOT/scripts/manifest_revs.py" "$M/lake-manifest.json" | awk -F'\t' -v n="$name" '$1==n{print $2}')"
  have="$(git -C "$LEAN/.lake/packages/$name" rev-parse HEAD 2>/dev/null || echo missing)"
  if [ "$want" = "$rev" ] && [ "$have" = "$rev" ]; then pass "package $name at Mathlib-pinned ${rev:0:12}"
  else fail "package $name: project pins $rev, Mathlib pins $want, checked out $have"; fi
done < <("$PY" -I "$ROOT/scripts/manifest_revs.py" "$LEAN/lake-manifest.json")
for p in "$LEAN"/.lake/packages/*/; do
  [ -z "$(git -C "$p" status --porcelain --untracked-files=no)" ] && pass "package $(basename "$p") worktree clean" \
    || fail "package $(basename "$p") has modified tracked files"
done

DEPS="$WORK/deps.sha256sums"
hash_deps() { ( cd "$LEAN" && find .lake/packages -path '*/.lake/build/*' -name '*.olean*' -type f -print0 | sort -z | xargs -0 sha256sum ); }
if [ -f "$DEPS" ]; then
  if sha256sum -c --quiet "$DEPS" >/dev/null 2>&1; then pass "dependency .olean files unchanged since first snapshot"
  else fail "dependency .olean files changed since first snapshot (delete .lake/packages/*/.lake/build and .check/deps.sha256sums, then re-run)"; fi
else
  hash_deps > "$DEPS"
  pass "snapshotted $(wc -l < "$DEPS") dependency .olean files (from official Mathlib cache)"
fi

if [ "$PREFLIGHT" = 1 ]; then
  echo
  if [ "$FAILED" = 0 ]; then log "RESULT: PREFLIGHT PASS (ready to build)"; else log "RESULT: PREFLIGHT FAIL"; fi
  exit "$FAILED"
fi

# ---------------------------------------------------------------- 3. build
stage "Build (long; resumes where it left off)"
log "INFO  build started $(date)"
lake build 2>&1 | tee "$RUN/build.log"
build_rc=${PIPESTATUS[0]}
log "INFO  build finished $(date)"
sorry_count="$(grep -c "declaration uses 'sorry'" "$RUN/build.log" || true)"
[ "$build_rc" = 0 ] && pass "lake build succeeded" || abort "lake build failed (exit $build_rc; see $RUN/build.log)"
[ "$sorry_count" = 0 ] && pass "no 'declaration uses sorry' warnings" || fail "$sorry_count 'declaration uses sorry' warnings in build log"

# ---------------------------------------------------------------- 4. axiom audit
stage "Axiom audit (independent tool)"
( cd "$ROOT/tools/axiomcheck" && lake build ) > "$RUN/axiomcheck-build.log" 2>&1 || abort "could not build tools/axiomcheck"
AXC="$ROOT/tools/axiomcheck/.lake/build/bin/axiomcheck"
[ -x "$AXC" ] || AXC="$AXC.exe"
if lake env "$AXC" 2>&1 | tee "$RUN/axiomcheck.txt"; [ "${PIPESTATUS[0]}" = 0 ]; then
  pass "axiomcheck: statement is Mathlib's RiemannHypothesis; only standard axioms"
else
  fail "axiomcheck reported a problem (see $RUN/axiomcheck.txt)"
fi

stage "Cross-check with #print axioms"
if lake env lean "$ROOT/checks/Axioms.lean" 2>&1 | tee "$RUN/print-axioms.txt"; [ "${PIPESTATUS[0]}" = 0 ]; then
  if grep -q sorryAx "$RUN/print-axioms.txt"; then fail "#print axioms mentions sorryAx"
  else pass "#print axioms ran (secondary; see print-axioms.txt)"; fi
else
  fail "#print axioms check failed to run"
fi

# ---------------------------------------------------------------- 5. post-build integrity
stage "Integrity (post-build)"
sha256sum -c --quiet "$DEPS" >/dev/null 2>&1 && pass "dependency .olean files unchanged after build" \
  || fail "dependency .olean files changed during build"
for p in "$LEAN"/.lake/packages/*/; do
  [ -z "$(git -C "$p" status --porcelain --untracked-files=no)" ] || fail "package $(basename "$p") modified during build"
done
cd "$ROOT"
expected="$(cut -d' ' -f1 ARCHIVE.sha256)"
if [ "$(sha256sum "$WORK/lean.tar.gz" | cut -d' ' -f1)" = "$expected" ]; then
  pass "archive still matches committed ARCHIVE.sha256"
  if "$PY" -I "$ROOT/scripts/verify_from_archive.py" "$WORK/lean.tar.gz" "$ROOT" | tee -a "$SUMMARY"; [ "${PIPESTATUS[0]}" = 0 ]; then
    pass "every source file re-verified directly against the archive"
  else
    fail "source files differ from the archive"
  fi
else
  fail "reassembled archive no longer matches ARCHIVE.sha256 (re-run scripts/setup.sh, then this check)"
fi

echo
if [ "$FAILED" = 0 ]; then log "RESULT: PASS"; else log "RESULT: FAIL (see FAIL lines above)"; fi
log "Results: $RUN"
log "Next (optional, strongest): scripts/replay.sh  # kernel re-check of every declaration"
exit "$FAILED"
