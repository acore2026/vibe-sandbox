#!/usr/bin/env python3

import html
import http.client
import json
import os
import re
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
ARCH_DIAGRAM_FILE = os.path.join(BASE_DIR, "arch-diagram.html")
NETWORK_NAME = os.environ.get("NETWORK_NAME", "vibe-net")
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", "101.245.78.174")
PUBLIC_PORT = int(os.environ.get("PUBLIC_PORT", "7901"))
TERMINAL_PORT = int(os.environ.get("TERMINAL_PORT", "8080"))
PREVIEW_PORT = int(os.environ.get("PREVIEW_PORT", "3000"))
IDLE_TIMEOUT_SECONDS = int(os.environ.get("IDLE_TIMEOUT_SECONDS", str(30 * 60)))
REAPER_INTERVAL_SECONDS = int(os.environ.get("REAPER_INTERVAL_SECONDS", "60"))
MAX_SESSIONS = int(os.environ.get("MAX_SESSIONS", "40"))
SESSION_STATE_FILE = os.environ.get("SESSION_STATE_FILE", "/tmp/vibe-session-state.json")
USERNAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,31}$")
RESERVED_NAMES = {
    "api",
    "architecture",
    "favicon.ico",
    "healthz",
    "sessions",
    "static",
}
STATE_LOCK = threading.Lock()
SESSION_CREATE_LOCK = threading.Lock()
SESSION_STATE = {"last_access": {}}


def load_state():
    global SESSION_STATE
    try:
        with open(SESSION_STATE_FILE, "r", encoding="utf-8") as handle:
            loaded = json.load(handle)
    except FileNotFoundError:
        return
    except Exception as exc:
        print(f"could not load session state: {exc}", flush=True)
        return

    if isinstance(loaded, dict) and isinstance(loaded.get("last_access"), dict):
        SESSION_STATE = loaded


def save_state():
    tmp_file = f"{SESSION_STATE_FILE}.tmp"
    with open(tmp_file, "w", encoding="utf-8") as handle:
        json.dump(SESSION_STATE, handle, sort_keys=True)
    os.replace(tmp_file, SESSION_STATE_FILE)


def mark_access(username):
    with STATE_LOCK:
        SESSION_STATE.setdefault("last_access", {})[username] = time.time()
        save_state()


def forget_user(username):
    with STATE_LOCK:
        SESSION_STATE.setdefault("last_access", {}).pop(username, None)
        save_state()


def get_last_access(username):
    with STATE_LOCK:
        value = SESSION_STATE.setdefault("last_access", {}).get(username)
    if isinstance(value, (int, float)):
        return float(value)
    return None
HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
}


