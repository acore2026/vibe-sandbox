#!/usr/bin/env bash

set -euo pipefail

PUBLIC_PORT="${1:-7901}"
PUBLIC_HOST="${PUBLIC_HOST:-101.245.78.174}"
IDLE_TIMEOUT_SECONDS="${IDLE_TIMEOUT_SECONDS:-1800}"
REAPER_INTERVAL_SECONDS="${REAPER_INTERVAL_SECONDS:-60}"
PID_FILE="${PID_FILE:-/tmp/vibe-dynamic-router.pid}"
LOG_FILE="${LOG_FILE:-/tmp/vibe-dynamic-router.log}"

if docker ps -a --format '{{.Names}}' | grep -Fxq vibe-router; then
  docker stop vibe-router >/dev/null
fi

if [[ -f "$PID_FILE" ]]; then
  old_pid="$(cat "$PID_FILE")"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    kill "$old_pid"
    sleep 1
  fi
  rm -f "$PID_FILE"
fi

PUBLIC_PORT="$PUBLIC_PORT" \
PUBLIC_HOST="$PUBLIC_HOST" \
IDLE_TIMEOUT_SECONDS="$IDLE_TIMEOUT_SECONDS" \
REAPER_INTERVAL_SECONDS="$REAPER_INTERVAL_SECONDS" \
  setsid python3 ./dynamic_router.py >"$LOG_FILE" 2>&1 &
router_pid="$!"
echo "$router_pid" > "$PID_FILE"

sleep 1
if ! kill -0 "$router_pid" >/dev/null 2>&1; then
  echo "Dynamic router failed to start. Log:" >&2
  sed -n '1,120p' "$LOG_FILE" >&2
  exit 1
fi

cat <<EOF
Started dynamic router

Open:
  http://${PUBLIC_HOST}:${PUBLIC_PORT}/

Logs:
  ${LOG_FILE}

Idle cleanup:
  ${IDLE_TIMEOUT_SECONDS} seconds

Stop:
  kill ${router_pid}
EOF
