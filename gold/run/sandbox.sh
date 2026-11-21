# Source me inside the VM as rhcheck. `sb <rw-dir>... -- cmd args` runs cmd under Landlock (landrun):
# read+exec system dirs and the Lean toolchain, read-only project sources, read-write only the given dirs and a
# private tmp, no TCP network. The VM kernel has Landlock ABI v6 (FS, TCP, scoping; no UDP rules, but the VM has
# no network), and landrun demands v10 unless --best-effort, so best-effort is used and the confinement is
# verified by tests (05-prepare.sh) instead of assumed. Optional: SB_RO="dir ..." adds read-only paths.
W=/home/rhcheck/work
LANDRUN=$W/tools/bin/landrun
export PATH=/home/rhcheck/.elan/bin:/usr/bin:/bin
sb() {
  local rw=()
  while [ "$1" != "--" ]; do rw+=(--rw "$1"); shift; done; shift
  mkdir -p $W/sbtmp
  "$LANDRUN" --best-effort --rox /usr --rox /lib --rox /lib64 --rox /bin --rox /home/rhcheck/.elan \
    --ro /etc --ro /proc --ro /sys/devices/system/cpu --rw /dev/null --ro /dev/urandom \
    --ro $W/proj --ro $W/gold --rox $W/tools \
    --rw $W/sbtmp "${rw[@]}" ${SB_RO:+$(for d in $SB_RO; do printf -- "--ro %s " "$d"; done)} \
    --env PATH=/home/rhcheck/.elan/bin:/usr/bin:/bin --env HOME=/home/rhcheck --env TMPDIR=$W/sbtmp \
    --env LEAN_ABORT_ON_PANIC=1 --env ELAN_HOME=/home/rhcheck/.elan \
    -- "$@"
}
