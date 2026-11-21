#!/usr/bin/env bash
# Run inside the VM as rhcheck (network on). Fetches the project archive and its pinned dependencies, the
# official Mathlib cache (for comparison only), and the community's published reference files.
set -euo pipefail
W=/home/rhcheck/work; mkdir -p $W/results $W/ref
export PATH=~/.elan/bin:$PATH
ARCHIVE_SHA=9631b4f020199e580ba86178cb56c6e9b09f690c2369a80dc4334aa93f49c7fc   # typed in independently of the repo

# 1. Checker repo, from GitHub at the pinned commit (not copied from the host).
[ -d $W/checker/.git ] || git clone -q https://github.com/kai-do/riemann-hypothesis-lean-check $W/checker
git -C $W/checker -c advice.detachedHead=false checkout -q 2e5086633c5b59e68b3aaae9a446fdc666444858
grep -q "^$ARCHIVE_SHA " $W/checker/ARCHIVE.sha256 && echo "ARCHIVE.sha256 in clone matches the typed-in hash"

# 2. Download, verify and extract with the repo's own safety checks (setup.sh). The result is read-only.
( cd $W/checker && scripts/setup.sh )
echo "$ARCHIVE_SHA  $W/checker/.check/lean.tar.gz" | sha256sum -c -
cp -a $W/checker/.check/lean.sha256sums $W/results/source-manifest.sha256sums

# 3. Working copy for the build. Sources stay read-only; Lake writes only .lake/.
if [ ! -d $W/proj ]; then cp -a $W/checker/lean $W/proj; fi
( cd $W/proj && sha256sum -c --quiet $W/results/source-manifest.sha256sums ) && echo "proj copy matches manifest"

# 4. Dependencies as git sources at the manifest revisions. Lake reads the TOML lakefile, so no project code runs.
#    No `lake update`, no cache.
( cd $W/proj && lake env true )
for p in $W/proj/.lake/packages/*; do echo "$(basename $p) $(git -C $p rev-parse HEAD) $(git -C $p status --porcelain | wc -l)-dirty"; done | tee $W/results/packages.txt
test "$(git -C $W/proj/.lake/packages/mathlib rev-parse HEAD)" = 0df444a360eaa60ab8c11dca51a86af692955474 && echo "mathlib at pinned 0df444a3"
find $W/proj/.lake/packages -name '*.olean' | wc -l | sed 's/^/oleans present in packages (should be 0): /'

# 5. Official Mathlib cache in a separate tree, for the later comparison only.
if [ ! -d $W/mathlib-cache-ref/.git ]; then git clone -q https://github.com/leanprover-community/mathlib4 $W/mathlib-cache-ref; fi
git -C $W/mathlib-cache-ref -c advice.detachedHead=false checkout -q 0df444a360eaa60ab8c11dca51a86af692955474
( cd $W/mathlib-cache-ref && lake exe cache get 2>&1 | tail -n 2 )

# 6. Community reference files (for comparison only).
curl -fsSL -o $W/ref/drew-project-oleans.sha256 https://math.mit.edu/~drew/grh/project-oleans.sha256
curl -fsSL -o $W/ref/drew-SHA256SUMS https://math.mit.edu/~drew/grh/SHA256SUMS
curl -fsSL -o $W/ref/drew-comparator.json https://math.mit.edu/~drew/grh/comparator.json
D=https://raw.githubusercontent.com/Deicyde/riemann-hypothesis/e50d09817ad81469f737e8f637561e6ccf86c670
for f in src/Challenge.lean export-targets.txt comparator.json; do curl -fsSL -o "$W/ref/deicyde-$(basename $f)" "$D/$f"; done
sha256sum $W/ref/* | tee $W/results/ref-files.sha256
echo "PROJECT DONE"
