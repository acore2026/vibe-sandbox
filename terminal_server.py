#!/usr/bin/env python3

import base64
import fcntl
import json
import os
import pty
import re
import select
import signal
import struct
import termios
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


HOST = os.environ.get("TERMINAL_HOST", "0.0.0.0")
PORT = int(os.environ.get("TERMINAL_PORT", "8080"))
WORKDIR = Path(os.environ.get("TERMINAL_WORKDIR", "/home/coder/project"))
XTERM_DIR = Path("/opt/http-terminal/node_modules/@xterm/xterm/lib")
XTERM_FIT_DIR = Path("/opt/http-terminal/node_modules/@xterm/addon-fit/lib")
MAX_BUFFER = 1024 * 1024
LONG_POLL_SECONDS = 20
CONTROL_SEQUENCE_RE = re.compile(
    rb"\x1b\[\?2004[hl]|"  # Bracketed paste mode confuses this HTTP terminal renderer.
    rb"\x1b\]0;[^\x07]*(?:\x07|\x1b\\)"  # Window title updates are not useful in browser.
)
ANSI_SEQUENCE_RE = re.compile(rb"\x1b\[[0-?]*[ -/]*[@-~]|\x1b[=>()]")

INDEX_HTML = """<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Codex HTTP Terminal</title>
  <link rel="stylesheet" href="/xterm.css" />
  <style>
    :root { color-scheme: dark; }
    html, body {
      margin: 0;
      background: #10130f;
      color: #f0f5e8;
      font-family: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      width: 100%;
      height: 100vh;
      min-height: 100vh;
      overflow: hidden;
    }
    body {
      display: grid;
      grid-template-rows: auto 1fr;
    }
    header {
      box-sizing: border-box;
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      align-items: center;
      padding: 10px 14px;
      background: #182016;
      border-bottom: 1px solid #34422c;
    }
    h1 {
      font-size: 14px;
      letter-spacing: .08em;
      margin: 0;
      text-transform: uppercase;
    }
    button {
      background: #d7ff6f;
      border: 0;
      border-radius: 999px;
      color: #111;
      cursor: pointer;
      font-weight: 700;
      padding: 8px 12px;
    }
    .hint { color: #b9c8aa; font-size: 13px; }
    #terminal {
      box-sizing: border-box;
      height: calc(100vh - var(--header-height, 58px));
      min-height: 0;
      overflow: hidden;
      padding: 8px;
      width: 100%;
    }
    .xterm {
      height: 100%;
      width: 100%;
    }
    .xterm-screen {
      height: 100% !important;
    }
    .xterm-viewport {
      overflow-y: auto !important;
    }
    #plain-terminal {
      box-sizing: border-box;
      display: none;
      font: 14px/1.35 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      height: calc(100vh - var(--header-height, 58px));
      margin: 0;
      outline: none;
      overflow: auto;
      padding: 12px;
      white-space: pre-wrap;
      width: 100%;
      word-break: break-word;
    }
  </style>
</head>
<body>
  <header>
    <h1>Vibe Coding Sandbox</h1>
    <button id="codex">Start Codex</button>
    <button id="clear">Clear</button>
    <span class="hint">HTTP polling terminal. No WebSocket.</span>
  </header>
  <div id="terminal"></div>
  <pre id="plain-terminal" tabindex="0"></pre>
  <script src="/xterm.js"></script>
  <script src="/addon-fit.js"></script>
  <script>
    const sidKey = 'vibe-http-terminal-session-id-v2';
    let sid = localStorage.getItem(sidKey);
    if (!sid) {
      sid = crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2);
      localStorage.setItem(sidKey, sid);
    }

    const terminalEl = document.getElementById('terminal');
    const plainEl = document.getElementById('plain-terminal');
    const headerEl = document.querySelector('header');
    const useXterm = new URLSearchParams(location.search).get('xterm') === '1';
    if (!useXterm) {
      terminalEl.style.display = 'none';
      plainEl.style.display = 'block';
      plainEl.focus();
    }
    const term = new Terminal({
      cursorBlink: true,
      convertEol: false,
      scrollback: 5000,
      fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
      fontSize: 14,
      theme: {
        background: '#10130f',
        foreground: '#f0f5e8',
        cursor: '#d7ff6f',
        selectionBackground: '#46543a'
      }
    });
    const fitAddon = new FitAddon.FitAddon();
    term.loadAddon(fitAddon);
    if (useXterm) {
      term.open(terminalEl);
      term.reset();
      term.clear();
      fitAddon.fit();
    }

    let pos = 0;
    let pending = Promise.resolve();

    function b64decode(value) {
      const binary = atob(value);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
      return new TextDecoder().decode(bytes);
    }

    let plainBuffer = '';

    function writePlain(text) {
      for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (ch === '\\x1b' && text.slice(i, i + 3) === '\\x1b[K') {
          i += 2;
        } else if (ch === '\\x1b') {
          const match = text.slice(i).match(/^\\x1b\\[[0-?]*[ -/]*[@-~]/);
          if (match) i += match[0].length - 1;
        } else if (ch === '\\x00') {
          continue;
        } else if (ch === '\\b' || ch === '\\x7f') {
          if (plainBuffer.length > 0) plainBuffer = plainBuffer.slice(0, -1);
        } else if (ch === '\\r') {
          if (text[i + 1] === '\\n') {
            plainBuffer += '\\n';
            i += 1;
          }
        } else {
          plainBuffer += ch;
        }
      }
      plainEl.textContent = plainBuffer;
      plainEl.scrollTop = plainEl.scrollHeight;
    }

    function sanitizeInput(data) {
      return data
        .replace(/\x1b\[(?:1[5-9]|2[0-4])(?:;\d+)?~/g, '')
        .replace(/\x1b\[1;\d+[A-Za-z]/g, '')
        .replace(/\x1b\[[A-D]/g, '')
        .replace(/[0-9]*;5~/g, '');
    }

    function send(data) {
      data = sanitizeInput(data);
      if (!data) return;
      pending = pending.then(() => fetch('/api/input', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ sid, data })
      }).catch(() => {}));
    }

    async function poll() {
      try {
        const response = await fetch('/api/output?sid=' + encodeURIComponent(sid) + '&pos=' + pos, { cache: 'no-store' });
        if (response.ok) {
          const payload = await response.json();
          pos = payload.pos;
          if (payload.data) {
            const text = b64decode(payload.data);
            if (useXterm) {
              term.write(text);
            } else {
              writePlain(text);
            }
          }
        }
      } catch (_) {}
      setTimeout(poll, 10);
    }

    async function resize() {
      document.documentElement.style.setProperty('--header-height', headerEl.offsetHeight + 'px');
      terminalEl.style.height = `calc(100vh - ${headerEl.offsetHeight}px)`;
      plainEl.style.height = `calc(100vh - ${headerEl.offsetHeight}px)`;
      if (useXterm) fitAddon.fit();
      await fetch('/api/resize', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ sid, cols: useXterm ? term.cols : 120, rows: useXterm ? term.rows : 40, plain: !useXterm })
      }).catch(() => {});
    }

    term.onData(send);
    terminalEl.addEventListener('pointerdown', () => { if (useXterm) term.focus(); });
    plainEl.addEventListener('pointerdown', () => plainEl.focus());
    document.addEventListener('keydown', (event) => {
      if (useXterm || document.activeElement !== plainEl) return;
      if (event.ctrlKey && event.key.toLowerCase() === 'c') {
        send('\\x03');
      } else if (event.key === 'Enter') {
        send('\\r');
      } else if (event.key === 'Backspace') {
        send('\\x7f');
      } else if (event.key === 'Tab') {
        send('\\t');
      } else if (event.key === 'ArrowUp') {
        send('\\x1b[A');
      } else if (event.key === 'ArrowDown') {
        send('\\x1b[B');
      } else if (event.key === 'ArrowRight') {
        send('\\x1b[C');
      } else if (event.key === 'ArrowLeft') {
        send('\\x1b[D');
      } else if (event.key.length === 1 && !event.metaKey && !event.altKey) {
        send(event.key);
      } else {
        return;
      }
      event.preventDefault();
    });
    window.addEventListener('resize', resize);
    if ('ResizeObserver' in window) new ResizeObserver(resize).observe(headerEl);
    document.getElementById('codex').onclick = () => send('codex\\r');
    document.getElementById('clear').onclick = () => {
      if (useXterm) term.clear();
      else {
        plainBuffer = '';
        plainEl.textContent = '';
      }
    };
    setTimeout(resize, 50);
    setTimeout(resize, 250);
    resize();
    poll();
  </script>
</body>
</html>
"""


