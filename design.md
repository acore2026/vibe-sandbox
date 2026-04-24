# Vibe Sandbox Design

This setup provides a disposable, browser-based coding sandbox for non-technical teammates:

- `code-server` gives each user a visual IDE and terminal in the browser.
- `@openai/codex` is installed globally inside the container.
- `opencode` is installed globally inside the container.
- Every session runs in a fresh Docker container.
- The host's Codex auth directory is mounted read-only.
- Container ports are bound to `127.0.0.1` so they are not exposed directly on the public IP.

## Files

- `Dockerfile`: Builds the sandbox image.
- `launch_session.sh`: Starts one disposable user session.
- `dynamic_router.py`: Creates/resumes per-user routed containers and proxies traffic through one public port.
- `design.md`: Build, run, proxy, and security notes.

## Build The Image

Run from this directory:

```bash
docker build -t vibe-sandbox:latest .
chmod +x launch_session.sh
```

## Start A Session

Example:

```bash
./launch_session.sh alice 8081
```

What this does:

- Starts the container in the background with `docker run -d`.
- Publishes `127.0.0.1:8081` on the host to `8080` inside the container.
- Mounts `~/.config/codex` into `/home/coder/.config/codex` as read-only.
- Applies automatic cleanup with `--rm`.

Stop and remove the session:

```bash
docker stop vibe-alice
```

## Dynamic One-Port Mode

For many teammates, use the dynamic router instead of manually assigning ports:

```bash
docker build -t vibe-sandbox:latest .
./start_dynamic_router.sh 7901
```

Then open:

```text
http://101.245.78.174:7901/
```

The home page asks for a username. The first request creates `vibe-<username>` automatically. Later requests resume the same running container until it is idle long enough to be stopped by the reaper.

Routed paths:

- `/<username>/` proxies to the user's terminal on container port `8080`.
- `/<username>/preview/` proxies to the user's web app on container port `3000`.

To expose a web app from inside the sandbox, start it on `0.0.0.0:3000`:

```bash
npm run dev -- --host 0.0.0.0 --port 3000
python3 -m http.server 3000 --bind 0.0.0.0
```

Then visit:

```text
http://101.245.78.174:7901/alice/preview/
```

Some frontend dev servers need a base path because the app is served under `/<username>/preview/` instead of `/`. For Vite, configure `base: "/alice/preview/"` or run a production preview/build that supports a relative base.

## How Teammates Access It

Do not send teammates to `http://server-public-ip:8081`.

The launcher intentionally binds the container to loopback only:

```text
127.0.0.1:<host-port> -> container:8080
```

That means the container is reachable only from the server itself. Nginx should be the only public entry point.

## Nginx Reverse Proxy With Basic Auth

Use one public hostname per session when possible, for example:

- `alice-vibe.example.com` -> `127.0.0.1:8081`
- `bob-vibe.example.com` -> `127.0.0.1:8082`

Install Nginx and htpasswd tooling:

```bash
sudo apt-get update
sudo apt-get install -y nginx apache2-utils
```

Create a Basic Auth password file:

```bash
sudo htpasswd -c /etc/nginx/.htpasswd-alice alice
```

Add this `map` block once in `/etc/nginx/nginx.conf` inside the `http` block:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
```

Create `/etc/nginx/sites-available/alice-vibe.conf`:

```nginx
server {
    listen 80;
    server_name alice-vibe.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name alice-vibe.example.com;

    ssl_certificate /etc/letsencrypt/live/alice-vibe.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/alice-vibe.example.com/privkey.pem;

    auth_basic "Restricted";
    auth_basic_user_file /etc/nginx/.htpasswd-alice;

    location / {
        proxy_pass http://127.0.0.1:8081/;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;

        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
```

Enable the site:

```bash
sudo ln -s /etc/nginx/sites-available/alice-vibe.conf /etc/nginx/sites-enabled/alice-vibe.conf
sudo nginx -t
sudo systemctl reload nginx
```

If you need certificates, `certbot --nginx` is the usual path:

```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d alice-vibe.example.com
```

## Security Notes

This design reduces exposure, but it is still a remote code execution environment by design. Treat it accordingly.

Recommended controls:

- Keep Docker and the host OS patched.
- Expose only ports `80` and `443` publicly.
- Keep session ports bound to `127.0.0.1` only.
- Use HTTPS. Do not use Basic Auth over plain HTTP.
- Keep the Codex auth mount read-only.
- Prefer one container per teammate and remove it when finished.
- Use DNS names per user/session instead of sharing raw ports.
- Consider host-level firewall rules with `ufw` or cloud security groups.
- Consider Docker daemon isolation features such as rootless Docker, user namespaces, and custom seccomp/apparmor profiles if this becomes a shared production service.

## Operational Notes

- The container user is `coder` (UID `1000`).
- If the mounted host auth directory is not readable inside the container, align permissions or adjust the image UID/GID to match the host account that owns `~/.config/codex`.
- Session data is ephemeral unless you add additional bind mounts or Docker volumes for project files.
- The launcher applies modest resource limits (`--cpus`, `--memory`, `--pids-limit`) that you can tune per server size.
