#!/usr/bin/env bash

set -euo pipefail

LISTEN_PORT="${1:-17890}"
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"
TARGET_PORT="${TARGET_PORT:-7890}"
PID_FILE="${PID_FILE:-/tmp/vibe-proxy-bridge.pid}"
LOG_FILE="${LOG_FILE:-/tmp/vibe-proxy-bridge.log}"

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE")"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    kill "$old_pid"
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

PROXY_BRIDGE_LISTEN_PORT="$LISTEN_PORT" \
PROXY_BRIDGE_TARGET_HOST="$TARGET_HOST" \
PROXY_BRIDGE_TARGET_PORT="$TARGET_PORT" \
  setsid python3 ./proxy_bridge.py >"$LOG_FILE" 2>&1 &
bridge_pid="$!"
echo "$bridge_pid" > "$PID_FILE"

sleep 1
if ! kill -0 "$bridge_pid" >/dev/null 2>&1; then
  echo "Proxy bridge failed to start. Log:" >&2
  sed -n '1,120p' "$LOG_FILE" >&2
  exit 1
fi

cat <<EOF
Started proxy bridge

Listen:
  0.0.0.0:${LISTEN_PORT}

Target:
  ${TARGET_HOST}:${TARGET_PORT}

Stop:
  kill ${bridge_pid}
EOF
