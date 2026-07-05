#!/bin/bash
# Agent-to-agent chat over the LAN bus (no GitHub). Same interface as chat.sh.
#   KVM_AGENT=claude ./netchat.sh send "hello"
#   KVM_AGENT=claude ./netchat.sh read
#   KVM_AGENT=claude ./netchat.sh wait [secs]   # long-poll for a NEW peer message
#
# BUS points at Mac #1. Override with env if the host IP changes:
#   BUS=http://192.168.1.210:8765
set -uo pipefail
BUS="${BUS:-http://192.168.1.210:8765}"
ME="${KVM_AGENT:-}"
CMD="${1:-read}"
STATE="$(dirname "$0")/.netchat.$ME.seq"

need_me() { [ -n "$ME" ] || { echo "ERROR: set KVM_AGENT=claude|codex"; exit 1; }; }

case "$CMD" in
  send)
    need_me
    MSG="${2:-}"
    out=$(curl -s --max-time 10 -X POST "$BUS/send" -H "X-Agent: $ME" --data-binary "$MSG") \
      && echo "sent: $out" || { echo "SEND FAILED (bus down? $BUS)"; exit 1; }
    ;;
  read)
    curl -s --max-time 10 "$BUS/read" || { echo "READ FAILED (bus down? $BUS)"; exit 1; }
    ;;
  wait)
    need_me
    SECS="${2:-25}"
    since=$(cat "$STATE" 2>/dev/null || echo 0)
    resp=$(curl -s --max-time $((SECS+10)) "$BUS/wait/$since?agent=$ME&secs=$SECS")
    if [ -z "$resp" ] || [ "$resp" = "[]" ]; then
      echo "(no new peer message in ${SECS}s)"
      exit 0
    fi
    # print human lines + advance our seq cursor to the last seq seen
    echo "$resp" | python3 -c '
import json,sys
data=json.load(sys.stdin)
last=0
for m in data:
    print(f"[{m[\"ts\"]}] {m[\"agent\"]}: {m[\"msg\"]}")
    last=max(last,m["seq"])
sys.stderr.write(str(last))
' 2>"$STATE.tmp"
    [ -s "$STATE.tmp" ] && mv "$STATE.tmp" "$STATE" || rm -f "$STATE.tmp"
    ;;
  reset)
    # forget our read cursor (re-see everything on next wait)
    rm -f "$STATE"; echo "cursor reset"
    ;;
  *)
    echo "usage: KVM_AGENT=claude|codex BUS=$BUS $0 {send \"msg\"|read|wait [secs]|reset}"
    ;;
esac
