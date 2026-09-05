# Hermes Cloud Desktop — single-image build for HF Spaces
# - XFCE4 + VNC + noVNC on :7860 (HF Spaces default app_port)
# - Hermes CLI installed
# - Telegram bot polling (background)
# - AgentMail inbox polling (background)
# - Supabase used for session/message persistence

FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=7860 \
    HOME=/home/vscode \
    TERM=xterm-256color

# System packages: XFCE desktop, TigerVNC, noVNC + websockify, build tools, Hermes deps.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xfce4 xfce4-goodies xfce4-terminal \
    tigervnc-standalone-server tigervnc-viewer \
    novnc websockify \
    python3 python3-pip python3-venv \
    curl wget ca-certificates git jq supervisor \
    nodejs npm \
    libnss3 libatk1.0-0 libatk-bridge2.0-0 libcups2 libxkbcommon0 \
    libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libgbm1 libpango-1.0-0 \
    libcairo2 libasound2 fonts-liberation fonts-noto-color-emoji \
    sudo dbus-x11 xauth \
 && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user `vscode` (HF Spaces default) and give it passwordless sudo.
RUN id -u vscode >/dev/null 2>&1 || useradd -m -s /bin/bash vscode \
 && echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode \
 && chmod 0440 /etc/sudoers.d/vscode

# VNC password will be set at container start via env (VNCPASS) — not baked into image.
# noVNC web files (HF Spaces serves from /workspace via their proxy).
RUN mkdir -p /home/vscode/.vnc /home/vscode/hermes /var/log/supervisor \
 && chown -R vscode:vscode /home/vscode /var/log/supervisor

# Install Hermes Agent CLI. We pin to main but allow upgrade later.
USER vscode
WORKDIR /home/vscode
ENV PATH="/home/vscode/.local/bin:/home/vscode/hermes/.venv/bin:${PATH}"

# Hermes requires Python 3.11+; ubuntu-22.04 ships 3.10. Use uv to install 3.11.
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && . "$HOME/.local/bin/env" \
 && uv python install 3.11

# Clone Hermes and install CLI in a venv.
RUN git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /home/vscode/hermes-src \
 && . "$HOME/.local/bin/env" \
 && cd /home/vscode/hermes-src \
 && uv venv --python 3.11 /home/vscode/hermes/.venv \
 && /home/vscode/hermes/.venv/bin/pip install -e . 2>&1 | tail -5 \
 || echo "Hermes pip install deferred — will install at first run if missing"

# Telegram bot poller — small standalone script that calls into Hermes.
COPY --chown=vscode:vscode poller.py /home/vscode/hermes/poller.py
COPY --chown=vscode:vscode supervisor.conf /home/vscode/hermes/supervisor.conf

USER root
RUN cp /home/vscode/hermes/supervisor.conf /etc/supervisor/conf.d/hermes.conf

# Entrypoint: write VNC password, start VNC, start noVNC, start supervisord (which starts poller).
COPY --chown=root:root entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 7860
ENTRYPOINT ["/entrypoint.sh"]
CMD ["start"]
