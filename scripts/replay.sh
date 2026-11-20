#!/usr/bin/env bash
# Kernel re-check of the compiled project with leanchecker (ships with the Lean toolchain).
# Run after scripts/check.sh has built everything.
#
#   scripts/replay.sh               # --fresh Main: replay EVERY constant Main depends on
#                                   # (Lean core + Mathlib + project) into an empty environment.
#                                   # Strongest check. Single-threaded; expect many hours.
#   scripts/replay.sh --per-module  # replay each project module against its imports, in parallel.
#                                   # Trusts Mathlib/core oleans. Uses all cores, lots of RAM.
#
# leanchecker loads .olean files without running any project code and re-checks every
# declaration with the kernel, catching "environment hacking" (declarations added without
# kernel checking). It is not a fully external verifier; for that, see lean4lean in CLAUDE.md.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LEAN="$ROOT/lean"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN="$ROOT/results/replay-$STAMP"
MODE="${1:---fresh}"
mkdir -p "$RUN"
for d in "$HOME/.elan/bin" "${USERPROFILE:-/nonexistent}/.elan/bin"; do
  [ -d "$d" ] && PATH="$d:$PATH"
done

cd "$LEAN"
[ -f .lake/build/lib/lean/Main.olean ] || { echo "Main is not built; run scripts/check.sh first." >&2; exit 1; }
LC="$(lean --print-prefix | tr -d '\r')/bin/leanchecker"
[ -x "$LC" ] || LC="$LC.exe"
[ -x "$LC" ] || { echo "leanchecker not found in toolchain" >&2; exit 1; }

TIMER=()
command -v /usr/bin/time >/dev/null 2>&1 && TIMER=(/usr/bin/time -v)

echo "Mode: $MODE   started $(date)" | tee "$RUN/SUMMARY.txt"
rc=0
case "$MODE" in
  --fresh)
    "${TIMER[@]}" lake env "$LC" --fresh --verbose Main 2>&1 | tee "$RUN/replay.log"
    rc=${PIPESTATUS[0]}
    ;;
  --per-module)
    # Every top-level module prefix the project builds (BuildAid, Development, ..., Main, Statements).
    mapfile -t prefixes < <(ls .lake/build/lib/lean | sed -n 's/\.olean$//p; /\./!p' | sort -u)
    for p in "${prefixes[@]}"; do
      echo "--- $p  $(date)" | tee -a "$RUN/replay.log"
      "${TIMER[@]}" lake env "$LC" "$p" 2>&1 | tee -a "$RUN/replay.log"
      r=${PIPESTATUS[0]}
      [ "$r" = 0 ] || { rc=$r; echo "FAIL  $p (exit $r)" | tee -a "$RUN/SUMMARY.txt"; }
    done
    ;;
  *) echo "usage: scripts/replay.sh [--fresh|--per-module]" >&2; exit 2 ;;
esac

echo "finished $(date)" | tee -a "$RUN/SUMMARY.txt"
if [ "$rc" = 0 ]; then echo "RESULT: PASS (leanchecker $MODE found no problems)" | tee -a "$RUN/SUMMARY.txt"
else echo "RESULT: FAIL (leanchecker exit $rc; see $RUN/replay.log)" | tee -a "$RUN/SUMMARY.txt"; fi
exit "$rc"
