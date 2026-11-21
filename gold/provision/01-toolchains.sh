#!/usr/bin/env bash
# Run inside the VM as rhcheck. Installs elan and the two Lean toolchains, and verifies each toolchain against
# the official release tarball whose sha256 is pinned below (GitHub release asset digests, checked 2026-11-20).
set -euo pipefail
W=/home/rhcheck/work; mkdir -p $W/dl $W/results
declare -A SHA=(
  [v4.33.1]=890afd185370f85666025b883914ab4f4b339136f8c96167b69cfb62aecaf235
  [v4.36.0]=2b7ab1ed8b92d2e6abfaf41344823b510064dbc9c0260cac73eb496ab2dea6eb
)
if [ ! -x ~/.elan/bin/elan ]; then
  curl -fsSL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -o $W/dl/elan-init.sh
  sh $W/dl/elan-init.sh -y --default-toolchain none --no-modify-path >/dev/null
fi
export PATH=~/.elan/bin:$PATH
for v in v4.33.1 v4.36.0; do
  t=$W/dl/lean-${v#v}-linux.tar.zst
  [ -s $t ] || curl -fsSL -o $t https://github.com/leanprover/lean4/releases/download/$v/lean-${v#v}-linux.tar.zst
  echo "${SHA[$v]}  $t" | sha256sum -c -
  elan toolchain install leanprover/lean4:$v >/dev/null 2>&1 || true
  # Compare every file elan installed against the verified tarball.
  x=$W/dl/x-$v; rm -rf $x; mkdir -p $x; tar --zstd -xf $t -C $x
  ref=$(ls -d $x/*/)
  inst=~/.elan/toolchains/leanprover--lean4---$v
  ( cd "$ref" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > $W/dl/ref-$v.sums
  ( cd "$inst" && sha256sum -c --quiet $W/dl/ref-$v.sums ) && echo "$v: installed toolchain matches verified tarball ($(wc -l < $W/dl/ref-$v.sums) files)"
  rm -rf $x
done
