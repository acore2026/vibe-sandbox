#!/usr/bin/env bash

set -euo pipefail

USERNAME="${1:-sandbox}"
HOST_PORT="${2:-80}"
IMAGE_NAME="${IMAGE_NAME:-vibe-sandbox:latest}"
CONTAINER_NAME="vibe-${USERNAME}"
HOST_CODEX_HOME="${HOST_CODEX_HOME:-$HOME/.codex}"
PUBLIC_CODEX_HOME="${PUBLIC_CODEX_HOME:-/tmp/vibe-codex-auth-${USERNAME}}"
HOST_OPENCODE_SHARE="${HOST_OPENCODE_SHARE:-$HOME/.local/share/opencode}"
HOST_OPENCODE_CONFIG="${HOST_OPENCODE_CONFIG:-$HOME/.config/opencode}"
PUBLIC_OPENCODE_ROOT="${PUBLIC_OPENCODE_ROOT:-/tmp/vibe-opencode-${USERNAME}}"
HOST_GATEWAY="${HOST_GATEWAY:-host.docker.internal}"
PROXY_BRIDGE_PORT="${PROXY_BRIDGE_PORT:-17890}"

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

HTTP_PROXY_VALUE="$(container_proxy_url "${HTTP_PROXY:-${http_proxy:-}}")"
HTTPS_PROXY_VALUE="$(container_proxy_url "${HTTPS_PROXY:-${https_proxy:-$HTTP_PROXY_VALUE}}")"
ALL_PROXY_VALUE="$(container_proxy_url "${ALL_PROXY:-${all_proxy:-}}")"
NO_PROXY_VALUE="${NO_PROXY:-${no_proxy:-localhost,127.0.0.1,::1}}"

usage() {
  cat <<'EOF'
Usage: ./launch_public_session.sh [username] [host-port]

Example:
  ./launch_public_session.sh sandbox 80

This exposes the HTTP-only terminal publicly on:
  http://SERVER_IP:<host-port>

This script intentionally skips Nginx, HTTPS, and login protection.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,31}$ ]]; then
  echo "Invalid username: use 1-32 characters from [a-zA-Z0-9_.-]." >&2
  exit 1
fi

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
  echo "Invalid host port: use a number between 1 and 65535." >&2
  exit 1
fi

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
  --add-host host.docker.internal:host-gateway \
  -p "0.0.0.0:${HOST_PORT}:8080" \
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
  --label owner="${USERNAME}" \
  "$IMAGE_NAME" >/dev/null

if [[ "$HOST_PORT" == "80" ]]; then
  PUBLIC_URL="http://SERVER_PUBLIC_IP/"
  LOCAL_URL="http://127.0.0.1/"
else
  PUBLIC_URL="http://SERVER_PUBLIC_IP:${HOST_PORT}"
  LOCAL_URL="http://127.0.0.1:${HOST_PORT}"
fi

cat <<EOF
Started ${CONTAINER_NAME}

Open this in your browser:
  ${PUBLIC_URL}

Local test URL:
  ${LOCAL_URL}

Stop it later with:
  docker stop ${CONTAINER_NAME}
EOF
