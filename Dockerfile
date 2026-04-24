FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=20

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SHELL=/bin/bash \
    HOME=/home/coder \
    CODE_SERVER_CONFIG=/home/coder/.config/code-server/config.yaml

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      bubblewrap \
      build-essential \
      ca-certificates \
      curl \
      dumb-init \
      git \
      gnupg \
      jq \
      less \
      lsb-release \
      nano \
      htop \
      openssh-client \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      shellinabox \
      software-properties-common \
      sudo \
      tmux \
      tree \
      unzip \
      vim \
      wget \
      zip \
      xz-utils && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    npm install -g @openai/codex opencode-ai && \
    npm install --prefix /opt/http-terminal @xterm/xterm @xterm/addon-fit && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL https://code-server.dev/install.sh | sh

RUN if id -u coder >/dev/null 2>&1; then \
      usermod --shell /bin/bash coder; \
    elif getent passwd 1000 >/dev/null 2>&1; then \
      existing_user="$(getent passwd 1000 | cut -d: -f1)" && \
      existing_home="$(getent passwd 1000 | cut -d: -f6)" && \
      existing_group="$(getent group 1000 | cut -d: -f1 || true)" && \
      usermod --login coder --home /home/coder --shell /bin/bash "$existing_user" && \
      if [ -n "$existing_group" ] && [ "$existing_group" != "coder" ]; then groupmod --new-name coder "$existing_group"; fi && \
      if [ "$existing_home" != "/home/coder" ] && [ -d "$existing_home" ]; then mv "$existing_home" /home/coder; fi; \
    else \
      useradd --create-home --shell /bin/bash --uid 1000 coder; \
    fi && \
    mkdir -p \
      /home/coder/project \
      /home/coder/.config/code-server \
      /home/coder/.config/codex \
      /home/coder/.config/opencode \
      /home/coder/.codex \
      /home/coder/.local/share/opencode \
      /home/coder/.local/state/opencode && \
    chown -R coder:coder /home/coder && \
    echo "coder ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/coder && \
    chmod 0440 /etc/sudoers.d/coder

RUN printf '%s\n' \
    'bind-addr: 0.0.0.0:8080' \
    'auth: none' \
    'cert: false' \
    > /home/coder/.config/code-server/config.yaml && \
    chown coder:coder /home/coder/.config/code-server/config.yaml

COPY terminal_server.py /usr/local/bin/terminal-server
RUN chmod 0755 /usr/local/bin/terminal-server
COPY shellinabox-dark.css /usr/local/share/vibe-sandbox/shellinabox-dark.css
COPY vibe-entrypoint.sh /usr/local/bin/vibe-entrypoint
COPY vibe-shell.sh /usr/local/bin/vibe-shell
RUN chmod 0755 /usr/local/bin/vibe-entrypoint /usr/local/bin/vibe-shell

USER root
WORKDIR /home/coder/project

EXPOSE 8080 3000

ENTRYPOINT ["/usr/bin/dumb-init", "--", "/usr/local/bin/vibe-entrypoint"]
CMD ["shellinaboxd", "-t", "--no-beep", "--css=/usr/local/share/vibe-sandbox/shellinabox-dark.css", "-p", "8080", "-s", "/:coder:coder:/home/coder/project:/usr/local/bin/vibe-shell"]