def run(args, check=True):
    return subprocess.run(
        args,
        cwd=BASE_DIR,
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def list_users():
    result = run(
        [
            "docker",
            "ps",
            "--filter",
            "label=app=vibe-sandbox",
            "--filter",
            "label=mode=routed",
            "--format",
            "{{.Label \"owner\"}}",
        ]
    )
    return sorted({line.strip() for line in result.stdout.splitlines() if line.strip()})


def list_user_containers():
    result = run(
        [
            "docker",
            "ps",
            "--filter",
            "label=app=vibe-sandbox",
            "--filter",
            "label=mode=routed",
            "--format",
            "{{.Names}} {{.Label \"owner\"}}",
        ]
    )
    containers = []
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2:
            containers.append((parts[0], parts[1]))
    return containers


def container_name(username):
    return f"vibe-{username}"


def container_running(username):
    result = run(
        ["docker", "ps", "--format", "{{.Names}}"],
        check=True,
    )
    return container_name(username) in set(result.stdout.splitlines())


def session_capacity_message():
    return (
        f"Sandbox capacity reached: {MAX_SESSIONS} active sessions are already running. "
        "Try again later or ask an administrator to stop an unused session."
    )


def ensure_session(username):
    if not USERNAME_RE.match(username) or username in RESERVED_NAMES:
        raise ValueError("Invalid username. Use 1-32 characters from a-z, A-Z, 0-9, _, ., -.")

    with SESSION_CREATE_LOCK:
        if container_running(username):
            mark_access(username)
            return

        running_sessions = len(list_user_containers())
        if MAX_SESSIONS > 0 and running_sessions >= MAX_SESSIONS:
            raise RuntimeError(session_capacity_message())

        run(["./launch_routed_session.sh", username])
        mark_access(username)

        deadline = time.time() + 20
        while time.time() < deadline:
            if container_ip(username):
                return
            time.sleep(0.25)
    raise RuntimeError(f"Timed out waiting for {container_name(username)} to get an IP address")


def stop_session(username, reason="idle"):
    name = container_name(username)
    result = run(["docker", "stop", name], check=False)
    forget_user(username)
    if result.returncode == 0:
        print(f"stopped {name}: {reason}", flush=True)
    else:
        print(f"could not stop {name}: {result.stderr.strip()}", flush=True)


def reap_idle_sessions_once():
    if IDLE_TIMEOUT_SECONDS <= 0:
        return

    now = time.time()
    for name, username in list_user_containers():
        last_access = get_last_access(username)
        if last_access is None:
            # Existing containers from before the reaper starts get a full idle
            # window instead of being deleted immediately.
            mark_access(username)
            continue
        idle_for = now - last_access
        if idle_for >= IDLE_TIMEOUT_SECONDS:
            stop_session(username, reason=f"idle for {int(idle_for)} seconds")


def reaper_loop():
    while True:
        try:
            reap_idle_sessions_once()
        except Exception as exc:
            print(f"session reaper error: {exc}", flush=True)
        time.sleep(max(REAPER_INTERVAL_SECONDS, 5))


def container_ip(username):
    result = run(
        [
            "docker",
            "inspect",
            "-f",
            "{{json .NetworkSettings.Networks}}",
            container_name(username),
        ],
        check=False,
    )
    if result.returncode != 0:
        return None
    try:
        networks = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    network = networks.get(NETWORK_NAME) or {}
    return network.get("IPAddress") or None


def split_user_path(path):
    parsed = urllib.parse.urlsplit(path)
    parts = parsed.path.lstrip("/").split("/", 1)
    if not parts or not parts[0]:
        return None, None, None, False
    username = urllib.parse.unquote(parts[0])
    remainder = parts[1] if len(parts) > 1 else ""
    is_preview = remainder == "preview" or remainder.startswith("preview/")
    if is_preview:
        preview_rest = remainder[len("preview") :]
        if preview_rest.startswith("/"):
            rest = preview_rest
        else:
            rest = "/"
    else:
        rest = "/" + remainder
    if parsed.query:
        rest += "?" + parsed.query
    return username, rest, parsed.path, is_preview


def page(title, body, status=200):
    payload = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(title)}</title>
  <style>
    :root {{ color-scheme: dark; }}
    body {{
      margin: 0;
      min-height: 100vh;
      background:
        radial-gradient(circle at 20% 15%, rgba(215,255,95,.14), transparent 28rem),
        linear-gradient(135deg, #050806 0%, #10180f 52%, #07110d 100%);
      color: #e8f5df;
      font: 16px/1.5 ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    }}
    main {{
      width: min(1600px, calc(100% - 64px));
      margin: 0 auto;
      padding: 56px 0;
    }}
    .home-layout {{
      display: grid;
      grid-template-columns: minmax(320px, 480px) minmax(560px, 1fr);
      gap: 28px;
      align-items: start;
    }}
    .home-sidebar {{
      position: sticky;
      top: 32px;
    }}
    h1 {{ font-size: clamp(2rem, 7vw, 4.6rem); line-height: .92; margin: 0 0 24px; letter-spacing: -0.06em; }}
    p {{ color: #b9cbae; }}
    form {{ display: flex; gap: 12px; flex-wrap: wrap; margin: 28px 0; }}
    input {{
      min-width: 240px;
      flex: 1;
      border: 1px solid #33422d;
      border-radius: 999px;
      background: #0b110c;
      color: #e8f5df;
      padding: 15px 18px;
      font: inherit;
    }}
    button, a.button {{
      border: 0;
      border-radius: 999px;
      background: #d7ff5f;
      color: #07110d;
      padding: 15px 20px;
      font-weight: 800;
      text-decoration: none;
      cursor: pointer;
    }}
    ul {{ padding: 0; list-style: none; display: grid; gap: 10px; }}
    li a {{ color: #d7ff5f; font-weight: 800; }}
    .panel {{ border: 1px solid #263620; background: rgba(5,8,6,.7); border-radius: 24px; padding: 22px; }}
    .architecture {{ min-width: 0; }}
    .architecture-frame {{
      width: 100%;
      height: min(900px, calc(100vh - 112px));
      min-height: 680px;
      border: 1px solid #263620;
      border-radius: 12px;
      background: #050806;
    }}
    @media (max-width: 1040px) {{
      main {{
        width: min(100% - 32px, 760px);
        padding: 40px 0;
      }}
      .home-layout {{
        grid-template-columns: 1fr;
      }}
      .home-sidebar {{
        position: static;
      }}
      .architecture-frame {{
        height: 760px;
        min-height: 620px;
      }}
    }}
    .error {{ color: #ffb4a8; }}
    code {{ color: #d7ff5f; }}
  </style>
</head>
<body>
  <main>{body}</main>
</body>
</html>"""
    return status, payload.encode("utf-8")


def should_inject_preview_button(headers, is_preview):
    if is_preview:
        return False
    for key, value in headers:
        if key.lower() == "content-type" and "text/html" in value.lower():
            return True
    return False


def inject_preview_button(payload, username):
    try:
        html_payload = payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload

    marker = "</body>"
    if marker not in html_payload or "vibe-preview-button" in html_payload:
        return payload

    quoted_user = urllib.parse.quote(username)
    button = f"""<a class="vibe-preview-button" href="/{quoted_user}/preview/" target="_blank" rel="noopener">Open Web App</a><style>.vibe-preview-button{{position:fixed;right:18px;top:14px;z-index:2147483647;border:0;border-radius:999px;background:#d7ff5f;color:#07110d!important;padding:11px 16px;font:800 14px/1.1 sans-serif;text-decoration:none!important;box-shadow:0 10px 30px rgba(0,0,0,.35)}}.vibe-preview-button:hover{{filter:brightness(1.05)}}</style>"""
    return html_payload.replace(marker, button + marker, 1).encode("utf-8")


class Router(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        if self.path in ("/", ""):
            self.render_home()
            return
        if self.path == "/architecture":
            self.render_architecture()
            return
        if self.path == "/healthz":
            self.send_bytes(200, b"ok\n", "text/plain; charset=utf-8")
            return
        self.proxy()

    def do_HEAD(self):
        if self.path in ("/", ""):
            status, payload = self.home_payload()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            return
        self.proxy(head_only=True)

    def do_POST(self):
        if self.path == "/sessions":
            self.create_session()
            return
        self.proxy()

    def do_PUT(self):
        self.proxy()

    def do_PATCH(self):
        self.proxy()

    def do_DELETE(self):
        self.proxy()

    def do_OPTIONS(self):
        self.proxy()

    def home_payload(self):
        users = list_users()
        if users:
            sessions = "\n".join(
                f"""
                <li>
                  <a href="/{html.escape(user)}/">{html.escape(user)} terminal</a>
                  <span> · </span>
                  <a href="/{html.escape(user)}/preview/">app preview</a>
                </li>
                """
                for user in users
            )
        else:
            sessions = "<li>No active sessions yet.</li>"

        body = f"""
<div class="home-layout">
  <div class="home-sidebar">
    <h1>Vibe Coding Sandbox</h1>
    <p>Enter your name to create or resume an isolated sandbox container.</p>
    <form method="post" action="/sessions">
      <input name="username" autocomplete="name" placeholder="Your name, e.g. alice" required pattern="[A-Za-z0-9][A-Za-z0-9_.-]{{0,31}}">
      <button type="submit">Launch Terminal</button>
    </form>
    <section class="panel">
      <p>Active sessions on <code>{html.escape(PUBLIC_HOST)}:{PUBLIC_PORT}</code></p>
      <p>Capacity limit: <code>{len(users)} / {MAX_SESSIONS}</code> active sessions.</p>
      <p>Run a web app inside the sandbox on <code>0.0.0.0:{PREVIEW_PORT}</code>, then open <code>/your-name/preview/</code>.</p>
      <p>Unused sessions are stopped after <code>{IDLE_TIMEOUT_SECONDS // 60}</code> idle minutes.</p>
      <ul>{sessions}</ul>
    </section>
  </div>
  <section class="architecture">
    <iframe class="architecture-frame" src="/architecture" title="Vibe Coding Sandbox architecture diagram"></iframe>
  </section>
</div>
"""
        return page("Vibe Coding Sandbox", body)

    def render_home(self):
        status, payload = self.home_payload()
        self.send_bytes(status, payload, "text/html; charset=utf-8")

    def render_architecture(self):
        try:
            with open(ARCH_DIAGRAM_FILE, "rb") as handle:
                payload = handle.read()
        except FileNotFoundError:
            self.send_error(404, "Architecture diagram not found")
            return
        self.send_bytes(200, payload, "text/html; charset=utf-8")

    def create_session(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length).decode("utf-8", errors="replace")
        params = urllib.parse.parse_qs(raw)
        username = (params.get("username") or [""])[0].strip()

        try:
            ensure_session(username)
            mark_access(username)
        except Exception as exc:
            status, payload = page(
                "Session Error",
                f"""
<h1>Could not start sandbox</h1>
<p class="error">{html.escape(str(exc))}</p>
<p><a class="button" href="/">Back</a></p>
""",
                status=400,
            )
            self.send_bytes(status, payload, "text/html; charset=utf-8")
            return

        self.send_response(303)
        self.send_header("Location", f"/{urllib.parse.quote(username)}/")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def proxy(self, head_only=False):
        username, upstream_path, parsed_path, is_preview = split_user_path(self.path)
        if not username or not USERNAME_RE.match(username) or username in RESERVED_NAMES:
            self.send_error(404)
            return

        if parsed_path == f"/{username}/preview":
            self.send_response(308)
            self.send_header("Location", f"/{urllib.parse.quote(username)}/preview/")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if not container_running(username):
            # Direct visits to /name/ are lazy-created. Asset/API paths are not,
            # otherwise /favicon.ico or stale /api requests would create users.
            if parsed_path not in (f"/{username}", f"/{username}/"):
                self.send_error(404, f"No running sandbox for {username}")
                return
            try:
                ensure_session(username)
            except Exception as exc:
                self.send_error(502, str(exc))
                return

        ip = container_ip(username)
        if not ip:
            self.send_error(502, f"No upstream IP for {container_name(username)}")
            return
        mark_access(username)
        upstream_port = PREVIEW_PORT if is_preview else TERMINAL_PORT
        upstream_prefix = f"/{username}/preview" if is_preview else f"/{username}"

        body = None
        if self.command in ("POST", "PUT", "PATCH", "DELETE"):
            length = int(self.headers.get("Content-Length", "0") or "0")
            body = self.rfile.read(length)

        headers = {}
        for key, value in self.headers.items():
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS or lower in {"host", "accept-encoding"}:
                continue
            headers[key] = value
        headers["Host"] = f"{ip}:{upstream_port}"
        headers["X-Forwarded-Host"] = self.headers.get("Host", "")
        headers["X-Forwarded-Prefix"] = upstream_prefix
        headers["X-Forwarded-Proto"] = "http"
        headers["X-Real-IP"] = self.client_address[0]

        conn = http.client.HTTPConnection(ip, upstream_port, timeout=3700)
        try:
            conn.request(self.command, upstream_path, body=body, headers=headers)
            resp = conn.getresponse()
            payload = b"" if head_only else resp.read()
        except Exception as exc:
            if is_preview:
                self.send_preview_error(username, exc)
            else:
                self.send_error(502, f"Proxy error for {username}: {exc}")
            return
        finally:
            conn.close()

        response_headers = resp.getheaders()
        if not head_only and should_inject_preview_button(response_headers, is_preview):
            payload = inject_preview_button(payload, username)

        self.send_response(resp.status, resp.reason)
        for key, value in response_headers:
            lower = key.lower()
            if lower in HOP_BY_HOP_HEADERS:
                continue
            if lower == "content-length":
                continue
            if lower == "content-encoding":
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        if not head_only:
            self.wfile.write(payload)

    def send_preview_error(self, username, exc):
        status, payload = page(
            "Preview Not Ready",
            f"""
<h1>Preview is not running</h1>
<p class="error">Could not connect to <code>{html.escape(username)}</code>'s app on container port <code>{PREVIEW_PORT}</code>.</p>
<p>Inside the sandbox terminal, start your web app on <code>0.0.0.0:{PREVIEW_PORT}</code>, then refresh this page.</p>
<p>Example for Vite:</p>
<pre><code>npm run dev -- --host 0.0.0.0 --port {PREVIEW_PORT}</code></pre>
<p class="error">Proxy detail: {html.escape(str(exc))}</p>
<p><a class="button" href="/{urllib.parse.quote(username)}/">Back to terminal</a></p>
""",
            status=502,
        )
        self.send_bytes(status, payload, "text/html; charset=utf-8")

    def send_bytes(self, status, payload, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print(f"{self.client_address[0]} - {fmt % args}", flush=True)


def main():
    load_state()
    threading.Thread(target=reaper_loop, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", PUBLIC_PORT), Router)
    print(
        f"dynamic router listening on 0.0.0.0:{PUBLIC_PORT}; "
        f"idle timeout={IDLE_TIMEOUT_SECONDS}s",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
