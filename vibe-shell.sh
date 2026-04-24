#!/usr/bin/env bash

if [[ -r /etc/vibe-sandbox/proxy.env ]]; then
  # shellcheck disable=SC1091
  source /etc/vibe-sandbox/proxy.env
fi

cd /home/coder/project || exit 1
exec /bin/bash
