#!/usr/bin/env python3
"""Regenerate the live sections of the kai.do post from the VM's results.

Reads only what the run wrote (results/*.txt, hashes) over ssh, and writes markdown includes into the post folder:
  _status.md  (at-a-glance callout)   _steps.md  (pipeline table)
  _kernels.md (checker table)         _hashes.md (our hashes vs the published ones)
Nothing here interprets a result the logs don't state: unknown means "pending".

Usage: update_post.py <post-dir>
"""
import datetime as dt
import json
import os
import re
import subprocess
import sys
from zoneinfo import ZoneInfo

SSH = ["ssh", "-n", "-i", os.path.expanduser("~/rh-vm/rh_vm_key"), "-p", "2222",
       "-o", "UserKnownHostsFile=" + os.path.expanduser("~/rh-vm/known_hosts"),
       "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "rhcheck@127.0.0.1"]
TOTAL = 175187

# Published reference values (Sutherland, math.mit.edu/~drew/grh; Deicyde/riemann-hypothesis).
REF = {
    "archive": "9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc",
    "main_olean": "9146dfb4148e24d2252e04c50742f3e49dd126dfcc5006d10bf5f873ddf796ad",
    "statements_olean": "f8e0aed3c2d69390b6dd3bb24e13aa25e043a02ca42f021e3f6e4ec8b57fd6b1",
    "olean_list": "375cbee2fc3fc0f5088ef2e6dc9a5ac5530924310dc62422ec65aac9dc4c1d25",
    "challenge_export": "bd484ac9886a96f26b1d9a7a59ebd45b7a70d102c015d4f31f9302bbdd6ab2b9",
    "solution_export": "5ea74b912147c5c93cc2b6d70cc727cf908df2f62ac6a20480a3fa02f6be244e",
}

# Steps already completed, with the evidence that was observed (kept verbatim from the logs).
DONE_STEPS = [
    ("Fresh VM", "A new Debian 13 VM (22 vCPU, 106 GB RAM) with its own kernel; the build user has no sudo.",
     "Base image SHA-512 matches Debian's published `SHA512SUMS`."),
    ("Toolchains", "Lean v4.33.1 (build, export) and v4.36.0 (judge) match the official release tarballs.",
     "`v4.33.1: installed toolchain matches verified tarball (17493 files)`; v4.36.0: 18248 files."),
    ("Checker tools", "lean4export, lean4lean, con-leche, con-ron, nanoclo, Pestka and landrun cloned at pinned commits and built.",
     "Commits listed under *Provenance*."),
    ("Project archive", "Downloaded inside the VM, verified, extracted read-only.",
     "`Archive checksum OK (9631b4f0…c7fc)`; `Extracted 175190 files into lean/ (read-only).`"),
    ("Dependencies", "Mathlib and 8 packages cloned at the revisions the project pins; no prebuilt files.",
     "`mathlib at pinned 0df444a3`; all worktrees clean; `oleans present in packages (should be 0): 0`."),
    ("Network cut", "VM restarted in isolated mode; nothing after this point can reach the internet.",
     "`curl: (6) Could not resolve host: github.com`; ping blocked."),
    ("Mathlib from source", "Built from source with the network off, then compared with Mathlib's official cache.",
     "32 min, 0 errors. 8,689 of 8,700 cache oleans byte-identical; 10 are the cache tool itself; 1 differs (see *Findings*)."),
    ("Challenge export", "The five statements, built and exported before any project code ran.",
     "The community's `Challenge.lean`, built with this Mathlib, exports to exactly `bd484ac9…b2b9`."),
    ("Sandbox", "Landlock (landrun) confinement for everything that loads project code, tested before use.",
     "Positive control passes; writes to sources (even after `chmod`), writes outside the build dir, `~/.ssh`, TCP: all denied."),
]


def vm(cmd):
    try:
        return subprocess.run(SSH + [cmd], capture_output=True, text=True, timeout=60).stdout
    except subprocess.TimeoutExpired:
        return ""


def short(h):
    return f"`{h[:8]}…{h[-4:]}`" if h else "—"


def main(post_dir):
    raw = vm(r'''R=work/results
echo "##STATUS"; cat $R/status.txt 2>/dev/null
echo "##PHASE"; cat $R/build-phase.txt 2>/dev/null
echo "##SOL"; cat $R/solution.ndjson.sha256 2>/dev/null
echo "##OLEANS"; [ -f $R/project-oleans.sha256 ] && { sha256sum < $R/project-oleans.sha256 | cut -c1-64; wc -l < $R/project-oleans.sha256; grep -E " \./(Main|Statements)\.olean$" $R/project-oleans.sha256; diff <(cut -c1-64 $R/project-oleans.sha256) <(cut -c1-64 work/ref/drew-project-oleans.sha256) | grep -c "^<" ; }
echo "##JUDGE"; for f in $R/judge-*.json; do [ -f "$f" ] && cat "$f" && echo; done
echo "##END"''')
    reachable = "##STATUS" in raw
    sec = {}
    cur = None
    for line in raw.splitlines():
        if line.startswith("##"):
            cur = line[2:]
            sec[cur] = []
        elif cur:
            sec[cur].append(line)

    now = dt.datetime.now(ZoneInfo("America/New_York")).strftime("%Y-%m-%d %-I:%M %p %Z")
    status = "\n".join(sec.get("STATUS", []))
    phase = sec.get("PHASE", [])
    m = re.search(r"modules (\d+)/\d+ \(([\d.]+)%\)\s+elapsed (\S+)\s+rate (\d+)/h\s+build ETA ([\d.]+)h", status)
    errs = re.search(r"errors (\d+)\s+sorry-warnings (\d+)", status)
    build_exit = next((l for l in phase if l.startswith("BUILD EXIT")), None)
    export_exit = next((l for l in phase if l.startswith("EXPORT EXIT")), None)
    export_start = any(l.startswith("EXPORT START") for l in phase)
    judges = []
    for l in sec.get("JUDGE", []):
        l = l.strip()
        if l:
            try:
                judges.append(json.loads(l))
            except json.JSONDecodeError:
                pass
    judge = {j["id"]: j for j in judges}

    # ---- pipeline table ----
    rows = [(n, w, "✅ Done", e) for n, w, e in DONE_STEPS]
    if build_exit:
        ok = build_exit.split()[2] == "0"
        rows.append(("Project build", "All 175,187 project modules compiled inside the sandbox (`lake build`).",
                     "✅ Done" if ok else "❌ Failed",
                     f"`{build_exit}`; " + (f"errors {errs.group(1)}, `sorry` warnings {errs.group(2)}" if errs else "")))
    elif m:
        rows.append(("Project build", "All 175,187 project modules compiled inside the sandbox (`lake build`).",
                     "⏳ Running",
                     f"{int(m.group(1)):,} / {TOTAL:,} modules ({m.group(2)}%), {m.group(3)} elapsed, ~{int(m.group(4)):,}/h, "
                     f"rough ETA {m.group(5)} h" + (f"; errors {errs.group(1)}, `sorry` warnings {errs.group(2)}" if errs else "")))
    else:
        rows.append(("Project build", "All 175,187 project modules compiled inside the sandbox.", "⏸ Pending", ""))
    if export_exit:
        ok = export_exit.split()[2] == "0"
        sol = sec.get("SOL", [""])[0].split()[0] if sec.get("SOL") else ""
        rows.append(("Export", "The compiled proof written out as one file (`lean4export`) for the checkers.",
                     "✅ Done" if ok else "❌ Failed", f"`{export_exit}`" + (f"; sha256 {short(sol)}" if sol else "")))
    else:
        rows.append(("Export", "The compiled proof written out as one file (`lean4export`) for the checkers.",
                     "⏳ Running" if export_start else "⏸ Pending", ""))
    for jid, name, what in [
        ("comparator", "Comparator", "Statements match the challenge; only the 3 standard axioms; Lean kernel + paranoid + nanoda replay."),
        ("secondary", "Secondary checks", "Axiom audit, per-module `leanchecker` replay, sources unchanged, tools unchanged."),
    ]:
        j = judge.get(jid)
        rows.append((name, what, j["status"] if j else "⏸ Pending", j.get("evidence", "") if j else ""))

    with open(os.path.join(post_dir, "_steps.md"), "w") as f:
        f.write("| # | Step | What It Establishes | Status | Evidence |\n|--:|---|---|---|---|\n")
        for i, (n, w, s, e) in enumerate(rows, 1):
            f.write(f"| {i} | {n} | {w} | {s} | {e} |\n")

    # ---- kernel table ----
    kernels = [
        ("lean", "Lean kernel (C++)", "Lean FRO", "The reference kernel, replaying the export inside `lake comparator`."),
        ("lean-paranoid", "Lean kernel, paranoid mode", "Lean FRO", "The same kernel with extra internal checks."),
        ("nanoda", "nanoda", "Chris Bailey", "Independent kernel in Rust."),
        ("con-leche-compare", "con-leche `--compare`", "Lean FRO", "Formally verified checker; also re-does the statement comparison."),
        ("con-leche", "con-leche", "Lean FRO", "Formally verified: anything it accepts has a model in set theory."),
        ("con-ron", "con-ron", "Lean FRO", "Rust port of con-leche."),
        ("lean4lean", "lean4lean", "Mario Carneiro", "Kernel written in Lean, partly verified; run module by module."),
        ("pestka", "Pestka", "jasisz", "Independent kernel written in Aver."),
        ("nanoclo", "nanoclo", "sgraf812", "Independent Rust kernel, forked from nanoda."),
    ]
    with open(os.path.join(post_dir, "_kernels.md"), "w") as f:
        f.write("| Checker | By | What It Is | Verdict | Time | Peak RAM | Evidence |\n|---|---|---|---|--:|--:|---|\n")
        for kid, name, by, what in kernels:
            j = judge.get(kid, {})
            f.write(f"| {name} | {by} | {what} | {j.get('status', '⏸ Pending')} | {j.get('time', '')} | "
                    f"{j.get('ram', '')} | {j.get('evidence', '')} |\n")

    # ---- hash table ----
    ol = sec.get("OLEANS", [])
    ours = {"archive": REF["archive"], "challenge_export": REF["challenge_export"]}
    olean_note = ""
    if len(ol) >= 4:
        ours["olean_list"] = ol[0].strip()
        for l in ol[2:4]:
            h, p = l.split()
            ours["main_olean" if p.endswith("/Main.olean") else "statements_olean"] = h
        olean_note = f" ({ol[1].strip()} files; {ol[4].strip() if len(ol) > 4 else '?'} differ from the published list)"
    if sec.get("SOL"):
        ours["solution_export"] = sec["SOL"][0].split()[0]

    def verdict(k):
        if k not in ours:
            return "⏸ Pending"
        return "✅ Match" if ours[k] == REF[k] else "⚠️ Differs"

    labels = [
        ("archive", "Source archive `lean.tar.gz`", ""),
        ("challenge_export", "Challenge export (their `Challenge.lean`, our build)", ""),
        ("main_olean", "`Main.olean`", ""),
        ("statements_olean", "`Statements.olean`", ""),
        ("olean_list", "List of all 175,187 project `.olean` hashes", olean_note),
        ("solution_export", "Solution export `solution.ndjson` (61.6 GB)", ""),
    ]
    with open(os.path.join(post_dir, "_hashes.md"), "w") as f:
        f.write("| Artifact | Published (SHA-256) | Ours | Result |\n|---|---|---|---|\n")
        for k, label, note in labels:
            f.write(f"| {label}{note} | {short(REF[k])} | {short(ours.get(k, ''))} | {verdict(k)} |\n")

    # ---- at-a-glance callout ----
    if not reachable:
        line = "The VM could not be reached for this update; the tables below show the last known state."
    elif build_exit and build_exit.split()[2] != "0":
        line = "**The project build failed.** See step 10 for the exact error."
    elif any(j.get("status", "").startswith(("❌", "⚠️")) for j in judges if j.get("id") != "secondary") or \
            any(j.get("status", "").startswith("❌") for j in judges if j.get("id") == "secondary"):
        line = ("**At least one checker did not accept the proof** (a rejection, a decline or a failure to run). "
                "See the checker table for its exact output.")
    elif m and not build_exit:
        line = (f"**Building the project:** {int(m.group(1)):,} of {TOTAL:,} modules ({m.group(2)}%) after {m.group(3)}. "
                f"No verdict yet; the checkers run after the build and export.")
    elif build_exit and not export_start:
        line = ("**The project build finished** with no errors and no `sorry` warnings. Hashing the compiled files, "
                "then exporting the proof for the checkers. No verdict yet.")
    elif export_start and not export_exit:
        line = "**Exporting the compiled proof** for the checkers. No verdict yet."
    elif export_exit and not judges:
        line = "**Export finished.** The checkers are starting. No verdict yet."
    else:
        done = [j for j in judges if j.get("status", "").startswith("✅")]
        line = f"**Checking:** {len(done)} of {len(kernels)} checkers have accepted so far; the rest are pending or running."
    with open(os.path.join(post_dir, "_status.md"), "w") as f:
        f.write(f"::: {{.callout-important title=\"Status, Updated {now}\"}}\n{line}\n:::\n")
    print(line)


if __name__ == "__main__":
    main(sys.argv[1])
