#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERNAME="${1:-ljm}"
HOST_PORT="${2:-7901}"
ROUTER_NAME="${ROUTER_NAME:-vibe-router}"
DYNAMIC_ROUTER_PID_FILE="${DYNAMIC_ROUTER_PID_FILE:-/tmp/vibe-dynamic-router.pid}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

if ! docker ps >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Cannot access Docker.

Run this script from a shell user that can use Docker, for example:
  sudo ./repair_preview_router.sh ljm 7901

Or add your user to the docker group and log in again.
EOF
  exit 1
fi

echo "Stopping old Python dynamic router if present..."
if [[ -f "$DYNAMIC_ROUTER_PID_FILE" ]]; then
  old_pid="$(cat "$DYNAMIC_ROUTER_PID_FILE" || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    kill "$old_pid" || true
    sleep 1
  fi
  rm -f "$DYNAMIC_ROUTER_PID_FILE"
fi
pkill -f "[d]ynamic_router.py" >/dev/null 2>&1 || true

echo "Starting Nginx router on port ${HOST_PORT}..."
"${SCRIPT_DIR}/start_router.sh" "$HOST_PORT"

echo
echo "Running containers:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'

echo
echo "Expected preview route for ${USERNAME}:"
docker exec "$ROUTER_NAME" nginx -T 2>/dev/null | sed -n "/location \\/${USERNAME}\\/preview\\//,/}/p"

echo
echo "Checking whether vibe-${USERNAME} is listening on container port 3000..."
if docker exec "vibe-${USERNAME}" sh -lc "command -v ss >/dev/null 2>&1 && ss -ltn | grep -q ':3000 '"; then
  echo "vibe-${USERNAME} has a process listening on port 3000."
else
  cat <<EOF
No listener detected on vibe-${USERNAME}:3000.

Start a web server inside the sandbox before opening the preview URL, for example:
  python3 -m http.server 3000 --bind 0.0.0.0
EOF
fi

echo
echo "Preview URL:"
echo "  http://101.245.78.174:${HOST_PORT}/${USERNAME}/preview/"
