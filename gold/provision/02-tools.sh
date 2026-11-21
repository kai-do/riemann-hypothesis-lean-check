#!/usr/bin/env bash
# Run inside the VM as rhcheck (network on). Clones every checker tool at a pinned commit and builds it.
set -euo pipefail
W=/home/rhcheck/work; T=$W/tools; mkdir -p $T/src $W/results
export PATH=~/.elan/bin:~/.cargo/bin:$PATH
pin() { # repo commit dir
  local d=$T/src/$3
  if [ ! -d $d/.git ]; then git clone -q https://github.com/$1 $d; fi
  git -C $d fetch -q origin $2 2>/dev/null || true
  git -C $d -c advice.detachedHead=false checkout -q $2
  git -C $d submodule update -q --init --recursive
  echo "$3 $1 $(git -C $d rev-parse HEAD)" >> $W/results/tool-commits.txt
}
: > $W/results/tool-commits.txt
pin leanprover/lean4export 15f6055e299ad5b89345e533cc2192f4cc00f659 lean4export
pin digama0/lean4lean      67f63b0c818920dfaed2ad07ccff187a6a8fe1e3 lean4lean
pin leanprover/con-leche   11d8ff13c86675e6ba4b6ca6cd1e4986154516d9 con-leche
pin leanprover/con-ron     de06320fcdce1ee999bb7a751725e5840d54c3fe con-ron
pin jasisz/pestka          48857ad7d1b15b80298a52ff525705c37cc0606a pestka
pin sgraf812/nanoclo       b8cefd0d0c76fe38c1db848e61816e1f23dca79e nanoclo
pin Zouuup/landrun         ec104f6edc1e14d7fec6d31146f1ec6f9c192c5a landrun

# Rust toolchain (rustup, stable), recorded.
if [ ! -x ~/.cargo/bin/cargo ]; then
  curl -fsSL https://sh.rustup.rs -o $W/dl/rustup-init.sh
  sh $W/dl/rustup-init.sh -y -q --profile minimal --no-modify-path
fi
{ rustc --version; cargo --version; go version; } >> $W/results/tool-commits.txt

echo "== lean4export (built with v4.33.1, to read v4.33.1 oleans)"
( cd $T/src/lean4export && lake +leanprover/lean4:v4.33.1 build 2>&1 | tail -n 2 )
echo "== lean4lean (built with v4.33.1)"
( cd $T/src/lean4lean && lake +leanprover/lean4:v4.33.1 build 2>&1 | tail -n 2 )
echo "== con-leche (v4.36.0, its own pin)"
( cd $T/src/con-leche && lake build con-leche 2>&1 | tail -n 2 )
echo "== con-ron"
( cd $T/src/con-ron && cargo build --release -q 2>&1 | tail -n 3 )
echo "== nanoclo"
( cd $T/src/nanoclo && cargo build --release -q 2>&1 | tail -n 3 )
echo "== pestka (Aver toolchain at the version it pins)"
( cd $T/src/pestka && cargo install -q aver-lang --version "$(cat .aver-version)" --locked 2>&1 | tail -n 3 )
echo "== landrun"
( cd $T/src/landrun && go build -o $T/bin/landrun ./cmd/landrun 2>&1 | tail -n 3 || go build -o $T/bin/landrun . 2>&1 | tail -n 3 )
echo "TOOLS DONE"
