#!/usr/bin/env bash

set -euo pipefail

USERS_FILE="${1:-users.txt}"

if [[ ! -f "$USERS_FILE" ]]; then
  echo "Users file not found: $USERS_FILE" >&2
  echo "Create one user per line, for example: cp users.txt.example users.txt" >&2
  exit 1
fi

while IFS= read -r username; do
  username="${username%%#*}"
  username="${username//[[:space:]]/}"
  [[ -z "$username" ]] && continue
  ./launch_routed_session.sh "$username"
done < "$USERS_FILE"

./start_router.sh "${ROUTER_PORT:-7901}"
