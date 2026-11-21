#!/usr/bin/env bash
# Inside the VM as rhcheck, network off. Sandboxed `lake build` of all default targets, then sandboxed export.
# Lake's and lean4export's output goes to stdout; this (unsandboxed) shell writes it to results/.
set -uo pipefail
W=/home/rhcheck/work; R=$W/results; . $W/gold/run/sandbox.sh
cd $W/proj
echo "BUILD START $(date -Is)" | tee $R/build-phase.txt
/usr/bin/time -v -o $R/build.time bash -c ". $W/gold/run/sandbox.sh; sb $W/proj/.lake -- lake build" > $R/build.log 2>&1
rc=$?
echo "BUILD EXIT $rc $(date -Is)" | tee -a $R/build-phase.txt
echo "errors: $(grep -cE '^error' $R/build.log || true)  sorry warnings: $(grep -c 'declaration uses .sorry.' $R/build.log || true)" | tee -a $R/build-phase.txt
[ $rc = 0 ] || { echo "BUILD FAILED"; tail -n 40 $R/build.log; exit 1; }
# Hash list in the same format as Sutherland's project-oleans.sha256.
( cd $W/proj/.lake/build/lib/lean && find . -name '*.olean' | LC_ALL=C sort | xargs -d '\n' sha256sum ) > $R/project-oleans.sha256
echo "project oleans: $(wc -l < $R/project-oleans.sha256)  list sha256: $(sha256sum < $R/project-oleans.sha256 | cut -c1-64)" | tee -a $R/build-phase.txt
echo "EXPORT START $(date -Is)" | tee -a $R/build-phase.txt
/usr/bin/time -v -o $R/export.time bash -c ". $W/gold/run/sandbox.sh; sb $W/proj/.lake -- lake env $W/tools/src/lean4export/.lake/build/bin/lean4export Main -- $(cat $W/gold/export-targets.txt)" > $R/solution.ndjson 2> $R/export.err
rc=$?
echo "EXPORT EXIT $rc $(date -Is)" | tee -a $R/build-phase.txt
[ $rc = 0 ] || { echo "EXPORT FAILED"; tail -n 20 $R/export.err; exit 1; }
sha256sum $R/solution.ndjson | tee $R/solution.ndjson.sha256
stat -c '%s bytes' $R/solution.ndjson | tee -a $R/build-phase.txt
(cd $W/proj && sha256sum -c --quiet $R/source-manifest.sha256sums) && echo "sources still match the archive manifest" | tee -a $R/build-phase.txt
echo "BUILD+EXPORT DONE" | tee -a $R/build-phase.txt
