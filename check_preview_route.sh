#!/usr/bin/env bash

set -euo pipefail

USERNAME="${1:-ljm}"
HOST_PORT="${2:-7901}"
ROUTER_NAME="${ROUTER_NAME:-vibe-router}"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

echo "Checking router container..."
docker ps --filter "name=^/${ROUTER_NAME}$" --format '  {{.Names}}  {{.Image}}  {{.Ports}}'

echo
echo "Checking generated Nginx route for ${USERNAME}..."
docker exec "$ROUTER_NAME" nginx -T 2>/dev/null | sed -n "/location \\/${USERNAME}\\/preview\\//,/}/p"

echo
echo "Checking public preview URL from the server..."
set +e
curl -i --max-time 5 "http://127.0.0.1:${HOST_PORT}/${USERNAME}/preview/" | sed -n '1,24p'
curl_status="${PIPESTATUS[0]}"
set -e

if [[ "$curl_status" -ne 0 ]]; then
  echo
  echo "curl failed. If the router is running, make sure the user's app is listening on 0.0.0.0:3000 inside vibe-${USERNAME}."
fi