class TerminalSession:
    def __init__(self):
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        self.buffer = bytearray()
        self.offset = 0
        env = os.environ.copy()
        env.update({
            "TERM": "vt100",
            "COLORTERM": "",
            "PROMPT_COMMAND": "",
            "PS1": r"\u@\h:\w\$ ",
        })
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(WORKDIR)
            os.execvpe("/bin/bash", ["/bin/bash", "--noprofile", "--norc", "-i"], env)
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()

    def _read_loop(self):
        while True:
            ready, _, _ = select.select([self.fd], [], [], 0.5)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 8192)
            except OSError:
                break
            if not chunk:
                break
            with self.lock:
                clean = CONTROL_SEQUENCE_RE.sub(b"", chunk).replace(b"\x00", b"")
                self.buffer.extend(clean)
                if len(self.buffer) > MAX_BUFFER:
                    drop = len(self.buffer) - MAX_BUFFER
                    del self.buffer[:drop]
                    self.offset += drop
                self.changed.notify_all()

    def read_from(self, pos, wait=True):
        with self.lock:
            if pos < self.offset:
                pos = self.offset
            if wait and pos >= self.offset + len(self.buffer):
                self.changed.wait(timeout=LONG_POLL_SECONDS)
            start = pos - self.offset
            data = bytes(self.buffer[start:])
            return self.offset + len(self.buffer), data

    def write(self, data):
        os.write(self.fd, data)

    def resize(self, cols, rows):
        winsz = struct.pack("HHHH", rows, cols, 0, 0)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, winsz)
        os.kill(self.pid, signal.SIGWINCH)


