# Run + monitor runbook (for the Claude session that starts the main run)

The user follows this run **only through Claude chat via Remote Control**. They have no terminal.
Every update must reach them as a chat message or a push notification.

The scripts in this folder only read. They write nothing except `results/.monitor-state.json` and
`results/.events-state.json`. They are not checker files: `check.sh` verifies `scripts/`, `checks/`,
`tools/` and `ARCHIVE.sha256` against git, not `monitor/`.

## Already done before handoff (verify, don't redo)

- elan installed in `~/.elan`; `/usr/bin/time` installed.
- `scripts/setup.sh` ran: archive downloaded, verified, extracted read-only into `lean/`.
- `scripts/check.sh --preflight` ran. See `results/$(cat results/LATEST)/SUMMARY.txt`, which must end
  with `RESULT: PREFLIGHT PASS`. If it doesn't, stop and tell the user. Don't start the build.

Quick re-verification (seconds):

```bash
~/.elan/bin/elan --version && test -x /usr/bin/time && echo ok
cat results/$(cat results/LATEST)/SUMMARY.txt | tail -3
git status --short   # scripts/ checks/ tools/ must show no changes
```

## 1. Start the run

Ask the user whether to include the kernel replay (recommended: a "genuine proof" verdict needs it;
it can also be run later with `scripts/replay.sh --fresh`). Then, from the repo root, run it with
`nohup` so it survives this chat session ending:

```bash
nohup scripts/bootstrap.sh --with-replay > results/bootstrap.log 2>&1 &   # or without --with-replay
```

Start it with Bash `run_in_background: true`. `bootstrap.sh` re-runs elan, setup and check from the
start. Every step skips or resumes finished work, so the preflight steps repeat quickly.

## 2. Arm the event watcher (immediately after starting)

Use the **Monitor** tool:

- command: `python3 -I monitor/events.py 30`
- description: `RH check events (bootstrap/build/replay)`
- timeout_ms: `1800000` (the maximum, 30 min)

Each stdout line is one event. When the monitor expires, **re-arm it with the same arguments**.
It saves its position, so old events don't repeat. The 30-minute re-arm also keeps this session's
1-hour prompt cache warm, so keep it running for the whole run.

On each event:
- `FAIL`, `RESULT:`, `BUILD: ... error`, `BUILD: ... 'sorry'`, `PROCESS: no run process left`,
  `MEMORY:`, or a stalled build log → tell the user in chat **and** send a **PushNotification**
  (under 200 chars, lead with what happened, for example `RH check: lake build FAILED, 3 errors in Development/X`).
- `BUILD: reached N%`, `PROCESS: ... started/ended`, `PASS` lines → mention in chat only, no push.
  Exception: push when the build finishes and when each `RESULT:` line appears.

## 3. Schedule the 2-hour reports

Use **CronCreate**, recurring, every 2 hours at an off-minute (for example `17 */2 * * *`). Prompt:

> Run `python3 -I monitor/progress.py` in the repo root and post a short progress update to the
> user (percent, elapsed, ETA, warnings, any new PASS/FAIL). Keep it to a few lines. No push
> notification unless something failed.

Tell the user: jobs are session-only (they stop if this session ends), recurring jobs expire after
30 days, and give the actual next run time from the tool's result.

## 4. When it finishes

Follow "Interpreting results" in `CLAUDE.md`. Quote the exact lines from `SUMMARY.txt`,
`axiomcheck.txt` and the replay `SUMMARY.txt`. Never predict or summarise results the logs don't show.
Then delete the cron job (CronDelete) and stop the watcher (TaskStop).

## If interrupted

- Session ended but the machine is up: the build continues (`nohup`). In a new session, check
  `ps -eo args | grep -E 'bootstrap|check.sh|lake|leanchecker'`, run `python3 -I monitor/progress.py`,
  then re-arm steps 2 and 3. Don't start a second bootstrap while one is running.
- Reboot / OOM kill (`PROCESS: no run process left` without a `RESULT:` line): re-run the same
  `nohup scripts/bootstrap.sh ...` command. It resumes. Tell the user first.

## Notes

- The ETA is rough. It uses the rate over the last 30 minutes, falling back to the average since start.
  Lake's job total can grow, so the percent may dip slightly.
- The replay prints no done/total counter, so its reports show elapsed time and activity only, no percent or ETA.
- The machine has 24 threads, about 125 GB RAM, **no swap** and about 600 GB of free disk. Lake runs one
  job per thread, so watch for `MEMORY:` events.
