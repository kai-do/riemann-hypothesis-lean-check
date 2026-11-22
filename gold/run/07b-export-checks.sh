#!/usr/bin/env bash
# Inside the VM as rhcheck, network off. Re-runs the export, then runs every checker one at a time (memory),
# fastest first, and writes results/judge-<id>.json for the post: {id, status, time, ram, evidence}.
# Statuses are read off exit codes as each tool documents them; evidence is the tool's own last output line.
set -uo pipefail
W=/home/rhcheck/work; R=$W/results; T=$W/tools/src; . $W/gold/run/sandbox.sh
B36=/home/rhcheck/.elan/toolchains/leanprover--lean4---v4.36.0/bin
CH=$R/challenge.ndjson; SOL=$R/solution.ndjson
export SB_RO="$R /home/rhcheck/fast $W/challenge"   # checkers may read the exports; they still write only sbtmp (and proj/.lake via RW)
bash $W/gold/run/06b-export.sh || true   # export retry (more RAM, uncompressed oleans)

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
if grep -q "BUILD+EXPORT DONE" $R/build-phase.txt; then
CL=$T/con-leche/.lake/build/bin/con-leche
run con-leche-compare 6 -- $CL --jobs=22 --progress=10% --compare $CH $SOL
run con-leche 6 -- $CL --jobs=22 --verified $SOL
run con-ron 8 -- $T/con-ron/target/release/con-ron --jobs=16 $SOL
run pestka 12 -- $T/pestka/.build/target/release/main $SOL 16
cat > $W/sbtmp/nanoclo.json <<EOF
{"export_file_path": "$SOL", "use_stdin": false, "permitted_axioms": ["propext", "Classical.choice", "Quot.sound"],
 "unpermitted_axiom_hard_error": true, "num_threads": 16, "nat_extension": true, "string_extension": true,
 "print_success_message": true}
EOF
run nanoclo 12 -- $T/nanoclo/target/release/nanoclo $W/sbtmp/nanoclo.json

# Comparator (Lean 4.36): statement match, axiom whitelist, Lean kernel + paranoid kernel + nanoda.
mkdir -p $W/judge && cp $W/gold/comparator.json $W/judge/ && cd $W/judge
echo "== comparator $(date -Is)" | tee -a $R/build-phase.txt
/usr/bin/time -v -o $R/judge-comparator.time timeout 96h env PATH=$B36:/usr/bin:/bin \
  $B36/lake comparator --config comparator.json --challenge-from-export $CH --solution-from-export $SOL \
  > $R/judge-comparator.log 2>&1
rc=$?; cat $R/judge-comparator.time >> $R/judge-comparator.log; record comparator $rc $R/judge-comparator.log
for k in lean lean-paranoid nanoda; do
  record $k $rc $R/judge-comparator.log "run inside lake comparator, which exits 0 only if every listed kernel accepts (exit $rc)"
done
echo "   comparator exit $rc" | tee -a $R/build-phase.txt

else
  echo "EXPORT-BASED CHECKS SKIPPED: export did not finish" | tee -a $R/build-phase.txt
fi

# lean4lean (built for v4.33): every module on the project's search path, from the oleans.
cd $W/proj && RW=$W/proj/.lake run lean4lean 48 -- lake env $T/lean4lean/.lake/build/bin/lean4lean

# Secondary: per-module leanchecker replay (v4.33), then integrity.
cd $W/proj && RW=$W/proj/.lake run replay 48 -- bash -c 'rc=0; for p in $(ls .lake/build/lib/lean | sed -n "s/\.olean$//p; /\./!p" | sort -u); do lake env leanchecker $p || rc=$?; done; echo "replay exit $rc"; exit $rc'
( cd $W/proj && sha256sum -c --quiet $R/source-manifest.sha256sums ) > $R/judge-integrity.log 2>&1; irc=$?
python3 -I - $R <<'PY'
import json, os, sys
R = sys.argv[1]
def j(i):
    p = f"{R}/judge-{i}.json"
    return json.load(open(p)) if os.path.exists(p) else {}
ax, rp = j("axiomcheck"), j("replay")
integ = open(f"{R}/judge-integrity.log").read().strip()
ok = ax.get("exit") == 0 and rp.get("exit") == 0 and not integ
parts = [f"axiomcheck {ax.get('status','not run')}", f"leanchecker replay {rp.get('status','not run')}",
         "sources unchanged" if not integ else "SOURCE CHANGE: see judge-integrity.log"]
json.dump({"id": "secondary", "status": "✅ Passed" if ok else "❌ See evidence", "evidence": "; ".join(parts)},
          open(f"{R}/judge-secondary.json", "w"))
PY
echo "JUDGE DONE $(date -Is)" | tee -a $R/build-phase.txt
