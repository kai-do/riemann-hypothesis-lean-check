#!/usr/bin/env bash
# Inside the VM as rhcheck, network off. Checks that read the compiled .olean files directly (no export needed),
# one at a time, and writes results/judge-<id>.json for the post: {id, status, time, ram, evidence}.
# Statuses are read off exit codes as each tool documents them; evidence is the tool's own last output line.
set -uo pipefail
W=/home/rhcheck/work; R=$W/results; T=$W/tools/src; . $W/gold/run/sandbox.sh
B36=/home/rhcheck/.elan/toolchains/leanprover--lean4---v4.36.0/bin
CH=$R/challenge.ndjson; SOL=$R/solution.ndjson
export SB_RO="$R /home/rhcheck/fast $W/challenge"   # checkers may read the exports; they still write only sbtmp (and proj/.lake via RW)
grep -q "BUILD EXIT 0" $R/build-phase.txt || { echo "OLEAN CHECKS SKIPPED: build did not succeed" | tee -a $R/build-phase.txt; exit 1; }
echo "OLEAN CHECKS START $(date -Is)" | tee -a $R/build-phase.txt

record() { # id rc log [evidence-override]
  python3 -I - "$@" <<'PY'
import json, re, sys
jid, rc, log = sys.argv[1], int(sys.argv[2]), sys.argv[3]
override = sys.argv[4] if len(sys.argv) > 4 else ""
txt = open(log, errors="replace").read()
lines = [l.strip() for l in txt.splitlines() if l.strip() and not l.startswith(("\t", "Command being timed"))]
tm = re.search(r"Elapsed \(wall clock\) time \(h:mm:ss or m:ss\): (\S+)", txt)
ram = re.search(r"Maximum resident set size \(kbytes\): (\d+)", txt)
body = [l for l in lines if not re.match(r"^(Command exited|Command terminated|User|System|Percent|Elapsed|Average|Maximum|Major|Minor|Voluntary|Involuntary|Swaps|File system|Socket|Signals|Page size|Exit status|con-leche: stats|con-ron: stats)", l)]
last = override or (body[-1] if body else "")
status = {0: "✅ Accepted"}.get(rc, "⏳ Did not finish (time limit)" if rc == 124 else f"⚠️ Exit {rc} (see evidence)")
ev = f"`{last[:160]}`" if last else ""
json.dump({"id": jid, "status": status, "time": tm.group(1) if tm else "",
           "ram": f"{int(ram.group(1))/1048576:.1f} GB" if ram else "", "evidence": ev, "exit": rc},
          open(f"{sys.argv[3].rsplit('/',1)[0]}/judge-{jid}.json", "w"))
PY
}
run() { # id timeout-hours -- cmd...   (sandboxed: read-only everything it needs, writes only sbtmp)
  local id=$1 hrs=$2; shift 3
  echo "== $id $(date -Is)" | tee -a $R/build-phase.txt
  /usr/bin/time -v -o $R/judge-$id.time timeout ${hrs}h bash -c '. '$W'/gold/run/sandbox.sh; sb '"${RW:-$W/sbtmp}"' -- "$@"' _ "$@" > $R/judge-$id.log 2>&1
  local rc=$?; cat $R/judge-$id.time >> $R/judge-$id.log; record $id $rc $R/judge-$id.log
  echo "   $id exit $rc" | tee -a $R/build-phase.txt
}
CL=$T/con-leche/.lake/build/bin/con-leche
pk() { local d=$1; ls -d $d/.lake/packages/*/.lake/build/lib/lean | tr '\n' ':' | sed 's/:$//'; }
# Trusted side: the challenge and the Mathlib built from source before any project code ran.
CORE=/home/rhcheck/.elan/toolchains/leanprover--lean4---v4.33.1/lib/lean   # Lean core (Init, Std, Lean): trusted
TRUSTED=$CORE:$W/challenge/.lake/build/lib/lean:$(pk $W/challenge)
# Solution side: the project's compiled files (Mathlib is read from the trusted side first).
SOLP=$W/proj/.lake/build/lib/lean:$(pk $W/proj)
cd $W/sbtmp
run con-leche-olean 24 -- $CL --olean --jobs=22 --progress=10% --compare --trusted-search-path=$TRUSTED --search-path=$SOLP Challenge Main

# The repo's own axiom audit (no project code runs: oleans loaded with loadExts := false).
# Built from the checker repo, then copied into tools/bin, which the sandbox allows to execute.
( cd $W/checker/tools/axiomcheck && lake build >/dev/null 2>&1 ) && cp $W/checker/tools/axiomcheck/.lake/build/bin/axiomcheck $W/tools/bin/ && \
  cd $W/proj && RW=$W/proj/.lake run axiomcheck 6 -- lake env $W/tools/bin/axiomcheck

echo "OLEAN CHECKS DONE $(date -Is)" | tee -a $R/build-phase.txt
