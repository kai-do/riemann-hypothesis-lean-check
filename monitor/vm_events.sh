#!/usr/bin/env bash
# Host-side watcher for the VM run. Polls results/ over ssh every 2 minutes and prints one line per new event:
# phase changes, errors or sorry warnings appearing, every 10% of modules, low memory, the run process ending,
# and the VM being unreachable. State in ~/rh-vm/.events-state so re-arming doesn't repeat events.
ST=$HOME/rh-vm/.events-state; touch $ST
S="ssh -n -i $HOME/rh-vm/rh_vm_key -p 2222 -o UserKnownHostsFile=$HOME/rh-vm/known_hosts -o BatchMode=yes -o ConnectTimeout=10 rhcheck@127.0.0.1"
emit() { grep -qxF "$1" $ST || { echo "$1"; echo "$1" >> $ST; }; }
down=0
while true; do
  out=$($S 'R=work/results; cat $R/build-phase.txt 2>/dev/null | sed "s/^/PHASE: /"; head -n2 $R/status.txt 2>/dev/null | sed "s/^/STATUS: /"; pgrep -f "06-build.sh|0[7-9]-.*\.sh" >/dev/null && echo "RUNNING" || echo "NOTRUNNING"; ls $R/judge-*.txt 2>/dev/null | while read f; do sed "s/^/JUDGE: /" $f; done' 2>/dev/null)
  if [ -z "$out" ]; then down=$((down+1)); [ $down = 3 ] && echo "VM UNREACHABLE for 6 min"; sleep 120; continue; fi
  down=0
  echo "$out" | grep '^PHASE: ' | while read -r l; do emit "$l"; done
  echo "$out" | grep '^JUDGE: ' | while read -r l; do emit "$l"; done
  s=$(echo "$out" | grep '^STATUS: modules' | head -1)
  pct=$(echo "$s" | grep -oP '\(\K[0-9]+(?=\.[0-9]+%)'); [ -n "$pct" ] && emit "PROGRESS: reached $((pct/10*10))% of modules"
  e=$(echo "$out" | grep -oP 'errors \K[0-9]+'); so=$(echo "$out" | grep -oP 'sorry-warnings \K[0-9]+')
  [ "${e:-0}" -gt 0 ] && emit "BUILD ERRORS: $e error lines in build.log"
  [ "${so:-0}" -gt 0 ] && emit "SORRY: $so 'declaration uses sorry' warnings"
  m=$(echo "$out" | grep -oP 'mem-avail \K[0-9]+'); [ "${m:-99}" -lt 8 ] && emit "MEMORY: only ${m}G available"
  echo "$out" | grep -qx NOTRUNNING && emit "PROCESS: no run script running ($(echo "$out" | grep '^PHASE' | tail -1))"
  sleep 120
done