SESSIONS = {}
SESSIONS_LOCK = threading.Lock()


def get_session(sid):
    safe_sid = "".join(ch for ch in (sid or "default") if ch.isalnum() or ch in "-_")[:80] or "default"
    with SESSIONS_LOCK:
        session = SESSIONS.get(safe_sid)
        if session is None:
            session = TerminalSession()
            SESSIONS[safe_sid] = session
        return session


def sanitize_input(data):
    data = re.sub(rb"\x1b\[(?:1[5-9]|2[0-4])(?:;\d+)?~", b"", data)
    data = re.sub(rb"\x1b\[1;\d+[A-Za-z]", b"", data)
    data = re.sub(rb"\x1b\[[A-D]", b"", data)
    data = re.sub(rb"[0-9]*;5~", b"", data)
    return data


class Handler(BaseHTTPRequestHandler):
    server_version = "HTTPPollingTerminal/1.0"

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/":
            self._send_bytes(INDEX_HTML.encode(), "text/html; charset=utf-8")
        elif path == "/xterm.js":
            self._send_file(XTERM_DIR / "xterm.js", "application/javascript")
        elif path == "/addon-fit.js":
            self._send_file(XTERM_FIT_DIR / "addon-fit.js", "application/javascript")
        elif path == "/xterm.css":
            self._send_file(XTERM_DIR / "xterm.css", "text/css")
        elif path == "/api/output":
            params = parse_qs(parsed.query)
            pos = 0
            try:
                pos = int(params.get("pos", ["0"])[0])
            except ValueError:
                pos = 0
            session = get_session(params.get("sid", ["default"])[0])
            next_pos, data = session.read_from(pos)
            if params.get("plain", ["0"])[0] == "1":
                data = ANSI_SEQUENCE_RE.sub(b"", data)
            payload = {
                "pos": next_pos,
                "data": base64.b64encode(data).decode("ascii"),
            }
            self._send_json(payload)
        else:
            self.send_error(404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self.rfile.read(int(self.headers.get("content-length", "0") or "0"))
        try:
            payload = json.loads(body.decode() or "{}")
        except json.JSONDecodeError:
            payload = {}
        if path == "/api/input":
            data = sanitize_input(str(payload.get("data", "")).encode())
            if data:
                get_session(payload.get("sid", "default")).write(data)
            self._send_json({"ok": True})
        elif path == "/api/resize":
            get_session(payload.get("sid", "default")).resize(int(payload.get("cols", 80)), int(payload.get("rows", 24)))
            self._send_json({"ok": True})
        else:
            self.send_error(404)

    def log_message(self, fmt, *args):
        return

    def _send_json(self, payload):
        self._send_bytes(json.dumps(payload).encode(), "application/json")

    def _send_file(self, path, content_type):
        self._send_bytes(path.read_bytes(), content_type)

    def _send_bytes(self, data, content_type):
        self.send_response(200)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    WORKDIR.mkdir(parents=True, exist_ok=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
