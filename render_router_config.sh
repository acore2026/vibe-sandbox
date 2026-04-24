#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER_DIR="${ROUTER_DIR:-${SCRIPT_DIR}/router}"
SERVER_NAME="${SERVER_NAME:-101.245.78.174}"
ARCH_DIAGRAM_SOURCE="${ARCH_DIAGRAM_SOURCE:-${SCRIPT_DIR}/arch-diagram.html}"

mkdir -p "$ROUTER_DIR"
if [[ -f "$ARCH_DIAGRAM_SOURCE" ]]; then
  cp "$ARCH_DIAGRAM_SOURCE" "$ROUTER_DIR/architecture.html"
fi

mapfile -t USERS < <(
  docker ps \
    --filter label=app=vibe-sandbox \
    --filter label=mode=routed \
    --format '{{.Names}} {{.Label "owner"}}' |
    awk 'NF == 2 { print $1 " " $2 }' |
    sort -k2,2
)

{
  cat <<'EOF'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Vibe Coding Sandbox</title>
  <style>
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      background:
        radial-gradient(circle at 20% 15%, rgba(215,255,95,.14), transparent 28rem),
        linear-gradient(135deg, #050806 0%, #10180f 52%, #07110d 100%);
      color: #e8f5df;
      font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }
    main {
      width: min(1600px, calc(100% - 64px));
      margin: 0 auto;
      padding: 48px 0;
    }
    .layout {
      display: grid;
      grid-template-columns: minmax(320px, 470px) minmax(560px, 1fr);
      gap: 28px;
      align-items: start;
    }
    .sidebar {
      position: sticky;
      top: 32px;
    }
    h1 {
      font-size: clamp(2rem, 7vw, 4.4rem);
      line-height: .92;
      margin: 0 0 20px;
      letter-spacing: -0.06em;
    }
    p { color: #b9cbae; }
    form {
      display: flex;
      gap: 10px;
      flex-wrap: wrap;
      margin: 22px 0;
    }
    input {
      flex: 1;
      min-width: 180px;
      border: 1px solid #33422d;
      border-radius: 999px;
      background: #0b110c;
      color: #e8f5df;
      padding: 14px 16px;
      font: inherit;
      outline: none;
    }
    input:focus {
      border-color: #d7ff5f;
      box-shadow: 0 0 0 3px rgba(215,255,95,.14);
    }
    button {
      border: 0;
      border-radius: 999px;
      background: #d7ff5f;
      color: #07110d;
      padding: 14px 18px;
      font: inherit;
      font-weight: 900;
      cursor: pointer;
    }
    .panel {
      border: 1px solid #263620;
      background: rgba(5,8,6,.72);
      border-radius: 24px;
      padding: 22px;
      box-shadow: 0 22px 70px rgba(0,0,0,.25);
    }
    ul { padding: 0; list-style: none; display: grid; gap: 12px; margin: 18px 0 0; }
    li {
      border: 1px solid #263620;
      background: #0b120d;
      border-radius: 16px;
      padding: 14px;
    }
    a { color: #d7ff5f; font-weight: 800; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .muted { color: #91a186; font-size: .92rem; }
    .chip {
      display: inline-block;
      border: 1px solid #34452e;
      border-radius: 999px;
      padding: 4px 10px;
      color: #b9cbae;
      background: #0b120d;
      font-size: .82rem;
      margin: 0 8px 8px 0;
    }
    .diagram {
      width: 100%;
      height: min(900px, calc(100vh - 96px));
      min-height: 680px;
      border: 1px solid #263620;
      border-radius: 16px;
      background: #050806;
    }
    @media (max-width: 1040px) {
      main { width: min(100% - 32px, 760px); padding: 36px 0; }
      .layout { grid-template-columns: 1fr; }
      .sidebar { position: static; }
      .diagram { height: 760px; min-height: 620px; }
    }
  </style>
</head>
<body>
  <main>
    <div class="layout">
      <section class="sidebar">
        <h1>Vibe Coding Sandbox</h1>
        <p>One public entry point on port 7901 routes each teammate to their own terminal and app preview.</p>
        <form id="launch-form">
          <input id="username" name="username" autocomplete="name" placeholder="Your name, e.g. ljm" required pattern="[A-Za-z0-9][A-Za-z0-9_.-]{0,31}">
          <button type="submit">Launch Terminal</button>
        </form>
        <div>
          <span class="chip">Terminal: /name/</span>
          <span class="chip">Preview: /name/preview/</span>
          <span class="chip">App port: 3000</span>
        </div>
        <section class="panel">
          <p class="muted">Active sessions on 101.245.78.174:7901</p>
          <ul>
EOF

  if ((${#USERS[@]} == 0)); then
    printf '            <li>No routed sessions are running.</li>\n'
  else
    for row in "${USERS[@]}"; do
      username="${row#* }"
      printf '            <li><a href="/%s/">%s terminal</a><span class="muted"> · </span><a href="/%s/preview/">app preview</a></li>\n' "$username" "$username" "$username"
    done
  fi

  cat <<'EOF'
          </ul>
        </section>
      </section>
      <section>
        <iframe class="diagram" src="/architecture.html" title="Vibe Coding Sandbox architecture diagram"></iframe>
      </section>
    </div>
  </main>
  <script>
    document.getElementById('launch-form').addEventListener('submit', function (event) {
      event.preventDefault();
      var username = document.getElementById('username').value.trim();
      if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$/.test(username)) {
        alert('Use 1-32 characters from a-z, A-Z, 0-9, _, ., -');
        return;
      }
      window.location.href = '/' + encodeURIComponent(username) + '/';
    });
  </script>
</body>
</html>
EOF
} > "$ROUTER_DIR/index.html"

{
  cat <<'EOF'
events {}

http {
  access_log /var/log/nginx/access.log;
  error_log /var/log/nginx/error.log warn;

  proxy_http_version 1.1;
  proxy_buffering off;
  proxy_request_buffering off;
  proxy_read_timeout 3600s;
  proxy_send_timeout 3600s;

  server {
    listen 8080;
    server_name _;

EOF

  cat <<'EOF'
    location = / {
      root /etc/nginx/html;
      try_files /index.html =404;
    }

    location = /architecture.html {
      root /etc/nginx/html;
      try_files /architecture.html =404;
    }

EOF

  for row in "${USERS[@]}"; do
    container="${row%% *}"
    username="${row#* }"
    cat <<EOF
    location = /${username} {
      return 302 /${username}/;
    }

    location = /${username}/preview {
      return 308 /${username}/preview/;
    }

    location /${username}/preview/ {
      proxy_pass http://${container}:3000/;
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Prefix /${username}/preview;
    }

    location /${username}/ {
      proxy_pass http://${container}:8080/;
      proxy_set_header Accept-Encoding "";
      proxy_set_header Host \$host;
      proxy_set_header X-Real-IP \$remote_addr;
      proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto \$scheme;
      proxy_set_header X-Forwarded-Prefix /${username};
      sub_filter_once on;
      sub_filter_types text/html;
      sub_filter '</body>' '<a class="vibe-preview-button" href="/${username}/preview/" target="_blank" rel="noopener">Open Web App</a><style>.vibe-preview-button{position:fixed;right:18px;top:14px;z-index:2147483647;border:0;border-radius:999px;background:#d7ff5f;color:#07110d!important;padding:11px 16px;font:800 14px/1.1 sans-serif;text-decoration:none!important;box-shadow:0 10px 30px rgba(0,0,0,.35)}.vibe-preview-button:hover{filter:brightness(1.05)}</style></body>';
    }

EOF
  done

  cat <<'EOF'
  }
}
EOF
} > "$ROUTER_DIR/nginx.conf"
