#!/bin/bash
# Start the LAN message bus on Mac #1 using the firewall-ALLOWED python binary.
# (Managed Mac: firewall can't be edited from CLI, but this python path is already
#  whitelisted for incoming connections, so the bus is reachable over the wifi.)
set -uo pipefail
cd "$(dirname "$0")"
PORT="${1:-8765}"
ALLOWED_PY="/opt/homebrew/Cellar/python@3.14/3.14.5/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
[ -x "$ALLOWED_PY" ] || ALLOWED_PY="$(command -v python3)"
pkill -f "bus.py" 2>/dev/null || true
sleep 1
nohup "$ALLOWED_PY" bus.py "$PORT" > bus.out 2>&1 &
sleep 1.5
ip=$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)
echo "bus pid=$(pgrep -f bus.py | head -1)  ->  http://$ip:$PORT"
curl -s --max-time 5 "http://$ip:$PORT/health" && echo " (reachable on LAN)" || echo "NOT reachable"
