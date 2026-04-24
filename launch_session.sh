#!/usr/bin/env bash

set -euo pipefail

IMAGE_NAME="${IMAGE_NAME:-vibe-sandbox:latest}"
CODEX_AUTH_DIR="${CODEX_AUTH_DIR:-$HOME/.config/codex}"
HOST_OPENCODE_SHARE="${HOST_OPENCODE_SHARE:-$HOME/.local/share/opencode}"
HOST_OPENCODE_CONFIG="${HOST_OPENCODE_CONFIG:-$HOME/.config/opencode}"
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
Usage: ./launch_session.sh <username> <host-port>

Example:
  ./launch_session.sh alice 8081

Environment overrides:
  IMAGE_NAME       Docker image to run. Default: vibe-sandbox:latest
  CODEX_AUTH_DIR   Host Codex auth directory. Default: ~/.config/codex
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

USERNAME="$1"
HOST_PORT="$2"
PUBLIC_OPENCODE_ROOT="${PUBLIC_OPENCODE_ROOT:-/tmp/vibe-opencode-${USERNAME}}"

if [[ ! "$USERNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,31}$ ]]; then
  echo "Invalid username: use 1-32 characters from [a-zA-Z0-9_.-]." >&2
  exit 1
fi

if [[ ! "$HOST_PORT" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1024 || HOST_PORT > 65535 )); then
  echo "Invalid host port: use a number between 1024 and 65535." >&2
  exit 1
fi

if [[ ! -d "$CODEX_AUTH_DIR" ]]; then
  echo "Codex auth directory not found: $CODEX_AUTH_DIR" >&2
  exit 1
fi

if command -v ss >/dev/null 2>&1; then
  if ss -ltn "( sport = :$HOST_PORT )" | grep -q ":$HOST_PORT"; then
    echo "Host port $HOST_PORT is already in use." >&2
    exit 1
  fi
fi

SAFE_NAME="${USERNAME//[^a-zA-Z0-9_.-]/-}"
CONTAINER_NAME="vibe-${SAFE_NAME}"

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  echo "Container $CONTAINER_NAME already exists. Stop it first with: docker stop $CONTAINER_NAME" >&2
  exit 1
fi

rm -rf "$PUBLIC_OPENCODE_ROOT"
mkdir -p \
  "$PUBLIC_OPENCODE_ROOT/share" \
  "$PUBLIC_OPENCODE_ROOT/config" \
  "$PUBLIC_OPENCODE_ROOT/state"

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

chown -R 1000:1000 "$PUBLIC_OPENCODE_ROOT"

docker run -d \
  --name "$CONTAINER_NAME" \
  --hostname "$CONTAINER_NAME" \
  --rm \
  --init \
  --pull=never \
  --cap-drop=ALL \
  --security-opt no-new-privileges:true \
  --add-host host.docker.internal:host-gateway \
  --pids-limit 512 \
  --memory 4g \
  --cpus 2 \
  --tmpfs /tmp:exec,size=1g \
  --tmpfs /run:size=64m \
  -p "127.0.0.1:${HOST_PORT}:8080" \
  -v "${CODEX_AUTH_DIR}:/home/coder/.config/codex:ro" \
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

cat <<EOF
Started ${CONTAINER_NAME}

Local upstream:
  http://127.0.0.1:${HOST_PORT}

Recommended public access pattern:
  Put Nginx in front of this port with HTTPS + Basic Auth.

Cleanup:
  docker stop ${CONTAINER_NAME}

Because --rm is enabled, stopping the container also deletes it.
EOF
