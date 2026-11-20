# riemann-hypothesis-lean-check

Builds a third-party Lean 4 project that claims to prove the Riemann Hypothesis, without
modifying it. Then it checks whether the main theorem really proves Mathlib's
`RiemannHypothesis` from Lean's standard axioms alone.

## Run it (Linux, or Git Bash on Windows)

```bash
sudo apt-get install -y git curl tar gzip coreutils python3 time   # Debian/Ubuntu
mkdir -p results
nohup scripts/bootstrap.sh --with-replay > results/bootstrap.log 2>&1 &
```

This installs elan (no sudo), downloads and verifies the project, builds it, audits the axioms
and replays every declaration through Lean's kernel. Expect hours to days; re-running resumes.

| Command | Time | Purpose |
|---|---|---|
| `scripts/setup.sh` | minutes | download 14 parts, verify SHA-256, extract read-only into `lean/` |
| `scripts/check.sh --preflight` | minutes | every check except the build |
| `scripts/check.sh` | hours–days | build + axiom audit + integrity checks |
| `scripts/replay.sh` | hours–a day | `leanchecker --fresh Main` kernel replay |

Results are written to `results/<timestamp>/SUMMARY.txt`. See [CLAUDE.md](CLAUDE.md) for what each
check establishes and how to read the results.

## Layout

| Path | Committed | Purpose |
|---|---|---|
| `ARCHIVE.sha256` | yes | pinned checksum of the reassembled archive |
| `scripts/` | yes | bootstrap, setup, check, replay |
| `tools/axiomcheck/` | yes | standalone axiom auditor (loads oleans without running project code) |
| `checks/Axioms.lean` | yes | `#print axioms` cross-check |
| `downloads/`, `lean/`, `.check/`, `results/` | no | downloaded parts, extracted project, hash manifests, run outputs |
