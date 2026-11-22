#!/usr/bin/env bash
# Inside the VM as rhcheck, network off. The export step on its own (06-build.sh's export had a quoting bug:
# the multi-line target list was pasted into a bash -c string, so each line ran as a command). Targets are now
# passed as arguments, never through a command string.
set -uo pipefail
W=/home/rhcheck/work; R=$W/results; . $W/gold/run/sandbox.sh
export SB_RO="${SB_RO:-} /home/rhcheck/fast"   # compiled files live on the uncompressed disk (proj/.lake/build/lib/lean is a symlink)
mapfile -t TARGETS < <(tr -s ' \n' '\n' < $W/gold/export-targets.txt | sed '/^$/d')
echo "export targets: ${#TARGETS[@]}" | tee -a $R/build-phase.txt
cd $W/proj
echo "EXPORT START $(date -Is)" | tee -a $R/build-phase.txt
/usr/bin/time -v -o $R/export.time bash -c '. '$W'/gold/run/sandbox.sh; cd '$W'/proj; sb '$W'/proj/.lake -- lake env '$W'/tools/src/lean4export/.lake/build/bin/lean4export Main -- "$@"' _ "${TARGETS[@]}" > $R/solution.ndjson 2> $R/export.err
rc=$?
echo "EXPORT EXIT $rc $(date -Is)" | tee -a $R/build-phase.txt
[ $rc = 0 ] || { echo "EXPORT FAILED" | tee -a $R/build-phase.txt; tail -n 20 $R/export.err; exit 1; }
sha256sum $R/solution.ndjson | tee $R/solution.ndjson.sha256
stat -c '%s bytes' $R/solution.ndjson | tee -a $R/build-phase.txt
(cd $W/proj && sha256sum -c --quiet $R/source-manifest.sha256sums) && echo "sources still match the archive manifest" | tee -a $R/build-phase.txt
echo "BUILD+EXPORT DONE" | tee -a $R/build-phase.txt
