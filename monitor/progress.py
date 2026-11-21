#!/usr/bin/env python3
"""Read-only progress report for a bootstrap/check/replay run.

    python3 -I monitor/progress.py            # one report
    python3 -I monitor/progress.py --watch 60 # refresh every 60 s

Reads results/bootstrap.log, results/<LATEST>/build.log and results/replay-*/replay.log, plus
`ps` and /proc/meminfo. It never writes outside results/.monitor-state.json (rate samples) and
never touches scripts/, tools/, checks/ or lean/. Log text comes from the untrusted project, so
control characters are stripped before printing.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
STATE = os.path.join(RESULTS, ".monitor-state.json")
RATE_WINDOW = 30 * 60   # seconds of samples used for the recent rate
STALL_AFTER = 20 * 60   # log unchanged this long while running -> warn

COUNTER = re.compile(r"\[(\d+)/(\d+)\]\s*(\S+)?\s*(\S+)?")
STAMP = re.compile(r"(\d{8}-\d{6})$")
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\x1b]|\x9b")


def clean(s, n=100):
    s = CTRL.sub("", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def dur(sec):
    if sec is None:
        return "?"
    sec = int(sec)
    d, sec = divmod(sec, 86400)
    h, sec = divmod(sec, 3600)
    m, _ = divmod(sec, 60)
    return (f"{d}d " if d else "") + (f"{h}h " if d or h else "") + f"{m}m"


def stamp_time(name):
    m = STAMP.search(name or "")
    return time.mktime(time.strptime(m.group(1), "%Y%m%d-%H%M%S")) if m else None


def read_tail(path, nbytes=256 * 1024):
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - nbytes))
            return f.read().decode("utf-8", "replace").splitlines()
    except OSError:
        return []


def scan_full(path, state, key):
    """Incrementally count sorry warnings / errors in a growing log (offset kept in state)."""
    st = state.setdefault(key, {"path": path, "off": 0, "sorry": 0, "errors": 0, "lines": 0})
    if st.get("path") != path:
        st.update(path=path, off=0, sorry=0, errors=0, lines=0)
    try:
        size = os.path.getsize(path)
        if size < st["off"]:
            st.update(off=0, sorry=0, errors=0, lines=0)
        with open(path, "rb") as f:
            f.seek(st["off"])
            chunk = f.read()
    except OSError:
        return st
    cut = chunk.rfind(b"\n") + 1          # only count complete lines
    text = chunk[:cut].decode("utf-8", "replace")
    st["off"] += cut
    st["lines"] += text.count("\n")
    st["sorry"] += text.count("declaration uses 'sorry'")
    st["errors"] += sum(1 for l in text.splitlines() if l.lstrip().startswith(("error", "✖")))
    return st


def procs():
    try:
        out = subprocess.run(["ps", "-eo", "pid=,etimes=,rss=,args="], capture_output=True,
                             text=True, timeout=10).stdout
    except Exception:
        return []
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 3)
        if len(parts) == 4:
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3]))
    return rows


def meminfo():
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0]) // 1024 // 1024
    except OSError:
        pass
    return info.get("MemTotal"), info.get("MemAvailable")


def latest_replay():
    try:
        dirs = sorted(d for d in os.listdir(RESULTS) if d.startswith("replay-"))
    except OSError:
        return None
    return os.path.join(RESULTS, dirs[-1]) if dirs else None


def report(state):
    now = time.time()
    out = []
    ps = procs()
    def running(pat):
        return [p for p in ps if pat in p[3] and "progress.py" not in p[3]]

    boot = running("bootstrap.sh")
    check = running("check.sh")
    lakeb = [p for p in running("lake") if " build" in p[3]]
    lean_jobs = [p for p in ps if re.search(r"(^|/)lean(\s|$)", p[3].split()[0] if p[3] else "")]
    checker = running("leanchecker")

    out.append(f"Progress report  {time.strftime('%a %d %b %H:%M:%S')}")
    if boot:
        out.append(f"bootstrap.sh running for {dur(boot[0][1])}")
    elif check:
        out.append(f"check.sh running for {dur(check[0][1])}")
    else:
        out.append("No bootstrap.sh / check.sh process running.")

    # current stage from bootstrap.log
    boot_log = os.path.join(RESULTS, "bootstrap.log")
    stages = [l for l in read_tail(boot_log, 2 * 1024 * 1024) if l.startswith("=== ")]
    if stages:
        out.append(f"Stage: {clean(stages[-1][4:])}")

    # ---- build
    latest = None
    try:
        with open(os.path.join(RESULTS, "LATEST")) as f:
            latest = f.read().strip()
    except OSError:
        pass
    run_dir = os.path.join(RESULTS, latest) if latest else None
    build_log = os.path.join(run_dir, "build.log") if run_dir else None
    if build_log and os.path.exists(build_log):
        tail = read_tail(build_log)
        last = None
        for l in reversed(tail):
            m = COUNTER.search(l)
            if m:
                last = m
                break
        scan = scan_full(build_log, state, "build")
        out.append("")
        if last:
            done, total = int(last.group(1)), int(last.group(2))
            samples = state.setdefault("samples", {}).setdefault(build_log, [])
            if not samples or samples[-1][1] != done or now - samples[-1][0] > 300:
                samples.append([now, done, total])
            samples[:] = [s for s in samples if now - s[0] <= 6 * 3600]
            start = stamp_time(latest)
            out.append(f"Build: {done:,} / {total:,} jobs ({100 * done / total:.1f}%)")
            out.append(f"  Elapsed since check.sh start: {dur(now - start) if start else '?'}")
            recent = [s for s in samples if now - s[0] <= RATE_WINDOW]
            rate = None
            if len(recent) >= 2 and recent[-1][0] - recent[0][0] >= 120:
                rate = (recent[-1][1] - recent[0][1]) / (recent[-1][0] - recent[0][0])
                basis = f"last {dur(recent[-1][0] - recent[0][0])}"
            elif start and now > start:
                rate = done / (now - start)
                basis = "average since start (monitor has no history yet)"
            if rate and rate > 0:
                eta = (total - done) / rate
                out.append(f"  Rate: {rate * 60:,.1f} jobs/min ({basis})")
                out.append(f"  ETA: ~{dur(eta)}  (finish ~ {time.strftime('%a %d %b %H:%M', time.localtime(now + eta))})")
            else:
                out.append("  Rate: not enough data yet")
            what = " ".join(x for x in (last.group(3), last.group(4)) if x)
            out.append(f"  Last: {clean(what)}")
        else:
            out.append("Build: started, no [done/total] counter yet")
        out.append(f"  'sorry' warnings: {scan['sorry']}   error lines: {scan['errors']}")
        age = now - os.path.getmtime(build_log)
        if (lakeb or check) and age > STALL_AFTER:
            out.append(f"  WARNING: build.log unchanged for {dur(age)} while running")
        out.append(f"  Lean processes: {len(lean_jobs)}")

    # ---- summary verdicts
    if run_dir:
        try:
            with open(os.path.join(run_dir, "SUMMARY.txt")) as f:
                lines = [clean(l, 140) for l in f if l.startswith(("PASS", "FAIL", "NOTE", "RESULT"))]
            if lines:
                out.append("")
                out.append(f"SUMMARY ({latest}):")
                out += [f"  {l}" for l in lines[-12:]]
        except OSError:
            pass

    # ---- replay
    rdir = latest_replay()
    if rdir:
        rlog = os.path.join(rdir, "replay.log")
        scan = scan_full(rlog, state, "replay")
        start = stamp_time(os.path.basename(rdir))
        out.append("")
        out.append(f"Replay ({os.path.basename(rdir)}): " + ("running" if checker else "not running"))
        out.append(f"  Elapsed: {dur(now - start) if start else '?'}   log lines: {scan['lines']:,}")
        if checker:
            out.append(f"  leanchecker RSS: {checker[0][2] // 1024 // 1024} GB")
        rt = [l for l in read_tail(rlog, 16 * 1024) if l.strip()]
        if rt:
            out.append(f"  Last: {clean(rt[-1])}")
        try:
            with open(os.path.join(rdir, "SUMMARY.txt")) as f:
                res = [clean(l, 140) for l in f if l.startswith(("RESULT", "FAIL"))]
            out += [f"  {l}" for l in res]
        except OSError:
            pass
        out.append("  (no done/total counter in replay output, so no percent or ETA)")

    # ---- memory / health
    total, avail = meminfo()
    if total:
        out.append("")
        out.append(f"Memory: {avail} GB available of {total} GB")
        if avail is not None and avail < 0.1 * total:
            out.append("  WARNING: under 10% free and there is no swap; OOM risk")
    if not (boot or check or checker):
        tail = [l for l in read_tail(boot_log, 8 * 1024) if l.strip()]
        if tail and not any("RESULT" in l for l in tail[-20:]):
            out.append("")
            out.append("NOTE: nothing is running and bootstrap.log has no final RESULT line.")
            out.append(f"  Last log line: {clean(tail[-1])}")
            out.append("  If it was killed (OOM, reboot), re-run the same bootstrap command to resume.")
    return "\n".join(out)


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(state):
    if not os.path.isdir(RESULTS):
        return
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, STATE)


def main():
    args = sys.argv[1:]
    interval = None
    if args[:1] == ["--watch"]:
        interval = int(args[1]) if len(args) > 1 else 60
    while True:
        state = load_state()
        text = report(state)
        save_state(state)
        if interval:
            sys.stdout.write("\x1b[2J\x1b[H")
        print(text, flush=True)
        if not interval:
            return
        time.sleep(interval)


if __name__ == "__main__":
    main()
