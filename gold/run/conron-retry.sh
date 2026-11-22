#!/usr/bin/env bash
# Retry con-ron with a 1 GiB default thread stack (RUST_MIN_STACK), set inside the sandbox by sh.
set -uo pipefail
W=/home/rhcheck/work; R=$W/results; T=$W/tools/src; . $W/gold/run/sandbox.sh
export SB_RO="$R /home/rhcheck/fast $W/challenge"
eval "$(sed -n "/^record() {/,/^}/p; /^run() {/,/^}/p" $W/gold/run/07b-export-checks.sh)"
run con-ron 8 -- /bin/sh -c "RUST_MIN_STACK=1073741824 exec $T/con-ron/target/release/con-ron --jobs=16 $R/solution.ndjson"
