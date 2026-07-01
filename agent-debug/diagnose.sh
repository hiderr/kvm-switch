#!/bin/bash
# KVM Switch connectivity diagnostics. Run on BOTH Macs.
#   ./diagnose.sh                 # local checks only
#   ./diagnose.sh <peer-ip>       # + ping / TCP connect to the peer
set -uo pipefail

PORT=52333
CFG="$HOME/Library/Application Support/KVM Switch/config.json"
if [ -f "$CFG" ]; then
  P=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('port',52333))" "$CFG" 2>/dev/null)
  [ -n "${P:-}" ] && PORT="$P"
fi

echo "===== KVM diagnostics @ $(date -u +%H:%M:%SZ) ====="
echo "## host"
echo "name: $(scutil --get ComputerName 2>/dev/null || hostname)"
echo "en0:  $(ipconfig getifaddr en0 2>/dev/null || echo -)"
echo "en1:  $(ipconfig getifaddr en1 2>/dev/null || echo -)"
echo "port (from config): $PORT"

echo "## kvm process"
pgrep -fl kvm-switch || echo "  NOT RUNNING"

echo "## listening socket on $PORT"
lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || echo "  nothing LISTENing on $PORT"

echo "## application firewall"
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null || echo "  (n/a)"

echo "## bonjour browse _kvmswitch._tcp (5s)"
( dns-sd -B _kvmswitch._tcp & BP=$!; sleep 5; kill "$BP" 2>/dev/null ) 2>&1 | sed 's/^/  /'

if [ -n "${1:-}" ]; then
  PEER="$1"
  echo "## ping $PEER (3x)"
  ping -c 3 -t 3 "$PEER" 2>&1 | sed 's/^/  /'
  echo "## tcp connect $PEER:$PORT"
  nc -vz -G 3 "$PEER" "$PORT" 2>&1 | sed 's/^/  /'
else
  echo "## peer test skipped — rerun as: ./diagnose.sh <peer-ip>"
fi
echo "===== end ====="
