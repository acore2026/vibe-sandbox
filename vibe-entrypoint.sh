#!/usr/bin/env bash

set -euo pipefail

mkdir -p /etc/vibe-sandbox
cat > /etc/vibe-sandbox/proxy.env <<EOF
export HTTP_PROXY='${HTTP_PROXY:-}'
export HTTPS_PROXY='${HTTPS_PROXY:-}'
export ALL_PROXY='${ALL_PROXY:-}'
export NO_PROXY='${NO_PROXY:-localhost,127.0.0.1,::1}'
export http_proxy='${http_proxy:-${HTTP_PROXY:-}}'
export https_proxy='${https_proxy:-${HTTPS_PROXY:-}}'
export all_proxy='${all_proxy:-${ALL_PROXY:-}}'
export no_proxy='${no_proxy:-${NO_PROXY:-localhost,127.0.0.1,::1}}'
EOF
chmod 0644 /etc/vibe-sandbox/proxy.env

exec "$@"
