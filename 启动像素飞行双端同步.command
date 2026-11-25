#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

mkdir -p .runtime
if [[ ! -f bridge.local.json || ! -f app/config.json ]]; then
  python3 host/configure.py
fi

PORT="$(python3 -c "import json; print(json.load(open('bridge.local.json')).get('port', 8780))")"
PID_FILE=".runtime/server.pid"

if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  echo "Bridge already running (PID $(cat "$PID_FILE")) on http://127.0.0.1:$PORT"
else
  nohup python3 host/server.py --port "$PORT" > .runtime/server.log 2>&1 &
  echo $! > "$PID_FILE"
  sleep 0.6
fi

open "http://127.0.0.1:$PORT"
