#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOST_PORT="${1:-7901}"
NETWORK_NAME="${NETWORK_NAME:-vibe-net}"
ROUTER_NAME="${ROUTER_NAME:-vibe-router}"
ROUTER_DIR="${ROUTER_DIR:-${SCRIPT_DIR}/router}"
DYNAMIC_ROUTER_PID_FILE="${DYNAMIC_ROUTER_PID_FILE:-/tmp/vibe-dynamic-router.pid}"

usage() {
  cat <<'EOF'
Usage: ./start_router.sh [host-port]

Example:
  ./start_router.sh 7901

This exposes all routed user containers through one public port:
  http://SERVER_IP:7901/alice/
  http://SERVER_IP:7901/alice/preview/
  http://SERVER_IP:7901/bob/
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
  echo "Invalid host port: use a number between 1 and 65535." >&2
  exit 1
fi

docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

if [[ -f "$DYNAMIC_ROUTER_PID_FILE" ]]; then
  dynamic_pid="$(cat "$DYNAMIC_ROUTER_PID_FILE")"
  if [[ -n "$dynamic_pid" ]] && kill -0 "$dynamic_pid" >/dev/null 2>&1; then
    kill "$dynamic_pid"
    sleep 1
  fi
  rm -f "$DYNAMIC_ROUTER_PID_FILE"
fi

"${SCRIPT_DIR}/render_router_config.sh"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$ROUTER_NAME"; then
  docker rm -f "$ROUTER_NAME" >/dev/null
fi

docker run -d \
  --name "$ROUTER_NAME" \
  --rm \
  --network "$NETWORK_NAME" \
  -p "0.0.0.0:${HOST_PORT}:8080" \
  -v "${ROUTER_DIR}/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "${ROUTER_DIR}:/etc/nginx/html:ro" \
  --label app=vibe-router \
  nginx:1.27-alpine >/dev/null

cat <<EOF
Started ${ROUTER_NAME}

Open:
  http://SERVER_PUBLIC_IP:${HOST_PORT}/

User URLs look like:
  http://SERVER_PUBLIC_IP:${HOST_PORT}/alice/
  http://SERVER_PUBLIC_IP:${HOST_PORT}/alice/preview/
EOF
