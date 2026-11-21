#!/usr/bin/env python3
"""Read-only event stream for a running check: prints one line per noteworthy event, then sleeps.

    python3 -I monitor/events.py [poll_seconds]   # default 30; runs until killed

Meant to be the command of a background watcher that turns each stdout line into a chat
notification. Events: new PASS/FAIL/NOTE/RESULT lines in any SUMMARY.txt, 'sorry' warnings and
error lines in build.log, build milestones (every 25%), a run process starting or ending,
the build log stalling, and low memory. State lives in results/.events-state.json so a restarted
watcher does not repeat old events. Log text is untrusted; control characters are stripped.
"""
import json
import os
import re
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results")
STATE = os.path.join(RESULTS, ".events-state.json")
STALL_AFTER = 20 * 60
COUNTER = re.compile(rb"\[(\d+)/(\d+)\]")
CTRL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f\x1b]|\x9b")


def clean(s, n=160):
    s = CTRL.sub("", s).strip()
    return s if len(s) <= n else s[: n - 1] + "…"


def emit(msg):
    print(clean(msg, 300), flush=True)


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save(st):
    if os.path.isdir(RESULTS):
        tmp = STATE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, STATE)


def read_new(path, st):
    """Return complete new lines (bytes) appended to path since the last call."""
    offs = st.setdefault("offsets", {})
    off = offs.get(path, 0)
    try:
        size = os.path.getsize(path)
        if size < off:
            off = 0
        with open(path, "rb") as f:
            f.seek(off)
            chunk = f.read(64 * 1024 * 1024)
    except OSError:
        return []
    cut = chunk.rfind(b"\n") + 1
    offs[path] = off + cut
    return chunk[:cut].splitlines()


def running():
    try:
        out = subprocess.run(["ps", "-eo", "args="], capture_output=True, text=True,
                             timeout=10).stdout.splitlines()
    except Exception:
        return None
    names = []
    for name in ("bootstrap.sh", "check.sh", "replay.sh", "leanchecker"):
        if any(name in a and "events.py" not in a for a in out):
            names.append(name)
    return names


def mem_avail_frac():
    info = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                info[k] = int(v.split()[0])
        return info["MemAvailable"] / info["MemTotal"]
    except (OSError, KeyError, ValueError):
        return None


def poll(st):
    now = time.time()
    if not os.path.isdir(RESULTS):
        return

    # SUMMARY lines from every run dir (check runs and replay runs)
    for d in sorted(os.listdir(RESULTS)):
        p = os.path.join(RESULTS, d, "SUMMARY.txt")
        if os.path.isfile(p):
            for raw in read_new(p, st):
                line = raw.decode("utf-8", "replace")
                if line.startswith(("PASS", "FAIL", "NOTE", "RESULT")):
                    emit(f"[{d}] {line}")

    # build.log of the latest check run
    try:
        with open(os.path.join(RESULTS, "LATEST")) as f:
            latest = f.read().strip()
    except OSError:
        latest = None
    if latest:
        bl = os.path.join(RESULTS, latest, "build.log")
        if os.path.isfile(bl):
            sorry = errors = 0
            first_err = []
            last = None
            for raw in read_new(bl, st):
                if b"declaration uses 'sorry'" in raw:
                    sorry += 1
                s = raw.lstrip()
                if s.startswith((b"error", "✖".encode())):
                    errors += 1
                    if len(first_err) < 3:
                        first_err.append(raw.decode("utf-8", "replace"))
                m = COUNTER.search(raw)
                if m:
                    last = (int(m.group(1)), int(m.group(2)))
            b = st.setdefault("build", {"sorry": 0, "errors": 0, "milestone": 0, "run": latest})
            if b.get("run") != latest:
                b.update(sorry=0, errors=0, milestone=0, run=latest)
            if sorry:
                b["sorry"] += sorry
                emit(f"BUILD: {sorry} new 'sorry' warning(s), {b['sorry']} total")
            if errors:
                b["errors"] += errors
                emit(f"BUILD: {errors} new error line(s), {b['errors']} total. First: "
                     + " | ".join(clean(e, 120) for e in first_err))
            if last and last[1]:
                pct = 100 * last[0] // last[1]
                ms = pct // 25 * 25
                if ms > b["milestone"]:
                    b["milestone"] = ms
                    emit(f"BUILD: reached {ms}% ({last[0]:,}/{last[1]:,})")
            age = now - os.path.getmtime(bl)
            procs = running() or []
            if "check.sh" in procs and age > STALL_AFTER and not b.get("stall_warned"):
                b["stall_warned"] = True
                emit(f"BUILD: build.log unchanged for {int(age // 60)} min while check.sh runs")
            elif age < STALL_AFTER:
                b["stall_warned"] = False

    # processes starting / ending
    procs = running()
    if procs is not None:
        prev = set(st.get("procs", []))
        cur = set(procs)
        for p in sorted(cur - prev):
            emit(f"PROCESS: {p} started")
        for p in sorted(prev - cur):
            emit(f"PROCESS: {p} ended")
        st["procs"] = sorted(cur)
        if prev and not cur:
            emit("PROCESS: no run process left; check the RESULT lines above (none = killed?)")

    frac = mem_avail_frac()
    if frac is not None:
        low = frac < 0.10
        if low and not st.get("mem_low"):
            emit(f"MEMORY: only {frac:.0%} available, no swap; OOM risk")
        elif not low and st.get("mem_low"):
            emit(f"MEMORY: recovered to {frac:.0%} available")
        st["mem_low"] = low


def main():
    interval = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    while True:
        st = load()
        poll(st)
        save(st)
        time.sleep(interval)


if __name__ == "__main__":
    main()
