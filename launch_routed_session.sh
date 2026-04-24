#!/usr/bin/env bash

set -euo pipefail

USERNAME="${1:-}"
IMAGE_NAME="${IMAGE_NAME:-vibe-sandbox:latest}"
NETWORK_NAME="${NETWORK_NAME:-vibe-net}"
CONTAINER_NAME="vibe-${USERNAME}"
HOST_CODEX_HOME="${HOST_CODEX_HOME:-$HOME/.codex}"
PUBLIC_CODEX_HOME="${PUBLIC_CODEX_HOME:-/tmp/vibe-codex-auth-${USERNAME}}"
HOST_OPENCODE_SHARE="${HOST_OPENCODE_SHARE:-$HOME/.local/share/opencode}"
HOST_OPENCODE_CONFIG="${HOST_OPENCODE_CONFIG:-$HOME/.config/opencode}"
PUBLIC_OPENCODE_ROOT="${PUBLIC_OPENCODE_ROOT:-/tmp/vibe-opencode-${USERNAME}}"
HOST_GATEWAY="${HOST_GATEWAY:-}"
PROXY_BRIDGE_PORT="${PROXY_BRIDGE_PORT:-17890}"

usage() {
  cat <<'EOF'
Usage: ./launch_routed_session.sh <username>

Example:
  ./launch_routed_session.sh alice

This starts one private container for the user. It does not publish a host port.
Run ./start_dynamic_router.sh 7901 to expose all routed users through one public port:
  http://SERVER_IP:7901/alice/
EOF
}

container_proxy_url() {
  local value="${1:-}"
  if [[ -z "$value" ]]; then
    return 0
  fi

  value="${value//127.0.0.1:7890/${HOST_GATEWAY}:${PROXY_BRIDGE_PORT}}"
  value="${value//localhost:7890/${HOST_GATEWAY}:${PROXY_BRIDGE_PORT}}"
  value="${value//127.0.0.1/${HOST_GATEWAY}}"
  value="${value//localhost/${HOST_GATEWAY}}"
  printf '%s' "$value"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || -z "$USERNAME" ]]; then
  usage
  exit 0
fi

if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,31}$ ]]; then
  echo "Invalid username: use 1-32 characters from [a-zA-Z0-9_.-]." >&2
  exit 1
fi

docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 || docker network create "$NETWORK_NAME" >/dev/null

if [[ -z "$HOST_GATEWAY" ]]; then
  HOST_GATEWAY="$(docker network inspect "$NETWORK_NAME" --format '{{(index .IPAM.Config 0).Gateway}}')"
fi

HTTP_PROXY_VALUE="$(container_proxy_url "${HTTP_PROXY:-${http_proxy:-}}")"
HTTPS_PROXY_VALUE="$(container_proxy_url "${HTTPS_PROXY:-${https_proxy:-$HTTP_PROXY_VALUE}}")"
ALL_PROXY_VALUE="$(container_proxy_url "${ALL_PROXY:-${all_proxy:-}}")"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  docker stop "$CONTAINER_NAME" >/dev/null
fi

rm -rf "$PUBLIC_CODEX_HOME"
mkdir -p "$PUBLIC_CODEX_HOME"
rm -rf "$PUBLIC_OPENCODE_ROOT"
mkdir -p \
  "$PUBLIC_OPENCODE_ROOT/share" \
  "$PUBLIC_OPENCODE_ROOT/config" \
  "$PUBLIC_OPENCODE_ROOT/state"

if [[ -f "$HOST_CODEX_HOME/auth.json" ]]; then
  install -m 0644 "$HOST_CODEX_HOME/auth.json" "$PUBLIC_CODEX_HOME/auth.json"
fi

if [[ -f "$HOST_CODEX_HOME/config.toml" ]]; then
  install -m 0644 "$HOST_CODEX_HOME/config.toml" "$PUBLIC_CODEX_HOME/config.toml"
fi

if [[ -d "$HOST_OPENCODE_SHARE" ]]; then
  if [[ -f "$HOST_OPENCODE_SHARE/auth.json" ]]; then
    install -m 0644 "$HOST_OPENCODE_SHARE/auth.json" "$PUBLIC_OPENCODE_ROOT/share/auth.json"
  fi
  if [[ -d "$HOST_OPENCODE_SHARE/storage" ]]; then
    cp -a "$HOST_OPENCODE_SHARE/storage" "$PUBLIC_OPENCODE_ROOT/share/storage"
  fi
fi

if [[ -d "$HOST_OPENCODE_CONFIG" ]]; then
  cp -a "$HOST_OPENCODE_CONFIG/." "$PUBLIC_OPENCODE_ROOT/config/"
fi

chown -R 1000:1000 "$PUBLIC_CODEX_HOME" "$PUBLIC_OPENCODE_ROOT"

docker run -d \
  --name "$CONTAINER_NAME" \
  --hostname "$CONTAINER_NAME" \
  --rm \
  --init \
  --network "$NETWORK_NAME" \
  --add-host host.docker.internal:host-gateway \
  -v "${PUBLIC_CODEX_HOME}:/home/coder/.codex" \
  -v "${PUBLIC_OPENCODE_ROOT}/share:/home/coder/.local/share/opencode" \
  -v "${PUBLIC_OPENCODE_ROOT}/config:/home/coder/.config/opencode" \
  -v "${PUBLIC_OPENCODE_ROOT}/state:/home/coder/.local/state/opencode" \
  -e "USER_NAME=${USERNAME}" \
  -e "OPENCODE_DISABLE_AUTOUPDATE=1" \
  -e "HTTP_PROXY=${HTTP_PROXY_VALUE}" \
  -e "HTTPS_PROXY=${HTTPS_PROXY_VALUE}" \
  -e "ALL_PROXY=${ALL_PROXY_VALUE}" \
  -e "NO_PROXY=${NO_PROXY_VALUE}" \
  -e "http_proxy=${HTTP_PROXY_VALUE}" \
  -e "https_proxy=${HTTPS_PROXY_VALUE}" \
  -e "all_proxy=${ALL_PROXY_VALUE}" \
  -e "no_proxy=${NO_PROXY_VALUE}" \
  --label app=vibe-sandbox \
  --label mode=routed \
  --label owner="${USERNAME}" \
  "$IMAGE_NAME" >/dev/null

if docker ps --format '{{.Names}}' | grep -Fxq vibe-router; then
  ./render_router_config.sh >/dev/null
  docker exec vibe-router nginx -s reload >/dev/null
fi

cat <<EOF
Started ${CONTAINER_NAME}

Private upstream:
  http://${CONTAINER_NAME}:8080
  http://${CONTAINER_NAME}:3000

Routed URL after ./start_dynamic_router.sh:
  http://SERVER_PUBLIC_IP:7901/${USERNAME}/
  http://SERVER_PUBLIC_IP:7901/${USERNAME}/preview/

Stop this user later with:
  docker stop ${CONTAINER_NAME}
EOF
