#!/usr/bin/env bash
# Run inside the VM as rhcheck, BEFORE any project code is compiled. Builds Mathlib from source in the trusted
# challenge workspace, builds Challenge, and exports it with lean4export.
set -euo pipefail
W=/home/rhcheck/work; C=$W/challenge; R=$W/results
export PATH=~/.elan/bin:$PATH
cd $C
test "$(cat lean-toolchain)" = "leanprover/lean4:v4.33.1"
# Network must be OFF here (VM in isolated mode) so nothing can be fetched; Mathlib is built from source.
if curl -fsS -m 5 -o /dev/null https://github.com 2>/dev/null; then echo "network is ON; refusing" >&2; exit 1; fi
test -f lake-manifest.json                      # created in the fetch phase; no update => no post-update hooks
test -z "$(find .lake/packages -path '*/.lake/build/*' -name '*.olean' -print -quit)"   # no prebuilt oleans
test "$(git -C .lake/packages/mathlib rev-parse HEAD)" = 0df444a360eaa60ab8c11dca51a86af692955474
echo "Mathlib from source (network off): start $(date -Is)"
/usr/bin/time -v lake build Challenge > $R/challenge-build.log 2> $R/challenge-build.time || { tail -n 30 $R/challenge-build.log; exit 1; }
echo "Mathlib + Challenge built: $(date -Is)"
echo "sorry warnings in Challenge (expect 5): $(grep -c 'declaration uses .sorry.' $R/challenge-build.log || true)"
lake env $W/tools/src/lean4export/.lake/build/bin/lean4export Challenge -- $(cat $W/gold/export-targets.txt) > $R/challenge.ndjson
sha256sum $R/challenge.ndjson | tee $R/challenge.ndjson.sha256
echo "CHALLENGE DONE"
