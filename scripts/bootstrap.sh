#!/usr/bin/env bash
# From a fresh clone to a full result. Safe to re-run: every step skips or resumes finished work.
#
#   scripts/bootstrap.sh                # install elan, setup, build + audit
#   scripts/bootstrap.sh --with-replay  # ...then the leanchecker --fresh kernel replay
#
# Long-running: start it in the background, e.g.
#   nohup scripts/bootstrap.sh --with-replay > results/bootstrap.log 2>&1 &
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p results

missing=()
for c in git curl tar gzip sha256sum python3; do
  command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "Missing: ${missing[*]}" >&2
  echo "On Debian/Ubuntu: sudo apt-get install -y git curl tar gzip coreutils python3" >&2
  exit 1
fi

export PATH="$HOME/.elan/bin:$PATH"
if ! command -v elan >/dev/null 2>&1; then
  echo "Installing elan (Lean toolchain manager) into ~/.elan"
  tmp="$(mktemp -d)"
  curl -fsSL https://elan.lean-lang.org/elan-init.sh -o "$tmp/elan-init.sh"
  sh "$tmp/elan-init.sh" -y --default-toolchain none
  rm -rf "$tmp"
fi
elan --version
( cd "$ROOT/lean" 2>/dev/null && lean --version ) || true   # fetches the pinned toolchain once lean/ exists

scripts/setup.sh
( cd lean && lean --version )
scripts/check.sh
if [ "${1:-}" = "--with-replay" ]; then
  scripts/replay.sh --fresh
fi
