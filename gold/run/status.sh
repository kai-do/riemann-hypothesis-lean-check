#!/usr/bin/env bash
# Writes results/status.txt every 5 minutes (read-only observation; runs outside the sandbox).
W=/home/rhcheck/work; R=$W/results; T=175187
start=$(date -d "$(grep -oP 'BUILD START \K\S+' $R/build-phase.txt)" +%s)
while true; do
  now=$(date +%s); el=$((now-start))
  n=$(find $W/proj/.lake/build/lib/lean -name '*.olean' 2>/dev/null | wc -l)
  job=$(grep -oE '\[[0-9]+/[0-9]+\]' $R/build.log 2>/dev/null | tail -1)
  errs=$(grep -cE '^error' $R/build.log 2>/dev/null); sorr=$(grep -c 'declaration uses .sorry.' $R/build.log 2>/dev/null)
  used=$(df -BG --output=used $W | tail -1 | tr -d ' ')
  mem=$(free -g | awk '/Mem/{print $7}')
  phase=$(tail -n 1 $R/build-phase.txt)
  python3 -I - "$n" "$el" "$T" "$job" "$errs" "$sorr" "$used" "$mem" "$phase" > $R/status.txt.tmp <<'PY'
import sys
n,el,T=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
r=n/el*3600 if el>0 else 0
eta=(T-n)/r if r>0 else float('nan')
print(f"modules {n}/{T} ({100*n/T:.2f}%)  elapsed {el//3600}h{el%3600//60:02d}m  rate {r:.0f}/h  build ETA {eta:.1f}h")
print(f"lake {sys.argv[4]}  errors {sys.argv[5]}  sorry-warnings {sys.argv[6]}  disk-used {sys.argv[7]}  mem-avail {sys.argv[8]}G")
print(f"phase: {sys.argv[9]}")
PY
  mv $R/status.txt.tmp $R/status.txt
  grep -q "DONE\|FAILED" $R/build-phase.txt && break
  sleep 300
done
