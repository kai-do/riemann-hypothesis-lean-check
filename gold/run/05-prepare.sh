#!/usr/bin/env bash
# Inside the VM as rhcheck, network off. Reuse our from-source Mathlib build in the project tree (btrfs reflink
# copy, same revisions), then check the sandbox actually confines.
set -euo pipefail
W=/home/rhcheck/work; . $W/gold/run/sandbox.sh
for p in $W/challenge/.lake/packages/*; do
  n=$(basename $p); [ -d $p/.lake/build ] || { echo "skip $n (not built)"; continue; }
  test "$(git -C $p rev-parse HEAD)" = "$(git -C $W/proj/.lake/packages/$n rev-parse HEAD)"
  [ -d $W/proj/.lake/packages/$n/.lake/build ] || cp -a --reflink=always $p/.lake/build $W/proj/.lake/packages/$n/.lake/build 2>/dev/null || { mkdir -p $W/proj/.lake/packages/$n/.lake; cp -a --reflink=always $p/.lake/build $W/proj/.lake/packages/$n/.lake/; }
done
echo "dependency oleans in proj: $(find $W/proj/.lake/packages -path '*/.lake/build/*' -name '*.olean' | wc -l)"
echo "== positive control (must SUCCEED, else the sandbox isn't running at all)"
sb $W/proj/.lake -- /bin/sh -c "touch $W/proj/.lake/sb-ok && rm $W/proj/.lake/sb-ok && cat $W/proj/src/Main.lean >/dev/null" || { echo "FAIL: positive control"; exit 1; }
echo "ok: positive control"
echo "== sandbox tests (each must be DENIED)"
sb $W/proj/.lake -- /bin/sh -c "touch $W/results/sb-test" 2>/dev/null && echo "FAIL: wrote to results" || echo "ok: write to results denied"
sb $W/proj/.lake -- /bin/sh -c "chmod u+w $W/proj/src/Main.lean; echo x >> $W/proj/src/Main.lean" 2>/dev/null && echo "FAIL: wrote project source" || echo "ok: write to source contents denied (even after chmod)"
sb $W/proj/.lake -- /bin/sh -c "echo x > $W/proj/src/NewFile.lean" 2>/dev/null && echo "FAIL: created file in sources" || echo "ok: creating files in sources denied"
chmod a-w $W/proj/src/Main.lean
(cd $W/proj && sha256sum -c --quiet $W/results/source-manifest.sha256sums) && echo "ok: all project sources still match the archive manifest"
sb $W/proj/.lake -- /bin/sh -c "cat /home/rhcheck/.ssh/authorized_keys" >/dev/null 2>&1 && echo "FAIL: read ssh keys" || echo "ok: read ~/.ssh denied"
sb $W/proj/.lake -- /usr/bin/python3 -I -c "import socket; s=socket.create_connection(('10.0.2.2',22),3)" 2>/dev/null && echo "FAIL: tcp connect" || echo "ok: tcp connect denied"
echo "== Lake sees Mathlib as up to date (no rebuild):"
cd $W/proj && sb $W/proj/.lake -- lake build --no-build Mathlib 2>&1 | tail -n 2
echo "PREPARE DONE"
