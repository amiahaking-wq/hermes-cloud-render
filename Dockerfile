# Hermes Cloud Desktop — single-image build for Render free tier.
# Slimmed: no Chrome libs, no xfce4-goodies. Just enough to run XFCE + VNC + noVNC + Hermes.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-22.04

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NOVNC_PORT=7860 \
    HOME=/home/vscode \
    TERM=xterm-256color

# Slim XFCE + VNC + noVNC + Hermes deps in one layer, then clean apt cache.
RUN apt-get update && apt-get install -y --no-install-recommends \
    xfce4 xfce4-terminal thunar \
    tigervnc-standalone-server tigervnc-viewer \
    novnc websockify \
    python3 python3-pip python3-venv python3-dev \
    curl wget ca-certificates git jq supervisor \
    nodejs npm \
    libdbus-1-3 libgtk-3-0 libx11-xcb1 libxcb-cursor0 \
    fonts-liberation fonts-dejavu fonts-noto-color-emoji \
    sudo dbus-x11 xauth \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create non-root user `vscode` and grant passwordless sudo.
RUN id -u vscode >/dev/null 2>&1 || useradd -m -s /bin/bash vscode \
 && echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode \
 && chmod 0440 /etc/sudoers.d/vscode

# Directories for runtime state.
RUN mkdir -p /home/vscode/.vnc /home/vscode/hermes /var/log/supervisor \
 && chown -R vscode:vscode /home/vscode /var/log/supervisor

# Install Hermes Agent in a Python 3.11 venv (ubuntu-22.04 ships 3.10).
USER vscode
WORKDIR /home/vscode
ENV PATH="/home/vscode/.local/bin:/home/vscode/hermes/.venv/bin:${PATH}"

RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
 && . "$HOME/.local/bin/env" \
 && uv python install 3.11 \
 && git clone --depth 1 https://github.com/NousResearch/hermes-agent.git /home/vscode/hermes-src \
 && /home/vscode/.local/bin/uv venv --python 3.11 /home/vscode/hermes/.venv \
 && /home/vscode/hermes/.venv/bin/pip install --quiet -e . 2>&1 | tail -3 \
 || echo "Hermes pip install deferred — see entrypoint"

# Project files (poller + supervisor config + entrypoint).
COPY --chown=vscode:vscode poller.py /home/vscode/hermes/poller.py
COPY --chown=vscode:vscode supervisor.conf /home/vscode/hermes/supervisor.conf
COPY --chown=root:root entrypoint.sh /entrypoint.sh

USER root
RUN cp /home/vscode/hermes/supervisor.conf /etc/supervisor/conf.d/hermes.conf \
 && chmod +x /entrypoint.sh

# Render free containers run as root by default; allow noVNC to listen on 7860
EXPOSE 7860
ENTRYPOINT ["/entrypoint.sh"]
CMD ["start"]
